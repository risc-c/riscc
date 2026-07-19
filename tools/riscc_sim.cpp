#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#if defined(__unix__) || defined(__APPLE__)
#include <sys/select.h>
#endif
#include <SDL.h>
#include <stb/stb_image_write.h>

#ifndef RISCC_VERSION
#define RISCC_VERSION "unknown"
#endif

namespace
{

// The top sixteen words are permanently reserved for board I/O and test
// control. The ISS models the shared board timer/IRQ subset as well as its
// test-only control registers.
constexpr uint16_t IRQ_PENDING_W = 0x7ff0; // byte 0xffe0
constexpr uint16_t IRQ_ENABLE_W = 0x7ff1;  // byte 0xffe2
constexpr uint16_t TIMER_COUNT_W = 0x7ff2; // byte 0xffe4
constexpr uint16_t TICKS_W = 0x7ff3;       // byte 0xffe6
constexpr uint16_t UART_TX_W = 0x7ff8;     // byte 0xfff0
constexpr uint16_t UART_RX_W = 0x7ff9;     // byte 0xfff2
constexpr uint16_t UART_STATUS_W = 0x7ffa; // byte 0xfff4
constexpr uint16_t UART_CTRL_W = 0x7ffb;   // byte 0xfff6
constexpr uint16_t IRQ_ACK_W = 0x7ffc;     // byte 0xfff8
constexpr uint16_t IRQ_RAISE_W = 0x7ffd;   // byte 0xfffa
constexpr uint16_t RESULT_W = 0x7fff;      // byte 0xfffe
constexpr uint16_t RESET_PC = 0x0000;
constexpr uint64_t TIMER_TICK_HZ = 1000;
constexpr double DEFAULT_TIMER_MHZ = 50.0;

constexpr uint16_t FB_BASE_W = 0x4000;
constexpr int FB_WIDTH = 160;
constexpr int FB_HEIGHT = 120;
constexpr int FB_PIXELS = FB_WIDTH * FB_HEIGHT;
constexpr int FB_UPDATE_MS = 33;

struct CycleTable
{
    uint64_t direct;
    uint64_t reg_alu;
    uint64_t slt;
    uint64_t count1_shift;
    uint64_t funnel_left;
    uint64_t funnel_right;
    uint64_t ldw_imm;
    uint64_t stw_imm;
    uint64_t index_load;
    uint64_t direct_store;
    uint64_t ret;
    uint64_t reg_jump;
    uint64_t jump16;
    uint64_t mul;
    uint64_t irq_entry;
    uint64_t variable_shift_base;
    uint64_t variable_shift_step;
    uint64_t variable_shift_one;
    uint64_t result_store_adjust;

    uint64_t variable_shift(int amount) const
    {
        if (amount == 1)
            return variable_shift_one;
        return variable_shift_base + variable_shift_step * static_cast<uint64_t>(amount);
    }
};

constexpr CycleTable TINY16_CYCLES =
{
    3,  // immediate ALU, branch, S-reg move, IE control, count-1 shift
    4,  // register ALU
    5,  // SLT/SLTU
    3,  // count-1 SHRI/SARI in min/sys builds
    5,  // FSL1 stages its result through MDR writeback
    4,  // FSR1 follows the normal two-source execute path
    6,  // LDW rd, [ra+simm8]
    5,  // STW rd, [ra+simm8]
    7,  // LDWX/LDB/LDBS
    5,  // direct-register STB
    4,  // RET/RETI
    5,  // register jump/call
    6,  // two-word jump/call
    22, // MUL
    2,  // interrupt entry
    2,  // variable shift base: 2*n + 2
    2,  // variable shift step
    4,  // count-one variable shift
    0,  // result store is observed at the end of the /16 store cycle
};

CycleTable cycle_table_for_fast(bool dsp)
{
    return CycleTable{
        1,              // ordinary ALU/immediate/untaken branch issue
        1,              // register ALU
        1,              // SLT/SLTU
        1,              // count-one shift completes directly in execute
        1,              // FSL1
        1,              // FSR1
        2,              // one load-response stall; younger fetch is retained
        2,              // immediate store consumes one fetch slot
        2,              // one load-response stall; younger fetch is retained
        2,              // register-indirect store consumes one fetch slot
        3,              // return redirect/refill
        3,              // register jump/call redirect/refill
        3,              // prefetched JAL16 target redirect/refill
        dsp ? 1u : 17u, // direct DSP result or X plus 15 side-state MUL steps
        3,              // approximate IRQ redirect/refill
        0,              // first bit in EX; remaining bits overlap held fetch
        1,
        1,              // count-one shift completes directly in execute
        0,
    };
}

CycleTable cycle_table_for_tiny_width(int width)
{
    if (width == 16)
        return TINY16_CYCLES;

    int pass = 0;
    if (width == 1 || width == 2 || width == 4 || width == 8)
    {
        pass = 16 / width;
    }
    else
    {
        throw std::runtime_error("--width must be one of 1, 2, 4, 8, 16");
    }

    CycleTable t{};
    t.direct = 3 + pass;
    t.reg_alu = 3 + 2 * pass;
    t.slt = 3 + 3 * pass;
    t.count1_shift = 3 + 2 * pass;
    t.funnel_left = 3 + 3 * pass;
    t.funnel_right = 3 + 3 * pass;
    t.ldw_imm = 4 + 3 * pass;
    t.stw_imm = 3 + 3 * pass;
    t.index_load = 4 + 4 * pass;
    t.direct_store = 3 + 3 * pass;
    t.ret = 3 + 2 * pass;
    t.reg_jump = 3 + 2 * pass;
    t.jump16 = 4 + 3 * pass;
    t.mul = 3 + 18 * pass;
    t.irq_entry = 3 + pass;
    t.variable_shift_base = 3 + pass;
    t.variable_shift_step = pass;
    t.variable_shift_one = t.variable_shift_base + t.variable_shift_step;
    t.result_store_adjust = pass - 1;
    return t;
}

struct Rgb
{
    uint8_t r;
    uint8_t g;
    uint8_t b;
};

constexpr std::array<Rgb, 16> FB_PALETTE = {{
    {0x02, 0x04, 0x0a}, {0x06, 0x11, 0x2b}, {0x0a, 0x1f, 0x4d}, {0x0d, 0x32, 0x74},
    {0x10, 0x49, 0x9c}, {0x14, 0x64, 0xc4}, {0x1a, 0x82, 0xe6}, {0x25, 0xa4, 0xff},
    {0x45, 0xbd, 0xff}, {0x6d, 0xd3, 0xff}, {0x98, 0xe5, 0xff}, {0xbd, 0xf1, 0xff},
    {0xd8, 0xf8, 0xff}, {0xea, 0xfc, 0xff}, {0xf6, 0xfe, 0xff}, {0xff, 0xff, 0xff},
}};

int16_t sign_extend_8(uint8_t v)
{
    return (v & 0x80) ? static_cast<int16_t>(static_cast<int>(v) - 256) : static_cast<int16_t>(v);
}

int32_t sign_extend_16(uint16_t v)
{
    return (v & 0x8000) ? static_cast<int32_t>(v) - 0x10000 : static_cast<int32_t>(v);
}

uint64_t parse_u64(const std::string &s)
{
    char *end = nullptr;
    uint64_t v = std::strtoull(s.c_str(), &end, 0);
    if (end == s.c_str() || *end != '\0')
        throw std::runtime_error("invalid integer: " + s);
    return v;
}

double parse_double(const std::string &s)
{
    char *end = nullptr;
    double v = std::strtod(s.c_str(), &end);
    if (end == s.c_str() || *end != '\0' || !std::isfinite(v))
        throw std::runtime_error("invalid number: " + s);
    return v;
}

std::vector<uint8_t> read_file(const std::string &path)
{
    std::ifstream f(path, std::ios::binary);
    if (!f)
        throw std::runtime_error("cannot open " + path);
    return std::vector<uint8_t>(std::istreambuf_iterator<char>(f), {});
}

struct Opts
{
    std::string image;
    bool min = false;
    bool full = false;
    bool nano = false;
    bool fast = false;
    bool fast_dsp = false;
    int width = 16;
    uint64_t max_insns = 2000000;
    double mhz = 0.0;
    bool trace = false;
    bool state = false;
    bool dump_written = false;
    bool uart = false;
    bool have_dump = false;
    uint32_t dump_base = 0;
    uint32_t dump_len = 0;
    bool fb_window = false;
    int fb_scale = 2;
    std::string fb_dump_png;

    bool uart_enabled() const
    {
        return uart;
    }

    bool has_sys() const
    {
        return fast || (!nano && !min);
    }

    bool has_shifts() const
    {
        return fast || nano || !min;
    }

    bool has_full() const
    {
        return fast || (full && !nano);
    }
};

bool host_stdin_ready()
{
    // iostream may already have buffered bytes from a pipe, in which case the
    // kernel descriptor need not be readable any more.
    if (std::cin.rdbuf()->in_avail() > 0)
        return true;

#if defined(__unix__) || defined(__APPLE__)
    fd_set read_fds;
    FD_ZERO(&read_fds);
    FD_SET(fileno(stdin), &read_fds);
    timeval timeout{};
    return select(fileno(stdin) + 1, &read_fds, nullptr, nullptr, &timeout) > 0;
#else
    return false;
#endif
}

struct Sim
{
    Opts opts;
    CycleTable cycle;
    std::array<uint16_t, 32768> mem{};
    std::array<uint8_t, 32768> mem_written{};
    std::array<uint16_t, 8> r{};
    std::array<uint16_t, 8> s{};
    uint16_t pc = RESET_PC;
    bool ie = false;
    bool irq_line = false;
    uint8_t irq_enable = 0;
    uint16_t timer_count = 0;
    bool timer_pending = false;
    uint16_t ticks = 0;
    uint64_t timer_cycles_per_tick = 1;
    uint64_t timer_cycle_remainder = 0;
    bool done = false;
    uint64_t pending_cycle_adjust = 0;
    bool uart_rx_ready = false;
    bool uart_rx_overflow = false;
    bool uart_tx_ready = true;
    uint8_t uart_rx_data = 0;
    uint8_t uart_irq_en = 0;
    bool uart_stdin_eof = false;
    bool halted = false;
    uint64_t insns = 0;
    uint64_t cycles = 3; // Match the RTL testbench's reset/startup count.
    uint64_t trace_steps = 0;

    Sim(const std::vector<uint8_t> &image, const Opts &opts)
        : opts(opts), cycle(opts.fast ? cycle_table_for_fast(opts.fast_dsp) :
            cycle_table_for_tiny_width(opts.width))
    {
        // Sys /16 deliberately stages STB for one extra cycle; min/full
        // issue its address directly. Other width/profile timings are shared.
        if (!opts.fast && !opts.nano && opts.width == 16 &&
            !opts.min && !opts.full)
            cycle.direct_store = 6;
        double timer_mhz = opts.mhz > 0.0 ? opts.mhz : DEFAULT_TIMER_MHZ;
        timer_cycles_per_tick = static_cast<uint64_t>(
            std::llround(timer_mhz * static_cast<double>(TIMER_TICK_HZ)));
        if (timer_cycles_per_tick == 0)
            timer_cycles_per_tick = 1;
        size_t limit = std::min<size_t>(image.size(), 65536);
        for (size_t i = 0; i < limit; i += 2)
        {
            uint16_t hi = (i + 1 < limit) ? image[i + 1] : 0;
            mem[i >> 1] = static_cast<uint16_t>(image[i] | (hi << 8));
        }
    }

    void service_uart()
    {
        if (!opts.uart_enabled() || uart_rx_ready || uart_stdin_eof)
            return;
        if (!host_stdin_ready())
            return;
        int value = std::cin.get();
        if (value == EOF)
        {
            uart_stdin_eof = true;
            return;
        }
        uart_rx_data = static_cast<uint8_t>(value);
        uart_rx_ready = true;
    }

    bool uart_irq() const
    {
        if (!opts.uart_enabled())
            return false;
        return ((uart_irq_en & 1) && uart_rx_ready) ||
               ((uart_irq_en & 2) && uart_tx_ready);
    }

    uint16_t peripheral_pending() const
    {
        return static_cast<uint16_t>((uart_irq() ? 1 : 0) |
                (timer_pending ? 2 : 0));
    }

    bool peripheral_irq() const
    {
        return (peripheral_pending() & irq_enable) != 0;
    }

    void advance_timer_ticks(uint64_t elapsed)
    {
        ticks = static_cast<uint16_t>(ticks + elapsed);
        if (timer_count == 0)
            return;
        if (elapsed >= timer_count)
        {
            timer_count = 0;
            timer_pending = true;
        }
        else
        {
            timer_count = static_cast<uint16_t>(timer_count - elapsed);
        }
    }

    void advance_cycles(uint64_t elapsed)
    {
        cycles += elapsed;

        uint64_t elapsed_ticks = elapsed / timer_cycles_per_tick;
        timer_cycle_remainder += elapsed % timer_cycles_per_tick;
        if (timer_cycle_remainder >= timer_cycles_per_tick)
        {
            ++elapsed_ticks;
            timer_cycle_remainder -= timer_cycles_per_tick;
        }
        if (elapsed_ticks)
            advance_timer_ticks(elapsed_ticks);
    }

    uint16_t load_word(uint16_t baddr)
    {
        uint16_t waddr = (baddr >> 1) & 0x7fff;
        if (waddr == IRQ_PENDING_W)
            return peripheral_pending();
        if (waddr == IRQ_ENABLE_W)
            return irq_enable;
        if (waddr == TIMER_COUNT_W)
            return timer_count;
        if (waddr == TICKS_W)
            return ticks;
        if (opts.uart_enabled())
        {
            if (waddr == UART_RX_W)
            {
                uint16_t val = uart_rx_data;
                uart_rx_ready = false;
                uart_rx_overflow = false;
                return val;
            }
            if (waddr == UART_STATUS_W)
            {
                return static_cast<uint16_t>((uart_rx_overflow ? 4 : 0) |
                        (uart_rx_ready ? 2 : 0) |
                        (uart_tx_ready ? 1 : 0));
            }
            if (waddr == UART_CTRL_W)
                return uart_irq_en & 3;
        }
        return mem[waddr];
    }

    void store_word(uint16_t baddr, uint16_t val, int mask = 3)
    {
        uint16_t w = (baddr >> 1) & 0x7fff;
        if (w == IRQ_ENABLE_W)
        {
            irq_enable = static_cast<uint8_t>(val & 3);
            return;
        }
        if (w == TIMER_COUNT_W)
        {
            timer_count = val;
            timer_pending = false;
            return;
        }
        if (w == IRQ_PENDING_W || w == TICKS_W)
            return;
        if (opts.uart_enabled() && (w == UART_TX_W || w == UART_CTRL_W))
        {
            mem_written[w] = 1;
            if (w == UART_TX_W && (mask & 1))
            {
                uint8_t byte = static_cast<uint8_t>(val);
                std::putchar(byte);
                std::fflush(stdout);
                uart_tx_ready = true;
            }
            else if (w == UART_CTRL_W && (mask & 1))
            {
                uart_irq_en = static_cast<uint8_t>(val & 3);
            }
            return;
        }
        uint16_t old = mem[w];
        if (mask & 1)
            old = static_cast<uint16_t>((old & 0xff00) | (val & 0x00ff));
        if (mask & 2)
            old = static_cast<uint16_t>((old & 0x00ff) | (val & 0xff00));
        mem[w] = old;
        mem_written[w] = 1;
        if (w == IRQ_RAISE_W)
            irq_line = true;
        if (w == IRQ_ACK_W)
            irq_line = false;
        if (w == RESULT_W)
        {
            done = true;
            pending_cycle_adjust = cycle.result_store_adjust;
        }
    }

    uint16_t load_byte(uint16_t baddr, bool is_signed) const
    {
        uint16_t waddr = (baddr >> 1) & 0x7fff;
        uint16_t w = mem[waddr];
        uint16_t b = (baddr & 1) ? ((w >> 8) & 0xff) : (w & 0xff);
        if (is_signed && (b & 0x80))
            b |= 0xff00;
        return b;
    }

    void store_byte(uint16_t baddr, uint16_t val)
    {
        if (baddr & 1)
            store_word(baddr, static_cast<uint16_t>((val & 0xff) << 8), 2);
        else
            store_word(baddr, static_cast<uint16_t>(val & 0xff), 1);
    }

    void emit_trace(uint16_t, uint16_t ir)
    {
        if (!opts.trace)
            return;
        std::fprintf(stderr, "TRACE step=%llu pc=%04X ir=%04X ie=%u r=",
                static_cast<unsigned long long>(trace_steps),
                pc & 0x7fff, ir & 0xffff, ie ? 1 : 0);
        for (int i = 0; i < 8; i++)
        {
            if (i)
                std::fputc(',', stderr);
            std::fprintf(stderr, "%04X", r[i]);
        }
        std::fprintf(stderr, " s=");
        for (int i = 0; i < 8; i++)
        {
            if (i)
                std::fputc(',', stderr);
            std::fprintf(stderr, "%04X", s[i]);
        }
        std::fputc('\n', stderr);
        trace_steps++;
    }

    void step()
    {
        service_uart();
        uint16_t pc_before = pc;
        uint16_t ir = mem[pc & 0x7fff];
        if (opts.has_sys() && ie && (irq_line || peripheral_irq()))
        {
            s[0] = pc & 0x7fff;
            ie = false;
            pc = 2;
            advance_cycles(cycle.irq_entry);
            emit_trace(pc_before, ir);
            return;
        }

        insns++;
        uint64_t instr_cycles = 0;
        uint16_t pc_next = (pc + 1) & 0x7fff;
        uint16_t opcode = ir >> 14;
        uint16_t rd = (ir >> 11) & 7;
        uint16_t ra = (ir >> 8) & 7;
        uint16_t func = (ir >> 3) & 0x1f;
        uint16_t rb = ir & 7;
        uint8_t imm8 = static_cast<uint8_t>(ir);

        if (opcode == 0)
        {
            r[rd] = load_word(static_cast<uint16_t>(r[ra] + sign_extend_8(imm8)));
            instr_cycles = cycle.ldw_imm;
        }
        else if (opcode == 1)
        {
            uint16_t addr = static_cast<uint16_t>(r[ra] + sign_extend_8(imm8));
            store_word(addr, r[rd]);
            instr_cycles = cycle.stw_imm;
        }
        else if (opcode == 2)
        {
            if (ra == 0)
            {
                r[rd] = imm8;
                instr_cycles = cycle.direct;
            }
            else if (ra == 1)
            {
                r[rd] = static_cast<uint16_t>(imm8 << 8);
                instr_cycles = cycle.direct;
            }
            else if (ra == 2)
            {
                r[rd] = static_cast<uint16_t>(r[rd] + sign_extend_8(imm8));
                instr_cycles = cycle.direct;
            }
            else if (ra == 3)
            {
                if (opts.nano)
                    throw std::runtime_error("CMPI in nano");
                r[0] = static_cast<uint16_t>(r[rd] - sign_extend_8(imm8));
                instr_cycles = cycle.direct;
            }
            else if (ra == 4)
            {
                r[rd] = static_cast<uint16_t>(r[rd] & imm8);
                instr_cycles = cycle.direct;
            }
            else if (ra == 5)
            {
                r[rd] = static_cast<uint16_t>(r[rd] | imm8);
                instr_cycles = cycle.direct;
            }
            else if (ra == 6)
            {
                r[rd] = static_cast<uint16_t>(r[rd] ^ imm8);
                instr_cycles = cycle.direct;
            }
            else
            {
                int16_t rel = sign_extend_8(imm8);
                bool taken = false;
                if (rd < 4)
                {
                    bool take = false;
                    if (rd == 0)
                        take = r[0] == 0;
                    else if (rd == 1)
                        take = r[0] != 0;
                    else if (rd == 2)
                        take = r[0] & 0x8000;
                    else
                        take = !(r[0] & 0x8000);
                    if (take)
                    {
                        pc_next = static_cast<uint16_t>((pc_next + rel) & 0x7fff);
                        taken = true;
                    }
                }
                else if (rd == 4)
                {
                    pc_next = static_cast<uint16_t>((pc_next + rel) & 0x7fff);
                    taken = true;
                    // HALT is the canonical JMP8 -1 encoding.  Hardware
                    // parks at that address; the ISS can terminate instead.
                    if (rel == -1)
                        halted = true;
                }
                else
                {
                    throw std::runtime_error("branch cc 101/110/111 reserved");
                }
                instr_cycles = (opts.fast && taken) ? 3 : cycle.direct;
            }
        }
        else
        {
            if (func < 0x08)
            {
                uint16_t a = r[ra];
                uint16_t b = r[rb];
                uint16_t res = 0;
                if (func == 0)
                {
                    res = static_cast<uint16_t>(a + b);
                }
                else if (func == 1)
                {
                    res = static_cast<uint16_t>(a - b);
                }
                else if (func == 2)
                {
                    if (opts.nano)
                    {
                        res = a < b ? 1 : 0;
                    }
                    else
                    {
                        res = sign_extend_16(a) < sign_extend_16(b) ? 1 : 0;
                    }
                }
                else if (func == 3)
                {
                    res = a < b ? 1 : 0;
                }
                else if (func == 4)
                {
                    res = a & b;
                }
                else if (func == 5)
                {
                    res = a | b;
                }
                else if (func == 6)
                {
                    res = a ^ b;
                }
                else if (func == 0x07)
                {
                    if (!opts.has_full())
                        throw std::runtime_error("MUL without the full profile");
                    res = static_cast<uint16_t>(a * b);
                }
                r[rd] = res;
                instr_cycles = (func == 0x07) ? cycle.mul :
                        (func == 2 || func == 3) ? cycle.slt :
                        cycle.reg_alu;
            }
            else if (func == 0x08 || func == 0x0a || func == 0x0e)
            {
                uint16_t addr = static_cast<uint16_t>(r[ra] + r[rb]);
                if (func == 0x08)
                {
                    r[rd] = load_word(addr);
                    instr_cycles = cycle.index_load;
                }
                else if (func == 0x0a)
                {
                    r[rd] = load_byte(addr, false);
                    instr_cycles = cycle.index_load;
                }
                else
                {
                    r[rd] = load_byte(addr, true);
                    instr_cycles = cycle.index_load;
                }
            }
            else if (func == 0x0c || func == 0x0d)
            {
                int n = opts.nano ? 1 : (opts.has_shifts() ? static_cast<int>(rb + 1) : 1);
                uint16_t v = r[ra];
                for (int i = 0; i < n; i++)
                {
                    uint16_t fill = (func == 0x0d && (v & 0x8000)) ? 0x8000 : 0;
                    v = static_cast<uint16_t>((v >> 1) | fill);
                }
                r[rd] = v;
                instr_cycles = (opts.has_shifts() && !opts.nano) ?
                    cycle.variable_shift(n) : cycle.count1_shift;
            }
            else if (func == 0x0f)
            {
                if (opts.nano || !opts.has_shifts())
                    throw std::runtime_error("SHLI is not in the min profile");
                r[rd] = static_cast<uint16_t>(r[ra] << (rb + 1));
                instr_cycles = cycle.variable_shift(static_cast<int>(rb + 1));
            }
            else if (func == 0x12 || func == 0x13)
            {
                if (opts.nano)
                    throw std::runtime_error("funnel shift in nano");
                uint16_t a = r[ra];
                uint16_t b = r[rb];
                if (func == 0x13)
                {
                    r[rd] = static_cast<uint16_t>((a << 1) | (b >> 15));
                    instr_cycles = cycle.funnel_left;
                }
                else
                {
                    r[rd] = static_cast<uint16_t>((a >> 1) | (b << 15));
                    instr_cycles = cycle.funnel_right;
                }
            }
            else if (func == 0x0b)
            {
                if (rb != 0)
                    throw std::runtime_error("STB sub-op reserved");
                store_byte(r[ra], r[rd]);
                instr_cycles = cycle.direct_store;
            }
            else if (func == 0x1f)
            {
                if (opts.nano)
                {
                    if (rb != 1)
                        throw std::runtime_error("non-JAL sys op in nano");
                    uint16_t target = r[ra] & 0x7fff;
                    if (rd != 0)
                        r[rd] = pc_next;
                    pc_next = target;
                    pc = pc_next;
                    advance_cycles(cycle.reg_jump);
                    emit_trace(pc_before, ir);
                    return;
                }
                if (rb == 0)
                {
                    if (rd == 0)
                    {// RET Sa
                        pc_next = s[ra] & 0x7fff;
                        instr_cycles = cycle.ret;
                    }
                    else if (rd == 7 && opts.has_sys())
                    {// RETI Sa
                        ie = true;
                        pc_next = s[ra] & 0x7fff;
                        instr_cycles = cycle.ret;
                    }
                    else
                    {
                        throw std::runtime_error("return control selector reserved");
                    }
                }
                else if (rb == 1)
                {
                    uint16_t target = r[ra] & 0x7fff;
                    if (rd != 0)
                        s[rd] = pc_next;
                    pc_next = target;
                    instr_cycles = cycle.reg_jump;
                }
                else if (rb == 2)
                {
                    r[rd] = s[ra];
                    instr_cycles = cycle.direct;
                }
                else if (rb == 3)
                {
                    s[rd] = r[ra];
                    instr_cycles = cycle.direct;
                }
                else if (rb == 5)
                {
                    if (!opts.has_sys())
                        throw std::runtime_error("sys-profile op in min");
                    uint16_t target = mem[pc_next & 0x7fff];
                    if (rd != 0)
                        s[rd] = static_cast<uint16_t>(pc + 2);
                    pc_next = target & 0x7fff;
                    instr_cycles = cycle.jump16;
                }
                else if (rb == 6)
                {
                    if (!opts.has_sys())
                        throw std::runtime_error("sys-profile op in min");
                    if (ra != 0)
                        throw std::runtime_error("CLI/STI ra field reserved");
                    if (rd == 0)
                        ie = false; // CLI
                    else if (rd == 7)
                        ie = true;  // STI
                    else
                        throw std::runtime_error("IE control selector reserved");
                    instr_cycles = cycle.direct;
                }
                else
                {
                    throw std::runtime_error("system sub-op reserved");
                }
            }
            else
            {
                throw std::runtime_error("register-format reserved");
            }
        }

        if (pending_cycle_adjust)
        {
            instr_cycles -= std::min(instr_cycles, pending_cycle_adjust);
            pending_cycle_adjust = 0;
        }
        advance_cycles(instr_cycles);
        pc = pc_next;
        emit_trace(pc_before, ir);
    }
};

void render_framebuffer_rgb(const Sim &sim, std::vector<uint8_t> &pixels)
{
    pixels.resize(FB_PIXELS * 3);
    for (int pix = 0; pix < FB_PIXELS; pix++)
    {
        uint16_t word = sim.mem[FB_BASE_W + (pix >> 2)];
        Rgb rgb = FB_PALETTE[(word >> ((pix & 3) * 4)) & 0xf];
        pixels[pix * 3 + 0] = rgb.r;
        pixels[pix * 3 + 1] = rgb.g;
        pixels[pix * 3 + 2] = rgb.b;
    }
}

struct FramebufferWindow
{
    SDL_Window *window = nullptr;
    SDL_Renderer *renderer = nullptr;
    SDL_Texture *texture = nullptr;
    std::vector<uint8_t> pixels;
    bool is_closed = false;

    explicit FramebufferWindow(int initial_scale)
    {
        int scale = std::max(1, initial_scale);
        if (SDL_Init(SDL_INIT_VIDEO) != 0)
            throw std::runtime_error(std::string("SDL_Init failed: ") + SDL_GetError());
        SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "nearest");
        window = SDL_CreateWindow("RISC-C framebuffer",
                SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED,
                FB_WIDTH * scale, FB_HEIGHT * scale,
                SDL_WINDOW_RESIZABLE);
        if (!window)
            throw std::runtime_error(std::string("SDL_CreateWindow failed: ") + SDL_GetError());
        renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_ACCELERATED);
        if (!renderer)
            renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_SOFTWARE);
        if (!renderer)
            throw std::runtime_error(std::string("SDL_CreateRenderer failed: ") + SDL_GetError());
        texture = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_RGB24,
                SDL_TEXTUREACCESS_STREAMING, FB_WIDTH, FB_HEIGHT);
        if (!texture)
            throw std::runtime_error(std::string("SDL_CreateTexture failed: ") + SDL_GetError());
    }

    ~FramebufferWindow()
    {
        if (texture)
            SDL_DestroyTexture(texture);
        if (renderer)
            SDL_DestroyRenderer(renderer);
        if (window)
            SDL_DestroyWindow(window);
        SDL_Quit();
    }

    void handle_events()
    {
        SDL_Event ev;
        while (SDL_PollEvent(&ev))
        {
            if (ev.type == SDL_QUIT)
            {
                is_closed = true;
            }
            else if (ev.type == SDL_KEYDOWN)
            {
                if (ev.key.keysym.sym == SDLK_q || ev.key.keysym.sym == SDLK_ESCAPE)
                    is_closed = true;
            }
        }
    }

    bool update(const Sim &sim)
    {
        if (is_closed)
            return false;
        handle_events();
        if (is_closed)
            return false;

        render_framebuffer_rgb(sim, pixels);
        SDL_UpdateTexture(texture, nullptr, pixels.data(), FB_WIDTH * 3);
        int win_w = 0;
        int win_h = 0;
        SDL_GetRendererOutputSize(renderer, &win_w, &win_h);
        int draw_scale = std::max(1, std::min(win_w / FB_WIDTH, win_h / FB_HEIGHT));
        SDL_Rect dst =
        {
            std::max(0, (win_w - FB_WIDTH * draw_scale) / 2),
            std::max(0, (win_h - FB_HEIGHT * draw_scale) / 2),
            FB_WIDTH * draw_scale,
            FB_HEIGHT * draw_scale,
        };
        std::string title = "RISC-C framebuffer  insns=" + std::to_string(sim.insns) +
                " cycles=" + std::to_string(sim.cycles);
        SDL_SetWindowTitle(window, title.c_str());
        SDL_SetRenderDrawColor(renderer, 32, 32, 32, 255);
        SDL_RenderClear(renderer);
        SDL_RenderCopy(renderer, texture, nullptr, &dst);
        SDL_RenderPresent(renderer);
        return true;
    }
};

std::string run_sim(Sim &sim, uint64_t max_insns, double mhz,
        FramebufferWindow *fb_window, bool *window_closed)
{
    using Clock = std::chrono::steady_clock;

    auto frame_period = std::chrono::milliseconds(FB_UPDATE_MS);
    auto next_frame = Clock::now();
    uint64_t throttle_step = mhz > 0.0 ? 50000 : 0;
    uint64_t next_throttle = sim.cycles + throttle_step;
    auto throttle_deadline = Clock::now();
    auto throttle_period = Clock::duration::zero();
    if (throttle_step)
    {
        throttle_period = std::chrono::duration_cast<Clock::duration>(
            std::chrono::duration<double>(static_cast<double>(throttle_step) / (mhz * 1000000.0)));
    }

    while ((max_insns == 0 || sim.insns < max_insns) && !sim.done && !sim.halted)
    {
        sim.step();
        if (throttle_step && sim.cycles >= next_throttle)
        {
            throttle_deadline += throttle_period;
            std::this_thread::sleep_until(throttle_deadline);
            next_throttle += throttle_step;
        }
        if (fb_window)
        {
            auto now = Clock::now();
            if (now >= next_frame)
            {
                if (!fb_window->update(sim))
                {
                    if (window_closed)
                        *window_closed = true;
                    return "STOPPED";
                }
                next_frame = now + frame_period;
            }
        }
    }
    if (fb_window)
    {
        if (!fb_window->update(sim) && window_closed)
            *window_closed = true;
    }
    return sim.done ? "DONE" : sim.halted ? "HALT" : "TIMEOUT";
}

void write_framebuffer_png(const Sim &sim, const std::string &path)
{
    std::vector<uint8_t> pixels;
    render_framebuffer_rgb(sim, pixels);

    if (!stbi_write_png(path.c_str(), FB_WIDTH, FB_HEIGHT, 3,
            pixels.data(), FB_WIDTH * 3))
        throw std::runtime_error("failed writing PNG " + path);
}

void print_usage(const char *prog)
{
    std::cerr
        << "RISC-C simulator " << RISCC_VERSION << "\n"
        << "usage: " << prog << " image.bin [options]\n"
        << "  --min --full\n"
        << "  --nano\n"
        << "  --fast [--fast-dsp]       approximate pipelined timing (full ISA)\n"
        << "  --width W --max-insns N --mhz N --trace --state --dump WADDR LEN --dump-written\n"
        << "    --mhz also selects the 1 kHz timer clock; without it, ISS uses 50 MHz virtual time\n"
        << "  --uart                    UART console: RX from stdin, TX to stdout\n"
        << "  --fb-window --fb-scale N --fb-dump-png FILE\n";
}

std::string need_arg(int argc, char **argv, int &i, const std::string &opt)
{
    if (++i >= argc)
        throw std::runtime_error(opt + " needs an argument");
    return argv[i];
}

Opts parse_args(int argc, char **argv)
{
    Opts opts;
    for (int i = 1; i < argc; i++)
    {
        std::string opt = argv[i];
        if (opt == "--help" || opt == "-h")
        {
            print_usage(argv[0]);
            std::exit(0);
        }
        else if (opt == "--version")
        {
            std::cout << "riscc-sim " << RISCC_VERSION << "\n";
            std::exit(0);
        }
        else if (opt == "--min")
        {
            opts.min = true;
        }
        else if (opt == "--full")
        {
            opts.full = true;
        }
        else if (opt == "--nano")
        {
            opts.nano = true;
        }
        else if (opt == "--fast")
        {
            opts.fast = true;
        }
        else if (opt == "--fast-dsp")
        {
            opts.fast = true;
            opts.fast_dsp = true;
        }
        else if (opt == "--width")
        {
            opts.width = static_cast<int>(parse_u64(need_arg(argc, argv, i, opt)));
            (void)cycle_table_for_tiny_width(opts.width);
        }
        else if (opt == "--max-insns")
        {
            opts.max_insns = parse_u64(need_arg(argc, argv, i, opt));
        }
        else if (opt == "--mhz")
        {
            opts.mhz = parse_double(need_arg(argc, argv, i, opt));
            if (opts.mhz < 0.0)
                throw std::runtime_error("--mhz must be nonnegative");
        }
        else if (opt == "--trace")
        {
            opts.trace = true;
        }
        else if (opt == "--state")
        {
            opts.state = true;
        }
        else if (opt == "--dump")
        {
            opts.have_dump = true;
            opts.dump_base = static_cast<uint32_t>(parse_u64(need_arg(argc, argv, i, opt)));
            opts.dump_len = static_cast<uint32_t>(parse_u64(need_arg(argc, argv, i, opt)));
        }
        else if (opt == "--dump-written")
        {
            opts.dump_written = true;
        }
        else if (opt == "--uart")
        {
            opts.uart = true;
        }
        else if (opt == "--fb-window")
        {
            opts.fb_window = true;
        }
        else if (opt == "--fb-scale")
        {
            opts.fb_scale = static_cast<int>(parse_u64(need_arg(argc, argv, i, opt)));
        }
        else if (opt == "--fb-dump-png")
        {
            opts.fb_dump_png = need_arg(argc, argv, i, opt);
        }
        else if (!opt.empty() && opt[0] == '-')
        {
            throw std::runtime_error("unknown option: " + opt);
        }
        else if (opts.image.empty())
        {
            opts.image = opt;
        }
        else
        {
            throw std::runtime_error("extra positional argument: " + opt);
        }
    }
    if (opts.image.empty())
        throw std::runtime_error("missing image");
    if (opts.min && opts.full)
        throw std::runtime_error("--min and --full are mutually exclusive");
    if (opts.nano && (opts.min || opts.full))
        throw std::runtime_error("--nano cannot be combined with a tiny profile");
    if (opts.fast && (opts.nano || opts.min))
        throw std::runtime_error("--fast cannot be combined with --nano or --min");
    return opts;
}

} // namespace

int main(int argc, char **argv)
{
    try
    {
        Opts opts = parse_args(argc, argv);
        std::vector<uint8_t> image = read_file(opts.image);

        Sim sim(image, opts);

        bool window_closed = false;
        std::unique_ptr<FramebufferWindow> fb_window;
        if (opts.fb_window)
            fb_window = std::make_unique<FramebufferWindow>(opts.fb_scale);
        std::string outcome = run_sim(sim, opts.max_insns, opts.mhz,
            fb_window.get(), &window_closed);
        if (!opts.fb_dump_png.empty())
            write_framebuffer_png(sim, opts.fb_dump_png);

        uint16_t result = sim.mem[RESULT_W];
        bool result_pass = result == 0x600d;
        bool normal_halt = outcome == "HALT" && result == 0;
        bool pass = result_pass || normal_halt;
        bool window_ok = opts.fb_window && window_closed;
        double ipc = sim.cycles ? static_cast<double>(sim.insns) /
            static_cast<double>(sim.cycles) : 0.0;
        std::fprintf(stderr, "%s after %llu insns, %llu cycles, IPC=%.3f, result=0x%04X: %s%s\n",
            outcome.c_str(), static_cast<unsigned long long>(sim.insns),
            static_cast<unsigned long long>(sim.cycles),
            ipc, result, (pass || window_ok) ? "PASS" : "FAIL",
            opts.fast ? " (estimated fast timing)" : "");

        if (opts.state)
        {
            std::fprintf(stderr, "STATE outcome=%s insns=%llu cycles=%llu ipc=%.6f timing=%s result=0x%04X\n",
                outcome.c_str(), static_cast<unsigned long long>(sim.insns),
                static_cast<unsigned long long>(sim.cycles), ipc,
                opts.fast ? "estimated-fast" : "modeled", result);
            std::fprintf(stderr, "R");
            for (int i = 0; i < 8; i++)
                std::fprintf(stderr, " 0x%04X", sim.r[i]);
            std::fprintf(stderr, "\nS");
            for (int i = 0; i < 8; i++)
                std::fprintf(stderr, " 0x%04X", sim.s[i]);
            std::fputc('\n', stderr);
        }

        if (opts.dump_written)
        {
            for (size_t i = 0; i < sim.mem_written.size(); i++)
            {
                if (sim.mem_written[i])
                    std::fprintf(stderr, "MEM 0x%04X 0x%04X\n", static_cast<unsigned>(i), sim.mem[i]);
            }
        }
        if (opts.have_dump)
        {
            for (uint32_t i = 0; i < opts.dump_len; i++)
            {
                uint32_t addr = opts.dump_base + i;
                std::fprintf(stderr, "  [0x%04X] = 0x%04X\n", addr & 0xffff, sim.mem[addr & 0x7fff]);
            }
        }

        return (pass || window_ok) ? 0 : 1;
    }
    catch (const std::exception &e)
    {
        std::cerr << "error: " << e.what() << "\n";
        return 1;
    }
}

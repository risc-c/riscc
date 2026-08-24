// Shared black-box Verilator testbench for the whole RISC-C core family
// (rc16-1/2/4/8/16, nano): build any core against it with the corresponding
// top module (riscc_min, riscc16, riscc_nano, or another renamed RTL top).
// so every top compiles into the same Vriscc class.  Drives only the
// architectural memory/irq interface -- no internal signals.
//
// Memory model: 32K x 16 synchronous single-port RAM (1-cycle read latency,
// like a synchronous FPGA RAM). Loads a little-endian binary image at word 0.
//
// I/O page: the top 16 bytes (0xFFF0..0xFFFF, words 0x7FF8..0x7FFF) are
// word-wide I/O registers, out of reach of code/data that grow from 0.
// Current map (mirrored by both ISSes):
//   0xFFF0                 UART data: write TX, read RX
//   0xFFF2                 UART state: write enables, read status
//   0xFFFA (word 0x7FFD)  test IRQ: write raises; read returns cause and acks
//   0xFFFE (word 0x7FFF)  result word: 0x600D pass, anything else fail
// Usage: tb <image.bin> [max_cycles] [--max-cycles N] [--irq-at N]
//           [--trace] [--dump-written] [--uart-expect-line TEXT]
//           [--mem-stall-seed N] [--stop-at-write BYTE_ADDR]
//           [--report-write BYTE_ADDR] [--report-stalls]
// --irq-at raises one IRQ at cycle N (deterministic IRQ tests without the
// store-to-0xFFFA trigger). A read from 0xFFFA acknowledges it. Exit status
// follows the result word.
// --uart-expect-line supplies an always-ready TX UART and succeeds when the
// emitted line matches TEXT.
// --trace requires a RISCC_TRACE/RISCC_TB_TRACE build and prints one
// architectural TRACE line per committed instruction.

#ifndef RISCC_TB_HEADER
#define RISCC_TB_HEADER "Vriscc.h"
#endif
#ifndef RISCC_TB_TOP
#define RISCC_TB_TOP Vriscc
#endif
#ifndef RISCC_TB_TRACE_DRAIN
#define RISCC_TB_TRACE_DRAIN 2
#endif

#include RISCC_TB_HEADER
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

static uint16_t mem[32768];
static uint8_t mem_written[32768];

#ifdef RISCC_TB_TRACE
static void print_trace(RISCC_TB_TOP *top, uint64_t step)
{
    if (!top->trace_valid)
        return;

#ifdef RISCC_TB_RC32
    printf("TRACE step=%llu pc=%08X ir=%04X ie=%u "
        "r=%08X,%08X,%08X,%08X,%08X,%08X,%08X,%08X "
        "s=%08X,%08X,%08X,%08X,%08X,%08X,%08X,%08X\n",
        (unsigned long long)step,
        (unsigned)top->trace_pc,
        (unsigned)top->trace_ir,
        (unsigned)top->trace_ie,
        (unsigned)top->trace_r0, (unsigned)top->trace_r1,
        (unsigned)top->trace_r2, (unsigned)top->trace_r3,
        (unsigned)top->trace_r4, (unsigned)top->trace_r5,
        (unsigned)top->trace_r6, (unsigned)top->trace_r7,
        (unsigned)top->trace_s0, (unsigned)top->trace_s1,
        (unsigned)top->trace_s2, (unsigned)top->trace_s3,
        (unsigned)top->trace_s4, (unsigned)top->trace_s5,
        (unsigned)top->trace_s6, (unsigned)top->trace_s7);
#else
    printf("TRACE step=%llu pc=%04X ir=%04X ie=%u "
        "r=%04X,%04X,%04X,%04X,%04X,%04X,%04X,%04X "
        "s=%04X,%04X,%04X,%04X,%04X,%04X,%04X,%04X\n",
        (unsigned long long)step,
        (unsigned)top->trace_pc,
        (unsigned)top->trace_ir,
        (unsigned)top->trace_ie,
        (unsigned)top->trace_r0, (unsigned)top->trace_r1,
        (unsigned)top->trace_r2, (unsigned)top->trace_r3,
        (unsigned)top->trace_r4, (unsigned)top->trace_r5,
        (unsigned)top->trace_r6, (unsigned)top->trace_r7,
        (unsigned)top->trace_s0, (unsigned)top->trace_s1,
        (unsigned)top->trace_s2, (unsigned)top->trace_s3,
        (unsigned)top->trace_s4, (unsigned)top->trace_s5,
        (unsigned)top->trace_s6, (unsigned)top->trace_s7);
#endif
}
#endif

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    if (argc < 2)
    {
        fprintf(stderr, "usage: %s <image.bin> [max_cycles]\n", argv[0]);
        return 2;
    }

    FILE *f = fopen(argv[1], "rb");
    if (!f)
    {
        perror(argv[1]);
        return 2;
    }
    uint8_t bytes[sizeof mem];
    memset(bytes, 0, sizeof bytes);
    size_t n = fread(bytes, 1, sizeof bytes, f);
    fclose(f);
    memset(mem_written, 0, sizeof mem_written);
    for (size_t i = 0; i < sizeof mem / sizeof mem[0]; i++)
        mem[i] = (uint16_t)(bytes[2 * i] | (bytes[2 * i + 1] << 8));
    fprintf(stderr, "loaded %zu bytes\n", n);

    uint64_t max_cycles = 2000000;
    int64_t irq_at = -1;
    int irq_at_fired = 0;
    int trace = 0;
    int dump_written = 0;
    int64_t stop_at_write = -1;
    int64_t report_at_write = -1;
    int report_stalls = 0;
    uint32_t mem_stall_seed = 0;
    const char *uart_expect_line = nullptr;
    for (int i = 2; i < argc; i++)
    {
        if (!strcmp(argv[i], "--irq-at") && i + 1 < argc)
            irq_at = strtoll(argv[++i], nullptr, 0);
        else if (!strcmp(argv[i], "--max-cycles") && i + 1 < argc)
            max_cycles = strtoull(argv[++i], nullptr, 0);
        else if (!strcmp(argv[i], "--trace"))
            trace = 1;
        else if (!strcmp(argv[i], "--dump-written"))
            dump_written = 1;
        else if (!strcmp(argv[i], "--stop-at-write") && i + 1 < argc)
            stop_at_write = strtoll(argv[++i], nullptr, 0);
        else if (!strcmp(argv[i], "--report-write") && i + 1 < argc)
            report_at_write = strtoll(argv[++i], nullptr, 0);
        else if (!strcmp(argv[i], "--report-stalls"))
            report_stalls = 1;
        else if (!strcmp(argv[i], "--mem-stall-seed") && i + 1 < argc)
            mem_stall_seed = strtoul(argv[++i], nullptr, 0);
        else if (!strcmp(argv[i], "--uart-expect-line") && i + 1 < argc)
            uart_expect_line = argv[++i];
        else
            max_cycles = strtoull(argv[i], nullptr, 0);
    }

#ifndef RISCC_TB_TRACE
    if (trace)
{
        fprintf(stderr, "--trace needs a testbench built with RISCC_TRACE and RISCC_TB_TRACE\n");
        return 2;
}
#endif

    RISCC_TB_TOP *top = new RISCC_TB_TOP;

    uint16_t rdata = 0;
    int irq = 0;
#ifdef RISCC_TB_MEM_HANDSHAKE
    uint32_t mem_stall_state = mem_stall_seed ? mem_stall_seed : 1;
    unsigned mem_wait = 0;
    int mem_pending = 0;
    uint32_t pending_addr = 0;
    uint16_t pending_wdata = 0;
    int pending_we = 0;
    int pending_wmask = 0;
#endif

    top->clk = 0;
    top->rst = 1;
    top->irq = 0;
    top->mem_rdata = 0;
#ifdef RISCC_TB_MEM_HANDSHAKE
    top->mem_ready = 0;
#endif
    top->eval();

    uint64_t cyc = 0;
    uint64_t trace_step = 0;
    int done = 0;
    int uart_done = 0;
    int done_trace_age = 0;
    int trace_printed = 0;
    int marker_done = 0;
    int external_irq_pending = 0;
    int external_irq_acked = 0;
    std::string uart_line;
    for (; cyc < max_cycles; cyc++)
    {
        trace_printed = 0;
        if (cyc == 4)
            top->rst = 0;

        if (!irq_at_fired && irq_at >= 0 && cyc >= (uint64_t)irq_at) {
            irq = 1;
            irq_at_fired = 1;
            external_irq_pending = 1;
        }
        top->irq = irq;

#ifdef RISCC_TB_MEM_HANDSHAKE
        // A native request remains asserted and stable until ready. Poison the
        // input afterward to verify that the core captured a completed read.
        top->mem_ready = 0;
        top->mem_rdata = 0xDEAD;
        top->eval();

        uint32_t addr  = top->mem_addr;
        int      we    = top->mem_we;
        uint16_t wdata = top->mem_wdata;
        int      wmask = top->mem_wmask;
        const int request = top->mem_valid;
        int request_complete = 0;

        if (mem_pending &&
            (!request || addr != pending_addr || we != pending_we ||
             (we && wdata != pending_wdata) || wmask != pending_wmask)) {
            fprintf(stderr,
                "Memory request changed before ready at cycle %llu: "
                "addr %08x/%08x we %d/%d data %04x/%04x mask %x/%x\n",
                (unsigned long long)cyc, pending_addr, addr,
                pending_we, we, pending_wdata, wdata,
                pending_wmask, wmask);
            delete top;
            return 1;
        }

        if (request && !mem_pending) {
            mem_pending = 1;
            pending_addr = addr;
            pending_we = we;
            pending_wdata = wdata;
            pending_wmask = wmask;
            if (mem_stall_seed) {
                mem_stall_state ^= mem_stall_state << 13;
                mem_stall_state ^= mem_stall_state >> 17;
                mem_stall_state ^= mem_stall_state << 5;
                mem_wait = mem_stall_state & 3;
            } else {
                mem_wait = 0;
            }
        }

        if (mem_pending && mem_wait == 0) {
            const int response_irq_read = !we && !top->rst &&
                (addr & 0x7FFF) == 0x7FFD;
            const int response_uart_state =
                uart_expect_line && !we && !top->rst &&
                (addr & 0x7FFF) == 0x7FF9;
            const uint16_t response = response_irq_read ? (irq ? 1 : 0) :
                (response_uart_state ? 1 : mem[addr & 0x7FFF]);
            top->mem_rdata =
                ((wmask & 1) ? (response & 0x00FF) : 0) |
                ((wmask & 2) ? (response & 0xFF00) : 0);
            top->mem_ready = 1;
            top->eval();
            request_complete = 1;
        } else if (mem_pending) {
            if (report_stalls)
                printf("STALL cycle=%llu\n", (unsigned long long)cyc);
            mem_wait--;
        }
#else
        // Present the prior synchronous response and settle response-driven
        // next-address logic before sampling the current request.
        top->mem_rdata = rdata;
        top->eval();

        // Sample the core's memory request during the current (pre-edge) cycle
        uint32_t addr  = top->mem_addr;
#ifdef RISCC_TB_RC32
        // The generic fixture owns a 64 KiB physical RAM window.  RC32's
        // architectural address can be wider, so alias its low window before
        // testing the common result and IRQ MMIO locations.
        addr &= 0x7fff;
#endif
        int      we    = top->mem_we;
        uint16_t wdata = top->mem_wdata;
        int      wmask = top->mem_wmask;
#ifdef RISCC_TB_MEM_OE_N
        const int request_complete = top->mem_we || !top->mem_oe_n;
#else
        const int request_complete = 1;
#endif
#endif

        const uint16_t fixture_addr = addr & 0x7FFF;

        top->clk = 1;
        top->eval();

        // Synchronous memory commits at the posedge
        const int test_irq_read = request_complete &&
            !we && !top->rst && fixture_addr == 0x7FFD;
        const uint16_t test_irq_cause = top->irq ? 1 : 0;
        if (test_irq_read) {
            if (external_irq_pending) {
                external_irq_pending = 0;
                external_irq_acked = 1;
            }
            irq = 0;
        }

        if (request_complete && we && !top->rst)
        {
            uint16_t old = mem[fixture_addr];
            uint16_t nw  = old;
            if (wmask & 1) nw = (uint16_t)((nw & 0xFF00) | (wdata & 0x00FF));
            if (wmask & 2) nw = (uint16_t)((nw & 0x00FF) | (wdata & 0xFF00));
            mem[fixture_addr] = nw;
            mem_written[fixture_addr] = 1;
            if (fixture_addr == 0x7FFD) irq = 1; // byte 0xFFFA: raise irq
            if (fixture_addr == 0x7FFF) done = 1; // byte 0xFFFE: result word
            if (stop_at_write >= 0 && fixture_addr ==
                    ((static_cast<uint64_t>(stop_at_write) >> 1) & 0x7fff))
                marker_done = 1;
            if (report_at_write >= 0 && fixture_addr ==
                    ((static_cast<uint64_t>(report_at_write) >> 1) & 0x7fff))
                printf("MARKER cycle=%llu\n", (unsigned long long)cyc);
            if (uart_expect_line && fixture_addr == 0x7FF8 && (wmask & 1))
            {
                const char ch = char(wdata & 0xFF);
                putchar(ch);
                fflush(stdout);
                if (ch == '\n')
                {
                    if (uart_line == uart_expect_line)
                        uart_done = 1;
                    uart_line.clear();
                }
                else
                    uart_line.push_back(ch);
            }
        }
#ifdef RISCC_TB_TRACE
        if (trace && top->trace_valid)
{
            print_trace(top, trace_step);
            trace_step++;
            trace_printed = 1;
}
#endif
#ifdef RISCC_TB_MEM_HANDSHAKE
        if (request_complete)
            mem_pending = 0;
#else
        if (request_complete && !we) {
            const int uart_state_read =
                uart_expect_line && !top->rst && fixture_addr == 0x7FF9;
            rdata = test_irq_read ? test_irq_cause :
                (uart_state_read ? 1 : mem[addr & 0x7FFF]);
        }
#endif

        top->clk = 0;
        top->eval();

        if (marker_done)
        {
            printf("MARKER cycle=%llu\n", (unsigned long long)cyc);
            delete top;
            return 0;
        }

        // A pipelined core can commit the result store before its trace
        // record reaches the trace output.  Allow two drain cycles; memory
        // serialization prevents a younger instruction from overtaking it.
        if ((done || uart_done) && (!trace ||
            (done_trace_age >= RISCC_TB_TRACE_DRAIN && trace_printed)))
            break;
        if ((done || uart_done) && trace)
            done_trace_age++;
    }

    uint16_t result = mem[0x7FFF];   // byte address 0xFFFE
    if (uart_expect_line)
    {
        if (!uart_done)
        {
            printf("UART TIMEOUT after %llu cycles\n", (unsigned long long)cyc);
            delete top;
            return 1;
        }
        printf("UART PASS after %llu cycles\n", (unsigned long long)cyc);
        delete top;
        return 0;
    }
    if (!done)
    {
        printf("TIMEOUT after %llu cycles, result=0x%04X\n",
            (unsigned long long)cyc, result);
        delete top;
        return 1;
    }
    if (irq_at >= 0 && !external_irq_acked)
    {
        printf("IRQ NOT ACKNOWLEDGED: requested cycle=%lld fired=%d\n",
            (long long)irq_at, irq_at_fired);
        delete top;
        return 1;
    }
    if (dump_written)
    {
        for (size_t i = 0; i < sizeof mem / sizeof mem[0]; i++)
            if (mem_written[i])
            printf("MEM 0x%04X 0x%04X\n", (unsigned)i, (unsigned)mem[i]);
    }
    printf("done after %llu cycles, result=0x%04X: %s\n",
        (unsigned long long)cyc, result,
        result == 0x600D ? "PASS" : "FAIL");
    delete top;
    return result == 0x600D ? 0 : 1;
}

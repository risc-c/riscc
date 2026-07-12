// Shared black-box Verilator testbench for the whole RISC-C core family
// (tiny1/2/4/8/16, nano): build any core against it with
//     verilator --top-module riscc_<core> --prefix Vriscc ...
// so every top compiles into the same Vriscc class.  Drives only the
// architectural memory/irq interface -- no internal signals.
//
// Memory model: 32K x 16 synchronous single-port RAM (1-cycle read latency,
// like an iCE40 UP5K SPRAM).  Loads a little-endian binary image at word 0.
//
// I/O page: the top 16 bytes (0xFFF0..0xFFFF, words 0x7FF8..0x7FFF) are
// word-wide I/O registers, out of reach of code/data that grow from 0.
// Current map (mirrored by both ISSes):
//   0xFFF0..0xFFF6         UART TX, RX, status, and control
//   0xFFF8 (word 0x7FFC)  irq ack (store) / cause log
//   0xFFFA (word 0x7FFD)  irq trigger (store raises the irq line)
//   0xFFFC (word 0x7FFE)  suite scratch (ISR entry counter)
//   0xFFFE (word 0x7FFF)  result word: 0x600D pass, anything else fail
// Usage: tb <image.bin> [max_cycles] [--max-cycles N] [--irq-at N] [--trace] [--dump-written]
// --irq-at asserts the irq line from cycle N (deterministic IRQ tests
// without the store-to-0xFFFA trigger). Exit status follows the result word.
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

static uint16_t mem[32768];
static uint8_t mem_written[32768];

#ifdef RISCC_TB_TRACE
static void print_trace(RISCC_TB_TOP *top, uint64_t step)
{
    if (!top->trace_valid)
        return;

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
}
#endif

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    if (argc < 2) {
        fprintf(stderr, "usage: %s <image.bin> [max_cycles]\n", argv[0]);
        return 2;
    }

    FILE *f = fopen(argv[1], "rb");
    if (!f) {
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
    int trace = 0;
    int dump_written = 0;
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--irq-at") && i + 1 < argc)
            irq_at = strtoll(argv[++i], nullptr, 0);
        else if (!strcmp(argv[i], "--max-cycles") && i + 1 < argc)
            max_cycles = strtoull(argv[++i], nullptr, 0);
        else if (!strcmp(argv[i], "--trace"))
            trace = 1;
        else if (!strcmp(argv[i], "--dump-written"))
            dump_written = 1;
        else
            max_cycles = strtoull(argv[i], nullptr, 0);
    }

#ifndef RISCC_TB_TRACE
    if (trace) {
        fprintf(stderr, "--trace needs a testbench built with RISCC_TRACE and RISCC_TB_TRACE\n");
        return 2;
    }
#endif

    RISCC_TB_TOP *top = new RISCC_TB_TOP;

    uint16_t rdata = 0;
    int irq = 0;

    top->clk = 0;
    top->rst = 1;
    top->irq = 0;
    top->mem_rdata = 0;
    top->eval();

    uint64_t cyc = 0;
    uint64_t trace_step = 0;
    int done = 0;
    int done_trace_age = 0;
    int trace_printed = 0;
    for (; cyc < max_cycles; cyc++) {
        trace_printed = 0;
        if (cyc == 4)
            top->rst = 0;

        // Present the prior synchronous response and settle response-driven
        // next-address logic before sampling the current request.
        top->mem_rdata = rdata;
        top->eval();

        // Sample the core's memory request during the current (pre-edge) cycle
        uint16_t addr  = top->mem_addr;
        int      we    = top->mem_we;
        uint16_t wdata = top->mem_wdata;
        int      wmask = top->mem_wmask;

        if (irq_at >= 0 && cyc >= (uint64_t)irq_at)
            irq = 1;
        top->irq = irq;

        top->clk = 1;
        top->eval();

        // Synchronous memory commits at the posedge
        if (we && !top->rst) {
            uint16_t old = mem[addr];
            uint16_t nw  = old;
            if (wmask & 1) nw = (uint16_t)((nw & 0xFF00) | (wdata & 0x00FF));
            if (wmask & 2) nw = (uint16_t)((nw & 0x00FF) | (wdata & 0xFF00));
            mem[addr] = nw;
            mem_written[addr & 0x7FFF] = 1;
            if (addr == 0x7FFD) irq = 1;   // byte 0xFFFA: raise irq
            if (addr == 0x7FFC) irq = 0;   // byte 0xFFF8: ack irq
            if (addr == 0x7FFF) done = 1;  // byte 0xFFFE: result word
        }
#ifdef RISCC_TB_TRACE
        if (trace && top->trace_valid) {
            print_trace(top, trace_step);
            trace_step++;
            trace_printed = 1;
        }
#endif
        rdata = mem[addr & 0x7FFF];

        top->clk = 0;
        top->eval();

        // A pipelined core can commit the result store before its trace
        // record reaches the trace output.  Allow two drain cycles; memory
        // serialization prevents a younger instruction from overtaking it.
        if (done && (!trace ||
                     (done_trace_age >= RISCC_TB_TRACE_DRAIN && trace_printed)))
            break;
        if (done && trace)
            done_trace_age++;
    }

    uint16_t result = mem[0x7FFF];   // byte address 0xFFFE
    if (!done) {
        printf("TIMEOUT after %llu cycles, result=0x%04X\n",
               (unsigned long long)cyc, result);
        delete top;
        return 1;
    }
    if (dump_written) {
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

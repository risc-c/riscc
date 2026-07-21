#include "Vriscc_peripherals_top.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>

static constexpr unsigned TIMER = 0xa;
static constexpr unsigned IRQ_STATE = 0xb;

static void fail(const char *message)
{
    std::fprintf(stderr, "peripherals FAIL: %s\n", message);
    std::exit(1);
}

static void tick(Vriscc_peripherals_top *top)
{
    top->clk = 0;
    top->eval();
    top->clk = 1;
    top->eval();
}

static void write16(Vriscc_peripherals_top *top, unsigned addr, unsigned data)
{
    top->cpu_addr = addr;
    top->cpu_wdata = data;
    top->cpu_we = 1;
    tick(top);
    top->cpu_we = 0;
}

static unsigned read16(Vriscc_peripherals_top *top, unsigned addr)
{
    top->clk = 0;
    top->cpu_we = 0;
    top->cpu_addr = addr;
    top->eval();
    return top->cpu_rdata;
}

static unsigned read_ticks(Vriscc_peripherals_top *top)
{
    return read16(top, TIMER);
}

static void wait_for_tick(Vriscc_peripherals_top *top)
{
    const unsigned ticks_before = read_ticks(top);
    do
    {
        tick(top);
    } while (read_ticks(top) == ticks_before);
}

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    Vriscc_peripherals_top top;
    top.clk = 0;
    top.rst = 1;
    top.cpu_we = 0;
    top.cpu_addr = 0;
    top.cpu_wdata = 0;
    top.uart_irq = 0;
    tick(&top);
    tick(&top);
    top.rst = 0;
    tick(&top);

    const unsigned ticks_before = read_ticks(&top);
    tick(&top);
    tick(&top);
    if (read_ticks(&top) != ticks_before)
        fail("free-running tick counter advanced before its prescaler expired");
    tick(&top);
    if (read_ticks(&top) != ticks_before + 1)
        fail("free-running tick counter did not advance at its prescaler period");

    if (read16(&top, IRQ_STATE) != 0)
        fail("interrupt controller does not reset masked and idle");

    top.uart_irq = 1;
    if ((read16(&top, IRQ_STATE) & 1) == 0 || top.cpu_irq)
        fail("masked UART source was not reported without raising CPU IRQ");

    write16(&top, IRQ_STATE, 1);
    if (!top.cpu_irq)
        fail("enabled UART source did not raise CPU IRQ");
    top.uart_irq = 0;
    top.eval();
    if (top.cpu_irq)
        fail("level UART source did not clear CPU IRQ");

    write16(&top, IRQ_STATE, 2);
    write16(&top, TIMER, 3);
    if (top.timer_irq || top.cpu_irq)
        fail("timer did not arm with its pending state clear");
    wait_for_tick(&top);
    if (top.timer_irq)
        fail("timer asserted before its terminal count");
    wait_for_tick(&top);
    if (top.timer_irq)
        fail("timer asserted before its terminal count");
    wait_for_tick(&top);
    if (!top.timer_irq || !top.cpu_irq)
        fail("timer terminal count did not latch and raise CPU IRQ");

    write16(&top, TIMER, 2);
    if (top.timer_irq || top.cpu_irq)
        fail("timer rearm did not acknowledge the pending source");
    write16(&top, TIMER, 0);
    if (top.timer_irq)
        fail("zero timer write did not disarm the timer");

    std::printf("peripherals PASS\n");
    return 0;
}

/* Firmware for cpu_memory_tb.v; LEDs report completion to the testbench. */
#include "cached_access_checks.h"

static void fail(void)
{
    LED = 14;
    for (;;) {}
}

int main(void)
{
    test_cached_accesses();
    LED = 15;
    for (;;) {}
}

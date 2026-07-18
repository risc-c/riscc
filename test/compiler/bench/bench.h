#ifndef RISCC_COMPILER_BENCH_H
#define RISCC_COMPILER_BENCH_H

#include <stdint.h>

#define BENCH_NOINLINE __attribute__((noinline))
#define BENCH_RESULT (*(volatile uint16_t *)0xfffeu)

static __attribute__((noreturn)) void bench_finish(uint16_t actual,
    uint16_t expected)
{
    BENCH_RESULT = actual == expected ? UINT16_C(0x600d) : actual;
    for (;;)
        ;
}

static uint16_t bench_fold32(uint32_t value)
{
    return (uint16_t)(value ^ (value >> 16));
}

#endif

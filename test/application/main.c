#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#ifdef __RISCC_SYS__
#include <riscc/interrupt.h>
#endif

extern uint32_t application_helper(uint32_t, uint32_t);
extern uint32_t application_cpp_helper(uint32_t, uint32_t);

#ifndef __RISCC_NANO__
static _Thread_local uint32_t tls_initialized = UINT32_C(0x13579bdf);
static _Thread_local uint32_t tls_zero;
#endif
static uint32_t zero_data[8];
static volatile uint64_t wide_input = UINT64_C(0x123456789abcdef0);
static volatile int64_t signed_input = -INT64_C(0x123456789abcdef);
static volatile float float_left = 81.0f;
static volatile float float_right = 17.0f;
static volatile double double_left = 144.0;
static volatile double double_right = 29.0;

#ifdef __RISCC_SYS__
static volatile uint32_t irq_count;
static volatile uint32_t irq_mix;

static __attribute__((noinline)) void application_irq_handler(void)
{
    volatile uint16_t *const irq_cause =
        (volatile uint16_t *)(uintptr_t)UINT32_C(0xfffa);
    uint32_t cause = *irq_cause;
    uint32_t left = UINT32_C(0x12345678) + cause;
    uint32_t right = UINT32_C(0x0f0f0f0f) ^ cause;

    irq_mix = (left ^ right) + UINT32_C(0x10203040);
    ++irq_count;
}
#endif

static void fail(uint16_t code)
{
    *(volatile uint16_t *)(uintptr_t)UINT32_C(0xfffe) = code;
    for (;;)
        __asm__ volatile("" ::: "memory");
}

int main(void)
{
    static const uint32_t source[] = {
        UINT32_C(0x01020304), UINT32_C(0x89abcdef),
        UINT32_C(0x55aa55aa), UINT32_C(0xfedcba98)};
    uint32_t *copy = malloc(sizeof(source));
    uint64_t wide = wide_input;
    int64_t signed_wide = signed_input;

    if (!copy)
        fail(1);
#ifndef __RISCC_NANO__
    if (tls_initialized != UINT32_C(0x13579bdf) || tls_zero)
        fail(1);
#endif
    for (unsigned i = 0; i != 8; ++i)
        if (zero_data[i])
            fail(2);

    memcpy(copy, source, sizeof(source));
    if (memcmp(copy, source, sizeof(source)))
        fail(3);
    if (application_helper(copy[1], copy[2]) != UINT32_C(0x4eb5ed83))
        fail(4);
    if (application_cpp_helper(copy[0], copy[1]) != UINT32_C(0x78a6be68))
        fail(15);

    if ((wide >> 36) != UINT64_C(0x1234567))
        fail(5);
    if ((wide / UINT64_C(0x12345)) != UINT64_C(0x100005b00205))
        fail(6);
    if ((wide % UINT64_C(0x12345)) != UINT64_C(0xa497))
        fail(7);
    if (wide * UINT64_C(0x101) != UINT64_C(0x468acf13579bcef0))
        fail(8);
    if (signed_wide / INT64_C(0x12345) != -INT64_C(1099517591584) ||
        signed_wide % INT64_C(0x12345) != -INT64_C(25935) ||
        (signed_wide >> 17) != -INT64_C(625499948246))
        fail(9);
    if (sqrtf(float_left) != 9.0f)
        fail(10);
    if (fmodf(float_right, 5.0f) != 2.0f)
        fail(11);
    if (sqrt(double_left) != 12.0)
        fail(12);
    if (fmod(double_right, 6.0) != 5.0)
        fail(13);

#ifdef __RISCC_SYS__
    riscc_irq_set_handler(application_irq_handler);
    *(volatile uint16_t *)(uintptr_t)UINT32_C(0xfffa) = 1;
    riscc_irq_enable();
    while (!irq_count)
        __asm__ volatile("" ::: "memory");
    riscc_irq_disable();
    if (irq_count != 1 || irq_mix != UINT32_C(0x2d5b89b7))
        fail(14);
#endif

    free(copy);
    *(volatile uint16_t *)(uintptr_t)UINT32_C(0xfffe) = UINT16_C(0x600d);
    return 0;
}

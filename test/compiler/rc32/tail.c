#include "test.h"

static __attribute__((noinline)) u32 tail_leaf(u32 value)
{
    return value + 7;
}

static __attribute__((noinline)) u32 tail_direct(u32 value)
{
    [[clang::musttail]] return tail_leaf(value);
}

static __attribute__((noinline)) u32 tail_after_call(u32 value)
{
    value = tail_leaf(value);
    [[clang::musttail]] return tail_leaf(value);
}

static __attribute__((noinline)) u32 tail_with_large_frame(u32 value)
{
    volatile u32 frame[100];

    frame[99] = value;
    [[clang::musttail]] return tail_leaf(frame[99]);
}

static __attribute__((noinline)) u32 tail_after_callee_saved_clobber(u32 value)
{
    __asm__ volatile("" ::: "r4");
    [[clang::musttail]] return tail_leaf(value);
}

u16 rc32_test_tail(void)
{
    if (tail_direct(10) != 17)
        return 1;
    if (tail_after_call(20) != 34)
        return 2;
    if (tail_with_large_frame(30) != 37)
        return 3;
    if (tail_after_callee_saved_clobber(40) != 47)
        return 4;
    return 0;
}

#include "riscc_compiler_features.h"

typedef u16 (*tail_unary_fn)(u16);

static __attribute__((noinline)) u16 tail_leaf(u16 value)
{
    return (u16)(value + 7);
}

static tail_unary_fn volatile tail_target = tail_leaf;

static __attribute__((noinline)) u16 tail_direct(u16 value)
{
    [[clang::musttail]] return tail_leaf(value);
}

static __attribute__((noinline)) u16 call_indirect(u16 value)
{
    return tail_target(value);
}

static __attribute__((noinline)) u16 tail_after_call(u16 value)
{
    value = tail_leaf(value);
    [[clang::musttail]] return tail_leaf(value);
}

static __attribute__((noinline)) u16 tail_with_large_frame(u16 value)
{
    volatile u16 frame[100];

    frame[99] = value;
    [[clang::musttail]] return tail_leaf(frame[99]);
}

u16 feature_test_tail(void)
{
    if (tail_direct(10) != 17)
        return 1;
    if (call_indirect(20) != 27)
        return 2;
    if (tail_after_call(30) != 44)
        return 3;
    if (tail_with_large_frame(40) != 47)
        return 4;
    return 0;
}

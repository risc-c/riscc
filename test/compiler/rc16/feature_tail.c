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

static __attribute__((noinline)) u16 nested_leaf(u16 value)
{
    return (u16)(value + 3);
}

static __attribute__((noinline)) u16 nested_middle(u16 value)
{
    u16 first = nested_leaf(value);
    u16 second = nested_leaf(first);
    return (u16)(second + 5);
}

static __attribute__((noinline)) u16 nested_outer(u16 value)
{
    u16 first = nested_middle(value);
    u16 second = nested_middle(first);
    return (u16)(second + 7);
}

__attribute__((noinline)) u16 feature_tail_public_step(u16 value)
{
    return (u16)(value + 11);
}

static __attribute__((noinline)) u16 public_to_private_target(u16 value)
{
    return (u16)(value + 13);
}

__attribute__((noinline)) u16 feature_tail_public_to_private(u16 value)
{
    value = feature_tail_public_step(value);
    [[clang::musttail]] return public_to_private_target(value);
}

__attribute__((noinline)) u16 feature_tail_public_target(u16 value)
{
    return (u16)(value + 17);
}

static __attribute__((noinline)) u16 private_to_public_step(u16 value)
{
    return (u16)(value + 19);
}

static __attribute__((noinline)) u16 private_to_public(u16 value)
{
    value = private_to_public_step(value);
    [[clang::musttail]] return feature_tail_public_target(value);
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
    if (feature_tail_public_to_private(20) != 44)
        return 5;
    if (private_to_public(30) != 66)
        return 6;
    if (nested_outer(10) != 39)
        return 7;
    return 0;
}

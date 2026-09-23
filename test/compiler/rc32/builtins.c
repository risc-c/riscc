#include "test.h"

u32 __mulsi3(u32, u32);
s32 __ashlsi3(s32, int);
u32 __lshrsi3(u32, int);
s32 __ashrsi3(s32, int);
u32 __riscc_shlsi_fast(u32, unsigned);
u32 __riscc_lshrsi_fast(u32, unsigned);
s32 __riscc_ashrsi_fast(s32, unsigned);
u32 __udivsi3(u32, u32);
u32 __umodsi3(u32, u32);
u32 __udivmodsi4(u32, u32, u32 *);
s32 __divsi3(s32, s32);
s32 __modsi3(s32, s32);
s32 __divmodsi4(s32, s32, s32 *);

s64 __muldi3(s64, s64);
s64 __ashldi3(s64, int);
u64 __lshrdi3(u64, int);
s64 __ashrdi3(s64, int);
u64 __udivdi3(u64, u64);
u64 __umoddi3(u64, u64);
u64 __udivmoddi4(u64, u64, u64 *);
s64 __divdi3(s64, s64);
s64 __moddi3(s64, s64);
s64 __divmoddi4(s64, s64, s64 *);
s64 __negdi2(s64);
int __ucmpdi2(u64, u64);
int __cmpdi2(s64, s64);
int __clzsi2(u32);
int __ctzsi2(u32);
int __clzdi2(s64);
int __ctzdi2(s64);

static volatile u32 value32 = 0x12345678u;
static volatile s32 signed32 = -100000;
static volatile u64 value64 = 0x123456789abcdef0ull;
static volatile s64 signed64 = -100000ll;
static volatile u32 shift32 = 0x80010001u;
static volatile u64 shift64 = 0x8001000200040001ull;
static volatile u32 native_mul_input = 0x10203040u;
static volatile u32 native_divisor32 = 12345u;
static volatile s32 native_signed_divisor32 = 300;
static volatile u32 native_select_true = 1;
static volatile u32 native_select_false = 0;
static volatile u32 native_select_value = 0x76543210u;
static volatile u32 native_rotate_input = 0x12345678u;
static volatile u32 native_pair_high = 0x81234567u;
static volatile u32 native_pair_low = 0x89abcdefu;

static __attribute__((noinline)) int check_multiply_overflow(
    u32 a, u32 b, u32 expected, int overflow)
{
    u32 product;
    int actual = __builtin_mul_overflow(a, b, &product);
    return actual == overflow && product == expected;
}

static int check_bit_counts(void)
{
    u64 bit = 1;
    for (unsigned i = 0; i != 64; ++i, bit += bit)
    {
        // One set bit, a run of low bits, and both ends set exercise every
        // count and both halves of the wide helpers without a reference loop.
        u64 low_bits = bit - 1;
        if (__clzdi2((s64)bit) != (int)(63 - i) ||
            __ctzdi2((s64)bit) != (int)i ||
            __clzdi2((s64)low_bits) != (int)(64 - i) ||
            __ctzdi2((s64)low_bits) != (i ? 0 : 64) ||
            __clzdi2((s64)(bit | 1)) != (int)(63 - i) ||
            __ctzdi2((s64)(bit | 1)) != 0 ||
            __clzdi2((s64)(bit | 0x8000000000000000ull)) != 0 ||
            __ctzdi2((s64)(bit | 0x8000000000000000ull)) != (int)i)
            return 0;
        if (i < 32 &&
            (__clzsi2((u32)bit) != (int)(31 - i) ||
             __ctzsi2((u32)bit) != (int)i ||
             __clzsi2((u32)low_bits) != (int)(32 - i) ||
             __ctzsi2((u32)low_bits) != (i ? 0 : 32) ||
             __clzsi2((u32)bit | 1u) != (int)(31 - i) ||
             __ctzsi2((u32)bit | 1u) != 0 ||
             __clzsi2((u32)bit | 0x80000000u) != 0 ||
             __ctzsi2((u32)bit | 0x80000000u) != (int)i))
            return 0;
    }
    return 1;
}

static int check_wide_negation(void)
{
    static const struct { u64 value, negative; } cases[] = {
        {0, 0},
        {1, 0xffffffffffffffffull},
        {0xffffffffull, 0xffffffff00000001ull},
        {0x100000000ull, 0xffffffff00000000ull},
        {0x100000001ull, 0xfffffffeffffffffull},
        {0x7fffffffffffffffull, 0x8000000000000001ull},
        {0x8000000000000000ull, 0x8000000000000000ull},
        {0xffffffffffffffffull, 1},
    };
    for (unsigned i = 0; i != sizeof(cases) / sizeof(cases[0]); ++i)
        if ((u64)__negdi2((s64)cases[i].value) != cases[i].negative)
            return 0;
    return 1;
}

/* Every computed entry, including the direct return for count zero. */
static __attribute__((noinline)) int check_variable_shifts(u32 value)
{
    u32 left = value, right = value;
    s32 arithmetic = (s32)value;

    for (unsigned count = 0; count != 32; ++count)
    {
        if (__riscc_shlsi_fast(value, count) != left ||
            __riscc_lshrsi_fast(value, count) != right ||
            __riscc_ashrsi_fast((s32)value, count) != arithmetic ||
            (value << count) != left || (value >> count) != right ||
            ((s32)value >> count) != arithmetic)
            return 0;
        left += left;
        right >>= 1;
        arithmetic >>= 1;
    }
    return 1;
}

struct native_rotate_case
{
    u32 count;
    u32 left;
    u32 right;
};

static const struct native_rotate_case native_rotate_cases[] =
{
    {0, 0x12345678u, 0x12345678u},
    {1, 0x2468acf0u, 0x091a2b3cu},
    {31, 0x091a2b3cu, 0x2468acf0u},
    {32, 0x12345678u, 0x12345678u},
    {33, 0x2468acf0u, 0x091a2b3cu},
};

static __attribute__((noinline)) u32 native_rotate_left(u32 value, u32 count)
{
    return __builtin_rotateleft32(value, count);
}

static __attribute__((noinline)) u32 native_rotate_right(u32 value, u32 count)
{
    return __builtin_rotateright32(value, count);
}

static __attribute__((noinline)) u32 native_mul_by_3(u32 value)
{
    return value * 3u;
}

static __attribute__((noinline)) u32 native_mul_by_5(u32 value)
{
    return value * 5u;
}

static __attribute__((noinline)) u32 native_mul_by_minus_3(u32 value)
{
    return value * (u32)-3;
}

static __attribute__((noinline)) u32 native_select_or_zero(_Bool condition,
    u32 value)
{
    return condition ? value : 0;
}

u16 rc32_test_builtins(void)
{
    u32 remainder32;
    s32 signed_remainder32;
    u64 remainder64;
    s64 signed_remainder64;
    u32 u32_value = value32;
    s32 s32_value = signed32;
    u64 u64_value = value64;
    s64 s64_value = signed64;
    u32 u32_shift = shift32;
    u64 u64_shift = shift64;

    u32 divisor32 = native_divisor32;
    u32 paired_quotient32 = u32_value / divisor32;
    u32 paired_remainder32 = u32_value % divisor32;
    if (paired_quotient32 != 0x60a4u || paired_remainder32 != 0x11f4u)
        return 9;

    u32 reconstructed_quotient32 = u32_value / divisor32;
    u32 reconstructed_remainder32 =
        u32_value - reconstructed_quotient32 * divisor32;
    if (reconstructed_quotient32 != 0x60a4u ||
        reconstructed_remainder32 != 0x11f4u)
        return 10;

    s32 signed_divisor32 = native_signed_divisor32;
    s32 paired_signed_quotient32 = s32_value / signed_divisor32;
    s32 paired_signed_remainder32 = s32_value % signed_divisor32;
    if (paired_signed_quotient32 != -333 || paired_signed_remainder32 != -100)
        return 11;

    u32 rotate_value = native_rotate_input;
    u32 rotate_index;
    const struct native_rotate_case *rotate_case;
    for (rotate_index = 0;
        rotate_index != sizeof(native_rotate_cases) /
            sizeof(native_rotate_cases[0]); ++rotate_index)
    {
        rotate_case = &native_rotate_cases[rotate_index];
        if (native_rotate_left(rotate_value, rotate_case->count) !=
                rotate_case->left ||
            native_rotate_right(rotate_value, rotate_case->count) !=
                rotate_case->right)
            return 12;
    }

    u32 pair_high = native_pair_high;
    u32 pair_low = native_pair_low;
    if (((pair_high << 1) | (pair_low >> 31)) != 0x02468acfu ||
        ((pair_low >> 1) | (pair_high << 31)) != 0xc4d5e6f7u)
        return 13;

    u32 multiply_input = native_mul_input;
    if (native_mul_by_3(multiply_input) != 0x306090c0u ||
        native_mul_by_5(multiply_input) != 0x50a0f140u ||
        native_mul_by_minus_3(multiply_input) != 0xcf9f6f40u ||
        native_mul_by_5(0xffffffffu) != 0xfffffffbu ||
        native_mul_by_minus_3(0xffffffffu) != 3u)
        return 14;

    u32 select_value = native_select_value;
    if (native_select_or_zero(native_select_true, select_value) != select_value)
        return 15;
    if (native_select_or_zero(native_select_false, select_value) != 0)
        return 15;

    // Overflow legalization must pass two whole wide operands to __muldi3.
    if (!check_multiply_overflow(4u, 1u, 4u, 0) ||
        !check_multiply_overflow(0xffffffffu, 0u, 0u, 0) ||
        !check_multiply_overflow(0xffffffffu, 1u, 0xffffffffu, 0) ||
        !check_multiply_overflow(65535u, 65535u, 0xfffe0001u, 0) ||
        !check_multiply_overflow(65536u, 65536u, 0u, 1) ||
        !check_multiply_overflow(0xffffffffu, 2u, 0xfffffffeu, 1) ||
        !check_multiply_overflow(0xffffffffu, 0xffffffffu, 1u, 1))
        return 16;

    if (__mulsi3(u32_value, 0) != 0 ||
        __mulsi3(u32_value, 1) != u32_value ||
        __mulsi3(3, 0x80000000u) != 0x80000000u ||
        __mulsi3(u32_value, 37) != 0xa1907f58u ||
        __mulsi3(0xffffffffu, 0xffffffffu) != 1 ||
        __mulsi3(0x00010001u, 0x00010001u) != 0x00020001u ||
        __mulsi3(0x89abcdefu, 0x76543210u) != 0xe5618cf0u ||
        __mulsi3(0xffff0001u, 0x0001ffffu) != 0x0002ffffu)
        return 1;

    if ((u32)__ashlsi3((s32)u32_shift, 0) != 0x80010001u ||
        (u32)__ashlsi3((s32)u32_shift, 1) != 0x00020002u ||
        (u32)__ashlsi3((s32)u32_shift, 16) != 0x00010000u ||
        (u32)__ashlsi3((s32)u32_shift, 31) != 0x80000000u ||
        __lshrsi3(u32_shift, 1) != 0x40008000u ||
        __lshrsi3(u32_shift, 16) != 0x00008001u ||
        __lshrsi3(u32_shift, 31) != 1 ||
        (u32)__ashrsi3((s32)u32_shift, 1) != 0xc0008000u ||
        (u32)__ashrsi3((s32)u32_shift, 16) != 0xffff8001u ||
        (u32)__ashrsi3((s32)u32_shift, 31) != 0xffffffffu)
        return 2;
    if (!check_variable_shifts(0) || !check_variable_shifts(0xffffffffu) ||
        !check_variable_shifts(1) || !check_variable_shifts(0x80000000u) ||
        !check_variable_shifts(0x7fffffffu) || !check_variable_shifts(u32_shift))
        return 2;

    if (__udivsi3(u32_value, 12345) != 0x60a4u ||
        __umodsi3(u32_value, 12345) != 0x11f4u ||
        __udivsi3(0xffffffffu, 0x80000001u) != 1 ||
        __umodsi3(0xffffffffu, 0x80000001u) != 0x7ffffffeu ||
        __udivsi3(0x80000000u, 0xffffffffu) != 0 ||
        __umodsi3(0x80000000u, 0xffffffffu) != 0x80000000u ||
        __udivsi3(0xffffffffu, 1) != 0xffffffffu ||
        __umodsi3(0xffffffffu, 1) != 0 ||
        __udivsi3(u32_value, 0) != 0 ||
        __umodsi3(u32_value, 0) != u32_value ||
        __udivmodsi4(u32_value, 12345, &remainder32) != 0x60a4u ||
        remainder32 != 0x11f4u ||
        __udivmodsi4(u32_value, 12345, (u32 *)0) != 0x60a4u)
        return 3;

    if (__divsi3(s32_value, 300) != -333 ||
        __modsi3(s32_value, 300) != -100 ||
        __divmodsi4(s32_value, 300, &signed_remainder32) != -333 ||
        signed_remainder32 != -100 ||
        __divsi3(100000, -300) != -333 ||
        __modsi3(100000, -300) != 100 ||
        __divsi3(-100000, -300) != 333 ||
        __modsi3(-100000, -300) != -100 ||
        __divsi3(-5, 300) != 0 || __modsi3(-5, 300) != -5 ||
        __divsi3(s32_value, 0) != 0 ||
        __modsi3(s32_value, 0) != s32_value ||
        __divmodsi4(s32_value, 300, (s32 *)0) != -333)
        return 4;

    if ((u64)__muldi3((s64)u64_value, 3) != 0x369d0369d0369cd0ull ||
        (u64)__ashldi3((s64)u64_shift, 0) != 0x8001000200040001ull ||
        (u64)__ashldi3((s64)u64_shift, 1) != 0x0002000400080002ull ||
        (u64)__ashldi3((s64)u64_shift, 16) != 0x0002000400010000ull ||
        (u64)__ashldi3((s64)u64_shift, 63) != 0x8000000000000000ull ||
        __lshrdi3(u64_shift, 1) != 0x4000800100020000ull ||
        __lshrdi3(u64_shift, 16) != 0x0000800100020004ull ||
        __lshrdi3(u64_shift, 63) != 1 ||
        (u64)__ashrdi3((s64)u64_shift, 1) != 0xc000800100020000ull ||
        (u64)__ashrdi3((s64)u64_shift, 16) != 0xffff800100020004ull ||
        (u64)__ashrdi3((s64)u64_shift, 63) != 0xffffffffffffffffull)
        return 5;

    if (__udivdi3(u64_value, 65537) != 0x0000123444445678ull ||
        __umoddi3(u64_value, 65537) != 0x8878ull ||
        __udivdi3(0xffffffffffffffffull, 0x8000000000000001ull) != 1 ||
        __umoddi3(0xffffffffffffffffull, 0x8000000000000001ull) !=
            0x7ffffffffffffffeull ||
        __udivdi3(0x8000000000000000ull, 0xffffffffffffffffull) != 0 ||
        __umoddi3(0x8000000000000000ull, 0xffffffffffffffffull) !=
            0x8000000000000000ull ||
        __udivdi3(0xffffffffffffffffull, 1) != 0xffffffffffffffffull ||
        __umoddi3(0xffffffffffffffffull, 1) != 0 ||
        __udivdi3(u64_value, 0) != 0 ||
        __umoddi3(u64_value, 0) != u64_value ||
        __udivmoddi4(u64_value, 65537, &remainder64) !=
            0x0000123444445678ull ||
        remainder64 != 0x8878ull ||
        __udivmoddi4(u64_value, 65537, (u64 *)0) !=
            0x0000123444445678ull)
        return 6;

    if (__divdi3(s64_value, 300) != -333ll ||
        __moddi3(s64_value, 300) != -100ll ||
        __divmoddi4(s64_value, 300, &signed_remainder64) != -333ll ||
        signed_remainder64 != -100ll ||
        __divdi3(100000ll, -300) != -333ll ||
        __moddi3(100000ll, -300) != 100ll ||
        __divdi3(-100000ll, -300) != 333ll ||
        __moddi3(-100000ll, -300) != -100ll ||
        __negdi2(s64_value) != 100000ll)
        return 7;

    if (__ucmpdi2(1, 2) != 0 || __ucmpdi2(2, 2) != 1 ||
        __ucmpdi2(3, 2) != 2 || __cmpdi2(-2, 1) != 0 ||
        __cmpdi2(-2, -2) != 1 || __cmpdi2(1, -2) != 2 ||
        __clzsi2(0) != 32 || __clzsi2(1) != 31 ||
        __clzsi2(0x80000000u) != 0 || __ctzsi2(0) != 32 ||
        __ctzsi2(0x80000000u) != 31 || __clzdi2(1) != 63 ||
        __clzdi2((s64)0x8000000000000000ull) != 0 ||
        __ctzdi2(0) != 64 || __ctzdi2((s64)0x8000000000000000ull) != 63)
        return 8;

    if (!check_bit_counts())
        return 9;
    if (!check_wide_negation())
        return 10;

    return 0;
}

#include "riscc_compiler_features.h"
#include "../comparison_ranges.h"

static volatile u16 integer_u16_a = 0xf123u;
static volatile u16 integer_u16_b = 0x1357u;
static volatile u16 integer_u16_multiplier = 3;
static volatile u16 integer_u16_divisor = 37;
static volatile u32 integer_u32 = 0x12345678ul;
static volatile u32 integer_u32_multiplier = 37ul;
static volatile u32 integer_u32_divisor = 12345ul;
static volatile u32 integer_u32_compare = 0x11111111ul;
static volatile u64 integer_u64 = 0x123456789abcdef0ull;
static volatile u64 integer_u64_multiplier = 3ull;
static volatile u64 integer_u64_divisor = 65537ull;
static volatile u64 integer_u64_compare = 0x1000000000000000ull;
static volatile s16 integer_s16_divisor = 37;
static volatile s32 integer_s32_divisor = 300l;
static volatile s64 integer_s64_divisor = 300ll;
static volatile u16 integer_shift = 4;
static volatile u16 integer_shift_inputs[] = {
    0x0000u, 0xffffu, 0x0001u, 0x8000u, 0x7fffu, 0x8101u,
};
static volatile u16 integer_byte_bits[] = {0xab7fu, 0xab80u, 0xffffu, 0xab00u};
static volatile u16 integer_merge_zero;
static volatile u16 integer_merge_ones = 0xffffu;
static volatile u16 integer_merge_a = 0x1234u;
static volatile u16 integer_merge_b = 0x9abcu;

static __attribute__((noinline)) s16 sign_extend_byte(u16 value)
{
    return (s8)value;
}

static __attribute__((noinline)) u16 multiply_by_3(u16 value)
{
    return (u16)(value * 3u);
}

static __attribute__((noinline)) u16 multiply_by_10(u16 value)
{
    return (u16)(value * 10u);
}

static __attribute__((noinline)) u16 select_or_zero(u16 condition, u16 value)
{
    return condition ? value : 0;
}

static __attribute__((noinline)) u16 shifted_byte(const u16 *p)
{
    return (u16)((*p << 3) & 0x7f8u);
}

static __attribute__((noinline)) u16 equality_mask(u16 a, u16 b)
{
    return (u16)(0u - (a == b));
}

static __attribute__((noinline)) u16 high_bit(u16 value)
{
    return value >> 15;
}

static __attribute__((noinline)) u16 fits_byte(u16 value)
{
    return (u8)value == value;
}

static __attribute__((noinline)) u16 masked_merge_byte_low(u16 a, u16 b)
{
    return (u16)((a & 0x00ffu) | (b & 0xff00u));
}

static __attribute__((noinline)) u16 masked_merge_byte_high(u16 a, u16 b)
{
    return (u16)((a & 0xff00u) | (b & 0x00ffu));
}

static __attribute__((noinline)) u16 masked_merge_sign_low(u16 a, u16 b)
{
    return (u16)((a & 0x7fffu) | (b & 0x8000u));
}

static __attribute__((noinline)) u16 masked_merge_sign_high(u16 a, u16 b)
{
    return (u16)((a & 0x8000u) | (b & 0x7fffu));
}

u16 __riscc_shlhi_fast(u16, u16);
u16 __riscc_lshrhi_fast(u16, u16);
s16 __riscc_ashrhi_fast(s16, u16);

static __attribute__((noinline)) u16 repeated_left_shift(u16 value, u16 count)
{
    volatile u16 result = value;
    for (u16 i = 0; i < count; ++i)
        result = (u16)(result + result);
    return result;
}

static __attribute__((noinline)) u16 repeated_right_shift(u16 value, u16 count)
{
    volatile u16 result = value;
    for (u16 i = 0; i < count; ++i)
        result = (u16)(result >> 1);
    return result;
}

static __attribute__((noinline)) s16 repeated_arithmetic_shift(u16 value,
                                                              u16 count)
{
    volatile s16 result = (s16)value;
    for (u16 i = 0; i < count; ++i)
        result = (s16)(result >> 1);
    return result;
}

static __attribute__((noinline)) u16 check_variable_shifts(u16 value)
{
    for (u16 count = 0; count < 16u; ++count) {
        u16 expected_left = repeated_left_shift(value, count);
        u16 expected_right = repeated_right_shift(value, count);
        u16 expected_arithmetic =
            (u16)repeated_arithmetic_shift(value, count);
        if (__riscc_shlhi_fast(value, count) != expected_left ||
            (u16)(value << count) != expected_left ||
            __riscc_lshrhi_fast(value, count) != expected_right ||
            (u16)(value >> count) != expected_right ||
            (u16)__riscc_ashrhi_fast((s16)value, count) !=
                expected_arithmetic ||
            (u16)((s16)value >> count) != expected_arithmetic)
            return 0;
    }
    return 1;
}

u16 feature_test_integer(void)
{
    if (test_comparison_ranges())
        return 30;
    u16 a = integer_u16_a;
    u16 b = integer_u16_b;
    u16 shift = integer_shift;
    u32 value32 = integer_u32;
    u64 value64 = integer_u64;
    s32 signed32;
    s64 signed64;

    if ((u16)(a + b) != 0x047au || (u16)(a - b) != 0xddccu)
        return 1;
    if ((u16)(0x1234u * integer_u16_multiplier) != 0x369cu)
        return 2;
    if ((u16)(0x55aau & 0x0ff0u) != 0x05a0u ||
        (u16)(0x55aau | 0x0ff0u) != 0x5ffau ||
        (u16)(0x55aau ^ 0x0ff0u) != 0x5a5au)
        return 3;
    if ((u16)(0x8123u << shift) != 0x1230u ||
        (u16)(0x8123u >> shift) != 0x0812u)
        return 4;
    if ((s16)((s16)-256 >> 3) != -32)
        return 5;
    if ((u16)(1000u / integer_u16_divisor) != 27u ||
        (u16)(1000u % integer_u16_divisor) != 1u ||
        (s16)((s16)-1000 / integer_s16_divisor) != -27 ||
        (s16)((s16)-1000 % integer_s16_divisor) != -1)
        return 6;

    if (value32 + 0x11112222ul != 0x2345789aul)
        return 7;
    if (value32 * integer_u32_multiplier != 0xa1907f58ul ||
        value32 / integer_u32_divisor != 0x000060a4ul ||
        value32 % integer_u32_divisor != 0x000011f4ul)
        return 8;
    if ((value32 << shift) != 0x23456780ul ||
        (value32 >> shift) != 0x01234567ul)
        return 9;
    signed32 = (s32)-100000l;
    if (signed32 / integer_s32_divisor != -333l ||
        signed32 % integer_s32_divisor != -100l ||
        -signed32 != 100000l)
        return 10;
    signed32 = (s32)0x87654321ul;
    if ((signed32 >> shift) != (s32)0xf8765432ul || signed32 >= 0 ||
        value32 <= integer_u32_compare)
        return 11;

    if (value64 + 0x1111111111111111ull != 0x23456789abcdf001ull)
        return 12;
    if (value64 * integer_u64_multiplier != 0x369d0369d0369cd0ull)
        return 13;
    if (value64 / integer_u64_divisor != 0x0000123444445678ull ||
        value64 % integer_u64_divisor != 0x8878ull)
        return 14;
    if ((0x0000000100000001ull << shift) != 0x0000001000000010ull ||
        (0x8000000000000001ull >> shift) != 0x0800000000000000ull)
        return 15;
    signed64 = -100000ll;
    if (signed64 / integer_s64_divisor != -333ll ||
        signed64 % integer_s64_divisor != -100ll ||
        -signed64 != 100000ll)
        return 16;
    signed64 = -0x100000000ll;
    if ((signed64 >> shift) != -0x10000000ll || signed64 >= 0 ||
        value64 <= integer_u64_compare)
        return 17;

    if ((u8)value32 != 0x78u || (u16)value32 != 0x5678u ||
        (u32)(s32)(s16)-2 != 0xfffffffeul)
        return 18;
    if (multiply_by_3(0x1234u) != 0x369cu ||
        multiply_by_10(0x1234u) != 0xb608u)
        return 19;
    if (select_or_zero(1, 0x5678u) != 0x5678u ||
        select_or_zero(0, 0x5678u) != 0)
        return 20;
    if (sign_extend_byte(integer_byte_bits[0]) != 127 ||
        sign_extend_byte(integer_byte_bits[1]) != -128 ||
        sign_extend_byte(integer_byte_bits[2]) != -1 ||
        sign_extend_byte(integer_byte_bits[3]) != 0)
        return 21;
    if (shifted_byte(&a) != 0x118u || shifted_byte(&b) != 0x2b8u)
        return 22;
    if (equality_mask(a, a) != 0xffffu || equality_mask(a, b) != 0 ||
        equality_mask(0, 0) != 0xffffu || equality_mask(0x8000u, 0) != 0)
        return 23;
    if (masked_merge_byte_low(integer_merge_zero, integer_merge_ones) !=
            0xff00u ||
        masked_merge_byte_high(integer_merge_zero, integer_merge_ones) !=
            0x00ffu ||
        masked_merge_byte_low(integer_merge_ones, integer_merge_zero) !=
            0x00ffu ||
        masked_merge_byte_high(integer_merge_ones, integer_merge_zero) !=
            0xff00u)
        return 24;
    if (masked_merge_byte_low(integer_merge_a, integer_merge_b) != 0x9a34u ||
        masked_merge_byte_high(integer_merge_a, integer_merge_b) != 0x12bcu ||
        masked_merge_byte_low(integer_merge_b, integer_merge_a) != 0x12bcu ||
        masked_merge_byte_high(integer_merge_b, integer_merge_a) != 0x9a34u)
        return 25;
    if (masked_merge_sign_low(integer_merge_zero, integer_merge_ones) !=
            0x8000u ||
        masked_merge_sign_high(integer_merge_zero, integer_merge_ones) !=
            0x7fffu ||
        masked_merge_sign_low(integer_merge_ones, integer_merge_zero) !=
            0x7fffu ||
        masked_merge_sign_high(integer_merge_ones, integer_merge_zero) !=
            0x8000u)
        return 26;
    if (masked_merge_sign_low(integer_merge_a, integer_merge_b) != 0x9234u ||
        masked_merge_sign_high(integer_merge_a, integer_merge_b) != 0x1abcu ||
        masked_merge_sign_low(integer_merge_b, integer_merge_a) != 0x1abcu ||
        masked_merge_sign_high(integer_merge_b, integer_merge_a) != 0x9234u)
        return 27;
    for (u16 i = 0; i < sizeof(integer_shift_inputs) /
                              sizeof(integer_shift_inputs[0]);
         ++i) {
        u16 value = integer_shift_inputs[i];
        if (!check_variable_shifts(value))
            return 28;
        if (high_bit(value) != repeated_right_shift(value, 15) ||
            fits_byte(value) != (value < 256u))
            return 29;
    }
    if (!fits_byte(255u) || fits_byte(256u))
        return 29;

    return 0;
}

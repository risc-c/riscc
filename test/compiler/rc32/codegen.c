#include "test.h"
#include "../comparison_ranges.h"

static __attribute__((noinline)) s32 signed_byte(signed char value)
{
    __asm__ volatile ("" : "+r" (value));
    return value;
}

static __attribute__((noinline)) s32 signed_half(short value)
{
    __asm__ volatile ("" : "+r" (value));
    return value;
}

/* PHIs must retain the extension facts of every incoming path. In particular,
 * an unsigned byte load is not already sign-extended for a signed-byte call. */
static __attribute__((noinline)) s32 byte_loop(unsigned char start)
{
    s32 sum = 0;
    signed char value = (signed char)start;
    for (unsigned i = 0; i != 32; ++i)
    {
        sum += signed_byte(value);
        value = (signed char)(value + 1);
    }
    return sum;
}

static __attribute__((noinline)) s32 unsigned_byte_loop(unsigned char start)
{
    s32 sum = 0;
    for (unsigned i = 0; i != 32; ++i)
        sum += signed_byte((signed char)(start + i));
    return sum;
}

static __attribute__((noinline)) s32 half_loop(short start)
{
    s32 sum = 0;
    for (unsigned i = 0; i != 32; ++i)
    {
        sum += signed_half(start);
        start = (short)(start + 1);
    }
    return sum;
}

static volatile u32 words[96];
static volatile u32 masked_merge_zero;
static volatile u32 masked_merge_ones = 0xffffffffu;
static volatile u32 masked_merge_a = 0x12345678u;
static volatile u32 masked_merge_b = 0x9abcdef0u;

static __attribute__((noinline)) void adjacent_words(unsigned i, u32 value)
{
    volatile u32 *p = words + 32;
    p[i - 1] = value;
    p[i] = value + 1;
    p[i + 1] = p[i - 1] ^ p[i];
    p[i + 33] = i;
}

/* Both frame setup and the distant word require large address constants. */
static __attribute__((noinline)) u32 large_frame(u32 value)
{
    volatile u32 frame[1024];
    frame[0] = value;
    frame[1023] = value + 7;
    __asm__ volatile ("" : : "r" (frame) : "memory");
    return frame[0] + frame[1023];
}

static __attribute__((noinline)) u32 medium_frame(u32 value)
{
    volatile u32 frame[50];
    frame[0] = value;
    frame[49] = value + 7;
    __asm__ volatile ("" : : "r" (frame) : "memory");
    return frame[0] + frame[49];
}

static __attribute__((noinline)) u32 shifted_byte(const u32 *p)
{
    return (*p << 3) & 0x7f8u;
}

static __attribute__((noinline)) u32 shifted_half(const u32 *p)
{
    return (*p << 3) & 0x7fff8u;
}

static __attribute__((noinline)) u32 equality_mask(u32 a, u32 b)
{
    return 0u - (a == b);
}

static __attribute__((noinline)) u32 high_bit(u32 value)
{
    return value >> 31;
}

static __attribute__((noinline)) u32 half_high_bit(u16 value)
{
    return (u32)value >> 15;
}

static __attribute__((noinline)) u32 fits_half(u32 value)
{
    return (u16)value == value;
}

static volatile u32 narrow_edges[] = {
    0, 1, 0x7fffu, 0x8000u, 0xffffu, 0x10000u,
    0x7fffffffu, 0x80000000u, 0xffffffffu
};

static __attribute__((noinline)) u32 masked_merge_byte_low(u32 a, u32 b)
{
    return (a & 0x000000ffu) | (b & 0xffffff00u);
}

static __attribute__((noinline)) u32 masked_merge_byte_high(u32 a, u32 b)
{
    return (a & 0xffffff00u) | (b & 0x000000ffu);
}

static __attribute__((noinline)) u32 masked_merge_sign_low(u32 a, u32 b)
{
    return (a & 0x7fffffffu) | (b & 0x80000000u);
}

static __attribute__((noinline)) u32 masked_merge_sign_high(u32 a, u32 b)
{
    return (a & 0x80000000u) | (b & 0x7fffffffu);
}

u16 rc32_test_codegen(void)
{
    if (test_comparison_ranges())
        return 14;
    if (byte_loop(120) != -1808 || unsigned_byte_loop(120) != -1808)
        return 1;
    if (half_loop(32760) != -524048)
        return 2;
    adjacent_words(3, 0x12345678u);
    if (words[34] != 0x12345678u || words[35] != 0x12345679u ||
        words[36] != 1 || words[68] != 3 || words[33] || words[37])
        return 3;
    if (large_frame(0x12345678u) != 0x2468acf7u)
        return 4;
    if (medium_frame(0x12345678u) != 0x2468acf7u)
        return 5;
    u32 value = words[34];
    if (shifted_byte(&value) != 0x3c0u || shifted_half(&value) != 0x2b3c0u)
        return 6;
    value = ~value;
    if (shifted_byte(&value) != 0x438u || shifted_half(&value) != 0x54c38u)
        return 7;
    if (equality_mask(value, value) != 0xffffffffu ||
        equality_mask(value, 0) != 0 || equality_mask(0, 0) != 0xffffffffu ||
        equality_mask(0x80000000u, 0) != 0)
        return 8;
    if (masked_merge_byte_low(masked_merge_zero, masked_merge_ones) !=
            0xffffff00u ||
        masked_merge_byte_high(masked_merge_zero, masked_merge_ones) !=
            0x000000ffu ||
        masked_merge_byte_low(masked_merge_ones, masked_merge_zero) !=
            0x000000ffu ||
        masked_merge_byte_high(masked_merge_ones, masked_merge_zero) !=
            0xffffff00u)
        return 9;
    if (masked_merge_byte_low(masked_merge_a, masked_merge_b) != 0x9abcde78u ||
        masked_merge_byte_high(masked_merge_a, masked_merge_b) != 0x123456f0u ||
        masked_merge_byte_low(masked_merge_b, masked_merge_a) != 0x123456f0u ||
        masked_merge_byte_high(masked_merge_b, masked_merge_a) != 0x9abcde78u)
        return 10;
    if (masked_merge_sign_low(masked_merge_zero, masked_merge_ones) !=
            0x80000000u ||
        masked_merge_sign_high(masked_merge_zero, masked_merge_ones) !=
            0x7fffffffu ||
        masked_merge_sign_low(masked_merge_ones, masked_merge_zero) !=
            0x7fffffffu ||
        masked_merge_sign_high(masked_merge_ones, masked_merge_zero) !=
            0x80000000u)
        return 11;
    if (masked_merge_sign_low(masked_merge_a, masked_merge_b) != 0x92345678u ||
        masked_merge_sign_high(masked_merge_a, masked_merge_b) != 0x1abcdef0u ||
        masked_merge_sign_low(masked_merge_b, masked_merge_a) != 0x1abcdef0u ||
        masked_merge_sign_high(masked_merge_b, masked_merge_a) != 0x92345678u)
        return 12;
    for (unsigned i = 0; i < sizeof(narrow_edges) / sizeof(narrow_edges[0]); ++i)
    {
        u32 bits = narrow_edges[i];
        if (high_bit(bits) != ((s32)bits < 0) ||
            half_high_bit((u16)bits) != ((short)bits < 0) ||
            fits_half(bits) != (bits < 0x10000u))
            return 13;
    }
    return 0;
}

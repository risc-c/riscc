#include "riscc_compiler_features.h"

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

u16 feature_test_integer(void)
{
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

    return 0;
}

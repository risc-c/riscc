#include "bench.h"

static volatile uint32_t seeds[8] =
{
    UINT32_C(0x243f6a88), UINT32_C(0x85a308d3),
    UINT32_C(0x13198a2e), UINT32_C(0x03707344),
    UINT32_C(0xa4093822), UINT32_C(0x299f31d0),
    UINT32_C(0x082efa98), UINT32_C(0xec4e6c89),
};

BENCH_NOINLINE static uint16_t arithmetic32(void)
{
    uint32_t a = seeds[0];
    uint32_t b = seeds[1];
    uint32_t c = seeds[2];
    uint32_t d = seeds[3];
    uint32_t e = seeds[4];
    uint32_t f = seeds[5];
    uint32_t g = seeds[6];
    uint32_t h = seeds[7];
    uint16_t round;

    for (round = 0; round != 48; ++round)
    {
        a += (b ^ (h >> 3)) + round;
        b ^= (c + (a << 1));
        c += (d ^ (b >> 5));
        d ^= (e + (c << 2));
        e += (f ^ (d >> 7));
        f ^= (g + (e << 3));
        g += (h ^ (f >> 11));
        h ^= (a + (g << 1));
    }

    return (uint16_t)(bench_fold32(a ^ e) +
        bench_fold32(b ^ f) + bench_fold32(c ^ g) +
        bench_fold32(d ^ h));
}

BENCH_NOINLINE static uint16_t multiply_shift32(void)
{
    uint32_t value = seeds[0];
    uint32_t multiplier = seeds[5] | 1;
    uint32_t hash = seeds[2];
    uint16_t round;

    for (round = 1; round != 25; ++round)
    {
        uint16_t shift = (uint16_t)((round % 31) + 1);
        int32_t signed_value;

        value = value * multiplier + seeds[round & 7];
        value = (value << shift) | (value >> (32 - shift));
        signed_value = (int32_t)(value ^ seeds[(round + 3) & 7]);
        hash += (uint32_t)(signed_value >> (shift & 15));
        hash ^= UINT32_C(0) - (uint32_t)signed_value;
        hash = ~hash + (value & multiplier) + (value | seeds[7]);
        multiplier ^= value + round;
    }
    return bench_fold32(hash ^ value ^ multiplier);
}

BENCH_NOINLINE static uint16_t bitops32(void)
{
    uint32_t value = seeds[3] | 1;
    uint32_t hash = seeds[7];
    uint16_t round;

    for (round = 1; round != 17; ++round)
    {
        uint16_t shift = (uint16_t)((round * 7) & 31);

        hash += value << shift;
        hash ^= value >> shift;
        hash += (uint32_t)((int32_t)value >> shift);
        hash ^= __builtin_bswap32(value);
        hash += (uint16_t)__builtin_clz(value);
        hash ^= (uint16_t)__builtin_ctz(value);
        hash += (uint16_t)__builtin_popcount(value);
        hash -= value ^ UINT32_C(0x9e3779b9);
        value = (value ^ hash) * UINT32_C(0x10001);
        value |= 1;
    }
    return bench_fold32(hash ^ value);
}

BENCH_NOINLINE static uint16_t divide32(void)
{
    uint32_t numerator = seeds[4];
    uint32_t hash = seeds[6];
    uint16_t round;

    for (round = 0; round != 12; ++round)
    {
        uint32_t denominator =
            (seeds[(round + 1) & 7] ^ (uint32_t)(round * 0x101u)) | 1;
        uint32_t quotient = numerator / denominator;
        uint32_t remainder = numerator % denominator;
        int32_t signed_numerator =
            (int32_t)(numerator ^ UINT32_C(0x9630a5c3));
        int32_t signed_denominator =
            (int32_t)((denominator & UINT32_C(0x3fffffff)) + 3);
        int32_t signed_quotient = signed_numerator / signed_denominator;
        int32_t signed_remainder = signed_numerator % signed_denominator;
        uint32_t small_denominator = (uint32_t)round + 3;
        uint32_t small_quotient = numerator / small_denominator;
        uint32_t small_remainder = numerator % small_denominator;

        hash ^= quotient + (remainder << (round & 7));
        hash += (uint32_t)signed_quotient ^ (uint32_t)signed_remainder;
        hash ^= small_quotient + small_remainder;
        hash += numerator / 10 + numerator % 10;
        if ((int32_t)hash < signed_remainder)
            hash ^= UINT32_C(0xa5a55a5a);
        if (numerator >= denominator)
            hash += UINT32_C(0x1020304);
        numerator = hash ^ (numerator * UINT32_C(0x10001));
    }
    return bench_fold32(hash ^ numerator);
}

int main(void)
{
    uint16_t result = arithmetic32();
    result ^= multiply_shift32();
    result ^= bitops32();
    result ^= divide32();
    bench_finish(result, UINT16_C(0x807f));
}

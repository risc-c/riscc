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

int main(void)
{
    bench_finish(arithmetic32(), UINT16_C(0x572a));
}

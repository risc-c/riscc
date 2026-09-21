#include "bench.h"

enum { WORDS = 1024, ROUNDS = 8 };

// Together these buffers exceed the 2 KiB data cache on both widths.
static volatile uint32_t source[WORDS] __attribute__((aligned(32)));
static volatile uint32_t destination[WORDS] __attribute__((aligned(32)));

static uint32_t pattern(unsigned index)
{
    return UINT32_C(0x9e3779b9) ^ ((uint32_t)index << 16) ^ index;
}

BENCH_NOINLINE static void copy_words(volatile uint32_t *dst,
    const volatile uint32_t *src)
{
    for (unsigned left = WORDS; left != 0; left -= 8)
    {
        dst[0] = src[0];
        dst[1] = src[1];
        dst[2] = src[2];
        dst[3] = src[3];
        dst[4] = src[4];
        dst[5] = src[5];
        dst[6] = src[6];
        dst[7] = src[7];
        src += 8;
        dst += 8;
    }
}

int main(void)
{
    for (unsigned i = 0; i != WORDS; ++i)
        source[i] = pattern(i);

    for (unsigned round = 0; round != ROUNDS; ++round)
    {
        copy_words(destination, source);
        copy_words(source, destination);
    }

    for (unsigned i = 0; i != WORDS; ++i)
        if (source[i] != pattern(i) || destination[i] != pattern(i))
            bench_finish(UINT16_C(0x0b01), 0);
    bench_finish(0, 0);
}

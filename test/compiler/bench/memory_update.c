#include "bench.h"

enum { WORDS = 256, ROUNDS = 64 };

// A 1 KiB working set exercises cache hits and write-through stores.
static volatile uint32_t words[WORDS] __attribute__((aligned(32)));

BENCH_NOINLINE void update_words(volatile uint32_t *p)
{
    for (unsigned left = WORDS; left != 0; left -= 8)
    {
        p[0] += 1;
        p[1] += 1;
        p[2] += 1;
        p[3] += 1;
        p[4] += 1;
        p[5] += 1;
        p[6] += 1;
        p[7] += 1;
        p += 8;
    }
}

int main(void)
{
    for (unsigned i = 0; i != WORDS; ++i)
        words[i] = UINT32_C(0xffffffc0) + i;
    for (unsigned round = 0; round != ROUNDS; ++round)
        update_words(words);

    // Sixty-four increments wrap each initial value back to its index.
    for (unsigned i = 0; i != WORDS; ++i)
        if (words[i] != i)
            bench_finish(UINT16_C(0x0b02), 0);
    bench_finish(0, 0);
}

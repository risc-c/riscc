// Board firmware: SDRAM correctness checks and CPU bandwidth, reported on UART.
#include <stdio.h>
#include <riscc/platform.h>

#include "cached_access_checks.h"

#if (defined(RISCC_ATUM_A3) || defined(RISCC_DE23_LITE))
static const u32 kSdramWords = 0x01000000u; // 64 MiB
#elif defined(RISCC_ICEPI_ZERO)
static const u32 kSdramWords = 0x00800000u; // 32 MiB
#else
#error "CPU SDRAM hardware test requires an SDRAM board macro"
#endif

static u32 sdram_pattern(u32 address)
{
    u32 value = address ^ (address >> 11);
    value *= 0x45d9f3bu;
    value ^= value >> 16;
    return value ^ 0xa5c3f17du;
}

static void wait_one_second()
{
    const uint16_t start = riscc_ticks();
    while (static_cast<uint16_t>(riscc_ticks() - start) < RISCC_TICK_HZ)
    {
    }
}

static void report_forever(const char *message)
{
    for (;;)
    {
        puts(message);
        wait_one_second();
    }
}

static void fail(void)
{
    LED = 14;
    report_forever("CPU SDRAM FAIL");
}

static void full_sdram_test()
{
    puts("CPU SDRAM WRITE PATTERN");
    LED = 6;
    for (u32 address = 0; address < kSdramWords; ++address)
        MEM[address] = sdram_pattern(address);

    puts("CPU SDRAM READ PATTERN");
    LED = 7;
    for (u32 address = 0; address < kSdramWords; ++address)
        check(MEM[address], sdram_pattern(address));

    puts("CPU SDRAM WRITE COMPLEMENT");
    LED = 8;
    for (u32 address = 0; address < kSdramWords; ++address)
        MEM[address] = ~sdram_pattern(address);

    puts("CPU SDRAM READ COMPLEMENT");
    LED = 9;
    for (u32 address = 0; address < kSdramWords; ++address)
        check(MEM[address], ~sdram_pattern(address));
}

// Report CPU-visible bandwidth with video scanout active. A 1 MiB working
// set exceeds both caches; the 1 KiB case is warmed before timing. Stores
// still reach SDRAM because the data cache is write-through.
static const u32 kBenchWords = 256u * 1024u;
static const u32 kBenchBatch = 4096u;
static const u32 kBenchTicks = 2u * RISCC_TICK_HZ;
static const u32 kReadPattern = 0x31415926u;
static volatile u32 *const bench_memory = MEM + 0x4000u;

// Volatile loads are retained even when their values are discarded. Keep
// checking and pattern generation outside these bandwidth loops.
__attribute__((noinline)) static void read_words(volatile u32 *p, u32 words)
{
    volatile u32 *const end = p + words;
    do
    {
        (void)p[0];
        (void)p[1];
        (void)p[2];
        (void)p[3];
        (void)p[4];
        (void)p[5];
        (void)p[6];
        (void)p[7];
        (void)p[8];
        (void)p[9];
        (void)p[10];
        (void)p[11];
        (void)p[12];
        (void)p[13];
        (void)p[14];
        (void)p[15];
        (void)p[16];
        (void)p[17];
        (void)p[18];
        (void)p[19];
        (void)p[20];
        (void)p[21];
        (void)p[22];
        (void)p[23];
        (void)p[24];
        (void)p[25];
        (void)p[26];
        (void)p[27];
        (void)p[28];
        (void)p[29];
        (void)p[30];
        (void)p[31];
        p += 32;
    } while (p != end);
}

__attribute__((noinline)) static void write_words(volatile u32 *p, u32 words,
                                                  u32 pattern)
{
    volatile u32 *const end = p + words;
    do
    {
        p[0] = pattern;
        p[1] = pattern;
        p[2] = pattern;
        p[3] = pattern;
        p[4] = pattern;
        p[5] = pattern;
        p[6] = pattern;
        p[7] = pattern;
        p[8] = pattern;
        p[9] = pattern;
        p[10] = pattern;
        p[11] = pattern;
        p[12] = pattern;
        p[13] = pattern;
        p[14] = pattern;
        p[15] = pattern;
        p[16] = pattern;
        p[17] = pattern;
        p[18] = pattern;
        p[19] = pattern;
        p[20] = pattern;
        p[21] = pattern;
        p[22] = pattern;
        p[23] = pattern;
        p[24] = pattern;
        p[25] = pattern;
        p[26] = pattern;
        p[27] = pattern;
        p[28] = pattern;
        p[29] = pattern;
        p[30] = pattern;
        p[31] = pattern;
        p += 32;
    } while (p != end);
}

static void sequential_benchmark(const char *name, bool writing, u32 words,
                                 u32 pattern)
{
    u32 passes = 0;
    u32 ticks = 0;
    uint16_t previous = riscc_ticks();
    do
    {
        if (writing)
            write_words(bench_memory, words, pattern);
        else
            read_words(bench_memory, words);
        ++passes;
        const uint16_t now = riscc_ticks();
        ticks += static_cast<uint16_t>(now - previous);
        previous = now;
    } while (ticks < kBenchTicks);

    for (u32 i = 0; i < words; ++i)
        check(bench_memory[i], writing ? pattern : i ^ pattern);

    const u32 bytes = passes * words * sizeof(u32);
    const u32 kib_per_second = (bytes / 1024u) * RISCC_TICK_HZ / ticks;
    printf("%s: %u bytes / %u ms = %u KiB/s\n",
           name, bytes, ticks, kib_per_second);
}

static void scattered_benchmark(const char *name, bool writing, u32 words,
                      u32 stride, u32 pattern)
{
    u32 position = 0;
    u32 accesses = 0;
    u32 ticks = 0;
    u32 checksum = 0;
    const u32 mask = words - 1u;
    uint16_t previous = riscc_ticks();

    do
    {
        if (writing)
        {
            for (u32 i = 0; i < kBenchBatch; ++i)
            {
                bench_memory[position] = position ^ pattern;
                position = (position + stride) & mask;
            }
        }
        else
        {
            for (u32 i = 0; i < kBenchBatch; ++i)
            {
                checksum += bench_memory[position];
                position = (position + stride) & mask;
            }
        }
        accesses += kBenchBatch;
        // Sample each batch so the 16-bit millisecond counter can wrap.
        const uint16_t now = riscc_ticks();
        ticks += static_cast<uint16_t>(now - previous);
        previous = now;
    } while (ticks < kBenchTicks);

    // Verify outside the timed interval, following the same address sequence.
    position = 0;
    u32 expected = 0;
    for (u32 i = 0; i < accesses; ++i)
    {
        if (writing)
            check(bench_memory[position], position ^ pattern);
        else
            expected += position ^ pattern;
        position = (position + stride) & mask;
    }
    if (!writing)
        check(checksum, expected);

    const u32 bytes = accesses * sizeof(u32);
    const u32 kib_per_second = (bytes / 1024u) * RISCC_TICK_HZ / ticks;
    printf("%s: %u bytes / %u ms = %u KiB/s\n",
           name, bytes, ticks, kib_per_second);
}

static void memory_benchmarks()
{
    puts("CPU SDRAM BENCHMARK: effective CPU bandwidth, video active");
    for (u32 i = 0; i < kBenchWords; ++i)
        bench_memory[i] = i ^ kReadPattern;
    // Warm the small working set. No flush is needed for the streaming cases:
    // their working set is much larger than the 2 KiB data cache.
    for (u32 i = 0; i < 256u; ++i)
        check(bench_memory[i], i ^ kReadPattern);
    sequential_benchmark("Cached read, 1 KiB", false, 256u, kReadPattern);
    sequential_benchmark("Sequential read, 1 MiB", false, kBenchWords, kReadPattern);
    // An odd stride visits every word, with successive accesses on different
    // cache lines and SDRAM rows. Each useful four-byte load triggers a fill.
    scattered_benchmark("Scattered read, 1 MiB", false, kBenchWords, 4093u, kReadPattern);

    for (u32 i = 0; i < 256u; ++i)
        check(bench_memory[i], i ^ kReadPattern);
    sequential_benchmark("Cached write-through, 1 KiB", true, 256u, 0x12345678u);
    sequential_benchmark("Sequential write, 1 MiB", true, kBenchWords, 0x89abcdefu);
    scattered_benchmark("Scattered write, 1 MiB", true, kBenchWords, 4093u, 0x76543210u);
}

int main()
{
    test_cached_accesses();
    puts("CPU SDRAM CACHE CHECKS PASS");
    full_sdram_test();
    memory_benchmarks();
    LED = 15;
    report_forever("CPU SDRAM PASS");
    return 0;
}

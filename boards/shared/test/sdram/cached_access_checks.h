/* Shared CPU/cache checks for simulation and physical boards. */
#ifndef SDRAM_CACHED_ACCESS_CHECKS_H
#define SDRAM_CACHED_ACCESS_CHECKS_H
typedef unsigned int u32;
typedef unsigned short u16;
typedef unsigned char u8;
#define MEM ((volatile u32 *)0x10000000u)
#define LED (*(volatile u32 *)0xfffffff0u)
/* Each test program supplies its own failure reporting. */
static void fail(void);
static void check(u32 got, u32 want) { if (got != want) fail(); }
static void test_cached_accesses(void)
{
    for (u32 i = 0; i < 40; ++i) MEM[i] = 0xa5000000u + i;
    volatile u32 *p = MEM + 0x4000;
    for (u32 i = 0; i < 16; ++i) p[i] = 0x12340000u + i;
    LED = 1;
    check(p[0], 0x12340000u);
    LED = 2;
    /* Keep warm reads within the first 64-byte RC32 cache line. */
    for (u32 repeat = 0; repeat < 4; ++repeat)
        for (u32 i = 0; i < 16; ++i) check(p[i], 0x12340000u + i);
    LED = 3;
    ((volatile u8 *)p)[1] = 0xabu;
    ((volatile u16 *)p)[1] = 0xcdefu;
    check(p[0], 0xcdefab00u);
    check(((volatile u8 *)p)[1], 0xabu);
    check(((volatile u16 *)p)[1], 0xcdefu);
    LED = 4;
    /* A distant address with the same cache index forces eviction. */
    p[0x10000] = 0x76543210u;
    check(p[0x10000], 0x76543210u);
    check(p[0], 0xcdefab00u);
    LED = 5;
    /* Scattered full-width, byte and halfword accesses across rows/banks. */
    for (u32 i = 0; i < 128; ++i) {
        u32 offset = 0x80000u + ((i * 73u) & 127u) * 0x401u;
        MEM[offset] = 0x89120000u + i;
        ((volatile u8 *)&MEM[offset])[0] = (u8)(i ^ 0x5au);
        ((volatile u16 *)&MEM[offset])[1] = (u16)(0xdead ^ i);
    }
    for (u32 i = 0; i < 128; ++i) {
        u32 offset = 0x80000u + ((i * 73u) & 127u) * 0x401u;
        check(MEM[offset], ((0xdeadu ^ i) << 16) | (i ^ 0x5au));
    }
}

#endif

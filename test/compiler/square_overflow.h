#ifndef RISCC_COMPILER_SQUARE_OVERFLOW_H
#define RISCC_COMPILER_SQUARE_OVERFLOW_H

/* Keep the builtin in a separate call so its native-width operands remain
 * visible to the backend while the caller checks the widened reference. */
#ifndef __RISCC_RC32__
static __attribute__((noinline)) u32 square_overflow_u16_same(u16 value)
{
    u16 result;
    unsigned overflow = __builtin_mul_overflow(value, value, &result);
    return (u32)result | ((u32)overflow << 16);
}

static __attribute__((noinline)) u32 square_overflow_u16_pair(
    u16 left, u16 right)
{
    u16 result;
    unsigned overflow = __builtin_mul_overflow(left, right, &result);
    return (u32)result | ((u32)overflow << 16);
}

static __attribute__((noinline)) u32 square_overflow_s16_pair(
    s16 left, s16 right)
{
    s16 result;
    unsigned overflow = __builtin_mul_overflow(left, right, &result);
    return (u32)(u16)result | ((u32)overflow << 16);
}

static volatile u16 square_overflow_seed16 = 0x1357u;

static __attribute__((noinline)) u16 square_overflow_next16(void)
{
    u16 value = square_overflow_seed16;
    square_overflow_seed16 = (u16)((u32)value * 251u + 17u);
    return value;
}

static volatile struct square_overflow_u16_pair {
    u16 left;
    u16 right;
} square_overflow_u16_distinct[] = {
    {0u, 1u},
    {1u, 0u},
    {254u, 255u},
    {255u, 256u},
    {256u, 255u},
    {32768u, 3u},
    {65535u, 1u},
    {65535u, 65534u},
};

static volatile u16 square_overflow_u16_edges[] = {
    0u, 1u, 254u, 255u, 256u, 32768u, 65535u,
};

static volatile struct square_overflow_s16_pair {
    s16 left;
    s16 right;
} square_overflow_s16_cases[] = {
    {-32768, 1},
    {-32768, -1},
    {32767, 1},
    {32767, 2},
    {-1, -1},
    {-1, 32767},
    {0, -32768},
};

static unsigned test_square_overflow_rc16(void)
{
    unsigned i;

    /* Same-input cases include zero, one, sqrt(UINT16_MAX)-1, the fitting
     * root, root+1, the high bit, and UINT16_MAX. */
    for (i = 0; i < sizeof(square_overflow_u16_edges) /
                        sizeof(square_overflow_u16_edges[0]); ++i) {
        u16 value = square_overflow_u16_edges[i];
        u32 wide = (u32)value * (u32)value;
        u32 expected = (u32)(u16)wide |
                       ((u32)(wide > 0xffffu) << 16);
        if (square_overflow_u16_same(value) != expected)
            return 1;
    }

    /* Distinct operands exercise the non-square form of the same intrinsic. */
    for (i = 0; i < sizeof(square_overflow_u16_distinct) /
                        sizeof(square_overflow_u16_distinct[0]); ++i) {
        u16 left = square_overflow_u16_distinct[i].left;
        u16 right = square_overflow_u16_distinct[i].right;
        u32 wide = (u32)left * (u32)right;
        u32 expected = (u32)(u16)wide |
                       ((u32)(wide > 0xffffu) << 16);
        if (square_overflow_u16_pair(left, right) != expected)
            return 2;
    }

    /* Volatile state and a noinline step keep these operands runtime-produced. */
    for (i = 0; i < 32u; ++i) {
        u16 left = square_overflow_next16();
        u16 right = (u16)(square_overflow_next16() ^ 1u);
        u32 square_wide = (u32)left * (u32)left;
        u32 pair_wide = (u32)left * (u32)right;
        u32 square_expected = (u32)(u16)square_wide |
                              ((u32)(square_wide > 0xffffu) << 16);
        u32 pair_expected = (u32)(u16)pair_wide |
                            ((u32)(pair_wide > 0xffffu) << 16);
        if (square_overflow_u16_same(left) != square_expected ||
            square_overflow_u16_pair(left, right) != pair_expected)
            return 3;
    }

    for (i = 0; i < sizeof(square_overflow_s16_cases) /
                        sizeof(square_overflow_s16_cases[0]); ++i) {
        s16 left = square_overflow_s16_cases[i].left;
        s16 right = square_overflow_s16_cases[i].right;
        s32 wide = (s32)left * (s32)right;
        u32 expected = (u32)(u16)wide |
                       ((u32)(wide < -32768 || wide > 32767) << 16);
        if (square_overflow_s16_pair(left, right) != expected)
            return 4;
    }

    return 0;
}

#endif

#ifdef __RISCC_RC32__

static __attribute__((noinline)) u64 square_overflow_u32_same(u32 value)
{
    u32 result;
    unsigned overflow = __builtin_mul_overflow(value, value, &result);
    return (u64)result | ((u64)overflow << 32);
}

static __attribute__((noinline)) u64 square_overflow_u32_pair(
    u32 left, u32 right)
{
    u32 result;
    unsigned overflow = __builtin_mul_overflow(left, right, &result);
    return (u64)result | ((u64)overflow << 32);
}

static __attribute__((noinline)) u64 square_overflow_s32_pair(
    s32 left, s32 right)
{
    s32 result;
    unsigned overflow = __builtin_mul_overflow(left, right, &result);
    return (u64)(u32)result | ((u64)overflow << 32);
}

static volatile u32 square_overflow_seed32 = 0x13579bdfu;

static __attribute__((noinline)) u32 square_overflow_next32(void)
{
    u32 value = square_overflow_seed32;
    square_overflow_seed32 = value * 1664525u + 1013904223u;
    return value;
}

static volatile struct square_overflow_u32_pair {
    u32 left;
    u32 right;
} square_overflow_u32_distinct[] = {
    {0u, 1u},
    {1u, 0u},
    {65534u, 65535u},
    {65535u, 65536u},
    {65536u, 65535u},
    {0x80000000u, 3u},
    {0xffffffffu, 1u},
    {0xffffffffu, 0xfffffffeu},
};

static volatile u32 square_overflow_u32_edges[] = {
    0u, 1u, 65534u, 65535u, 65536u, 0x80000000u, 0xffffffffu,
};

static volatile struct square_overflow_s32_pair {
    s32 left;
    s32 right;
} square_overflow_s32_cases[] = {
    {(s32)0x80000000u, 1},
    {(s32)0x80000000u, -1},
    {2147483647, 1},
    {2147483647, 2},
    {-1, -1},
    {-1, 2147483647},
    {0, (s32)0x80000000u},
};

static unsigned test_square_overflow_rc32(void)
{
    unsigned i;

    for (i = 0; i < sizeof(square_overflow_u32_edges) /
                        sizeof(square_overflow_u32_edges[0]); ++i) {
        u32 value = square_overflow_u32_edges[i];
        u64 wide = (u64)value * (u64)value;
        u64 expected = (u64)(u32)wide |
                       ((u64)(wide > 0xffffffffull) << 32);
        if (square_overflow_u32_same(value) != expected)
            return 1;
    }

    for (i = 0; i < sizeof(square_overflow_u32_distinct) /
                        sizeof(square_overflow_u32_distinct[0]); ++i) {
        u32 left = square_overflow_u32_distinct[i].left;
        u32 right = square_overflow_u32_distinct[i].right;
        u64 wide = (u64)left * (u64)right;
        u64 expected = (u64)(u32)wide |
                       ((u64)(wide > 0xffffffffull) << 32);
        if (square_overflow_u32_pair(left, right) != expected)
            return 2;
    }

    for (i = 0; i < 32u; ++i) {
        u32 left = square_overflow_next32();
        u32 right = square_overflow_next32() ^ 1u;
        u64 square_wide = (u64)left * (u64)left;
        u64 pair_wide = (u64)left * (u64)right;
        u64 square_expected = (u64)(u32)square_wide |
                              ((u64)(square_wide > 0xffffffffull) << 32);
        u64 pair_expected = (u64)(u32)pair_wide |
                            ((u64)(pair_wide > 0xffffffffull) << 32);
        if (square_overflow_u32_same(left) != square_expected ||
            square_overflow_u32_pair(left, right) != pair_expected)
            return 3;
    }

    for (i = 0; i < sizeof(square_overflow_s32_cases) /
                        sizeof(square_overflow_s32_cases[0]); ++i) {
        s32 left = square_overflow_s32_cases[i].left;
        s32 right = square_overflow_s32_cases[i].right;
        s64 wide = (s64)left * (s64)right;
        u64 expected = (u64)(u32)wide |
                       ((u64)(wide < (s64)-2147483648ll ||
                               wide > (s64)2147483647ll) << 32);
        if (square_overflow_s32_pair(left, right) != expected)
            return 4;
    }

    return 0;
}

#endif

static unsigned test_square_overflow(void)
{
#ifdef __RISCC_RC32__
    return test_square_overflow_rc32();
#else
    return test_square_overflow_rc16();
#endif
}

#endif

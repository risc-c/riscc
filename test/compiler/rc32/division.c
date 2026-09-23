#include "test.h"

u32 __udivsi3(u32, u32);
u32 __umodsi3(u32, u32);
u32 __udivmodsi4(u32, u32, u32 *);
s32 __divsi3(s32, s32);
s32 __modsi3(s32, s32);
s32 __divmodsi4(s32, s32, s32 *);

u64 __udivdi3(u64, u64);
u64 __umoddi3(u64, u64);
u64 __udivmoddi4(u64, u64, u64 *);
s64 __divdi3(s64, s64);
s64 __moddi3(s64, s64);
s64 __divmoddi4(s64, s64, s64 *);

struct division_case
{
    u32 numerator;
    u32 denominator;
    u32 quotient;
    u32 remainder;
};

/* Expected values are fixed vectors, so this test does not reproduce the
 * shift/subtract algorithm used by firmware/rc32/integer.S.  The zero divisor
 * convention is quotient zero and the unchanged numerator as remainder. */
static const struct division_case unsigned_cases[] =
{
    {0x00000000U, 0x00000000U, 0x00000000U, 0x00000000U},
    {0x00000000U, 0x00000001U, 0x00000000U, 0x00000000U},
    {0x00000001U, 0x00000000U, 0x00000000U, 0x00000001U},
    {0x00000001U, 0x00000001U, 0x00000001U, 0x00000000U},
    /* Quotient-zero/one fast paths and the first normalized-loop case. */
    {6U, 7U, 0U, 6U},
    {7U, 7U, 1U, 0U},
    {9U, 7U, 1U, 2U},
    {13U, 7U, 1U, 6U},
    {14U, 7U, 2U, 0U},
    {15U, 7U, 2U, 1U},
    {0x80000000U, 0x40000001U, 1U, 0x3fffffffU},
    {0xffffffffU, 0x00000000U, 0x00000000U, 0xffffffffU},
    {0xffffffffU, 0x00000001U, 0xffffffffU, 0x00000000U},
    {0xffffffffU, 0xffffffffU, 0x00000001U, 0x00000000U},
    {0xffffffffU, 0xfffffffeU, 0x00000001U, 0x00000001U},
    {0x80000000U, 0x80000000U, 0x00000001U, 0x00000000U},
    {0x80000000U, 0x7fffffffU, 0x00000001U, 0x00000001U},
    {0x7fffffffU, 0x80000000U, 0x00000000U, 0x7fffffffU},
    {0x80000001U, 0x80000000U, 0x00000001U, 0x00000001U},
    {0x7fffffffU, 0x7ffffffeU, 0x00000001U, 0x00000001U},
    {0x12345678U, 0x00012345U, 0x00001000U, 0x00000678U},
    {0x89abcdefU, 0x07654321U, 0x00000012U, 0x048d159dU},
    {0xdeadbeefU, 0x00010001U, 0x0000deacU, 0x0000e043U},
    {0x13579bdfU, 0x2468ace1U, 0x00000000U, 0x13579bdfU},
    {0xfeedfaceU, 0x80000003U, 0x00000001U, 0x7eedfacbU},
    {0x01010101U, 0x0100ffffU, 0x00000001U, 0x00000102U},
    {0xc001d00dU, 0x00010001U, 0x0000c001U, 0x0000100cU},
    {0x55555555U, 0x0000aaaaU, 0x00008000U, 0x00005555U},
    {0xabcdef01U, 0x10000001U, 0x0000000aU, 0x0bcdeef7U},

    /* Every divisor alignment from bit zero through the sign bit. */
    {0xffffffffU, 0x00000001U, 0xffffffffU, 0x00000000U},
    {0xffffffffU, 0x00000002U, 0x7fffffffU, 0x00000001U},
    {0xffffffffU, 0x00000004U, 0x3fffffffU, 0x00000003U},
    {0xffffffffU, 0x00000008U, 0x1fffffffU, 0x00000007U},
    {0xffffffffU, 0x00000010U, 0x0fffffffU, 0x0000000fU},
    {0xffffffffU, 0x00000020U, 0x07ffffffU, 0x0000001fU},
    {0xffffffffU, 0x00000040U, 0x03ffffffU, 0x0000003fU},
    {0xffffffffU, 0x00000080U, 0x01ffffffU, 0x0000007fU},
    {0xffffffffU, 0x00000100U, 0x00ffffffU, 0x000000ffU},
    {0xffffffffU, 0x00000200U, 0x007fffffU, 0x000001ffU},
    {0xffffffffU, 0x00000400U, 0x003fffffU, 0x000003ffU},
    {0xffffffffU, 0x00000800U, 0x001fffffU, 0x000007ffU},
    {0xffffffffU, 0x00001000U, 0x000fffffU, 0x00000fffU},
    {0xffffffffU, 0x00002000U, 0x0007ffffU, 0x00001fffU},
    {0xffffffffU, 0x00004000U, 0x0003ffffU, 0x00003fffU},
    {0xffffffffU, 0x00008000U, 0x0001ffffU, 0x00007fffU},
    {0xffffffffU, 0x00010000U, 0x0000ffffU, 0x0000ffffU},
    {0xffffffffU, 0x00020000U, 0x00007fffU, 0x0001ffffU},
    {0xffffffffU, 0x00040000U, 0x00003fffU, 0x0003ffffU},
    {0xffffffffU, 0x00080000U, 0x00001fffU, 0x0007ffffU},
    {0xffffffffU, 0x00100000U, 0x00000fffU, 0x000fffffU},
    {0xffffffffU, 0x00200000U, 0x000007ffU, 0x001fffffU},
    {0xffffffffU, 0x00400000U, 0x000003ffU, 0x003fffffU},
    {0xffffffffU, 0x00800000U, 0x000001ffU, 0x007fffffU},
    {0xffffffffU, 0x01000000U, 0x000000ffU, 0x00ffffffU},
    {0xffffffffU, 0x02000000U, 0x0000007fU, 0x01ffffffU},
    {0xffffffffU, 0x04000000U, 0x0000003fU, 0x03ffffffU},
    {0xffffffffU, 0x08000000U, 0x0000001fU, 0x07ffffffU},
    {0xffffffffU, 0x10000000U, 0x0000000fU, 0x0fffffffU},
    {0xffffffffU, 0x20000000U, 0x00000007U, 0x1fffffffU},
    {0xffffffffU, 0x40000000U, 0x00000003U, 0x3fffffffU},
    {0xffffffffU, 0x80000000U, 0x00000001U, 0x7fffffffU},
};

/* Values are represented as u32 so INT_MIN and INT_MIN/-1 can be checked
 * without asking the C compiler to evaluate that undefined C expression. */
static const struct division_case signed_cases[] =
{
    {0x00000000U, 0x00000000U, 0x00000000U, 0x00000000U},
    {0x00000000U, 0x00000001U, 0x00000000U, 0x00000000U},
    {0x00000000U, 0xffffffffU, 0x00000000U, 0x00000000U},
    {0x00000001U, 0x00000000U, 0x00000000U, 0x00000001U},
    {0xffffffffU, 0x00000000U, 0x00000000U, 0xffffffffU},
    {0x00000001U, 0x00000001U, 0x00000001U, 0x00000000U},
    {0xffffffffU, 0x00000001U, 0xffffffffU, 0x00000000U},
    {0x00000001U, 0xffffffffU, 0xffffffffU, 0x00000000U},
    {0xffffffffU, 0xffffffffU, 0x00000001U, 0x00000000U},
    {0x7fffffffU, 0x00000001U, 0x7fffffffU, 0x00000000U},
    {0x80000000U, 0x00000001U, 0x80000000U, 0x00000000U},
    {0x7fffffffU, 0xffffffffU, 0x80000001U, 0x00000000U},
    {0x80000000U, 0xffffffffU, 0x80000000U, 0x00000000U},
    {0x80000000U, 0x7fffffffU, 0xffffffffU, 0xffffffffU},
    {0x7fffffffU, 0x80000000U, 0x00000000U, 0x7fffffffU},
    {0xfffffff9U, 0x00000003U, 0xfffffffeU, 0xffffffffU},
    {0x00000007U, 0xfffffffdU, 0xfffffffeU, 0x00000001U},
    {0xfffffff9U, 0xfffffffdU, 0x00000002U, 0xffffffffU},
    {0xfffffff3U, 7U, 0xffffffffU, 0xfffffffaU},
    {13U, 0xfffffff9U, 0xffffffffU, 6U},
    {0xfffffff3U, 0xfffffff9U, 1U, 0xfffffffaU},
    {0x7fffffffU, 0x00000002U, 0x3fffffffU, 0x00000001U},
    {0x80000001U, 0xfffffffeU, 0x3fffffffU, 0xffffffffU},
    {0xf8a432ebU, 0x0000012cU, 0xfff9b87eU, 0xffffff43U},
    {0x075bcd15U, 0xfffffed4U, 0xfff9b87eU, 0x000000bdU},
    {0xf8a432ebU, 0xfffffed4U, 0x00064782U, 0xffffff43U},
    {0x40000001U, 0x40000000U, 0x00000001U, 0x00000001U},
    {0x40000000U, 0x40000001U, 0x00000000U, 0x40000000U},
    {0x40000000U, 0xbfffffffU, 0x00000000U, 0x40000000U},
    {0xc0000000U, 0x40000001U, 0x00000000U, 0xc0000000U},
    {0x13579bdfU, 0x2468ace1U, 0x00000000U, 0x13579bdfU},
    {0xdb97531fU, 0x13579bdfU, 0xffffffffU, 0xeeeeeefeU},
};

static __attribute__((noinline)) u16 check_unsigned(const struct division_case *test)
{
    u32 remainder = 0x5a5a5a5aU;

    if (__udivsi3(test->numerator, test->denominator) != test->quotient ||
        __umodsi3(test->numerator, test->denominator) != test->remainder)
        return 1;
    if (__udivmodsi4(test->numerator, test->denominator, &remainder) !=
            test->quotient || remainder != test->remainder)
        return 2;
    if (__udivmodsi4(test->numerator, test->denominator, (u32 *)0) !=
            test->quotient)
        return 3;
    return 0;
}

static __attribute__((noinline)) u16 check_signed(const struct division_case *test)
{
    s32 remainder = (s32)0x5a5a5a5aU;
    s32 numerator = (s32)test->numerator;
    s32 denominator = (s32)test->denominator;

    if ((u32)__divsi3(numerator, denominator) != test->quotient ||
        (u32)__modsi3(numerator, denominator) != test->remainder)
        return 1;
    if ((u32)__divmodsi4(numerator, denominator, &remainder) !=
            test->quotient || (u32)remainder != test->remainder)
        return 2;
    if ((u32)__divmodsi4(numerator, denominator, (s32 *)0) !=
            test->quotient)
        return 3;
    return 0;
}

/* Keep live values in each C callee-saved GPR across every helper entry. */
static __attribute__((noinline)) u16 check_callee_saved(void)
{
    register u32 keep4 __asm__("r4") = 0x13579bdfU;
    register u32 keep5 __asm__("r5") = 0x2468ace0U;
    register u32 keep6 __asm__("r6") = 0xdeadbeefU;
    u32 remainder;

    (void)__udivsi3(0xdeadbeefU, 0x12345U);
    (void)__umodsi3(0xdeadbeefU, 0x12345U);
    (void)__udivmodsi4(0xdeadbeefU, 0x12345U, &remainder);
    (void)__divsi3((s32)0xdeadbeefU, 0x12345);
    (void)__modsi3((s32)0xdeadbeefU, 0x12345);
    (void)__divmodsi4((s32)0xdeadbeefU, 0x12345, (s32 *)0);
    __asm__ volatile("" : "+r"(keep4), "+r"(keep5), "+r"(keep6));

    return keep4 == 0x13579bdfU && keep5 == 0x2468ace0U &&
        keep6 == 0xdeadbeefU ? 0 : 1;
}

struct wide_division_case
{
    u64 numerator, denominator, quotient, remainder;
};

/* Both sides of the 32-bit prefix skip, quotient 0/1, and cross-word borrow. */
static const struct wide_division_case wide_unsigned_cases[] =
{
    {0x0000000000000000ull, 0x0000000000000000ull, 0x0000000000000000ull, 0x0000000000000000ull},
    {0x0000000000000001ull, 0x0000000000000000ull, 0x0000000000000000ull, 0x0000000000000001ull},
    {0x0000000000000001ull, 0x0000000000000001ull, 0x0000000000000001ull, 0x0000000000000000ull},
    {0x0000000000000009ull, 0x0000000000000007ull, 0x0000000000000001ull, 0x0000000000000002ull},
    {0x000000000000000dull, 0x0000000000000007ull, 0x0000000000000001ull, 0x0000000000000006ull},
    {0x000000000000000eull, 0x0000000000000007ull, 0x0000000000000002ull, 0x0000000000000000ull},
    {0x00000001ffffffffull, 0x0000000000000002ull, 0x00000000ffffffffull, 0x0000000000000001ull},
    {0x0000000200000000ull, 0x0000000000000002ull, 0x0000000100000000ull, 0x0000000000000000ull},
    {0xffffffffffffffffull, 0x0000000000000002ull, 0x7fffffffffffffffull, 0x0000000000000001ull},
    {0xffffffffffffffffull, 0x000000000000000aull, 0x1999999999999999ull, 0x0000000000000005ull},
    {0xffffffffffffffffull, 0x000000007fffffffull, 0x0000000200000004ull, 0x0000000000000003ull},
    {0xffffffff00000000ull, 0x000000000000000aull, 0x1999999980000000ull, 0x0000000000000000ull},
    {0x8000000000000000ull, 0x4000000000000001ull, 0x0000000000000001ull, 0x3fffffffffffffffull},
    {0x8000000000000000ull, 0x4000000000000000ull, 0x0000000000000002ull, 0x0000000000000000ull},
    {0x8000000000000000ull, 0x3000000000000001ull, 0x0000000000000002ull, 0x1ffffffffffffffeull},
    {0xffffffffffffffffull, 0x0000000100000001ull, 0x00000000ffffffffull, 0x0000000000000000ull},
};

static const struct wide_division_case wide_signed_cases[] =
{
    /* Negation with and without a borrow from the low word. */
    {0xffffffff00000000ull, 0x0000000000010000ull, 0xffffffffffff0000ull, 0x0000000000000000ull},
    {0xfffffffeffffffffull, 0x0000000000010000ull, 0xffffffffffff0000ull, 0xffffffffffffffffull},
    {0x0000000100000000ull, 0xffffffff00000000ull, 0xffffffffffffffffull, 0x0000000000000000ull},
    {0x0000000100000001ull, 0xffffffff00000000ull, 0xffffffffffffffffull, 0x0000000000000001ull},
    {0xffffffff00000000ull, 0xffffffffffff0000ull, 0x0000000000010000ull, 0x0000000000000000ull},
    {0xfffffffffffffff3ull, 0x0000000000000007ull, 0xffffffffffffffffull, 0xfffffffffffffffaull},
    {0x000000000000000dull, 0xfffffffffffffff9ull, 0xffffffffffffffffull, 0x0000000000000006ull},
    {0xfffffffffffffff3ull, 0xfffffffffffffff9ull, 0x0000000000000001ull, 0xfffffffffffffffaull},
    {0x8000000000000000ull, 0xffffffffffffffffull, 0x8000000000000000ull, 0x0000000000000000ull},
    {0x8000000000000000ull, 0x0000000000000000ull, 0x0000000000000000ull, 0x8000000000000000ull},
    {0x8000000000000001ull, 0x000000000000000aull, 0xf333333333333334ull, 0xfffffffffffffff9ull},
};

static __attribute__((noinline)) int check_wide_unsigned(
    const struct wide_division_case *test)
{
    u64 remainder;
    return __udivdi3(test->numerator, test->denominator) == test->quotient &&
        __umoddi3(test->numerator, test->denominator) == test->remainder &&
        __udivmoddi4(test->numerator, test->denominator, &remainder) ==
            test->quotient && remainder == test->remainder &&
        __udivmoddi4(test->numerator, test->denominator, (u64 *)0) ==
            test->quotient;
}

static __attribute__((noinline)) int check_wide_signed(
    const struct wide_division_case *test)
{
    s64 n = (s64)test->numerator, d = (s64)test->denominator, remainder;
    return (u64)__divdi3(n, d) == test->quotient &&
        (u64)__moddi3(n, d) == test->remainder &&
        (u64)__divmoddi4(n, d, &remainder) == test->quotient &&
        (u64)remainder == test->remainder &&
        (u64)__divmoddi4(n, d, (s64 *)0) == test->quotient;
}

u16 rc32_test_division(void)
{
    u32 index;

    if (check_callee_saved() != 0)
        return 1;
    for (index = 0; index != sizeof(unsigned_cases) / sizeof(unsigned_cases[0]);
        ++index)
        if (check_unsigned(&unsigned_cases[index]) != 0)
            return 2;
    for (index = 0; index != sizeof(signed_cases) / sizeof(signed_cases[0]);
        ++index)
        if (check_signed(&signed_cases[index]) != 0)
            return 3;
    for (index = 0; index != sizeof(wide_unsigned_cases) /
            sizeof(wide_unsigned_cases[0]); ++index)
        if (!check_wide_unsigned(&wide_unsigned_cases[index]))
            return 4;
    for (index = 0; index != sizeof(wide_signed_cases) /
            sizeof(wide_signed_cases[0]); ++index)
        if (!check_wide_signed(&wide_signed_cases[index]))
            return 5;
    return 0;
}

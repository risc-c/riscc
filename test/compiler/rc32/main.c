#include <limits.h>
#include <math.h>

#include "test.h"

#define RESULT (*(volatile u16 *)0xfffeu)

static void fail(u16 code)
{
    RESULT = (u16)(0xc000u | code);
    for (;;)
        ;
}

int main(void)
{
    struct rc32_pair pair;
    struct rc32_large large;

    _Static_assert(sizeof(int) == 4, "RC32 int width");
    _Static_assert(sizeof(void *) == 4, "RC32 pointer width");
    _Static_assert(sizeof(struct rc32_pair) == 8, "RC32 aggregate layout");
    _Static_assert(INT_MIN == (-2147483647 - 1), "RC32 INT_MIN");
    _Static_assert(INT_MAX == 2147483647, "RC32 INT_MAX");
    _Static_assert(UINT_MAX == 4294967295u, "RC32 UINT_MAX");
    _Static_assert(FP_ILOGB0 == INT_MIN, "RC32 FP_ILOGB0");
    _Static_assert(FP_ILOGBNAN == INT_MAX, "RC32 FP_ILOGBNAN");

    if (rc32_global != 0x13579bdfu || rc32_bss != 0)
        fail(1);
    if (rc32_tls_data != 0x2468ace0u || rc32_tls_bss != 0)
        fail(2);
    if (rc32_tls_update(0x10u) != 0x2468ad10u ||
        rc32_tls_data != 0x2468acf0u || rc32_tls_bss != 0x20u)
        fail(3);

    if (rc32_stack_sum(1, 2, 3, 4, 5) != 15)
        fail(4);

    pair = rc32_make_pair(0x01020304u);
    if (pair.first != 0x12131415u || pair.second != 0xa4a7a6a1u)
        fail(5);

    large = rc32_make_large(0x11223340u);
    if (large.word[0] != 0x11223341u ||
        large.word[1] != 0x11223342u ||
        large.word[2] != 0x11223343u ||
        large.word[3] != 0x11223344u)
        fail(6);

    if (rc32_varargs_sum(0x1000u, 4,
                         0x10u, 0x20u, 0x30u, 0x40u) != 0x10a0u)
        fail(7);
    if (rc32_varargs_pair(0x10u, 1, pair) != 0xb6babac6u)
        fail(8);

    if (rc32_literal_long(1) != 0x8dbf2546u)
        fail(9);
    if (rc32_cpp_check(0x12345678u) != 0x288ff75du)
        fail(10);
    {
        u16 detail = rc32_test_builtins();
        if (detail)
            fail((u16)(0x100u + detail));
    }
    {
        u16 detail = rc32_test_float();
        if (detail)
            fail((u16)(0x200u + detail));
    }
    {
        u16 detail = rc32_test_tail();
        if (detail)
            fail((u16)(0x300u + detail));
    }

    RESULT = 0x600d;
    return 0;
}

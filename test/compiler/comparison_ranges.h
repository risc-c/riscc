/* Exercise immediate comparisons with and without a proven narrow range. */
#include <limits.h>

static volatile unsigned comparison_flags;

static __attribute__((noinline)) unsigned compare_byte(signed char value)
{
    comparison_flags = 0;
    if (value < 65) comparison_flags |= 1;
    if (value >= -3) comparison_flags |= 2;
    if (value <= 10) comparison_flags |= 4;
    if (value > 126) comparison_flags |= 8;
    return comparison_flags;
}

static __attribute__((noinline)) unsigned compare_native(int value)
{
    comparison_flags = 0;
    if (value < 65) comparison_flags |= 1;
    if (value >= -3) comparison_flags |= 2;
    if (value <= 10) comparison_flags |= 4;
    if (value > 126) comparison_flags |= 8;
    return comparison_flags;
}

static unsigned test_comparison_ranges(void)
{
    static const signed char values[] = {-128, -4, -3, 0, 10, 11, 64, 65, 126, 127};
    static const unsigned char expected[] = {5, 5, 7, 7, 7, 3, 3, 2, 2, 10};
    for (unsigned i = 0; i < sizeof(values); ++i)
        if (compare_byte(values[i]) != expected[i] ||
            compare_native(values[i]) != expected[i])
            return 1;
    return compare_native(INT_MIN) != 5 || compare_native(INT_MAX) != 10;
}

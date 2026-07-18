#include <math.h>
#include <stdint.h>

#include "internal.h"

static int16_t float_is_nan(riscc_float_shape shape)
{
    return (shape.word[1] & UINT16_C(0x7f80)) == UINT16_C(0x7f80) &&
        ((shape.word[1] & UINT16_C(0x007f)) || shape.word[0]);
}

static int16_t double_is_nan(riscc_double_shape shape)
{
    return (shape.word[3] & UINT16_C(0x7ff0)) == UINT16_C(0x7ff0) &&
        ((shape.word[3] & UINT16_C(0x000f)) || shape.word[2] ||
            shape.word[1] || shape.word[0]);
}

static void increment_float(riscc_float_shape *shape)
{
    if (++shape->word[0] == 0)
        ++shape->word[1];
}

static void decrement_float(riscc_float_shape *shape)
{
    if (shape->word[0]-- == 0)
        --shape->word[1];
}

static void increment_double(riscc_double_shape *shape)
{
    uint16_t index;
    for (index = 0; index != 4; ++index)
        if (++shape->word[index])
            return;
}

static void decrement_double(riscc_double_shape *shape)
{
    uint16_t index;
    for (index = 0; index != 4; ++index)
        if (shape->word[index]--)
            return;
}

float nextafterf(float from, float toward)
{
    riscc_float_shape from_shape = {from};
    riscc_float_shape toward_shape = {toward};
    int16_t increase;

    if (float_is_nan(from_shape))
    {
        from_shape.word[1] |= UINT16_C(0x0040);
        return from_shape.value;
    }
    if (float_is_nan(toward_shape))
    {
        toward_shape.word[1] |= UINT16_C(0x0040);
        return toward_shape.value;
    }
    if (from == toward)
        return toward;
    if (!(from_shape.word[0] ||
            (from_shape.word[1] & UINT16_C(0x7fff))))
    {
        from_shape.word[0] = 1;
        from_shape.word[1] = toward_shape.word[1] & UINT16_C(0x8000);
        return from_shape.value;
    }

    increase = (from < toward) ==
        !(from_shape.word[1] & UINT16_C(0x8000));
    if (increase)
        increment_float(&from_shape);
    else
        decrement_float(&from_shape);
    return from_shape.value;
}

double nextafter(double from, double toward)
{
    riscc_double_shape from_shape = {from};
    riscc_double_shape toward_shape = {toward};
    int16_t increase;

    if (double_is_nan(from_shape))
    {
        from_shape.word[3] |= UINT16_C(0x0008);
        return from_shape.value;
    }
    if (double_is_nan(toward_shape))
    {
        toward_shape.word[3] |= UINT16_C(0x0008);
        return toward_shape.value;
    }
    if (from == toward)
        return toward;
    if (!(from_shape.word[0] || from_shape.word[1] || from_shape.word[2] ||
            (from_shape.word[3] & UINT16_C(0x7fff))))
    {
        from_shape.word[0] = 1;
        from_shape.word[1] = 0;
        from_shape.word[2] = 0;
        from_shape.word[3] = toward_shape.word[3] & UINT16_C(0x8000);
        return from_shape.value;
    }

    increase = (from < toward) ==
        !(from_shape.word[3] & UINT16_C(0x8000));
    if (increase)
        increment_double(&from_shape);
    else
        decrement_double(&from_shape);
    return from_shape.value;
}

long double nextafterl(long double from, long double toward)
{
    return (long double)nextafter((double)from, (double)toward);
}

float nexttowardf(float from, long double toward)
{
    long double wide_from = (long double)from;

    if (toward != toward)
        return nextafterf(from, (float)toward);
    if (wide_from == toward)
        return (float)toward;
    return nextafterf(from, wide_from < toward ? HUGE_VALF : -HUGE_VALF);
}

double nexttoward(double from, long double toward)
{
    return nextafter(from, (double)toward);
}

long double nexttowardl(long double from, long double toward)
{
    return (long double)nextafter((double)from, (double)toward);
}

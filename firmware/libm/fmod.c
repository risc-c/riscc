#include <math.h>
#include <stdint.h>

#include "internal.h"

static uint32_t quiet_float_nan(uint32_t bits)
{
    if ((bits & UINT32_C(0x7f800000)) == UINT32_C(0x7f800000) &&
        (bits & UINT32_C(0x007fffff)))
        return bits | UINT32_C(0x00400000);
    return UINT32_C(0x7fc00000);
}

static uint32_t unsigned_fmodf(uint32_t numerator, uint32_t denominator)
{
    uint32_t numerator_significand = numerator & UINT32_C(0x007fffff);
    uint32_t denominator_significand = denominator & UINT32_C(0x007fffff);
    uint16_t numerator_field = (uint16_t)(numerator >> 23);
    uint16_t denominator_field = (uint16_t)(denominator >> 23);
    int16_t numerator_exponent;
    int16_t denominator_exponent;

    if (numerator_field)
    {
        numerator_significand |= UINT32_C(0x00800000);
        numerator_exponent = (int16_t)numerator_field - 127;
    }
    else
    {
        numerator_exponent = -126;
        while (numerator_significand < UINT32_C(0x00800000))
        {
            numerator_significand <<= 1;
            --numerator_exponent;
        }
    }

    if (denominator_field)
    {
        denominator_significand |= UINT32_C(0x00800000);
        denominator_exponent = (int16_t)denominator_field - 127;
    }
    else
    {
        denominator_exponent = -126;
        while (denominator_significand < UINT32_C(0x00800000))
        {
            denominator_significand <<= 1;
            --denominator_exponent;
        }
    }

    while (numerator_exponent > denominator_exponent)
    {
        if (numerator_significand >= denominator_significand)
            numerator_significand -= denominator_significand;
        if (!numerator_significand)
            return 0;
        numerator_significand <<= 1;
        --numerator_exponent;
    }
    if (numerator_significand >= denominator_significand)
        numerator_significand -= denominator_significand;
    if (!numerator_significand)
        return 0;

    while (numerator_significand < UINT32_C(0x00800000))
    {
        numerator_significand <<= 1;
        --numerator_exponent;
    }
    if (numerator_exponent >= -126)
        return (uint32_t)(numerator_exponent + 127) << 23 |
            (numerator_significand & UINT32_C(0x007fffff));

    while (numerator_exponent < -126)
    {
        numerator_significand >>= 1;
        ++numerator_exponent;
    }
    return numerator_significand;
}

float fmodf(float numerator, float denominator)
{
    riscc_float_shape left = {numerator};
    riscc_float_shape right = {denominator};
    uint32_t sign = left.bits & UINT32_C(0x80000000);
    uint32_t x = left.bits & UINT32_C(0x7fffffff);
    uint32_t y = right.bits & UINT32_C(0x7fffffff);

    if (x > UINT32_C(0x7f800000) || y > UINT32_C(0x7f800000))
    {
        left.bits = quiet_float_nan(
            x > UINT32_C(0x7f800000) ? left.bits : right.bits);
        return left.value;
    }
    if (x == UINT32_C(0x7f800000) || y == 0)
    {
        left.bits = UINT32_C(0x7fc00000);
        return left.value;
    }
    if (y == UINT32_C(0x7f800000) || x < y)
        return numerator;
    if (x == y)
    {
        left.bits = sign;
        return left.value;
    }

    left.bits = sign | unsigned_fmodf(x, y);
    return left.value;
}

static int16_t double_significand(
    riscc_math_uint *value, uint16_t exponent_field)
{
    int16_t exponent;

    value->word[3] &= UINT16_C(0x000f);
    if (exponent_field)
    {
        value->word[3] |= UINT16_C(0x0010);
        return (int16_t)exponent_field - 1023;
    }

    exponent = -1022;
    while (!(value->word[3] & UINT16_C(0x0010)))
    {
        __riscc_math_shift_left_one(value, 4);
        --exponent;
    }
    return exponent;
}

static void unsigned_fmod(
    riscc_math_uint *numerator, const riscc_math_uint *denominator,
    int16_t *numerator_exponent, int16_t denominator_exponent)
{
    while (*numerator_exponent > denominator_exponent)
    {
        if (__riscc_math_compare(numerator, denominator, 4) >= 0)
            __riscc_math_subtract(numerator, denominator, 4);
        if (__riscc_math_is_zero(numerator, 4))
            return;
        __riscc_math_shift_left_one(numerator, 4);
        --*numerator_exponent;
    }
    if (__riscc_math_compare(numerator, denominator, 4) >= 0)
        __riscc_math_subtract(numerator, denominator, 4);
    if (__riscc_math_is_zero(numerator, 4))
        return;

    while (!(numerator->word[3] & UINT16_C(0x0010)))
    {
        __riscc_math_shift_left_one(numerator, 4);
        --*numerator_exponent;
    }
}

double fmod(double numerator, double denominator)
{
    riscc_double_shape left = {numerator};
    riscc_double_shape right = {denominator};
    riscc_math_uint x = {{left.word[0], left.word[1], left.word[2],
        (uint16_t)(left.word[3] & UINT16_C(0x7fff))}};
    riscc_math_uint y = {{right.word[0], right.word[1], right.word[2],
        (uint16_t)(right.word[3] & UINT16_C(0x7fff))}};
    uint16_t sign = left.word[3] & UINT16_C(0x8000);
    uint16_t x_field = x.word[3] >> 4;
    uint16_t y_field = y.word[3] >> 4;
    int16_t comparison = __riscc_math_compare(&x, &y, 4);
    int16_t x_exponent;
    int16_t y_exponent;

    if ((x_field == 0x7ff &&
            (x.word[3] & UINT16_C(0x000f) || x.word[2] || x.word[1] ||
                x.word[0])) ||
        (y_field == 0x7ff &&
            (y.word[3] & UINT16_C(0x000f) || y.word[2] || y.word[1] ||
                y.word[0])))
    {
        if (x_field != 0x7ff ||
            !(x.word[3] & UINT16_C(0x000f) || x.word[2] || x.word[1] ||
                x.word[0]))
            left = right;
        left.word[3] |= UINT16_C(0x0008);
        return left.value;
    }
    if (x_field == 0x7ff || __riscc_math_is_zero(&y, 4))
    {
        left.word[0] = 0;
        left.word[1] = 0;
        left.word[2] = 0;
        left.word[3] = UINT16_C(0x7ff8);
        return left.value;
    }
    if (y_field == 0x7ff || comparison < 0)
        return numerator;
    if (!comparison)
    {
        left.word[0] = 0;
        left.word[1] = 0;
        left.word[2] = 0;
        left.word[3] = sign;
        return left.value;
    }

    x_exponent = double_significand(&x, x_field);
    y_exponent = double_significand(&y, y_field);
    unsigned_fmod(&x, &y, &x_exponent, y_exponent);
    if (__riscc_math_is_zero(&x, 4))
    {
        left.word[0] = 0;
        left.word[1] = 0;
        left.word[2] = 0;
        left.word[3] = sign;
        return left.value;
    }

    if (x_exponent >= -1022)
        x.word[3] = (uint16_t)(x_exponent + 1023) << 4 |
            (x.word[3] & UINT16_C(0x000f));
    else
    {
        while (x_exponent < -1022)
        {
            __riscc_math_shift_right_one(&x, 4);
            ++x_exponent;
        }
        x.word[3] &= UINT16_C(0x000f);
    }
    left.word[0] = x.word[0];
    left.word[1] = x.word[1];
    left.word[2] = x.word[2];
    left.word[3] = sign | x.word[3];
    return left.value;
}

long double fmodl(long double numerator, long double denominator)
{
    return (long double)fmod((double)numerator, (double)denominator);
}

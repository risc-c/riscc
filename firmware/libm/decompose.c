#include <math.h>
#include <stdint.h>

#include "internal.h"

static void shift_float_left(riscc_float_shape *shape)
{
    shape->word[1] =
        (uint16_t)((shape->word[1] << 1) | (shape->word[0] >> 15));
    shape->word[0] <<= 1;
}

static void shift_double_left(riscc_double_shape *shape)
{
    shape->word[3] =
        (uint16_t)((shape->word[3] << 1) | (shape->word[2] >> 15));
    shape->word[2] =
        (uint16_t)((shape->word[2] << 1) | (shape->word[1] >> 15));
    shape->word[1] =
        (uint16_t)((shape->word[1] << 1) | (shape->word[0] >> 15));
    shape->word[0] <<= 1;
}

float modff(float value, float *integral)
{
    riscc_float_shape shape = {value};
    uint16_t exponent = (shape.word[1] >> 7) & 0xff;

    *integral = truncf(value);
    if (exponent == 0xff)
    {
        if ((shape.word[1] & UINT16_C(0x007f)) || shape.word[0])
            return value;
        shape.word[0] = 0;
        shape.word[1] &= UINT16_C(0x8000);
        return shape.value;
    }
    return copysignf(value - *integral, value);
}

double modf(double value, double *integral)
{
    riscc_double_shape shape = {value};
    uint16_t exponent = (shape.word[3] >> 4) & 0x7ff;

    *integral = trunc(value);
    if (exponent == 0x7ff)
    {
        if ((shape.word[3] & UINT16_C(0x000f)) || shape.word[2] ||
            shape.word[1] || shape.word[0])
            return value;
        shape.word[0] = 0;
        shape.word[1] = 0;
        shape.word[2] = 0;
        shape.word[3] &= UINT16_C(0x8000);
        return shape.value;
    }
    return copysign(value - *integral, value);
}

long double modfl(long double value, long double *integral)
{
    double integer;
    double fraction = modf((double)value, &integer);
    *integral = (long double)integer;
    return (long double)fraction;
}

float frexpf(float value, int16_t *result_exponent)
{
    riscc_float_shape shape = {value};
    uint16_t sign = shape.word[1] & UINT16_C(0x8000);
    uint16_t exponent = (shape.word[1] >> 7) & 0xff;
    int16_t unbiased;

    *result_exponent = 0;
    if (exponent == 0xff || !(shape.word[0] || (shape.word[1] & 0x7fff)))
        return value;
    shape.word[1] &= UINT16_C(0x7fff);
    if (exponent)
        unbiased = (int16_t)exponent - 127;
    else
    {
        unbiased = -126;
        while (!(shape.word[1] & UINT16_C(0x0080)))
        {
            shift_float_left(&shape);
            --unbiased;
        }
    }
    *result_exponent = unbiased + 1;
    shape.word[1] =
        sign | UINT16_C(0x3f00) | (shape.word[1] & UINT16_C(0x007f));
    return shape.value;
}

double frexp(double value, int16_t *result_exponent)
{
    riscc_double_shape shape = {value};
    uint16_t sign = shape.word[3] & UINT16_C(0x8000);
    uint16_t exponent = (shape.word[3] >> 4) & 0x7ff;
    int16_t unbiased;

    *result_exponent = 0;
    if (exponent == 0x7ff ||
        !(shape.word[0] || shape.word[1] || shape.word[2] ||
            (shape.word[3] & 0x7fff)))
        return value;
    shape.word[3] &= UINT16_C(0x7fff);
    if (exponent)
        unbiased = (int16_t)exponent - 1023;
    else
    {
        unbiased = -1022;
        while (!(shape.word[3] & UINT16_C(0x0010)))
        {
            shift_double_left(&shape);
            --unbiased;
        }
    }
    *result_exponent = unbiased + 1;
    shape.word[3] =
        sign | UINT16_C(0x3fe0) | (shape.word[3] & UINT16_C(0x000f));
    return shape.value;
}

long double frexpl(long double value, int16_t *result_exponent)
{
    return (long double)frexp((double)value, result_exponent);
}

static float multiply_float_power(float value, int16_t exponent)
{
    riscc_float_shape power = {.bits = 0};
    power.word[1] = (uint16_t)(exponent + 127) << 7;
    return value * power.value;
}

static double multiply_double_power(double value, int16_t exponent)
{
    riscc_double_shape power = {.bits = 0};
    power.word[3] = (uint16_t)(exponent + 1023) << 4;
    return value * power.value;
}

float scalbnf(float value, int16_t exponent)
{
    if (exponent > 127)
    {
        value = multiply_float_power(value, 127);
        exponent -= 127;
        if (exponent > 127)
        {
            value = multiply_float_power(value, 127);
            exponent -= 127;
            if (exponent > 127)
                exponent = 127;
        }
    }
    else if (exponent < -126)
    {
        value = multiply_float_power(value, -102);
        exponent += 102;
        if (exponent < -126)
        {
            value = multiply_float_power(value, -102);
            exponent += 102;
            if (exponent < -126)
                exponent = -126;
        }
    }
    return multiply_float_power(value, exponent);
}

double scalbn(double value, int16_t exponent)
{
    if (exponent > 1023)
    {
        value = multiply_double_power(value, 1023);
        exponent -= 1023;
        if (exponent > 1023)
        {
            value = multiply_double_power(value, 1023);
            exponent -= 1023;
            if (exponent > 1023)
                exponent = 1023;
        }
    }
    else if (exponent < -1022)
    {
        value = multiply_double_power(value, -969);
        exponent += 969;
        if (exponent < -1022)
        {
            value = multiply_double_power(value, -969);
            exponent += 969;
            if (exponent < -1022)
                exponent = -1022;
        }
    }
    return multiply_double_power(value, exponent);
}

long double scalbnl(long double value, int16_t exponent)
{
    return (long double)scalbn((double)value, exponent);
}

float ldexpf(float value, int16_t exponent)
{
    return scalbnf(value, exponent);
}

double ldexp(double value, int16_t exponent)
{
    return scalbn(value, exponent);
}

long double ldexpl(long double value, int16_t exponent)
{
    return (long double)scalbn((double)value, exponent);
}

float scalblnf(float value, int32_t exponent)
{
    if (exponent > INT16_MAX)
        exponent = INT16_MAX;
    else if (exponent < INT16_MIN)
        exponent = INT16_MIN;
    return scalbnf(value, (int16_t)exponent);
}

double scalbln(double value, int32_t exponent)
{
    if (exponent > INT16_MAX)
        exponent = INT16_MAX;
    else if (exponent < INT16_MIN)
        exponent = INT16_MIN;
    return scalbn(value, (int16_t)exponent);
}

long double scalblnl(long double value, int32_t exponent)
{
    return (long double)scalbln((double)value, exponent);
}

int16_t ilogbf(float value)
{
    riscc_float_shape shape = {value};
    uint16_t exponent = (shape.word[1] >> 7) & 0xff;
    int16_t result;

    if (!(shape.word[0] || (shape.word[1] & UINT16_C(0x7fff))))
        return FP_ILOGB0;
    if (exponent == 0xff)
        return FP_ILOGBNAN;
    if (exponent)
        return (int16_t)exponent - 127;
    result = -127;
    while (!(shape.word[1] & UINT16_C(0x0040)))
    {
        shift_float_left(&shape);
        --result;
    }
    return result;
}

int16_t ilogb(double value)
{
    riscc_double_shape shape = {value};
    uint16_t exponent = (shape.word[3] >> 4) & 0x7ff;
    int16_t result;

    if (!(shape.word[0] || shape.word[1] || shape.word[2] ||
            (shape.word[3] & UINT16_C(0x7fff))))
        return FP_ILOGB0;
    if (exponent == 0x7ff)
        return FP_ILOGBNAN;
    if (exponent)
        return (int16_t)exponent - 1023;
    result = -1023;
    while (!(shape.word[3] & UINT16_C(0x0008)))
    {
        shift_double_left(&shape);
        --result;
    }
    return result;
}

int16_t ilogbl(long double value)
{
    return ilogb((double)value);
}

float logbf(float value)
{
    riscc_float_shape shape = {value};
    uint16_t exponent = (shape.word[1] >> 7) & 0xff;

    if (!(shape.word[0] || (shape.word[1] & UINT16_C(0x7fff))))
    {
        shape.bits = UINT32_C(0xff800000);
        return shape.value;
    }
    if (exponent == 0xff)
    {
        shape.word[1] &= UINT16_C(0x7fff);
        if ((shape.word[1] & UINT16_C(0x007f)) || shape.word[0])
            shape.word[1] |= UINT16_C(0x0040);
        return shape.value;
    }
    return (float)ilogbf(value);
}

double logb(double value)
{
    riscc_double_shape shape = {value};
    uint16_t exponent = (shape.word[3] >> 4) & 0x7ff;

    if (!(shape.word[0] || shape.word[1] || shape.word[2] ||
            (shape.word[3] & UINT16_C(0x7fff))))
    {
        shape.bits = UINT64_C(0xfff0000000000000);
        return shape.value;
    }
    if (exponent == 0x7ff)
    {
        shape.word[3] &= UINT16_C(0x7fff);
        if ((shape.word[3] & UINT16_C(0x000f)) || shape.word[2] ||
            shape.word[1] || shape.word[0])
            shape.word[3] |= UINT16_C(0x0008);
        return shape.value;
    }
    return (double)ilogb(value);
}

long double logbl(long double value)
{
    return (long double)logb((double)value);
}

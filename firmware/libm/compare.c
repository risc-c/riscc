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

static float quiet_float(riscc_float_shape shape)
{
    shape.word[1] |= UINT16_C(0x0040);
    return shape.value;
}

static double quiet_double(riscc_double_shape shape)
{
    shape.word[3] |= UINT16_C(0x0008);
    return shape.value;
}

float fminf(float left, float right)
{
    riscc_float_shape left_shape = {left};
    riscc_float_shape right_shape = {right};

    if (float_is_nan(left_shape))
        return float_is_nan(right_shape) ? quiet_float(left_shape) : right;
    if (float_is_nan(right_shape))
        return left;
    if (left == right)
    {
        left_shape.word[1] |= right_shape.word[1] & UINT16_C(0x8000);
        return left_shape.value;
    }
    return left < right ? left : right;
}

double fmin(double left, double right)
{
    riscc_double_shape left_shape = {left};
    riscc_double_shape right_shape = {right};

    if (double_is_nan(left_shape))
        return double_is_nan(right_shape) ? quiet_double(left_shape) : right;
    if (double_is_nan(right_shape))
        return left;
    if (left == right)
    {
        left_shape.word[3] |= right_shape.word[3] & UINT16_C(0x8000);
        return left_shape.value;
    }
    return left < right ? left : right;
}

long double fminl(long double left, long double right)
{
    return (long double)fmin((double)left, (double)right);
}

float fmaxf(float left, float right)
{
    riscc_float_shape left_shape = {left};
    riscc_float_shape right_shape = {right};

    if (float_is_nan(left_shape))
        return float_is_nan(right_shape) ? quiet_float(left_shape) : right;
    if (float_is_nan(right_shape))
        return left;
    if (left == right)
    {
        left_shape.word[1] &= right_shape.word[1] | UINT16_C(0x7fff);
        return left_shape.value;
    }
    return left > right ? left : right;
}

double fmax(double left, double right)
{
    riscc_double_shape left_shape = {left};
    riscc_double_shape right_shape = {right};

    if (double_is_nan(left_shape))
        return double_is_nan(right_shape) ? quiet_double(left_shape) : right;
    if (double_is_nan(right_shape))
        return left;
    if (left == right)
    {
        left_shape.word[3] &= right_shape.word[3] | UINT16_C(0x7fff);
        return left_shape.value;
    }
    return left > right ? left : right;
}

long double fmaxl(long double left, long double right)
{
    return (long double)fmax((double)left, (double)right);
}

float fdimf(float left, float right)
{
    riscc_float_shape left_shape = {left};
    riscc_float_shape right_shape = {right};

    if (float_is_nan(left_shape))
        return quiet_float(left_shape);
    if (float_is_nan(right_shape))
        return quiet_float(right_shape);
    return left > right ? left - right : 0.0f;
}

double fdim(double left, double right)
{
    riscc_double_shape left_shape = {left};
    riscc_double_shape right_shape = {right};

    if (double_is_nan(left_shape))
        return quiet_double(left_shape);
    if (double_is_nan(right_shape))
        return quiet_double(right_shape);
    return left > right ? left - right : 0.0;
}

long double fdiml(long double left, long double right)
{
    return (long double)fdim((double)left, (double)right);
}

float nanf(const char *tag)
{
    riscc_float_shape result = {.bits = UINT32_C(0x7fc00000)};
    (void)tag;
    return result.value;
}

double nan(const char *tag)
{
    riscc_double_shape result = {.bits = UINT64_C(0x7ff8000000000000)};
    (void)tag;
    return result.value;
}

long double nanl(const char *tag)
{
    return (long double)nan(tag);
}

#include <math.h>
#include <stdint.h>

#include "internal.h"

float fabsf(float value)
{
    riscc_float_shape shape = {value};
    shape.word[1] &= UINT16_C(0x7fff);
    return shape.value;
}

double fabs(double value)
{
    riscc_double_shape shape = {value};
    shape.bits &= UINT64_C(0x7fffffffffffffff);
    return shape.value;
}

long double fabsl(long double value)
{
    return (long double)fabs((double)value);
}

float copysignf(float magnitude, float sign)
{
    riscc_float_shape mag = {magnitude};
    riscc_float_shape source = {sign};
    mag.word[1] =
        (mag.word[1] & UINT16_C(0x7fff)) | (source.word[1] & UINT16_C(0x8000));
    return mag.value;
}

double copysign(double magnitude, double sign)
{
    riscc_double_shape mag = {magnitude};
    riscc_double_shape source = {sign};
    mag.bits = (mag.bits & UINT64_C(0x7fffffffffffffff)) |
        (source.bits & UINT64_C(0x8000000000000000));
    return mag.value;
}

long double copysignl(long double magnitude, long double sign)
{
    return (long double)copysign((double)magnitude, (double)sign);
}

static uint32_t trunc_float_bits(riscc_float_shape shape)
{
    uint16_t exponent = (shape.word[1] >> 7) & 0xff;
    int16_t unbiased;
    uint16_t shift;
    uint32_t mask;

    if (exponent == 0xff)
        return shape.bits;
    unbiased = (int16_t)exponent - 127;
    if (unbiased < 0)
    {
        shape.word[0] = 0;
        shape.word[1] &= UINT16_C(0x8000);
        return shape.bits;
    }
    if (unbiased >= 23)
        return shape.bits;
    shift = (uint16_t)(23 - unbiased);
    mask = (UINT32_C(1) << shift) - 1;
    return shape.bits & ~mask;
}

static int16_t truncate_double(riscc_double_shape *shape)
{
    uint16_t exponent = (shape->word[3] >> 4) & 0x7ff;
    int16_t remaining = (int16_t)exponent - 1023;
    int16_t changed = 0;
    int16_t index;

    if (exponent == 0x7ff)
        return 0;
    if (remaining < 0)
    {
        changed = (shape->word[3] & UINT16_C(0x7fff)) || shape->word[2] ||
            shape->word[1] || shape->word[0];
        shape->word[0] = 0;
        shape->word[1] = 0;
        shape->word[2] = 0;
        shape->word[3] &= UINT16_C(0x8000);
        return changed;
    }
    if (remaining >= 52)
        return 0;

    if (remaining < 4)
    {
        uint16_t mask =
            (uint16_t)(UINT16_C(0x000f) << (4 - remaining)) &
            UINT16_C(0x000f);

        changed = (shape->word[3] & UINT16_C(0x000f) & ~mask) ||
            shape->word[2] || shape->word[1] || shape->word[0];
        shape->word[3] =
            (shape->word[3] & UINT16_C(0xfff0)) | (shape->word[3] & mask);
        shape->word[0] = 0;
        shape->word[1] = 0;
        shape->word[2] = 0;
        return changed;
    }

    remaining -= 4;
    for (index = 2; index >= 0; --index)
    {
        uint16_t mask;

        if (remaining >= 16)
        {
            remaining -= 16;
            continue;
        }
        mask = remaining
            ? (uint16_t)(UINT16_C(0xffff) << (16 - remaining))
            : 0;
        changed = (shape->word[index] & ~mask) != 0;
        shape->word[index] &= mask;
        while (index)
        {
            --index;
            changed |= shape->word[index] != 0;
            shape->word[index] = 0;
        }
        break;
    }
    return changed;
}

static void increment_double(riscc_double_shape *shape, uint16_t bit)
{
    uint16_t index = bit / 16;
    uint16_t addend = UINT16_C(1) << (bit % 16);
    uint16_t previous = shape->word[index];

    shape->word[index] += addend;
    if (shape->word[index] >= previous)
        return;
    while (++index < 4)
        if (++shape->word[index])
            return;
}

float truncf(float value)
{
    riscc_float_shape shape = {value};
    shape.bits = trunc_float_bits(shape);
    return shape.value;
}

double trunc(double value)
{
    riscc_double_shape shape = {value};
    truncate_double(&shape);
    return shape.value;
}

long double truncl(long double value)
{
    return (long double)trunc((double)value);
}

float floorf(float value)
{
    riscc_float_shape shape = {value};
    uint32_t integral = trunc_float_bits(shape);
    uint16_t exponent = (shape.word[1] >> 7) & 0xff;
    int16_t unbiased = (int16_t)exponent - 127;

    if (exponent == 0xff || integral == shape.bits)
        return value;
    if (!(shape.word[1] & UINT16_C(0x8000)))
    {
        shape.bits = integral;
        return shape.value;
    }
    if (unbiased < 0)
        shape.bits = UINT32_C(0xbf800000);
    else
        shape.bits = integral + (UINT32_C(1) << (23 - unbiased));
    return shape.value;
}

double floor(double value)
{
    riscc_double_shape shape = {value};
    uint16_t exponent = (shape.word[3] >> 4) & 0x7ff;
    int16_t unbiased = (int16_t)exponent - 1023;

    if (!truncate_double(&shape))
        return value;
    if (!(shape.word[3] & UINT16_C(0x8000)))
        return shape.value;
    if (unbiased < 0)
    {
        shape.word[0] = 0;
        shape.word[1] = 0;
        shape.word[2] = 0;
        shape.word[3] = UINT16_C(0xbff0);
    }
    else
        increment_double(&shape, (uint16_t)(52 - unbiased));
    return shape.value;
}

long double floorl(long double value)
{
    return (long double)floor((double)value);
}

float ceilf(float value)
{
    riscc_float_shape shape = {value};
    uint32_t integral = trunc_float_bits(shape);
    uint16_t exponent = (shape.word[1] >> 7) & 0xff;
    int16_t unbiased = (int16_t)exponent - 127;

    if (exponent == 0xff || integral == shape.bits)
        return value;
    if (shape.word[1] & UINT16_C(0x8000))
    {
        shape.bits = integral;
        return shape.value;
    }
    if (unbiased < 0)
        shape.bits = UINT32_C(0x3f800000);
    else
        shape.bits = integral + (UINT32_C(1) << (23 - unbiased));
    return shape.value;
}

double ceil(double value)
{
    riscc_double_shape shape = {value};
    uint16_t exponent = (shape.word[3] >> 4) & 0x7ff;
    int16_t unbiased = (int16_t)exponent - 1023;

    if (!truncate_double(&shape))
        return value;
    if (shape.word[3] & UINT16_C(0x8000))
        return shape.value;
    if (unbiased < 0)
    {
        shape.word[0] = 0;
        shape.word[1] = 0;
        shape.word[2] = 0;
        shape.word[3] = UINT16_C(0x3ff0);
    }
    else
        increment_double(&shape, (uint16_t)(52 - unbiased));
    return shape.value;
}

long double ceill(long double value)
{
    return (long double)ceil((double)value);
}

float roundf(float value)
{
    riscc_float_shape shape = {value};
    uint16_t sign = shape.word[1] & UINT16_C(0x8000);
    uint32_t magnitude = shape.bits & UINT32_C(0x7fffffff);
    uint16_t exponent = (shape.word[1] >> 7) & 0xff;
    int16_t unbiased = (int16_t)exponent - 127;
    uint16_t shift;
    uint32_t mask;

    if (exponent == 0xff || unbiased >= 23)
        return value;
    if (unbiased < -1)
    {
        shape.word[0] = 0;
        shape.word[1] = sign;
        return shape.value;
    }
    if (unbiased == -1)
    {
        shape.word[0] = 0;
        shape.word[1] = sign | UINT16_C(0x3f80);
        return shape.value;
    }
    shift = (uint16_t)(23 - unbiased);
    mask = (UINT32_C(1) << shift) - 1;
    magnitude &= ~mask;
    if (shape.bits & (UINT32_C(1) << (shift - 1)))
        magnitude += UINT32_C(1) << shift;
    shape.bits = magnitude;
    shape.word[1] |= sign;
    return shape.value;
}

double round(double value)
{
    riscc_double_shape shape = {value};
    uint16_t sign = shape.word[3] & UINT16_C(0x8000);
    uint16_t exponent = (shape.word[3] >> 4) & 0x7ff;
    int16_t unbiased = (int16_t)exponent - 1023;
    uint16_t round_bit;
    int16_t round_up;

    if (exponent == 0x7ff || unbiased >= 52)
        return value;
    if (unbiased < -1)
    {
        shape.word[0] = 0;
        shape.word[1] = 0;
        shape.word[2] = 0;
        shape.word[3] = sign;
        return shape.value;
    }
    if (unbiased == -1)
    {
        shape.word[0] = 0;
        shape.word[1] = 0;
        shape.word[2] = 0;
        shape.word[3] = sign | UINT16_C(0x3ff0);
        return shape.value;
    }
    round_bit = (uint16_t)(51 - unbiased);
    round_up =
        (shape.word[round_bit / 16] & (UINT16_C(1) << (round_bit % 16))) != 0;
    truncate_double(&shape);
    if (round_up)
        increment_double(&shape, (uint16_t)(52 - unbiased));
    return shape.value;
}

long double roundl(long double value)
{
    return (long double)round((double)value);
}

int32_t lroundf(float value)
{
    return (int32_t)roundf(value);
}

int32_t lround(double value)
{
    return (int32_t)round(value);
}

int32_t lroundl(long double value)
{
    return (int32_t)round((double)value);
}

int64_t llroundf(float value)
{
    return (int64_t)roundf(value);
}

int64_t llround(double value)
{
    return (int64_t)round(value);
}

int64_t llroundl(long double value)
{
    return (int64_t)round((double)value);
}

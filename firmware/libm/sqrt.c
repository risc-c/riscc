#include <math.h>
#include <stdint.h>

#include "internal.h"

static uint16_t significand_bit(
    const riscc_math_uint *significand, int16_t position)
{
    if (position < 0)
        return 0;
    return (significand->word[(uint16_t)position / 16] >>
               ((uint16_t)position % 16)) &
        1;
}

static void scaled_square_root(const riscc_math_uint *significand,
    uint16_t precision, uint16_t words, riscc_math_uint *root,
    riscc_math_uint *remainder)
{
    int16_t zero_bits = (int16_t)precision - 1;
    int16_t pair;

    *root = (riscc_math_uint){{0}};
    *remainder = (riscc_math_uint){{0}};

    /*
     * Compute floor(sqrt(significand << zero_bits)) one base-four digit at
     * a time. The small word loops avoid compiler-expanded 64-bit operations.
     */
    for (pair = (int16_t)precision - 1; pair >= 0; --pair)
    {
        riscc_math_uint trial;
        int16_t low_position = pair * 2;
        uint16_t input_pair =
            significand_bit(significand, low_position - zero_bits) |
            (significand_bit(
                 significand, low_position + 1 - zero_bits) << 1);

        __riscc_math_shift_left_two(remainder, words);
        remainder->word[0] |= (uint16_t)input_pair;
        __riscc_math_shift_left_one(root, words);

        trial = *root;
        __riscc_math_shift_left_one(&trial, words);
        trial.word[0] |= 1;
        if (__riscc_math_compare(remainder, &trial, words) >= 0)
        {
            __riscc_math_subtract(remainder, &trial, words);
            __riscc_math_increment(root, words);
        }
    }
}

float sqrtf(float value)
{
    riscc_float_shape shape = {value};
    uint16_t sign = shape.word[1] & UINT16_C(0x8000);
    uint32_t fraction = shape.bits & UINT32_C(0x007fffff);
    uint16_t exponent = (shape.word[1] >> 7) & 0xff;
    uint32_t significand;
    riscc_math_uint input = {{0}};
    riscc_math_uint root;
    riscc_math_uint remainder;
    int16_t unbiased;

    if (exponent == 0xff)
    {
        if (fraction)
            shape.word[1] |= UINT16_C(0x0040);
        else if (sign)
            shape.bits = UINT32_C(0x7fc00000);
        return shape.value;
    }
    if (!exponent && !fraction)
        return value;
    if (sign)
    {
        shape.bits = UINT32_C(0x7fc00000);
        return shape.value;
    }

    if (exponent)
    {
        significand = UINT32_C(0x00800000) | fraction;
        unbiased = (int16_t)exponent - 127;
    }
    else
    {
        significand = fraction;
        unbiased = -126;
        while (significand < UINT32_C(0x00800000))
        {
            significand <<= 1;
            --unbiased;
        }
    }
    if (unbiased % 2)
    {
        significand <<= 1;
        --unbiased;
    }

    input.word[0] = (uint16_t)significand;
    input.word[1] = (uint16_t)(significand >> 16);
    scaled_square_root(&input, 24, 2, &root, &remainder);
    if (__riscc_math_compare(&remainder, &root, 2) > 0)
        __riscc_math_increment(&root, 2);

    unbiased /= 2;
    if (root.word[1] & UINT16_C(0x0100))
    {
        __riscc_math_shift_right_one(&root, 2);
        ++unbiased;
    }
    shape.word[0] = root.word[0];
    shape.word[1] =
        (uint16_t)(unbiased + 127) << 7 | (root.word[1] & UINT16_C(0x007f));
    return shape.value;
}

double sqrt(double value)
{
    riscc_double_shape shape = {value};
    uint16_t sign = shape.word[3] & UINT16_C(0x8000);
    uint16_t fraction_high = shape.word[3] & UINT16_C(0x000f);
    uint16_t exponent = (shape.word[3] >> 4) & 0x7ff;
    riscc_math_uint input = {{0}};
    riscc_math_uint root;
    riscc_math_uint remainder;
    int16_t unbiased;

    if (exponent == 0x7ff)
    {
        if (fraction_high || shape.word[2] || shape.word[1] || shape.word[0])
            shape.word[3] |= UINT16_C(0x0008);
        else if (sign)
        {
            shape.word[0] = 0;
            shape.word[1] = 0;
            shape.word[2] = 0;
            shape.word[3] = UINT16_C(0x7ff8);
        }
        return shape.value;
    }
    if (!(fraction_high || shape.word[2] || shape.word[1] || shape.word[0]) &&
        !exponent)
        return value;
    if (sign)
    {
        shape.word[0] = 0;
        shape.word[1] = 0;
        shape.word[2] = 0;
        shape.word[3] = UINT16_C(0x7ff8);
        return shape.value;
    }

    input.word[0] = shape.word[0];
    input.word[1] = shape.word[1];
    input.word[2] = shape.word[2];
    input.word[3] = fraction_high;
    if (exponent)
    {
        input.word[3] |= UINT16_C(0x0010);
        unbiased = (int16_t)exponent - 1023;
    }
    else
    {
        unbiased = -1022;
        while (!(input.word[3] & UINT16_C(0x0010)))
        {
            __riscc_math_shift_left_one(&input, 4);
            --unbiased;
        }
    }
    if (unbiased % 2)
    {
        __riscc_math_shift_left_one(&input, 4);
        --unbiased;
    }

    scaled_square_root(&input, 53, 4, &root, &remainder);
    if (__riscc_math_compare(&remainder, &root, 4) > 0)
        __riscc_math_increment(&root, 4);

    unbiased /= 2;
    if (root.word[3] & UINT16_C(0x0020))
    {
        __riscc_math_shift_right_one(&root, 4);
        ++unbiased;
    }
    shape.word[0] = root.word[0];
    shape.word[1] = root.word[1];
    shape.word[2] = root.word[2];
    shape.word[3] =
        (uint16_t)(unbiased + 1023) << 4 | (root.word[3] & UINT16_C(0x000f));
    return shape.value;
}

long double sqrtl(long double value)
{
    return (long double)sqrt((double)value);
}

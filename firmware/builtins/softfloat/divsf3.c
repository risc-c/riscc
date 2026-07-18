#include "internal.h"

float __divsf3(float numerator, float denominator)
{
    float_shape a = {numerator};
    float_shape b = {denominator};
    u16 a_exponent = float_exponent(a);
    u16 b_exponent = float_exponent(b);
    u16 sign = (u16)(float_sign(a) ^ float_sign(b));
    u32_words a_significand = significand(a, a_exponent);
    u32_words b_significand = significand(b, b_exponent);
    u32_words remainder;
    u32_words quotient = {1, 0};
    s16 exponent;
    u16 bit;

    if (a_exponent == 255)
    {
        if (!float_fraction_is_zero(a))
            return float_quiet_nan(a);
        if (b_exponent == 255)
        {
            if (!float_fraction_is_zero(b))
                return float_quiet_nan(b);
            return float_qnan();
        }
        return float_infinity(sign);
    }
    if (b_exponent == 255)
    {
        if (!float_fraction_is_zero(b))
            return float_quiet_nan(b);
        return float_zero(sign);
    }
    if (words_is_zero(a_significand))
    {
        if (words_is_zero(b_significand))
            return float_qnan();
        return float_zero(sign);
    }
    if (words_is_zero(b_significand))
        return float_infinity(sign);

    exponent = a_exponent ? (s16)a_exponent - 127 : -126;
    a_significand = normalize_significand(a_significand, &exponent);
    {
        s16 b_unbiased = b_exponent ? (s16)b_exponent - 127 : -126;
        b_significand =
            normalize_significand(b_significand, &b_unbiased);
        exponent = (s16)(exponent - b_unbiased + 127);
    }

    if (words_compare(a_significand, b_significand) < 0)
    {
        remainder = words_shift_left_one(a_significand);
        --exponent;
    }
    else
        remainder = a_significand;
    remainder = words_subtract(remainder, b_significand);

    for (bit = 0; bit != 26; ++bit)
    {
        quotient = words_shift_left_one(quotient);
        remainder = words_shift_left_one(remainder);
        if (words_compare(remainder, b_significand) >= 0)
        {
            remainder = words_subtract(remainder, b_significand);
            quotient.low = (u16)(quotient.low | 1);
        }
    }
    if (!words_is_zero(remainder))
        quotient.low = (u16)(quotient.low | 1);

    return pack_float(sign, exponent, quotient);
}

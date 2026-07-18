#include "internal.h"

float __mulsf3(float left, float right)
{
    float_shape a = {left};
    float_shape b = {right};
    u16 a_exponent = float_exponent(a);
    u16 b_exponent = float_exponent(b);
    u16 sign = (u16)(float_sign(a) ^ float_sign(b));
    u32_words a_significand = significand(a, a_exponent);
    u32_words b_significand = significand(b, b_exponent);
    u48_words product;
    u32_words extended;
    s16 exponent;
    u16 shift;

    if (a_exponent == 255)
    {
        if (!float_fraction_is_zero(a))
            return float_quiet_nan(a);
        if (b_exponent == 255 && !float_fraction_is_zero(b))
            return float_quiet_nan(b);
        if (words_is_zero(b_significand))
            return float_qnan();
        return float_infinity(sign);
    }
    if (b_exponent == 255)
    {
        if (!float_fraction_is_zero(b))
            return float_quiet_nan(b);
        if (words_is_zero(a_significand))
            return float_qnan();
        return float_infinity(sign);
    }
    if (words_is_zero(a_significand) || words_is_zero(b_significand))
        return float_zero(sign);

    exponent = a_exponent ? (s16)a_exponent - 127 : -126;
    a_significand = normalize_significand(a_significand, &exponent);
    {
        s16 b_unbiased = b_exponent ? (s16)b_exponent - 127 : -126;
        b_significand =
            normalize_significand(b_significand, &b_unbiased);
        exponent = (s16)(exponent + b_unbiased + 127);
    }

    product = multiply_significands(a_significand, b_significand);
    if (product.word[2] & 0x8000)
    {
        shift = 21;
        ++exponent;
    }
    else
        shift = 20;
    extended = product_to_extended(product, shift);

    return pack_float(sign, exponent, extended);
}

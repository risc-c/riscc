#include "internal.h"

float __addsf3(float left, float right)
{
    float_shape a = {left};
    float_shape b = {right};
    u16 a_exponent = float_exponent(a);
    u16 b_exponent = float_exponent(b);
    u16 a_sign = float_sign(a);
    u16 b_sign = float_sign(b);
    u32_words a_significand;
    u32_words b_significand;
    u32_words result;
    s16 exponent;

    if (a_exponent == 255)
    {
        if (!float_fraction_is_zero(a))
            return float_quiet_nan(a);
        if (b_exponent == 255)
        {
            if (!float_fraction_is_zero(b))
                return float_quiet_nan(b);
            if (a_sign != b_sign)
                return float_qnan();
        }
        return left;
    }
    if (b_exponent == 255)
    {
        if (!float_fraction_is_zero(b))
            return float_quiet_nan(b);
        return right;
    }

    a_significand = significand(a, a_exponent);
    b_significand = significand(b, b_exponent);
    if (words_is_zero(a_significand))
    {
        if (words_is_zero(b_significand))
            return float_zero((u16)(a_sign & b_sign));
        return right;
    }
    if (words_is_zero(b_significand))
        return left;

    if (!a_exponent)
        a_exponent = 1;
    if (!b_exponent)
        b_exponent = 1;
    if (a_exponent < b_exponent ||
        (a_exponent == b_exponent &&
            words_compare(a_significand, b_significand) < 0))
    {
        u16 temporary_exponent = a_exponent;
        u16 temporary_sign = a_sign;
        u32_words temporary_significand = a_significand;

        a_exponent = b_exponent;
        a_sign = b_sign;
        a_significand = b_significand;
        b_exponent = temporary_exponent;
        b_sign = temporary_sign;
        b_significand = temporary_significand;
    }

    a_significand = extend_significand(a_significand);
    b_significand = extend_significand(b_significand);
    b_significand = words_shift_right_sticky(
        b_significand, (u16)(a_exponent - b_exponent));
    exponent = (s16)a_exponent;

    if (a_sign == b_sign)
    {
        result = words_add(a_significand, b_significand);
        if (result.high & 0x0800)
        {
            result = words_shift_right_sticky(result, 1);
            ++exponent;
        }
    }
    else
    {
        result = words_subtract(a_significand, b_significand);
        if (words_is_zero(result))
            return float_zero(0);
        while (!(result.high & 0x0400) && exponent > 1)
        {
            result = words_shift_left_one(result);
            --exponent;
        }
    }

    return pack_float(a_sign, exponent, result);
}

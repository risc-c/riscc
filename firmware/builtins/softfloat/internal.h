#ifndef RISCC_SOFTFLOAT_INTERNAL_H
#define RISCC_SOFTFLOAT_INTERNAL_H

/*
 * Binary32 support shaped for RISC-C's 16-bit datapath.
 *
 * Values wider than a register stay split into explicit little-endian limbs.
 * This keeps the compiler from introducing the wide shift and multiply
 * libcalls that these routines implement floating-point arithmetic to avoid.
 */

typedef __UINT16_TYPE__ u16;
typedef __INT16_TYPE__ s16;

typedef struct
{
    u16 low;
    u16 high;
} u32_words;

typedef struct
{
    u16 word[3];
} u48_words;

typedef union
{
    float value;
    u16 word[2];
} float_shape;

#define INLINE static __inline__ __attribute__((always_inline))

#define FLOAT_SIGN_MASK ((u16)0x8000)
#define FLOAT_FRAC_MASK ((u16)0x007f)
#define FLOAT_QUIET_BIT ((u16)0x0040)
#define FLOAT_INF_HIGH ((u16)0x7f80)
#define FLOAT_QNAN_HIGH ((u16)0x7fc0)

INLINE u16 words_is_zero(u32_words value)
{
    return (u16)((value.low | value.high) == 0);
}

INLINE s16 words_compare(u32_words left, u32_words right)
{
    if (left.high != right.high)
        return left.high < right.high ? -1 : 1;
    if (left.low != right.low)
        return left.low < right.low ? -1 : 1;
    return 0;
}

INLINE u32_words words_add(u32_words left, u32_words right)
{
    u32_words result;

    result.low = (u16)(left.low + right.low);
    result.high =
        (u16)(left.high + right.high + (result.low < left.low));
    return result;
}

INLINE u32_words words_subtract(u32_words left, u32_words right)
{
    u32_words result;
    u16 borrow = (u16)(left.low < right.low);

    result.low = (u16)(left.low - right.low);
    result.high = (u16)(left.high - right.high - borrow);
    return result;
}

INLINE u32_words words_shift_left_one(u32_words value)
{
    u32_words result;

    result.high = (u16)((value.high << 1) | (value.low >> 15));
    result.low = (u16)(value.low << 1);
    return result;
}

INLINE u32_words words_shift_right_one(u32_words value)
{
    u32_words result;

    result.low = (u16)((value.low >> 1) | (value.high << 15));
    result.high = (u16)(value.high >> 1);
    return result;
}

INLINE u32_words words_shift_right_sticky(u32_words value, u16 count)
{
    u16 sticky = 0;

    if (count >= 32)
    {
        value.low = (u16)!words_is_zero(value);
        value.high = 0;
        return value;
    }
    if (count >= 16)
    {
        sticky = (u16)(value.low != 0);
        value.low = value.high;
        value.high = 0;
        count = (u16)(count - 16);
    }
    while (count)
    {
        sticky = (u16)(sticky | (value.low & 1));
        value = words_shift_right_one(value);
        --count;
    }
    value.low = (u16)(value.low | sticky);
    return value;
}

INLINE u32_words significand(float_shape value, u16 exponent)
{
    u32_words result;

    result.low = value.word[0];
    result.high = (u16)(value.word[1] & FLOAT_FRAC_MASK);
    if (exponent)
        result.high = (u16)(result.high | 0x0080);
    return result;
}

INLINE u32_words extend_significand(u32_words value)
{
    u32_words result;

    result.high = (u16)((value.high << 3) | (value.low >> 13));
    result.low = (u16)(value.low << 3);
    return result;
}

INLINE u16 float_exponent(float_shape value)
{
    return (u16)((value.word[1] >> 7) & 0x00ff);
}

INLINE u16 float_sign(float_shape value)
{
    return (u16)(value.word[1] & FLOAT_SIGN_MASK);
}

INLINE u16 float_fraction_is_zero(float_shape value)
{
    return (u16)(((value.word[1] & FLOAT_FRAC_MASK) | value.word[0]) == 0);
}

INLINE float float_zero(u16 sign)
{
    float_shape result;

    result.word[0] = 0;
    result.word[1] = sign;
    return result.value;
}

INLINE float float_infinity(u16 sign)
{
    float_shape result;

    result.word[0] = 0;
    result.word[1] = (u16)(sign | FLOAT_INF_HIGH);
    return result.value;
}

INLINE float float_qnan(void)
{
    float_shape result;

    result.word[0] = 0;
    result.word[1] = FLOAT_QNAN_HIGH;
    return result.value;
}

INLINE float float_quiet_nan(float_shape value)
{
    value.word[1] = (u16)(value.word[1] | FLOAT_QUIET_BIT);
    return value.value;
}

INLINE u32_words normalize_significand(u32_words value, s16 *exponent)
{
    while (!(value.high & 0x0080))
    {
        value = words_shift_left_one(value);
        --*exponent;
    }
    return value;
}

/*
 * Pack a normalized significand carrying three round/guard/sticky bits.
 * Exponent is biased. Values at exponent one may still be subnormal.
 */
INLINE float pack_float(u16 sign, s16 exponent, u32_words extended)
{
    float_shape result;
    u16 round_bits;
    u16 increment;
    u32_words rounded;
    u32_words eight = {8, 0};

    if (exponent <= 0)
    {
        extended =
            words_shift_right_sticky(extended, (u16)(1 - exponent));
        exponent = 1;
    }

    round_bits = (u16)(extended.low & 7);
    increment = (u16)(round_bits > 4 ||
        (round_bits == 4 && (extended.low & 8)));
    rounded = increment ? words_add(extended, eight) : extended;

    /* Rounding 1.111... produces 10.000... at the next exponent. */
    if (rounded.high & 0x0800)
    {
        rounded.low = 0;
        rounded.high = 0x0400;
        ++exponent;
    }
    if (exponent >= 255)
        return float_infinity(sign);

    if (exponent == 1 && !(rounded.high & 0x0400))
        exponent = 0;

    result.word[0] =
        (u16)((rounded.low >> 3) | (rounded.high << 13));
    result.word[1] = (u16)(sign | ((u16)exponent << 7) |
        ((rounded.high >> 3) & FLOAT_FRAC_MASK));
    return result.value;
}

INLINE u48_words wide_add(u48_words left, u48_words right)
{
    u48_words result;
    u16 partial;
    u16 carry;

    result.word[0] = (u16)(left.word[0] + right.word[0]);
    carry = (u16)(result.word[0] < left.word[0]);

    partial = (u16)(left.word[1] + carry);
    carry = (u16)(partial < left.word[1]);
    result.word[1] = (u16)(partial + right.word[1]);
    carry = (u16)(carry | (result.word[1] < partial));

    result.word[2] = (u16)(left.word[2] + right.word[2] + carry);
    return result;
}

INLINE u48_words wide_shift_left_one(u48_words value)
{
    u48_words result;

    result.word[2] =
        (u16)((value.word[2] << 1) | (value.word[1] >> 15));
    result.word[1] =
        (u16)((value.word[1] << 1) | (value.word[0] >> 15));
    result.word[0] = (u16)(value.word[0] << 1);
    return result;
}

INLINE u48_words multiply_significands(
    u32_words left, u32_words right)
{
    u48_words multiplicand = {{left.low, left.high, 0}};
    u48_words product = {{0, 0, 0}};

    while (!words_is_zero(right))
    {
        if (right.low & 1)
            product = wide_add(product, multiplicand);
        multiplicand = wide_shift_left_one(multiplicand);
        right = words_shift_right_one(right);
    }
    return product;
}

INLINE u32_words product_to_extended(u48_words product, u16 shift)
{
    u32_words result;
    u16 discarded_mask = shift == 20 ? 0x000f : 0x001f;
    u16 low_shift = shift == 20 ? 4 : 5;
    u16 high_shift = shift == 20 ? 12 : 11;
    u16 sticky =
        (u16)(product.word[0] != 0 ||
            (product.word[1] & discarded_mask) != 0);

    result.low = (u16)((product.word[1] >> low_shift) |
        (product.word[2] << high_shift));
    result.high = (u16)(product.word[2] >> low_shift);
    result.low = (u16)(result.low | sticky);
    return result;
}

#endif

/*
 * Small integer runtime for the RISC-C freestanding ABI.
 *
 * The implementations deliberately operate on 16-bit limbs.  This prevents
 * the compiler from turning the body of a wide helper back into a call to the
 * same helper while the backend's native wide lowering is still minimal.
 */

typedef __UINT16_TYPE__ u16;
typedef __INT16_TYPE__ s16;
typedef __UINT32_TYPE__ u32;
typedef __INT32_TYPE__ s32;
typedef __UINT64_TYPE__ u64;
typedef __INT64_TYPE__ s64;

static u16 udivmod16(u16 numerator, u16 denominator, u16 *remainder)
{
    u16 quotient = 0;
    u16 rem = 0;
    u16 i;

    if (denominator == 0)
    {
        if (remainder)
            *remainder = numerator;
        return 0;
    }

    for (i = 0; i != 16; ++i)
    {
        u16 next = (u16)(numerator >> 15);
        u16 carry = (u16)(rem >> 15);
        numerator = (u16)(numerator << 1);
        rem = (u16)((rem << 1) | next);
        quotient = (u16)(quotient << 1);
        if (carry || rem >= denominator)
        {
            rem = (u16)(rem - denominator);
            quotient = (u16)(quotient | 1);
        }
    }

    if (remainder)
        *remainder = rem;
    return quotient;
}

static u16 abs16(s16 value)
{
    u16 bits = (u16)value;
    return value < 0 ? (u16)(0 - bits) : bits;
}

u16 __udivhi3(u16 numerator, u16 denominator)
{
    return udivmod16(numerator, denominator, (u16 *)0);
}

u16 __umodhi3(u16 numerator, u16 denominator)
{
    u16 remainder;
    (void)udivmod16(numerator, denominator, &remainder);
    return remainder;
}

u16 __udivmodhi4(u16 numerator, u16 denominator, u16 *remainder)
{
    return udivmod16(numerator, denominator, remainder);
}

s16 __divhi3(s16 numerator, s16 denominator)
{
    u16 quotient = udivmod16(abs16(numerator), abs16(denominator), (u16 *)0);
    if ((numerator < 0) != (denominator < 0))
        quotient = (u16)(0 - quotient);
    return (s16)quotient;
}

s16 __modhi3(s16 numerator, s16 denominator)
{
    u16 remainder;
    (void)udivmod16(abs16(numerator), abs16(denominator), &remainder);
    if (numerator < 0)
        remainder = (u16)(0 - remainder);
    return (s16)remainder;
}

s16 __divmodhi4(s16 numerator, s16 denominator, s16 *remainder)
{
    u16 unsigned_remainder;
    u16 quotient =
        udivmod16(abs16(numerator), abs16(denominator), &unsigned_remainder);
    if ((numerator < 0) != (denominator < 0))
        quotient = (u16)(0 - quotient);
    if (numerator < 0)
        unsigned_remainder = (u16)(0 - unsigned_remainder);
    if (remainder)
        *remainder = (s16)unsigned_remainder;
    return (s16)quotient;
}

typedef union
{
    u32 all;
    u16 word[2];
} u32_words;

static u32_words words32(u32 value)
{
    u32_words result;
    result.all = value;
    return result;
}

static u32_words zero32(void)
{
    u32_words result;
    result.word[0] = 0;
    result.word[1] = 0;
    return result;
}

static int cmp32(u32_words left, u32_words right)
{
    if (left.word[1] != right.word[1])
        return left.word[1] < right.word[1] ? -1 : 1;
    if (left.word[0] != right.word[0])
        return left.word[0] < right.word[0] ? -1 : 1;
    return 0;
}

static u32_words add32(u32_words left, u32_words right)
{
    u32_words result;
    result.word[0] = (u16)(left.word[0] + right.word[0]);
    result.word[1] = (u16)(left.word[1] + right.word[1] +
        (result.word[0] < left.word[0]));
    return result;
}

static u32_words sub32(u32_words left, u32_words right)
{
    u32_words result;
    u16 borrow = left.word[0] < right.word[0];
    result.word[0] = (u16)(left.word[0] - right.word[0]);
    result.word[1] = (u16)(left.word[1] - right.word[1] - borrow);
    return result;
}

static u32_words neg32(u32_words value)
{
    u32_words result;
    result.word[0] = (u16)(0 - value.word[0]);
    result.word[1] = (u16)(0 - value.word[1] - (value.word[0] != 0));
    return result;
}

static u32_words shl32(u32_words value)
{
    u32_words result;
    result.word[1] =
        (u16)((value.word[1] << 1) | (value.word[0] >> 15));
    result.word[0] = (u16)(value.word[0] << 1);
    return result;
}

static u32_words shr32(u32_words value)
{
    u32_words result;
    result.word[0] =
        (u16)((value.word[0] >> 1) | (value.word[1] << 15));
    result.word[1] = (u16)(value.word[1] >> 1);
    return result;
}

static u32_words udivmod32(u32_words numerator, u32_words denominator,
    u32_words *remainder)
{
    u32_words quotient = zero32();
    u32_words rem = zero32();
    u16 i;

    if (denominator.word[0] == 0 && denominator.word[1] == 0)
    {
        if (remainder)
            *remainder = numerator;
        return quotient;
    }

    for (i = 0; i != 32; ++i)
    {
        u16 next = (u16)(numerator.word[1] >> 15);
        u16 carry = (u16)(rem.word[1] >> 15);
        numerator = shl32(numerator);
        rem = shl32(rem);
        rem.word[0] = (u16)(rem.word[0] | next);
        quotient = shl32(quotient);
        if (carry || cmp32(rem, denominator) >= 0)
        {
            rem = sub32(rem, denominator);
            quotient.word[0] = (u16)(quotient.word[0] | 1);
        }
    }

    if (remainder)
        *remainder = rem;
    return quotient;
}

u32 __mulsi3(u32 left, u32 right)
{
    u32_words multiplicand = words32(left);
    u32_words multiplier = words32(right);
    u32_words result = zero32();
    u16 i;
    for (i = 0; i != 32; ++i)
    {
        if (multiplier.word[0] & 1)
            result = add32(result, multiplicand);
        multiplicand = shl32(multiplicand);
        multiplier = shr32(multiplier);
    }
    return result.all;
}

s32 __ashlsi3(s32 value, int count)
{
    u32_words bits = words32((u32)value);
    while (count-- > 0)
        bits = shl32(bits);
    return (s32)bits.all;
}

u32 __lshrsi3(u32 value, int count)
{
    u32_words bits = words32(value);
    while (count-- > 0)
        bits = shr32(bits);
    return bits.all;
}

s32 __ashrsi3(s32 value, int count)
{
    u32_words bits = words32((u32)value);
    u16 sign = (u16)(bits.word[1] & 0x8000u);
    while (count-- > 0)
    {
        bits = shr32(bits);
        bits.word[1] = (u16)(bits.word[1] | sign);
    }
    return (s32)bits.all;
}

u32 __udivmodsi4(u32 numerator, u32 denominator, u32 *remainder)
{
    u32_words rem;
    u32_words quotient =
        udivmod32(words32(numerator), words32(denominator), &rem);
    if (remainder)
        *remainder = rem.all;
    return quotient.all;
}

u32 __udivsi3(u32 numerator, u32 denominator)
{
    return udivmod32(words32(numerator), words32(denominator),
        (u32_words *)0)
        .all;
}

u32 __umodsi3(u32 numerator, u32 denominator)
{
    u32_words remainder;
    (void)udivmod32(words32(numerator), words32(denominator), &remainder);
    return remainder.all;
}

s32 __divmodsi4(s32 numerator, s32 denominator, s32 *remainder)
{
    u32_words left = words32((u32)numerator);
    u32_words right = words32((u32)denominator);
    u16 left_negative = (u16)(left.word[1] >> 15);
    u16 right_negative = (u16)(right.word[1] >> 15);
    u32_words rem;
    u32_words quotient;

    if (left_negative)
        left = neg32(left);
    if (right_negative)
        right = neg32(right);
    quotient = udivmod32(left, right, &rem);
    if (left_negative != right_negative)
        quotient = neg32(quotient);
    if (left_negative)
        rem = neg32(rem);
    if (remainder)
        *remainder = (s32)rem.all;
    return (s32)quotient.all;
}

s32 __divsi3(s32 numerator, s32 denominator)
{
    return __divmodsi4(numerator, denominator, (s32 *)0);
}

s32 __modsi3(s32 numerator, s32 denominator)
{
    s32 remainder;
    (void)__divmodsi4(numerator, denominator, &remainder);
    return remainder;
}

s32 __negsi2(s32 value)
{
    return (s32)neg32(words32((u32)value)).all;
}

typedef union
{
    u64 all;
    u16 word[4];
} u64_words;

static u64_words words64(u64 value)
{
    u64_words result;
    result.all = value;
    return result;
}

static u64_words zero64(void)
{
    u64_words result;
    u16 i;
    for (i = 0; i != 4; ++i)
        result.word[i] = 0;
    return result;
}

static int cmp64(u64_words left, u64_words right)
{
    int i;
    for (i = 3; i >= 0; --i)
    {
        if (left.word[i] != right.word[i])
            return left.word[i] < right.word[i] ? -1 : 1;
    }
    return 0;
}

static u64_words add64(u64_words left, u64_words right)
{
    u64_words result;
    u16 carry = 0;
    u16 i;
    for (i = 0; i != 4; ++i)
    {
        u16 partial = (u16)(left.word[i] + carry);
        u16 carry0 = partial < left.word[i];
        result.word[i] = (u16)(partial + right.word[i]);
        carry = (u16)(carry0 || result.word[i] < partial);
    }
    return result;
}

static u64_words sub64(u64_words left, u64_words right)
{
    u64_words result;
    u16 borrow = 0;
    u16 i;
    for (i = 0; i != 4; ++i)
    {
        u16 partial = (u16)(left.word[i] - borrow);
        u16 borrow0 = left.word[i] < borrow;
        result.word[i] = (u16)(partial - right.word[i]);
        borrow = (u16)(borrow0 || partial < right.word[i]);
    }
    return result;
}

static u64_words neg64(u64_words value)
{
    u64_words result;
    u16 carry = 1;
    u16 i;
    for (i = 0; i != 4; ++i)
    {
        u16 inverted = (u16)~value.word[i];
        result.word[i] = (u16)(inverted + carry);
        carry = (u16)(carry && result.word[i] == 0);
    }
    return result;
}

static u64_words shl64(u64_words value)
{
    u64_words result;
    u16 carry = 0;
    u16 i;
    for (i = 0; i != 4; ++i)
    {
        u16 next = (u16)(value.word[i] >> 15);
        result.word[i] = (u16)((value.word[i] << 1) | carry);
        carry = next;
    }
    return result;
}

static u64_words shr64(u64_words value)
{
    u64_words result;
    u16 carry = 0;
    int i;
    for (i = 3; i >= 0; --i)
    {
        u16 next = (u16)(value.word[i] & 1);
        result.word[i] = (u16)((value.word[i] >> 1) | (carry << 15));
        carry = next;
    }
    return result;
}

static u64_words udivmod64(u64_words numerator, u64_words denominator,
    u64_words *remainder)
{
    u64_words quotient = zero64();
    u64_words rem = zero64();
    u16 denominator_nonzero = 0;
    u16 i;

    for (i = 0; i != 4; ++i)
        denominator_nonzero = (u16)(denominator_nonzero | denominator.word[i]);
    if (!denominator_nonzero)
    {
        if (remainder)
            *remainder = numerator;
        return quotient;
    }

    for (i = 0; i != 64; ++i)
    {
        u16 next = (u16)(numerator.word[3] >> 15);
        u16 carry = (u16)(rem.word[3] >> 15);
        numerator = shl64(numerator);
        rem = shl64(rem);
        rem.word[0] = (u16)(rem.word[0] | next);
        quotient = shl64(quotient);
        if (carry || cmp64(rem, denominator) >= 0)
        {
            rem = sub64(rem, denominator);
            quotient.word[0] = (u16)(quotient.word[0] | 1);
        }
    }

    if (remainder)
        *remainder = rem;
    return quotient;
}

s64 __muldi3(s64 left, s64 right)
{
    u64_words multiplicand = words64((u64)left);
    u64_words multiplier = words64((u64)right);
    u64_words result = zero64();
    u16 i;
    for (i = 0; i != 64; ++i)
    {
        if (multiplier.word[0] & 1)
            result = add64(result, multiplicand);
        multiplicand = shl64(multiplicand);
        multiplier = shr64(multiplier);
    }
    return (s64)result.all;
}

s64 __ashldi3(s64 value, int count)
{
    u64_words bits = words64((u64)value);
    while (count-- > 0)
        bits = shl64(bits);
    return (s64)bits.all;
}

u64 __lshrdi3(u64 value, int count)
{
    u64_words bits = words64(value);
    while (count-- > 0)
        bits = shr64(bits);
    return bits.all;
}

s64 __ashrdi3(s64 value, int count)
{
    u64_words bits = words64((u64)value);
    u16 sign = (u16)(bits.word[3] & 0x8000u);
    while (count-- > 0)
    {
        bits = shr64(bits);
        bits.word[3] = (u16)(bits.word[3] | sign);
    }
    return (s64)bits.all;
}

u64 __udivmoddi4(u64 numerator, u64 denominator, u64 *remainder)
{
    u64_words rem;
    u64_words quotient =
        udivmod64(words64(numerator), words64(denominator), &rem);
    if (remainder)
        *remainder = rem.all;
    return quotient.all;
}

u64 __udivdi3(u64 numerator, u64 denominator)
{
    return udivmod64(words64(numerator), words64(denominator),
        (u64_words *)0)
        .all;
}

u64 __umoddi3(u64 numerator, u64 denominator)
{
    u64_words remainder;
    (void)udivmod64(words64(numerator), words64(denominator), &remainder);
    return remainder.all;
}

s64 __divmoddi4(s64 numerator, s64 denominator, s64 *remainder)
{
    u64_words left = words64((u64)numerator);
    u64_words right = words64((u64)denominator);
    u16 left_negative = (u16)(left.word[3] >> 15);
    u16 right_negative = (u16)(right.word[3] >> 15);
    u64_words rem;
    u64_words quotient;

    if (left_negative)
        left = neg64(left);
    if (right_negative)
        right = neg64(right);
    quotient = udivmod64(left, right, &rem);
    if (left_negative != right_negative)
        quotient = neg64(quotient);
    if (left_negative)
        rem = neg64(rem);
    if (remainder)
        *remainder = (s64)rem.all;
    return (s64)quotient.all;
}

s64 __divdi3(s64 numerator, s64 denominator)
{
    return __divmoddi4(numerator, denominator, (s64 *)0);
}

s64 __moddi3(s64 numerator, s64 denominator)
{
    s64 remainder;
    (void)__divmoddi4(numerator, denominator, &remainder);
    return remainder;
}

s64 __negdi2(s64 value)
{
    return (s64)neg64(words64((u64)value)).all;
}

int __ucmpdi2(u64 left, u64 right)
{
    return cmp64(words64(left), words64(right)) + 1;
}

int __cmpdi2(s64 left, s64 right)
{
    u64_words left_bits = words64((u64)left);
    u64_words right_bits = words64((u64)right);
    u16 left_negative = (u16)(left_bits.word[3] >> 15);
    u16 right_negative = (u16)(right_bits.word[3] >> 15);
    if (left_negative != right_negative)
        return left_negative ? 0 : 2;
    return cmp64(left_bits, right_bits) + 1;
}

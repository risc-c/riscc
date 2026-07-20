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

static u16 abs16(s16 value)
{
    u16 bits = (u16)value;
    return value < 0 ? (u16)(0 - bits) : bits;
}

u16 __udivhi3(u16 numerator, u16 denominator);
u16 __umodhi3(u16 numerator, u16 denominator);
u16 __udivmodhi4(u16 numerator, u16 denominator, u16 *remainder);

s16 __divhi3(s16 numerator, s16 denominator)
{
    u16 quotient = __udivhi3(abs16(numerator), abs16(denominator));
    if ((numerator < 0) != (denominator < 0))
        quotient = (u16)(0 - quotient);
    return (s16)quotient;
}

s16 __modhi3(s16 numerator, s16 denominator)
{
    u16 remainder;
    remainder = __umodhi3(abs16(numerator), abs16(denominator));
    if (numerator < 0)
        remainder = (u16)(0 - remainder);
    return (s16)remainder;
}

s16 __divmodhi4(s16 numerator, s16 denominator, s16 *remainder)
{
    u16 unsigned_remainder;
    u16 quotient = __udivmodhi4(
        abs16(numerator), abs16(denominator), &unsigned_remainder);
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

static u32_words neg32(u32_words value)
{
    u32_words result;
    result.word[0] = (u16)(0 - value.word[0]);
    result.word[1] = (u16)(0 - value.word[1] - (value.word[0] != 0));
    return result;
}

u32 __udivmodsi4(u32 numerator, u32 denominator, u32 *remainder);

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
    quotient.all = __udivmodsi4(left.all, right.all, &rem.all);
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

u64 __udivmoddi4(u64 numerator, u64 denominator, u64 *remainder);

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
    quotient.all = __udivmoddi4(left.all, right.all, &rem.all);
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

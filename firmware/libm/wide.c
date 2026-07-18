#include "internal.h"

int16_t __riscc_math_compare(const riscc_math_uint *left,
    const riscc_math_uint *right, uint16_t words)
{
    while (words)
    {
        --words;
        if (left->word[words] != right->word[words])
            return left->word[words] > right->word[words] ? 1 : -1;
    }
    return 0;
}

int16_t __riscc_math_is_zero(
    const riscc_math_uint *value, uint16_t words)
{
    uint16_t index;

    for (index = 0; index < words; ++index)
        if (value->word[index])
            return 0;
    return 1;
}

void __riscc_math_increment(riscc_math_uint *value, uint16_t words)
{
    uint16_t index;

    for (index = 0; index < words; ++index)
        if (++value->word[index])
            return;
}

void __riscc_math_shift_left_one(riscc_math_uint *value, uint16_t words)
{
    uint16_t carry = 0;
    uint16_t index;

    for (index = 0; index < words; ++index)
    {
        uint16_t next = value->word[index] >> 15;
        value->word[index] = (uint16_t)(value->word[index] << 1) | carry;
        carry = next;
    }
}

void __riscc_math_shift_left_two(riscc_math_uint *value, uint16_t words)
{
    uint16_t carry = 0;
    uint16_t index;

    for (index = 0; index < words; ++index)
    {
        uint16_t next = value->word[index] >> 14;
        value->word[index] = (uint16_t)(value->word[index] << 2) | carry;
        carry = next;
    }
}

void __riscc_math_shift_right_one(riscc_math_uint *value, uint16_t words)
{
    uint16_t carry = 0;

    while (words)
    {
        uint16_t next;

        --words;
        next = (uint16_t)(value->word[words] & 1) << 15;
        value->word[words] = (value->word[words] >> 1) | carry;
        carry = next;
    }
}

void __riscc_math_subtract(
    riscc_math_uint *left, const riscc_math_uint *right, uint16_t words)
{
    uint16_t borrow = 0;
    uint16_t index;

    for (index = 0; index < words; ++index)
    {
        uint16_t minuend = left->word[index];
        uint16_t subtrahend = right->word[index];
        uint16_t next_borrow =
            minuend < subtrahend || (borrow && minuend == subtrahend);

        left->word[index] = minuend - subtrahend - borrow;
        borrow = next_borrow;
    }
}

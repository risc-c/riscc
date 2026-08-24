#include "../libm/internal.h"

int16_t __riscc_math_compare(const riscc_math_uint *left,
    const riscc_math_uint *right, uint16_t words)
{
    while (words)
    {
        --words;
        if (left->word[words] != right->word[words])
            return left->word[words] < right->word[words] ? -1 : 1;
    }
    return 0;
}

int16_t __riscc_math_is_zero(
    const riscc_math_uint *value, uint16_t words)
{
    uint16_t i;
    for (i = 0; i != words; ++i)
        if (value->word[i])
            return 0;
    return 1;
}

void __riscc_math_increment(riscc_math_uint *value, uint16_t words)
{
    uint16_t i;
    for (i = 0; i != words; ++i)
    {
        ++value->word[i];
        if (value->word[i])
            return;
    }
}

void __riscc_math_shift_left_one(riscc_math_uint *value, uint16_t words)
{
    uint16_t carry = 0;
    uint16_t i;
    for (i = 0; i != words; ++i)
    {
        uint16_t current = value->word[i];
        value->word[i] = (uint16_t)(current << 1) | carry;
        carry = current >> 15;
    }
}

void __riscc_math_shift_left_two(riscc_math_uint *value, uint16_t words)
{
    __riscc_math_shift_left_one(value, words);
    __riscc_math_shift_left_one(value, words);
}

void __riscc_math_shift_right_one(riscc_math_uint *value, uint16_t words)
{
    uint16_t carry = 0;
    while (words)
    {
        uint16_t current;
        --words;
        current = value->word[words];
        value->word[words] = (current >> 1) | carry;
        carry = (uint16_t)(current << 15);
    }
}

void __riscc_math_subtract(riscc_math_uint *left,
    const riscc_math_uint *right, uint16_t words)
{
    uint16_t borrow = 0;
    uint16_t i;
    for (i = 0; i != words; ++i)
    {
        uint16_t old = left->word[i];
        uint16_t subtrahend = (uint16_t)(right->word[i] + borrow);
        uint16_t wrapped = subtrahend < right->word[i];
        left->word[i] = (uint16_t)(old - subtrahend);
        borrow = (uint16_t)(wrapped || old < subtrahend);
    }
}

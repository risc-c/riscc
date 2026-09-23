#include "../libm/internal.h"

int __riscc_math_compare(const riscc_math_uint *left,
    const riscc_math_uint *right, unsigned int words)
{
    while (words)
    {
        --words;
        if (left->limb[words] != right->limb[words])
            return left->limb[words] < right->limb[words] ? -1 : 1;
    }
    return 0;
}

int __riscc_math_is_zero(
    const riscc_math_uint *value, unsigned int words)
{
    unsigned int i;
    for (i = 0; i != words; ++i)
        if (value->limb[i])
            return 0;
    return 1;
}

void __riscc_math_increment(riscc_math_uint *value, unsigned int words)
{
    unsigned int i;
    for (i = 0; i != words; ++i)
    {
        ++value->limb[i];
        if (value->limb[i])
            return;
    }
}

void __riscc_math_shift_left_one(riscc_math_uint *value, unsigned int words)
{
    unsigned int previous = 0;
    unsigned int i;
    for (i = 0; i != words; ++i)
    {
        unsigned int current = value->limb[i];
        value->limb[i] = (current << 1) | (previous >> 31);
        previous = current;
    }
}

void __riscc_math_shift_left_two(riscc_math_uint *value, unsigned int words)
{
    unsigned int previous = 0;
    unsigned int i;
    for (i = 0; i != words; ++i)
    {
        unsigned int current = value->limb[i];
        value->limb[i] = (current << 2) | (previous >> 30);
        previous = current;
    }
}

void __riscc_math_shift_right_one(riscc_math_uint *value, unsigned int words)
{
    unsigned int previous = 0;
    while (words)
    {
        unsigned int current;
        --words;
        current = value->limb[words];
        value->limb[words] = (current >> 1) | (previous << 31);
        previous = current;
    }
}

void __riscc_math_subtract(riscc_math_uint *left,
    const riscc_math_uint *right, unsigned int words)
{
    unsigned int borrow = 0;
    unsigned int i;
    for (i = 0; i != words; ++i)
    {
        unsigned int old = left->limb[i];
        unsigned int subtrahend = right->limb[i] + borrow;
        unsigned int wrapped = subtrahend < right->limb[i];
        left->limb[i] = old - subtrahend;
        borrow = wrapped | (old < subtrahend);
    }
}

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

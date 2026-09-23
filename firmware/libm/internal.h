#ifndef RISCC_LIBM_INTERNAL_H
#define RISCC_LIBM_INTERNAL_H

#include <stdint.h>

#define RISCC_MATH_WORDS (8 / sizeof(unsigned int))
#define RISCC_MATH_FLOAT_WORDS (4 / sizeof(unsigned int))

typedef union
{
    float value;
    uint32_t bits;
    uint16_t word[2];
} riscc_float_shape;

typedef union
{
    double value;
    uint64_t bits;
    uint16_t word[4];
} riscc_double_shape;

typedef union
{
    /* Fixed 16-bit views for IEEE fields; native limbs for arithmetic. */
    uint16_t word[4];
    unsigned int limb[RISCC_MATH_WORDS];
} riscc_math_uint;

int __riscc_math_compare(const riscc_math_uint *left,
    const riscc_math_uint *right, unsigned int words);
int __riscc_math_is_zero(
    const riscc_math_uint *value, unsigned int words);
void __riscc_math_increment(riscc_math_uint *value, unsigned int words);
void __riscc_math_shift_left_one(riscc_math_uint *value, unsigned int words);
void __riscc_math_shift_left_two(riscc_math_uint *value, unsigned int words);
void __riscc_math_shift_right_one(riscc_math_uint *value, unsigned int words);
void __riscc_math_subtract(
    riscc_math_uint *left, const riscc_math_uint *right, unsigned int words);

#endif

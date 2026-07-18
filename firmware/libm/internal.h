#ifndef RISCC_LIBM_INTERNAL_H
#define RISCC_LIBM_INTERNAL_H

#include <stdint.h>

#define RISCC_MATH_WORDS 4

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
    uint16_t word[RISCC_MATH_WORDS];
} riscc_double_shape;

typedef struct
{
    /* Little-endian limbs: word[0] is the least-significant 16 bits. */
    uint16_t word[RISCC_MATH_WORDS];
} riscc_math_uint;

int16_t __riscc_math_compare(const riscc_math_uint *left,
    const riscc_math_uint *right, uint16_t words);
int16_t __riscc_math_is_zero(
    const riscc_math_uint *value, uint16_t words);
void __riscc_math_increment(riscc_math_uint *value, uint16_t words);
void __riscc_math_shift_left_one(riscc_math_uint *value, uint16_t words);
void __riscc_math_shift_left_two(riscc_math_uint *value, uint16_t words);
void __riscc_math_shift_right_one(riscc_math_uint *value, uint16_t words);
void __riscc_math_subtract(
    riscc_math_uint *left, const riscc_math_uint *right, uint16_t words);

#endif

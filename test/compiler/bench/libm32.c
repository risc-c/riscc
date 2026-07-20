#include "bench.h"

#include <math.h>

typedef union
{
    float value;
    uint32_t bits;
} float_bits;

static volatile float inputs[8] =
{
    1.25f, -2.75f, 3.5f, -0.625f,
    7.75f, 0.375f, -5.125f, 12.0f,
};

static uint32_t mix_float(uint32_t hash, float value)
{
    float_bits shape = {value};
    hash = (hash << 5) | (hash >> 27);
    return hash ^ shape.bits;
}

BENCH_NOINLINE static uint16_t common_libm32(void)
{
    float integral;
    float fraction;
    float normalized;
    float value;
    int exponent;
    long rounded;
    uint32_t hash = UINT32_C(0x6a09e667);

    hash = mix_float(hash, fabsf(inputs[1]));
    hash = mix_float(hash, copysignf(inputs[0], inputs[1]));
    hash = mix_float(hash, truncf(inputs[4]));
    hash = mix_float(hash, floorf(inputs[1]));
    hash = mix_float(hash, ceilf(inputs[2]));
    hash = mix_float(hash, roundf(inputs[6]));
    rounded = lroundf(inputs[4]);
    hash ^= (uint32_t)rounded;

    hash = mix_float(hash, sqrtf(inputs[7]));
    hash = mix_float(hash, fmodf(inputs[4], inputs[2]));
    hash = mix_float(hash, fminf(inputs[1], inputs[3]));
    hash = mix_float(hash, fmaxf(inputs[0], inputs[2]));
    hash = mix_float(hash, fdimf(inputs[2], inputs[0]));

    fraction = modff(inputs[1], &integral);
    hash = mix_float(hash, fraction);
    hash = mix_float(hash, integral);
    normalized = frexpf(inputs[4], &exponent);
    hash = mix_float(hash, normalized);
    hash ^= (uint16_t)exponent;
    hash = mix_float(hash, ldexpf(normalized, exponent));
    hash = mix_float(hash, scalbnf(inputs[5], 4));
    hash ^= (uint16_t)ilogbf(inputs[6]);
    hash = mix_float(hash, logbf(inputs[7]));
    hash = mix_float(hash, nextafterf(inputs[0], inputs[2]));

    value = inputs[0];
    if (isfinite(value) && isnormal(value) && !isnan(value) &&
        !isinf(value) && isless(value, inputs[2]))
        hash ^= UINT32_C(0x3c6ef372);

    return bench_fold32(hash);
}

int main(void)
{
    bench_finish(common_libm32(), UINT16_C(0x5430));
}

#include <math.h>
#include <stdint.h>

#include "test.h"

typedef union
{
    float value;
    uint32_t bits;
} float_shape;

typedef union
{
    double value;
    uint64_t bits;
} double_shape;

static volatile float float_half = 0.5f;
static volatile float float_two = 2.0f;
static volatile float float_five_and_half = 5.5f;
static volatile double double_half = 0.5;
static volatile double double_two = 2.0;
static volatile double double_five_and_half = 5.5;

static uint32_t float_bits(float value)
{
    float_shape shape = {value};
    return shape.bits;
}

static uint64_t double_bits(double value)
{
    double_shape shape = {value};
    return shape.bits;
}

int main(void)
{
    float_shape float_infinity = {.bits = UINT32_C(0x7f800000)};
    float_shape float_maximum = {.bits = UINT32_C(0x7f7fffff)};
    float_shape float_nan = {.bits = UINT32_C(0x7fc00001)};
    float_shape float_subnormal = {.bits = UINT32_C(1)};
    double_shape double_infinity = {.bits = UINT64_C(0x7ff0000000000000)};
    double_shape double_maximum = {.bits = UINT64_C(0x7fefffffffffffff)};
    double_shape double_nan = {.bits = UINT64_C(0x7ff8000000000001)};
    double_shape double_subnormal = {.bits = UINT64_C(1)};
    double_shape double_three_minimum = {.bits = UINT64_C(3)};
    float fhalf = float_half;
    float ftwo = float_two;
    float ffive = float_five_and_half;
    double dhalf = double_half;
    double dtwo = double_two;
    double dfive = double_five_and_half;

    CHECK(fpclassify(0.0f) == FP_ZERO &&
            fpclassify(float_subnormal.value) == FP_SUBNORMAL &&
            fpclassify(1.0) == FP_NORMAL &&
            fpclassify(double_infinity.value) == FP_INFINITE &&
            fpclassify(double_nan.value) == FP_NAN,
        1);
    CHECK(isfinite(ftwo) && !isfinite(double_infinity.value) &&
            isinf(float_infinity.value) && isnan(float_nan.value) &&
            isnormal(dtwo) && !isnormal(double_subnormal.value) &&
            signbit(-0.0) && !signbit(0.0),
        2);
    CHECK(isgreater(dtwo, dhalf) && isgreaterequal(dtwo, dtwo) &&
            isless(dhalf, dtwo) && islessequal(dhalf, dhalf) &&
            islessgreater(dhalf, dtwo) &&
            isunordered(double_nan.value, dtwo),
        3);

    CHECK(float_bits(fabsf(-ffive)) == UINT32_C(0x40b00000) &&
            double_bits(fabs(-dfive)) == UINT64_C(0x4016000000000000) &&
            float_bits(copysignf(fhalf, -ftwo)) == UINT32_C(0xbf000000) &&
            double_bits(copysign(dhalf, dtwo)) ==
                UINT64_C(0x3fe0000000000000),
        4);
    CHECK(float_bits(truncf(ffive)) == UINT32_C(0x40a00000) &&
            float_bits(truncf(-fhalf)) == UINT32_C(0x80000000) &&
            double_bits(trunc(-dfive)) == UINT64_C(0xc014000000000000),
        5);
    CHECK(float_bits(floorf(-ffive)) == UINT32_C(0xc0c00000) &&
            float_bits(ceilf(ffive)) == UINT32_C(0x40c00000) &&
            double_bits(floor(dfive)) == UINT64_C(0x4014000000000000) &&
            double_bits(ceil(-dhalf)) == UINT64_C(0x8000000000000000),
        6);
    CHECK(float_bits(roundf(fhalf)) == UINT32_C(0x3f800000) &&
            float_bits(roundf(-fhalf)) == UINT32_C(0xbf800000) &&
            double_bits(round(1.49)) == UINT64_C(0x3ff0000000000000) &&
            double_bits(round(-1.5)) == UINT64_C(0xc000000000000000),
        7);

    CHECK(float_bits(sqrtf(ftwo)) == UINT32_C(0x3fb504f3) &&
            float_bits(sqrtf(float_subnormal.value)) ==
                UINT32_C(0x1a3504f3) &&
            float_bits(sqrtf(float_maximum.value)) ==
                UINT32_C(0x5f7fffff),
        8);
    CHECK(double_bits(sqrt(dtwo)) == UINT64_C(0x3ff6a09e667f3bcd) &&
            double_bits(sqrt(double_subnormal.value)) ==
                UINT64_C(0x1e60000000000000) &&
            double_bits(sqrt(double_maximum.value)) ==
                UINT64_C(0x5fefffffffffffff),
        9);
    CHECK(isnan(sqrt(-dtwo)) && isnan(sqrt(double_nan.value)) &&
            isinf(sqrt(double_infinity.value)) &&
            double_bits(sqrt(-0.0)) == UINT64_C(0x8000000000000000),
        10);

    CHECK(float_bits(fmodf(ffive, ftwo)) == UINT32_C(0x3fc00000) &&
            float_bits(fmodf(-ffive, ftwo)) == UINT32_C(0xbfc00000) &&
            float_bits(fmodf(-ftwo, ftwo)) == UINT32_C(0x80000000),
        11);
    CHECK(double_bits(fmod(dfive, dtwo)) ==
                UINT64_C(0x3ff8000000000000) &&
            double_bits(fmod(-dfive, dtwo)) ==
                UINT64_C(0xbff8000000000000) &&
            double_bits(fmod(dhalf, dtwo)) ==
                UINT64_C(0x3fe0000000000000),
        12);
    CHECK(isnan(fmod(double_infinity.value, dtwo)) &&
            isnan(fmod(dtwo, 0.0)) &&
            double_bits(fmod(dtwo, double_infinity.value)) ==
                UINT64_C(0x4000000000000000) &&
            double_bits(fmod(1.0, double_three_minimum.value)) ==
                UINT64_C(1) &&
            float_bits(fmodf((float_shape){.bits = 5}.value,
                           (float_shape){.bits = 2}.value)) == UINT32_C(1),
        13);

    CHECK((double)fabsl(-3.0L) == 3.0 &&
            (double)copysignl(3.0L, -1.0L) == -3.0 &&
            (double)floorl(-2.25L) == -3.0 &&
            (double)ceill(2.25L) == 3.0 &&
            (double)truncl(-2.75L) == -2.0 &&
            (double)roundl(-2.5L) == -3.0 &&
            (double)sqrtl(9.0L) == 3.0 &&
            (double)fmodl(7.0L, 2.0L) == 1.0,
        14);

    pass();
}

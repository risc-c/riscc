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
static volatile float float_one = 1.0f;
static volatile float float_two = 2.0f;
static volatile float float_five_and_half = 5.5f;
static volatile double double_one = 1.0;
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
    double_shape double_nan = {.bits = UINT64_C(0x7ff8000000000001)};
    double_shape double_subnormal = {.bits = UINT64_C(1)};
    double_shape double_next_one = {.bits = UINT64_C(0x3ff0000000000001)};
    float fhalf = float_half;
    float fone = float_one;
    float ftwo = float_two;
    float ffive = float_five_and_half;
    double done = double_one;
    double dtwo = double_two;
    double dfive = double_five_and_half;

    CHECK(float_bits(fminf(0.0f, -0.0f)) == UINT32_C(0x80000000) &&
            float_bits(fmaxf(0.0f, -0.0f)) == 0 &&
            fminf(float_nan.value, ftwo) == ftwo &&
            fmax(double_nan.value, dtwo) == dtwo &&
            double_bits(fdim(dfive, dtwo)) ==
                UINT64_C(0x400c000000000000) &&
            float_bits(fdimf(ftwo, ffive)) == 0 &&
            isnan(fdim(double_nan.value, dtwo)),
        1);

    {
        float integer_float;
        double integer_double;

        CHECK(float_bits(modff(ffive, &integer_float)) ==
                    UINT32_C(0x3f000000) &&
                float_bits(integer_float) == UINT32_C(0x40a00000) &&
                double_bits(modf(-dfive, &integer_double)) ==
                    UINT64_C(0xbfe0000000000000) &&
                double_bits(integer_double) ==
                    UINT64_C(0xc014000000000000) &&
                double_bits(
                    modf(double_infinity.value, &integer_double)) == 0 &&
                isinf(integer_double),
            2);
    }

    {
        int exponent;

        CHECK(float_bits(frexpf(ffive, &exponent)) ==
                    UINT32_C(0x3f300000) &&
                exponent == 3 &&
                float_bits(frexpf(float_subnormal.value, &exponent)) ==
                    UINT32_C(0x3f000000) &&
                exponent == -148 &&
                double_bits(frexp(double_subnormal.value, &exponent)) ==
                    UINT64_C(0x3fe0000000000000) &&
                exponent == -1073,
            3);
    }

    CHECK(float_bits(scalbnf(fhalf, 4)) == UINT32_C(0x41000000) &&
            double_bits(ldexp(dfive, -1)) ==
                UINT64_C(0x4006000000000000) &&
            float_bits(scalbnf(fone, -149)) == UINT32_C(1) &&
            double_bits(scalbn(done, -1074)) == UINT64_C(1) &&
            isinf(scalbnf(float_maximum.value, 1)) &&
            isinf(scalbln(done, 1024)),
        4);

    CHECK(ilogbf(ffive) == 2 &&
            ilogbf(float_subnormal.value) == -149 &&
            ilogb(double_subnormal.value) == -1074 &&
            ilogb(0.0) == FP_ILOGB0 &&
            ilogb(double_infinity.value) == FP_ILOGBNAN &&
            float_bits(logbf(fhalf)) == UINT32_C(0xbf800000) &&
            isinf(logb(0.0)) && signbit(logb(0.0)) &&
            isinf(logb(double_infinity.value)),
        5);

    CHECK(float_bits(nextafterf(fone, ftwo)) == UINT32_C(0x3f800001) &&
            float_bits(nextafterf(0.0f, -fone)) == UINT32_C(0x80000001) &&
            double_bits(nextafter(done, dtwo)) ==
                UINT64_C(0x3ff0000000000001) &&
            double_bits(nextafter(double_infinity.value, dtwo)) ==
                UINT64_C(0x7fefffffffffffff) &&
            float_bits(nexttowardf(
                fone, (long double)double_next_one.value)) ==
                UINT32_C(0x3f800001),
        6);

    CHECK(isnan(nanf("")) && isnan(nan("payload")) && isnan(nanl("")) &&
            (double)fminl(3.0L, 4.0L) == 3.0 &&
            (double)fmaxl(3.0L, 4.0L) == 4.0 &&
            (double)fdiml(4.0L, 3.0L) == 1.0 &&
            (double)scalbnl(0.5L, 3) == 4.0 &&
            (double)nextafterl(1.0L, 2.0L) > 1.0,
        7);

    CHECK(lroundf(ffive) == 6 && lround(-dfive) == -6 &&
            lroundl(2.5L) == 3 && llroundf(-ffive) == -6 &&
            llround(dfive) == 6 && llroundl(-2.5L) == -3,
        8);

    pass();
}

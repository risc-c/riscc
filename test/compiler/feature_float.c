#include "riscc_compiler_features.h"

union feature_float_bits
{
    float value;
    u32 bits;
};

union feature_double_bits
{
    double value;
    u64 bits;
};

static volatile float float_left = 1.5f;
static volatile float float_right = 2.25f;
static volatile double double_left = 1.5;
static volatile double double_right = 2.0;
static volatile s16 signed16 = -1234;
static volatile u16 unsigned16 = 60000u;
static volatile s32 signed32 = -123456l;
static volatile u32 unsigned32 = 0xf0000000ul;
static volatile s64 signed64 = -0x100000000ll;
static volatile u64 unsigned64 = 0x100000000ull;

static u32 float_bits(float value)
{
    union feature_float_bits converted = {value};
    return converted.bits;
}

static u64 double_bits(double value)
{
    union feature_double_bits converted = {value};
    return converted.bits;
}

u16 feature_test_float(void)
{
    union feature_float_bits float_nan = {.bits = 0x7fc00000ul};
    union feature_double_bits double_nan = {.bits = 0x7ff8000000000000ull};
    struct feature_float_pair pair = {1.25f, -2.5f};
    float a = float_left;
    float b = float_right;
    double x = double_left;
    double y = double_right;

    if (float_bits(a + b) != 0x40700000ul ||
        float_bits(b - a) != 0x3f400000ul ||
        float_bits(a * b) != 0x40580000ul ||
        float_bits(b / a) != 0x3fc00000ul)
        return 1;

    if (double_bits(x + y) != 0x400c000000000000ull ||
        double_bits(y - x) != 0x3fe0000000000000ull ||
        double_bits(x * y) != 0x4008000000000000ull ||
        double_bits(y / x) != 0x3ff5555555555555ull)
        return 2;

    if (!(a < b) || !(a <= b) || !(b > a) || !(b >= a) ||
        a == b || !(a != b))
        return 3;
    if (!(x < y) || !(x <= y) || !(y > x) || !(y >= x) ||
        x == y || !(x != y))
        return 4;
    if (float_nan.value == float_nan.value ||
        !(float_nan.value != float_nan.value) ||
        double_nan.value == double_nan.value ||
        !(double_nan.value != double_nan.value))
        return 5;

    if ((s16)(float)signed16 != signed16 ||
        (u16)(float)unsigned16 != unsigned16 ||
        (s32)(float)signed32 != signed32 ||
        (u32)(float)unsigned32 != unsigned32 ||
        (s64)(float)signed64 != signed64 ||
        (u64)(float)unsigned64 != unsigned64)
        return 6;
    if ((s16)(double)signed16 != signed16 ||
        (u16)(double)unsigned16 != unsigned16 ||
        (s32)(double)signed32 != signed32 ||
        (u32)(double)unsigned32 != unsigned32 ||
        (s64)(double)signed64 != signed64 ||
        (u64)(double)unsigned64 != unsigned64)
        return 7;

    if (double_bits((double)a) != 0x3ff8000000000000ull ||
        float_bits((float)x) != 0x3fc00000ul)
        return 8;

    if (float_bits(feature_float_add(a, b)) != 0x40700000ul ||
        float_bits(feature_float_stack(1, 2, 3, a, 4)) != 0x3fc00000ul)
        return 9;
    if (double_bits(feature_double_arithmetic(x, y)) !=
            0x4008000000000000ull ||
        double_bits(feature_float_mixed(0x1234u, a, 0x5678u)) !=
            0x3ff8000000000000ull)
        return 10;

    pair = feature_float_pair_roundtrip(pair);
    if (float_bits(pair.first) != 0x3fa00000ul ||
        float_bits(pair.second) != 0xc0200000ul)
        return 11;
    if (double_bits((double)feature_long_double_roundtrip(6.5L)) !=
            0x401a000000000000ull ||
        feature_float_varargs(3, 1.25f, -2.5, 3.75L) != 0x6f10u)
        return 12;

    return 0;
}

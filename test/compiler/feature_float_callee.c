#include "riscc_compiler_features.h"
#include <stdarg.h>

float feature_float_add(float left, float right)
{
    return left + right;
}

float feature_float_stack(u16 a, u16 b, u16 c, float value, u16 tail)
{
    return a == 1 && b == 2 && c == 3 && tail == 4 ? value : 0.0f;
}

double feature_double_arithmetic(double left, double right)
{
    return (left * right + left) / left;
}

double feature_float_mixed(u16 prefix, float value, u16 suffix)
{
    return prefix == 0x1234u && suffix == 0x5678u
        ? (double)value
        : 0.0;
}

long double feature_long_double_roundtrip(long double value)
{
    return value;
}

struct feature_float_pair feature_float_pair_roundtrip(
    struct feature_float_pair value)
{
    return value;
}

u16 feature_float_varargs(u16 count, ...)
{
    va_list ap;
    double promoted_float;
    double value;
    long double long_value;

    if (count != 3)
        return 0;
    va_start(ap, count);
    promoted_float = va_arg(ap, double);
    value = va_arg(ap, double);
    long_value = va_arg(ap, long double);
    va_end(ap);

    return promoted_float == 1.25 && value == -2.5 && long_value == 3.75L
        ? 0x6f10u
        : 0;
}

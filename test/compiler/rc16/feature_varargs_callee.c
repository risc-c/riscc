#include "riscc_compiler_features.h"
#include <stdarg.h>

u16 feature_varargs_sum(u16 seed, u16 count, ...)
{
    va_list ap;
    u16 result = seed;

    va_start(ap, count);
    while (count-- != 0)
        result = (u16)(result + va_arg(ap, unsigned int));
    va_end(ap);
    return result;
}

u16 feature_varargs_promote(u16 count, ...)
{
    va_list ap;
    int signed_value;
    int unsigned_value;

    if (count != 2)
        return 0;
    va_start(ap, count);
    signed_value = va_arg(ap, int);
    unsigned_value = va_arg(ap, int);
    va_end(ap);
    return signed_value == -7 && unsigned_value == 250 ? 0x7a11u : 0;
}

u16 feature_varargs_copy(u16 count, ...)
{
    va_list first;
    va_list copy;
    unsigned int first_a;
    unsigned int first_b;
    unsigned int second_a;
    unsigned int second_b;

    if (count != 2)
        return 0;
    va_start(first, count);
    va_copy(copy, first);
    first_a = va_arg(first, unsigned int);
    first_b = va_arg(copy, unsigned int);
    second_a = va_arg(first, unsigned int);
    second_b = va_arg(copy, unsigned int);
    va_end(copy);
    va_end(first);
    return first_a == 0x1357u && first_b == 0x1357u &&
        second_a == 0x2468u && second_b == 0x2468u
        ? 0x3579u
        : 0;
}

u16 feature_varargs_mix(u16 lead, u16 a, u16 b, u16 c, u16 count, ...)
{
    va_list ap;
    struct feature_vararg_pair pair;
    struct feature_vararg_bytes3 bytes;
    unsigned long wide;
    unsigned int tail;

    if (lead != 0x55aau || a != 1 || b != 2 || c != 3 || count != 4)
        return 0;
    va_start(ap, count);
    pair = va_arg(ap, struct feature_vararg_pair);
    bytes = va_arg(ap, struct feature_vararg_bytes3);
    wide = va_arg(ap, unsigned long);
    tail = va_arg(ap, unsigned int);
    va_end(ap);
    return pair.first == 0x1357u && pair.second == 0x2468u &&
        bytes.byte[0] == 0x12u && bytes.byte[1] == 0x34u &&
        bytes.byte[2] == 0x56u &&
        wide == 0x12345678ul && tail == 0xabcdu
        ? 0x5aa5u
        : 0;
}

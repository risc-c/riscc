#include <stdarg.h>
#include "c_abi.h"

volatile u32 c_abi_data_word = 0x13579bdfu;
volatile u32 c_abi_bss_word;
const u16 c_abi_rodata_words[3] = {0x2468u, 0xabcdu, 0x55aau};
__thread volatile u32 c_abi_tls_data_word = 0x2468ace0u;
_Thread_local volatile u32 c_abi_tls_bss_word;

u16 c_abi_sum_six(u16 a, u16 b, u16 c, u16 d, u16 e, u16 f)
{
    return (u16)(a + b + c + d + e + f);
}

u16 c_abi_stack_mix(u16 a, u16 b, u16 c, u32 wide, u16 tail)
{
    return a == 1 && b == 2 && c == 3 && wide == 0x12345678u && tail == 5
        ? 0x2468u
        : 0;
}

struct c_abi_pair c_abi_make_pair(u16 value)
{
    struct c_abi_pair result = {value, (u16)(value ^ 0xffffu)};
    return result;
}

struct c_abi_large c_abi_make_large(u16 value)
{
    struct c_abi_large result;
    u16 index;

    for (index = 0; index != 5; ++index)
        result.word[index] = (u16)(value + index);
    return result;
}

u16 c_abi_add_seven(u16 value)
{
    return (u16)(value + 7);
}

u16 c_abi_call(c_abi_unary_fn function, u16 value)
{
    return function(value);
}

static u16 triangular(u16 value)
{
    return value == 0 ? 0 : (u16)(value + triangular((u16)(value - 1)));
}

u16 c_abi_stack_and_recursion(u16 value)
{
    volatile u16 words[6];
    u16 index;

    for (index = 0; index != 6; ++index)
        words[index] = (u16)(value + index);
    return (u16)(words[0] + words[5] + triangular(value));
}

u16 c_abi_varargs_sum(u16 seed, unsigned int count, ...)
{
    va_list ap;
    u16 result = seed;

    va_start(ap, count);
    while (count-- != 0)
        result = (u16)(result + va_arg(ap, unsigned int));
    va_end(ap);
    return result;
}

u16 c_abi_varargs_mix(u16 lead, u16 a, u16 b, u16 c,
    unsigned int count, ...)
{
    va_list ap;
    struct c_abi_pair pair;
    u16 tail;
    unsigned long wide;

    if (lead != 0x55aau || a != 1 || b != 2 || c != 3 || count != 3)
        return 0;
    va_start(ap, count);
    pair = va_arg(ap, struct c_abi_pair);
    wide = va_arg(ap, unsigned long);
    tail = (u16)va_arg(ap, unsigned int);
    va_end(ap);
    return pair.first == 0x1357u && pair.second == 0x2468u &&
        wide == 0x12345678ul && tail == 0xabcdu
        ? 0x5aa5u
        : 0;
}

u16 c_abi_tls_update(u16 value)
{
    c_abi_tls_data_word += value;
    c_abi_tls_bss_word = value + value;
    return (u16)(c_abi_tls_data_word + c_abi_tls_bss_word);
}

float c_abi_float_scale(float value)
{
    return value * 2.25f;
}

double c_abi_double_scale(double value)
{
    return value * 2.0 + 1.0;
}

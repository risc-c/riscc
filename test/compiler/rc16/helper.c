#include "riscc_compiler_test.h"

volatile u16 compiler_bss_word;
volatile u16 compiler_data_word = 0x1357;
const u16 compiler_rodata_words[3] = {0x2468, 0xabcd, 0x55aa};
__thread volatile u16 compiler_tls_data_word = 0x7a35;
_Thread_local volatile u16 compiler_tls_bss_word;

struct pair16 make_pair16(u16 value)
{
    struct pair16 result;
    result.first = value;
    result.second = (u16)(value ^ 0xffffu);
    return result;
}

u16 sum_six(u16 a, u16 b, u16 c, u16 d, u16 e, u16 f)
{
    return (u16)(a + b + c + d + e + f);
}

static u16 triangular(u16 value)
{
    if (value == 0)
        return 0;
    return (u16)(value + triangular((u16)(value - 1)));
}

u16 stack_and_recursion(u16 value)
{
    volatile u16 words[6];
    u16 index;

    for (index = 0; index != 6; ++index)
        words[index] = (u16)(value + index);

    return (u16)(words[0] + words[5] + triangular(value));
}

u16 add_seven(u16 value)
{
    return (u16)(value + 7);
}

u16 call_unary16(unary16_fn fn, u16 value)
{
    return fn(value);
}

u32 mix_word32(u32 value)
{
    return (value + 0x11112222ul) ^ 0x00ff00fful;
}

u16 divide_word16(u16 value, u16 divisor)
{
    return (u16)(value / divisor + value % divisor);
}

s16 signed_divide_word16(s16 value, s16 divisor)
{
    return (s16)(value / divisor + value % divisor);
}

u32 arithmetic_word32(u32 value)
{
    return (value * 37ul) / 37ul + value % 97ul;
}

u64 arithmetic_word64(u64 value, u16 shift)
{
    u64 rotated = (value << shift) | (value >> (64u - shift));
    return (rotated * 3ull) / 3ull + rotated % 17ull;
}

u16 compiler_tls_helper(u16 value)
{
    compiler_tls_data_word = (u16)(compiler_tls_data_word + value);
    compiler_tls_bss_word = (u16)(compiler_tls_bss_word ^ value);
    return (u16)(compiler_tls_data_word + compiler_tls_bss_word);
}

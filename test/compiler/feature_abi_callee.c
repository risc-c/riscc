#include "riscc_compiler_features.h"

u16 feature_abi_narrow(s8 a, u8 b, s16 c, u16 d, s8 e)
{
    return a == -7 && b == 250 && c == -1234 && d == 0xabcdu && e == -9
               ? 0x1357u
               : 0;
}

u16 feature_abi_stack_mix(u16 a, u16 b, u16 c, u32 wide, u16 tail)
{
    return a == 1 && b == 2 && c == 3 && wide == 0x12345678ul && tail == 5
               ? 0x2468u
               : 0;
}

u16 feature_abi_pair_regs(u16 prefix, struct feature_pair value, u16 suffix)
{
    return prefix == 0x1111u && value.first == 0x2222u &&
                   value.second == 0x3333u && suffix == 0x4444u
               ? 0x3579u
               : 0;
}

u16 feature_abi_pair_stack(u16 a, u16 b, u16 c, struct feature_pair value,
                           u16 suffix)
{
    return a == 1 && b == 2 && c == 3 && value.first == 0x2222u &&
                   value.second == 0x3333u && suffix == 4
               ? 0x468au
               : 0;
}

u16 feature_abi_large_arg(struct feature_large value, u16 tail)
{
    u16 i;
    for (i = 0; i != 5; ++i)
        if (value.word[i] != (u16)(i + 1))
            return 0;
    return tail == 6 ? 0x579bu : 0;
}

u16 feature_abi_u64_stack(u16 prefix, u64 value, u16 suffix)
{
    return prefix == 7 && value == 0x1122334455667788ull && suffix == 9
               ? 0x68acu
               : 0;
}

struct feature_byte feature_abi_return_byte(s8 value)
{
    struct feature_byte result = {value};
    return result;
}

struct feature_pair feature_abi_return_pair(u16 value)
{
    struct feature_pair result = {value, (u16)(value ^ 0xffffu)};
    return result;
}

struct feature_quad feature_abi_return_quad(u16 value)
{
    struct feature_quad result;
    u16 i;
    for (i = 0; i != 4; ++i)
        result.word[i] = (u16)(value + i);
    return result;
}

struct feature_large feature_abi_return_large(u16 value)
{
    struct feature_large result;
    u16 i;
    for (i = 0; i != 5; ++i)
        result.word[i] = (u16)(value + i);
    return result;
}

u32 feature_abi_return_u32(u16 low)
{
    return 0x12340000ul | low;
}

u64 feature_abi_return_u64(u16 low)
{
    return 0x1122334455660000ull | low;
}

u64 feature_abi_u64_roundtrip(u64 value)
{
    return value;
}

u16 feature_abi_add(u16 left, u16 right)
{
    return (u16)(left + right);
}

feature_binary_fn feature_global_binary = feature_abi_add;

u16 feature_abi_apply(feature_binary_fn function, u16 left, u16 right)
{
    return function(left, right);
}

u16 feature_abi_pressure(u16 seed)
{
    volatile u16 a = (u16)(seed + 1);
    volatile u16 b = (u16)(seed + 2);
    volatile u16 c = (u16)(seed + 3);
    volatile u16 d = (u16)(seed + 4);
    volatile u16 e = (u16)(seed + 5);
    volatile u16 f = (u16)(seed + 6);
    u16 nested = feature_abi_add(seed, 7);
    return (u16)(a + b + c + d + e + f + nested + 32);
}

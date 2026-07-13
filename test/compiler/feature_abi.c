#include "riscc_compiler_features.h"

u16 feature_test_abi(void)
{
    struct feature_byte byte;
    struct feature_pair pair = {0x2222u, 0x3333u};
    struct feature_quad quad;
    struct feature_large large = {{1, 2, 3, 4, 5}};
    feature_binary_fn roundtrip;
    void *volatile code_as_data;
    u16 i;

    if (feature_abi_narrow(-7, 250, -1234, 0xabcdu, -9) != 0x1357u)
        return 1;
    if (feature_abi_stack_mix(1, 2, 3, 0x12345678ul, 5) != 0x2468u)
        return 2;
    if (feature_abi_pair_regs(0x1111u, pair, 0x4444u) != 0x3579u)
        return 3;
    if (feature_abi_pair_stack(1, 2, 3, pair, 4) != 0x468au)
        return 4;
    if (feature_abi_large_arg(large, 6) != 0x579bu)
        return 5;
    if (feature_abi_u64_stack(7, 0x1122334455667788ull, 9) != 0x68acu)
        return 6;

    byte = feature_abi_return_byte(-12);
    if ((s16)byte.value != -12)
        return 7;
    pair = feature_abi_return_pair(0x1234u);
    if (pair.first != 0x1234u || pair.second != 0xedcbu)
        return 8;
    quad = feature_abi_return_quad(0x2000u);
    for (i = 0; i != 4; ++i)
        if (quad.word[i] != (u16)(0x2000u + i))
            return 9;
    large = feature_abi_return_large(0x3000u);
    for (i = 0; i != 5; ++i)
        if (large.word[i] != (u16)(0x3000u + i))
            return 10;

    if (feature_abi_return_u32(0x5678u) != 0x12345678ul ||
        feature_abi_return_u64(0x7788u) != 0x1122334455667788ull ||
        feature_abi_u64_roundtrip(0xfedcba9876543210ull) !=
            0xfedcba9876543210ull)
        return 11;

    if (feature_global_binary == (feature_binary_fn)0 ||
        feature_abi_apply(feature_global_binary, 19, 23) != 42)
        return 12;

    code_as_data = (void *)feature_abi_add;
    roundtrip = (feature_binary_fn)code_as_data;
    if (roundtrip != feature_abi_add || roundtrip(20, 22) != 42)
        return 13;

    if (feature_abi_pressure(7) != 109u)
        return 14;
    if (feature_check_callee_saved() != 0)
        return 15;

    for (i = 0; i != 10; ++i)
        if (feature_abi_stack_mix(1, 2, 3, 0x12345678ul, 5) != 0x2468u)
            return 16;

    return 0;
}

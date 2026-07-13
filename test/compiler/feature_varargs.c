#include "riscc_compiler_features.h"

u16 feature_test_varargs(void)
{
    struct feature_vararg_pair pair = {0x1357u, 0x2468u};
    struct feature_vararg_bytes3 bytes = {{0x12u, 0x34u, 0x56u}};
    s8 signed_byte = -7;
    u8 unsigned_byte = 250;

    if (feature_varargs_sum(0x1000u, 3, 0x0010u, 0x0020u, 0x0030u) !=
        0x1060u)
        return 1;
    if (feature_varargs_promote(2, signed_byte, unsigned_byte) != 0x7a11u)
        return 2;
    if (feature_varargs_copy(2, 0x1357u, 0x2468u) != 0x3579u)
        return 3;
    if (feature_varargs_mix(0x55aau, 1, 2, 3, 4, pair, bytes, 0x12345678ul,
        0xabcdu) != 0x5aa5u)
        return 4;
    return 0;
}

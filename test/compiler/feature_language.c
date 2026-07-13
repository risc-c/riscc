#include "riscc_compiler_features.h"

enum feature_mode {
    FEATURE_ZERO,
    FEATURE_ONE,
    FEATURE_SEVEN = 7,
    FEATURE_LARGE = 255
};

static volatile u16 language_seed = FEATURE_SEVEN;
static volatile u8 language_u8 = 250;
static volatile s8 language_s8 = -7;

static u16 bump(u16 *value)
{
    *value = (u16)(*value + 1);
    return *value;
}

static u16 select_case(u16 value)
{
    switch (value) {
    case FEATURE_ZERO:
        return 11;
    case FEATURE_ONE:
        return 22;
    case FEATURE_SEVEN:
        return 77;
    case FEATURE_LARGE:
        return 99;
    default:
        return 44;
    }
}

u16 feature_test_language(void)
{
    u16 i;
    u16 sum;
    u16 side;
    u8 narrow;
    s8 signed_narrow;
    _Bool boolean;
    u16 seed = language_seed;
    enum feature_mode mode = (enum feature_mode)seed;

    if ((u16)language_u8 != 250u || (s16)language_s8 != -7)
        return 1;

    narrow = (u8)0x12abu;
    signed_narrow = (s8)-19;
    if (narrow != 0xabu || (s16)signed_narrow != -19)
        return 2;
    if ((s16)(signed_narrow + (s8)20) != 1)
        return 3;

    boolean = (_Bool)language_seed;
    if (boolean != 1 || (_Bool)0 != 0 || sizeof(boolean) != 1)
        return 4;
    if (mode != FEATURE_SEVEN || select_case((u16)mode) != 77 ||
        select_case(3) != 44)
        return 5;

    side = 0;
    if ((0 && bump(&side)) || side != 0)
        return 6;
    if (!(1 || bump(&side)) || side != 0)
        return 7;
    if (!(1 && bump(&side)) || side != 1)
        return 8;
    if (!(0 || bump(&side)) || side != 2)
        return 9;

    if ((language_seed == 7 ? 0x1234u : 0x5678u) != 0x1234u)
        return 10;

    sum = 0;
    for (i = 0; i != (u16)(seed + 3); ++i) {
        if (i == (u16)(seed - 3))
            continue;
        if (i == (u16)(seed + 1))
            break;
        sum = (u16)(sum + i);
    }
    if (sum != 24)
        return 11;

    i = 0;
    sum = 0;
    while (i != (u16)(seed - 2))
        sum = (u16)(sum + i++);
    do {
        sum = (u16)(sum + i);
        --i;
    } while (i != 0);
    if (sum != 25)
        return 12;

    i = 0;
    sum = 0;
again:
    sum = (u16)(sum + ++i);
    if (i != (u16)(seed - 3))
        goto again;
    if (sum != 10)
        return 13;

    i = (u16)(seed - 4);
    sum = (u16)((i += 4, i *= 3, i));
    if (sum != 21 || !(sum > 20 && sum <= 21) || sum == 0)
        return 14;

    return 0;
}

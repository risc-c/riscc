#include "c_abi.h"

#define RESULT_WORD (*(volatile u16 *)0xfffeu)

union float_bits
{
    float value;
    u32 bits;
};

union double_bits
{
    double value;
    u64 bits;
};

struct c_abi_layout
{
    u8 head;
    u16 word;
    u8 tail;
};

static void fail(u16 code)
{
    RESULT_WORD = (u16)(0xd000u | code);
    for (;;)
        ;
}

static u32 float_bits(float value)
{
    union float_bits converted = {.value = value};
    return converted.bits;
}

static u64 double_bits(double value)
{
    union double_bits converted = {.value = value};
    return converted.bits;
}

int main(void)
{
    struct c_abi_pair pair;
    struct c_abi_large large;
    struct c_abi_layout layout = {.tail = 0x56u, .head = 0x12u,
                                    .word = 0x3456u};
    u8 bytes[8];
    u16 index;
    u32 value32 = 0x12345678u;
    u64 value64 = 0x123456789abcdef0ull;
    s32 signed32 = -100000;
    s64 signed64 = -100000ll;

    _Static_assert(sizeof(u8) == 1, "8-bit byte type");
    _Static_assert(sizeof(u16) == 2, "16-bit type");
    _Static_assert(sizeof(u32) == 4, "32-bit type");
    _Static_assert(sizeof(u64) == 8, "64-bit type");
    _Static_assert(sizeof(int) == sizeof(void *), "native integer width");
    _Static_assert(sizeof(long) == 4, "32-bit long");
    _Static_assert(sizeof(long long) == 8, "64-bit long long");
    _Static_assert(sizeof(float) == 4, "binary32 float");
    _Static_assert(sizeof(double) == 8, "binary64 double");

    if (c_abi_data_word != 0x13579bdfu || c_abi_bss_word != 0 ||
        c_abi_rodata_words[0] != 0x2468u ||
        c_abi_rodata_words[2] != 0x55aau)
        fail(1);
    c_abi_bss_word = 0xa55aa55au;
    if (c_abi_bss_word != 0xa55aa55au)
        fail(2);
    if (c_abi_tls_data_word != 0x2468ace0u || c_abi_tls_bss_word != 0 ||
        c_abi_tls_update(0x33u) != 0xad79u ||
        c_abi_tls_data_word != 0x2468ad13u || c_abi_tls_bss_word != 0x66u)
        fail(3);

    if (c_abi_sum_six(1, 2, 3, 4, 5, 6) != 21 ||
        c_abi_stack_mix(1, 2, 3, 0x12345678u, 5) != 0x2468u)
        fail(4);
    pair = c_abi_make_pair(0x1234u);
    if (pair.first != 0x1234u || pair.second != 0xedcbu)
        fail(5);
    large = c_abi_make_large(0x3000u);
    for (index = 0; index != 5; ++index)
        if (large.word[index] != (u16)(0x3000u + index))
            fail(6);
    if (c_abi_stack_and_recursion(5) != 30 ||
        c_abi_call(c_abi_add_seven, 35) != 42)
        fail(7);

    if (c_abi_varargs_sum(0x1000u, 3, 0x10u, 0x20u, 0x30u) != 0x1060u ||
        c_abi_varargs_mix(0x55aau, 1, 2, 3, 3,
            (struct c_abi_pair){0x1357u, 0x2468u}, 0x12345678ul,
            0xabcdu) != 0x5aa5u)
        fail(8);

    if (layout.head != 0x12u || layout.word != 0x3456u ||
        layout.tail != 0x56u)
        fail(9);
    for (index = 0; index != sizeof(bytes); ++index)
        bytes[index] = (u8)index;
    if (bytes[0] != 0 || bytes[7] != 7)
        fail(10);

    if (value32 * 37u != 0xa1907f58u || value32 / 12345u != 0x60a4u ||
        value32 % 12345u != 0x11f4u || (value32 >> 4) != 0x01234567u ||
        signed32 / 300 != -333 || signed32 % 300 != -100)
        fail(11);
    if (value64 * 3ull != 0x369d0369d0369cd0ull ||
        value64 / 65537ull != 0x0000123444445678ull ||
        value64 % 65537ull != 0x8878ull || signed64 / 300ll != -333ll ||
        signed64 % 300ll != -100ll)
        fail(12);

    if (float_bits(c_abi_float_scale(1.5f)) != 0x40580000u ||
        double_bits(c_abi_double_scale(1.5)) != 0x4010000000000000ull)
        fail(13);

    RESULT_WORD = 0x600d;
    return 0;
}

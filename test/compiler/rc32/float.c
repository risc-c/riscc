#include "test.h"

union float_bits
{
    float value;
    u32 bits;
};

struct float_case
{
    u32 left;
    u32 right;
    u32 expected;
};

static volatile struct float_case add_cases[] =
{
    {0x3f812345u, 0x3fcabcdeu, 0x4025f012u},
    {0x3fffffffu, 0x3f800001u, 0x40400000u},
    {0x41234567u, 0xbedcba98u, 0x411c5f92u},
    {0x3fabcdefu, 0xbf987654u, 0x3e1abcd8u},
    {0x7eabcdefu, 0x00812345u, 0x7eabcdefu},
    {0x3f800001u, 0x33800000u, 0x3f800002u},
    {0x3f800000u, 0x33800000u, 0x3f800000u},
    {0x00812345u, 0x00876543u, 0x01044444u},
    {0x00000001u, 0x00000001u, 0x00000002u},
    {0x007fffffu, 0x00000001u, 0x00800000u},
    {0x7f7fffffu, 0x7f7fffffu, 0x7f800000u},
    {0x80000000u, 0x80000000u, 0x80000000u},
    {0x3f800000u, 0xbf800000u, 0x00000000u},
    {0x7f800001u, 0x3f800000u, 0x7fc00001u},
    {0x7f800000u, 0xff800000u, 0x7fc00000u}
};

static volatile struct float_case multiply_cases[] =
{
    {0x3f812345u, 0x3fcabcdeu, 0x3fcc8a35u},
    {0x3fffffffu, 0x3fffffffu, 0x407ffffeu},
    {0x3f800001u, 0x3f800001u, 0x3f800002u},
    {0x41234567u, 0x3edcba98u, 0x408cc6a6u},
    {0x7eabcdefu, 0x00812345u, 0x3fad54e2u},
    {0x00ffffffu, 0x4effffffu, 0x107ffffeu},
    {0x3fabcdefu, 0xbf987654u, 0xbfcca35eu},
    {0x00812345u, 0x3f812345u, 0x00824921u},
    {0x00800000u, 0x3f000000u, 0x00400000u},
    {0x00000001u, 0x40000000u, 0x00000002u},
    {0x00000001u, 0x3f000000u, 0x00000000u},
    {0x00000003u, 0x3f000000u, 0x00000002u},
    {0x7f7fffffu, 0x40000000u, 0x7f800000u},
    {0x80000000u, 0xc0000000u, 0x00000000u},
    {0x7f800000u, 0x00000000u, 0x7fc00000u},
    {0x7f800001u, 0x3f800000u, 0x7fc00001u}
};

static volatile struct float_case divide_cases[] =
{
    {0x3f812345u, 0x3fcabcdeu, 0x3f23106fu},
    {0x3fffffffu, 0x3f800001u, 0x3ffffffdu},
    {0x41234567u, 0x3edcba98u, 0x41bd5c5fu},
    {0x00812345u, 0x3f812345u, 0x00800000u},
    {0x3fabcdefu, 0xbf987654u, 0xbf903d22u},
    {0x3f800000u, 0x40400000u, 0x3eaaaaabu},
    {0x00800000u, 0x40000000u, 0x00400000u},
    {0x00000001u, 0x40000000u, 0x00000000u},
    {0x00000003u, 0x40000000u, 0x00000002u},
    {0x7f7fffffu, 0x3f000000u, 0x7f800000u},
    {0x3f800000u, 0x7f800000u, 0x00000000u},
    {0x00000000u, 0x00000000u, 0x7fc00000u},
    {0x7f800000u, 0x7f800000u, 0x7fc00000u},
    {0x7f800001u, 0x3f800000u, 0x7fc00001u}
};

static float from_bits(u32 bits)
{
    union float_bits converted = {.bits = bits};
    return converted.value;
}

static u32 bits_of(float value)
{
    union float_bits converted = {.value = value};
    return converted.bits;
}

u16 rc32_test_float(void)
{
    u32 index;

    for (index = 0; index != sizeof(add_cases) / sizeof(add_cases[0]); ++index)
    {
        u32 actual = bits_of(from_bits(add_cases[index].left) +
                             from_bits(add_cases[index].right));
        if (actual != add_cases[index].expected)
            return (u16)(0x10u + index);
    }

    for (index = 0; index != sizeof(multiply_cases) / sizeof(multiply_cases[0]);
         ++index)
        if (bits_of(from_bits(multiply_cases[index].left) *
                    from_bits(multiply_cases[index].right)) !=
            multiply_cases[index].expected)
            return (u16)(0x30u + index);

    for (index = 0; index != sizeof(divide_cases) / sizeof(divide_cases[0]);
         ++index)
        if (bits_of(from_bits(divide_cases[index].left) /
                    from_bits(divide_cases[index].right)) !=
            divide_cases[index].expected)
            return (u16)(0x50u + index);

    return 0;
}

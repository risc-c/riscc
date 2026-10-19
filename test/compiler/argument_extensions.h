#ifndef RISCC_COMPILER_ARGUMENT_EXTENSIONS_H
#define RISCC_COMPILER_ARGUMENT_EXTENSIONS_H

/* Keep public ABI extension contracts: private-call lowering may legitimately
 * remove them. Separate calls also prevent caller-specific constant folding. */

__attribute__((noinline)) signed char
argument_extensions_signed_byte_loop(signed char value, u16 count)
{
    do {
        value = (signed char)((value >> 1) ^ 64);
    } while (--count);
    return value;
}

__attribute__((noinline)) u8
argument_extensions_unsigned_byte_loop(u8 value, u16 count)
{
    do {
        value = (u8)((value >> 1) ^ 156u);
    } while (--count);
    return value;
}

__attribute__((noinline)) signed char
argument_extensions_wrapping_byte_loop(signed char value, u16 count)
{
    do {
        value = (signed char)(value + 79);
    } while (--count);
    return value;
}

__attribute__((noinline)) u8
argument_extensions_wide_byte_loop(u32 value, u16 count)
{
    do {
        value = (value >> 1) ^ 156u;
    } while (--count);
    return (u8)value;
}

__attribute__((noinline)) signed short
argument_extensions_signed_half_loop(signed short value, u16 count)
{
    do {
        value = (signed short)((value >> 1) ^ 0x4000u);
    } while (--count);
    return value;
}

__attribute__((noinline)) u16
argument_extensions_unsigned_half_loop(u16 value, u16 count)
{
    do {
        value = (u16)((value >> 1) ^ 0x9041u);
    } while (--count);
    return value;
}

static volatile u8 argument_extensions_byte_values[] = {
    0, 1, 127, 128, 255,
};
static volatile u16 argument_extensions_half_values[] = {
    0, 1, 32767, 32768, 65535,
};
static volatile u32 argument_extensions_wide_values[] = {
    0u, 255u, 256u, 65535u, 0x80000000u, 0xffffffffu,
};
static volatile u16 argument_extensions_counts[] = {
    1, 2, 7, 17,
};

static u16 test_argument_extensions(void)
{
    for (unsigned value_index = 0;
         value_index < sizeof(argument_extensions_byte_values) /
             sizeof(argument_extensions_byte_values[0]); ++value_index) {
        u8 start = argument_extensions_byte_values[value_index];
        for (unsigned count_index = 0;
             count_index < sizeof(argument_extensions_counts) /
                 sizeof(argument_extensions_counts[0]); ++count_index) {
            u16 count = argument_extensions_counts[count_index];
            u32 signed_reference = start;
            u32 unsigned_reference = start;
            u32 wrapping_reference = start;
            for (u16 n = 0; n < count; ++n) {
                signed_reference = ((signed_reference >> 1) |
                                    (signed_reference & 128u)) ^ 64u;
                unsigned_reference = (unsigned_reference >> 1) ^ 156u;
                wrapping_reference = (wrapping_reference + 79u) & 255u;
            }
            if ((u8)argument_extensions_signed_byte_loop(
                    (signed char)start, count) != (u8)signed_reference)
                return 1;
            if (argument_extensions_unsigned_byte_loop(start, count) !=
                    (u8)unsigned_reference)
                return 2;
            if ((u8)argument_extensions_wrapping_byte_loop(
                    (signed char)start, count) != (u8)wrapping_reference)
                return 3;
        }
    }

    for (unsigned value_index = 0;
         value_index < sizeof(argument_extensions_wide_values) /
             sizeof(argument_extensions_wide_values[0]); ++value_index) {
        u32 start = argument_extensions_wide_values[value_index];
        for (unsigned count_index = 0;
             count_index < sizeof(argument_extensions_counts) /
                 sizeof(argument_extensions_counts[0]); ++count_index) {
            u16 count = argument_extensions_counts[count_index];
            u32 reference = start;
            for (u16 n = 0; n < count; ++n)
                reference = (reference >> 1) ^ 156u;
            if (argument_extensions_wide_byte_loop(start, count) !=
                    (u8)reference)
                return 4;
        }
    }

    for (unsigned value_index = 0;
         value_index < sizeof(argument_extensions_half_values) /
             sizeof(argument_extensions_half_values[0]); ++value_index) {
        u16 start = argument_extensions_half_values[value_index];
        for (unsigned count_index = 0;
             count_index < sizeof(argument_extensions_counts) /
                 sizeof(argument_extensions_counts[0]); ++count_index) {
            u16 count = argument_extensions_counts[count_index];
            u32 signed_reference = start;
            u32 unsigned_reference = start;
            for (u16 n = 0; n < count; ++n) {
                signed_reference = ((signed_reference >> 1) |
                                    (signed_reference & 32768u)) ^ 16384u;
                unsigned_reference = (unsigned_reference >> 1) ^ 36929u;
            }
            if ((u16)argument_extensions_signed_half_loop(
                    (signed short)start, count) != (u16)signed_reference)
                return 5;
            if (argument_extensions_unsigned_half_loop(start, count) !=
                    (u16)unsigned_reference)
                return 6;
        }
    }
    return 0;
}

#endif

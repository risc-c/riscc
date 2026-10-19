#ifndef RISCC_COMPILER_NARROW_ARITHMETIC_H
#define RISCC_COMPILER_NARROW_ARITHMETIC_H

/* Keep these operations in separate calls so the tests exercise the narrow
 * add and comparison shape, rather than a caller-specific constant fold. */
static __attribute__((noinline)) unsigned narrow_byte_sub_lt(u8 value)
{
    return (u8)(value - 58u) < 246u;
}

static __attribute__((noinline)) unsigned narrow_byte_sub_ge(u8 value)
{
    return (u8)(value - 58u) >= 246u;
}

static __attribute__((noinline)) unsigned narrow_byte_sub_le(u8 value)
{
    return (u8)(value - 65u) <= 25u;
}

static __attribute__((noinline)) unsigned narrow_byte_sub_gt(u8 value)
{
    return (u8)(value - 65u) > 25u;
}

static __attribute__((noinline)) unsigned narrow_half_sub_lt(u16 value)
{
    return (u16)(value - 58u) < 65526u;
}

static __attribute__((noinline)) unsigned narrow_half_sub_ge(u16 value)
{
    return (u16)(value - 58u) >= 65526u;
}

/* The accumulator is observed only after the loop.  Its low bits are the
 * intended state, while the return conversion also checks the sign boundary. */
static __attribute__((noinline)) s32 narrow_byte_sum(
    const volatile u8 *values, unsigned count)
{
    u8 sum = 0;
    for (unsigned i = 0; i < count; ++i)
        sum = (u8)(sum + values[i]);
    return (s32)(signed char)sum;
}

static __attribute__((noinline)) s32 narrow_half_sum(
    const volatile u16 *values, unsigned count)
{
    u16 sum = 0;
    for (unsigned i = 0; i < count; ++i)
        sum = (u16)(sum + values[i]);
    return (s32)(signed short)sum;
}

static __attribute__((noinline)) u16 narrow_nested_conditional(
    const volatile u8 *values, unsigned rows, unsigned columns)
{
    u8 sum = 0;
    for (unsigned row = 0; row < rows; ++row)
        for (unsigned column = 0; column < columns; ++column) {
            u8 value = values[row * columns + column];
            sum = (u8)(sum + value);
            if (value >= 128u)
                sum = (u8)(sum + 1u);
        }
    return sum;
}

static __attribute__((noinline)) s32 narrow_sub_xor(
    const volatile u8 *values, unsigned count)
{
    u8 value = 0x80u;
    for (unsigned i = 0; i < count; ++i) {
        value = (u8)(value - values[i]);
        value = (u8)(value ^ values[i]);
    }
    return (s32)(signed char)value;
}

/* These two deliberately observe the wrapped value in the loop.  They are
 * runtime checks as well as guards against widening an open recurrence. */
static __attribute__((noinline)) u16 narrow_compare_inside_loop(
    const volatile u8 *values, unsigned count)
{
    u8 value = 1u;
    u16 matches = 0;
    for (unsigned i = 0; i < count; ++i) {
        value = (u8)(value + values[i]);
        if (value < 32u)
            ++matches;
    }
    return (u16)(matches + value);
}

static __attribute__((noinline)) u16 narrow_shift_inside_loop(
    const volatile u8 *values, unsigned count)
{
    u8 value = 1u;
    u16 shifted = 0;
    for (unsigned i = 0; i < count; ++i) {
        value = (u8)(value + values[i]);
        shifted = (u16)(shifted + (u8)(value >> 1));
    }
    return (u16)(shifted + value);
}

/* Keep the recurrence itself narrow: the PHI, logical shift, bit test,
 * conditional polynomial select and XOR all have the u8 type.  The explicit
 * casts also keep the intended modulo-256 reference visible in the source. */
static __attribute__((noinline)) u8 narrow_byte_shift_xor(
    u8 seed, unsigned count)
{
    u8 state = seed;
    for (unsigned i = 0; i < count; ++i) {
        u8 shifted = (u8)(state >> 1);
        u8 bit = (u8)(state & (u8)1u);
        u8 polynomial = bit ? (u8)0x9cu : (u8)0;
        state = (u8)(shifted ^ polynomial);
    }
    return state;
}

/* The u16 version is kept as a separate simple-return case so it remains a
 * direct narrow recurrence even when the checksum observation below adds an
 * extra user. */
static __attribute__((noinline)) u16 narrow_half_shift_xor(
    u16 seed, unsigned count)
{
    u16 state = seed;
    for (unsigned i = 0; i < count; ++i) {
        u16 shifted = (u16)(state >> 1);
        u16 bit = (u16)(state & (u16)1u);
        u16 polynomial = bit ? (u16)0xb400u : (u16)0;
        state = (u16)(shifted ^ polynomial);
    }
    return state;
}

/* Exercise an in-loop low-bit observation without storing a narrow value to
 * memory.  The return packs the final u16 state in the high half and the
 * 32-bit checksum of trunc(u8) observations in the low half. */
static __attribute__((noinline)) u32 narrow_half_shift_xor_checksum(
    u16 seed, unsigned count)
{
    u16 state = seed;
    u32 checksum = 0;
    for (unsigned i = 0; i < count; ++i) {
        u16 shifted = (u16)(state >> 1);
        u16 bit = (u16)(state & (u16)1u);
        u16 polynomial = bit ? (u16)0xb400u : (u16)0;
        state = (u16)(shifted ^ polynomial);
        checksum += (u32)(u8)state;
    }
    return ((u32)state << 16) | (checksum & 0xffffu);
}

/* The wrapping add must remain before the logical shift.  In particular, an
 * unsigned-wrap recurrence must not be widened under the zero-range pass. */
static __attribute__((noinline)) u8 narrow_byte_add_shift_guard(
    u8 seed, unsigned count)
{
    u8 state = seed;
    for (unsigned i = 0; i < count; ++i)
        state = (u8)((u8)(state + 10u) >> 1);
    return state;
}

/* These polynomial recurrences deliberately keep every intermediate state
 * narrow.  The input is volatile and the count is supplied by the caller so
 * the multiply/add/xor/constant-left-shift sequence cannot be folded away. */
static __attribute__((noinline)) u8 narrow_byte_polynomial(
    const volatile u8 *values, unsigned count, u8 seed)
{
    u8 state = seed;
    for (unsigned i = 0; i < count; ++i) {
        u8 input = values[i % 11u];
        u8 product = (u8)(state * 33u);
        u8 shifted = (u8)(input << 3);
        state = (u8)((u8)(product + input) ^ shifted);
    }
    return state;
}

/* The product is observed both after a right shift and in a comparison before
 * the next recurrence step.  The byte shift counter intentionally wraps
 * through 255 to zero during the count-seven case. */
static __attribute__((noinline)) u16 narrow_byte_polynomial_guard(
    const volatile u8 *values, unsigned count, u8 seed)
{
    u8 state = seed;
    u16 observed = 0;
    u8 shift_count = 254u;
    for (unsigned i = 0; i < count; ++i) {
        u8 input = values[i % 11u];
        u8 product = (u8)(state * (u8)(input | 1u));
        u8 shifted = (u8)(product >> 2);
        if (product >= 0x80u)
            observed = (u16)(observed + shifted + 0x31u);
        else
            observed = (u16)(observed + shifted);
        if (shift_count < 8u)
            observed = (u16)(observed + (u8)(product >> shift_count));
        state = (u8)((u8)(product + input) ^ (u8)(input << 3));
        if (shift_count == 0xffu)
            observed = (u16)(observed ^ 0x4000u);
        shift_count = (u8)(shift_count + 1u);
    }
    return (u16)(observed ^ (u16)state ^ (u16)shift_count);
}

static __attribute__((noinline)) u16 narrow_half_polynomial(
    const volatile u16 *values, unsigned count, u16 seed)
{
    u16 state = seed;
    for (unsigned i = 0; i < count; ++i) {
        u16 input = values[i % 8u];
        u16 product = (u16)(state * 257u);
        u16 shifted = (u16)(input << 5);
        state = (u16)((u16)(product + input) ^ shifted);
    }
    return state;
}

static __attribute__((noinline)) u32 narrow_half_polynomial_guard(
    const volatile u16 *values, unsigned count, u16 seed)
{
    u16 state = seed;
    u32 observed = 0;
    u8 shift_count = 254u;
    for (unsigned i = 0; i < count; ++i) {
        u16 input = values[i % 8u];
        u16 product = (u16)((u32)state * (u32)(input | 1u));
        u16 shifted = (u16)(product >> 4);
        if (product >= 0x8000u)
            observed = (observed + (u32)shifted + 0x1234u) & 0xffffffffu;
        else
            observed = (observed + shifted) & 0xffffffffu;
        state = (u16)((u16)(product + input) ^ (u16)(input << 5));
        if (shift_count == 0xffu)
            observed ^= 0x40000000u;
        shift_count = (u8)(shift_count + 1u);
    }
    return observed ^ (u32)state ^ (u32)shift_count;
}

static volatile u8 narrow_byte_values[] = {
    0xffu, 1u, 0x80u, 0x7fu, 2u, 0xfeu,
    0x55u, 0xabu, 0x80u, 0x81u, 0x80u,
};

static volatile u16 narrow_half_values[] = {
    0xffffu, 1u, 0x8000u, 0x7fffu,
    2u, 0xfffeu, 0x1234u, 0xedcbu,
};

static volatile u8 narrow_nested_values[] = {
    0xffu, 1u, 0x80u, 0x7fu,
    2u, 0xfeu, 0x55u, 0xabu,
    0x80u, 0x81u, 0x7eu, 3u,
};
static volatile unsigned narrow_byte_count = 11u;
static volatile unsigned narrow_half_count = 8u;
static volatile unsigned narrow_nested_rows = 3u;
static volatile unsigned narrow_nested_columns = 4u;

static unsigned test_narrow_arithmetic(void)
{
    static const u16 half_edges[] = {
        0u, 1u, 47u, 48u, 49u, 56u, 57u, 58u, 59u,
        65524u, 65525u, 65526u, 65527u, 65535u,
    };

    /* The wrapped interval is [0, 47] U [58, 255], with its ten-value
     * complement [48, 57].  Exercise every possible byte input. */
    for (unsigned i = 0; i < 256u; ++i) {
        u8 value = (u8)i;
        unsigned in_first = i < 48u || i >= 58u;
        unsigned in_second = i >= 48u && i < 58u;
        unsigned after_65_le = i >= 65u && i < 91u;
        unsigned after_65_gt = i < 65u || i >= 91u;
        if (narrow_byte_sub_lt(value) != in_first ||
            narrow_byte_sub_ge(value) != in_second ||
            narrow_byte_sub_le(value) != after_65_le ||
            narrow_byte_sub_gt(value) != after_65_gt)
            return 1;
    }

    for (unsigned i = 0; i < sizeof(half_edges) / sizeof(half_edges[0]);
         ++i) {
        u16 value = half_edges[i];
        unsigned wrapped = value >= 48u && value < 58u;
        if (narrow_half_sub_lt(value) == wrapped ||
            narrow_half_sub_ge(value) != wrapped)
            return 2;
    }

    if (narrow_byte_sum(narrow_byte_values, narrow_byte_count) != -128 ||
        narrow_half_sum(narrow_half_values, narrow_half_count) != -2)
        return 3;
    if (narrow_nested_conditional(narrow_nested_values, narrow_nested_rows,
                                  narrow_nested_columns) != 0x87u)
        return 4;
    if (narrow_sub_xor(narrow_byte_values, narrow_byte_count) != 108)
        return 5;
    if (narrow_compare_inside_loop(narrow_byte_values, narrow_byte_count) !=
        136u)
        return 6;
    if (narrow_shift_inside_loop(narrow_byte_values, narrow_byte_count) !=
        364u)
        return 7;

    static const u8 byte_seeds[] = {0u, 1u, 0x7fu, 0x80u, 0xffu};
    static const u16 half_seeds[] = {0u, 1u, 0x7fffu, 0x8000u, 0xffffu};
    static const unsigned recurrence_counts[] = {0u, 1u, 7u, 16u, 33u};

    /* Use an explicitly masked u32 reference so every narrow wrap is part of
     * the check rather than an accidental property of the host C types. */
    for (unsigned s = 0; s < sizeof(byte_seeds) / sizeof(byte_seeds[0]);
         ++s) {
        for (unsigned c = 0;
             c < sizeof(recurrence_counts) / sizeof(recurrence_counts[0]);
             ++c) {
            u32 reference = byte_seeds[s];
            for (unsigned i = 0; i < recurrence_counts[c]; ++i) {
                u32 shifted = (reference >> 1) & 0xffu;
                u32 polynomial = (reference & 1u) ? 0x9cu : 0u;
                reference = (shifted ^ polynomial) & 0xffu;
            }
            if (narrow_byte_shift_xor(byte_seeds[s], recurrence_counts[c]) !=
                (u8)reference)
                return 8;

            u32 guard_reference = byte_seeds[s];
            for (unsigned i = 0; i < recurrence_counts[c]; ++i)
                guard_reference = (((guard_reference + 10u) & 0xffu) >> 1) &
                                  0xffu;
            if (narrow_byte_add_shift_guard(byte_seeds[s],
                                           recurrence_counts[c]) !=
                (u8)guard_reference)
                return 9;
        }
    }

    for (unsigned s = 0; s < sizeof(half_seeds) / sizeof(half_seeds[0]);
         ++s) {
        for (unsigned c = 0;
             c < sizeof(recurrence_counts) / sizeof(recurrence_counts[0]);
             ++c) {
            u32 reference = half_seeds[s];
            u32 checksum = 0;
            for (unsigned i = 0; i < recurrence_counts[c]; ++i) {
                u32 shifted = (reference >> 1) & 0xffffu;
                u32 polynomial = (reference & 1u) ? 0xb400u : 0u;
                reference = (shifted ^ polynomial) & 0xffffu;
                checksum = (checksum + (reference & 0xffu)) & 0xffffffffu;
            }
            if (narrow_half_shift_xor(half_seeds[s], recurrence_counts[c]) !=
                (u16)reference)
                return 10;
            u32 expected = (reference << 16) | (checksum & 0xffffu);
            if (narrow_half_shift_xor_checksum(half_seeds[s],
                                              recurrence_counts[c]) !=
                expected)
                return 11;
        }
    }

    /* Widened references mask after every operation, including the product,
     * so wrap/sign-boundary seeds and counts zero, one, and many are covered
     * independently of the host integer width. */
    for (unsigned s = 0; s < sizeof(byte_seeds) / sizeof(byte_seeds[0]);
         ++s) {
        for (unsigned c = 0;
             c < sizeof(recurrence_counts) / sizeof(recurrence_counts[0]);
             ++c) {
            unsigned count = recurrence_counts[c];
            u32 reference = byte_seeds[s];
            for (unsigned i = 0; i < count; ++i) {
                u32 input = narrow_byte_values[i % 11u];
                u32 product = (reference * 33u) & 0xffu;
                u32 shifted = (input << 3) & 0xffu;
                reference = (((product + input) & 0xffu) ^ shifted) &
                            0xffu;
            }
            if (narrow_byte_polynomial(narrow_byte_values, count,
                                       byte_seeds[s]) != (u8)reference)
                return 12;

            reference = byte_seeds[s];
            u32 observed = 0;
            u32 shift_count = 254u;
            for (unsigned i = 0; i < count; ++i) {
                u32 input = narrow_byte_values[i % 11u];
                u32 product = (reference * (input | 1u)) & 0xffu;
                u32 shifted = product >> 2;
                if (product >= 0x80u)
                    observed = (observed + shifted + 0x31u) & 0xffffu;
                else
                    observed = (observed + shifted) & 0xffffu;
                if (shift_count < 8u)
                    observed = (observed + (product >> shift_count)) &
                               0xffffu;
                reference = ((((product + input) & 0xffu) ^
                              ((input << 3) & 0xffu)) & 0xffu);
                if (shift_count == 0xffu)
                    observed = (observed ^ 0x4000u) & 0xffffu;
                shift_count = (shift_count + 1u) & 0xffu;
            }
            u32 expected = (observed ^ reference ^ shift_count) & 0xffffu;
            if (narrow_byte_polynomial_guard(narrow_byte_values, count,
                                             byte_seeds[s]) != (u16)expected)
                return 13;
        }
    }

    for (unsigned s = 0; s < sizeof(half_seeds) / sizeof(half_seeds[0]);
         ++s) {
        for (unsigned c = 0;
             c < sizeof(recurrence_counts) / sizeof(recurrence_counts[0]);
             ++c) {
            unsigned count = recurrence_counts[c];
            u32 reference = half_seeds[s];
            for (unsigned i = 0; i < count; ++i) {
                u32 input = narrow_half_values[i % 8u];
                u32 product = (reference * 257u) & 0xffffu;
                u32 shifted = (input << 5) & 0xffffu;
                reference = (((product + input) & 0xffffu) ^ shifted) &
                            0xffffu;
            }
            if (narrow_half_polynomial(narrow_half_values, count,
                                       half_seeds[s]) != (u16)reference)
                return 14;

            reference = half_seeds[s];
            u32 observed = 0;
            u32 shift_count = 254u;
            for (unsigned i = 0; i < count; ++i) {
                u32 input = narrow_half_values[i % 8u];
                u32 product = (reference * (input | 1u)) & 0xffffu;
                u32 shifted = product >> 4;
                if (product >= 0x8000u)
                    observed += shifted + 0x1234u;
                else
                    observed += shifted;
                reference = ((((product + input) & 0xffffu) ^
                              ((input << 5) & 0xffffu)) & 0xffffu);
                if (shift_count == 0xffu)
                    observed ^= 0x40000000u;
                shift_count = (shift_count + 1u) & 0xffu;
            }
            u32 expected = observed ^ reference ^ shift_count;
            if (narrow_half_polynomial_guard(narrow_half_values, count,
                                             half_seeds[s]) != expected)
                return 15;
        }
    }
    return 0;
}

#endif

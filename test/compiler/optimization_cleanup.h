#ifndef RISCC_COMPILER_OPTIMIZATION_CLEANUP_H
#define RISCC_COMPILER_OPTIMIZATION_CLEANUP_H

/* Keep the source values runtime-visible while making the expected results
 * independent of the optimizer's extension decisions. */
static volatile signed char optimization_cleanup_signed8_values[] = {
    -128, -1, 0, 1, 127,
};
static volatile short optimization_cleanup_signed16_values[] = {
    -32768, -1, 0, 1, 32767,
};
static volatile unsigned char optimization_cleanup_unsigned8_values[] = {
    0u, 1u, 127u, 128u, 255u,
};
static volatile unsigned short optimization_cleanup_unsigned16_values[] = {
    0u, 1u, 32767u, 32768u, 65535u,
};

/* The low bit is the comparison result; the remaining bits retain the
 * original signed value after the comparison has been evaluated. */
static __attribute__((noinline)) u32 optimization_cleanup_signed8(
    signed char value)
{
    int widened = (int)value;
    return (u32)(value < 0) | ((u32)widened << 1);
}

static __attribute__((noinline)) u32 optimization_cleanup_signed16(
    short value)
{
    int widened = (int)value;
    return (u32)(value < 0) | ((u32)widened << 1);
}

/* A high-bit mask makes an accidental sign extension observable. */
static __attribute__((noinline)) u32 optimization_cleanup_unsigned8(
    unsigned char value)
{
    u32 widened = (u32)value;
    return (widened & 0xffffff00u) | (widened & 0x000000ffu);
}

static __attribute__((noinline)) u32 optimization_cleanup_unsigned16(
    unsigned short value)
{
    u32 widened = (u32)value;
    return (widened & 0xffff0000u) | (widened & 0x0000ffffu);
}

static volatile u32 optimization_cleanup_observed;

/* The full input remains observable, but only the truncated sign controls
 * whether to store. Upper bits must not affect these branches. */
static __attribute__((noinline)) void optimization_cleanup_byte_branch(u32 value)
{
    if ((signed char)value < 0)
        optimization_cleanup_observed = value;
}

static __attribute__((noinline)) void optimization_cleanup_half_branch(u32 value)
{
    if ((short)value >= 0)
        optimization_cleanup_observed = value;
}

static __attribute__((noinline)) u32 optimization_cleanup_returning(
    u32 first, u32 second)
{
    u32 result = first + second + 0x17u;
    optimization_cleanup_observed = result;
    return result + 1u;
}

/* The return value is intentionally discarded, but the callee's volatile
 * observation requires that the call itself remain. */
static __attribute__((noinline)) void optimization_cleanup_discard(
    u32 first, u32 second)
{
    (void)optimization_cleanup_returning(first, second);
}

typedef u32 (*optimization_cleanup_binary_fn)(u32, u32);

static __attribute__((noinline)) u32 optimization_cleanup_tail_leaf(
    u32 first, u32 second)
{
    return (first ^ 0x55u) + second * 3u;
}

static optimization_cleanup_binary_fn volatile optimization_cleanup_target =
    optimization_cleanup_tail_leaf;

/* Returning the indirect call directly keeps this wrapper tail-call eligible
 * while retaining both arguments and the callee's return value. */
static __attribute__((noinline)) u32 optimization_cleanup_indirect(
    u32 first, u32 second)
{
    return optimization_cleanup_target(first, second);
}

/* Keep these wrappers in the target-native type: unsigned int is 16 bits on
 * RC16/Nano and 32 bits on RC32.  The frame is deliberately larger than 256
 * bytes, but only a few volatile elements are touched. */
typedef unsigned int optimization_cleanup_native;
typedef optimization_cleanup_native (*optimization_cleanup_native_fn)(
    optimization_cleanup_native);
typedef optimization_cleanup_native (*optimization_cleanup_three_fn)(
    optimization_cleanup_native, optimization_cleanup_native,
    optimization_cleanup_native);

/* Keep these masks in the target-native unsigned type.  The source values are
 * explicitly u32 constants so RC16 also tests the intended truncation at the
 * native operation boundary. */
static volatile unsigned int optimization_cleanup_mask_values[] = {
    (unsigned int)(u32)0x00000000u,
    (unsigned int)(u32)0x0000ff00u,
    (unsigned int)(u32)0x12345678u,
    (unsigned int)(u32)0xffff8000u,
    (unsigned int)(u32)0xffffffffu,
    (unsigned int)(u32)0x80000000u,
    (unsigned int)(u32)0xffff00ffu,
    (unsigned int)(u32)0x5555aaaau,
};

static __attribute__((noinline)) unsigned int
optimization_cleanup_mask_adjacent(unsigned int value)
{
    return (value & (unsigned int)255u) ^
           ((value & (unsigned int)65280u) >> 8);
}

static __attribute__((noinline)) unsigned int
optimization_cleanup_mask_sparse(unsigned int value)
{
    return (value & (unsigned int)21760u) >> 8;
}

static __attribute__((noinline)) unsigned int
optimization_cleanup_mask_shared(unsigned int value)
{
    return (value & (unsigned int)65280u) +
           ((value & (unsigned int)65280u) >> 8);
}

static volatile optimization_cleanup_native optimization_cleanup_native_seen;
static volatile optimization_cleanup_native optimization_cleanup_three_seen[3];

static __attribute__((noinline)) optimization_cleanup_native
optimization_cleanup_native_prefix(optimization_cleanup_native value)
{
    return (optimization_cleanup_native)(value + 3u);
}

static __attribute__((noinline)) optimization_cleanup_native
optimization_cleanup_native_leaf(optimization_cleanup_native value)
{
    optimization_cleanup_native_seen = value;
    return (optimization_cleanup_native)((value ^ 0x5au) + 7u);
}

static optimization_cleanup_native_fn volatile
    optimization_cleanup_native_target = optimization_cleanup_native_leaf;

/* Branch-derived facts must describe the particular edge and the current
 * value, including when a call or a later loop iteration replaces it. */
static __attribute__((noinline)) optimization_cleanup_native
optimization_cleanup_equal_constant(optimization_cleanup_native value)
{
    if (value == 5u) {
        optimization_cleanup_native_seen = 5u;
        return 5u;
    }
    optimization_cleanup_native_seen = value;
    return (optimization_cleanup_native)(value + 1u);
}

static __attribute__((noinline)) optimization_cleanup_native
optimization_cleanup_equal_call(optimization_cleanup_native value)
{
    if (value == 5u)
        value = optimization_cleanup_native_target(value);
    return value == 5u ? 0u : value;
}

static __attribute__((noinline)) optimization_cleanup_native
optimization_cleanup_equal_join(optimization_cleanup_native value,
                                unsigned choose)
{
    if (choose) {
        if (value != 5u)
            return value;
    } else {
        value = 6u;
    }
    optimization_cleanup_native_seen = value;
    return value;
}

static __attribute__((noinline)) optimization_cleanup_native
optimization_cleanup_zero_backedge(optimization_cleanup_native value)
{
    for (unsigned i = 0; i != 4; ++i) {
        if (value == 0u)
            value = 5u;
        value = (optimization_cleanup_native)(value + 1u);
    }
    return value;
}

static __attribute__((noinline)) optimization_cleanup_native
optimization_cleanup_large_indirect(optimization_cleanup_native value)
{
    volatile optimization_cleanup_native frame[256];
    frame[0] = value;
    frame[127] = (optimization_cleanup_native)(value ^ 0x33u);

    /* A live call before the final indirect return exercises link-save and
     * large-frame restoration while keeping the outgoing call to one native
     * argument. */
    optimization_cleanup_native active =
        optimization_cleanup_native_prefix(value);
    optimization_cleanup_native adjusted =
        (optimization_cleanup_native)(active + frame[0] + frame[127]);
    frame[255] = adjusted;
    return optimization_cleanup_native_target(adjusted);
}

static __attribute__((noinline)) unsigned
optimization_cleanup_large_indirect_case(void)
{
    volatile optimization_cleanup_native caller_state[4] = {
        0x1357u, 0x2468u, 0x369au, 0x47acu,
    };
    optimization_cleanup_native result =
        optimization_cleanup_large_indirect(9u);
    return result == 0x1cu && optimization_cleanup_native_seen == 0x4fu &&
                   caller_state[0] == 0x1357u &&
                   caller_state[1] == 0x2468u &&
                   caller_state[2] == 0x369au &&
                   caller_state[3] == 0x47acu
               ? 0u
               : 1u;
}

static __attribute__((noinline)) optimization_cleanup_native
optimization_cleanup_three_leaf(optimization_cleanup_native first,
                                optimization_cleanup_native second,
                                optimization_cleanup_native third)
{
    optimization_cleanup_three_seen[0] = first;
    optimization_cleanup_three_seen[1] = second;
    optimization_cleanup_three_seen[2] = third;
    return (optimization_cleanup_native)(first + second * 3u + third * 5u +
                                         7u);
}

static optimization_cleanup_three_fn volatile optimization_cleanup_three_target =
    optimization_cleanup_three_leaf;

/* The post-call addition makes this an ordinary indirect call, providing the
 * fallback case for profiles whose outgoing argument list needs R3. */
static __attribute__((noinline)) optimization_cleanup_native
optimization_cleanup_three_indirect(optimization_cleanup_native first,
                                    optimization_cleanup_native second,
                                    optimization_cleanup_native third)
{
    return (optimization_cleanup_native)(
        optimization_cleanup_three_target(first, second, third) + 1u);
}

/* This direct-return form is tail-call-shaped, but its three native outgoing
 * arguments exercise the R3 collision fallback in the indirect call lowering. */
static __attribute__((noinline)) optimization_cleanup_native
optimization_cleanup_three_returning(optimization_cleanup_native first,
                                     optimization_cleanup_native second,
                                     optimization_cleanup_native third)
{
    return optimization_cleanup_three_target(first, second, third);
}

static __attribute__((noinline)) unsigned
optimization_cleanup_three_indirect_case(void)
{
    volatile optimization_cleanup_native caller_value = 0x5aa5u;
    optimization_cleanup_native result =
        optimization_cleanup_three_indirect(2u, 3u, 4u);
    if (result != 39u || optimization_cleanup_three_seen[0] != 2u ||
        optimization_cleanup_three_seen[1] != 3u ||
        optimization_cleanup_three_seen[2] != 4u ||
        caller_value != 0x5aa5u)
        return 1u;

    result = optimization_cleanup_three_returning(5u, 6u, 7u);
    return result == 65u && optimization_cleanup_three_seen[0] == 5u &&
                   optimization_cleanup_three_seen[1] == 6u &&
                   optimization_cleanup_three_seen[2] == 7u &&
                   caller_value == 0x5aa5u
               ? 0u
               : 1u;
}

static volatile optimization_cleanup_native
    optimization_cleanup_mul_values[] = {
        (optimization_cleanup_native)0u,
        (optimization_cleanup_native)1u,
        ~(optimization_cleanup_native)0u,
        (optimization_cleanup_native)1u <<
            (sizeof(optimization_cleanup_native) * 8u - 1u),
        ((optimization_cleanup_native)1u <<
         (sizeof(optimization_cleanup_native) * 8u - 2u)),
        (optimization_cleanup_native)0x1234u,
        (optimization_cleanup_native)0xaaaau,
    };
static volatile optimization_cleanup_native
    optimization_cleanup_mul_reference_factors[] = {
        (optimization_cleanup_native)17u,
        (optimization_cleanup_native)7u,
        (optimization_cleanup_native)24u,
        (optimization_cleanup_native)(0u - 7u),
        (optimization_cleanup_native)(0u - 17u),
    };

static __attribute__((noinline)) optimization_cleanup_native
optimization_cleanup_mul17(optimization_cleanup_native value)
{
    return (optimization_cleanup_native)(value *
                                         (optimization_cleanup_native)17u);
}

static __attribute__((noinline)) optimization_cleanup_native
optimization_cleanup_mul7(optimization_cleanup_native value)
{
    return (optimization_cleanup_native)(value *
                                         (optimization_cleanup_native)7u);
}

static __attribute__((noinline)) optimization_cleanup_native
optimization_cleanup_mul24(optimization_cleanup_native value)
{
    return (optimization_cleanup_native)(value *
                                         (optimization_cleanup_native)24u);
}

static __attribute__((noinline)) optimization_cleanup_native
optimization_cleanup_mul_neg7(optimization_cleanup_native value)
{
    return (optimization_cleanup_native)(
        value * (optimization_cleanup_native)(0u - 7u));
}

static __attribute__((noinline)) optimization_cleanup_native
optimization_cleanup_mul_neg17(optimization_cleanup_native value)
{
    return (optimization_cleanup_native)(
        value * (optimization_cleanup_native)(0u - 17u));
}

static __attribute__((noinline)) optimization_cleanup_native
optimization_cleanup_mul_reference(optimization_cleanup_native value,
                                   unsigned index)
{
    volatile optimization_cleanup_native multiplier =
        optimization_cleanup_mul_reference_factors[index];
    return (optimization_cleanup_native)(value * multiplier);
}

static optimization_cleanup_native optimization_cleanup_dot_left[] = {
    (optimization_cleanup_native)0u,
    (optimization_cleanup_native)1u,
    (optimization_cleanup_native)0xffffu,
    (optimization_cleanup_native)0x8000u,
    (optimization_cleanup_native)0x1234u,
    (optimization_cleanup_native)0xff00u,
    (optimization_cleanup_native)0x55aau,
    (optimization_cleanup_native)0xaaaau,
    (optimization_cleanup_native)0x1357u,
    (optimization_cleanup_native)0x2468u,
    (optimization_cleanup_native)0x369au,
    (optimization_cleanup_native)0x47acu,
    (optimization_cleanup_native)0x7fffu,
    (optimization_cleanup_native)0x8001u,
    (optimization_cleanup_native)0xdeadu,
    (optimization_cleanup_native)0xbeefu,
    (optimization_cleanup_native)0xffffu,
};
static optimization_cleanup_native optimization_cleanup_dot_right[] = {
    (optimization_cleanup_native)0xffffu,
    (optimization_cleanup_native)3u,
    (optimization_cleanup_native)7u,
    (optimization_cleanup_native)11u,
    (optimization_cleanup_native)13u,
    (optimization_cleanup_native)17u,
    (optimization_cleanup_native)19u,
    (optimization_cleanup_native)23u,
    (optimization_cleanup_native)29u,
    (optimization_cleanup_native)31u,
    (optimization_cleanup_native)37u,
    (optimization_cleanup_native)41u,
    (optimization_cleanup_native)43u,
    (optimization_cleanup_native)47u,
    (optimization_cleanup_native)53u,
    (optimization_cleanup_native)59u,
    (optimization_cleanup_native)61u,
};
static volatile unsigned optimization_cleanup_dot_lengths[] = {
    0u, 1u, 2u, 3u, 4u, 5u, 6u, 7u, 8u,
    9u, 10u, 11u, 12u, 13u, 14u, 15u, 16u, 17u,
};

static __attribute__((noinline)) optimization_cleanup_native
optimization_cleanup_dot_native(const optimization_cleanup_native *left,
                                const optimization_cleanup_native *right,
                                unsigned length)
{
    optimization_cleanup_native total = (optimization_cleanup_native)0u;
    for (unsigned i = 0u; i < length; ++i)
        total = (optimization_cleanup_native)(
            total + (optimization_cleanup_native)(left[i] * right[i]));
    return total;
}

static __attribute__((noinline)) optimization_cleanup_native
optimization_cleanup_dot_reference(
    const volatile optimization_cleanup_native *left,
    const volatile optimization_cleanup_native *right, unsigned length)
{
    optimization_cleanup_native total = (optimization_cleanup_native)0u;
    for (unsigned i = 0u; i < length; ++i) {
        volatile optimization_cleanup_native left_value = left[i];
        volatile optimization_cleanup_native right_value = right[i];
        total = (optimization_cleanup_native)(
            total + (optimization_cleanup_native)(left_value * right_value));
    }
    return total;
}

static u32 optimization_cleanup_sign_extend8(u32 value)
{
    u32 low = value & 0xffu;
    return (low & 0x80u) ? (low | 0xffffff00u) : low;
}

static u32 optimization_cleanup_sign_extend16(u32 value)
{
    u32 low = value & 0xffffu;
    return (low & 0x8000u) ? (low | 0xffff0000u) : low;
}

static u32 optimization_cleanup_narrow_expected(u32 first, u32 second,
                                                u32 third, u32 fourth,
                                                u32 fifth)
{
    u32 result = optimization_cleanup_sign_extend8(first);
    result += optimization_cleanup_sign_extend16(second) * 3u;
    result ^= (third & 0xffu) << 7;
    result += (fourth & 0xffffu) * 5u;
    result ^= optimization_cleanup_sign_extend8(fifth) << 13;
    return result;
}

static volatile u32 optimization_cleanup_narrow_runtime[][5] = {
    {0x00000000u, 0x00000001u, 0x00000002u, 0x00000003u,
     0x00000004u},
    {0xabcdef01u, 0x12345680u, 0xdeadbe7fu, 0x76543210u,
     0xface0080u},
    {0x800000ffu, 0xffff8000u, 0x12345680u, 0xaaaa8001u,
     0x0000007fu},
    {0x13579bdfu, 0x2468ace0u, 0xffff00ffu, 0xdeadffffu,
     0x87654321u},
    {0xffffffffu, 0x00007fffu, 0x80000000u, 0x00008000u,
     0xffff7fffu},
    {0x01020304u, 0x05060708u, 0x090a0b0cu, 0x0d0e0f10u,
     0x11121314u},
};

static __attribute__((noinline)) u32 optimization_cleanup_narrow_stack(
    signed char first, short second, unsigned char third,
    unsigned short fourth, signed char fifth)
{
    u32 result = (u32)(int)first;
    result += (u32)(int)second * 3u;
    result ^= (u32)third << 7;
    result += (u32)fourth * 5u;
    result ^= (u32)(int)fifth << 13;
    return result;
}

typedef u32 (*optimization_cleanup_narrow_many_fn)(
    signed char, short, unsigned char, unsigned short, signed char);

static __attribute__((noinline)) u32 optimization_cleanup_narrow_indirect_leaf(
    signed char first, short second, unsigned char third,
    unsigned short fourth, signed char fifth)
{
    u32 result = (u32)(int)first;
    result += (u32)(int)second * 3u;
    result ^= (u32)third << 7;
    result += (u32)fourth * 5u;
    result ^= (u32)(int)fifth << 13;
    return result;
}

static optimization_cleanup_narrow_many_fn volatile
    optimization_cleanup_narrow_indirect_target =
        optimization_cleanup_narrow_indirect_leaf;

static __attribute__((noinline)) u32 optimization_cleanup_narrow_indirect(
    u32 first, u32 second, u32 third, u32 fourth, u32 fifth)
{
    return optimization_cleanup_narrow_indirect_target(first, second, third,
                                                       fourth, fifth);
}

typedef struct optimization_cleanup_node {
    optimization_cleanup_native payload;
    struct optimization_cleanup_node *next;
} optimization_cleanup_node;

static optimization_cleanup_node optimization_cleanup_nodes[4] = {
    {11u, &optimization_cleanup_nodes[1]},
    {22u, &optimization_cleanup_nodes[2]},
    {33u, &optimization_cleanup_nodes[3]},
    {44u, 0},
};
static volatile unsigned optimization_cleanup_reverse_head = 0u;

static __attribute__((noinline)) optimization_cleanup_node *
optimization_cleanup_reverse(optimization_cleanup_node *head)
{
    optimization_cleanup_node *previous = 0;
    while (head) {
        optimization_cleanup_node *next = head->next;
        head->next = previous;
        previous = head;
        head = next;
    }
    return previous;
}

static __attribute__((noinline)) unsigned
optimization_cleanup_reverse_case(void)
{
    unsigned start = optimization_cleanup_reverse_head;
    if (start != 0u)
        return 4u;
    optimization_cleanup_node *head = &optimization_cleanup_nodes[start];
    head = optimization_cleanup_reverse(head);
    if (head != &optimization_cleanup_nodes[3] ||
        head->next != &optimization_cleanup_nodes[2] ||
        head->next->next != &optimization_cleanup_nodes[1] ||
        head->next->next->next != &optimization_cleanup_nodes[0] ||
        head->next->next->next->next != 0 || head->payload != 44u ||
        head->next->payload != 33u)
        return 1u;

    head = optimization_cleanup_reverse(head);
    if (head != &optimization_cleanup_nodes[0] ||
        head->next != &optimization_cleanup_nodes[1] ||
        head->next->next != &optimization_cleanup_nodes[2] ||
        head->next->next->next != &optimization_cleanup_nodes[3] ||
        head->next->next->next->next != 0 || head->payload != 11u ||
        head->next->next->payload != 33u)
        return 2u;

    head = optimization_cleanup_reverse(head);
    return head == &optimization_cleanup_nodes[3] &&
                   head->next == &optimization_cleanup_nodes[2] &&
                   head->next->next == &optimization_cleanup_nodes[1] &&
                   head->next->next->next == &optimization_cleanup_nodes[0]
               ? 0u
               : 3u;
}

static volatile optimization_cleanup_native optimization_cleanup_affine_data[16];
static volatile optimization_cleanup_native optimization_cleanup_affine_indices[] = {
    1u, 4u, 7u,
};
static volatile optimization_cleanup_native optimization_cleanup_affine_seeds[] = {
    0x12u, 0x3456u, 0xff00u,
};

static __attribute__((noinline)) unsigned
optimization_cleanup_affine_probe(optimization_cleanup_native index,
                                  optimization_cleanup_native value)
{
    volatile optimization_cleanup_native *base =
        optimization_cleanup_affine_data;
    volatile optimization_cleanup_native *left = base + index;
    volatile optimization_cleanup_native *right = left + 3u;
    volatile optimization_cleanup_native *cancel = right - 3u;
    *left = value;
    *right = (optimization_cleanup_native)(value + 1u);
    *cancel = (optimization_cleanup_native)(*cancel + 2u);
    return *left == (optimization_cleanup_native)(value + 2u) &&
                   *right == (optimization_cleanup_native)(value + 1u)
               ? 0u
               : 1u;
}

static volatile optimization_cleanup_native optimization_cleanup_diamond_seen[2];

static __attribute__((noinline)) optimization_cleanup_native
optimization_cleanup_diamond_equal(optimization_cleanup_native choose,
                                    optimization_cleanup_native first,
                                    optimization_cleanup_native second)
{
    if (choose & 1u) {
        optimization_cleanup_native left = first;
        optimization_cleanup_diamond_seen[0] = left;
        return (optimization_cleanup_native)(left + 3u);
    }
    optimization_cleanup_native right = second;
    optimization_cleanup_diamond_seen[1] = right;
    return (optimization_cleanup_native)(right + 7u);
}

static __attribute__((noinline)) optimization_cleanup_native
optimization_cleanup_diamond_distinct(optimization_cleanup_native choose,
                                      optimization_cleanup_native first,
                                      optimization_cleanup_native second)
{
    if (choose & 1u) {
        optimization_cleanup_native left = first;
        optimization_cleanup_native right = second;
        optimization_cleanup_diamond_seen[0] = left;
        return (optimization_cleanup_native)((left ^ 0x33u) + right);
    }
    optimization_cleanup_native left = second;
    optimization_cleanup_native right = first;
    optimization_cleanup_diamond_seen[1] = right;
    return (optimization_cleanup_native)((right ^ 0x77u) + left);
}

static volatile optimization_cleanup_native optimization_cleanup_diamond_inputs[] = {
    5u, 5u, 7u, 11u, 0x1234u, 0x4321u, 0xffffu, 1u,
};

static volatile optimization_cleanup_native optimization_cleanup_nested_data[3][8] = {
    {1u, 2u, 3u, 4u, 5u, 6u, 7u, 8u},
    {11u, 12u, 13u, 14u, 15u, 16u, 17u, 18u},
    {21u, 22u, 23u, 24u, 25u, 26u, 27u, 28u},
};
static volatile optimization_cleanup_native optimization_cleanup_nested_seed = 5u;

static __attribute__((noinline)) optimization_cleanup_native
optimization_cleanup_nested_stride(optimization_cleanup_native seed)
{
    optimization_cleanup_native total = seed;
    optimization_cleanup_native outer = seed;
    for (optimization_cleanup_native row = 0; row != 3u; ++row) {
        outer = (optimization_cleanup_native)(outer + row + 1u);
        for (optimization_cleanup_native column = 0; column != 4u;
             ++column)
            total = (optimization_cleanup_native)(
                total + optimization_cleanup_nested_data[row][column * 2u] +
                outer + column);
    }
    return total;
}

/* Native-width sign masks must handle INT_MIN without signed negation.
 * Store explicit expected bit patterns so the reference cannot be lowered
 * through the same signed-shift sequence as the functions under test. */
static volatile struct optimization_cleanup_sign_case {
    unsigned int value;
    unsigned int mask;
    unsigned int magnitude;
} optimization_cleanup_sign_cases[] = {
    {0u, 0u, 0u},
    {1u, 0u, 1u},
    {~0u, ~0u, 1u},
    {~1u, ~0u, 2u},
    {~0u >> 1, 0u, ~0u >> 1},
    {1u << (sizeof(int) * 8u - 1u), ~0u,
     1u << (sizeof(int) * 8u - 1u)},
};

static __attribute__((noinline)) unsigned int
optimization_cleanup_sign_mask(int value)
{
    return (unsigned int)(value >> (sizeof(int) * 8u - 1u));
}

static __attribute__((noinline)) unsigned int
optimization_cleanup_magnitude(int value)
{
    unsigned int mask = (unsigned int)(value >> (sizeof(int) * 8u - 1u));
    return ((unsigned int)value ^ mask) - mask;
}

static __attribute__((noinline)) unsigned int
optimization_cleanup_sign_retained(int value, unsigned int salt)
{
    unsigned int mask = (unsigned int)(value >> (sizeof(int) * 8u - 1u));
    return ((unsigned int)value + salt) ^ mask;
}

static unsigned test_optimization_cleanup(void)
{
    static const u32 signed8_expected[] = {
        0xffffff01u, 0xffffffffu, 0u, 2u, 254u,
    };
    static const u32 signed16_expected[] = {
        0xffff0001u, 0xffffffffu, 0u, 2u, 0xfffeu,
    };

    for (unsigned i = 0;
         i < sizeof(optimization_cleanup_signed8_values) /
                 sizeof(optimization_cleanup_signed8_values[0]);
         ++i) {
        if (optimization_cleanup_signed8(
                optimization_cleanup_signed8_values[i]) !=
            signed8_expected[i])
            return 1;
    }
    for (unsigned i = 0;
         i < sizeof(optimization_cleanup_signed16_values) /
                 sizeof(optimization_cleanup_signed16_values[0]);
         ++i) {
        if (optimization_cleanup_signed16(
                optimization_cleanup_signed16_values[i]) !=
            signed16_expected[i])
            return 2;
    }
    for (unsigned i = 0;
         i < sizeof(optimization_cleanup_unsigned8_values) /
                 sizeof(optimization_cleanup_unsigned8_values[0]);
         ++i) {
        u32 value = optimization_cleanup_unsigned8_values[i];
        if (optimization_cleanup_unsigned8(
                optimization_cleanup_unsigned8_values[i]) != value)
            return 3;
    }
    for (unsigned i = 0;
         i < sizeof(optimization_cleanup_unsigned16_values) /
                 sizeof(optimization_cleanup_unsigned16_values[0]);
         ++i) {
        u32 value = optimization_cleanup_unsigned16_values[i];
        if (optimization_cleanup_unsigned16(
                optimization_cleanup_unsigned16_values[i]) != value)
            return 4;
    }

    optimization_cleanup_observed = 0u;
    optimization_cleanup_discard(0x1234u, 0x5678u);
    if (optimization_cleanup_observed != 0x68c3u)
        return 5;

    if (optimization_cleanup_indirect(0x12345678u, 9u) != 0x12345648u ||
        optimization_cleanup_indirect(0x10u, 7u) != 0x5au)
        return 6;
    if (optimization_cleanup_large_indirect_case())
        return 7;
    if (optimization_cleanup_three_indirect_case())
        return 8;

    optimization_cleanup_observed = 0;
    optimization_cleanup_byte_branch(0xffff007fu);
    if (optimization_cleanup_observed != 0)
        return 9;
    optimization_cleanup_byte_branch(0x12340080u);
    if (optimization_cleanup_observed != 0x12340080u)
        return 10;
    optimization_cleanup_half_branch(0x56788000u);
    if (optimization_cleanup_observed != 0x12340080u)
        return 11;
    optimization_cleanup_half_branch(0xffff7fffu);
    if (optimization_cleanup_observed != 0xffff7fffu)
        return 12;

    static const unsigned int mask_adjacent_expected[] = {
        0u, 255u, 46u, 128u, 0u, 0u, 255u, 0u,
    };
    static const unsigned int mask_sparse_expected[] = {
        0u, 85u, 84u, 0u, 85u, 0u, 0u, 0u,
    };
    static const unsigned int mask_shared_expected[] = {
        0u, 65535u, 22102u, 32896u, 65535u, 0u, 0u, 43690u,
    };

    for (unsigned i = 0;
         i < sizeof(optimization_cleanup_mask_values) /
                 sizeof(optimization_cleanup_mask_values[0]);
         ++i) {
        unsigned int value = optimization_cleanup_mask_values[i];
        if (optimization_cleanup_mask_adjacent(value) !=
            mask_adjacent_expected[i])
            return 13u + i;
        if (optimization_cleanup_mask_sparse(value) != mask_sparse_expected[i])
            return 21u + i;
        if (optimization_cleanup_mask_shared(value) != mask_shared_expected[i])
            return 29u + i;
    }

    unsigned reverse_status = optimization_cleanup_reverse_case();
    if (reverse_status)
        return 37u + reverse_status;

    for (unsigned i = 0; i < sizeof(optimization_cleanup_affine_indices) /
                                sizeof(optimization_cleanup_affine_indices[0]);
         ++i) {
        if (optimization_cleanup_affine_probe(
                optimization_cleanup_affine_indices[i],
                optimization_cleanup_affine_seeds[i]))
            return 40u + i;
    }

    if (optimization_cleanup_diamond_equal(
            0u, optimization_cleanup_diamond_inputs[0],
            optimization_cleanup_diamond_inputs[1]) != 12u ||
        optimization_cleanup_diamond_seen[1] != 5u ||
        optimization_cleanup_diamond_equal(
            1u, optimization_cleanup_diamond_inputs[2],
            optimization_cleanup_diamond_inputs[3]) != 10u ||
        optimization_cleanup_diamond_seen[0] != 7u ||
        optimization_cleanup_diamond_distinct(
            0u, optimization_cleanup_diamond_inputs[2],
            optimization_cleanup_diamond_inputs[3]) != 123u ||
        optimization_cleanup_diamond_seen[1] != 7u ||
        optimization_cleanup_diamond_distinct(
            1u, optimization_cleanup_diamond_inputs[4],
            optimization_cleanup_diamond_inputs[5]) != 21800u ||
        optimization_cleanup_diamond_seen[0] != 4660u ||
        optimization_cleanup_diamond_distinct(
            0u, optimization_cleanup_diamond_inputs[6],
            optimization_cleanup_diamond_inputs[7]) !=
            (optimization_cleanup_native)65417u ||
        optimization_cleanup_diamond_seen[1] != 65535u)
        return 44u;

    if (optimization_cleanup_nested_stride(optimization_cleanup_nested_seed) !=
        (optimization_cleanup_native)291u)
        return 45u;

    for (unsigned factor_index = 0u; factor_index < 5u; ++factor_index) {
        for (unsigned value_index = 0u;
             value_index < sizeof(optimization_cleanup_mul_values) /
                                sizeof(optimization_cleanup_mul_values[0]);
             ++value_index) {
            optimization_cleanup_native value =
                optimization_cleanup_mul_values[value_index];
            optimization_cleanup_native actual;
            switch (factor_index) {
            case 0u:
                actual = optimization_cleanup_mul17(value);
                break;
            case 1u:
                actual = optimization_cleanup_mul7(value);
                break;
            case 2u:
                actual = optimization_cleanup_mul24(value);
                break;
            case 3u:
                actual = optimization_cleanup_mul_neg7(value);
                break;
            default:
                actual = optimization_cleanup_mul_neg17(value);
                break;
            }
            if (actual != optimization_cleanup_mul_reference(
                                value, factor_index))
                return 46u + factor_index * 7u + value_index;
        }
    }

    optimization_cleanup_dot_left[0] = optimization_cleanup_mul_values[5];
    optimization_cleanup_dot_right[0] = optimization_cleanup_mul_values[6];
    for (unsigned length_index = 0u;
         length_index < sizeof(optimization_cleanup_dot_lengths) /
                            sizeof(optimization_cleanup_dot_lengths[0]);
         ++length_index) {
        unsigned length = optimization_cleanup_dot_lengths[length_index];
        if (optimization_cleanup_dot_native(
                optimization_cleanup_dot_left, optimization_cleanup_dot_right,
                length) != optimization_cleanup_dot_reference(
                                optimization_cleanup_dot_left,
                                optimization_cleanup_dot_right, length))
            return 82u + length_index;
    }

    for (unsigned row = 0u;
         row < sizeof(optimization_cleanup_narrow_runtime) /
                   sizeof(optimization_cleanup_narrow_runtime[0]);
         ++row) {
        u32 value = optimization_cleanup_narrow_runtime[row][0];
        u32 signed8 = optimization_cleanup_sign_extend8(value);
        u32 signed16 = optimization_cleanup_sign_extend16(value);
        u32 signed8_expected =
            ((signed8 & 0x80000000u) ? 1u : 0u) | (signed8 << 1);
        u32 signed16_expected =
            ((signed16 & 0x80000000u) ? 1u : 0u) | (signed16 << 1);
        if (optimization_cleanup_signed8(value) != signed8_expected)
            return 101u + row;
        if (optimization_cleanup_signed16(value) != signed16_expected)
            return 108u + row;
        if (optimization_cleanup_unsigned8(value) != (value & 0xffu))
            return 115u + row;
        if (optimization_cleanup_unsigned16(value) != (value & 0xffffu))
            return 122u + row;
    }

    for (unsigned row = 0u;
         row < sizeof(optimization_cleanup_narrow_runtime) /
                   sizeof(optimization_cleanup_narrow_runtime[0]);
         ++row) {
        u32 first = optimization_cleanup_narrow_runtime[row][0];
        u32 second = optimization_cleanup_narrow_runtime[row][1];
        u32 third = optimization_cleanup_narrow_runtime[row][2];
        u32 fourth = optimization_cleanup_narrow_runtime[row][3];
        u32 fifth = optimization_cleanup_narrow_runtime[row][4];
        u32 expected = optimization_cleanup_narrow_expected(
            first, second, third, fourth, fifth);
        if (optimization_cleanup_narrow_stack(first, second, third, fourth,
                                              fifth) != expected)
            return 130u + row;
        if (optimization_cleanup_narrow_indirect(first, second, third, fourth,
                                                 fifth) != expected)
            return 138u + row;
    }

    for (unsigned row = 0u;
         row < sizeof(optimization_cleanup_mask_values) /
                   sizeof(optimization_cleanup_mask_values[0]);
         ++row) {
        /* Include equality, adjacent and wraparound inputs at native width. */
        optimization_cleanup_native value =
            row < 3u ? row + 4u : optimization_cleanup_mask_values[row];
        optimization_cleanup_native expected =
            value == 5u ? 5u : (optimization_cleanup_native)(value + 1u);
        if (optimization_cleanup_equal_constant(value) != expected ||
            optimization_cleanup_native_seen != value)
            return 146u + row;
        expected = value == 5u ? 0x66u : value;
        if (optimization_cleanup_equal_call(value) != expected)
            return 154u + row;
        for (unsigned choose = 0; choose != 2; ++choose) {
            optimization_cleanup_native_seen = 0x1234u;
            expected = choose ? value : 6u;
            if (optimization_cleanup_equal_join(value, choose) != expected ||
                optimization_cleanup_native_seen !=
                    (choose && value != 5u ? 0x1234u : expected))
                return 162u + row;
        }
        /* Volatile reference storage avoids reusing the candidate's
         * register-value relationships while evaluating the expected value. */
        volatile optimization_cleanup_native reference = value;
        for (unsigned step = 0; step != 4; ++step) {
            if (reference == 0u)
                reference = 5u;
            reference = (optimization_cleanup_native)(reference + 1u);
        }
        if (optimization_cleanup_zero_backedge(value) != reference)
            return 170u + row;
    }

    for (unsigned row = 0u;
         row < sizeof(optimization_cleanup_sign_cases) /
                   sizeof(optimization_cleanup_sign_cases[0]); ++row) {
        unsigned int value = optimization_cleanup_sign_cases[row].value;
        unsigned int mask = optimization_cleanup_sign_cases[row].mask;
        unsigned int magnitude =
            optimization_cleanup_sign_cases[row].magnitude;
        if (optimization_cleanup_sign_mask((int)value) != mask ||
            optimization_cleanup_magnitude((int)value) != magnitude ||
            optimization_cleanup_sign_retained((int)value, row) !=
                ((unsigned int)(value + row) ^ mask))
            return 178u + row;
    }

    return 0;
}

#endif

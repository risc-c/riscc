#ifndef RISCC_COMPILER_PRIVATE_CALLS_H
#define RISCC_COMPILER_PRIVATE_CALLS_H

typedef __UINTPTR_TYPE__ private_word;

static __attribute__((noinline)) private_word
private_call_leaf(private_word value)
{
    return value + 3;
}

__attribute__((noinline)) private_word
private_call_public_leaf(private_word value)
{
    return value + 5;
}

static private_word (*volatile private_call_opaque)(private_word) =
    private_call_public_leaf;

/* An ordinary user keeps the leaf's distinct private link convention. */
__attribute__((noinline)) private_word
private_call_ordinary(private_word value)
{
    return private_call_leaf(value) + 1;
}

__attribute__((noinline)) private_word
private_call_saved_s(private_word value)
{
    value = private_call_public_leaf(value);
    [[clang::musttail]] return private_call_leaf(value);
}

__attribute__((noinline)) private_word
private_call_saved_stack(private_word value)
{
    value = private_call_opaque(value);
    [[clang::musttail]] return private_call_leaf(value);
}

static __attribute__((noinline)) private_word
private_call_to_public(private_word value)
{
    value = private_call_leaf(value);
    [[clang::musttail]] return private_call_public_leaf(value);
}

static __attribute__((noinline)) private_word
private_call_stack_to_public(private_word value)
{
    value = private_call_opaque(value);
    [[clang::musttail]] return private_call_public_leaf(value);
}

__attribute__((noinline)) private_word
private_call_large_frame(private_word value)
{
    volatile private_word frame[256];
    frame[255] = private_call_opaque(value);
    [[clang::musttail]] return private_call_leaf(frame[255]);
}

static __attribute__((noinline)) private_word
private_call_cycle_b(private_word value);

static __attribute__((noinline)) private_word
private_call_cycle_a(private_word value)
{
    if (!value)
        return 3;
    [[clang::musttail]] return private_call_cycle_b(value - 1);
}

static __attribute__((noinline)) private_word
private_call_cycle_b(private_word value)
{
    if (!value)
        return 5;
    [[clang::musttail]] return private_call_cycle_a(value - 1);
}

__attribute__((noinline)) private_word
private_call_enter_cycle(private_word value)
{
    [[clang::musttail]] return private_call_cycle_a(value);
}

static __attribute__((noinline)) private_word
private_arg_four(private_word a, private_word b, private_word c, private_word d)
{
    return (private_word)(((__UINT32_TYPE__)a + (__UINT32_TYPE__)b) ^
                          ((__UINT32_TYPE__)c * (__UINT32_TYPE__)d));
}

static __attribute__((noinline)) private_word
private_arg_six(private_word a, private_word b, private_word c,
                private_word d, private_word e, private_word f)
{
    private_word callback = private_call_opaque(
        (private_word)((__UINT32_TYPE__)a ^ (__UINT32_TYPE__)c ^
                       (__UINT32_TYPE__)e));
    return (private_word)((__UINT32_TYPE__)callback +
                          (__UINT32_TYPE__)a * (__UINT32_TYPE__)b +
                          (__UINT32_TYPE__)c * (__UINT32_TYPE__)d +
                          (__UINT32_TYPE__)e * (__UINT32_TYPE__)f);
}

static __attribute__((noinline)) __UINT32_TYPE__
private_arg_native_native_u32_u32(private_word a, private_word b,
                                  __UINT32_TYPE__ c, __UINT32_TYPE__ d)
{
    return (__UINT32_TYPE__)a + c + ((__UINT32_TYPE__)b ^ d);
}

static __attribute__((noinline)) private_word
private_arg_recur(private_word n, private_word a, private_word b,
                  private_word c)
{
    if (!n)
        return (private_word)(((__UINT32_TYPE__)a + (__UINT32_TYPE__)b) ^
                              (__UINT32_TYPE__)c);
    private_word x = private_arg_recur(
        (private_word)((__UINT32_TYPE__)n - 1),
        (private_word)((__UINT32_TYPE__)a + 1),
        (private_word)((__UINT32_TYPE__)b + 2),
        (private_word)((__UINT32_TYPE__)c + 3));
    return (private_word)((__UINT32_TYPE__)x + (__UINT32_TYPE__)a +
                          (__UINT32_TYPE__)c);
}

static __attribute__((noinline)) private_word
private_arg_escaped(private_word a, private_word b, private_word c,
                    private_word d)
{
    return (private_word)((__UINT32_TYPE__)a + (__UINT32_TYPE__)b +
                          (__UINT32_TYPE__)c + (__UINT32_TYPE__)d);
}

static private_word (*volatile private_arg_indirect)(
    private_word, private_word, private_word, private_word) =
    private_arg_escaped;

static __attribute__((noinline)) signed char
private_signed_byte(signed char a, signed char b)
{
    return (signed char)(a + b);
}

static __attribute__((noinline)) unsigned char
private_unsigned_byte(unsigned char a, unsigned char b)
{
    return (unsigned char)(a + b);
}

static __attribute__((noinline)) short
private_signed_half(short a, short b)
{
    return (short)((__INT32_TYPE__)a + b);
}

static __attribute__((noinline)) unsigned short
private_unsigned_half(unsigned short a, unsigned short b)
{
    return (unsigned short)((__UINT32_TYPE__)a + b);
}

static __attribute__((noinline)) signed char
private_signed_byte_bits(signed char a, signed char b)
{
    return (signed char)(a ^ b);
}

static __attribute__((noinline)) unsigned char
private_unsigned_byte_bits(unsigned char a, unsigned char b)
{
    return (unsigned char)(a ^ b);
}

static __attribute__((noinline)) short
private_signed_half_bits(short a, short b)
{
    return (short)(a ^ b);
}

static unsigned test_private_narrow_calls(void)
{
    static volatile unsigned short values[] = {
        0, 1, 127, 128, 255, 256, 32767, 32768, 65535
    };
    volatile unsigned char byte_result;
    volatile unsigned short half_result;
    for (unsigned i = 0; i != sizeof(values) / sizeof(values[0]); ++i) {
        unsigned short a = values[i];
        unsigned short b = values[(i + 1) % (sizeof(values) / sizeof(values[0]))];
        unsigned char byte_sum = (unsigned char)(a + b);
        unsigned short half_sum = (unsigned short)((__UINT32_TYPE__)a + b);
        __INT32_TYPE__ signed_byte = byte_sum < 128 ? byte_sum :
                                      (__INT32_TYPE__)byte_sum - 256;
        __INT32_TYPE__ signed_half = half_sum < 32768u ? half_sum :
                                      (__INT32_TYPE__)half_sum - 65536;
        /* Actual wide uses must still receive the appropriate extension. */
        if ((__INT32_TYPE__)private_signed_byte((signed char)a, (signed char)b)
            != signed_byte)
            return 1;
        if ((__UINT32_TYPE__)private_unsigned_byte((unsigned char)a,
                                                  (unsigned char)b) != byte_sum)
            return 2;
        if ((__INT32_TYPE__)private_signed_half((short)a, (short)b) != signed_half)
            return 3;
        if ((__UINT32_TYPE__)private_unsigned_half(a, b) != half_sum)
            return 4;
        /* Low-bit-only users need no extended result from a private call. */
        byte_result = private_signed_byte((signed char)a, (signed char)b);
        half_result = private_signed_half((short)a, (short)b);
        if (byte_result != byte_sum || half_result != half_sum)
            return 5;
        /* Private result conventions may follow opposite-signed consumers. */
        unsigned char byte_bits = (unsigned char)(a ^ b);
        __INT32_TYPE__ signed_bits = byte_bits < 128 ? byte_bits :
                                      (__INT32_TYPE__)byte_bits - 256;
        if ((__UINT32_TYPE__)(unsigned char)private_signed_byte_bits(
                (signed char)a, (signed char)b) != byte_bits)
            return 6;
        if ((__INT32_TYPE__)(signed char)private_unsigned_byte_bits(
                (unsigned char)a, (unsigned char)b) != signed_bits)
            return 7;
        if ((__UINT32_TYPE__)(unsigned short)private_signed_half_bits(
                (short)a, (short)b) != (unsigned short)(a ^ b))
            return 8;
    }
    return 0;
}

static unsigned test_private_argument_calls(void)
{
    static volatile private_word private_arg_inputs[] = {
        1, 3, 17, 257, 4093, 65521, 12345, 54321
    };
    static volatile __UINT32_TYPE__ private_arg_u32_inputs[] = {
        0x00000001u, 0x00010003u, 0x00110011u, 0x01000101u,
        0x10001001u, 0x7fff0001u, 0x80000003u, 0xfffe0001u
    };
    for (unsigned i = 0; i != 8; ++i) {
        private_word a = private_arg_inputs[i];
        private_word b = private_arg_inputs[(i + 1) & 7];
        private_word c = private_arg_inputs[(i + 2) & 7];
        private_word d = private_arg_inputs[(i + 3) & 7];
        private_word e = private_arg_inputs[(i + 4) & 7];
        private_word f = private_arg_inputs[(i + 5) & 7];
        __UINT32_TYPE__ c32 = private_arg_u32_inputs[i];
        __UINT32_TYPE__ d32 = private_arg_u32_inputs[(i + 3) & 7];
        __UINT32_TYPE__ wide_a = (__UINT32_TYPE__)a;
        __UINT32_TYPE__ wide_b = (__UINT32_TYPE__)b;
        __UINT32_TYPE__ wide_c = (__UINT32_TYPE__)c;
        __UINT32_TYPE__ wide_d = (__UINT32_TYPE__)d;
        __UINT32_TYPE__ wide_e = (__UINT32_TYPE__)e;
        __UINT32_TYPE__ wide_f = (__UINT32_TYPE__)f;

        private_word expected_four = (private_word)((wide_a + wide_b) ^
                                                     (wide_c * wide_d));
        if (private_arg_four(a, b, c, d) != expected_four)
            return 1;

        private_word callback_arg = (private_word)(wide_a ^ wide_c ^ wide_e);
        private_word expected_six = (private_word)(
            (__UINT32_TYPE__)callback_arg + 5u + wide_a * wide_b +
            wide_c * wide_d + wide_e * wide_f);
        if (private_arg_six(a, b, c, d, e, f) != expected_six)
            return 2;

        __UINT32_TYPE__ expected_split =
            wide_a + c32 + (wide_b ^ d32);
        if (private_arg_native_native_u32_u32(a, b, c32, d32) !=
            expected_split)
            return 3;

        private_word expected_recur = (private_word)(
            ((wide_a + 3u) + (wide_b + 6u)) ^ (wide_c + 9u));
        expected_recur = (private_word)(
            (__UINT32_TYPE__)expected_recur + wide_a + wide_c +
            (wide_a + 1u) + (wide_c + 3u) + (wide_a + 2u) +
            (wide_c + 6u));
        if (private_arg_recur(3, a, b, c) != expected_recur)
            return 4;

        private_word expected_escaped = (private_word)(
            wide_a + wide_b + wide_c + wide_d);
        if (private_arg_escaped(a, b, c, d) != expected_escaped ||
            private_arg_indirect(a, b, c, d) != expected_escaped)
            return 5;
    }
    return 0;
}

/* External linkage keeps the public three-register convention: d and e are
 * incoming stack arguments on both widths. Asymmetric arithmetic detects
 * swapped slots without exercising software multiplication in Min/Nano. */
__attribute__((noinline)) private_word
private_stack_target(private_word a, private_word b, private_word c,
                     private_word d, private_word e)
{
    return (private_word)((((__UINT32_TYPE__)a + (__UINT32_TYPE__)b) ^
                           (__UINT32_TYPE__)c) + (__UINT32_TYPE__)d +
                          ((__UINT32_TYPE__)e ^ 0x5a3cu));
}

__attribute__((noinline)) private_word
private_stack_forward(private_word a, private_word b, private_word c,
                      private_word d, private_word e)
{
    return private_stack_target(a, b, c, d, e);
}

__attribute__((noinline)) private_word
private_stack_branch(private_word a, private_word b, private_word c,
                     private_word d, private_word e)
{
    if (!a)
        return d;
    return private_stack_target(a, b, c, d, e);
}

__attribute__((noinline)) private_word
private_stack_frame(private_word a, private_word b, private_word c,
                    private_word d, private_word e)
{
    volatile private_word frame[260];
    /* Keep the complete frame, rather than letting SROA retain one element. */
    __asm__ volatile("" : : "r"(frame) : "memory");
    frame[259] = a;
#if defined(__OPTIMIZE__)
    /* At O0 the arguments still live in local allocas, not incoming slots. */
    [[clang::musttail]]
#endif
    return private_stack_target(frame[259], b, c, d, e);
}

__attribute__((noinline)) private_word
private_stack_after_call(private_word a, private_word b, private_word c,
                         private_word d, private_word e)
{
    a = private_call_opaque(a);
    return private_stack_target(a, b, c, d, e);
}

__attribute__((noinline)) private_word
private_stack_changed(private_word a, private_word b, private_word c,
                      private_word d, private_word e)
{
    return private_stack_target(a, b, c, e, (private_word)(d + 1u));
}

static unsigned test_stack_argument_tails(void)
{
    static volatile __UINT32_TYPE__ values[] = {
        1u, 3u, 0x00008000u, 0x80000001u,
        0xffffffffu, 0x55555555u, 0xaaaaaaaau, 0x7fffffffu
    };
    for (unsigned i = 0; i < sizeof(values) / sizeof(values[0]); ++i) {
        private_word a = (private_word)values[i];
        private_word b = (private_word)(a ^ (private_word)0x55aau);
        private_word c = (private_word)(a + 3u);
        private_word d = (private_word)(a ^ (private_word)0xa55au);
        private_word e = (private_word)(a - 1u);
        private_word expected = private_stack_target(a, b, c, d, e);
        if (private_stack_forward(a, b, c, d, e) != expected)
            return 1;
        if (private_stack_branch(a, b, c, d, e) != expected ||
            private_stack_branch(0, b, c, d, e) != d)
            return 2;
        if (private_stack_frame(a, b, c, d, e) != expected)
            return 3;
        if (private_stack_after_call(a, b, c, d, e) !=
            private_stack_target((private_word)(a + 5u), b, c, d, e))
            return 4;
        if (private_stack_changed(a, b, c, d, e) !=
            private_stack_target(a, b, c, e, (private_word)(d + 1u)))
            return 5;
    }
    return 0;
}

static unsigned test_private_calls(void)
{
    /* Exercise every native bit, not just values that fit in RC16. */
    private_word value = (private_word)-201;
    for (unsigned i = 0; i != 4; ++i, value += 67) {
        if (private_call_ordinary(value) != (private_word)(value + 4))
            return 1;
        if (private_call_saved_s(value) != (private_word)(value + 8))
            return 2;
        if (private_call_saved_stack(value) != (private_word)(value + 8))
            return 3;
        if (private_call_to_public(value) != (private_word)(value + 8))
            return 4;
        if (private_call_stack_to_public(value) != (private_word)(value + 10))
            return 5;
        if (private_call_large_frame(value) != (private_word)(value + 8))
            return 6;
        if (private_call_enter_cycle(i + 4) != ((i & 1) ? 5 : 3))
            return 7;
    }
    if (test_private_narrow_calls())
        return 8;
    if (test_private_argument_calls())
        return 9;
    if (test_stack_argument_tails())
        return 10;
    return 0;
}

#endif

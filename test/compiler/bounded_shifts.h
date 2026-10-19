#ifndef RISCC_COMPILER_BOUNDED_SHIFTS_H
#define RISCC_COMPILER_BOUNDED_SHIFTS_H

/* unsigned/int are native-width on both RC16 and RC32. Keep the counts
 * variable at the call boundary so lowering must handle all four cases. */
static __attribute__((noinline)) unsigned bounded_shl(unsigned value,
                                                    unsigned count)
{
    return value << (count & 3u);
}

static __attribute__((noinline)) unsigned bounded_lshr(unsigned value,
                                                     unsigned count)
{
    return value >> (count & 3u);
}

static __attribute__((noinline)) int bounded_ashr(int value, unsigned count)
{
    return value >> (count & 3u);
}

static __attribute__((noinline)) unsigned bounded_shift_live(
    unsigned value, unsigned count, unsigned a, unsigned b, unsigned c)
{
    return (value << (count & 1u)) + a + (b ^ c);
}

/* Keep a real induction variable: its range comes from the loop exit, not
 * an explicit mask. Test all directions with independently constant-shift
 * reference expressions below. */
static __attribute__((noinline)) unsigned bounded_shift_loop(unsigned value)
{
    unsigned result = 0;
#pragma clang loop unroll(disable)
    for (unsigned count = 0; count != 3; ++count)
        result ^= (value << count) ^ (value >> count) ^
                  (unsigned)((int)value >> count);
    return result;
}

static unsigned test_bounded_shifts(void)
{
    static volatile unsigned inputs[] = {
        0u, 1u, 3u, 127u, 128u, 255u, 256u, 0x7fffu, 0x8000u,
        ~0u >> 1, (~0u >> 1) + 1u, ~0u, (unsigned)0x89abcdeful
    };
    for (unsigned i = 0; i < sizeof(inputs) / sizeof(inputs[0]); ++i) {
        unsigned value = inputs[i];
        int signed_value = (int)value;
        unsigned loop_expected =
            value ^ (value << 1) ^ (value >> 1) ^
            (unsigned)(signed_value >> 1) ^ (value << 2) ^ (value >> 2) ^
            (unsigned)(signed_value >> 2);
        if (bounded_shift_loop(value) != loop_expected)
            return 5;
        for (unsigned count = 0; count != 16; ++count) {
            unsigned left, right;
            int arithmetic;
            /* The reference uses constant shifts, not the variable-shift
             * lowering being tested. Signed right shift is arithmetic on
             * RISC-C, including negative values and the sign-bit boundary. */
            switch (count & 3u) {
            case 0:
                left = value;
                right = value;
                arithmetic = signed_value;
                break;
            case 1:
                left = value << 1;
                right = value >> 1;
                arithmetic = signed_value >> 1;
                break;
            case 2:
                left = value << 2;
                right = value >> 2;
                arithmetic = signed_value >> 2;
                break;
            default:
                left = value << 3;
                right = value >> 3;
                arithmetic = signed_value >> 3;
                break;
            }
            if (bounded_shl(value, count) != left)
                return 1;
            if (bounded_lshr(value, count) != right)
                return 2;
            if (bounded_ashr(signed_value, count) != arithmetic)
                return 3;
            unsigned a = inputs[(i + 1u) % 13u];
            unsigned b = inputs[(i + 2u) % 13u];
            unsigned c = inputs[(i + 3u) % 13u];
            unsigned shifted = (count & 1u) ? value << 1 : value;
            if (bounded_shift_live(value, count, a, b, c) !=
                (unsigned)(shifted + a + (b ^ c)))
                return 4;
        }
    }
    return 0;
}

#endif

#ifndef RISCC_COMPILER_BIASED_POINTER_H
#define RISCC_COMPILER_BIASED_POINTER_H

/* p is three bytes past the byte consumed by the loop. */
static volatile u8 biased_pointer_bytes[32];
/* Keep the entry pointer runtime-visible so the scanner cannot specialize the
 * load to this buffer's absolute address. */
static const volatile u8 *volatile biased_pointer_start =
    biased_pointer_bytes + 3;

static __attribute__((noinline)) const volatile u8 *biased_pointer_scan(
    const volatile u8 *p, u16 limit, const volatile u8 **next_out,
    u16 *value_out)
{
    u16 count = 0;
    u16 value = 0;

    while (count < limit) {
        u8 value8 = p[-3];
        if (value8 == 0) {
            break;
        }
        if (value8 == (u8)',') {
            break;
        }
        if (value8 < (u8)'0' || value8 > (u8)'9') {
            break;
        }
        value = (u16)(value * 10u + (u16)(value8 - (u8)'0'));
        ++p;
        ++count;
    }

    /* The caller checks both the current return value and this incremented
     * pointer, so this recurrence is observed inside the noinline scanner. */
    *next_out = p + 1;
    *value_out = value;
    return p;
}

static void biased_pointer_reference(const u8 *source, u16 length,
                                     u16 limit, u16 *current_out,
                                     u16 *next_out, u16 *value_out)
{
    u16 count = 0;
    u16 value = 0;

    while (count < limit) {
        u8 value8 = count < length ? source[count] : 0;
        if (value8 == 0) {
            break;
        }
        if (value8 == (u8)',') {
            break;
        }
        if (value8 < (u8)'0' || value8 > (u8)'9') {
            break;
        }
        value = (u16)(value * 10u + (u16)(value8 - (u8)'0'));
        ++count;
    }

    *current_out = (u16)(count + 3u);
    *next_out = (u16)(count + 4u);
    *value_out = value;
}

static __attribute__((noinline)) u16 biased_pointer_case(
    const u8 *source, u16 length, u16 limit)
{
    u16 i;
    u16 actual_value;
    u16 expected_current;
    u16 expected_next;
    u16 expected_value;
    const volatile u8 *current;
    const volatile u8 *next;

    /* Prefix and trailing margin keep p[-3] and current+1 in bounds. */
    for (i = 0; i < (u16)sizeof(biased_pointer_bytes); ++i)
        biased_pointer_bytes[i] = 0;
    for (i = 0; i < length; ++i)
        biased_pointer_bytes[i] = source[i];

    current = biased_pointer_scan(biased_pointer_start, limit, &next,
                                  &actual_value);
    biased_pointer_reference(source, length, limit, &expected_current,
                             &expected_next, &expected_value);

    return current == biased_pointer_bytes + expected_current &&
                   next == biased_pointer_bytes + expected_next &&
                   actual_value == expected_value
               ? 0
               : 1;
}

static __attribute__((noinline)) unsigned test_biased_pointer(void)
{
    static const u8 empty[] = { 0 };
    static const u8 one_digit[] = { (u8)'7' };
    static const u8 multiple_digits[] = {
        (u8)'1', (u8)'2', (u8)'3', (u8)','
    };
    static const u8 non_digit[] = { (u8)'x' };
    static const u8 limit_exit[] = {
        (u8)'4', (u8)'5', (u8)'6', (u8)'7'
    };

    if (biased_pointer_case(empty, 0, 8))
        return 1;
    if (biased_pointer_case(one_digit, 1, 8))
        return 2;
    if (biased_pointer_case(multiple_digits, 4, 8))
        return 3;
    if (biased_pointer_case(non_digit, 1, 8))
        return 4;
    if (biased_pointer_case(limit_exit, 4, 4))
        return 5;
    return 0;
}

#endif

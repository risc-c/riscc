#ifndef RISCC_LIBC_WORD_H
#define RISCC_LIBC_WORD_H

#include <stddef.h>
#include <stdint.h>

typedef unsigned int riscc_word_t __attribute__((__may_alias__));

#define RISCC_WORD_SIZE ((size_t)sizeof(riscc_word_t))
#define RISCC_WORD_ALIGN_MASK \
    ((uintptr_t)(sizeof(riscc_word_t) - (size_t)1))
#define RISCC_WORD_ALIGNED(pointer) \
    ((((uintptr_t)(pointer)) & RISCC_WORD_ALIGN_MASK) == (uintptr_t)0)

/* Each byte of these masks has the same value for every native word width. */
#define RISCC_WORD_ONES \
    ((riscc_word_t)(~(riscc_word_t)0) / (riscc_word_t)0xffu)
#define RISCC_WORD_HIGHS ((riscc_word_t)(RISCC_WORD_ONES << 7))
#define RISCC_WORD_HAS_ZERO(value) \
    ((((value) - RISCC_WORD_ONES) & ~(value) & RISCC_WORD_HIGHS) != 0)

/* Compare the first differing byte, optionally stopping at an earlier NUL.
 * The low event bit identifies that byte's high bit; XOR with events-1
 * masks every byte after it. Lower matching bytes do not affect the result.
 * RISC-C stores the first byte in the low end of a native word.
 */
static __attribute__((always_inline)) inline int riscc_word_compare(riscc_word_t a, riscc_word_t b,
    int stop_at_zero)
{
    const riscc_word_t low_bits = (riscc_word_t)~RISCC_WORD_HIGHS;
    const riscc_word_t diff = a ^ b;
    riscc_word_t events = ((diff & low_bits) + low_bits) | diff;
    if (stop_at_zero)
        events |= (a - RISCC_WORD_ONES) & ~a;
    events &= RISCC_WORD_HIGHS;
    const riscc_word_t mask = events ^ (events - 1);
    a &= mask;
    b &= mask;
    return (a > b) - (a < b);
}

#endif

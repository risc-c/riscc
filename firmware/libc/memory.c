/* Minimal freestanding memory routines used by LLVM aggregate lowering. */

#include <stddef.h>
#include <stdint.h>

#if !defined(__RISCC_NANO__) && !defined(__RISCC_MIN__)
#include "word.h"
#endif

void *memchr(const void *source, int value, size_t count)
{
    const unsigned char *in = (const unsigned char *)source;
    unsigned char byte = (unsigned char)value;

    while (count--)
    {
        if (*in == byte)
            return (void *)in;
        ++in;
    }
    return (void *)0;
}

int memcmp(const void *left, const void *right, size_t count)
{
    const unsigned char *a = (const unsigned char *)left;
    const unsigned char *b = (const unsigned char *)right;

#if !defined(__RISCC_NANO__) && !defined(__RISCC_MIN__)
    if ((((uintptr_t)a ^ (uintptr_t)b) & RISCC_WORD_ALIGN_MASK) ==
        (uintptr_t)0)
    {
        while (count && !RISCC_WORD_ALIGNED(a))
        {
            if (*a != *b)
                return (int)*a - (int)*b;
            ++a;
            ++b;
            --count;
        }
        const riscc_word_t *aw = (const riscc_word_t *)a;
        const riscc_word_t *bw = (const riscc_word_t *)b;
        while (count >= RISCC_WORD_SIZE)
        {
            const riscc_word_t left_word = *aw;
            const riscc_word_t right_word = *bw;
            if (left_word != right_word)
                return riscc_word_compare(left_word, right_word, 0);
            ++aw;
            ++bw;
            count -= RISCC_WORD_SIZE;
        }
        a = (const unsigned char *)aw;
        b = (const unsigned char *)bw;
    }
#endif

    while (count--)
    {
        if (*a != *b)
            return (int)*a - (int)*b;
        ++a;
        ++b;
    }
    return 0;
}

void *memcpy(void *restrict destination, const void *restrict source,
    size_t count)
{
    unsigned char *out = (unsigned char *)destination;
    const unsigned char *in = (const unsigned char *)source;

#if !defined(__RISCC_NANO__) && !defined(__RISCC_MIN__)
    if ((((uintptr_t)out ^ (uintptr_t)in) & RISCC_WORD_ALIGN_MASK) ==
        (uintptr_t)0)
    {
        while (count && !RISCC_WORD_ALIGNED(out))
        {
            *out++ = *in++;
            --count;
        }
        riscc_word_t *out_words = (riscc_word_t *)out;
        const riscc_word_t *in_words = (const riscc_word_t *)in;
        while (count >= RISCC_WORD_SIZE)
        {
            *out_words++ = *in_words++;
            count -= RISCC_WORD_SIZE;
        }
        out = (unsigned char *)out_words;
        in = (const unsigned char *)in_words;
    }
#endif

    while (count--)
        *out++ = *in++;
    return destination;
}

void *memmove(void *destination, const void *source, size_t count)
{
    unsigned char *out = (unsigned char *)destination;
    const unsigned char *in = (const unsigned char *)source;
    if ((uintptr_t)out < (uintptr_t)in)
    {
#if !defined(__RISCC_NANO__) && !defined(__RISCC_MIN__)
        if ((((uintptr_t)out ^ (uintptr_t)in) & RISCC_WORD_ALIGN_MASK) ==
            (uintptr_t)0)
        {
            while (count && !RISCC_WORD_ALIGNED(out))
            {
                *out++ = *in++;
                --count;
            }
            riscc_word_t *out_words = (riscc_word_t *)out;
            const riscc_word_t *in_words = (const riscc_word_t *)in;
            while (count >= RISCC_WORD_SIZE)
            {
                *out_words++ = *in_words++;
                count -= RISCC_WORD_SIZE;
            }
            out = (unsigned char *)out_words;
            in = (const unsigned char *)in_words;
        }
#endif
        while (count--)
            *out++ = *in++;
    }
    else if (out != in)
    {
        out += count;
        in += count;
#if !defined(__RISCC_NANO__) && !defined(__RISCC_MIN__)
        if ((((uintptr_t)out ^ (uintptr_t)in) & RISCC_WORD_ALIGN_MASK) ==
            (uintptr_t)0)
        {
            while (count && !RISCC_WORD_ALIGNED(out))
            {
                *--out = *--in;
                --count;
            }
            riscc_word_t *out_words = (riscc_word_t *)out;
            const riscc_word_t *in_words = (const riscc_word_t *)in;
            while (count >= RISCC_WORD_SIZE)
            {
                *--out_words = *--in_words;
                count -= RISCC_WORD_SIZE;
            }
            out = (unsigned char *)out_words;
            in = (const unsigned char *)in_words;
        }
#endif
        while (count--)
            *--out = *--in;
    }
    return destination;
}

void *memset(void *destination, int value, size_t count)
{
    unsigned char *out = (unsigned char *)destination;

#if !defined(__RISCC_NANO__) && !defined(__RISCC_MIN__)
    while (count && !RISCC_WORD_ALIGNED(out))
    {
        *out++ = (unsigned char)value;
        --count;
    }
    if (RISCC_WORD_ALIGNED(out))
    {
        riscc_word_t *out_words = (riscc_word_t *)out;
        riscc_word_t fill = (riscc_word_t)(unsigned char)value *
            RISCC_WORD_ONES;
        while (count >= RISCC_WORD_SIZE)
        {
            *out_words++ = fill;
            count -= RISCC_WORD_SIZE;
        }
        out = (unsigned char *)out_words;
    }
#endif

    while (count--)
        *out++ = (unsigned char)value;
    return destination;
}

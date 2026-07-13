/* Minimal freestanding memory routines used by LLVM aggregate lowering. */

#include <stddef.h>

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
    while (count--)
        *out++ = *in++;
    return destination;
}

void *memmove(void *destination, const void *source, size_t count)
{
    unsigned char *out = (unsigned char *)destination;
    const unsigned char *in = (const unsigned char *)source;
    if (out < in)
    {
        while (count--)
            *out++ = *in++;
    }
    else if (out != in)
    {
        out += count;
        in += count;
        while (count--)
            *--out = *--in;
    }
    return destination;
}

void *memset(void *destination, int value, size_t count)
{
    unsigned char *out = (unsigned char *)destination;
    while (count--)
        *out++ = (unsigned char)value;
    return destination;
}

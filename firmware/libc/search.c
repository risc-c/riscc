#include <stddef.h>

void *bsearch(const void *key, const void *base, size_t nmemb, size_t size,
    int (*compar)(const void *, const void *))
{
    const unsigned char *items = (const unsigned char *)base;

    while (nmemb)
    {
        size_t half = nmemb / 2u;
        const void *item = items + half * size;
        int order = compar(key, item);
        if (!order)
            return (void *)item;
        if (order < 0)
        {
            nmemb = half;
        }
        else
        {
            items = (const unsigned char *)item + size;
            nmemb -= half + 1u;
        }
    }
    return (void *)0;
}

void qsort(void *base, size_t nmemb, size_t size,
    int (*compar)(const void *, const void *))
{
    unsigned char *items = (unsigned char *)base;
    size_t index;

    if (size == 0)
        return;
    for (index = 0; index < nmemb; ++index)
    {
        size_t least = index;
        size_t scan;
        for (scan = index + 1u; scan < nmemb; ++scan)
        {
            if (compar(items + scan * size, items + least * size) < 0)
                least = scan;
        }
        if (least != index)
        {
            size_t byte;
            for (byte = 0; byte < size; ++byte)
            {
                unsigned char swap = items[index * size + byte];
                items[index * size + byte] = items[least * size + byte];
                items[least * size + byte] = swap;
            }
        }
    }
}

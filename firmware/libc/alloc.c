#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

struct free_block
{
    size_t total;
    struct free_block *next;
};

static struct free_block *free_head;

extern void *sbrk(ptrdiff_t increment);

static size_t block_size(size_t size)
{
    if (!size || size > SIZE_MAX - sizeof(size_t) - 1u)
        return 0;
    size += sizeof(size_t);
    return (size + 1u) & ~(size_t)1u;
}

void *malloc(size_t size)
{
    size_t wanted = block_size(size);
    struct free_block *previous = (struct free_block *)0;
    struct free_block *block = free_head;

    if (!wanted)
    {
        if (size)
            errno = ENOMEM;
        return (void *)0;
    }
    if (wanted > 32767u)
    {
        errno = ENOMEM;
        return (void *)0;
    }
    while (block)
    {
        while (block->next &&
            (uintptr_t)block + block->total == (uintptr_t)block->next)
        {
            block->total += block->next->total;
            block->next = block->next->next;
        }
        if (block->total >= wanted)
        {
            size_t remainder = block->total - wanted;
            if (remainder >= sizeof(struct free_block))
            {
                struct free_block *split =
                    (struct free_block *)((unsigned char *)block + wanted);
                split->total = remainder;
                split->next = block->next;
                if (previous)
                    previous->next = split;
                else
                    free_head = split;
                block->total = wanted;
            }
            else if (previous)
            {
                previous->next = block->next;
            }
            else
            {
                free_head = block->next;
            }
            return (unsigned char *)block + sizeof(size_t);
        }
        previous = block;
        block = block->next;
    }
    block = (struct free_block *)sbrk((ptrdiff_t)wanted);
    if (block == (struct free_block *)-1)
        return (void *)0;
    block->total = wanted;
    return (unsigned char *)block + sizeof(size_t);
}

void free(void *ptr)
{
    struct free_block *block;
    struct free_block *previous = (struct free_block *)0;
    struct free_block *current = free_head;

    if (!ptr)
        return;
    block = (struct free_block *)((unsigned char *)ptr - sizeof(size_t));
    while (current && (uintptr_t)current < (uintptr_t)block)
    {
        previous = current;
        current = current->next;
    }
    block->next = current;
    if (previous)
        previous->next = block;
    else
        free_head = block;
}

void *calloc(size_t nmemb, size_t size)
{
    size_t total;
    void *ptr;

    if (size && nmemb > SIZE_MAX / size)
    {
        errno = ENOMEM;
        return (void *)0;
    }
    total = nmemb * size;
    ptr = malloc(total);
    if (ptr)
        memset(ptr, 0, total);
    return ptr;
}

void *realloc(void *ptr, size_t size)
{
    struct free_block *block;
    void *replacement;
    size_t old_size;

    if (!ptr)
        return malloc(size);
    if (!size)
    {
        free(ptr);
        return (void *)0;
    }
    block = (struct free_block *)((unsigned char *)ptr - sizeof(size_t));
    old_size = block->total - sizeof(size_t);
    replacement = malloc(size);
    if (!replacement)
        return (void *)0;
    if (old_size > size)
        old_size = size;
    memcpy(replacement, ptr, old_size);
    free(ptr);
    return replacement;
}

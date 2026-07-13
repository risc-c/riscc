#include <errno.h>
#include <stddef.h>
#include <stdint.h>

extern unsigned char __heap_start[];
extern unsigned char __heap_end[];
extern void *__riscc_heap_limit(void);

static unsigned char *heap_break = __heap_start;

void *sbrk(ptrdiff_t increment)
{
    uintptr_t current = (uintptr_t)heap_break;
    uintptr_t ceiling = (uintptr_t)__heap_end;
    uintptr_t limit;
    unsigned int amount;

    if (increment < 0)
    {
        errno = EINVAL;
        return (void *)-1;
    }
    amount = (unsigned int)increment;
    if (current > ceiling || amount > ceiling - current)
    {
        errno = ENOMEM;
        return (void *)-1;
    }
    limit = (uintptr_t)__riscc_heap_limit();
    if (limit < current || amount > limit - current)
    {
        errno = ENOMEM;
        return (void *)-1;
    }
    heap_break = (unsigned char *)(current + amount);
    return (void *)current;
}

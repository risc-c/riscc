#include <stdarg.h>
#include "test.h"

volatile u32 rc32_global = 0x13579bdfu;
volatile u32 rc32_bss;
__thread volatile u32 rc32_tls_data = 0x2468ace0u;
_Thread_local volatile u32 rc32_tls_bss;

u32 rc32_stack_sum(u32 a, u32 b, u32 c, u32 d, u32 e)
{
    return a + b + c + d + e;
}

struct rc32_pair rc32_make_pair(u32 value)
{
    struct rc32_pair result = {
        value + 0x11111111u,
        value ^ 0xa5a5a5a5u,
    };
    return result;
}

struct rc32_large rc32_make_large(u32 value)
{
    struct rc32_large result = {{
        value + 1, value + 2, value + 3, value + 4,
    }};
    return result;
}

u32 rc32_varargs_sum(u32 seed, u32 count, ...)
{
    va_list ap;
    u32 result = seed;
    u32 index;

    va_start(ap, count);
    for (index = 0; index != count; ++index)
        result += va_arg(ap, u32);
    va_end(ap);
    return result;
}

u32 rc32_varargs_pair(u32 seed, u32 count, ...)
{
    va_list ap;
    struct rc32_pair pair;

    va_start(ap, count);
    pair = va_arg(ap, struct rc32_pair);
    va_end(ap);
    return seed + pair.first + pair.second;
}

u32 rc32_tls_update(u32 value)
{
    rc32_tls_data += value;
    rc32_tls_bss = value + value;
    return rc32_tls_data + rc32_tls_bss;
}

__attribute__((noinline)) u32 rc32_literal_long(u32 take_fast_path)
{
    if (take_fast_path)
        return rc32_global ^ 0x9ee8be99u;
    __asm__ volatile(".space 320" ::: "memory");
    return 0;
}

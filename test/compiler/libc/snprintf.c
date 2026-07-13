#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "test.h"

static int format_with_va(char *out, size_t size, const char *format, ...)
{
    int result;
    va_list arguments;
    va_start(arguments, format);
    result = vsnprintf(out, size, format, arguments);
    va_end(arguments);
    return result;
}

int main(void)
{
    char small[6];
    char full[32];
    char untouched = 'x';
    char one = 'x';

    CHECK(snprintf(small, sizeof(small), "%05d %s", -12, "xy") == 8, 1);
    CHECK(!strcmp(small, "-0012"), 2);
    CHECK(snprintf(&untouched, 0, "abc") == 3 && untouched == 'x', 3);
    CHECK(sprintf(full, "%-4c:%04x:%X:%lu", 'A', 0x2a, 0x2a,
        123456789UL) == 22,
        4);
    CHECK(!strcmp(full, "A   :002a:2A:123456789"), 5);
    CHECK(format_with_va(full, sizeof(full), "%ld/%u/%%", -2147483647L,
        65535u) == 19,
        6);
    CHECK(!strcmp(full, "-2147483647/65535/%"), 7);
    CHECK(snprintf(full, sizeof(full), "%p", (void *)0x1234u) == 4 &&
        !strcmp(full, "1234"),
        8);
    CHECK(snprintf(full, sizeof(full), "%-5s:%3i:%-04u", "x", -7, 12u) ==
        14 && !strcmp(full, "x    : -7:12  "),
        9);
    CHECK(snprintf(full, sizeof(full), "%p", (void *)0) == 4 &&
        !strcmp(full, "0000"),
        10);
    CHECK(snprintf(&one, 1, "x") == 1 && !one, 11);
    pass();
}

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "test.h"

static int call_vprintf(const char *format, ...)
{
    int result;
    va_list arguments;

    va_start(arguments, format);
    result = vprintf(format, arguments);
    va_end(arguments);
    return result;
}

static int call_vfprintf(FILE *stream, const char *format, ...)
{
    int result;
    va_list arguments;

    va_start(arguments, format);
    result = vfprintf(stream, format, arguments);
    va_end(arguments);
    return result;
}

static int call_vsprintf(char *string, const char *format, ...)
{
    int result;
    va_list arguments;

    va_start(arguments, format);
    result = vsprintf(string, format, arguments);
    va_end(arguments);
    return result;
}

int main(void)
{
    char line[8];
    char short_line[4];
    char formatted[12];
    char empty[1] = {'x'};

    CHECK(fgets(empty, sizeof(empty), stdin) == empty && !empty[0], 1);
    line[0] = 'x';
    CHECK(fgets(line, 0, stdin) == 0 && line[0] == 'x', 2);
    CHECK(fgetc(stdin) == 'Q' && getchar() == 'l', 3);
    CHECK(fgets(line, sizeof(line), stdin) == line, 4);
    CHECK(!strcmp(line, "ine\n"), 5);
    CHECK(putchar('P') == 'P', 6);
    CHECK(fputc('Q', stdout) == 'Q', 7);
    CHECK(fputc(':', stderr) == ':', 8);
    CHECK(fputs(line, stdout) == 0, 9);
    CHECK(fgets(short_line, sizeof(short_line), stdin) == short_line &&
        !strcmp(short_line, "abc"),
        10);
    CHECK(fgets(line, sizeof(line), stdin) == line && !strcmp(line, "def\n"),
        11);
    CHECK(getchar() == 'Z', 12);
    CHECK(printf("%s:%d", "p", 7) == 3, 13);
    CHECK(call_vprintf("/%03x", 0x2a) == 4, 14);
    CHECK(call_vfprintf(stderr, "/%s", "v") == 2, 15);
    CHECK(call_vsprintf(formatted, "%c:%s:%i", 'V', "ok", -3) == 7 &&
        !strcmp(formatted, "V:ok:-3"),
        16);
    CHECK(fputs("", stdout) == 0 && puts("") == 0, 17);
    CHECK(puts("!") == 0, 18);
    pass();
}

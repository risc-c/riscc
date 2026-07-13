#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

typedef void (*format_put)(void *context, int character);

static void put_character(format_put put, void *context, int character,
    int *count)
{
    put(context, character);
    ++*count;
}

static void put_repeat(format_put put, void *context, int character, int count,
    int *written)
{
    while (count--)
        put_character(put, context, character, written);
}

static void put_number(format_put put, void *context, unsigned long value,
    unsigned int base, int upper, int width, int left,
    int zero, int negative, int *written)
{
    char digits[10];
    unsigned int count = 0;
    int padding;

    do
    {
        unsigned int digit = (unsigned int)(value % base);
        digits[count++] = (char)(digit < 10u ? '0' + digit
            : (upper ? 'A' : 'a') + digit - 10u);
        value /= base;
    } while (value);
    padding = width - (int)count - negative;
    if (padding < 0)
        padding = 0;
    if (!left && !zero)
        put_repeat(put, context, ' ', padding, written);
    if (negative)
        put_character(put, context, '-', written);
    if (!left && zero)
        put_repeat(put, context, '0', padding, written);
    while (count)
        put_character(put, context, digits[--count], written);
    if (left)
        put_repeat(put, context, ' ', padding, written);
}

static void put_string(format_put put, void *context, const char *string,
    int width, int left, int *written)
{
    int length = 0;
    int padding;

    if (!string)
        string = "(null)";
    while (string[length])
        ++length;
    padding = width - length;
    if (padding < 0)
        padding = 0;
    if (!left)
        put_repeat(put, context, ' ', padding, written);
    while (*string)
        put_character(put, context, (unsigned char)*string++, written);
    if (left)
        put_repeat(put, context, ' ', padding, written);
}

static int vformat(format_put put, void *context, const char *format,
    va_list arguments)
{
    int written = 0;

    while (*format)
    {
        int left = 0;
        int zero = 0;
        int width = 0;
        int is_long = 0;
        int conversion;

        if (*format != '%')
        {
            put_character(put, context, (unsigned char)*format++, &written);
            continue;
        }
        ++format;
        while (*format == '-' || *format == '0')
        {
            if (*format == '-')
                left = 1;
            else
                zero = 1;
            ++format;
        }
        while (*format >= '0' && *format <= '9')
        {
            width = width * 10 + *format++ - '0';
        }
        if (*format == 'l')
        {
            is_long = 1;
            ++format;
        }
        conversion = (unsigned char)*format;
        if (*format)
            ++format;
        if (left)
            zero = 0;
        switch (conversion)
        {
        case '%':
        case 'c':
        {
            int character = conversion == '%' ? '%' : va_arg(arguments, int);
            int padding = width - 1;
            if (padding < 0)
                padding = 0;
            if (!left)
                put_repeat(put, context, ' ', padding, &written);
            put_character(put, context, character, &written);
            if (left)
                put_repeat(put, context, ' ', padding, &written);
            break;
        }
        case 's':
            put_string(put, context, va_arg(arguments, char *), width, left,
                &written);
            break;
        case 'd':
        case 'i':
        {
            unsigned long value;
            int negative;
            if (is_long)
            {
                long signed_value = va_arg(arguments, long);
                negative = signed_value < 0;
                value = negative ? 0UL - (unsigned long)signed_value
                        : (unsigned long)signed_value;
            }
            else
            {
                int signed_value = va_arg(arguments, int);
                negative = signed_value < 0;
                value = negative ? (unsigned long)(0u - (unsigned int)signed_value)
                        : (unsigned long)(unsigned int)signed_value;
            }
            put_number(put, context, value, 10, 0, width, left, zero, negative,
                    &written);
            break;
        }
        case 'u':
        case 'x':
        case 'X':
        {
            unsigned long value = is_long ? va_arg(arguments, unsigned long)
                    : (unsigned long)va_arg(arguments,
                    unsigned int);
            unsigned int base = conversion == 'u' ? 10u : 16u;
            put_number(put, context, value, base, conversion == 'X', width, left,
                    zero, 0, &written);
            break;
        }
        case 'p':
        {
            unsigned long value = (unsigned long)(uintptr_t)va_arg(arguments, void *);
            if (!width)
            {
                width = 4;
                zero = 1;
            }
            put_number(put, context, value, 16, 0, width, left, zero, 0, &written);
            break;
        }
        default:
            put_character(put, context, '%', &written);
            if (conversion)
                put_character(put, context, conversion, &written);
            break;
        }
    }
    return written;
}

struct file_sink
{
    FILE *stream;
};

static void file_put(void *context, int character)
{
    fputc(character, ((struct file_sink *)context)->stream);
}

struct string_sink
{
    char *next;
};

static void string_put(void *context, int character)
{
    struct string_sink *sink = (struct string_sink *)context;
    *sink->next++ = (char)character;
}

struct bounded_sink
{
    char *string;
    size_t size;
    size_t stored;
};

static void bounded_put(void *context, int character)
{
    struct bounded_sink *sink = (struct bounded_sink *)context;
    if (sink->size && sink->stored + 1u < sink->size)
        sink->string[sink->stored++] = (char)character;
}

int vfprintf(FILE *stream, const char *format, va_list arguments)
{
    struct file_sink sink = {stream};
    return vformat(file_put, &sink, format, arguments);
}

int fprintf(FILE *stream, const char *format, ...)
{
    int result;
    va_list arguments;
    va_start(arguments, format);
    result = vfprintf(stream, format, arguments);
    va_end(arguments);
    return result;
}

int vprintf(const char *format, va_list arguments)
{
    return vfprintf(stdout, format, arguments);
}

int printf(const char *format, ...)
{
    int result;
    va_list arguments;
    va_start(arguments, format);
    result = vfprintf(stdout, format, arguments);
    va_end(arguments);
    return result;
}

int vsprintf(char *string, const char *format, va_list arguments)
{
    struct string_sink sink = {string};
    int result = vformat(string_put, &sink, format, arguments);
    *sink.next = '\0';
    return result;
}

int sprintf(char *string, const char *format, ...)
{
    int result;
    va_list arguments;
    va_start(arguments, format);
    result = vsprintf(string, format, arguments);
    va_end(arguments);
    return result;
}

int vsnprintf(char *string, size_t size, const char *format,
    va_list arguments)
{
    struct bounded_sink sink = {string, size, 0};
    int result = vformat(bounded_put, &sink, format, arguments);
    if (size)
        string[sink.stored] = '\0';
    return result;
}

int snprintf(char *string, size_t size, const char *format, ...)
{
    int result;
    va_list arguments;
    va_start(arguments, format);
    result = vsnprintf(string, size, format, arguments);
    va_end(arguments);
    return result;
}

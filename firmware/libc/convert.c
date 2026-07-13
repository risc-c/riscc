#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <stdlib.h>

static int digit_value(int c)
{
    if (isdigit(c))
        return c - '0';
    if (c >= 'a' && c <= 'z')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'Z')
        return c - 'A' + 10;
    return -1;
}

static unsigned long parse_unsigned(const char *nptr, char **endptr, int base,
    int *negative, int *overflow_out)
{
    const char *scan = nptr;
    const char *first;
    unsigned long value = 0;
    unsigned long limit;
    int digit;
    int overflow = 0;

    if (overflow_out)
        *overflow_out = 0;
    while (isspace((unsigned char)*scan))
        ++scan;
    *negative = 0;
    if (*scan == '-' || *scan == '+')
    {
        *negative = *scan == '-';
        ++scan;
    }
    if (base == 0)
    {
        if (scan[0] == '0' && (scan[1] == 'x' || scan[1] == 'X') &&
            digit_value((unsigned char)scan[2]) >= 0 &&
            digit_value((unsigned char)scan[2]) < 16)
        {
            base = 16;
            scan += 2;
        }
        else if (*scan == '0')
        {
            base = 8;
        }
        else
        {
            base = 10;
        }
    }
    else if (base == 16 && scan[0] == '0' &&
        (scan[1] == 'x' || scan[1] == 'X') &&
        digit_value((unsigned char)scan[2]) >= 0 &&
        digit_value((unsigned char)scan[2]) < 16)
    {
        scan += 2;
    }
    first = scan;
    limit = ULONG_MAX;
    while ((digit = digit_value((unsigned char)*scan)) >= 0 && digit < base)
    {
        if (value > (limit - (unsigned long)digit) / (unsigned long)base)
            overflow = 1;
        else
            value = value * (unsigned long)base + (unsigned long)digit;
        ++scan;
    }
    if (first == scan)
    {
        if (endptr)
            *endptr = (char *)nptr;
        return 0;
    }
    if (endptr)
        *endptr = (char *)scan;
    if (overflow)
    {
        errno = ERANGE;
        if (overflow_out)
            *overflow_out = 1;
        return ULONG_MAX;
    }
    return value;
}

unsigned long strtoul(const char *nptr, char **endptr, int base)
{
    int negative;
    int overflow;
    unsigned long value;

    if (base < 0 || base == 1 || base > 36)
    {
        errno = EINVAL;
        if (endptr)
            *endptr = (char *)nptr;
        return 0;
    }
    value = parse_unsigned(nptr, endptr, base, &negative, &overflow);
    if (overflow)
        return ULONG_MAX;
    return negative ? 0UL - value : value;
}

long strtol(const char *nptr, char **endptr, int base)
{
    int negative;
    int overflow;
    unsigned long value;
    unsigned long positive_limit = (unsigned long)LONG_MAX;
    unsigned long negative_limit = positive_limit + 1UL;

    if (base < 0 || base == 1 || base > 36)
    {
        errno = EINVAL;
        if (endptr)
            *endptr = (char *)nptr;
        return 0;
    }
    value = parse_unsigned(nptr, endptr, base, &negative, &overflow);
    if (overflow)
        return negative ? LONG_MIN : LONG_MAX;
    if (negative)
    {
        if (value > negative_limit)
        {
            errno = ERANGE;
            return LONG_MIN;
        }
        return (long)(0UL - value);
    }
    if (value > positive_limit)
    {
        errno = ERANGE;
        return LONG_MAX;
    }
    return (long)value;
}

int atoi(const char *nptr)
{
    return (int)strtol(nptr, (char **)0, 10);
}

long atol(const char *nptr)
{
    return strtol(nptr, (char **)0, 10);
}

int abs(int value)
{
    return value < 0 ? -value : value;
}

long labs(long value)
{
    return value < 0 ? -value : value;
}

div_t div(int numer, int denom)
{
    div_t result;
    result.quot = numer / denom;
    result.rem = numer % denom;
    return result;
}

ldiv_t ldiv(long numer, long denom)
{
    ldiv_t result;
    result.quot = numer / denom;
    result.rem = numer % denom;
    return result;
}

#include <errno.h>
#include <stddef.h>

char *strcat(char *dest, const char *src)
{
    char *result = dest;
    while (*dest)
        ++dest;
    while ((*dest++ = *src++) != '\0')
        ;
    return result;
}

char *strchr(const char *string, int character)
{
    unsigned char byte = (unsigned char)character;
    do
    {
        if ((unsigned char)*string == byte)
            return (char *)string;
    } while (*string++);
    return (char *)0;
}

int strcmp(const char *left, const char *right)
{
    while (*left && *left == *right)
    {
        ++left;
        ++right;
    }
    return (int)(unsigned char)*left - (int)(unsigned char)*right;
}

int strcoll(const char *left, const char *right)
{
    return strcmp(left, right);
}

char *strcpy(char *dest, const char *src)
{
    char *result = dest;
    while ((*dest++ = *src++) != '\0')
        ;
    return result;
}

size_t strcspn(const char *string, const char *reject)
{
    const char *start = string;
    while (*string)
    {
        const char *scan = reject;
        while (*scan)
        {
            if (*string == *scan++)
                return (size_t)(string - start);
        }
        ++string;
    }
    return (size_t)(string - start);
}

char *strerror(int errnum)
{
    switch (errnum)
    {
    case 0:
        return "Success";
    case ENOMEM:
        return "Out of memory";
    case EINVAL:
        return "Invalid argument";
    case ERANGE:
        return "Result out of range";
    default:
        return "Unknown error";
    }
}

size_t strlen(const char *string)
{
    const char *start = string;
    while (*string)
        ++string;
    return (size_t)(string - start);
}

char *strncat(char *dest, const char *src, size_t count)
{
    char *result = dest;
    while (*dest)
        ++dest;
    while (count && *src)
    {
        *dest++ = *src++;
        --count;
    }
    *dest = '\0';
    return result;
}

int strncmp(const char *left, const char *right, size_t count)
{
    while (count && *left && *left == *right)
    {
        ++left;
        ++right;
        --count;
    }
    if (!count)
        return 0;
    return (int)(unsigned char)*left - (int)(unsigned char)*right;
}

char *strncpy(char *dest, const char *src, size_t count)
{
    char *result = dest;
    while (count && *src)
    {
        *dest++ = *src++;
        --count;
    }
    while (count--)
        *dest++ = '\0';
    return result;
}

char *strpbrk(const char *string, const char *accept)
{
    while (*string)
    {
        const char *scan = accept;
        while (*scan)
        {
            if (*string == *scan++)
                return (char *)string;
        }
        ++string;
    }
    return (char *)0;
}

char *strrchr(const char *string, int character)
{
    const char *result = (const char *)0;
    unsigned char byte = (unsigned char)character;
    do
    {
        if ((unsigned char)*string == byte)
            result = string;
    } while (*string++);
    return (char *)result;
}

size_t strspn(const char *string, const char *accept)
{
    const char *start = string;
    while (*string)
    {
        const char *scan = accept;
        while (*scan && *scan != *string)
            ++scan;
        if (!*scan)
            break;
        ++string;
    }
    return (size_t)(string - start);
}

char *strstr(const char *haystack, const char *needle)
{
    if (!*needle)
        return (char *)haystack;
    while (*haystack)
    {
        const char *a = haystack;
        const char *b = needle;
        while (*a && *b && *a == *b)
        {
            ++a;
            ++b;
        }
        if (!*b)
            return (char *)haystack;
        ++haystack;
    }
    return (char *)0;
}

char *strtok(char *string, const char *delim)
{
    static char *next;
    char *token;

    if (string)
        next = string;
    if (!next)
        return (char *)0;
    next += strspn(next, delim);
    if (!*next)
    {
        next = (char *)0;
        return (char *)0;
    }
    token = next;
    next += strcspn(next, delim);
    if (*next)
        *next++ = '\0';
    else
        next = (char *)0;
    return token;
}

size_t strxfrm(char *dest, const char *src, size_t count)
{
    size_t length = strlen(src);
    if (count)
    {
        size_t copy = length < count - 1u ? length : count - 1u;
        size_t index;
        for (index = 0; index < copy; ++index)
            dest[index] = src[index];
        dest[copy] = '\0';
    }
    return length;
}

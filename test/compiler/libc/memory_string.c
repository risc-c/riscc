#include <ctype.h>
#include <errno.h>
#include <string.h>

#include "test.h"

int main(void)
{
    char copy[16];
    char joined[16] = "ab";
    char tokens[] = ",one::two,";
    char transformed[4] = {'?', '?', '?', '?'};
    char repeated[] = "abca";
    char reverse[] = "abcd";
    char fixed[4] = {'?', '?', '?', '?'};
    char unchanged[] = "keep";
    const char bytes[] = {'a', 'b', 'c', 'd'};
    const unsigned char high_left[] = {0x80u};
    const unsigned char high_right[] = {0x7fu};
    char *token;
    int character;

    CHECK(memchr(bytes, 'c', 4) == bytes + 2, 1);
    CHECK(memchr(bytes, 'x', 4) == 0, 2);
    CHECK(memcmp("abc", "abd", 3) < 0, 3);
    CHECK(memcpy(copy, "abcd", 5) == copy && !strcmp(copy, "abcd"), 4);
    CHECK(memmove(copy + 1, copy, 3) == copy + 1 && !strcmp(copy, "aabc"), 5);
    CHECK(!strcmp(memset(copy, 'x', 3), "xxxc"), 6);
    CHECK(memchr(bytes, 'a', 0) == 0 && !memcmp(bytes, bytes, 0), 7);
    CHECK(memcpy(copy, "z", 0) == copy && !memcmp(high_left, high_left, 0),
        8);
    CHECK(memcmp(high_left, high_right, 1) > 0, 9);
    CHECK(memmove(reverse, reverse + 1, 3) == reverse &&
        !memcmp(reverse, "bcdd", 4),
        10);

    CHECK(!strcmp(strcat(joined, "cd"), "abcd"), 11);
    CHECK(strchr(joined, 'c') == joined + 2 && strchr(joined, '\0') == joined + 4,
        12);
    CHECK(strcmp("abc", "abd") < 0 && !strcoll("abc", "abc"), 13);
    CHECK(!strcmp(strcpy(copy, "copy"), "copy"), 14);
    CHECK(strcspn("abc,def", ",;") == 3 && strlen("abc") == 3, 15);
    CHECK(!strcmp(strncat(strcpy(copy, "a"), "bcdef", 2), "abc"), 16);
    CHECK(!strncmp("abc", "abd", 2) && strncmp("abc", "abd", 3) < 0, 17);
    memset(copy, 'x', sizeof(copy));
    strncpy(copy, "ab", 4);
    CHECK(copy[0] == 'a' && copy[1] == 'b' && !copy[2] && !copy[3], 18);
    strncpy(fixed, "abcdef", sizeof(fixed));
    CHECK(!memcmp(fixed, "abcd", sizeof(fixed)), 18);
    CHECK(strncat(unchanged, "x", 0) == unchanged && !strcmp(unchanged, "keep"),
        19);
    CHECK(!strncmp("a", "b", 0) && strcspn("", "x") == 0 &&
        strspn("", "x") == 0,
        20);
    CHECK(strstr(joined, "") == joined && !strpbrk("", "a"), 21);
    CHECK(strpbrk(joined, "zxby") == joined + 1, 22);
    CHECK(strrchr(repeated, 'a') == repeated + 3, 23);
    CHECK(strspn("aaab", "a") == 3 && !strcmp(strstr("abcde", "cd"), "cde"),
        24);
    token = strtok(tokens, ",:");
    CHECK(token && !strcmp(token, "one"), 25);
    token = strtok(0, ",:");
    CHECK(token && !strcmp(token, "two") && !strtok(0, ",:"), 26);
    CHECK(strxfrm(transformed, "hello", sizeof(transformed)) == 5 &&
        !strcmp(transformed, "hel"),
        27);
    CHECK(strxfrm(unchanged, "hello", 0) == 5 && !strcmp(unchanged, "keep"),
        28);
    CHECK(!strcmp(strerror(0), "Success") && !strcmp(strerror(ENOMEM), "Out of memory") &&
        !strcmp(strerror(EINVAL), "Invalid argument") &&
        !strcmp(strerror(ERANGE), "Result out of range") &&
        !strcmp(strerror(-1), "Unknown error"),
        29);

    for (character = -1; character <= 255; ++character)
    {
        int ascii = character >= 0 && character <= 0x7f;
        int digit = character >= '0' && character <= '9';
        int lower = character >= 'a' && character <= 'z';
        int upper = character >= 'A' && character <= 'Z';
        int alpha = lower || upper;
        int graph = character >= 0x21 && character <= 0x7e;

        CHECK(!!isascii(character) == ascii, 30);
        CHECK(!!isblank(character) == (character == ' ' || character == '\t'), 31);
        CHECK(!!iscntrl(character) ==
            (ascii && (character < 0x20 || character == 0x7f)),
            32);
        CHECK(!!isdigit(character) == digit && !!islower(character) == lower &&
            !!isupper(character) == upper && !!isalpha(character) == alpha,
            33);
        CHECK(!!isalnum(character) == (alpha || digit), 34);
        CHECK(!!isgraph(character) == graph &&
            !!isprint(character) == (character >= 0x20 && character <= 0x7e),
            35);
        CHECK(!!ispunct(character) == (graph && !alpha && !digit), 36);
        CHECK(!!isspace(character) ==
            (character == ' ' || (character >= '\t' && character <= '\r')),
            37);
        CHECK(!!isxdigit(character) ==
            (digit || (character >= 'a' && character <= 'f') ||
            (character >= 'A' && character <= 'F')),
            38);
        CHECK(toascii(character) == (character & 0x7f), 39);
        CHECK(tolower(character) == (upper ? character + ('a' - 'A') : character),
            40);
        CHECK(toupper(character) == (lower ? character - ('a' - 'A') : character),
            41);
    }
    pass();
}

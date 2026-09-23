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
    unsigned char source[64];
    unsigned char destination[64];
    unsigned char move_storage[128];
    unsigned char move_expected[128];
    unsigned char left_bytes[64];
    unsigned char right_bytes[64];
    const unsigned char fill_values[] = {0u, 0x80u, 0xffu, 'x'};
    char *token;
    unsigned int destination_offset;
    unsigned int source_offset;
    unsigned int length;
    unsigned int index;
    unsigned int move_length_index;
    unsigned int string_length_index;
    unsigned int fill_index;
    unsigned int nul_lane;
    int character;
    const unsigned int move_lengths[] =
        {0u, 1u, 2u, 3u, 4u, 5u, 7u, 8u, 9u, 15u, 16u, 17u,
         31u, 32u, 33u, 64u};
    const unsigned int string_lengths[] =
        {0u, 1u, 2u, 3u, 4u, 5u, 7u, 8u, 9u, 15u, 16u, 17u, 31u, 32u, 40u};

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

    for (destination_offset = 0; destination_offset < 4; ++destination_offset)
    {
        for (source_offset = 0; source_offset < 4; ++source_offset)
        {
            for (string_length_index = 0;
                 string_length_index < sizeof(string_lengths) /
                     sizeof(string_lengths[0]); ++string_length_index)
            {
                length = string_lengths[string_length_index];
                for (index = 0; index < sizeof(source); ++index)
                {
                    source[index] = 0x7fu;
                    destination[index] = 0xa5u;
                }
                for (index = 0; index < length; ++index)
                    source[source_offset + index] =
                        (unsigned char)(index * 13u + 1u);
                source[source_offset + length] = 0;
                CHECK(strcpy((char *)destination + destination_offset,
                    (const char *)source + source_offset) ==
                    (char *)destination + destination_offset, 78);
                for (index = 0; index < length + 1u; ++index)
                    CHECK(destination[destination_offset + index] ==
                        source[source_offset + index], 79);
                for (index = 0; index < destination_offset; ++index)
                    CHECK(destination[index] == 0xa5u, 80);
                for (index = destination_offset + length + 1u;
                     index < sizeof(destination); ++index)
                    CHECK(destination[index] == 0xa5u, 81);
            }
        }
    }

    /* Exercise overlapping moves at every alignment, including the aligned
     * word path and the byte fallback for differing source/destination
     * alignments.  The outer bytes are canaries for accidental overrun. */
    for (destination_offset = 0; destination_offset < 8; ++destination_offset)
    {
        for (source_offset = 0; source_offset < 8; ++source_offset)
        {
            for (move_length_index = 0;
                 move_length_index < sizeof(move_lengths) / sizeof(move_lengths[0]);
                 ++move_length_index)
            {
                length = move_lengths[move_length_index];
                for (index = 0; index < sizeof(move_storage); ++index)
                {
                    move_storage[index] = (unsigned char)(index * 11u + 3u);
                    move_expected[index] = move_storage[index];
                }
                unsigned char *const move_destination = move_storage + 8u +
                    destination_offset;
                const unsigned char *const move_source = move_storage + 8u +
                    source_offset;
                unsigned char *const expected_destination = move_expected +
                    8u + destination_offset;
                const unsigned char *const expected_source = move_expected +
                    8u + source_offset;

                if (expected_destination < expected_source)
                {
                    for (index = 0; index < length; ++index)
                        expected_destination[index] = expected_source[index];
                }
                else if (expected_destination > expected_source)
                {
                    for (index = length; index != 0; --index)
                        expected_destination[index - 1u] =
                            expected_source[index - 1u];
                }
                CHECK(memmove(move_destination, move_source, length) ==
                    move_destination, 70);
                for (index = 0; index < sizeof(move_storage); ++index)
                    CHECK(move_storage[index] == move_expected[index], 71);
            }
        }
    }

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

    /* Exercise every byte alignment, short lengths, and both canary edges. */
    for (destination_offset = 0; destination_offset < 4; ++destination_offset)
    {
        for (source_offset = 0; source_offset < 4; ++source_offset)
        {
            for (length = 0; length <= 40; ++length)
            {
                for (index = 0; index < 64; ++index)
                {
                    source[index] = (unsigned char)(index * 13u +
                        source_offset);
                    destination[index] = 0xa5u;
                }
                source[source_offset + 1u] = 0x80u;
                source[source_offset + 3u] = 0xffu;
                CHECK(memcpy(destination + destination_offset,
                    source + source_offset, length) ==
                    destination + destination_offset, 50);
                for (index = 0; index < destination_offset; ++index)
                    CHECK(destination[index] == 0xa5u, 51);
                for (index = 0; index < length; ++index)
                    CHECK(destination[destination_offset + index] ==
                        source[source_offset + index], 52);
                for (index = destination_offset + length; index < 56; ++index)
                    CHECK(destination[index] == 0xa5u, 53);
            }
        }
    }

    for (destination_offset = 0; destination_offset < 4; ++destination_offset)
    {
        for (fill_index = 0; fill_index < sizeof(fill_values); ++fill_index)
        {
            for (length = 0; length <= 40; ++length)
            {
                for (index = 0; index < 64; ++index)
                    destination[index] = 0x5au;
                CHECK(memset(destination + destination_offset,
                    fill_values[fill_index], length) ==
                    destination + destination_offset, 54);
                for (index = 0; index < destination_offset; ++index)
                    CHECK(destination[index] == 0x5au, 55);
                for (index = 0; index < length; ++index)
                    CHECK(destination[destination_offset + index] ==
                        fill_values[fill_index], 56);
                for (index = destination_offset + length; index < 56; ++index)
                    CHECK(destination[index] == 0x5au, 57);
            }
        }
    }

    for (destination_offset = 0; destination_offset < 4; ++destination_offset)
    {
        for (source_offset = 0; source_offset < 4; ++source_offset)
        {
            for (length = 0; length <= 40; ++length)
            {
                for (index = 0; index < 64; ++index)
                {
                    left_bytes[index] = 0x33u;
                    right_bytes[index] = 0x33u;
                }
                right_bytes[source_offset + length] = 0x44u;
                CHECK(memcmp(left_bytes + destination_offset,
                    right_bytes + source_offset, length) == 0, 58);
                if (length)
                {
                    left_bytes[destination_offset + length - 1u] = 0x80u;
                    right_bytes[source_offset + length - 1u] = 0xffu;
                    CHECK(memcmp(left_bytes + destination_offset,
                        right_bytes + source_offset, length) < 0, 59);
                    left_bytes[destination_offset + length - 1u] = 0xffu;
                    right_bytes[source_offset + length - 1u] = 0x80u;
                    CHECK(memcmp(left_bytes + destination_offset,
                        right_bytes + source_offset, length) > 0, 60);
                }
            }
        }
    }

    for (source_offset = 0; source_offset < 4; ++source_offset)
    {
        for (length = 0; length <= 40; ++length)
        {
            for (index = 0; index < 64; ++index)
                source[index] = 0x7fu;
            for (index = 0; index < length; ++index)
                source[source_offset + index] = (unsigned char)('a' +
                    (index & 7u));
            source[source_offset + length] = 0;
            source[source_offset + length + 1u] = 0xffu;
            CHECK(strlen((const char *)source + source_offset) == length, 61);
        }
    }

    for (destination_offset = 0; destination_offset < 4; ++destination_offset)
    {
        for (source_offset = 0; source_offset < 4; ++source_offset)
        {
            for (length = 0; length <= 40; ++length)
            {
                for (index = 0; index < 64; ++index)
                {
                    left_bytes[index] = 'A';
                    right_bytes[index] = 'A';
                }
                left_bytes[destination_offset + length] = 0;
                right_bytes[source_offset + length] = 0;
                left_bytes[destination_offset + length + 1u] = 0x80u;
                right_bytes[source_offset + length + 1u] = 0xffu;
                CHECK(strcmp((const char *)left_bytes + destination_offset,
                    (const char *)right_bytes + source_offset) == 0, 62);
                CHECK(strncmp((const char *)left_bytes + destination_offset,
                    (const char *)right_bytes + source_offset, length) == 0,
                    63);
                CHECK(strncmp((const char *)left_bytes + destination_offset,
                    (const char *)right_bytes + source_offset, length + 1u) == 0,
                    64);
            }
            for (index = 0; index < 64; ++index)
            {
                left_bytes[index] = 0;
                right_bytes[index] = 0;
            }
            left_bytes[destination_offset] = 0x80u;
            right_bytes[source_offset] = 0x7fu;
            CHECK(strcmp((const char *)left_bytes + destination_offset,
                (const char *)right_bytes + source_offset) > 0, 65);
            CHECK(strncmp((const char *)left_bytes + destination_offset,
                (const char *)right_bytes + source_offset, 2) > 0, 66);
            left_bytes[destination_offset] = 0xffu;
            right_bytes[source_offset] = 0x80u;
            CHECK(strcmp((const char *)left_bytes + destination_offset,
                (const char *)right_bytes + source_offset) > 0, 67);
            CHECK(strncmp((const char *)left_bytes + destination_offset,
                (const char *)right_bytes + source_offset, 2) > 0, 68);
        }
    }

    for (destination_offset = 0; destination_offset < 4; ++destination_offset)
    {
        for (source_offset = 0; source_offset < 4; ++source_offset)
        {
            for (nul_lane = 0; nul_lane < sizeof(unsigned int); ++nul_lane)
            {
                for (index = 0; index < 64; ++index)
                {
                    left_bytes[index] = 'Q';
                    right_bytes[index] = 'Q';
                }
                left_bytes[destination_offset + nul_lane] = 0;
                right_bytes[source_offset + nul_lane] = 0;
                left_bytes[destination_offset + nul_lane + 1u] = 0x80u;
                right_bytes[source_offset + nul_lane + 1u] = 0xffu;
                CHECK(strcmp((const char *)left_bytes + destination_offset,
                    (const char *)right_bytes + source_offset) == 0, 69);
            }
        }
    }

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

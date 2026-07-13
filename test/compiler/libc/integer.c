#include <errno.h>
#include <limits.h>
#include <stdlib.h>

#include "test.h"

struct record
{
    char key;
    char value;
};

static int compare_int(const void *left, const void *right)
{
    int a = *(const int *)left;
    int b = *(const int *)right;
    return (a > b) - (a < b);
}

static int compare_record(const void *left, const void *right)
{
    const struct record *a = (const struct record *)left;
    const struct record *b = (const struct record *)right;
    return (int)a->key - (int)b->key;
}

int main(void)
{
    char *end;
    const char invalid_base[] = "1";
    const char no_digits[] = " + ";
    int values[] = {1, 3, 5, 7};
    int key = 3;
    int missing = 4;
    int empty = 0;
    int index;
    int first_rand;
    struct record records[] = {{'c', '3'}, {'a', '1'}, {'b', '2'}, {'b', '4'}};

    errno = 0;
    CHECK(strtol(" -0x80000000z", &end, 0) == -2147483647L - 1L &&
                        *end == 'z',
        1);
    CHECK(strtoul("777", &end, 8) == 511UL && !*end, 2);
    CHECK(strtol("999999999999", &end, 10) == 2147483647L && errno == ERANGE,
        3);
    errno = 0;
    CHECK(strtol(invalid_base, &end, 1) == 0 && end == invalid_base &&
        errno == EINVAL,
        4);
    CHECK(atoi("-12") == -12 && atol("123456") == 123456L, 5);
    CHECK(strtol(" +1011x", &end, 2) == 11 && *end == 'x', 6);
    CHECK(strtol("077", &end, 0) == 63 && !*end, 7);
    CHECK(strtol("0X10", &end, 16) == 16 && !*end, 8);
    CHECK(strtoul("z", &end, 36) == 35UL && !*end, 9);
    CHECK(strtol(no_digits, &end, 10) == 0 && end == no_digits, 10);
    CHECK(strtoul("-42", &end, 10) == ULONG_MAX - 41UL && !*end, 11);
    errno = 0;
    CHECK(strtoul("4294967296", &end, 10) == ULONG_MAX && errno == ERANGE &&
        !*end,
        12);
    errno = 0;
    CHECK(strtol("-2147483649", &end, 10) == -2147483647L - 1L &&
        errno == ERANGE && !*end,
        13);

    CHECK(abs(-7) == 7 && labs(-123456L) == 123456L, 14);
    CHECK(div(-7, 3).quot == -2 && div(-7, 3).rem == -1 &&
        div(7, -3).quot == -2 && div(7, -3).rem == 1,
        15);
    CHECK(ldiv(-123456L, 100L).quot == -1234L &&
        ldiv(-123456L, 100L).rem == -56L,
        16);

    qsort(records, sizeof(records) / sizeof(records[0]), sizeof(records[0]),
        compare_record);
    CHECK(records[0].key == 'a' && records[1].key == 'b' &&
        records[2].key == 'b' && records[3].key == 'c',
        17);
    qsort(values, 0, sizeof(values[0]), compare_int);
    qsort(values, sizeof(values) / sizeof(values[0]), sizeof(values[0]),
        compare_int);
    CHECK(values[0] == 1 && values[3] == 7, 18);
    CHECK(bsearch(&key, values, 4, sizeof(values[0]), compare_int) == values + 1 &&
        !bsearch(&missing, values, 4, sizeof(values[0]), compare_int) &&
        !bsearch(&empty, values, 0, sizeof(values[0]), compare_int),
        19);

    srand(7);
    first_rand = rand();
    srand(7);
    CHECK(first_rand == rand() && first_rand >= 0 && first_rand <= RAND_MAX, 20);
    for (index = 0; index < 16; ++index)
        CHECK(rand() >= 0 && rand() <= RAND_MAX, 21);
    pass();
}

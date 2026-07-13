#include <assert.h>
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "test.h"

static int compare_int(const void *left, const void *right)
{
    int a = *(const int *)left;
    int b = *(const int *)right;
    return (a > b) - (a < b);
}

int main(void)
{
    int values[] = {4, 1, 3, 2};
    int key = 3;
    int first_rand;
    int *found;
    char *copy;
    char formatted[20];

    assert(1);
    CHECK(abs(-7) == 7 && labs(-123456L) == 123456L, 1);
    CHECK(div(-7, 3).quot == -2 && div(-7, 3).rem == -1, 2);
    CHECK(ldiv(123456L, 100L).quot == 1234L, 3);
    qsort(values, 4, sizeof(values[0]), compare_int);
    CHECK(values[0] == 1 && values[3] == 4, 4);
    found = bsearch(&key, values, 4, sizeof(values[0]), compare_int);
    CHECK(found && *found == 3, 5);
    srand(7);
    first_rand = rand();
    srand(7);
    CHECK(first_rand == rand() && first_rand >= 0 && first_rand <= RAND_MAX, 6);

    copy = malloc(8);
    CHECK(copy && !strcmp(strcpy(copy, "all"), "all") && isalpha(copy[0]), 7);
    free(copy);
    CHECK(snprintf(formatted, sizeof(formatted), "%ld:%04x", -123456L, 0x2a) ==
        12 && !strcmp(formatted, "-123456:002a"),
        8);
    CHECK(fprintf(stderr, "%s\n", formatted) == 13, 9);
    pass();
}

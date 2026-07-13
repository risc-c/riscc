#include <errno.h>
#include <stdlib.h>

#include "test.h"

int main(void)
{
    unsigned char *first;
    unsigned char *second;
    unsigned char *third;
    unsigned char *merged;
    unsigned char *split;
    unsigned char *grown;
    unsigned int count = 0;
    void *blocks[40];

    errno = 0;
    CHECK(malloc(0) == 0 && errno == 0, 1);
    free(0);
    first = realloc(0, 4);
    CHECK(first != 0, 2);
    first[0] = 0x5a;
    CHECK(realloc(first, 0) == 0, 3);
    CHECK(calloc(0, 4) == 0 && calloc(4, 0) == 0, 4);

    first = malloc(4);
    second = malloc(4);
    third = malloc(4);
    CHECK(first && second && third, 5);
    free(second);
    free(first);
    merged = malloc(6);
    CHECK(merged == first, 6);
    split = malloc(2);
    CHECK(split == merged + 8, 7);
    free(split);
    free(merged);
    free(third);
    first = malloc(4);
    second = malloc(4);
    third = malloc(4);
    CHECK(first && second && third, 8);
    free(first);
    free(third);
    CHECK(malloc(4) == first, 9);

    first[0] = 0x11;
    first[1] = 0x22;
    first[2] = 0x33;
    first[3] = 0x44;
    grown = realloc(first, 8);
    CHECK(grown && grown != first, 10);
    CHECK(grown[0] == 0x11 && grown[1] == 0x22 && grown[2] == 0x33 &&
        grown[3] == 0x44,
        11);
    errno = 0;
    CHECK(realloc(grown, 32767u) == 0 && errno == ENOMEM, 12);
    CHECK(grown[0] == 0x11 && grown[3] == 0x44, 13);
    free(grown);
    errno = 0;
    CHECK(malloc(32768u) == 0 && errno == ENOMEM, 14);
    CHECK(calloc(40000u, 2u) == 0 && errno == ENOMEM, 15);
    first = calloc(4, 1);
    CHECK(first && !first[0] && !first[1] && !first[2] && !first[3], 16);

    while (count < sizeof(blocks) / sizeof(blocks[0]) &&
        (blocks[count] = malloc(1024)) != 0)
        ++count;
    CHECK(count > 10 && count < sizeof(blocks) / sizeof(blocks[0]), 17);
    pass();
}

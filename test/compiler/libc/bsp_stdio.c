#include <stdio.h>
#include <string.h>

#include "test.h"

static char output[8];
static unsigned int output_length;

int putchar(int character)
{
    if (output_length < sizeof(output))
        output[output_length++] = (char)character;
    return (unsigned char)character;
}

int getchar(void)
{
    return 'R';
}

int puts(const char *string)
{
    while (*string)
        putchar((unsigned char)*string++);
    putchar('\n');
    return 0;
}

int main(void)
{
    CHECK(getchar() == 'R' && fgetc(stdin) == 'R', 1);
    CHECK(putchar('x') == 'x', 2);
    CHECK(fputc('y', stderr) == 'y', 3);
    CHECK(fputs("z", stdout) == 0, 4);
    CHECK(puts("") == 0, 5);
    CHECK(output_length == 4 && !memcmp(output, "xyz\n", 4), 6);
    pass();
}

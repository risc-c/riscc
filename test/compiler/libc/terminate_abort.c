#include <stdlib.h>

#include "test.h"

static void (*volatile halt)(void) = abort;

int main(void)
{
    halt();
    RESULT_WORD = 0xb001u;
    for (;;)
        ;
}

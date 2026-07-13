#include <stdlib.h>

#include "test.h"

static void (*volatile halt)(int) = exit;

int main(void)
{
    halt(EXIT_FAILURE);
    RESULT_WORD = 0xb002u;
    for (;;)
        ;
}

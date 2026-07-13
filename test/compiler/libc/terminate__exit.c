#include <stdlib.h>

#include "test.h"

static void (*volatile halt)(int) = _Exit;

int main(void)
{
    halt(EXIT_FAILURE);
    RESULT_WORD = 0xb003u;
    for (;;)
        ;
}

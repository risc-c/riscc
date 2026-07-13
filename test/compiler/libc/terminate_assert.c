#include <assert.h>

#include "test.h"

int main(void)
{
    assert(0);
    RESULT_WORD = 0xb004u;
    for (;;)
        ;
}

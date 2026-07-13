#include <time.h>

#include "test.h"

int main(void)
{
    CHECK(CLOCKS_PER_SEC == 1000UL, 1);
    CHECK(clock() == 0, 2);
    pass();
}

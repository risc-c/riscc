#include <riscc/platform.h>
#include <time.h>

#include "test.h"

int main(void)
{
    time_t stored = 1;

    CHECK(CLOCKS_PER_SEC == RISCC_TICK_HZ, 1);
    CHECK(clock() == 0, 2);
    CHECK(time(&stored) == 0 && stored == 0, 3);
    CHECK((RISCC_MMIO16(RISCC_IRQ_ENABLE) & RISCC_IRQ_TIMER) != 0, 4);
    riscc_time_init();
    CHECK(time(0) == 0, 6);
    pass();
}

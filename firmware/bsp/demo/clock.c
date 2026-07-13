/* Default demo-BSP fast clock: direct read of the 1 kHz tick counter. */

#include <riscc/platform.h>
#include <time.h>

clock_t clock(void)
{
    return (clock_t)riscc_ticks();
}

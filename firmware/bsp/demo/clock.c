/* Default demo-BSP fast clock: direct read of the hardware tick/frame counter. */

#include <riscc/platform.h>
#include <time.h>

clock_t clock(void)
{
    return (clock_t)riscc_ticks();
}

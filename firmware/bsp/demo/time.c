/* Default demo-BSP uptime service: one timer IRQ per second. */

#include <riscc/interrupt.h>
#include <riscc/platform.h>
#include <time.h>

static volatile uint16_t seconds_low;
static volatile uint16_t seconds_high;
static volatile uint16_t time_started;

static void riscc_time_tick(void)
{
    uint16_t next = seconds_low + 1u;

    seconds_low = next;
    if (next == 0)
        ++seconds_high;
    riscc_timer_set_ticks(RISCC_TICK_HZ);
}

void riscc_time_init(void)
{
    if (time_started)
        return;

    seconds_low = 0;
    seconds_high = 0;
    riscc_irq_set_handler(riscc_time_tick);
    riscc_timer_set_ticks(RISCC_TICK_HZ);
    RISCC_MMIO16(RISCC_IRQ_ENABLE) = RISCC_IRQ_TIMER;
    time_started = 1;
    riscc_irq_enable();
}

static time_t riscc_time_seconds(void)
{
    uint16_t high0;
    uint16_t low;
    uint16_t high1;

    do
    {
        high0 = seconds_high;
        low = seconds_low;
        high1 = seconds_high;
    } while (high0 != high1);
    return ((time_t)high1 << 16) | low;
}

time_t time(time_t *result)
{
    time_t value;

    riscc_time_init();
    value = riscc_time_seconds();
    if (result)
        *result = value;
    return value;
}

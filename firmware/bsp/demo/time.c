/* Demo uptime: one interrupt per display frame on boards, per second otherwise. */

#include <riscc/interrupt.h>
#include <riscc/platform.h>
#include <time.h>

static volatile uint16_t seconds_low;
static volatile uint16_t seconds_high;
static volatile uint16_t time_started;
#ifdef RISCC_BOARD_DEMO
static uint16_t last_frame;
static uint16_t second_frames;
#define TIME_IRQ_TICKS 1u
#else
#define TIME_IRQ_TICKS RISCC_TICK_HZ
#endif

static void riscc_time_tick(void)
{
#ifdef RISCC_BOARD_DEMO
    const uint16_t now = riscc_ticks();
    const uint32_t elapsed = (uint16_t)(now - last_frame) + (uint32_t)second_frames;
    last_frame = now;
    second_frames = elapsed % RISCC_TICK_HZ;
    uint16_t next = seconds_low + elapsed / RISCC_TICK_HZ;
#else
    uint16_t next = seconds_low + 1u;
#endif
    const uint16_t previous = seconds_low;

    seconds_low = next;
    if (next < previous)
        ++seconds_high;
    riscc_timer_set_ticks(TIME_IRQ_TICKS);
}

void riscc_time_init(void)
{
    if (time_started)
        return;

    seconds_low = 0;
    seconds_high = 0;
#ifdef RISCC_BOARD_DEMO
    last_frame = riscc_ticks();
    second_frames = 0;
#endif
    riscc_irq_set_handler(riscc_time_tick);
    riscc_timer_set_ticks(TIME_IRQ_TICKS);
    RISCC_MMIO_WORD(RISCC_IRQ_ENABLE) = RISCC_IRQ_TIMER;
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

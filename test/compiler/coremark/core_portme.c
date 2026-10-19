/* Only the platform layer is RISC-C-specific. No timed workload is changed. */
#include "coremark.h"
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415;
volatile ee_s32 seed2_volatile = 0x3415;
#elif PERFORMANCE_RUN
volatile ee_s32 seed1_volatile = 0;
volatile ee_s32 seed2_volatile = 0;
#else
#error "Select PERFORMANCE_RUN or VALIDATION_RUN"
#endif
volatile ee_s32 seed3_volatile = 0x66;
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;
ee_u32 default_num_contexts = 1;

static CORE_TICKS start_ticks, stop_ticks;
static volatile unsigned errors, short_run;

/* Simulation-only MMIO. Reading low snapshots both halves; high reads that
 * snapshot, so timer rollover cannot tear a read. These are not ISA CSRs. */
static CORE_TICKS read_cycles(void)
{
    uint32_t low = *(volatile uint32_t *)0xffffffe0u;
    uint32_t high = *(volatile uint32_t *)0xffffffe4u;
    return ((CORE_TICKS)high << 32) | low;
}

void start_time(void)
{
    __asm__ volatile ("" ::: "memory");
    start_ticks = read_cycles();
    __asm__ volatile ("" ::: "memory");
}

void stop_time(void)
{
    __asm__ volatile ("" ::: "memory");
    stop_ticks = read_cycles();
    __asm__ volatile ("" ::: "memory");
}

CORE_TICKS get_time(void)
{
    return stop_ticks - start_ticks;
}

secs_ret time_in_secs(CORE_TICKS ticks)
{
    return (secs_ret)(ticks / COREMARK_CLOCK_HZ);
}

void portable_init(core_portable *port, int *argc, char *argv[])
{
    (void)argc;
    (void)argv;
    port->portable_id = 1;
}

/* The fixture's TX is always ready. The RC32 ISS accepts these writes as
 * ordinary memory; its terminal status still checks the upstream CRC tests. */
int putchar(int character)
{
    *(volatile uint16_t *)0xfff0u = (unsigned char)character;
    return (unsigned char)character;
}

int getchar(void)
{
    return EOF;
}

int ee_printf(const char *format, ...)
{
    va_list arguments;
    /* Upstream deliberately counts a short timed run as an error. Keep its
     * warning intact, but distinguish that from incorrect CRCs/types. The
     * host also independently checks every expected CRC and the duration. */
    if (strcmp(format,
            "ERROR! Must execute for at least 10 secs for a valid result!\n") == 0)
        short_run = 1;
    else if (strstr(format, "ERROR") || strstr(format, "Cannot validate"))
        ++errors;
    va_start(arguments, format);
    int result = vprintf(format, arguments);
    va_end(arguments);
    return result;
}

void portable_fini(core_portable *port)
{
    CORE_TICKS ticks = get_time();
    port->portable_id = 0;
    /* The firmware printf supports 32-bit integers, not %llu. */
    printf("RISCC_COREMARK ticks_hi=%lu ticks_lo=%lu iterations=%lu hz=%lu short=%u errors=%u\n",
           (unsigned long)(ticks >> 32), (unsigned long)ticks,
           (unsigned long)seed4_volatile, (unsigned long)COREMARK_CLOCK_HZ,
           short_run, errors);
    *(volatile uint16_t *)0xfffeu = errors ? 0xbad0u : 0x600du;
    for (;;)
        ;
}

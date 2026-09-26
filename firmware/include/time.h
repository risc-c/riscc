#ifndef RISCC_TIME_H
#define RISCC_TIME_H

#include <stdint.h>

/* The BSP clock counts display frames on boards, milliseconds otherwise. */
typedef uint32_t clock_t;
typedef uint32_t time_t;

#ifdef RISCC_BOARD_DEMO
#define CLOCKS_PER_SEC 60UL
#else
#define CLOCKS_PER_SEC 1000UL
#endif

#ifdef __cplusplus
extern "C"
{
#endif

clock_t clock(void);
time_t time(time_t *result);

#ifdef __cplusplus
}
#endif

#endif

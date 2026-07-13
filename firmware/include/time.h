#ifndef RISCC_TIME_H
#define RISCC_TIME_H

#include <stdint.h>

/* The default BSP clock is its 1 kHz free-running tick counter. */
typedef uint32_t clock_t;
typedef uint32_t time_t;

#define CLOCKS_PER_SEC 1000UL

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

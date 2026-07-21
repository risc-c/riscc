#ifndef RISCC_PLATFORM_H
#define RISCC_PLATFORM_H

#include <stdint.h>

/* Shared minimal peripheral map for the current demo-board SoCs. */
#define RISCC_MMIO16(address) \
    (*(volatile uint16_t *)(uintptr_t)(address))

/* The framebuffer follows the board's firmware RAM window. */
#ifdef RISCC_ICEPI_ZERO
#define RISCC_FRAMEBUFFER_BASE 0x8000u
#else
#define RISCC_FRAMEBUFFER_BASE 0x6000u
#endif
#if defined(RISCC_ATUM_A3) || defined(RISCC_ICEPI_ZERO)
#define RISCC_FRAMEBUFFER_WIDTH 320u
#define RISCC_FRAMEBUFFER_HEIGHT 180u
#else
#define RISCC_FRAMEBUFFER_WIDTH 320u
#define RISCC_FRAMEBUFFER_HEIGHT 240u
#endif

#define RISCC_IRQ_STATE 0xfff6u /* read pending, write enable mask */
#define RISCC_IRQ_PENDING RISCC_IRQ_STATE
#define RISCC_IRQ_ENABLE RISCC_IRQ_STATE
#define RISCC_IRQ_UART 0x0001u
#define RISCC_IRQ_TIMER 0x0002u

/* The current demo boards use a 1 kHz timer/tick timebase. */
#define RISCC_TICK_HZ 1000u

/* Write a non-zero delay to arm or rearm; read the free-running ticks. */
#define RISCC_TIMER 0xfff4u
#define RISCC_TIMER_COUNT RISCC_TIMER
#define RISCC_TICKS RISCC_TIMER

static inline void riscc_timer_set_ticks(uint16_t delay_ticks)
{
    RISCC_MMIO16(RISCC_TIMER_COUNT) = delay_ticks;
}

static inline uint16_t riscc_ticks(void)
{
    return RISCC_MMIO16(RISCC_TICKS);
}

/* Start the on-demand seconds service used by time().  Safe to call twice. */
#ifdef __cplusplus
extern "C"
{
#endif
void riscc_time_init(void);
#ifdef __cplusplus
}
#endif

#define RISCC_LED 0xfff8u

#define RISCC_UART_DATA 0xfff0u  /* write TX, read RX */
#define RISCC_UART_STATE 0xfff2u /* read status, write IRQ enables */
#define RISCC_UART_TX RISCC_UART_DATA
#define RISCC_UART_RX RISCC_UART_DATA
#define RISCC_UART_STATUS RISCC_UART_STATE
#define RISCC_UART_CTRL RISCC_UART_STATE
#define RISCC_UART_TX_READY 0x0001u
#define RISCC_UART_RX_READY 0x0002u
#define RISCC_UART_RX_OVERFLOW 0x0004u
#define RISCC_UART_IRQ_RX 0x0001u
#define RISCC_UART_IRQ_TX 0x0002u

#endif

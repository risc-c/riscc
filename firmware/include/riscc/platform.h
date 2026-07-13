#ifndef RISCC_PLATFORM_H
#define RISCC_PLATFORM_H

#include <stdint.h>

/* Shared minimal peripheral map for the current demo-board SoCs. */
#define RISCC_MMIO16(address) \
    (*(volatile uint16_t *)(uintptr_t)(address))

#define RISCC_FRAMEBUFFER_BASE 0x8000u
#define RISCC_FRAMEBUFFER_WIDTH 160u
#define RISCC_FRAMEBUFFER_HEIGHT 120u

#define RISCC_IRQ_PENDING 0xffe0u
#define RISCC_IRQ_ENABLE 0xffe2u
#define RISCC_IRQ_UART 0x0001u
#define RISCC_IRQ_TIMER 0x0002u

/* The current demo boards use a 1 kHz timer/tick timebase. */
#define RISCC_TICK_HZ 1000u

/* Read remaining ticks; write a non-zero delay to arm or rearm. */
#define RISCC_TIMER_COUNT 0xffe4u

/* 16-bit free-running tick counter, reset with the SoC. */
#define RISCC_TICKS 0xffe6u

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

#define RISCC_LED 0xffe8u

#define RISCC_UART_TX 0xfff0u
#define RISCC_UART_RX 0xfff2u
#define RISCC_UART_STATUS 0xfff4u
#define RISCC_UART_CTRL 0xfff6u
#define RISCC_UART_TX_READY 0x0001u
#define RISCC_UART_RX_READY 0x0002u
#define RISCC_UART_RX_OVERFLOW 0x0004u
#define RISCC_UART_IRQ_RX 0x0001u
#define RISCC_UART_IRQ_TX 0x0002u

#endif

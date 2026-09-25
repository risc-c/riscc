#ifndef RISCC_PLATFORM_H
#define RISCC_PLATFORM_H

#include <stdint.h>

/* Shared minimal peripheral map for the current demo-board SoCs. */
#define RISCC_MMIO16(address) \
    (*(volatile uint16_t *)(uintptr_t)(address))
#define RISCC_MMIO32(address) \
    (*(volatile uint32_t *)(uintptr_t)(address))
#ifdef RISCC_BOARD_DEMO
#define RISCC_MMIO_WORD(address) RISCC_MMIO32(address)
#else
#define RISCC_MMIO_WORD(address) RISCC_MMIO16(address)
#endif

/* Board RC32 demos keep devices in the top 64 KiB. */
#ifdef RISCC_BOARD_DEMO
#define RISCC_DEVICE_BASE 0xffff0000u
#else
#define RISCC_DEVICE_BASE 0u
#endif

/* Demo-board framebuffer. */
#ifdef RISCC_BOARD_DEMO
#define RISCC_SDRAM_BASE 0x10000000u
#define RISCC_FRAMEBUFFER_BASE RISCC_SDRAM_BASE
#define RISCC_PALETTE_BASE 0xfffff800u
#else
#define RISCC_FRAMEBUFFER_BASE 0x8000u
#endif
#if (defined(RISCC_ATUM_A3) || defined(RISCC_DE23_LITE)) || defined(RISCC_ICEPI_ZERO)
#define RISCC_FRAMEBUFFER_WIDTH 320u
#define RISCC_FRAMEBUFFER_HEIGHT 180u
#else
#define RISCC_FRAMEBUFFER_WIDTH 320u
#define RISCC_FRAMEBUFFER_HEIGHT 240u
#endif

#ifdef RISCC_BOARD_DEMO
#define RISCC_IRQ_STATE (RISCC_DEVICE_BASE | 0xffecu) /* read pending, write enable mask */
#else
#define RISCC_IRQ_STATE (RISCC_DEVICE_BASE | 0xfff6u) /* read pending, write enable mask */
#endif
#define RISCC_IRQ_PENDING RISCC_IRQ_STATE
#define RISCC_IRQ_ENABLE RISCC_IRQ_STATE
#define RISCC_IRQ_UART 0x0001u
#define RISCC_IRQ_TIMER 0x0002u

/* The current demo boards use a 1 kHz timer/tick timebase. */
#define RISCC_TICK_HZ 1000u

/* Write a non-zero delay to arm or rearm; read the free-running ticks. */
#ifdef RISCC_BOARD_DEMO
#define RISCC_TIMER (RISCC_DEVICE_BASE | 0xffe8u)
#else
#define RISCC_TIMER (RISCC_DEVICE_BASE | 0xfff4u)
#endif
#define RISCC_TIMER_COUNT RISCC_TIMER
#define RISCC_TICKS RISCC_TIMER

static inline void riscc_timer_set_ticks(uint16_t delay_ticks)
{
    RISCC_MMIO_WORD(RISCC_TIMER_COUNT) = delay_ticks;
}

static inline uint16_t riscc_ticks(void)
{
    return (uint16_t)RISCC_MMIO_WORD(RISCC_TICKS);
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

#ifdef RISCC_BOARD_DEMO
#define RISCC_LED (RISCC_DEVICE_BASE | 0xfff0u)
#else
#define RISCC_LED (RISCC_DEVICE_BASE | 0xfff8u)
#endif

#ifdef RISCC_BOARD_DEMO
#define RISCC_UART_DATA (RISCC_DEVICE_BASE | 0xffe0u)  /* write TX, read RX */
#define RISCC_UART_STATE (RISCC_DEVICE_BASE | 0xffe4u) /* read status, write IRQ enables */
#else
#define RISCC_UART_DATA (RISCC_DEVICE_BASE | 0xfff0u)  /* write TX, read RX */
#define RISCC_UART_STATE (RISCC_DEVICE_BASE | 0xfff2u) /* read status, write IRQ enables */
#endif
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

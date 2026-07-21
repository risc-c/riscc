/* Default BSP console: the shared demo-board MMIO UART. */

#include <riscc/platform.h>
#include <stdio.h>

#define UART_DATA RISCC_MMIO16(RISCC_UART_DATA)
#define UART_STATUS RISCC_MMIO16(RISCC_UART_STATUS)

int putchar(int character)
{
    while ((UART_STATUS & RISCC_UART_TX_READY) == 0)
        ;
    UART_DATA = (unsigned char)character;
    return (unsigned char)character;
}

int getchar(void)
{
    while ((UART_STATUS & RISCC_UART_RX_READY) == 0)
        ;
    return UART_DATA & 0x00ffu;
}

int puts(const char *string)
{
    while (*string)
    {
        while ((UART_STATUS & RISCC_UART_TX_READY) == 0)
            ;
        UART_DATA = (unsigned char)*string++;
    }
    while ((UART_STATUS & RISCC_UART_TX_READY) == 0)
        ;
    UART_DATA = '\n';
    return 0;
}

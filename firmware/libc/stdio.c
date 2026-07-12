/* Minimal UART-backed stdio for the RISC-C freestanding runtime. */

#include <stdio.h>

#define RISCC_UART_TX (*(volatile unsigned short *)0xfff0u)
#define RISCC_UART_RX (*(volatile unsigned short *)0xfff2u)
#define RISCC_UART_STATUS (*(volatile unsigned short *)0xfff4u)

#define RISCC_UART_TX_READY 0x0001u
#define RISCC_UART_RX_READY 0x0002u

int putchar(int character)
{
  while ((RISCC_UART_STATUS & RISCC_UART_TX_READY) == 0)
    ;
  RISCC_UART_TX = (unsigned char)character;
  return (unsigned char)character;
}

int getchar(void)
{
  while ((RISCC_UART_STATUS & RISCC_UART_RX_READY) == 0)
    ;
  return RISCC_UART_RX & 0x00ffu;
}

int puts(const char *string)
{
  while (*string != '\0')
    putchar((unsigned char)*string++);
  putchar('\n');
  return 0;
}

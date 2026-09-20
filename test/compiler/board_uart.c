#include <stdint.h>
#include <stdio.h>
#include <riscc/platform.h>

_Static_assert(sizeof(void *) == 4, "board demos require RC32 pointers");
_Static_assert(RISCC_UART_DATA == 0xffffffe0u, "board UART data address");
_Static_assert(RISCC_UART_STATE == 0xffffffe4u, "board UART state address");
_Static_assert(RISCC_TIMER == 0xffffffe8u, "board timer address");
_Static_assert(RISCC_IRQ_STATE == 0xffffffecu, "board IRQ address");
_Static_assert(RISCC_LED == 0xfffffff0u, "board LED address");

static volatile uint32_t initialized = 0x12345678u;
static volatile uint32_t cleared;
static _Thread_local volatile uint32_t tls_initialized = 0x89abcdefu;
static _Thread_local volatile uint32_t tls_cleared;

int main(void)
{
    if (initialized != 0x12345678u || cleared != 0 ||
        tls_initialized != 0x89abcdefu || tls_cleared != 0)
        puts("LLVM RISCC FAIL");
    else
        puts("LLVM RISCC PASS");
    for (;;)
        ;
}

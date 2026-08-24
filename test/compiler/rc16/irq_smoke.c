#include <riscc/interrupt.h>

volatile unsigned short irq_count;

void irq_smoke_clobber_s(void);

/* This non-leaf path deliberately needs the IRQ-private r7 stack. */
static __attribute__((noinline)) void irq_acknowledge(void)
{
    volatile unsigned short *const irq_ack =
        (volatile unsigned short *)0xfffau;

    (void)*irq_ack;
}

void irq_smoke_handler(void)
{
    ++irq_count;
    irq_smoke_clobber_s();
    irq_acknowledge();
}

void irq_smoke_install(void)
{
    riscc_irq_set_handler(irq_smoke_handler);
}

#include <riscc/interrupt.h>

volatile unsigned short irq_count;

void irq_smoke_clobber_s(void);

/* This non-leaf path deliberately needs the IRQ-private r7 stack. */
static __attribute__((noinline)) void irq_acknowledge(unsigned short value)
{
    volatile unsigned short local = value;
    volatile unsigned short *const irq_ack =
        (volatile unsigned short *)0xfff8u;

    *irq_ack = local;
}

void irq_smoke_handler(void)
{
    ++irq_count;
    irq_smoke_clobber_s();
    irq_acknowledge(1);
}

void irq_smoke_install(void)
{
    riscc_irq_set_handler(irq_smoke_handler);
}

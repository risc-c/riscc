#include <riscc/interrupt.h>
#include <riscc/platform.h>

#include "test.h"

static volatile unsigned int timer_irqs;

static void timer_irq(void)
{
    ++timer_irqs;
    riscc_timer_set_ticks(0);
}

int main(void)
{
    uint16_t before;

    RISCC_MMIO16(RISCC_IRQ_ENABLE) = 0;
    before = riscc_ticks();
    while (riscc_ticks() == before)
        ;
    CHECK(riscc_ticks() != before, 1);

    before = riscc_ticks();
    riscc_timer_set_ticks(1);
    while (riscc_ticks() == before)
        ;
    CHECK((RISCC_MMIO16(RISCC_IRQ_PENDING) & RISCC_IRQ_TIMER) != 0, 2);
    riscc_timer_set_ticks(0);
    CHECK((RISCC_MMIO16(RISCC_IRQ_PENDING) & RISCC_IRQ_TIMER) == 0, 3);

    riscc_irq_set_handler(timer_irq);
    RISCC_MMIO16(RISCC_IRQ_ENABLE) = RISCC_IRQ_TIMER;
    riscc_timer_set_ticks(1);
    riscc_irq_enable();
    while (timer_irqs == 0)
        ;
    CHECK(timer_irqs == 1, 4);
    CHECK((RISCC_MMIO16(RISCC_IRQ_PENDING) & RISCC_IRQ_TIMER) == 0, 5);
    pass();
}

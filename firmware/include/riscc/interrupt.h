#ifndef RISCC_INTERRUPT_H
#define RISCC_INTERRUPT_H

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Installing a handler extracts the optional C IRQ wrapper and makes it the
 * vector implementation.  The wrapper calls the selected function with IRQs
 * masked, on its one global IRQ stack.  A null handler uses the runtime's
 * default halt loop.  A handler must acknowledge every level-sensitive source
 * before returning and must not enable nested interrupts.
 */
typedef void (*riscc_irq_handler_t)(void);

/* Install the global C IRQ handler before enabling interrupts. */
void riscc_irq_set_handler(riscc_irq_handler_t handler);

/* These tiny control helpers are also usable with a custom ASM vector. */
void riscc_irq_enable(void);
void riscc_irq_disable(void);

#ifdef __cplusplus
}
#endif

#endif

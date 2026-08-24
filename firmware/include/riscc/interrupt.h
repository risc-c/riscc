#ifndef RISCC_INTERRUPT_H
#define RISCC_INTERRUPT_H

#ifdef __cplusplus
extern "C"
{
#endif

/*
 * Installing a handler extracts the optional C IRQ wrapper and makes it the
 * vector implementation.  The wrapper calls the selected function with IRQs
 * masked, on its one global IRQ stack.  The handler must be non-null,
 * acknowledge every level-sensitive source before returning, and must not
 * enable nested interrupts.  Until a handler is installed, the runtime uses
 * its default halt loop.
 */
typedef void (*riscc_irq_handler_t)(void);

/* Install a non-null global C IRQ handler before enabling interrupts. */
void riscc_irq_set_handler(riscc_irq_handler_t handler);

/* These compact control helpers are also usable with a custom ASM vector. */
void riscc_irq_enable(void);
void riscc_irq_disable(void);

#ifdef __cplusplus
}
#endif

#endif

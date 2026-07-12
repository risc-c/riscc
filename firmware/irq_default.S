// Minimal fallback for an IRQ-capable image that does not opt into the C
// interrupt runtime.  A user-supplied strong __riscc_irq_vector overrides this
// weak symbol without pulling the C wrapper into the link.

        .section .text.__riscc_irq_unhandled,"ax",@progbits
        .p2align 1
        .weak __riscc_irq_vector
        .type __riscc_irq_vector,@function
__riscc_irq_vector:
.Lirq_halt:
        JMP8    .Lirq_halt
        .size __riscc_irq_vector, . - __riscc_irq_vector

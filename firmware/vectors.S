// Sys and Full have four-byte reset and IRQ vector slots. Min and Nano need
// only the compact reset jump because they have no interrupt entry.

        .section .vectors,"ax",@progbits
        .p2align 1
        .global __vectors
        .type __vectors,@object
__vectors:
#if defined(__RISCC_SYS__) || defined(__RISCC_FULL__)
        JMPL    _start
        JMPL    __riscc_irq_vector
        .size __vectors, . - __vectors

        // Keep the no-runtime fallback outside libirq.a.  Otherwise the
        // vector's unresolved reference selects the strong C wrapper from
        // the archive even when an application never opts into interrupts.
        .section .text.__riscc_irq_unhandled,"ax",@progbits
        .p2align 1
        .weak __riscc_irq_vector
        .type __riscc_irq_vector,@function
__riscc_irq_vector:
.Lirq_halt:
        JMP8    .Lirq_halt
        .size __riscc_irq_vector, . - __riscc_irq_vector
#else
        JMP8    _start
        .size __vectors, . - __vectors
#endif

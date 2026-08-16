// RISC-C reset and IRQ vector slots.  Each slot is exactly four bytes.

        .section .vectors,"ax",@progbits
        .p2align 1
        .global __vectors
        .type __vectors,@object
__vectors:
#if defined(__RISCC_SYS__) || defined(__RISCC_FULL__)
        JMPL    _start
        JMPL    __riscc_irq_vector
        .size __vectors, . - __vectors
#else
        JMP8    _start
        NOP
.Lno_irq:
        JMP8    .Lno_irq
        NOP
        .size __vectors, . - __vectors
#endif

// RISC-C reset and IRQ vector slots.  Each slot is exactly four bytes.

        .section .vectors,"ax",@progbits
        .p2align 1
        .global __vectors
        .type __vectors,@object
__vectors:
#if defined(__RISCC_MIN__) || defined(__RISCC_NANO__)
        JMP8    _start
        NOP
.Lno_irq:
        JMP8    .Lno_irq
        NOP
#else
        JAL16   S0, _start
        JAL16   S0, __riscc_irq_vector
#endif
        .size __vectors, . - __vectors

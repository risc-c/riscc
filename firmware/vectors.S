// RISC-C reset and IRQ vector slots.  Each slot is exactly four bytes.

        .section .vectors,"ax",@progbits
        .p2align 1
        .global __vectors
        .type __vectors,@object
__vectors:
#ifdef __RISCC_MIN__
        JMP8    _start
        NOP
.Lmin_irq:
        JMP8    .Lmin_irq
        NOP
#else
        JAL16   S0, _start
        JAL16   S0, __riscc_irq_vector
#endif
        .size __vectors, . - __vectors

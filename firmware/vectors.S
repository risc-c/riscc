// RISC-C reset and IRQ vector slots.  Each JAL16 is exactly four bytes.

        .section .vectors,"ax",@progbits
        .p2align 1
        .global __vectors
        .type __vectors,@object
__vectors:
        JAL16   S0, _start
        JAL16   S0, __riscc_irq_vector
        .size __vectors, . - __vectors

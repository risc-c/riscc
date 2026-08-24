// Minimal application-owned IRQ vector.  It deliberately does not use
// libirq: no C wrapper, TLS context prefix, or C IRQ stack is linked.

        .section .text.main,"ax",@progbits
        .p2align 1
        .global main
        .type main,@function
main:
#if defined(__RISCC_SYS__) || defined(__RISCC_FULL__)
        JALL    S7, riscc_irq_enable
#else
        LDI16   r0, riscc_irq_enable
        JALR    S7, r0
#endif
        LDI16   r0, 1
        LDI16   r1, 0xfffa
        ST     r0, [r1+0]        // Testbench IRQ raise register.

        LDI16   r0, 0x600d
        LDI16   r1, 0xfffe
        ST     r0, [r1+0]
.Ldone:
        JMP8    .Ldone
        .size main, . - main

        .section .text.__custom_irq_vector,"ax",@progbits
        .p2align 1
        .global __riscc_irq_vector
        .type __riscc_irq_vector,@function
__riscc_irq_vector:
        MTS    S1, r0
        MTS    S2, r1
        LDI16   r1, 0xfffa
        LD     r0, [r1+0]        // Read acknowledges the testbench IRQ.
        MFS    r1, S2
        MFS    r0, S1
        RETI    S0
        .size __riscc_irq_vector, . - __riscc_irq_vector

// Minimal application-owned IRQ vector.  It deliberately does not use
// libirq: no C wrapper, TLS context prefix, or C IRQ stack is linked.

        .section .text.main,"ax",@progbits
        .p2align 1
        .global main
        .type main,@function
main:
        CALL16  riscc_irq_enable
        LDI16   r0, 1
        LDI16   r1, 0xfffa
        STW     r0, [r1+0]        // Testbench IRQ raise register.

        LDI16   r0, 0x600d
        LDI16   r1, 0xfffe
        STW     r0, [r1+0]
.Ldone:
        JMP8    .Ldone
        .size main, . - main

        .section .text.__custom_irq_vector,"ax",@progbits
        .p2align 1
        .global __riscc_irq_vector
        .type __riscc_irq_vector,@function
__riscc_irq_vector:
        LDI16   r0, 1
        LDI16   r1, 0xfff8
        STW     r0, [r1+0]        // Testbench IRQ acknowledge register.
        RETI    S0
        .size __riscc_irq_vector, . - __riscc_irq_vector

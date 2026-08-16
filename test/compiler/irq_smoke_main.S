// Verify the runtime C ISR ABI with the testbench's level-sensitive IRQ.
// r7 is deliberately a leaf scratch value when the IRQ arrives; the wrapper
// must use its global IRQ stack rather than the interrupted r7.

        .section .text.main,"ax",@progbits
        .p2align 1
        .global main
        .type main,@function
        .extern irq_count
        .extern irq_smoke_install
        .extern riscc_irq_enable
        .extern riscc_irq_disable
main:
#if defined(__RISCC_SYS__) || defined(__RISCC_FULL__)
        JALL    S7, irq_smoke_install
        JALL    S7, riscc_irq_enable
#else
        LDI16   r0, irq_smoke_install
        JALR    S7, r0
        LDI16   r0, riscc_irq_enable
        JALR    S7, r0
#endif

        // S3 holds the normal C stack pointer; S4 holds the TLS anchor.
        // S7 is an ordinary interrupted link/scratch register to preserve.
        MTS     S3, r7
        MFS     r0, S2
        MTS     S4, r0
        LDI16   r0, 0x5a5a
        MTS     S5, r0
        LDI16   r0, 0x6b6b
        MTS     S6, r0
        LDI16   r0, 0x7c7c
        MTS     S7, r0

        LDI16   r0, 0x1111
        LDI16   r1, 0x2222
        LDI16   r2, 0x3333
        LDI16   r3, 0x4444
        LDI16   r4, 0x5555
        LDI16   r5, 0x6666
        LDI16   r6, 0xfffa
        LDI16   r7, 0x7777
        ST     r5, [r6+0]        // Testbench IRQ raise register.

        // The IRQ is accepted before this instruction. S1 is
        // interrupt-clobbered and safe for retaining the resumed r7 value.
        MTS     S1, r7

        // Resume ordinary code with its normal stack pointer, then retain the
        // resumed GPRs in a normal data-stack frame for comparison.
        MFS     r7, S3
        ADDI    r7, -14
        ST     r0, [r7+0]
        ST     r1, [r7+2]
        ST     r2, [r7+4]
        ST     r3, [r7+6]
        ST     r4, [r7+8]
        ST     r5, [r7+10]
        ST     r6, [r7+12]

        LDI16   r0, 0x7777
        MFS     r1, S1
        SUB     r0, r1, r0
        BNEZ    .Lfail

        LDI16   r0, irq_count
        LD     r0, [r0+0]
        ADDI    r0, -1
        BNEZ    .Lfail

        LD     r0, [r7+0]
        LDI16   r1, 0x1111
        SUB     r0, r0, r1
        BNEZ    .Lfail
        LD     r0, [r7+2]
        LDI16   r1, 0x2222
        SUB     r0, r0, r1
        BNEZ    .Lfail
        LD     r0, [r7+4]
        LDI16   r1, 0x3333
        SUB     r0, r0, r1
        BNEZ    .Lfail
        LD     r0, [r7+6]
        LDI16   r1, 0x4444
        SUB     r0, r0, r1
        BNEZ    .Lfail
        LD     r0, [r7+8]
        LDI16   r1, 0x5555
        SUB     r0, r0, r1
        BNEZ    .Lfail
        LD     r0, [r7+10]
        LDI16   r1, 0x6666
        SUB     r0, r0, r1
        BNEZ    .Lfail
        LD     r0, [r7+12]
        LDI16   r1, 0xfffa
        SUB     r0, r0, r1
        BNEZ    .Lfail

        // Check the ordinary stack, TLS, and user link-register state.
        MFS     r0, S3
        ADDI    r0, -14
        SUB     r0, r7, r0
        BNEZ    .Lfail
        MFS     r0, S2
        MFS     r1, S4
        SUB     r0, r0, r1
        BNEZ    .Lfail
        MFS     r0, S5
        LDI16   r1, 0x5a5a
        SUB     r0, r0, r1
        BNEZ    .Lfail
        MFS     r0, S6
        LDI16   r1, 0x6b6b
        SUB     r0, r0, r1
        BNEZ    .Lfail
        MFS     r0, S7
        LDI16   r1, 0x7c7c
        SUB     r0, r0, r1
        BNEZ    .Lfail

        ADDI    r7, 14
#if defined(__RISCC_SYS__) || defined(__RISCC_FULL__)
        JALL    S7, riscc_irq_disable
#else
        LDI16   r0, riscc_irq_disable
        JALR    S7, r0
#endif
        LDI16   r0, 0x600d
        LDI16   r1, 0xfffe
        ST     r0, [r1+0]
.Ldone:
        JMP8    .Ldone

.Lfail:
        LDI16   r0, 0xdead
        LDI16   r1, 0xfffe
        ST     r0, [r1+0]
.Lfail_halt:
        JMP8    .Lfail_halt
        .size main, . - main

        // Deliberately violate the normal software-cache convention inside
        // the ISR. The IRQ wrapper must restore all four registers.
        .section .text.irq_smoke_clobber_s,"ax",@progbits
        .p2align 1
        .global irq_smoke_clobber_s
        .type irq_smoke_clobber_s,@function
irq_smoke_clobber_s:
        LDI16   r0, 0x0303
        MTS     S3, r0
        LDI16   r0, 0x0404
        MTS     S4, r0
        LDI16   r0, 0x0505
        MTS     S5, r0
        LDI16   r0, 0x0606
        MTS     S6, r0
        RET     S7
        .size irq_smoke_clobber_s, . - irq_smoke_clobber_s

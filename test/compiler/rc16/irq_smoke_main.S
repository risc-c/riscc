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

        // S3 holds a normal-stack save area. Exercise caller-saved S2/S4 and
        // callee-saved S5/S6 while S7 holds interrupted link state.
        ADDI    r7, -16
        MTS     S3, r7
        LDI16   r0, 0x2a2a
        MTS     S2, r0
        LDI16   r0, 0x4a4a
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
        LDI16   r5, 0xfffa
        MFS     r6, S3
        LDI16   r7, 0x7777
        ST      r4, [r5+0]        // Testbench IRQ raise register.

        // Save every resumed GPR before reclaiming r7 as the stack pointer.
        ST      r0, [r6+0]
        ST      r1, [r6+2]
        ST      r2, [r6+4]
        ST      r3, [r6+6]
        ST      r4, [r6+8]
        ST      r5, [r6+10]
        ST      r6, [r6+12]
        ST      r7, [r6+14]
        MFS     r7, S3

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
        LDI16   r1, 0xfffa
        SUB     r0, r0, r1
        BNEZ    .Lfail
        LD     r0, [r7+12]
        SUB     r0, r0, r7
        BNEZ    .Lfail
        LD     r0, [r7+14]
        LDI16   r1, 0x7777
        SUB     r0, r0, r1
        BNEZ    .Lfail

        // Check the ordinary stack and interrupted S-register state.
        MFS     r0, S3
        SUB     r0, r7, r0
        BNEZ    .Lfail
        MFS     r0, S2
        LDI16   r1, 0x2a2a
        SUB     r0, r0, r1
        BNEZ    .Lfail
        MFS     r0, S4
        LDI16   r1, 0x4a4a
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

        ADDI    r7, 16
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

        // Exercise caller-saved S2..S4 while preserving callee-saved r4,
        // S5, and S6 in this ABI-conforming ISR helper.
        .section .text.irq_smoke_clobber_s,"ax",@progbits
        .p2align 1
        .global irq_smoke_clobber_s
        .type irq_smoke_clobber_s,@function
irq_smoke_clobber_s:
        ADDI    r7, -6
        ST      r4, [r7+0]
        MFS     r0, S5
        ST      r0, [r7+2]
        MFS     r0, S6
        ST      r0, [r7+4]

        LDI16   r4, 0x0505
        LDI16   r0, 0x0202
        MTS     S2, r0
        LDI16   r0, 0x0303
        MTS     S3, r0
        LDI16   r0, 0x0404
        MTS     S4, r0
        LDI16   r0, 0x0505
        MTS     S5, r0
        LDI16   r0, 0x0606
        MTS     S6, r0

        LD      r0, [r7+2]
        MTS     S5, r0
        LD      r0, [r7+4]
        MTS     S6, r0
        LD      r4, [r7+0]
        ADDI    r7, 6
        RET     S7
        .size irq_smoke_clobber_s, . - irq_smoke_clobber_s

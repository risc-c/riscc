// Verify the RC32 runtime C ISR ABI with the testbench's level-sensitive IRQ.
// r7 is deliberately a leaf scratch value at interrupt entry; the wrapper
// must switch to its private IRQ stack before calling the C handler.

        .section .text.main,"ax",@progbits
        .p2align 1
        .global main
        .type main,@function
        .extern irq_count
        .extern irq_smoke_install
        .extern riscc_irq_enable
        .extern riscc_irq_disable
main:
        JALL    S7, irq_smoke_install
        JALL    S7, riscc_irq_enable

        // S3 holds a normal-stack save area. Exercise caller-saved S2/S4 and
        // callee-saved S5/S6 while S7 holds interrupted link state.
        ADDI    r7, -32
        MTS     S3, r7
        LDI     r0, 0x2a
        MTS     S2, r0
        LDI     r0, 0x4a
        MTS     S4, r0
        LDI     r0, 0x5a
        MTS     S5, r0
        LDI     r0, 0x6b
        MTS     S6, r0
        LDI     r0, 0x7c
        MTS     S7, r0

        LDI     r0, 0x11
        LDI     r1, 0x22
        LDI     r2, 0x33
        LDI     r3, 0x44
        LDI     r4, 0x55
        LDPC    r5, .Lirq_cause
        MFS     r6, S3
        LDI     r7, 0x77
        STH     r4, [r5]          // Testbench IRQ raise register.

        // Save every resumed GPR before reclaiming r7 as the stack pointer.
        ST      r0, [r6+0]
        ST      r1, [r6+4]
        ST      r2, [r6+8]
        ST      r3, [r6+12]
        ST      r4, [r6+16]
        ST      r5, [r6+20]
        ST      r6, [r6+24]
        ST      r7, [r6+28]
        MFS     r7, S3

        LDPC    r0, .Lirq_count
        LD      r0, [r0+0]
        ADDI    r0, -1
        BNEZ    .Lfail

        LD      r0, [r7+0]
        LDI     r1, 0x11
        SUB     r0, r0, r1
        BNEZ    .Lfail
        LD      r0, [r7+4]
        LDI     r1, 0x22
        SUB     r0, r0, r1
        BNEZ    .Lfail
        LD      r0, [r7+8]
        LDI     r1, 0x33
        SUB     r0, r0, r1
        BNEZ    .Lfail
        LD      r0, [r7+12]
        LDI     r1, 0x44
        SUB     r0, r0, r1
        BNEZ    .Lfail
        LD      r0, [r7+16]
        LDI     r1, 0x55
        SUB     r0, r0, r1
        BNEZ    .Lfail
        LD      r0, [r7+20]
        LDPC    r1, .Lirq_cause
        SUB     r0, r0, r1
        BNEZ    .Lfail
        LD      r0, [r7+24]
        SUB     r0, r0, r7
        BNEZ    .Lfail
        LD      r0, [r7+28]
        LDI     r1, 0x77
        SUB     r0, r0, r1
        BNEZ    .Lfail

        // Check ordinary-stack and interrupted S-register state.
        MFS     r0, S3
        SUB     r0, r7, r0
        BNEZ    .Lfail
        MFS     r0, S2
        LDI     r1, 0x2a
        SUB     r0, r0, r1
        BNEZ    .Lfail
        MFS     r0, S4
        LDI     r1, 0x4a
        SUB     r0, r0, r1
        BNEZ    .Lfail
        MFS     r0, S5
        LDI     r1, 0x5a
        SUB     r0, r0, r1
        BNEZ    .Lfail
        MFS     r0, S6
        LDI     r1, 0x6b
        SUB     r0, r0, r1
        BNEZ    .Lfail
        MFS     r0, S7
        LDI     r1, 0x7c
        SUB     r0, r0, r1
        BNEZ    .Lfail

        ADDI    r7, 32
        JALL    S7, riscc_irq_disable
        LDPC    r0, .Lpass_code
        LDPC    r1, .Lirq_cause
        ADDI    r1, 4
        STH     r0, [r1]
.Ldone:
        JMP8    .Ldone

.Lfail:
        LDPC    r0, .Lfail_code
        LDPC    r1, .Lirq_cause
        ADDI    r1, 4
        STH     r0, [r1]
.Lfail_halt:
        JMP8    .Lfail_halt
        .size main, . - main

        // Literal pool is outside every executed main path.
        .p2align 2
.Lirq_cause:
        .long   0x0000fffa
.Lirq_count:
        .long   irq_count
.Lpass_code:
        .long   0x0000600d
.Lfail_code:
        .long   0x0000dead

        // Exercise caller-saved S2..S4 in the C handler while preserving
        // callee-saved r4, S5, and S6 in this ABI-conforming helper.
        .section .text.irq_smoke_clobber_s,"ax",@progbits
        .p2align 1
        .global irq_smoke_clobber_s
        .type irq_smoke_clobber_s,@function
irq_smoke_clobber_s:
        ADDI    r7, -12
        ST      r4, [r7+0]
        MFS     r0, S5
        ST      r0, [r7+4]
        MFS     r0, S6
        ST      r0, [r7+8]

        LDI     r4, 5
        LDI     r0, 2
        MTS     S2, r0
        LDI     r0, 3
        MTS     S3, r0
        LDI     r0, 4
        MTS     S4, r0
        LDI     r0, 5
        MTS     S5, r0
        LDI     r0, 6
        MTS     S6, r0

        LD      r0, [r7+4]
        MTS     S5, r0
        LD      r0, [r7+8]
        MTS     S6, r0
        LD      r4, [r7+0]
        ADDI    r7, 12
        RET     S7
        .size irq_smoke_clobber_s, . - irq_smoke_clobber_s

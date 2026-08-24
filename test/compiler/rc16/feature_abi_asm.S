// Assembly oracle for the C ABI's callee-save requirement.

        .section .text.feature_check_callee_saved,"ax",@progbits
        .p2align 1
        .global feature_check_callee_saved
        .type feature_check_callee_saved,@function
        .extern feature_abi_pressure
feature_check_callee_saved:
        MOV     r0, r7
        ANDI    r0, 1
        BNEZ    .Lstack_unaligned
#ifdef __RISCC_NANO__
        // Nano preserves r4 and r5. Save our incoming r6 return address
        // because the nested call is allowed to clobber it.
        ADDI    r7, -6
        ST     r4, [r7+0]
        ST     r5, [r7+2]
        ST     r6, [r7+4]

        LDI16   r4, 0x0f0f
        LDI16   r5, 0x55aa
        LDI     r1, 7
        LDI16   r0, feature_abi_pressure
        JALR    r6, r0

        LDI16   r0, 0x0f0f
        SUB     r0, r4, r0
        BNEZ    .Lr4_failed_nano
        LDI16   r0, 0x55aa
        SUB     r0, r5, r0
        BNEZ    .Lr5_failed_nano
        LDI     r1, 0
        JMP8    .Lrestore_nano

.Lr4_failed_nano:
        LDI     r1, 1
        JMP8    .Lrestore_nano

.Lr5_failed_nano:
        LDI     r1, 2

.Lrestore_nano:
        LD     r4, [r7+0]
        LD     r5, [r7+2]
        LD     r2, [r7+4]
        ADDI    r7, 6
        JMP     r2

.Lstack_unaligned:
        LDI     r1, 3
        JMP     r6
#else
        ADDI    r7, -12
        ST     r4, [r7+0]
        ST     r5, [r7+2]
        ST     r6, [r7+4]
        MFS     r0, S5
        ST     r0, [r7+6]
        MFS     r0, S6
        ST     r0, [r7+8]
        MFS     r0, S7
        ST     r0, [r7+10]

        LDI16   r4, 0x0f0f
        LDI16   r5, 0x55aa
        LDI16   r6, 0xaa55
        LDI16   r0, 0x1234
        MTS     S5, r0
        LDI16   r0, 0x4321
        MTS     S6, r0
        LDI     r1, 7
#if defined(__RISCC_SYS__) || defined(__RISCC_FULL__)
        JALL    S7, feature_abi_pressure
#else
        LDI16   r0, feature_abi_pressure
        JALR    S7, r0
#endif

        LDI16   r0, 0x0f0f
        SUB     r0, r4, r0
        BNEZ    .Lr4_failed
        LDI16   r0, 0x55aa
        SUB     r0, r5, r0
        BNEZ    .Lr5_failed
        LDI16   r0, 0xaa55
        SUB     r0, r6, r0
        BNEZ    .Lr6_failed
        MFS     r0, S5
        LDI16   r2, 0x1234
        SUB     r0, r0, r2
        BNEZ    .Ls5_failed
        MFS     r0, S6
        LDI16   r2, 0x4321
        SUB     r0, r0, r2
        BNEZ    .Ls6_failed
        LDI     r1, 0
        JMP8    .Lrestore

.Lr4_failed:
        LDI     r1, 1
        JMP8    .Lrestore
.Lr5_failed:
        LDI     r1, 2
        JMP8    .Lrestore
.Lr6_failed:
        LDI     r1, 3
        JMP8    .Lrestore
.Ls5_failed:
        LDI     r1, 4
        JMP8    .Lrestore
.Ls6_failed:
        LDI     r1, 5

.Lrestore:
        LD     r4, [r7+0]
        LD     r5, [r7+2]
        LD     r6, [r7+4]
        LD     r0, [r7+6]
        MTS     S5, r0
        LD     r0, [r7+8]
        MTS     S6, r0
        LD     r0, [r7+10]
        MTS     S7, r0
        ADDI    r7, 12
        RET     S7

.Lstack_unaligned:
        LDI     r1, 6
        RET     S7
#endif
        .size feature_check_callee_saved, . - feature_check_callee_saved

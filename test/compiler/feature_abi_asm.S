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
        // Nano has only one callee-saved GPR (r5). Save our incoming r6
        // return address because the nested call is allowed to clobber it.
        ADDI    r7, -4
        STW     r5, [r7+0]
        STW     r6, [r7+2]

        LDI16   r5, 0x55aa
        LDI     r1, 7
        LDI16   r0, code(feature_abi_pressure)
        JAL     r6, r0

        LDI16   r0, 0x55aa
        SUB     r0, r5, r0
        BNEZ    .Lr5_failed_nano
        LDI     r1, 0
        JMP8    .Lrestore_nano

.Lr5_failed_nano:
        LDI     r1, 1

.Lrestore_nano:
        LDW     r5, [r7+0]
        LDW     r2, [r7+2]
        ADDI    r7, 4
        JAL     r0, r2

.Lstack_unaligned:
        LDI     r1, 3
        JAL     r0, r6
#else
        ADDI    r7, -6
        STW     r5, [r7+0]
        STW     r6, [r7+2]
        MFS     r0, S7
        STW     r0, [r7+4]

        LDI16   r5, 0x55aa
        LDI16   r6, 0xaa55
        LDI     r1, 7
#ifdef __RISCC_MIN__
        LDI16   r0, code(feature_abi_pressure)
        CALL    r0
#else
        CALL16  feature_abi_pressure
#endif

        LDI16   r0, 0x55aa
        SUB     r0, r5, r0
        BNEZ    .Lr5_failed
        LDI16   r0, 0xaa55
        SUB     r0, r6, r0
        BNEZ    .Lr6_failed
        LDI     r1, 0
        JMP8    .Lrestore

.Lr5_failed:
        LDI     r1, 1
        JMP8    .Lrestore
.Lr6_failed:
        LDI     r1, 2

.Lrestore:
        LDW     r5, [r7+0]
        LDW     r6, [r7+2]
        LDW     r0, [r7+4]
        MTS     S7, r0
        ADDI    r7, 6
        RETS

.Lstack_unaligned:
        LDI     r1, 3
        RETS
#endif
        .size feature_check_callee_saved, . - feature_check_callee_saved

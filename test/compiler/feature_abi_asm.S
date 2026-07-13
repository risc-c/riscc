// Assembly oracle for the C ABI's r5/r6 callee-save requirement.

        .section .text.feature_check_callee_saved,"ax",@progbits
        .p2align 1
        .global feature_check_callee_saved
        .type feature_check_callee_saved,@function
        .extern feature_abi_pressure
feature_check_callee_saved:
        MOV     r0, r7
        ANDI    r0, 1
        BNEZ    .Lstack_unaligned
        ADDI    r7, -6
        STW     r5, [r7+0]
        STW     r6, [r7+2]
        MFS     r0, S7
        STW     r0, [r7+4]

        LDI16   r5, 0x55aa
        LDI16   r6, 0xaa55
        LDI     r1, 7
        CALL16  feature_abi_pressure

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
        .size feature_check_callee_saved, . - feature_check_callee_saved

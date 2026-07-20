/*
 * Compact Nano binary32 add/subtract core.
 *
 * Contract matches Nano's size-tuned multiply: finite normal arithmetic,
 * round-to-nearest/ties-to-even, and exponent-zero operands treated as
 * signed zero.  __subsf3 remains the compiler-rt sign-flip wrapper.
 */

        .macro NANO_FSL1 d, high, low
        ADD     \d, \high, \high
        MOV     r0, \low
        BGEZ    .Lfsl_done\@
        ORI     \d, 1
.Lfsl_done\@:
        .endm

        .section .text.__addsf3,"ax",@progbits
        .p2align 1
        .global __addsf3
        .hidden __addsf3
        .type __addsf3,@function
__addsf3:
        STW     r5, [r7 - 12]
        STW     r6, [r7 - 10]
        STW     r2, [r7 - 8]           /* left sign */
        STW     r4, [r7 - 6]           /* right sign */

        LDI16   r5, 0x7f80
        AND     r6, r2, r5
        MOV     r0, r6
        BNEZ    .Lleft_normal
        MOV     r1, r3                 /* exponent-zero left is zero */
        MOV     r2, r4
        JMP8    .Learly_return

.Lleft_normal:
        STW     r6, [r7 - 4]
        AND     r0, r4, r5
        BNEZ    .Lboth_normal
        /* exponent-zero right is zero; left is already the result */
.Learly_return:
        LDW     r6, [r7 - 10]
        LDW     r5, [r7 - 12]
        RET     r6

.Lboth_normal:
        STW     r0, [r7 - 2]
        ANDI    r2, 0x7f
        ORI     r2, 0x80
        ANDI    r4, 0x7f
        ORI     r4, 0x80

        /* Put the larger magnitude in r2:r1. */
        LDW     r5, [r7 - 4]
        LDW     r6, [r7 - 2]
        SLTU    r0, r5, r6
        BNEZ    .Lswap
        SUB     r0, r5, r6
        BNEZ    .Lordered
        SLTU    r0, r2, r4
        BNEZ    .Lswap
        SUB     r0, r2, r4
        BNEZ    .Lordered
        SLTU    r0, r1, r3
        BEQZ    .Lordered

.Lswap:
        MOV     r0, r1
        MOV     r1, r3
        MOV     r3, r0
        MOV     r0, r2
        MOV     r2, r4
        MOV     r4, r0
        MOV     r0, r5
        MOV     r5, r6
        MOV     r6, r0
        LDW     r0, [r7 - 8]
        LDW     r6, [r7 - 6]
        STW     r6, [r7 - 8]
        STW     r0, [r7 - 6]
        LDW     r5, [r7 - 2]           /* swapped larger exponent */
        LDW     r6, [r7 - 4]           /* swapped smaller exponent */

.Lordered:
        STW     r5, [r7 - 4]           /* result exponent field */

        /* Add three guard/round/sticky bits. */
        .rept 3
        NANO_FSL1 r2, r2, r1
        ADD     r1, r1, r1
        NANO_FSL1 r4, r4, r3
        ADD     r3, r3, r3
        .endr

        /* Convert the encoded exponent difference to a shift count. */
        SUB     r5, r5, r6
        .rept 7
        SHRI    r5, r5, 1
        .endr
        LDI     r0, 0
        STW     r0, [r7 - 2]           /* discarded-bit sticky */
        LDI     r6, 27
        SLTU    r0, r5, r6
        BNEZ    .Lalign_test
        LDI     r3, 1                  /* nonzero operand becomes sticky */
        LDI     r4, 0
        JMP8    .Laligned

.Lalign_test:
        MOV     r0, r5
        BEQZ    .Laligned
        LUI     r6, 0x80
.Lalign:
        MOV     r0, r3
        ANDI    r0, 1
        BEQZ    .Lsticky_done
        LDI     r0, 1
        STW     r0, [r7 - 2]
.Lsticky_done:
        MOV     r0, r4
        ANDI    r0, 1
        SHRI    r3, r3, 1
        BEQZ    .Lalign_no_carry
        OR      r3, r3, r6
.Lalign_no_carry:
        SHRI    r4, r4, 1
        ADDI    r5, -1
        MOV     r0, r5
        BNEZ    .Lalign
        LDW     r0, [r7 - 2]
        BEQZ    .Laligned
        ORI     r3, 1

.Laligned:
        LDW     r5, [r7 - 8]
        LDW     r6, [r7 - 6]
        XOR     r0, r5, r6
        BLTZ    .Lsubtract

        ADD     r5, r1, r3
        SLTU    r0, r5, r1
        ADD     r2, r2, r4
        ADD     r2, r2, r0
        MOV     r1, r5
        LUI     r6, 8
        AND     r0, r2, r6
        BEQZ    .Lround

        /* Addition overflow: shift right once with sticky. */
        MOV     r0, r1
        ANDI    r0, 1
        STW     r0, [r7 - 2]
        MOV     r0, r2
        ANDI    r0, 1
        SHRI    r1, r1, 1
        BEQZ    .Ladd_shift_no_carry
        LUI     r0, 0x80
        OR      r1, r1, r0
.Ladd_shift_no_carry:
        SHRI    r2, r2, 1
        LDW     r0, [r7 - 2]
        BEQZ    .Ladd_shift_sticky_done
        ORI     r1, 1
.Ladd_shift_sticky_done:
        LDW     r5, [r7 - 4]
        LDI     r0, 0x80
        ADD     r5, r5, r0
        STW     r5, [r7 - 4]
        JMP8    .Lround

.Lsubtract:
        SLTU    r5, r1, r3
        SUB     r1, r1, r3
        SUB     r2, r2, r4
        SUB     r2, r2, r5
        OR      r0, r1, r2
        BNEZ    .Lnormalize_test
        LDI     r1, 0                  /* exact cancellation is +0 */
        LDI     r2, 0
        JMP8    .Lreturn

.Lnormalize_test:
        LUI     r6, 4
.Lnormalize:
        AND     r0, r2, r6
        BNEZ    .Lround
        LDW     r5, [r7 - 4]
        ADDI    r5, -128
        MOV     r0, r5
        BEQZ    .Lunderflow
        STW     r5, [r7 - 4]
        NANO_FSL1 r2, r2, r1
        ADD     r1, r1, r1
        JMP8    .Lnormalize

.Lunderflow:
        LDI     r1, 0
        LDI     r2, 0
        LDW     r0, [r7 - 8]
        BGEZ    .Lreturn
        LUI     r2, 0x80
        JMP8    .Lreturn

        /* Round the 27-bit result to binary32. */
.Lround:
        MOV     r0, r1
        ANDI    r0, 7
        LDI     r5, 4
        SLTU    r6, r0, r5
        MOV     r0, r6
        BNEZ    .Lrounded
        MOV     r0, r1
        ANDI    r0, 7
        SLTU    r6, r5, r0
        MOV     r0, r6
        BNEZ    .Lround_up
        MOV     r0, r1
        ANDI    r0, 8
        BEQZ    .Lrounded
.Lround_up:
        ADDI    r1, 8
        LDI     r5, 8
        SLTU    r0, r1, r5            /* adding eight wrapped into 0..7 */
        ADD     r2, r2, r0

.Lrounded:
        LUI     r6, 8
        AND     r0, r2, r6
        BEQZ    .Lpack
        LDI     r1, 0
        LUI     r2, 4
        LDW     r5, [r7 - 4]
        LDI     r0, 0x80
        ADD     r5, r5, r0
        STW     r5, [r7 - 4]

.Lpack:
        LUI     r6, 0x80
        LDI     r5, 3
.Lpack_shift:
        MOV     r0, r2
        ANDI    r0, 1
        SHRI    r1, r1, 1
        BEQZ    .Lpack_no_carry
        OR      r1, r1, r6
.Lpack_no_carry:
        SHRI    r2, r2, 1
        ADDI    r5, -1
        MOV     r0, r5
        BNEZ    .Lpack_shift
        ANDI    r2, 0x7f
        LDW     r5, [r7 - 4]
        OR      r2, r2, r5
        LDW     r5, [r7 - 8]
        LUI     r0, 0x80
        AND     r5, r5, r0
        OR      r2, r2, r5

.Lreturn:
        LDW     r6, [r7 - 10]
        LDW     r5, [r7 - 12]
        RET     r6
        .size __addsf3, . - __addsf3

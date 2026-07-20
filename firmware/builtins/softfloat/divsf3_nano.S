/*
 * Compact Nano binary32 divide.
 *
 * Finite normal operands are divided with round-to-nearest/ties-to-even.
 * An exponent-zero numerator flushes to signed zero; an exponent-zero
 * denominator produces signed infinity.  Other IEEE special values and
 * gradual underflow are outside Nano's reduced binary32 contract.
 */

        .macro NANO_FSL1 d, high, low
        ADD     \d, \high, \high
        MOV     r0, \low
        BGEZ    .Lfsl_done\@
        ORI     \d, 1
.Lfsl_done\@:
        .endm

        .macro NANO_DIV_ROUND
        NANO_FSL1 r2, r2, r1
        ADD     r1, r1, r1
        NANO_FSL1 r4, r4, r3
        ADD     r3, r3, r3

        SLTU    r0, r4, r6
        BNEZ    .Ldiv_no_subtract\@
        SUB     r0, r4, r6
        BNEZ    .Ldiv_subtract\@
        SLTU    r0, r3, r5
        BNEZ    .Ldiv_no_subtract\@
.Ldiv_subtract\@:
        SLTU    r0, r3, r5
        SUB     r3, r3, r5
        SUB     r4, r4, r6
        SUB     r4, r4, r0
        ORI     r1, 1
.Ldiv_no_subtract\@:
        .endm

        .section .text.__divsf3,"ax",@progbits
        .p2align 1
        .global __divsf3
        .hidden __divsf3
        .type __divsf3,@function
__divsf3:
        STW     r5, [r7 - 10]
        STW     r6, [r7 - 8]
        XOR     r0, r2, r4
        STW     r0, [r7 - 6]

        LDI16   r5, 0x7f80
        AND     r6, r2, r5
        MOV     r0, r6
        BNEZ    .Lnumerator_normal

        /* Signed zero numerator. */
        LDI     r1, 0
        LDI     r2, 0
        JMP8    .Learly_sign

.Lnumerator_normal:
        STW     r6, [r7 - 4]
        AND     r0, r4, r5
        BNEZ    .Lboth_normal

        /* Division by exponent-zero denominator. */
        LDI     r1, 0
        LDI16   r2, 0x7f80
.Learly_sign:
        LDW     r0, [r7 - 6]
        BGEZ    .Learly_return
        LUI     r0, 0x80
        OR      r2, r2, r0
.Learly_return:
        LDW     r6, [r7 - 8]
        LDW     r5, [r7 - 10]
        RET     r6

.Lboth_normal:
        /* Biased result exponent: a_exp - b_exp + 127. */
        LDW     r6, [r7 - 4]
        SUB     r6, r6, r0
        LDI16   r5, 0x3f80
        ADD     r6, r6, r5
        STW     r6, [r7 - 4]

        /* Restore implicit leading ones and retain the divisor in r6:r5. */
        ANDI    r2, 0x7f
        ORI     r2, 0x80
        ANDI    r4, 0x7f
        ORI     r4, 0x80
        MOV     r5, r3
        MOV     r6, r4

        /* Normalize the quotient into [1,2). */
        SLTU    r0, r2, r6
        BNEZ    .Lnumerator_smaller
        SUB     r0, r2, r6
        BNEZ    .Lnumerator_ready
        SLTU    r0, r1, r5
        BEQZ    .Lnumerator_ready
.Lnumerator_smaller:
        NANO_FSL1 r2, r2, r1
        ADD     r1, r1, r1
        LDW     r0, [r7 - 4]
        ADDI    r0, -128
        STW     r0, [r7 - 4]

.Lnumerator_ready:
        /* remainder = normalized numerator - divisor */
        SLTU    r0, r1, r5
        SUB     r3, r1, r5
        SUB     r4, r2, r6
        SUB     r4, r4, r0
        LDI     r1, 1
        LDI     r2, 0
        LDI     r0, 13
        STW     r0, [r7 - 2]

.Ldivide:
        .rept 2
        NANO_DIV_ROUND
        .endr
        LDW     r0, [r7 - 2]
        ADDI    r0, -1
        STW     r0, [r7 - 2]
        BNEZ    .Ldivide

        /* Any nonzero remainder is the sticky bit. */
        OR      r0, r3, r4
        BEQZ    .Lround
        ORI     r1, 1

        /* Round the 27-bit quotient. */
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
        SLTU    r0, r1, r5
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
        LDW     r5, [r7 - 6]
        LUI     r0, 0x80
        AND     r5, r5, r0
        OR      r2, r2, r5

        LDW     r6, [r7 - 8]
        LDW     r5, [r7 - 10]
        RET     r6
        .size __divsf3, . - __divsf3

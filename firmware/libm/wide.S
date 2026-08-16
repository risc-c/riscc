/*
 * Unsigned arbitrary-precision comparison for the libm inner loops.
 *
 * Start just above the high limb, then walk down.  r4 and r5 hold the two
 * current limbs; no third callee-saved GPR is needed.  S3/S4 are specifically
 * scratch cache slots, so mainline can preserve r4/r5 without a stack frame.
 */

#ifdef __RISCC_NANO__
        .macro MATH_COMPARE_RETURN
        LD      r5, [r7 + 2]
        LD      r4, [r7 + 0]
        ADDI    r7, 4
        JMP     r6
        .endm
#else
        .macro MATH_COMPARE_RETURN
        MFS     r5, s4
        MFS     r4, s3
        RET     S7
        .endm
#endif

        .section .text.__riscc_math_compare,"ax",@progbits
        .p2align 1
        .global __riscc_math_compare
        .hidden __riscc_math_compare
        .type __riscc_math_compare,@function
__riscc_math_compare:
#ifdef __RISCC_NANO__
        ADDI    r7, -4
        ST      r4, [r7 + 0]
        ST      r5, [r7 + 2]
#else
        MTS     s3, r4
        MTS     s4, r5
#endif
        MOV     r0, r3
        BEQZ    .Lmath_compare_equal
        ADD     r0, r3, r3
        ADD     r1, r1, r0
        ADD     r2, r2, r0
.Lmath_compare_loop:
        ADDI    r1, -2
        ADDI    r2, -2
        LD      r4, [r1 + 0]
        LD      r5, [r2 + 0]
        SUB     r0, r4, r5
        BNEZ    .Lmath_compare_different
        ADDI    r3, -1
        MOV     r0, r3
        BNEZ    .Lmath_compare_loop
.Lmath_compare_equal:
        LDI     r1, 0
        JMP8    .Lmath_compare_return
.Lmath_compare_different:
        LDI     r1, 1
        SLTU    r0, r4, r5
        BEQZ    .Lmath_compare_return
        LUI     r1, 255
        ORI     r1, 255
.Lmath_compare_return:
        MATH_COMPARE_RETURN
        .size __riscc_math_compare, . - __riscc_math_compare

/*
 * Small in-place arbitrary-precision helpers used in libm inner loops.
 */

#ifdef __RISCC_NANO__
#define MATH_RETURN RET r6
#else
#define MATH_RETURN RETS
#endif

        .macro FUNCTION name
        .section .text.\name,"ax",@progbits
        .p2align 1
        .global \name
        .hidden \name
        .type \name,@function
\name:
        .endm

        FUNCTION __riscc_math_is_zero
        MOV     r0, r2
        BEQZ    .Lmath_zero_yes
.Lmath_zero_loop:
        LDW     r0, [r1 + 0]
        BNEZ    .Lmath_zero_no
        ADDI    r1, 2
        ADDI    r2, -1
        MOV     r0, r2
        BNEZ    .Lmath_zero_loop
.Lmath_zero_yes:
        LDI     r1, 1
        MATH_RETURN
.Lmath_zero_no:
        LDI     r1, 0
        MATH_RETURN
        .size __riscc_math_is_zero, . - __riscc_math_is_zero

        FUNCTION __riscc_math_increment
        MOV     r0, r2
        BEQZ    .Lmath_increment_done
.Lmath_increment_loop:
        LDW     r0, [r1 + 0]
        ADDI    r0, 1
        STW     r0, [r1 + 0]
        BNEZ    .Lmath_increment_done
        ADDI    r1, 2
        ADDI    r2, -1
        MOV     r0, r2
        BNEZ    .Lmath_increment_loop
.Lmath_increment_done:
        MATH_RETURN
        .size __riscc_math_increment, . - __riscc_math_increment

        FUNCTION __riscc_math_subtract
#ifdef __RISCC_NANO__
        STW     r5, [r7 - 2]
        STW     r6, [r7 - 4]
#else
        MTS     s4, r5
        MTS     s5, r6
#endif
        LDI     r4, 0                   /* incoming borrow */
        MOV     r0, r3
        BEQZ    .Lmath_subtract_done
.Lmath_subtract_loop:
        LDW     r5, [r1 + 0]
        LDW     r6, [r2 + 0]
        SUB     r0, r5, r4
        SLTU    r4, r5, r4
        SUB     r5, r0, r6
        SLTU    r0, r0, r6
        OR      r4, r4, r0
        STW     r5, [r1 + 0]
        ADDI    r1, 2
        ADDI    r2, 2
        ADDI    r3, -1
        MOV     r0, r3
        BNEZ    .Lmath_subtract_loop
.Lmath_subtract_done:
#ifdef __RISCC_NANO__
        LDW     r6, [r7 - 4]
        LDW     r5, [r7 - 2]
#else
        MFS     r6, s5
        MFS     r5, s4
#endif
        MATH_RETURN
        .size __riscc_math_subtract, . - __riscc_math_subtract

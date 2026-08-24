/*
 * RC16 in-place arbitrary-precision shifts used by sqrt and fmod.
 *
 * Mainline copies each current limb to the result register, then feeds the
 * unmodified adjacent limb to compact FSL1/FSR1.  Nano lacks funnels, so it
 * conditionally inserts the carry bit with the same in-place traversal.
 */

#ifdef __RISCC_NANO__
#define MATH_RETURN JMP r6
#else
#define MATH_RETURN RET S7
#endif

        .macro SAVE_R4
        ADDI    r7, -2
        ST      r4, [r7 + 0]
        .endm

        .macro RESTORE_R4
        LD      r4, [r7 + 0]
        ADDI    r7, 2
        .endm

        .macro FUNCTION name
        .section .text.\name,"ax",@progbits
        .p2align 1
        .global \name
        .hidden \name
        .type \name,@function
\name:
        .endm

        FUNCTION __riscc_math_shift_left_one
        SAVE_R4
        LDI     r3, 0                   /* previous unmodified lower limb */
        MOV     r0, r2
        BEQZ    .Lmath_shl1_done
.Lmath_shl1_loop:
        LD     r4, [r1 + 0]
#ifdef __RISCC_NANO__
        MOV     r0, r3
        BLTZ    .Lmath_shl1_carry
        ADD     r0, r4, r4
        JMP8    .Lmath_shl1_store
.Lmath_shl1_carry:
        ADD     r0, r4, r4
        ORI     r0, 1
.Lmath_shl1_store:
#else
        MOV     r0, r4
        FSL1    r0, r3
#endif
        ST     r0, [r1 + 0]
        MOV     r3, r4
        ADDI    r1, 2
        ADDI    r2, -1
        MOV     r0, r2
        BNEZ    .Lmath_shl1_loop
.Lmath_shl1_done:
        RESTORE_R4
        MATH_RETURN
        .size __riscc_math_shift_left_one, . - __riscc_math_shift_left_one

        FUNCTION __riscc_math_shift_left_two
        SAVE_R4
#ifdef __RISCC_NANO__
        ST     r5, [r7 - 2]
#endif
        LDI     r3, 0                   /* previous unmodified lower limb */
        MOV     r0, r2
        BEQZ    .Lmath_shl2_done
.Lmath_shl2_loop:
        LD     r4, [r1 + 0]
#ifdef __RISCC_NANO__
        ADD     r5, r4, r4
        ADD     r5, r5, r5
        MOV     r0, r3
        BGEZ    .Lmath_shl2_bit15_done
        ORI     r5, 2
.Lmath_shl2_bit15_done:
        ADD     r3, r3, r3
        MOV     r0, r3
        BGEZ    .Lmath_shl2_bit14_done
        ORI     r5, 1
.Lmath_shl2_bit14_done:
        ST     r5, [r1 + 0]
#else
        MOV     r0, r4
        FSL1    r0, r3
        ADD     r3, r3, r3
        FSL1    r0, r3
        ST     r0, [r1 + 0]
#endif
        MOV     r3, r4
        ADDI    r1, 2
        ADDI    r2, -1
        MOV     r0, r2
        BNEZ    .Lmath_shl2_loop
.Lmath_shl2_done:
#ifdef __RISCC_NANO__
        LD     r5, [r7 - 2]
#endif
        RESTORE_R4
        MATH_RETURN
        .size __riscc_math_shift_left_two, . - __riscc_math_shift_left_two

        FUNCTION __riscc_math_shift_right_one
        SAVE_R4
#ifdef __RISCC_NANO__
        ST     r5, [r7 - 2]
        LUI     r5, 128
#endif
        MOV     r0, r2
        BEQZ    .Lmath_shr1_done
        ADD     r2, r2, r2             /* word count to byte offset */
        ADD     r1, r1, r2             /* one word beyond the high limb */
        LDI     r3, 0                   /* previous unmodified upper limb */
.Lmath_shr1_loop:
        ADDI    r1, -2
        LD     r4, [r1 + 0]
#ifdef __RISCC_NANO__
        MOV     r0, r3
        ANDI    r0, 1
        BEQZ    .Lmath_shr1_no_carry
        SRLI    r0, r4, 1
        OR      r0, r0, r5
        JMP8    .Lmath_shr1_store
.Lmath_shr1_no_carry:
        SRLI    r0, r4, 1
.Lmath_shr1_store:
#else
        MOV     r0, r4
        FSR1    r0, r3
#endif
        ST     r0, [r1 + 0]
        MOV     r3, r4
        ADDI    r2, -2
        MOV     r0, r2
        BNEZ    .Lmath_shr1_loop
.Lmath_shr1_done:
#ifdef __RISCC_NANO__
        LD     r5, [r7 - 2]
#endif
        RESTORE_R4
        MATH_RETURN
        .size __riscc_math_shift_right_one, . - __riscc_math_shift_right_one

/*
 * Integer multiply helpers.
 *
 * Full has a native low-half multiply, so __mulhi3 is just the instruction.
 * The other profiles use a branchless shift/add loop: turning the multiplier
 * bit into an all-zero/all-one mask avoids an unpredictable branch per bit.
 *
 * __mulsi3 keeps the two 32-bit values in r1:r2 and r3:r4.  On Full, the
 * three cross products only need their low halves; a byte-decomposed product
 * supplies the otherwise unavailable unsigned high half of r1*r3.
 */

#ifdef __RISCC_NANO__
#define MUL_RETURN RET r6
#else
#define MUL_RETURN RETS
#endif

        .macro FUNCTION name
        .section .text.\name,"ax",@progbits
        .p2align 1
        .global \name
        .hidden \name
        .type \name,@function
\name:
        .endm

/*
 * Low 64 bits of a 64-by-64 product.
 *
 * The multiplier is copied from its stack argument into fixed leaf scratch.
 * The loop stops when its remaining high bits are zero, which is particularly
 * useful for the 53-bit significands passed by the binary64 runtime.
 */

        FUNCTION __muldi3
        STW     r5, [r7 - 2]
        STW     r6, [r7 - 4]

        LDI     r0, 0
        STW     r0, [r7 - 6]            /* result, low to high */
        STW     r0, [r7 - 8]
        STW     r0, [r7 - 10]
        STW     r0, [r7 - 12]

        LDW     r5, [r7 + 0]
        STW     r5, [r7 - 14]           /* multiplier, low to high */
        OR      r0, r0, r5
        LDW     r5, [r7 + 2]
        STW     r5, [r7 - 16]
        OR      r0, r0, r5
        LDW     r5, [r7 + 4]
        STW     r5, [r7 - 18]
        OR      r0, r0, r5
        LDW     r5, [r7 + 6]
        STW     r5, [r7 - 20]
        OR      r0, r0, r5
        BEQZ    .Lmuldi_done

.Lmuldi_loop:
        LDW     r0, [r7 - 14]
        ANDI    r0, 1
        BEQZ    .Lmuldi_no_add

        LDW     r5, [r7 - 6]
        MOV     r0, r5
        ADD     r5, r5, r1
        SLTU    r6, r5, r0
        STW     r5, [r7 - 6]

        LDW     r5, [r7 - 8]
        MOV     r0, r5
        ADD     r5, r5, r6
        SLTU    r0, r5, r0
        STW     r0, [r7 - 22]
        MOV     r0, r5
        ADD     r5, r5, r2
        SLTU    r6, r5, r0
        LDW     r0, [r7 - 22]
        OR      r6, r6, r0
        STW     r5, [r7 - 8]

        LDW     r5, [r7 - 10]
        MOV     r0, r5
        ADD     r5, r5, r6
        SLTU    r0, r5, r0
        STW     r0, [r7 - 22]
        MOV     r0, r5
        ADD     r5, r5, r3
        SLTU    r6, r5, r0
        LDW     r0, [r7 - 22]
        OR      r6, r6, r0
        STW     r5, [r7 - 10]

        LDW     r5, [r7 - 12]
        ADD     r5, r5, r6
        ADD     r5, r5, r4
        STW     r5, [r7 - 12]

.Lmuldi_no_add:
#ifdef __RISCC_NANO__
        LUI     r0, 128
        SLTU    r0, r3, r0
        XORI    r0, 1
        ADD     r4, r4, r4
        OR      r4, r4, r0
        LUI     r0, 128
        SLTU    r0, r2, r0
        XORI    r0, 1
        ADD     r3, r3, r3
        OR      r3, r3, r0
        LUI     r0, 128
        SLTU    r0, r1, r0
        XORI    r0, 1
        ADD     r2, r2, r2
        OR      r2, r2, r0
        ADD     r1, r1, r1
#else
        FSL1    r4, r4, r3
        FSL1    r3, r3, r2
        FSL1    r2, r2, r1
        ADD     r1, r1, r1
#endif

        /* Shift the saved multiplier right by one. */
        LDW     r5, [r7 - 14]
        LDW     r6, [r7 - 16]
#ifdef __RISCC_NANO__
        MOV     r0, r6
        ANDI    r0, 1
        SHRI    r5, r5, 1
        BEQZ    .Lmuldi_shr0_done
        LUI     r0, 128
        OR      r5, r5, r0
.Lmuldi_shr0_done:
#else
        FSR1    r5, r5, r6
#endif
        STW     r5, [r7 - 14]

        LDW     r5, [r7 - 16]
        LDW     r6, [r7 - 18]
#ifdef __RISCC_NANO__
        MOV     r0, r6
        ANDI    r0, 1
        SHRI    r5, r5, 1
        BEQZ    .Lmuldi_shr1_done
        LUI     r0, 128
        OR      r5, r5, r0
.Lmuldi_shr1_done:
#else
        FSR1    r5, r5, r6
#endif
        STW     r5, [r7 - 16]

        LDW     r5, [r7 - 18]
        LDW     r6, [r7 - 20]
#ifdef __RISCC_NANO__
        MOV     r0, r6
        ANDI    r0, 1
        SHRI    r5, r5, 1
        BEQZ    .Lmuldi_shr2_done
        LUI     r0, 128
        OR      r5, r5, r0
.Lmuldi_shr2_done:
#else
        FSR1    r5, r5, r6
#endif
        STW     r5, [r7 - 18]

        LDW     r5, [r7 - 20]
        SHRI    r5, r5, 1
        STW     r5, [r7 - 20]

        LDW     r0, [r7 - 14]
        LDW     r5, [r7 - 16]
        OR      r0, r0, r5
        LDW     r5, [r7 - 18]
        OR      r0, r0, r5
        LDW     r5, [r7 - 20]
        OR      r0, r0, r5
        BNEZ    .Lmuldi_loop

.Lmuldi_done:
        LDW     r1, [r7 - 6]
        LDW     r2, [r7 - 8]
        LDW     r3, [r7 - 10]
        LDW     r4, [r7 - 12]
        LDW     r6, [r7 - 4]
        LDW     r5, [r7 - 2]
        MUL_RETURN
        .size __muldi3, . - __muldi3

        FUNCTION __mulhi3
#ifdef __RISCC_FULL__
        MUL     r1, r1, r2
        MUL_RETURN
#else
        LDI     r3, 0
.Lmulhi_loop:
        MOV     r0, r2
        ANDI    r0, 1
        LDI     r4, 0
        SUB     r0, r4, r0
        AND     r0, r0, r1
        ADD     r3, r3, r0
        ADD     r1, r1, r1
        SHRI    r2, r2, 1
        MOV     r0, r2
        BNEZ    .Lmulhi_loop
        MOV     r1, r3
        MUL_RETURN
#endif
        .size __mulhi3, . - __mulhi3

#ifdef __RISCC_FULL__
        FUNCTION __mulsi3
        /* Preserve callee-saved GPRs in call-clobbered cache registers. */
        MTS     s5, r5
        MTS     s6, r6

        /* Cross terms contribute directly to result word one. */
        MUL     r5, r1, r4
        MUL     r6, r2, r3
        MTS     s3, r5
        MTS     s4, r6

        /*
         * Unsigned r1*r3 using four 8x8 products:
         *   p00 + (p01+p10)<<8 + p11<<16.
         * Each byte product fits completely in MUL's low half.
         */
        MOV     r5, r1
        ANDI    r1, 255
        SHRI    r5, r5, 8
        MOV     r6, r3
        ANDI    r3, 255
        SHRI    r6, r6, 8
        MUL     r0, r1, r3              /* p00 */
        MUL     r1, r1, r6              /* p01 */
        MUL     r2, r5, r3              /* p10 */
        MUL     r3, r5, r6              /* p11 */

        SHRI    r4, r1, 8
        ADD     r3, r3, r4
        SHRI    r4, r2, 8
        ADD     r3, r3, r4
        SHRI    r4, r0, 8
        MOV     r5, r1
        ANDI    r5, 255
        ADD     r4, r4, r5
        MOV     r5, r2
        ANDI    r5, 255
        ADD     r4, r4, r5
        SHRI    r5, r4, 8
        ADD     r2, r3, r5
        MFS     r5, s3
        ADD     r2, r2, r5
        MFS     r5, s4
        ADD     r2, r2, r5
        SHLI    r4, r4, 8
        ANDI    r0, 255
        OR      r1, r0, r4

        MFS     r6, s6
        MFS     r5, s5
        MUL_RETURN
        .size __mulsi3, . - __mulsi3
#else
        FUNCTION __mulsi3
#ifdef __RISCC_NANO__
        STW     r5, [r7 - 2]
        STW     r6, [r7 - 4]
#else
        MTS     s5, r5
        MTS     s6, r6
#endif
        LDI     r5, 0                   /* result low */
        LDI     r6, 0                   /* result high */
        OR      r0, r3, r4
        BEQZ    .Lmulsi_done

.Lmulsi_loop:
        MOV     r0, r3
        ANDI    r0, 1
        BEQZ    .Lmulsi_no_add
        MOV     r0, r5
        ADD     r5, r5, r1
        SLTU    r0, r5, r0
        ADD     r6, r6, r2
        ADD     r6, r6, r0

.Lmulsi_no_add:
#ifdef __RISCC_NANO__
        LUI     r0, 128
        SLTU    r0, r1, r0
        XORI    r0, 1
        ADD     r2, r2, r2
        OR      r2, r2, r0
        ADD     r1, r1, r1

        MOV     r0, r4
        ANDI    r0, 1
        SHRI    r3, r3, 1
        BEQZ    .Lmulsi_no_shift_carry
        LUI     r0, 128
        OR      r3, r3, r0
.Lmulsi_no_shift_carry:
        SHRI    r4, r4, 1
#else
        FSL1    r2, r2, r1
        ADD     r1, r1, r1
        FSR1    r3, r3, r4
        SHRI    r4, r4, 1
#endif
        OR      r0, r3, r4
        BNEZ    .Lmulsi_loop

.Lmulsi_done:
        MOV     r1, r5
        MOV     r2, r6
#ifdef __RISCC_NANO__
        LDW     r6, [r7 - 4]
        LDW     r5, [r7 - 2]
#else
        MFS     r6, s6
        MFS     r5, s5
#endif
        MUL_RETURN
        .size __mulsi3, . - __mulsi3
#endif

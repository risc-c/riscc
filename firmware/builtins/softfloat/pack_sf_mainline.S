/*
 * Pack a mainline-profile binary32 result.
 *
 * Inputs:
 *   r2:r1 = normalized significand with guard/round/sticky in bits 2:0
 *   r3    = sign (0 or 0x8000)
 *   r4    = signed biased exponent
 * Result:
 *   r2:r1 = IEEE-754 binary32, round-to-nearest/ties-to-even
 *
 * Arithmetic entry points tail-call this helper, so S7 still contains their
 * caller's return address.  Keeping gradual underflow and rounding here avoids
 * duplicating the least common path in add, multiply, and divide.
 */

        .section .text.__riscc_pack_sf,"ax",@progbits
        .p2align 1
        .global __riscc_pack_sf
        .hidden __riscc_pack_sf
        .type __riscc_pack_sf,@function
__riscc_pack_sf:
        MTS     s3, r5
        MTS     s4, r6

        /* Exponents at zero or below become gradual underflow. */
        MOV     r0, r4
        BLTZ    .Lunderflow
        BNEZ    .Lround
.Lunderflow:
        LDI     r5, 1
        SUB     r5, r5, r4             /* shift = 1 - exponent */
        LDI     r6, 32
        SLTU    r0, r5, r6
        BNEZ    .Lunderflow_loop_test
        OR      r0, r1, r2
        LDI     r1, 0
        LDI     r2, 0
        BEQZ    .Lunderflow_shifted
        LDI     r1, 1
        JMP8    .Lunderflow_shifted

.Lunderflow_loop:
        MOV     r6, r1
        ANDI    r6, 1
        FSR1    r1, r1, r2
        SHRI    r2, r2, 1
        OR      r1, r1, r6
        ADDI    r5, -1
.Lunderflow_loop_test:
        MOV     r0, r5
        BNEZ    .Lunderflow_loop
.Lunderflow_shifted:
        LDI     r4, 1

.Lround:
        /*
         * Increment by one retained ulp when GRS > 100, or for the
         * exactly-halfway case when the retained significand is odd.
         */
        MOV     r5, r1
        ANDI    r5, 7
        LDI     r6, 4
        SLTU    r0, r6, r5
        BNEZ    .Lround_up
        SUB     r0, r5, r6
        BNEZ    .Lrounded
        MOV     r0, r1
        ANDI    r0, 8
        BEQZ    .Lrounded
.Lround_up:
        MOV     r5, r1
        ADDI    r1, 8
        SLTU    r0, r1, r5
        ADD     r2, r2, r0

.Lrounded:
        /* 1.111... rounded to 10.000... advances the exponent. */
        LUI     r5, 8
        AND     r0, r2, r5
        BEQZ    .Lrange
        LDI     r1, 0
        LUI     r2, 4
        ADDI    r4, 1

.Lrange:
        LDI     r5, 255
        SLTU    r0, r4, r5
        BNEZ    .Lsubnormal_test
        LDI     r1, 0
        LDI16   r2, 0x7f80
        OR      r2, r2, r3
        JMP8    .Lreturn

.Lsubnormal_test:
        CMPI    r4, 1
        BNEZ    .Lpack
        LUI     r5, 4
        AND     r0, r2, r5
        BNEZ    .Lpack
        LDI     r4, 0

.Lpack:
        /* Low result word: (extended >> 3). */
#ifdef __RISCC_MIN__
        .rept 3
        FSR1    r1, r1, r2
        SHRI    r2, r2, 1
        .endr
#else
        MOV     r5, r2
        SHLI    r5, r5, 8
        SHLI    r5, r5, 5
        SHRI    r1, r1, 3
        OR      r1, r1, r5
        SHRI    r2, r2, 3
#endif

        /* High result word: sign | exponent<<7 | fraction[22:16]. */
        MOV     r5, r4
#ifdef __RISCC_MIN__
        .rept 7
        ADD     r5, r5, r5
        .endr
#else
        SHLI    r5, r5, 7
#endif
        ANDI    r2, 0x7f
        OR      r2, r2, r5
        OR      r2, r2, r3

.Lreturn:
        MFS     r6, s4
        MFS     r5, s3
        RETS
        .size __riscc_pack_sf, . - __riscc_pack_sf

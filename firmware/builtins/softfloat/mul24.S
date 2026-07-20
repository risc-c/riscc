/*
 * Full-profile unsigned 24x24 -> 48 significand multiply.
 *
 * MULH is an optional extension and is not enabled by any standard profile.
 * This routine therefore decomposes the two normalized significands into
 * bytes, uses Full's low-half MUL for the nine byte products, and accumulates
 * them into three 16-bit result limbs.
 *
 * Arguments: r1:r2, r3:r4 (high limbs contain only eight significant bits)
 * Result:    r1:r2:r3
 */

#ifdef __RISCC_FULL__
        .section .text.__riscc_umul24x24,"ax",@progbits
        .p2align 1
        .global __riscc_umul24x24
        .hidden __riscc_umul24x24
        .type __riscc_umul24x24,@function
__riscc_umul24x24:
        /*
         * r5/r6 become byte digits. This leaf uses scratch immediately below
         * the incoming r7; the supplied IRQ wrapper never consumes the
         * interrupted stack.
         */
        STW     r5, [r7 - 2]
        STW     r6, [r7 - 4]

        /*
         * Byte layout after extraction:
         *   r1=a0 r2=a1 r3=a2, r4=b0 r5=b1 r6=b2.
         */
        MOV     r0, r2
        ANDI    r0, 255
        MTS     s6, r0
        MOV     r2, r1
        SHRI    r2, r2, 8
        ANDI    r1, 255
        MOV     r5, r3
        SHRI    r5, r5, 8
        ANDI    r3, 255
        MOV     r6, r4
        ANDI    r6, 255
        MOV     r4, r3
        MFS     r3, s6

        /* Byte column zero: a0*b0 is the initial low result word. */
        MUL     r0, r1, r4
        MTS     s3, r0

        /*
         * Byte column one: sum a0*b1 + a1*b0, then add it at bit
         * position eight.  s4 temporarily holds the low sum and s5 its
         * carry before becoming result words one and two.
         */
        MUL     r0, r1, r5
        MTS     s4, r0
        MUL     r0, r2, r4
        MTS     s6, r3                  /* free r3 while preserving a2 */
        MFS     r3, s4
        ADD     r0, r3, r0
        SLTU    r3, r0, r3             /* carry from the 16-bit sum */
        MTS     s4, r0
        MTS     s5, r3

        SHLI    r0, r0, 8
        MFS     r3, s3
        ADD     r0, r3, r0
        SLTU    r3, r0, r3             /* carry into result word one */
        MTS     s3, r0
        MFS     r0, s4
        SHRI    r0, r0, 8
        MTS     s4, r3
        MFS     r3, s5
        SHLI    r3, r3, 8
        ADD     r0, r0, r3
        MFS     r3, s4
        ADD     r0, r0, r3
        MTS     s4, r0
        LDI     r0, 0
        MTS     s5, r0
        MFS     r3, s6

        /*
         * Byte column two maps directly to result word one.  Accumulate
         * its three products and increment word two after each overflow.
         */
        MUL     r0, r1, r6
        MTS     s6, r3
        MFS     r3, s4
        ADD     r0, r3, r0
        SLTU    r3, r0, r3
        MTS     s4, r0
        MFS     r0, s5
        ADD     r0, r0, r3
        MTS     s5, r0
        MFS     r3, s6

        MUL     r0, r2, r5
        MTS     s6, r3
        MFS     r3, s4
        ADD     r0, r3, r0
        SLTU    r3, r0, r3
        MTS     s4, r0
        MFS     r0, s5
        ADD     r0, r0, r3
        MTS     s5, r0
        MFS     r3, s6

        MUL     r0, r3, r4
        MTS     s6, r3
        MFS     r3, s4
        ADD     r0, r3, r0
        SLTU    r3, r0, r3
        MTS     s4, r0
        MFS     r0, s5
        ADD     r0, r0, r3
        MTS     s5, r0
        MFS     r3, s6

        /*
         * Byte column three is shifted eight within result word one:
         * a1*b2 + a2*b1.
         */
        MUL     r0, r2, r6
        MTS     s6, r0
        MUL     r0, r3, r5
        MOV     r4, r0                  /* b0 is dead; r4 is now scratch */
        MFS     r0, s6
        ADD     r4, r0, r4
        SLTU    r0, r4, r0             /* column-sum carry */
        MTS     s6, r4
        SHLI    r4, r4, 8
        MFS     r1, s4                 /* a0 is dead; r1 is now scratch */
        ADD     r4, r1, r4
        SLTU    r1, r4, r1             /* carry into result word two */
        MTS     s4, r4
        SHLI    r0, r0, 8
        MFS     r4, s6
        SHRI    r4, r4, 8
        ADD     r0, r0, r4
        ADD     r0, r0, r1
        MFS     r1, s5
        ADD     r0, r0, r1
        MTS     s5, r0

        /* Byte column four: a2*b2 maps directly to result word two. */
        MUL     r0, r3, r6
        MFS     r1, s5
        ADD     r3, r1, r0
        MFS     r1, s3
        MFS     r2, s4

        LDW     r6, [r7 - 4]
        LDW     r5, [r7 - 2]
        RETS
        .size __riscc_umul24x24, . - __riscc_umul24x24
#endif

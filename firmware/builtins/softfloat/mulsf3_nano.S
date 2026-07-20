/*
 * Compact binary32 multiply for the Nano profile.
 *
 * Nano deliberately uses the small-controller floating-point contract:
 * finite normal inputs, round-to-nearest/ties-to-even, and signed-zero
 * flush for exponent-zero inputs.  NaNs, infinities, gradual underflow, and
 * exponent overflow are outside this entry point's contract.
 *
 * ABI:
 *   left   = r2:r1
 *   right  = r4:r3
 *   result = r2:r1
 *
 * Nano has no funnel instructions.  The multiply therefore keeps its 49-bit
 * accumulator in registers and implements cross-word shifts with short
 * conditional sequences.  Two rounds are unrolled per loop: this removes
 * half the loop-control work without duplicating the comparatively large
 * Nano shift sequence four times.
 */

        .macro NANO_FSL1 d, high, low
        ADD     \d, \high, \high
        MOV     r0, \low
        BGEZ    .Lfsl_done\@
        ORI     \d, 1
.Lfsl_done\@:
        .endm

        /*
         * One round of the combined accumulator/multiplier:
         *   carry:r3:r2:r1 = 0:0:right_significand.
         *
         * r4:r5 is the left significand and r6 is 0x8000.  Scratch word -4
         * temporarily preserves the 49th carry while r0 moves the two
         * cross-word bits.
         */
        .macro NANO_MUL_ROUND
        MOV     r0, r1
        ANDI    r0, 1
        BEQZ    .Lmul_shift\@

        ADD     r2, r2, r4
        SLTU    r0, r2, r4
        ADD     r3, r3, r0
        SLTU    r0, r3, r0
        ADD     r3, r3, r5
        BNEZ    .Lmul_shift\@
        SLTU    r0, r3, r5

.Lmul_shift\@:
        STW     r0, [r7 - 4]

        MOV     r0, r2
        ANDI    r0, 1
        SHRI    r1, r1, 1
        BEQZ    .Lmul_shift_low_done\@
        OR      r1, r1, r6
.Lmul_shift_low_done\@:

        MOV     r0, r3
        ANDI    r0, 1
        SHRI    r2, r2, 1
        BEQZ    .Lmul_shift_middle_done\@
        OR      r2, r2, r6
.Lmul_shift_middle_done\@:

        LDW     r0, [r7 - 4]
        SHRI    r3, r3, 1
        BEQZ    .Lmul_shift_high_done\@
        OR      r3, r3, r6
.Lmul_shift_high_done\@:
        .endm

        .section .text.__mulsf3,"ax",@progbits
        .p2align 1
        .global __mulsf3
        .hidden __mulsf3
        .type __mulsf3,@function
__mulsf3:
        STW     r5, [r7 - 12]
        STW     r6, [r7 - 10]

        XOR     r0, r2, r4
        STW     r0, [r7 - 8]

        /* Exponent-zero operands, including subnormals, flush to zero. */
        LDI16   r5, 0x7f80
        AND     r0, r2, r5
        BNEZ    .Lcheck_right

.Lzero:
        LDI     r1, 0
        LDI     r2, 0
        LDW     r0, [r7 - 8]
        BGEZ    .Lzero_return
        LUI     r2, 0x80
.Lzero_return:
        LDW     r6, [r7 - 10]
        LDW     r5, [r7 - 12]
        RET     r6

.Lcheck_right:
        AND     r6, r4, r5
        MOV     r5, r0
        MOV     r0, r6
        BEQZ    .Lzero

        /*
         * Save (left_exp + right_exp - 128) << 7.  The normalized product's
         * high byte later supplies the remaining bias bit.
         */
        ADD     r6, r6, r5
        LUI     r5, 0x40
        SUB     r6, r6, r5
        STW     r6, [r7 - 6]

        /* Restore implicit leading ones. */
        ANDI    r2, 0x7f
        ORI     r2, 0x80
        ANDI    r4, 0x7f
        ORI     r4, 0x80
        MOV     r6, r4

        /*
         * Align the left 24-bit significand at bits 24..47.  Two shifts per
         * loop are a compact compromise between code size and loop overhead.
         */
        LDI     r5, 4
.Lalign:
        .rept 2
        NANO_FSL1 r2, r2, r1
        ADD     r1, r1, r1
        .endr
        ADDI    r5, -1
        MOV     r0, r5
        BNEZ    .Lalign
        MOV     r4, r1
        MOV     r5, r2

        /* Initialize the combined product/multiplier and sign-bit mask. */
        MOV     r1, r3
        MOV     r2, r6
        LDI     r3, 0
        LUI     r6, 0x80
        LDI     r0, 12
        STW     r0, [r7 - 2]

.Lmultiply:
        .rept 2
        NANO_MUL_ROUND
        .endr
        LDW     r0, [r7 - 2]
        ADDI    r0, -1
        STW     r0, [r7 - 2]
        BNEZ    .Lmultiply

        /*
         * Normalize to a 24-bit significand.  Preserve all discarded bits:
         * r4 holds the high discarded fragment and r1 the low sticky part.
         */
        MOV     r0, r3
        BLTZ    .Lproduct_bit47

        MOV     r4, r2
        ANDI    r4, 0x7f
        LDI     r5, 7
        LDI     r0, 0x40
        STW     r0, [r7 - 2]
        JMP8    .Lnormalize

.Lproduct_bit47:
        MOV     r4, r2
        ANDI    r4, 0xff
        LDW     r5, [r7 - 6]
        LDI     r0, 0x80
        ADD     r5, r5, r0
        STW     r5, [r7 - 6]
        LDI     r5, 8
        STW     r0, [r7 - 2]

.Lnormalize:
        MOV     r0, r3
        ANDI    r0, 1
        SHRI    r2, r2, 1
        BEQZ    .Lnormalize_no_carry
        OR      r2, r2, r6
.Lnormalize_no_carry:
        SHRI    r3, r3, 1
        ADDI    r5, -1
        MOV     r0, r5
        BNEZ    .Lnormalize

        /* Round to nearest, ties to even. */
        LDW     r6, [r7 - 2]
        AND     r0, r4, r6
        BEQZ    .Lpack
        ADDI    r6, -1
        AND     r0, r4, r6
        BNEZ    .Lround_up
        MOV     r0, r1
        BNEZ    .Lround_up
        MOV     r0, r2
        ANDI    r0, 1
        BEQZ    .Lpack

.Lround_up:
        ADDI    r2, 1
        MOV     r0, r2
        BNEZ    .Lpack
        ADDI    r3, 1

.Lpack:
        MOV     r1, r2
        LDW     r5, [r7 - 6]
        ADD     r2, r5, r3
        LDW     r0, [r7 - 8]
        BGEZ    .Lreturn
        LUI     r0, 0x80
        OR      r2, r2, r0
        JMP8    .Lreturn

.Lreturn:
        LDW     r6, [r7 - 10]
        LDW     r5, [r7 - 12]
        RET     r6
        .size __mulsf3, . - __mulsf3

/*
 * Full IEEE-754 binary32 multiply for all mainline profiles.
 *
 * Min/Sys keep the 48-bit shift/add product entirely in registers. Full calls
 * the native-byte-product helper, then rejoins the same normalization and
 * packing path. Subnormal inputs are normalized before either multiply.
 */

        .macro EXTRACT_EXP reg
#ifdef __RISCC_MIN__
        .rept 7
        SRLI    \reg, \reg, 1
        .endr
#else
        SRLI    \reg, \reg, 7
#endif
        .endm

        .macro TAIL_PACK
#ifdef __RISCC_MIN__
        LI      r0, __riscc_pack_sf
        JALR    s0, r0
#else
        JMPL    __riscc_pack_sf
#endif
        .endm

        .macro ABI_RETURN
        LD      r0, [r7 + 8]
        MTS     s6, r0
        LD      r0, [r7 + 6]
        MTS     s5, r0
        LD      r6, [r7 + 4]
        LD      r5, [r7 + 2]
        LD      r4, [r7 + 0]
        ADDI    r7, 48
        RETS
        .endm

        .macro MUL_ROUND
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
        FSR1    r1, r2
        FSR1    r2, r3
        SRLI    r3, r3, 1
        BEQZ    .Lmul_shift_done\@
        OR      r3, r3, r6
.Lmul_shift_done\@:
        .endm

        .section .text.__mulsf3,"ax",@progbits
        .p2align 1
        .global __mulsf3
        .hidden __mulsf3
        .type __mulsf3,@function
__mulsf3:
        /*
         * Reserve this frame's low words for __riscc_umul24x24.  The Full
         * profile calls that leaf without moving r7, so its private scratch
         * must not overlap this routine's live words.
         */
        ADDI    r7, -48
        ST      r4, [r7 + 0]
        LD      r3, [r7 + 48]           /* second operand */
        LD      r4, [r7 + 50]
        ST      r5, [r7 + 2]
        ST      r6, [r7 + 4]
        MFS     r0, s5
        ST      r0, [r7 + 6]
        MFS     r0, s6
        ST      r0, [r7 + 8]

        ST     r5, [r7 + 34]
        ST     r6, [r7 + 36]
        XOR     r0, r2, r4
        LUI     r5, 0x80
        AND     r0, r0, r5
        ST     r0, [r7 + 38]          /* result sign */

        /* Extract both exponent fields. */
        MOV     r5, r2
        MOV     r6, r4
        EXTRACT_EXP r5
        EXTRACT_EXP r6
        ANDI    r5, 255
        ANDI    r6, 255

        /* IEEE special operands. */
        LDI     r0, 255
        SUB     r0, r5, r0
        BNEZ    .Lcheck_right_special
        MOV     r0, r2
        ANDI    r0, 0x7f
        OR      r0, r0, r1
        BNEZ    .Lquiet_left
        LDI     r0, 255
        SUB     r0, r6, r0
        BNEZ    .Lleft_infinity
        MOV     r0, r4
        ANDI    r0, 0x7f
        OR      r0, r0, r3
        BNEZ    .Lquiet_right
.Lleft_infinity:
        MOV     r0, r4
        ANDI    r0, 0x7f
        OR      r0, r0, r3
        OR      r0, r0, r6
        BEQZ    .Lqnan
        JMP8    .Linfinity

.Lcheck_right_special:
        LDI     r0, 255
        SUB     r0, r6, r0
        BNEZ    .Lfinite
        MOV     r0, r4
        ANDI    r0, 0x7f
        OR      r0, r0, r3
        BNEZ    .Lquiet_right
        MOV     r0, r2
        ANDI    r0, 0x7f
        OR      r0, r0, r1
        OR      r0, r0, r5
        BEQZ    .Lqnan
        JMP8    .Linfinity

.Lquiet_left:
        ORI     r2, 0x40
        JMP8    .Lspecial_return
.Lquiet_right:
        MOV     r1, r3
        MOV     r2, r4
        ORI     r2, 0x40
        JMP8    .Lspecial_return
.Lqnan:
        LDI     r1, 0
        LI      r2, 0x7fc0
        JMP8    .Lspecial_return
.Linfinity:
        LDI     r1, 0
        LI      r2, 0x7f80
        LD     r0, [r7 + 38]
        OR      r2, r2, r0

.Lspecial_return:
        ABI_RETURN

.Lfinite:
        /* Restore significands, including implicit bits for normals. */
        ANDI    r2, 0x7f
        MOV     r0, r5
        BEQZ    .Lleft_no_implicit
        ORI     r2, 0x80
.Lleft_no_implicit:
        ANDI    r4, 0x7f
        MOV     r0, r6
        BEQZ    .Lright_no_implicit
        ORI     r4, 0x80
.Lright_no_implicit:
        OR      r0, r1, r2
        BEQZ    .Lzero
        OR      r0, r3, r4
        BEQZ    .Lzero

        /* Effective exponent fields: subnormals use one before normalize. */
        MOV     r0, r5
        BNEZ    .Lleft_effective
        LDI     r5, 1
.Lleft_effective:
        MOV     r0, r6
        BNEZ    .Lright_effective
        LDI     r6, 1
.Lright_effective:
        ADD     r5, r5, r6
        ADDI    r5, -127

.Lnormalize_left:
        MOV     r0, r2
        ANDI    r0, 0x80
        BNEZ    .Lnormalize_right
        FSL1    r2, r1
        ADD     r1, r1, r1
        ADDI    r5, -1
        JMP8    .Lnormalize_left

.Lnormalize_right:
        MOV     r0, r4
        ANDI    r0, 0x80
        BNEZ    .Lnormalized
        FSL1    r4, r3
        ADD     r3, r3, r3
        ADDI    r5, -1
        JMP8    .Lnormalize_right

.Lnormalized:
        ST     r5, [r7 + 40]          /* signed biased result exponent */
#ifdef __RISCC_FULL__
        /*
         * The helper returns the exact 48-bit product in r3:r2:r1. Preserve
         * the public link because this is the only non-tail call.
         */
        MFS     r0, s7
        ST     r0, [r7 + 42]
        JALL    s7, __riscc_umul24x24
        LD     r0, [r7 + 42]
        MTS     s7, r0
#else
        MOV     r6, r4                 /* preserve multiplier high */

        /* Align multiplicand at bits 24..47. */
#ifdef __RISCC_MIN__
        .rept 8
        FSL1    r2, r1
        ADD     r1, r1, r1
        .endr
#else
        SLLI    r2, r2, 8
        SRLI    r0, r1, 8
        OR      r2, r2, r0
        SLLI    r1, r1, 8
#endif
        MOV     r4, r1
        MOV     r5, r2

        /* Combined product/multiplier: carry:r3:r2:r1. */
        MOV     r1, r3
        MOV     r2, r6
        LDI     r3, 0
        LUI     r6, 0x80
        LDI     r0, 12
        ST     r0, [r7 + 42]
.Lmultiply:
        .rept 2
        MUL_ROUND
        .endr
        LD     r0, [r7 + 42]
        ADDI    r0, -1
        ST     r0, [r7 + 42]
        BNEZ    .Lmultiply
#endif

        /*
         * Convert the 48-bit product to the packer's 27-bit extended
         * significand.  Everything below it is folded into sticky bit zero.
         */
        MOV     r4, r2
        MOV     r5, r1
        MOV     r0, r3
        BLTZ    .Lproduct_bit47
        ANDI    r4, 0x0f
        LDI     r6, 4
        JMP8    .Lproduct_shift
.Lproduct_bit47:
        ANDI    r4, 0x1f
        LDI     r6, 5
        LD     r0, [r7 + 40]
        ADDI    r0, 1
        ST     r0, [r7 + 40]
.Lproduct_shift:
        OR      r4, r4, r5
.Lproduct_shift_loop:
        FSR1    r2, r3
        SRLI    r3, r3, 1
        ADDI    r6, -1
        MOV     r0, r6
        BNEZ    .Lproduct_shift_loop
        MOV     r0, r4
        BEQZ    .Lproduct_exact
        ORI     r2, 1
.Lproduct_exact:
        MOV     r1, r2
        MOV     r2, r3
        LD     r3, [r7 + 38]
        LD     r4, [r7 + 40]
        TAIL_PACK                      /* tail call */

.Lzero:
        LDI     r1, 0
        LD     r2, [r7 + 38]
.Lreturn:
        ABI_RETURN
        .size __mulsf3, . - __mulsf3

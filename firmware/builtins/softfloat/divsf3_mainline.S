/*
 * Full IEEE-754 binary32 divide for the Min/Sys/Full profiles.
 *
 * Normalized 24-bit significands feed a 26-round restoring divide.  The
 * quotient is produced directly with guard/round/sticky bits for the shared
 * mainline packer.
 */

        .macro EXTRACT_EXP reg
#ifdef __RISCC_MIN__
        .rept 7
        SHRI    \reg, \reg, 1
        .endr
#else
        SHRI    \reg, \reg, 7
#endif
        .endm

        .macro TAIL_PACK
#ifdef __RISCC_MIN__
        LI      r0, code(__riscc_pack_sf)
        JAL     s0, r0
#else
        JAL16   s0, __riscc_pack_sf
#endif
        .endm

        .macro DIV_ROUND
        FSL1    r2, r2, r1
        ADD     r1, r1, r1
        FSL1    r4, r4, r3
        ADD     r3, r3, r3

        SLTU    r0, r4, r6
        BNEZ    .Ldiv_keep\@
        SUB     r0, r4, r6
        BNEZ    .Ldiv_subtract\@
        SLTU    r0, r3, r5
        BNEZ    .Ldiv_keep\@
.Ldiv_subtract\@:
        SLTU    r0, r3, r5
        SUB     r3, r3, r5
        SUB     r4, r4, r6
        SUB     r4, r4, r0
        ORI     r1, 1
.Ldiv_keep\@:
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
        LUI     r5, 0x80
        AND     r0, r0, r5
        STW     r0, [r7 - 6]           /* result sign */

        MOV     r5, r2
        MOV     r6, r4
        EXTRACT_EXP r5
        EXTRACT_EXP r6
        ANDI    r5, 255
        ANDI    r6, 255

        /* IEEE NaN and infinity precedence. */
        LDI     r0, 255
        SUB     r0, r5, r0
        BNEZ    .Lcheck_right_special
        MOV     r0, r2
        ANDI    r0, 0x7f
        OR      r0, r0, r1
        BNEZ    .Lquiet_left
        LDI     r0, 255
        SUB     r0, r6, r0
        BNEZ    .Linfinity
        MOV     r0, r4
        ANDI    r0, 0x7f
        OR      r0, r0, r3
        BNEZ    .Lquiet_right
        JMP8    .Lqnan

.Lcheck_right_special:
        LDI     r0, 255
        SUB     r0, r6, r0
        BNEZ    .Lfinite
        MOV     r0, r4
        ANDI    r0, 0x7f
        OR      r0, r0, r3
        BNEZ    .Lquiet_right
        JMP8    .Lzero

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
        LDI16   r2, 0x7fc0
        JMP8    .Lspecial_return
.Linfinity:
        LDI     r1, 0
        LDI16   r2, 0x7f80
        LDW     r0, [r7 - 6]
        OR      r2, r2, r0
        JMP8    .Lspecial_return
.Lzero:
        LDI     r1, 0
        LDW     r2, [r7 - 6]
.Lspecial_return:
        LDW     r6, [r7 - 8]
        LDW     r5, [r7 - 10]
        RETS

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
        BNEZ    .Lnumerator_nonzero
        OR      r0, r3, r4
        BEQZ    .Lfinite_qnan
        JMP8    .Lfinite_zero
.Lnumerator_nonzero:
        OR      r0, r3, r4
        BNEZ    .Lnonzero_operands
        LDI     r1, 0
        LDI16   r2, 0x7f80
        LDW     r0, [r7 - 6]
        OR      r2, r2, r0
        JMP8    .Lfinite_return
.Lfinite_qnan:
        LDI     r1, 0
        LDI16   r2, 0x7fc0
        JMP8    .Lfinite_return
.Lfinite_zero:
        LDI     r1, 0
        LDW     r2, [r7 - 6]
.Lfinite_return:
        LDW     r6, [r7 - 8]
        LDW     r5, [r7 - 10]
        RETS

.Lnonzero_operands:
        /* Effective exponents use one for subnormal encodings. */
        MOV     r0, r5
        BNEZ    .Lleft_effective
        LDI     r5, 1
.Lleft_effective:
        MOV     r0, r6
        BNEZ    .Lright_effective
        LDI     r6, 1
.Lright_effective:
        SUB     r5, r5, r6
        ADDI    r5, 127

.Lnormalize_left:
        MOV     r0, r2
        ANDI    r0, 0x80
        BNEZ    .Lnormalize_right
        FSL1    r2, r2, r1
        ADD     r1, r1, r1
        ADDI    r5, -1
        JMP8    .Lnormalize_left
.Lnormalize_right:
        MOV     r0, r4
        ANDI    r0, 0x80
        BNEZ    .Lnormalized
        FSL1    r4, r4, r3
        ADD     r3, r3, r3
        ADDI    r5, 1
        JMP8    .Lnormalize_right

.Lnormalized:
        STW     r5, [r7 - 4]
        MOV     r5, r3                 /* divisor low */
        MOV     r6, r4                 /* divisor high */

        /* Choose a remainder in [divisor, 2*divisor). */
        SLTU    r0, r2, r6
        BNEZ    .Lnumerator_less
        SUB     r0, r2, r6
        BNEZ    .Lnumerator_ge
        SLTU    r0, r1, r5
        BNEZ    .Lnumerator_less
.Lnumerator_ge:
        MOV     r3, r1
        MOV     r4, r2
        JMP8    .Linitial_subtract
.Lnumerator_less:
        FSL1    r4, r2, r1
        ADD     r3, r1, r1
        LDW     r0, [r7 - 4]
        ADDI    r0, -1
        STW     r0, [r7 - 4]
.Linitial_subtract:
        SLTU    r0, r3, r5
        SUB     r3, r3, r5
        SUB     r4, r4, r6
        SUB     r4, r4, r0

        LDI     r1, 1
        LDI     r2, 0
        LDI     r0, 13
        STW     r0, [r7 - 2]
.Ldivide:
        .rept 2
        DIV_ROUND
        .endr
        LDW     r0, [r7 - 2]
        ADDI    r0, -1
        STW     r0, [r7 - 2]
        BNEZ    .Ldivide

        OR      r0, r3, r4
        BEQZ    .Lexact
        ORI     r1, 1
.Lexact:
        LDW     r3, [r7 - 6]
        LDW     r4, [r7 - 4]
        LDW     r6, [r7 - 8]
        LDW     r5, [r7 - 10]
        TAIL_PACK                      /* tail call */
        .size __divsf3, . - __divsf3

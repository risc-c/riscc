/*
 * Full IEEE-754 binary32 divide for the Min/Sys/Full profiles.
 *
 * Without MDU, normalized 24-bit significands feed a 26-round restoring
 * divide.  The MDU build instead uses two base-2^16 quotient digits.  Both
 * produce guard/round/sticky bits directly for the shared mainline packer.
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

        .macro DIV_ROUND
        FSL1    r2, r1
        ADD     r1, r1, r1
        FSL1    r4, r3
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

#ifdef __RISCC_MDU__
        /*
         * One base-2^16 Knuth quotient digit.  r6:r5 holds the normalized
         * divisor high:low, r4:r3 holds the incoming partial remainder, and
         * r2 is the next dividend limb.  The quotient digit is kept at -14
         * from r7.  The private S3 link makes one copy serve both digits.
         *
         * DIVU divides the two top partial-remainder limbs by divisor-high.
         * Normalization makes that limb at least 0x8000, so the standard
         * estimate needs at most two corrections.
         */
        .macro MDU_DIV_DIGIT
        MTS     s5, r4
        MTS     s6, r3
        ST     r2, [r7 + 36]           /* preserve appended limb */
        DIVU    r4, r3, r6              /* r4:r3 -> estimate remainder:q */
        ST     r3, [r7 + 34]

.Lmdu_div_check\@:
        LD     r1, [r7 + 34]
        MULHU   r0, r1, r5              /* r0:p.lo, r1:p.hi for q*vlo */
        ST     r0, [r7 + 32]
        ST     r1, [r7 + 30]
        SLTU    r0, r4, r1
        BNEZ    .Lmdu_div_correct\@
        SUB     r0, r1, r4
        BNEZ    .Lmdu_div_ready\@
        LD     r3, [r7 + 36]
        LD     r0, [r7 + 32]
        SLTU    r0, r3, r0
        BNEZ    .Lmdu_div_correct\@
        JMP8    .Lmdu_div_ready\@

.Lmdu_div_correct\@:
        LD     r1, [r7 + 34]
        ADDI    r1, -1
        ST     r1, [r7 + 34]
        ADD     r4, r4, r6              /* estimate remainder += vhi */
        SLTU    r0, r4, r6
        BNEZ    .Lmdu_div_ready\@      /* carry: no further correction */
        JMP8    .Lmdu_div_check\@

.Lmdu_div_ready\@:
        /* q * (vhi:vlo), represented as three 16-bit product limbs. */
        LD     r1, [r7 + 34]
        MULHU   r0, r1, r6              /* p1 = q*vhi */
        LD     r3, [r7 + 30]
        ADD     r3, r3, r0              /* middle product limb */
        SLTU    r4, r3, r0              /* carry into top limb */
        ADD     r1, r1, r4              /* top product limb */

        /* (old remainder : appended limb) - q * divisor. */
        LD     r4, [r7 + 36]
        LD     r0, [r7 + 32]
        SLTU    r2, r4, r0
        SUB     r4, r4, r0              /* new remainder low */
        MFS     r0, s6
        ADD     r3, r3, r2
        SLTU    r2, r3, r2
        SLTU    r5, r0, r3
        SUB     r0, r0, r3              /* new remainder high */
        OR      r2, r2, r5
        MFS     r3, s5
        SUB     r3, r3, r1
        SUB     r3, r3, r2              /* proven zero after correction */
        MOV     r3, r4                  /* return remainder low */
        MOV     r4, r0                  /* return remainder high */
        RET     s3
        .endm
#endif

        .section .text.__divsf3,"ax",@progbits
        .p2align 1
        .global __divsf3
        .hidden __divsf3
        .type __divsf3,@function
__divsf3:
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

        ST     r5, [r7 + 38]
        ST     r6, [r7 + 40]
        XOR     r0, r2, r4
        LUI     r5, 0x80
        AND     r0, r0, r5
        ST     r0, [r7 + 42]          /* result sign */

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
        LI      r2, 0x7fc0
        JMP8    .Lspecial_return
.Linfinity:
        LDI     r1, 0
        LI      r2, 0x7f80
        LD     r0, [r7 + 42]
        OR      r2, r2, r0
        JMP8    .Lspecial_return
.Lzero:
        LDI     r1, 0
        LD     r2, [r7 + 42]
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
        BNEZ    .Lnumerator_nonzero
        OR      r0, r3, r4
        BEQZ    .Lfinite_qnan
        JMP8    .Lfinite_zero
.Lnumerator_nonzero:
        OR      r0, r3, r4
        BNEZ    .Lnonzero_operands
        LDI     r1, 0
        LI      r2, 0x7f80
        LD     r0, [r7 + 42]
        OR      r2, r2, r0
        JMP8    .Lfinite_return
.Lfinite_qnan:
        LDI     r1, 0
        LI      r2, 0x7fc0
        JMP8    .Lfinite_return
.Lfinite_zero:
        LDI     r1, 0
        LD     r2, [r7 + 42]
.Lfinite_return:
        ABI_RETURN

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
        ADDI    r5, 1
        JMP8    .Lnormalize_right

.Lnormalized:
#ifdef __RISCC_MDU__
        /*
         * Align the 24-bit divisor into a normalized two-limb base-2^16
         * value.  The quotient below is floor((X << 26) / divisor), where
         * X is selected in [divisor, 2*divisor), exactly as the restoring
         * implementation does.  Dividing X<<34 by divisor<<8 leaves that
         * quotient unchanged and makes two 16-bit quotient digits available.
         */
        ST     r5, [r7 + 44]
        MOV     r5, r3
        SLLI    r5, r5, 8               /* divisor low limb */
        MTS     s4, r5
        MOV     r6, r4
        SLLI    r6, r6, 8
        SRLI    r0, r3, 8
        OR      r6, r6, r0              /* divisor high limb, >= 0x8000 */

        /* Select X and the matching exponent, so divisor <= X < 2*divisor. */
        SLTU    r0, r2, r4
        BNEZ    .Lmdu_numerator_less
        SUB     r0, r2, r4
        BNEZ    .Lmdu_numerator_ready
        SLTU    r0, r1, r3
        BNEZ    .Lmdu_numerator_less
.Lmdu_numerator_ready:
        JMP8    .Lmdu_numerator_selected
.Lmdu_numerator_less:
        FSL1    r2, r1
        ADD     r1, r1, r1
        LD     r0, [r7 + 44]
        ADDI    r0, -1
        ST     r0, [r7 + 44]
.Lmdu_numerator_selected:
        /*
         * X << 34: start the 4-limb dividend with its upper two limbs.
         * Form X << 2 as a pair with two one-bit funnel steps.  Besides
         * avoiding large immediate shifts, this is four instructions rather
         * than splitting r1 >> 14 and ORing it into the high limb.
         */
        LDI     r0, 0
        ST     r0, [r7 + 36]           /* next limb; final limb is zero */
        MOV     r4, r2
        FSL1    r4, r1
        ADD     r3, r1, r1
        FSL1    r4, r3
        ADD     r3, r3, r3              /* initial remainder = X << 2 */

        /* The two digits share one local helper; both appended limbs are zero. */
        LDI     r2, 0
        JALL    s3, .Lmdu_div_digit
        LD     r0, [r7 + 34]
        ST     r0, [r7 + 28]

        MFS     r5, s4
        LDI     r2, 0
        JALL    s3, .Lmdu_div_digit

        LD     r2, [r7 + 28]
        LD     r1, [r7 + 34]
        OR      r0, r3, r4
        BEQZ    .Lmdu_exact
        ORI     r1, 1                   /* sticky */
.Lmdu_exact:
        LD     r3, [r7 + 42]
        LD     r4, [r7 + 44]
        TAIL_PACK
#else
        ST     r5, [r7 + 44]
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
        MOV     r4, r2
        FSL1    r4, r1
        ADD     r3, r1, r1
        LD     r0, [r7 + 44]
        ADDI    r0, -1
        ST     r0, [r7 + 44]
.Linitial_subtract:
        SLTU    r0, r3, r5
        SUB     r3, r3, r5
        SUB     r4, r4, r6
        SUB     r4, r4, r0

        LDI     r1, 1
        LDI     r2, 0
        LDI     r0, 13
        ST     r0, [r7 + 46]
.Ldivide:
        .rept 2
        DIV_ROUND
        .endr
        LD     r0, [r7 + 46]
        ADDI    r0, -1
        ST     r0, [r7 + 46]
        BNEZ    .Ldivide

        OR      r0, r3, r4
        BEQZ    .Lexact
        ORI     r1, 1
.Lexact:
        LD     r3, [r7 + 42]
        LD     r4, [r7 + 44]
        TAIL_PACK                      /* tail call */
#endif
#ifdef __RISCC_MDU__
.Lmdu_div_digit:
        MDU_DIV_DIGIT
#endif
        .size __divsf3, . - __divsf3

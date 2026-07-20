/*
 * Full IEEE-754 binary32 addition for the Min/Sys/Full profiles.
 *
 * The larger magnitude is kept in r2:r1 and the smaller in r4:r3.  Three
 * guard/round/sticky bits are carried through alignment and cancellation;
 * __riscc_pack_sf supplies gradual underflow and final rounding.
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

        .section .text.__addsf3,"ax",@progbits
        .p2align 1
        .global __addsf3
        .hidden __addsf3
        .type __addsf3,@function
__addsf3:
        STW     r5, [r7 - 12]
        STW     r6, [r7 - 10]

        LUI     r5, 0x80
        AND     r0, r2, r5
        STW     r0, [r7 - 8]           /* left sign */
        AND     r0, r4, r5
        STW     r0, [r7 - 6]           /* right sign */

        MOV     r5, r2
        MOV     r6, r4
        EXTRACT_EXP r5
        EXTRACT_EXP r6
        ANDI    r5, 255
        ANDI    r6, 255

        /* NaNs and infinities preserve the C implementation's precedence. */
        LDI     r0, 255
        SUB     r0, r5, r0
        BNEZ    .Lcheck_right_special
        MOV     r0, r2
        ANDI    r0, 0x7f
        OR      r0, r0, r1
        BNEZ    .Lquiet_left
        LDI     r0, 255
        SUB     r0, r6, r0
        BNEZ    .Lspecial_return
        MOV     r0, r4
        ANDI    r0, 0x7f
        OR      r0, r0, r3
        BNEZ    .Lquiet_right
        LDW     r0, [r7 - 8]
        LDW     r5, [r7 - 6]
        XOR     r0, r0, r5
        BLTZ    .Lqnan
        JMP8    .Lspecial_return

.Lcheck_right_special:
        LDI     r0, 255
        SUB     r0, r6, r0
        BNEZ    .Lfinite
        MOV     r0, r4
        ANDI    r0, 0x7f
        OR      r0, r0, r3
        BNEZ    .Lquiet_right
        MOV     r1, r3
        MOV     r2, r4
        JMP8    .Lspecial_return

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
.Lspecial_return:
        LDW     r6, [r7 - 10]
        LDW     r5, [r7 - 12]
        RETS

.Lfinite:
        /* Exact zeros retain the nonzero operand or IEEE signed-zero rule. */
        MOV     r0, r2
        ANDI    r0, 0x7f
        OR      r0, r0, r1
        OR      r0, r0, r5
        BNEZ    .Lleft_nonzero
        MOV     r0, r4
        ANDI    r0, 0x7f
        OR      r0, r0, r3
        OR      r0, r0, r6
        BNEZ    .Lreturn_right
        LDW     r2, [r7 - 8]
        LDW     r0, [r7 - 6]
        AND     r2, r2, r0
        LDI     r1, 0
        JMP8    .Lspecial_return
.Lreturn_right:
        MOV     r1, r3
        MOV     r2, r4
        JMP8    .Lspecial_return
.Lleft_nonzero:
        MOV     r0, r4
        ANDI    r0, 0x7f
        OR      r0, r0, r3
        OR      r0, r0, r6
        BEQZ    .Lspecial_return

        /* Build significands and effective exponents. */
        ANDI    r2, 0x7f
        MOV     r0, r5
        BNEZ    .Lleft_normal
        LDI     r5, 1
        JMP8    .Lleft_ready
.Lleft_normal:
        ORI     r2, 0x80
.Lleft_ready:
        ANDI    r4, 0x7f
        MOV     r0, r6
        BNEZ    .Lright_normal
        LDI     r6, 1
        JMP8    .Lright_ready
.Lright_normal:
        ORI     r4, 0x80
.Lright_ready:

        /* Put the larger magnitude in r2:r1. */
        SLTU    r0, r5, r6
        BNEZ    .Lswap
        SUB     r0, r5, r6
        BNEZ    .Lordered
        SLTU    r0, r2, r4
        BNEZ    .Lswap
        SUB     r0, r2, r4
        BNEZ    .Lordered
        SLTU    r0, r1, r3
        BEQZ    .Lordered
.Lswap:
        MOV     r0, r1
        MOV     r1, r3
        MOV     r3, r0
        MOV     r0, r2
        MOV     r2, r4
        MOV     r4, r0
        MOV     r0, r5
        MOV     r5, r6
        MOV     r6, r0
        LDW     r0, [r7 - 8]
        STW     r0, [r7 - 4]
        LDW     r0, [r7 - 6]
        STW     r0, [r7 - 8]
        LDW     r0, [r7 - 4]
        STW     r0, [r7 - 6]

.Lordered:
        /* Add GRS bits before aligning the smaller operand. */
        .rept 3
        FSL1    r2, r2, r1
        ADD     r1, r1, r1
        FSL1    r4, r4, r3
        ADD     r3, r3, r3
        .endr

        SUB     r6, r5, r6
        LDI     r0, 0
        STW     r0, [r7 - 4]           /* alignment sticky */
        LDI     r0, 32
        SLTU    r0, r6, r0
        BNEZ    .Lalign_test
        LDI     r3, 1
        LDI     r4, 0
        JMP8    .Laligned
.Lalign_loop:
        LDW     r0, [r7 - 4]
        MOV     r6, r3
        ANDI    r6, 1
        OR      r0, r0, r6
        STW     r0, [r7 - 4]
        FSR1    r3, r3, r4
        SHRI    r4, r4, 1
        LDW     r6, [r7 - 2]
        ADDI    r6, -1
        STW     r6, [r7 - 2]
.Lalign_test:
        STW     r6, [r7 - 2]
        MOV     r0, r6
        BNEZ    .Lalign_loop
        LDW     r0, [r7 - 4]
        OR      r3, r3, r0
.Laligned:

        LDW     r6, [r7 - 8]
        LDW     r0, [r7 - 6]
        XOR     r0, r6, r0
        BLTZ    .Lsubtract

        MOV     r6, r1
        ADD     r1, r1, r3
        SLTU    r0, r1, r6
        ADD     r2, r2, r4
        ADD     r2, r2, r0
        LUI     r6, 8
        AND     r0, r2, r6
        BEQZ    .Lpack
        MOV     r6, r1
        ANDI    r6, 1
        FSR1    r1, r1, r2
        SHRI    r2, r2, 1
        OR      r1, r1, r6
        ADDI    r5, 1
        JMP8    .Lpack

.Lsubtract:
        SLTU    r0, r1, r3
        SUB     r1, r1, r3
        SUB     r2, r2, r4
        SUB     r2, r2, r0
        OR      r0, r1, r2
        BEQZ    .Lcancelled
.Lnormalize:
        LUI     r6, 4
        AND     r0, r2, r6
        BNEZ    .Lpack
        CMPI    r5, 1
        BEQZ    .Lpack
        FSL1    r2, r2, r1
        ADD     r1, r1, r1
        ADDI    r5, -1
        JMP8    .Lnormalize

.Lcancelled:
        LDI     r1, 0
        LDI     r2, 0
        LDW     r6, [r7 - 10]
        LDW     r5, [r7 - 12]
        RETS

.Lpack:
        LDW     r3, [r7 - 8]
        MOV     r4, r5
        LDW     r6, [r7 - 10]
        LDW     r5, [r7 - 12]
        TAIL_PACK                      /* tail call */
        .size __addsf3, . - __addsf3

/*
 * Hot unsigned integer divide and remainder entry points.
 *
 * The C implementation's branchless selection is compact at source level but
 * spills several live values around every quotient bit.  These leaf loops keep
 * the complete divide in registers.  Mainline uses FSL1 to feed the numerator
 * into the remainder; Nano expands that operation locally.
 */

#ifdef __RISCC_NANO__
#define DIV_RETURN RET r6
#else
#define DIV_RETURN RETS
#endif

        .macro SAVE_R5
#ifdef __RISCC_NANO__
        STW     r5, [r7 - 2]
#else
        MTS     s3, r5
#endif
        .endm

        .macro RESTORE_R5
#ifdef __RISCC_NANO__
        LDW     r5, [r7 - 2]
#else
        MFS     r5, s3
#endif
        .endm

        .macro FUNCTION name
        .section .text.\name,"ax",@progbits
        .p2align 1
        .global \name
        .hidden \name
        .type \name,@function
\name:
        .endm

        .macro SIGN_BIT source
#ifdef __RISCC_NANO__
        LUI     r0, 128
        SLTU    r0, \source, r0
        XORI    r0, 1
#else
        LDI     r0, 0
        SLT     r0, \source, r0
#endif
        .endm

        FUNCTION __udivhi3
        SAVE_R5
        LDI     r4, 0                  /* quotient */
        MOV     r0, r2
        BEQZ    .Ludiv_done
        LDI     r3, 0                  /* remainder */
        LDI     r5, 16
.Ludiv_loop:
#ifdef __RISCC_NANO__
        SIGN_BIT r1
        ADD     r3, r3, r3
        OR      r3, r3, r0
        ADD     r1, r1, r1
#else
        FSL1    r3, r3, r1
        ADD     r1, r1, r1
#endif
        /*
         * Before the final input bit, the partial numerator is at most
         * 0x7fff, so remainder << 1 cannot overflow a 16-bit register.
         */
        MOV     r0, r3
        SLTU    r0, r0, r2
        BNEZ    .Ludiv_keep
.Ludiv_subtract:
        SUB     r3, r3, r2
        ADDI    r4, 1
.Ludiv_keep:
        ADDI    r5, -1
        MOV     r0, r5
        BEQZ    .Ludiv_done
        ADD     r4, r4, r4
        JMP8    .Ludiv_loop
.Ludiv_done:
        MOV     r1, r4
        RESTORE_R5
        DIV_RETURN
        .size __udivhi3, . - __udivhi3

        FUNCTION __umodhi3
        SAVE_R5
        MOV     r0, r2
        BEQZ    .Lumod_done
        LDI     r3, 0                  /* remainder */
        LDI     r5, 16
.Lumod_loop:
#ifdef __RISCC_NANO__
        SIGN_BIT r1
        ADD     r3, r3, r3
        OR      r3, r3, r0
        ADD     r1, r1, r1
#else
        FSL1    r3, r3, r1
        ADD     r1, r1, r1
#endif
        MOV     r0, r3
        SLTU    r0, r0, r2
        BNEZ    .Lumod_keep
.Lumod_subtract:
        SUB     r3, r3, r2
.Lumod_keep:
        ADDI    r5, -1
        MOV     r0, r5
        BNEZ    .Lumod_loop
        MOV     r1, r3
.Lumod_done:
        RESTORE_R5
        DIV_RETURN
        .size __umodhi3, . - __umodhi3

        FUNCTION __udivmodhi4
        SAVE_R5
#ifdef __RISCC_NANO__
        STW     r3, [r7 - 4]
#else
        MTS     s4, r3
#endif
        LDI     r4, 0                   /* quotient */
        MOV     r0, r2
        BEQZ    .Ludivmodhi_zero
        LDI     r3, 0                   /* remainder */
        LDI     r5, 16
.Ludivmodhi_loop:
#ifdef __RISCC_NANO__
        SIGN_BIT r1
        ADD     r3, r3, r3
        OR      r3, r3, r0
        ADD     r1, r1, r1
#else
        FSL1    r3, r3, r1
        ADD     r1, r1, r1
#endif
        MOV     r0, r3
        SLTU    r0, r0, r2
        BNEZ    .Ludivmodhi_keep
        SUB     r3, r3, r2
        ADDI    r4, 1
.Ludivmodhi_keep:
        ADDI    r5, -1
        MOV     r0, r5
        BEQZ    .Ludivmodhi_store
        ADD     r4, r4, r4
        JMP8    .Ludivmodhi_loop
.Ludivmodhi_zero:
        MOV     r3, r1
.Ludivmodhi_store:
#ifdef __RISCC_NANO__
        LDW     r0, [r7 - 4]
#else
        MFS     r0, s4
#endif
        BEQZ    .Ludivmodhi_no_store
        STW     r3, [r0 + 0]
.Ludivmodhi_no_store:
        MOV     r1, r4
        RESTORE_R5
        DIV_RETURN
        .size __udivmodhi4, . - __udivmodhi4

/*
 * Shared unsigned 32-bit quotient/remainder core.
 *
 * The three public entries select quotient, remainder, or quotient plus a
 * stored remainder.  They deliberately share one section and one restoring
 * loop: pulling any entry from the archive therefore costs only one divider.
 *
 * Mainline keeps the 64-bit combined quotient/remainder state in GPRs and
 * uses the S-register cache for saved state and loop control.  Nano stores
 * the divisor and loop state below the unchanged incoming r7, leaving its
 * link in r6 untouched.
 */

        .section .text.__udivsi3,"ax",@progbits
        .p2align 1
        .global __udivsi3
        .hidden __udivsi3
        .type __udivsi3,@function
__udivsi3:
        LDI     r0, 0                   /* return quotient */
        JMP8    .Ludivsi_entry

        .global __umodsi3
        .hidden __umodsi3
        .type __umodsi3,@function
__umodsi3:
        LDI     r0, 1                   /* return remainder */
        JMP8    .Ludivsi_entry

        .global __udivmodsi4
        .hidden __udivmodsi4
        .type __udivmodsi4,@function
__udivmodsi4:
#ifdef __RISCC_NANO__
        LDW     r0, [r7 + 0]
        STW     r0, [r7 - 6]            /* remainder pointer */
#else
        LDW     r0, [r7 + 0]
        STW     r0, [r7 - 2]            /* remainder pointer */
#endif
        LDI     r0, 2                   /* quotient and stored remainder */

.Ludivsi_entry:
#ifdef __RISCC_NANO__
        STW     r5, [r7 - 2]
        STW     r0, [r7 - 4]            /* result selection */
        STW     r3, [r7 - 8]            /* divisor low */
        STW     r4, [r7 - 10]           /* divisor high */
#else
        MTS     s3, r5
        MTS     s4, r6
        MTS     s5, r0                  /* result selection */
#endif

        OR      r0, r3, r4
        BNEZ    .Ludivsi_nonzero

        /* Project convention: division by zero gives q=0, r=numerator. */
#ifdef __RISCC_NANO__
        MOV     r3, r1
        MOV     r4, r2
#else
        MOV     r5, r1
        MOV     r6, r2
#endif
        LDI     r1, 0
        LDI     r2, 0
        JMP8    .Ludivsi_done

.Ludivsi_nonzero:
#ifdef __RISCC_NANO__
        LDI     r3, 0                   /* remainder low */
        LDI     r4, 0                   /* remainder high */
        LDI     r0, 32
        STW     r0, [r7 - 12]
#else
        LDI     r5, 0                   /* remainder low */
        LDI     r6, 0                   /* remainder high */
        LDI     r0, 32
        MTS     s6, r0
#endif

.Ludivsi_loop:
#ifdef __RISCC_NANO__
        /* Shift remainder:q left by one without funnel instructions. */
        MOV     r0, r3
        ADD     r3, r3, r3
        SLTU    r0, r3, r0
        ADD     r4, r4, r4
        OR      r4, r4, r0

        LUI     r0, 128
        SLTU    r0, r2, r0
        XORI    r0, 1
        OR      r3, r3, r0

        MOV     r0, r1
        ADD     r1, r1, r1
        SLTU    r0, r1, r0
        ADD     r2, r2, r2
        OR      r2, r2, r0

        /* Compare remainder r4:r3 with the saved divisor. */
        LDW     r0, [r7 - 10]
        SLTU    r0, r4, r0
        BNEZ    .Ludivsi_keep
        LDW     r0, [r7 - 10]
        SUB     r0, r4, r0
        BNEZ    .Ludivsi_subtract
        LDW     r0, [r7 - 8]
        SLTU    r0, r3, r0
        BNEZ    .Ludivsi_keep

.Ludivsi_subtract:
        LDW     r0, [r7 - 8]
        SLTU    r5, r3, r0
        SUB     r3, r3, r0
        LDW     r0, [r7 - 10]
        SUB     r4, r4, r0
        SUB     r4, r4, r5
#else
        FSL1    r6, r6, r5
        FSL1    r5, r5, r2
        FSL1    r2, r2, r1
        ADD     r1, r1, r1

        SLTU    r0, r6, r4
        BNEZ    .Ludivsi_keep
        SUB     r0, r6, r4
        BNEZ    .Ludivsi_subtract
        SLTU    r0, r5, r3
        BNEZ    .Ludivsi_keep

.Ludivsi_subtract:
        SLTU    r0, r5, r3
        SUB     r5, r5, r3
        SUB     r6, r6, r4
        SUB     r6, r6, r0
#endif
        ADDI    r1, 1                   /* quotient bit */

.Ludivsi_keep:
#ifdef __RISCC_NANO__
        LDW     r0, [r7 - 12]
        ADDI    r0, -1
        STW     r0, [r7 - 12]
#else
        MFS     r0, s6
        ADDI    r0, -1
        MTS     s6, r0
#endif
        BNEZ    .Ludivsi_loop

.Ludivsi_done:
#ifdef __RISCC_NANO__
        LDW     r0, [r7 - 4]
        ADDI    r0, -1
        BEQZ    .Ludivsi_remainder
        BLTZ    .Ludivsi_return
        LDW     r0, [r7 - 6]
        BEQZ    .Ludivsi_return
        STW     r3, [r0 + 0]
        STW     r4, [r0 + 2]
        JMP8    .Ludivsi_return
.Ludivsi_remainder:
        MOV     r1, r3
        MOV     r2, r4
.Ludivsi_return:
        LDW     r5, [r7 - 2]
        RET     r6
#else
        MFS     r0, s5
        ADDI    r0, -1
        BEQZ    .Ludivsi_remainder
        BLTZ    .Ludivsi_return
        LDW     r0, [r7 - 2]
        BEQZ    .Ludivsi_return
        STW     r5, [r0 + 0]
        STW     r6, [r0 + 2]
        JMP8    .Ludivsi_return
.Ludivsi_remainder:
        MOV     r1, r5
        MOV     r2, r6
.Ludivsi_return:
        MFS     r6, s4
        MFS     r5, s3
        RETS
#endif
        .size __udivsi3, . - __udivsi3
        .size __umodsi3, . - __umodsi3
        .size __udivmodsi4, . - __udivmodsi4

/*
 * Shared unsigned 64-bit quotient/remainder core.
 *
 * The ABI passes the numerator in r1..r4 and the denominator in the first
 * four stack slots.  The restoring state lives below the unchanged incoming
 * r7.  Mainline retains the loop count in its S-register cache; Nano uses one
 * additional fixed scratch slot and preserves its incoming link in r6.
 */

        .section .text.__udivdi3,"ax",@progbits
        .p2align 1
        .global __udivdi3
        .hidden __udivdi3
        .type __udivdi3,@function
__udivdi3:
        LDI     r0, 0                   /* return quotient */
        JMP8    .Ludivdi_entry

        .global __umoddi3
        .hidden __umoddi3
        .type __umoddi3,@function
__umoddi3:
        LDI     r0, 1                   /* return remainder */
        JMP8    .Ludivdi_entry

        .global __udivmoddi4
        .hidden __udivmoddi4
        .type __udivmoddi4,@function
__udivmoddi4:
        LDW     r0, [r7 + 8]
        STW     r0, [r7 - 8]            /* remainder pointer */
        LDI     r0, 2                   /* quotient and stored remainder */

.Ludivdi_entry:
        STW     r5, [r7 - 2]
        STW     r6, [r7 - 4]
        STW     r0, [r7 - 6]            /* result selection */

        LDW     r0, [r7 + 0]
        LDW     r6, [r7 + 2]
        OR      r0, r0, r6
        LDW     r6, [r7 + 4]
        OR      r0, r0, r6
        LDW     r6, [r7 + 6]
        OR      r0, r0, r6
        BNEZ    .Ludivdi_nonzero

        /* Project convention: division by zero gives q=0, r=numerator. */
        STW     r1, [r7 - 10]
        STW     r2, [r7 - 12]
        STW     r3, [r7 - 14]
        STW     r4, [r7 - 16]
        LDI     r1, 0
        LDI     r2, 0
        LDI     r3, 0
        LDI     r4, 0
        JMP8    .Ludivdi_done

.Ludivdi_nonzero:
        LDI     r0, 0
        STW     r0, [r7 - 10]           /* remainder, low to high */
        STW     r0, [r7 - 12]
        STW     r0, [r7 - 14]
        STW     r0, [r7 - 16]
        LDI     r0, 64
#ifdef __RISCC_NANO__
        STW     r0, [r7 - 18]
#else
        MTS     s3, r0
#endif

.Ludivdi_loop:
        /* Shift the 128-bit remainder:quotient state left by one. */
        LDW     r5, [r7 - 16]
        LDW     r6, [r7 - 14]
#ifdef __RISCC_NANO__
        SIGN_BIT r6
        ADD     r5, r5, r5
        OR      r5, r5, r0
#else
        FSL1    r5, r5, r6
#endif
        STW     r5, [r7 - 16]

        LDW     r5, [r7 - 14]
        LDW     r6, [r7 - 12]
#ifdef __RISCC_NANO__
        SIGN_BIT r6
        ADD     r5, r5, r5
        OR      r5, r5, r0
#else
        FSL1    r5, r5, r6
#endif
        STW     r5, [r7 - 14]

        LDW     r5, [r7 - 12]
        LDW     r6, [r7 - 10]
#ifdef __RISCC_NANO__
        SIGN_BIT r6
        ADD     r5, r5, r5
        OR      r5, r5, r0
#else
        FSL1    r5, r5, r6
#endif
        STW     r5, [r7 - 12]

        LDW     r5, [r7 - 10]
#ifdef __RISCC_NANO__
        SIGN_BIT r4
        ADD     r5, r5, r5
        OR      r5, r5, r0
#else
        FSL1    r5, r5, r4
#endif
        STW     r5, [r7 - 10]

#ifdef __RISCC_NANO__
        SIGN_BIT r3
        ADD     r4, r4, r4
        OR      r4, r4, r0
        SIGN_BIT r2
        ADD     r3, r3, r3
        OR      r3, r3, r0
        SIGN_BIT r1
        ADD     r2, r2, r2
        OR      r2, r2, r0
        ADD     r1, r1, r1
#else
        FSL1    r4, r4, r3
        FSL1    r3, r3, r2
        FSL1    r2, r2, r1
        ADD     r1, r1, r1
#endif

        /* Compare remainder with the denominator, high word first. */
        LDW     r5, [r7 - 16]
        LDW     r6, [r7 + 6]
        SLTU    r0, r5, r6
        BNEZ    .Ludivdi_keep
        SUB     r0, r5, r6
        BNEZ    .Ludivdi_subtract

        LDW     r5, [r7 - 14]
        LDW     r6, [r7 + 4]
        SLTU    r0, r5, r6
        BNEZ    .Ludivdi_keep
        SUB     r0, r5, r6
        BNEZ    .Ludivdi_subtract

        LDW     r5, [r7 - 12]
        LDW     r6, [r7 + 2]
        SLTU    r0, r5, r6
        BNEZ    .Ludivdi_keep
        SUB     r0, r5, r6
        BNEZ    .Ludivdi_subtract

        LDW     r5, [r7 - 10]
        LDW     r6, [r7 + 0]
        SLTU    r0, r5, r6
        BNEZ    .Ludivdi_keep

.Ludivdi_subtract:
        /* Low word has no incoming borrow. */
        LDW     r5, [r7 - 10]
        LDW     r0, [r7 + 0]
        SLTU    r6, r5, r0
        SUB     r5, r5, r0
        STW     r5, [r7 - 10]

        /*
         * For the upper words, combine the incoming-borrow underflow with
         * the ordinary word subtraction's borrow.
         */
        LDW     r5, [r7 - 12]
        MOV     r0, r5
        SUB     r5, r5, r6
        SLTU    r0, r0, r5
        STW     r0, [r7 - 20]
        LDW     r0, [r7 + 2]
        SLTU    r6, r5, r0
        SUB     r5, r5, r0
        LDW     r0, [r7 - 20]
        OR      r6, r6, r0
        STW     r5, [r7 - 12]

        LDW     r5, [r7 - 14]
        MOV     r0, r5
        SUB     r5, r5, r6
        SLTU    r0, r0, r5
        STW     r0, [r7 - 20]
        LDW     r0, [r7 + 4]
        SLTU    r6, r5, r0
        SUB     r5, r5, r0
        LDW     r0, [r7 - 20]
        OR      r6, r6, r0
        STW     r5, [r7 - 14]

        LDW     r5, [r7 - 16]
        MOV     r0, r5
        SUB     r5, r5, r6
        SLTU    r0, r0, r5
        STW     r0, [r7 - 20]
        LDW     r0, [r7 + 6]
        SLTU    r6, r5, r0
        SUB     r5, r5, r0
        LDW     r0, [r7 - 20]
        OR      r6, r6, r0
        STW     r5, [r7 - 16]

        ADDI    r1, 1                   /* quotient bit */

.Ludivdi_keep:
#ifdef __RISCC_NANO__
        LDW     r0, [r7 - 18]
        ADDI    r0, -1
        STW     r0, [r7 - 18]
#else
        MFS     r0, s3
        ADDI    r0, -1
        MTS     s3, r0
#endif
        BNEZ    .Ludivdi_loop

.Ludivdi_done:
        LDW     r0, [r7 - 6]
        ADDI    r0, -1
        BEQZ    .Ludivdi_remainder
        BLTZ    .Ludivdi_return

        LDW     r0, [r7 - 8]
        BEQZ    .Ludivdi_return
        LDW     r5, [r7 - 10]
        STW     r5, [r0 + 0]
        LDW     r5, [r7 - 12]
        STW     r5, [r0 + 2]
        LDW     r5, [r7 - 14]
        STW     r5, [r0 + 4]
        LDW     r5, [r7 - 16]
        STW     r5, [r0 + 6]
        JMP8    .Ludivdi_return

.Ludivdi_remainder:
        LDW     r1, [r7 - 10]
        LDW     r2, [r7 - 12]
        LDW     r3, [r7 - 14]
        LDW     r4, [r7 - 16]

.Ludivdi_return:
        LDW     r6, [r7 - 4]
        LDW     r5, [r7 - 2]
        DIV_RETURN
        .size __udivdi3, . - __udivdi3
        .size __umoddi3, . - __umoddi3
        .size __udivmoddi4, . - __udivmoddi4

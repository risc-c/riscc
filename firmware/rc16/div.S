/*
 * Hot RC16 unsigned integer divide and remainder entry points.
 *
 * The C implementation's branchless selection is compact at source level but
 * spills several live values around every quotient bit.  These leaf loops keep
 * the complete divide in registers.  Mainline uses FSL1 to feed the numerator
 * into the remainder; Nano expands that operation locally.
 */

#ifdef __RISCC_NANO__
#define DIV_RETURN NANO_RETURN
#define DIV_ARG0 8
#define DIV_ARG2 10
#define DIV_ARG4 12
#define DIV_ARG6 14
#define DIV_ARG8 16
#define DIV32_ARG0 0
#define DIV32_ARG2 2
#define DIV32_ARG4 4
#else
#define DIV_RETURN ABI_RETURN
#define DIV_ARG0 48
#define DIV_ARG2 50
#define DIV_ARG4 52
#define DIV_ARG6 54
#define DIV_ARG8 56
#define DIV32_ARG0 40
#define DIV32_ARG2 42
#define DIV32_ARG4 44
#endif

#ifdef __RISCC_NANO__
        .macro NANO_SAVE
        ST      r4, [r7 - 22]
        .endm

        .macro NANO_RETURN
        LD      r4, [r7 - 22]
        JMP     r6
        .endm

        .macro NANO_RETURN64
        LD      r0, [r7 - 24]
        ST      r1, [r0 + 0]
        ST      r2, [r0 + 2]
        ST      r3, [r0 + 4]
        ST      r4, [r0 + 6]
        NANO_RETURN
        .endm

        /* Signed 32-bit adapters call an unsigned helper. Keep their r4
         * save outside the unsigned helper's fixed Nano scratch area. */
        .macro NANO_SIGNED_SAVE
        ST      r4, [r7 - 24]
        NANO_SAVE
        .endm

        .macro NANO_SIGNED_RETURN
        LD      r4, [r7 - 24]
        JMP     r6
        .endm
#endif

#ifndef __RISCC_NANO__
        .macro ABI_SAVE
        /*
         * The cores retain temporary values below r7 and signed adapters
         * call these unsigned entries.  Reserve that scratch area as part
         * of the ABI frame so a nested helper cannot overlap its caller.
         */
        ADDI    r7, -40
        ST      r4, [r7 + 10]
        ST      r5, [r7 + 12]
        ST      r6, [r7 + 14]
        MFS     r0, s5
        ST      r0, [r7 + 16]
        MFS     r0, s6
        ST      r0, [r7 + 18]
        .endm

        .macro ABI_RETURN
        LD      r4, [r7 + 10]
        LD      r5, [r7 + 12]
        LD      r6, [r7 + 14]
        LD      r0, [r7 + 16]
        MTS     s5, r0
        LD      r0, [r7 + 18]
        MTS     s6, r0
        ADDI    r7, 40
        RET     S7
        .endm

        .macro ABI_RETURN64
        MFS     r0, s4
        ST      r1, [r0 + 0]
        ST      r2, [r0 + 2]
        ST      r3, [r0 + 4]
        ST      r4, [r0 + 6]
        ABI_RETURN
        .endm
#endif

        .macro LOAD_DIVISOR32
        LD      r3, [r7 + DIV32_ARG0]
        LD      r4, [r7 + DIV32_ARG2]
        .endm

        .macro LOAD_DIVIDEND64
#ifdef __RISCC_NANO__
        ST      r1, [r7 - 24]
        LD      r1, [r7 + 0]
        LD      r2, [r7 + 2]
        LD      r3, [r7 + 4]
        LD      r4, [r7 + 6]
#else
        MTS     s4, r1
        LD      r1, [r7 + 40]
        LD      r2, [r7 + 42]
        LD      r3, [r7 + 44]
        LD      r4, [r7 + 46]
#endif
        .endm

        .macro SAVE_R5
#ifdef __RISCC_NANO__
        ST     r5, [r7 - 2]
#else
        MTS     s3, r5
#endif
        .endm

        .macro RESTORE_R5
#ifdef __RISCC_NANO__
        LD     r5, [r7 - 2]
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
#ifdef __RISCC_NANO__
        NANO_SAVE
#else
        ABI_SAVE
#endif
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
#ifdef __RISCC_MDU__
        /* DIVU takes remainder:quotient in r3:r1 and leaves r1 as quotient. */
        MOV     r0, r2
        BEQZ    .Ludiv_mdu_zero
        LDI     r3, 0
        DIVU    r3, r1, r2
        DIV_RETURN
.Ludiv_mdu_zero:
        LDI     r1, 0
        DIV_RETURN
#else
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
        FSL1    r3, r1
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
#endif
        .size __udivhi3, . - __udivhi3

        FUNCTION __umodhi3
#ifdef __RISCC_MDU__
        MOV     r0, r2
        BEQZ    .Lumod_mdu_done
        LDI     r3, 0
        DIVU    r3, r1, r2
        MOV     r1, r3
.Lumod_mdu_done:
        DIV_RETURN
#else
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
        FSL1    r3, r1
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
#endif
        .size __umodhi3, . - __umodhi3

        FUNCTION __udivmodhi4
#ifdef __RISCC_MDU__
        /* Preserve the ABI remainder pointer while r3 becomes DIVU's rr. */
        MTS     s4, r3
        MOV     r0, r2
        BEQZ    .Ludivmodhi_mdu_zero
        LDI     r3, 0
        DIVU    r3, r1, r2
        JMP8    .Ludivmodhi_mdu_store
.Ludivmodhi_mdu_zero:
        MOV     r3, r1
        LDI     r1, 0
.Ludivmodhi_mdu_store:
        MFS     r0, s4
        BEQZ    .Ludivmodhi_mdu_done
        ST     r3, [r0 + 0]
.Ludivmodhi_mdu_done:
        DIV_RETURN
#else
        SAVE_R5
#ifdef __RISCC_NANO__
        ST     r3, [r7 - 4]
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
        FSL1    r3, r1
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
        LD     r0, [r7 - 4]
#else
        MFS     r0, s4
#endif
        BEQZ    .Ludivmodhi_no_store
        ST     r3, [r0 + 0]
.Ludivmodhi_no_store:
        MOV     r1, r4
        RESTORE_R5
        DIV_RETURN
#endif
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
#ifdef __RISCC_NANO__
        NANO_SAVE
#else
        ABI_SAVE
#endif
        LOAD_DIVISOR32
        LDI     r0, 0                   /* return quotient */
        JMP8    .Ludivsi_entry

        .global __umodsi3
        .hidden __umodsi3
        .type __umodsi3,@function
__umodsi3:
#ifdef __RISCC_NANO__
        NANO_SAVE
#else
        ABI_SAVE
#endif
        LOAD_DIVISOR32
        LDI     r0, 1                   /* return remainder */
        JMP8    .Ludivsi_entry

        .global __udivmodsi4
        .hidden __udivmodsi4
        .type __udivmodsi4,@function
__udivmodsi4:
#ifdef __RISCC_NANO__
        NANO_SAVE
#else
        ABI_SAVE
#endif
        LOAD_DIVISOR32
#ifdef __RISCC_NANO__
        LD     r0, [r7 + DIV32_ARG4]
        ST     r0, [r7 - 6]            /* remainder pointer */
#else
        LD     r0, [r7 + DIV32_ARG4]
        ST     r0, [r7 - 2]            /* remainder pointer */
#endif
        LDI     r0, 2                   /* quotient and stored remainder */

.Ludivsi_entry:
#ifdef __RISCC_NANO__
        ST     r5, [r7 - 2]
        ST     r0, [r7 - 4]            /* result selection */
        ST     r3, [r7 - 8]            /* divisor low */
        ST     r4, [r7 - 10]           /* divisor high */
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
        /* Common divisions by one need no restoring-loop iterations. */
        MOV     r0, r4
        BNEZ    .Ludivsi_compare
        MOV     r0, r3
        ADDI    r0, -1
        BNEZ    .Ludivsi_compare
#ifdef __RISCC_NANO__
        LDI     r3, 0
        LDI     r4, 0
#else
        LDI     r5, 0
        LDI     r6, 0
#endif
        JMP8    .Ludivsi_done

.Ludivsi_compare:
        /* If numerator < denominator, quotient is zero and remainder is n. */
        SLTU    r0, r2, r4
        BNEZ    .Ludivsi_numerator_small
        SUB     r0, r2, r4
        BNEZ    .Ludivsi_loop_setup
        SLTU    r0, r1, r3
        BEQZ    .Ludivsi_loop_setup

.Ludivsi_numerator_small:
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

.Ludivsi_loop_setup:
#ifdef __RISCC_NANO__
        LDI     r3, 0                   /* remainder low */
        LDI     r4, 0                   /* remainder high */
        LDI     r0, 32
        ST     r0, [r7 - 12]
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
        LD     r0, [r7 - 10]
        SLTU    r0, r4, r0
        BNEZ    .Ludivsi_keep
        LD     r0, [r7 - 10]
        SUB     r0, r4, r0
        BNEZ    .Ludivsi_subtract
        LD     r0, [r7 - 8]
        SLTU    r0, r3, r0
        BNEZ    .Ludivsi_keep

.Ludivsi_subtract:
        LD     r0, [r7 - 8]
        SLTU    r5, r3, r0
        SUB     r3, r3, r0
        LD     r0, [r7 - 10]
        SUB     r4, r4, r0
        SUB     r4, r4, r5
#else
        FSL1    r6, r5
        FSL1    r5, r2
        FSL1    r2, r1
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
        LD     r0, [r7 - 12]
        ADDI    r0, -1
        ST     r0, [r7 - 12]
#else
        MFS     r0, s6
        ADDI    r0, -1
        MTS     s6, r0
#endif
        BNEZ    .Ludivsi_loop

.Ludivsi_done:
#ifdef __RISCC_NANO__
        LD     r0, [r7 - 4]
        ADDI    r0, -1
        BEQZ    .Ludivsi_remainder
        BLTZ    .Ludivsi_return
        LD     r0, [r7 - 6]
        BEQZ    .Ludivsi_return
        ST     r3, [r0 + 0]
        ST     r4, [r0 + 2]
        JMP8    .Ludivsi_return
.Ludivsi_remainder:
        MOV     r1, r3
        MOV     r2, r4
.Ludivsi_return:
        LD     r5, [r7 - 2]
        NANO_RETURN
#else
        MFS     r0, s5
        ADDI    r0, -1
        BEQZ    .Ludivsi_remainder
        BLTZ    .Ludivsi_return
        LD     r0, [r7 - 2]
        BEQZ    .Ludivsi_return
        ST     r5, [r0 + 0]
        ST     r6, [r0 + 2]
        JMP8    .Ludivsi_return
.Ludivsi_remainder:
        MOV     r1, r5
        MOV     r2, r6
.Ludivsi_return:
        MFS     r6, s4
        MFS     r5, s3
        ABI_RETURN
#endif
        .size __udivsi3, . - __udivsi3
        .size __umodsi3, . - __umodsi3
        .size __udivmodsi4, . - __udivmodsi4

/*
 * Signed 32-bit adapters.
 *
 * These live in a separate archive section, so unsigned-only programs do not
 * pay for sign handling.  They use fixed scratch below the unchanged incoming
 * r7 and call the shared unsigned loop with magnitude operands.
 */

        .macro NEGATE32 low, high, scratch
        LDI     r0, 0
        SLTU    \scratch, r0, \low
        SUB     \low, r0, \low
        SUB     \high, r0, \high
        SUB     \high, \high, \scratch
        .endm

        .macro CALL_UNSIGNED name
        ST      r3, [r7 + 0]
        ST      r4, [r7 + 2]
#ifdef __RISCC_NANO__
        LDI16   r0, \name
        JALR    r6, r0
#elif defined(__RISCC_SYS__) || defined(__RISCC_FULL__)
        JALL    s7, \name
#else
        LDI16   r0, \name
        JALR    s7, r0
#endif
        .endm

        .section .text.__divsi3,"ax",@progbits
        .p2align 1
        .global __divsi3
        .hidden __divsi3
        .type __divsi3,@function
__divsi3:
#ifdef __RISCC_NANO__
        NANO_SIGNED_SAVE
#else
        ABI_SAVE
#endif
        LOAD_DIVISOR32
        LDI     r0, 0                   /* signed quotient */
        JMP8    .Ldivsi_entry

        .global __modsi3
        .hidden __modsi3
        .type __modsi3,@function
__modsi3:
#ifdef __RISCC_NANO__
        NANO_SIGNED_SAVE
#else
        ABI_SAVE
#endif
        LOAD_DIVISOR32
        LDI     r0, 1                   /* signed remainder */
        JMP8    .Ldivsi_entry

        .global __divmodsi4
        .hidden __divmodsi4
        .type __divmodsi4,@function
__divmodsi4:
#ifdef __RISCC_NANO__
        NANO_SIGNED_SAVE
#else
        ABI_SAVE
        /* Pass the remainder pointer in the nested call's stack slot. */
        LD      r0, [r7 + DIV32_ARG4]
        ST      r0, [r7 + 4]
#endif
        LOAD_DIVISOR32
        LDI     r0, 2                   /* signed quotient and remainder */

.Ldivsi_entry:
        ST     r5, [r7 - 18]
        ST     r0, [r7 - 20]           /* result selection */
#ifdef __RISCC_NANO__
        ST     r6, [r7 - 14]           /* incoming link */
#else
        MFS     r0, s7
        ST     r0, [r7 - 14]           /* incoming link */
#endif

        /* bit 0: negate quotient; bit 1: negate remainder */
        SIGN_BIT r2
        MOV     r5, r0
        ADD     r5, r5, r5
        OR      r5, r5, r0
        SIGN_BIT r4
        XOR     r5, r5, r0
        ST     r5, [r7 - 16]

        MOV     r0, r2
        BLTZ    .Ldivsi_negate_numerator
.Ldivsi_denominator_sign:
        MOV     r0, r4
        BLTZ    .Ldivsi_negate_denominator
        JMP8    .Ldivsi_call
.Ldivsi_negate_numerator:
        NEGATE32 r1, r2, r5
        JMP8    .Ldivsi_denominator_sign
.Ldivsi_negate_denominator:
        NEGATE32 r3, r4, r5

.Ldivsi_call:
        LD     r0, [r7 - 20]
        ADDI    r0, -1
        BEQZ    .Ldivsi_call_remainder
        BLTZ    .Ldivsi_call_quotient
        CALL_UNSIGNED __udivmodsi4
        JMP8    .Ldivsi_fix_stored_remainder
.Ldivsi_call_remainder:
        CALL_UNSIGNED __umodsi3
        JMP8    .Ldivsi_fix_remainder
.Ldivsi_call_quotient:
        CALL_UNSIGNED __udivsi3
        JMP8    .Ldivsi_fix_quotient

.Ldivsi_fix_stored_remainder:
        LD     r0, [r7 - 16]
        ANDI    r0, 2
        BEQZ    .Ldivsi_fix_quotient
        LD     r0, [r7 + DIV32_ARG4]
        BEQZ    .Ldivsi_fix_quotient
        LD     r3, [r0 + 0]
        LD     r4, [r0 + 2]
        NEGATE32 r3, r4, r5
        LD     r0, [r7 + DIV32_ARG4]
        ST     r3, [r0 + 0]
        ST     r4, [r0 + 2]
        JMP8    .Ldivsi_fix_quotient

.Ldivsi_fix_remainder:
        LD     r0, [r7 - 16]
        ANDI    r0, 2
        BEQZ    .Ldivsi_return
        NEGATE32 r1, r2, r5
        JMP8    .Ldivsi_return

.Ldivsi_fix_quotient:
        LD     r0, [r7 - 16]
        ANDI    r0, 1
        BEQZ    .Ldivsi_return
        NEGATE32 r1, r2, r5

.Ldivsi_return:
        LD     r5, [r7 - 18]
#ifdef __RISCC_NANO__
        LD     r6, [r7 - 14]
        NANO_SIGNED_RETURN
#else
        LD     r0, [r7 - 14]
        MTS     s7, r0
        ABI_RETURN
#endif
        .size __divsi3, . - __divsi3
        .size __modsi3, . - __modsi3
        .size __divmodsi4, . - __divmodsi4

/*
 * Shared unsigned 64-bit quotient/remainder core.
 *
 * The mainline ABI passes the numerator in r1, r2, r3, r0 and the denominator
 * in the first four stack slots.  The restoring state lives below the unchanged incoming
 * r7.  Mainline retains the loop count in its S-register cache; Nano uses one
 * additional fixed scratch slot and preserves its incoming link in r6.
 */

        .section .text.__udivdi3,"ax",@progbits
        .p2align 1
        .global __udivdi3
        .hidden __udivdi3
        .type __udivdi3,@function
__udivdi3:
#ifdef __RISCC_NANO__
        NANO_SAVE
#else
        ABI_SAVE
#endif
        LOAD_DIVIDEND64
        LDI     r0, 0                   /* return quotient */
        JMP8    .Ludivdi_entry

        .global __umoddi3
        .hidden __umoddi3
        .type __umoddi3,@function
__umoddi3:
#ifdef __RISCC_NANO__
        NANO_SAVE
#else
        ABI_SAVE
#endif
        LOAD_DIVIDEND64
        LDI     r0, 1                   /* return remainder */
        JMP8    .Ludivdi_entry

        .global __udivmoddi4
        .hidden __udivmoddi4
        .type __udivmoddi4,@function
__udivmoddi4:
#ifdef __RISCC_NANO__
        NANO_SAVE
#else
        ABI_SAVE
#endif
        LOAD_DIVIDEND64
        LD     r0, [r7 + DIV_ARG8]
        ST     r0, [r7 - 8]            /* remainder pointer */
        LDI     r0, 2                   /* quotient and stored remainder */

.Ludivdi_entry:
        ST     r5, [r7 - 2]
        ST     r6, [r7 - 4]
        ST     r0, [r7 - 6]            /* result selection */

        LD     r0, [r7 + DIV_ARG0]
        LD     r6, [r7 + DIV_ARG2]
        OR      r0, r0, r6
        LD     r6, [r7 + DIV_ARG4]
        OR      r0, r0, r6
        LD     r6, [r7 + DIV_ARG6]
        OR      r0, r0, r6
        BNEZ    .Ludivdi_nonzero

        /* Project convention: division by zero gives q=0, r=numerator. */
        ST     r1, [r7 - 10]
        ST     r2, [r7 - 12]
        ST     r3, [r7 - 14]
        ST     r4, [r7 - 16]
        LDI     r1, 0
        LDI     r2, 0
        LDI     r3, 0
        LDI     r4, 0
        JMP8    .Ludivdi_done

.Ludivdi_nonzero:
        LDI     r0, 0
        ST     r0, [r7 - 10]           /* remainder, low to high */
        ST     r0, [r7 - 12]
        ST     r0, [r7 - 14]
        ST     r0, [r7 - 16]
        LDI     r0, 64
#ifdef __RISCC_NANO__
        ST     r0, [r7 - 18]
#else
        MTS     s3, r0
#endif

.Ludivdi_loop:
        /* Shift the 128-bit remainder:quotient state left by one. */
        LD     r5, [r7 - 16]
        LD     r6, [r7 - 14]
#ifdef __RISCC_NANO__
        SIGN_BIT r6
        ADD     r5, r5, r5
        OR      r5, r5, r0
#else
        FSL1    r5, r6
#endif
        ST     r5, [r7 - 16]

        LD     r5, [r7 - 14]
        LD     r6, [r7 - 12]
#ifdef __RISCC_NANO__
        SIGN_BIT r6
        ADD     r5, r5, r5
        OR      r5, r5, r0
#else
        FSL1    r5, r6
#endif
        ST     r5, [r7 - 14]

        LD     r5, [r7 - 12]
        LD     r6, [r7 - 10]
#ifdef __RISCC_NANO__
        SIGN_BIT r6
        ADD     r5, r5, r5
        OR      r5, r5, r0
#else
        FSL1    r5, r6
#endif
        ST     r5, [r7 - 12]

        LD     r5, [r7 - 10]
#ifdef __RISCC_NANO__
        SIGN_BIT r4
        ADD     r5, r5, r5
        OR      r5, r5, r0
#else
        FSL1    r5, r4
#endif
        ST     r5, [r7 - 10]

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
        FSL1    r4, r3
        FSL1    r3, r2
        FSL1    r2, r1
        ADD     r1, r1, r1
#endif

        /* Compare remainder with the denominator, high word first. */
        LD     r5, [r7 - 16]
        LD     r6, [r7 + DIV_ARG6]
        SLTU    r0, r5, r6
        BNEZ    .Ludivdi_keep
        SUB     r0, r5, r6
        BNEZ    .Ludivdi_subtract

        LD     r5, [r7 - 14]
        LD     r6, [r7 + DIV_ARG4]
        SLTU    r0, r5, r6
        BNEZ    .Ludivdi_keep
        SUB     r0, r5, r6
        BNEZ    .Ludivdi_subtract

        LD     r5, [r7 - 12]
        LD     r6, [r7 + DIV_ARG2]
        SLTU    r0, r5, r6
        BNEZ    .Ludivdi_keep
        SUB     r0, r5, r6
        BNEZ    .Ludivdi_subtract

        LD     r5, [r7 - 10]
        LD     r6, [r7 + DIV_ARG0]
        SLTU    r0, r5, r6
        BNEZ    .Ludivdi_keep

.Ludivdi_subtract:
        /* Low word has no incoming borrow. */
        LD     r5, [r7 - 10]
        LD     r0, [r7 + DIV_ARG0]
        SLTU    r6, r5, r0
        SUB     r5, r5, r0
        ST     r5, [r7 - 10]

        /*
         * For the upper words, combine the incoming-borrow underflow with
         * the ordinary word subtraction's borrow.
         */
        LD     r5, [r7 - 12]
        MOV     r0, r5
        SUB     r5, r5, r6
        SLTU    r0, r0, r5
        ST     r0, [r7 - 20]
        LD     r0, [r7 + DIV_ARG2]
        SLTU    r6, r5, r0
        SUB     r5, r5, r0
        LD     r0, [r7 - 20]
        OR      r6, r6, r0
        ST     r5, [r7 - 12]

        LD     r5, [r7 - 14]
        MOV     r0, r5
        SUB     r5, r5, r6
        SLTU    r0, r0, r5
        ST     r0, [r7 - 20]
        LD     r0, [r7 + DIV_ARG4]
        SLTU    r6, r5, r0
        SUB     r5, r5, r0
        LD     r0, [r7 - 20]
        OR      r6, r6, r0
        ST     r5, [r7 - 14]

        LD     r5, [r7 - 16]
        MOV     r0, r5
        SUB     r5, r5, r6
        SLTU    r0, r0, r5
        ST     r0, [r7 - 20]
        LD     r0, [r7 + DIV_ARG6]
        SLTU    r6, r5, r0
        SUB     r5, r5, r0
        LD     r0, [r7 - 20]
        OR      r6, r6, r0
        ST     r5, [r7 - 16]

        ADDI    r1, 1                   /* quotient bit */

.Ludivdi_keep:
#ifdef __RISCC_NANO__
        LD     r0, [r7 - 18]
        ADDI    r0, -1
        ST     r0, [r7 - 18]
#else
        MFS     r0, s3
        ADDI    r0, -1
        MTS     s3, r0
#endif
        BNEZ    .Ludivdi_loop

.Ludivdi_done:
        LD     r0, [r7 - 6]
        ADDI    r0, -1
        BEQZ    .Ludivdi_remainder
        BLTZ    .Ludivdi_return

        LD     r0, [r7 - 8]
        BEQZ    .Ludivdi_return
        LD     r5, [r7 - 10]
        ST     r5, [r0 + 0]
        LD     r5, [r7 - 12]
        ST     r5, [r0 + 2]
        LD     r5, [r7 - 14]
        ST     r5, [r0 + 4]
        LD     r5, [r7 - 16]
        ST     r5, [r0 + 6]
        JMP8    .Ludivdi_return

.Ludivdi_remainder:
        LD     r1, [r7 - 10]
        LD     r2, [r7 - 12]
        LD     r3, [r7 - 14]
        LD     r4, [r7 - 16]

.Ludivdi_return:
        LD     r6, [r7 - 4]
        LD     r5, [r7 - 2]
#ifdef __RISCC_NANO__
        NANO_RETURN64
#else
        ABI_RETURN64
#endif
        .size __udivdi3, . - __udivdi3
        .size __umoddi3, . - __umoddi3
        .size __udivmoddi4, . - __udivmoddi4

/*
 * Size-oriented constant shifts for the Min, Sys, and Nano profiles.
 *
 * Every rung is an input section, but its R_RISCC_NONE relocation keeps the
 * next rung live.  Therefore --gc-sections retains exactly the suffix entered
 * by a constant-count helper without adding a branch between fall-through
 * shifts.  The variable-count helpers are compact bounded loops, so using one
 * does not pull in a whole direction's staircase.
 */

#ifdef __RISCC_NANO__
#define SHIFT_RETURN JMP r6
#else
#define SHIFT_RETURN RET S7
#endif

        .macro SHIFT_LABEL name
        .global \name
        .hidden \name
        .type \name,@function
\name:
        .endm

        .macro SHL_STEP count, next
        .section .text.__riscc_shlhi\count,"ax",@progbits
        .p2align 1
        SHIFT_LABEL __riscc_shlhi\count
        ADD     r1, r1, r1
        .reloc . - 2, R_RISCC_NONE, \next
        .endm

        .section .text.__riscc_shlhi,"ax",@progbits
        .p2align 1
        SHIFT_LABEL __riscc_shlhi
        MOV     r0, r2
        ANDI    r0, 15
        BEQZ    .Lshlhi_done
.Lshlhi_loop:
        ADD     r1, r1, r1
        ADDI    r0, -1
        BNEZ    .Lshlhi_loop
.Lshlhi_done:
        SHIFT_RETURN

        SHL_STEP 15, __riscc_shlhi14
        SHL_STEP 14, __riscc_shlhi13
        SHL_STEP 13, __riscc_shlhi12
        SHL_STEP 12, __riscc_shlhi11
        SHL_STEP 11, __riscc_shlhi10
        SHL_STEP 10, __riscc_shlhi9
        SHL_STEP 9, __riscc_shlhi8
        SHL_STEP 8, __riscc_shlhi7
        SHL_STEP 7, __riscc_shlhi6
        SHL_STEP 6, __riscc_shlhi5
        SHL_STEP 5, __riscc_shlhi4
        SHL_STEP 4, __riscc_shlhi3
        SHL_STEP 3, __riscc_shlhi2
        SHL_STEP 2, __riscc_shlhi1
        SHL_STEP 1, __riscc_shlhi_return

        .section .text.__riscc_shlhi_return,"ax",@progbits
        .p2align 1
__riscc_shlhi_return:
        SHIFT_RETURN

        .macro LSHR_STEP count, next
        .section .text.__riscc_lshrhi\count,"ax",@progbits
        .p2align 1
        SHIFT_LABEL __riscc_lshrhi\count
        SRLI    r1, r1, 1
        .reloc . - 2, R_RISCC_NONE, \next
        .endm

        .section .text.__riscc_lshrhi,"ax",@progbits
        .p2align 1
        SHIFT_LABEL __riscc_lshrhi
        MOV     r0, r2
        ANDI    r0, 15
        BEQZ    .Llshrhi_done
.Llshrhi_loop:
        SRLI    r1, r1, 1
        ADDI    r0, -1
        BNEZ    .Llshrhi_loop
.Llshrhi_done:
        SHIFT_RETURN

        LSHR_STEP 15, __riscc_lshrhi14
        LSHR_STEP 14, __riscc_lshrhi13
        LSHR_STEP 13, __riscc_lshrhi12
        LSHR_STEP 12, __riscc_lshrhi11
        LSHR_STEP 11, __riscc_lshrhi10
        LSHR_STEP 10, __riscc_lshrhi9
        LSHR_STEP 9, __riscc_lshrhi8
        LSHR_STEP 8, __riscc_lshrhi7
        LSHR_STEP 7, __riscc_lshrhi6
        LSHR_STEP 6, __riscc_lshrhi5
        LSHR_STEP 5, __riscc_lshrhi4
        LSHR_STEP 4, __riscc_lshrhi3
        LSHR_STEP 3, __riscc_lshrhi2
        LSHR_STEP 2, __riscc_lshrhi1
        LSHR_STEP 1, __riscc_lshrhi_return

        .section .text.__riscc_lshrhi_return,"ax",@progbits
        .p2align 1
__riscc_lshrhi_return:
        SHIFT_RETURN

        .macro ASHR_STEP count, next
        .section .text.__riscc_ashrhi\count,"ax",@progbits
        .p2align 1
        SHIFT_LABEL __riscc_ashrhi\count
        SRAI    r1, r1, 1
        .reloc . - 2, R_RISCC_NONE, \next
        .endm

        .section .text.__riscc_ashrhi,"ax",@progbits
        .p2align 1
        SHIFT_LABEL __riscc_ashrhi
        MOV     r0, r2
        ANDI    r0, 15
        BEQZ    .Lashrhi_done
.Lashrhi_loop:
        SRAI    r1, r1, 1
        ADDI    r0, -1
        BNEZ    .Lashrhi_loop
.Lashrhi_done:
        SHIFT_RETURN

        ASHR_STEP 15, __riscc_ashrhi14
        ASHR_STEP 14, __riscc_ashrhi13
        ASHR_STEP 13, __riscc_ashrhi12
        ASHR_STEP 12, __riscc_ashrhi11
        ASHR_STEP 11, __riscc_ashrhi10
        ASHR_STEP 10, __riscc_ashrhi9
        ASHR_STEP 9, __riscc_ashrhi8
        ASHR_STEP 8, __riscc_ashrhi7
        ASHR_STEP 7, __riscc_ashrhi6
        ASHR_STEP 6, __riscc_ashrhi5
        ASHR_STEP 5, __riscc_ashrhi4
        ASHR_STEP 4, __riscc_ashrhi3
        ASHR_STEP 3, __riscc_ashrhi2
        ASHR_STEP 2, __riscc_ashrhi1
        ASHR_STEP 1, __riscc_ashrhi_return

        .section .text.__riscc_ashrhi_return,"ax",@progbits
        .p2align 1
__riscc_ashrhi_return:
        SHIFT_RETURN

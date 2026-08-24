/*
 * Size-oriented RC32 fixed-count shifts for Min and Sys.
 *
 * LLVM enters one rung for a large constant shift in a minsize function.
 * R_RISCC_NONE keeps only the required fall-through suffix live, allowing all
 * call sites in an image to share the same one-instruction-per-bit sequence.
 * Full emits its native shifts directly and does not reference this object.
 */

        .macro SHIFT_LABEL name
        .global \name
        .hidden \name
        .type \name,@function
\name:
        .endm

        .macro SHL_STEP count, next
        .section .text.__riscc_shlsi\count,"ax",@progbits
        .p2align 1
        SHIFT_LABEL __riscc_shlsi\count
        ADD     r1, r1, r1
        .reloc . - 2, R_RISCC_NONE, \next
        .endm

        SHL_STEP 31, __riscc_shlsi30
        SHL_STEP 30, __riscc_shlsi29
        SHL_STEP 29, __riscc_shlsi28
        SHL_STEP 28, __riscc_shlsi27
        SHL_STEP 27, __riscc_shlsi26
        SHL_STEP 26, __riscc_shlsi25
        SHL_STEP 25, __riscc_shlsi24
        SHL_STEP 24, __riscc_shlsi23
        SHL_STEP 23, __riscc_shlsi22
        SHL_STEP 22, __riscc_shlsi21
        SHL_STEP 21, __riscc_shlsi20
        SHL_STEP 20, __riscc_shlsi19
        SHL_STEP 19, __riscc_shlsi18
        SHL_STEP 18, __riscc_shlsi17
        SHL_STEP 17, __riscc_shlsi16
        SHL_STEP 16, __riscc_shlsi15
        SHL_STEP 15, __riscc_shlsi14
        SHL_STEP 14, __riscc_shlsi13
        SHL_STEP 13, __riscc_shlsi12
        SHL_STEP 12, __riscc_shlsi11
        SHL_STEP 11, __riscc_shlsi10
        SHL_STEP 10, __riscc_shlsi9
        SHL_STEP 9, __riscc_shlsi8
        SHL_STEP 8, __riscc_shlsi7
        SHL_STEP 7, __riscc_shlsi6
        SHL_STEP 6, __riscc_shlsi5
        SHL_STEP 5, __riscc_shlsi4
        SHL_STEP 4, __riscc_shlsi3
        SHL_STEP 3, __riscc_shlsi2
        SHL_STEP 2, __riscc_shlsi1
        SHL_STEP 1, __riscc_shlsi_return

        .section .text.__riscc_shlsi_return,"ax",@progbits
        .p2align 1
__riscc_shlsi_return:
        RET     S7

        .macro LSHR_STEP count, next
        .section .text.__riscc_lshrsi\count,"ax",@progbits
        .p2align 1
        SHIFT_LABEL __riscc_lshrsi\count
        SRLI    r1, r1, 1
        .reloc . - 2, R_RISCC_NONE, \next
        .endm

        LSHR_STEP 31, __riscc_lshrsi30
        LSHR_STEP 30, __riscc_lshrsi29
        LSHR_STEP 29, __riscc_lshrsi28
        LSHR_STEP 28, __riscc_lshrsi27
        LSHR_STEP 27, __riscc_lshrsi26
        LSHR_STEP 26, __riscc_lshrsi25
        LSHR_STEP 25, __riscc_lshrsi24
        LSHR_STEP 24, __riscc_lshrsi23
        LSHR_STEP 23, __riscc_lshrsi22
        LSHR_STEP 22, __riscc_lshrsi21
        LSHR_STEP 21, __riscc_lshrsi20
        LSHR_STEP 20, __riscc_lshrsi19
        LSHR_STEP 19, __riscc_lshrsi18
        LSHR_STEP 18, __riscc_lshrsi17
        LSHR_STEP 17, __riscc_lshrsi16
        LSHR_STEP 16, __riscc_lshrsi15
        LSHR_STEP 15, __riscc_lshrsi14
        LSHR_STEP 14, __riscc_lshrsi13
        LSHR_STEP 13, __riscc_lshrsi12
        LSHR_STEP 12, __riscc_lshrsi11
        LSHR_STEP 11, __riscc_lshrsi10
        LSHR_STEP 10, __riscc_lshrsi9
        LSHR_STEP 9, __riscc_lshrsi8
        LSHR_STEP 8, __riscc_lshrsi7
        LSHR_STEP 7, __riscc_lshrsi6
        LSHR_STEP 6, __riscc_lshrsi5
        LSHR_STEP 5, __riscc_lshrsi4
        LSHR_STEP 4, __riscc_lshrsi3
        LSHR_STEP 3, __riscc_lshrsi2
        LSHR_STEP 2, __riscc_lshrsi1
        LSHR_STEP 1, __riscc_lshrsi_return

        .section .text.__riscc_lshrsi_return,"ax",@progbits
        .p2align 1
__riscc_lshrsi_return:
        RET     S7

        .macro ASHR_STEP count, next
        .section .text.__riscc_ashrsi\count,"ax",@progbits
        .p2align 1
        SHIFT_LABEL __riscc_ashrsi\count
        SRAI    r1, r1, 1
        .reloc . - 2, R_RISCC_NONE, \next
        .endm

        ASHR_STEP 31, __riscc_ashrsi30
        ASHR_STEP 30, __riscc_ashrsi29
        ASHR_STEP 29, __riscc_ashrsi28
        ASHR_STEP 28, __riscc_ashrsi27
        ASHR_STEP 27, __riscc_ashrsi26
        ASHR_STEP 26, __riscc_ashrsi25
        ASHR_STEP 25, __riscc_ashrsi24
        ASHR_STEP 24, __riscc_ashrsi23
        ASHR_STEP 23, __riscc_ashrsi22
        ASHR_STEP 22, __riscc_ashrsi21
        ASHR_STEP 21, __riscc_ashrsi20
        ASHR_STEP 20, __riscc_ashrsi19
        ASHR_STEP 19, __riscc_ashrsi18
        ASHR_STEP 18, __riscc_ashrsi17
        ASHR_STEP 17, __riscc_ashrsi16
        ASHR_STEP 16, __riscc_ashrsi15
        ASHR_STEP 15, __riscc_ashrsi14
        ASHR_STEP 14, __riscc_ashrsi13
        ASHR_STEP 13, __riscc_ashrsi12
        ASHR_STEP 12, __riscc_ashrsi11
        ASHR_STEP 11, __riscc_ashrsi10
        ASHR_STEP 10, __riscc_ashrsi9
        ASHR_STEP 9, __riscc_ashrsi8
        ASHR_STEP 8, __riscc_ashrsi7
        ASHR_STEP 7, __riscc_ashrsi6
        ASHR_STEP 6, __riscc_ashrsi5
        ASHR_STEP 5, __riscc_ashrsi4
        ASHR_STEP 4, __riscc_ashrsi3
        ASHR_STEP 3, __riscc_ashrsi2
        ASHR_STEP 2, __riscc_ashrsi1
        ASHR_STEP 1, __riscc_ashrsi_return

        .section .text.__riscc_ashrsi_return,"ax",@progbits
        .p2align 1
__riscc_ashrsi_return:
        RET     S7

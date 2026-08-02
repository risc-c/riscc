/*
 * Size-oriented constant shifts for the Min and Nano profiles.
 *
 * Each public label enters a fall-through staircase at the requested count.
 * The first i16 argument and result both use r1, so calls need no register
 * shuffling.  Keep each direction in a separate section: --gc-sections can
 * discard the other two after this archive member is extracted.
 */

#ifdef __RISCC_NANO__
#define SHIFT_RETURN RET r6
#else
#define SHIFT_RETURN RETS
#endif

        .macro SHIFT_LABEL name
        .global \name
        .hidden \name
        .type \name,@function
\name:
        .endm

        .section .text.__riscc_shlhi,"ax",@progbits
        .p2align 1

        SHIFT_LABEL __riscc_shlhi15
        ADD     r1, r1, r1
        SHIFT_LABEL __riscc_shlhi14
        ADD     r1, r1, r1
        SHIFT_LABEL __riscc_shlhi13
        ADD     r1, r1, r1
        SHIFT_LABEL __riscc_shlhi12
        ADD     r1, r1, r1
        SHIFT_LABEL __riscc_shlhi11
        ADD     r1, r1, r1
        SHIFT_LABEL __riscc_shlhi10
        ADD     r1, r1, r1
        SHIFT_LABEL __riscc_shlhi9
        ADD     r1, r1, r1
        SHIFT_LABEL __riscc_shlhi8
        ADD     r1, r1, r1
        SHIFT_LABEL __riscc_shlhi7
        ADD     r1, r1, r1
        SHIFT_LABEL __riscc_shlhi6
        ADD     r1, r1, r1
        SHIFT_LABEL __riscc_shlhi5
        ADD     r1, r1, r1
        SHIFT_LABEL __riscc_shlhi4
        ADD     r1, r1, r1
        SHIFT_LABEL __riscc_shlhi3
        ADD     r1, r1, r1
        SHIFT_LABEL __riscc_shlhi2
        ADD     r1, r1, r1
        SHIFT_LABEL __riscc_shlhi1
        ADD     r1, r1, r1
        SHIFT_RETURN

        .section .text.__riscc_lshrhi,"ax",@progbits
        .p2align 1

        SHIFT_LABEL __riscc_lshrhi15
        SRLI    r1, r1, 1
        SHIFT_LABEL __riscc_lshrhi14
        SRLI    r1, r1, 1
        SHIFT_LABEL __riscc_lshrhi13
        SRLI    r1, r1, 1
        SHIFT_LABEL __riscc_lshrhi12
        SRLI    r1, r1, 1
        SHIFT_LABEL __riscc_lshrhi11
        SRLI    r1, r1, 1
        SHIFT_LABEL __riscc_lshrhi10
        SRLI    r1, r1, 1
        SHIFT_LABEL __riscc_lshrhi9
        SRLI    r1, r1, 1
        SHIFT_LABEL __riscc_lshrhi8
        SRLI    r1, r1, 1
        SHIFT_LABEL __riscc_lshrhi7
        SRLI    r1, r1, 1
        SHIFT_LABEL __riscc_lshrhi6
        SRLI    r1, r1, 1
        SHIFT_LABEL __riscc_lshrhi5
        SRLI    r1, r1, 1
        SHIFT_LABEL __riscc_lshrhi4
        SRLI    r1, r1, 1
        SHIFT_LABEL __riscc_lshrhi3
        SRLI    r1, r1, 1
        SHIFT_LABEL __riscc_lshrhi2
        SRLI    r1, r1, 1
        SHIFT_LABEL __riscc_lshrhi1
        SRLI    r1, r1, 1
        SHIFT_RETURN

        .section .text.__riscc_ashrhi,"ax",@progbits
        .p2align 1

        SHIFT_LABEL __riscc_ashrhi15
        SRAI    r1, r1, 1
        SHIFT_LABEL __riscc_ashrhi14
        SRAI    r1, r1, 1
        SHIFT_LABEL __riscc_ashrhi13
        SRAI    r1, r1, 1
        SHIFT_LABEL __riscc_ashrhi12
        SRAI    r1, r1, 1
        SHIFT_LABEL __riscc_ashrhi11
        SRAI    r1, r1, 1
        SHIFT_LABEL __riscc_ashrhi10
        SRAI    r1, r1, 1
        SHIFT_LABEL __riscc_ashrhi9
        SRAI    r1, r1, 1
        SHIFT_LABEL __riscc_ashrhi8
        SRAI    r1, r1, 1
        SHIFT_LABEL __riscc_ashrhi7
        SRAI    r1, r1, 1
        SHIFT_LABEL __riscc_ashrhi6
        SRAI    r1, r1, 1
        SHIFT_LABEL __riscc_ashrhi5
        SRAI    r1, r1, 1
        SHIFT_LABEL __riscc_ashrhi4
        SRAI    r1, r1, 1
        SHIFT_LABEL __riscc_ashrhi3
        SRAI    r1, r1, 1
        SHIFT_LABEL __riscc_ashrhi2
        SRAI    r1, r1, 1
        SHIFT_LABEL __riscc_ashrhi1
        SRAI    r1, r1, 1
        SHIFT_RETURN

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
        SHRI    r1, r1, 1
        SHIFT_LABEL __riscc_lshrhi14
        SHRI    r1, r1, 1
        SHIFT_LABEL __riscc_lshrhi13
        SHRI    r1, r1, 1
        SHIFT_LABEL __riscc_lshrhi12
        SHRI    r1, r1, 1
        SHIFT_LABEL __riscc_lshrhi11
        SHRI    r1, r1, 1
        SHIFT_LABEL __riscc_lshrhi10
        SHRI    r1, r1, 1
        SHIFT_LABEL __riscc_lshrhi9
        SHRI    r1, r1, 1
        SHIFT_LABEL __riscc_lshrhi8
        SHRI    r1, r1, 1
        SHIFT_LABEL __riscc_lshrhi7
        SHRI    r1, r1, 1
        SHIFT_LABEL __riscc_lshrhi6
        SHRI    r1, r1, 1
        SHIFT_LABEL __riscc_lshrhi5
        SHRI    r1, r1, 1
        SHIFT_LABEL __riscc_lshrhi4
        SHRI    r1, r1, 1
        SHIFT_LABEL __riscc_lshrhi3
        SHRI    r1, r1, 1
        SHIFT_LABEL __riscc_lshrhi2
        SHRI    r1, r1, 1
        SHIFT_LABEL __riscc_lshrhi1
        SHRI    r1, r1, 1
        SHIFT_RETURN

        .section .text.__riscc_ashrhi,"ax",@progbits
        .p2align 1

        SHIFT_LABEL __riscc_ashrhi15
        SARI    r1, r1, 1
        SHIFT_LABEL __riscc_ashrhi14
        SARI    r1, r1, 1
        SHIFT_LABEL __riscc_ashrhi13
        SARI    r1, r1, 1
        SHIFT_LABEL __riscc_ashrhi12
        SARI    r1, r1, 1
        SHIFT_LABEL __riscc_ashrhi11
        SARI    r1, r1, 1
        SHIFT_LABEL __riscc_ashrhi10
        SARI    r1, r1, 1
        SHIFT_LABEL __riscc_ashrhi9
        SARI    r1, r1, 1
        SHIFT_LABEL __riscc_ashrhi8
        SARI    r1, r1, 1
        SHIFT_LABEL __riscc_ashrhi7
        SARI    r1, r1, 1
        SHIFT_LABEL __riscc_ashrhi6
        SARI    r1, r1, 1
        SHIFT_LABEL __riscc_ashrhi5
        SARI    r1, r1, 1
        SHIFT_LABEL __riscc_ashrhi4
        SARI    r1, r1, 1
        SHIFT_LABEL __riscc_ashrhi3
        SARI    r1, r1, 1
        SHIFT_LABEL __riscc_ashrhi2
        SARI    r1, r1, 1
        SHIFT_LABEL __riscc_ashrhi1
        SARI    r1, r1, 1
        SHIFT_RETURN

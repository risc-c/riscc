/* Full-range transfer between independently discardable division sections.
 * R0 must be dead; the incoming return link is preserved. RC32 Sys/Full
 * links may shorten the transfer and discard its private target word. */
#if defined(__OPTIMIZE_SIZE__) && \
    (defined(__RISCC_SYS__) || defined(__RISCC_FULL__))
// Without direct long transfers, entry overhead outweighs wrapper GC savings
// for short divisions. Keep the grouped layout on Min and Nano.
#define RISCC_SPLIT_DIV_SECTIONS
#endif

        .macro DIV_TAIL target
#ifdef __RISCC_RC32__
#if defined(__RISCC_SYS__) || defined(__RISCC_FULL__)
        .reloc  ., R_RISCC_RELAX_TAIL, .Ldiv_tail_target\@
#endif
        LDPC    r0, .Ldiv_tail_target\@
        JMP     r0
        .p2align 2
.Ldiv_tail_target\@:
#if defined(__RISCC_SYS__) || defined(__RISCC_FULL__)
        .long   call_target(\target)
#else
        .long   \target
#endif
#elif defined(__RISCC_SYS__) || defined(__RISCC_FULL__)
        JALL    s0, \target
#else
        LDI16   r0, \target
        JMP     r0
#endif
        .endm

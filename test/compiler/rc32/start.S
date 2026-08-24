// Minimal RC32 startup with a trailing local LDPC pool. The same object is
// valid for Min, Sys, and Full because reset and the public call use compact
// base forms.

        .section .vectors,"ax",@progbits
        .p2align 1
        .global __vectors
__vectors:
#if defined(__RISCC_SYS__) || defined(__RISCC_FULL__)
        JMPL    _start
        // The focused ABI test never enables IRQs; halt if one is injected.
        HALT
        NOP
#else
        JMP8    _start
#endif

        .section .text._start,"ax",@progbits
        .p2align 1
        .global _start
        .type _start,@function
_start:
        LDPC    r7, .Lstack
        LDPC    r1, .Lzero_start
        LDPC    r2, .Lzero_end
        LDI     r3, 0
        SUB     r0, r2, r1
        BEQZ    .Lcleared
.Lclear:
        ST      r3, [r1 + 0]
        ADDI    r1, 4
        ADDI    r0, -4
        BNEZ    .Lclear
.Lcleared:
#if defined(__RISCC_SYS__) || defined(__RISCC_FULL__)
        .reloc  ., R_RISCC_RELAX_CALL, .Lmain
#endif
        LDPC    r0, .Lmain
        JALR    s7, r0
        HALT
.Lstart_end:
        .size _start, .Lstart_end - _start

        .p2align 2
.Lstack:
        .long   __stack_top
.Lzero_start:
        .long   __zero_start
.Lzero_end:
        .long   __zero_end
.Lmain:
#if defined(__RISCC_SYS__) || defined(__RISCC_FULL__)
        .long   call_target(main)
#else
        .long   main
#endif

        .section .data.riscc_current_context,"aw",@progbits
        .p2align 2
        .global __riscc_current_context
        .type __riscc_current_context,@object
__riscc_current_context:
        .long   __tls_start
        .size __riscc_current_context, 4

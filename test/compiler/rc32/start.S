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
        LDPC    r0, .Ltls
        MTS     s2, r0
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
        LDPC    r0, .Lmain
        JALR    s7, r0
        HALT
.Lstart_end:
        .size _start, .Lstart_end - _start

        .p2align 2
.Lstack:
        .long   __stack_top
.Ltls:
        .long   __tls_start
.Lzero_start:
        .long   __zero_start
.Lzero_end:
        .long   __zero_end
.Lmain:
        .long   main

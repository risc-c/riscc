// Minimal freestanding RC32 startup. Initialized data is already present in
// memory; the local LDPC pool follows the non-returning startup code.

        .section .text._start,"ax",@progbits
        .p2align 1
        .global _start
        .type _start,@function
        .extern main
        .extern __zero_start
        .extern __zero_end
        .extern __tls_start
        .extern __stack_top
_start:
        LDPC    r7, .Lstack_top
        LDPC    r0, .Ltls_start
        MTS     s2, r0
        LDPC    r1, .Lzero_start
        LDPC    r2, .Lzero_end
        LDI     r3, 0

        SUB     r0, r2, r1
        BEQZ    .Lzero_done
.Lclear_zero:
        ST      r3, [r1+0]
        ADDI    r1, 4
        ADDI    r0, -4
        BNEZ    .Lclear_zero

.Lzero_done:
        LDPC    r0, .Lmain
        JALR    S7, r0
        HALT
.Lstart_end:
        .size _start, .Lstart_end - _start

        .p2align 2
.Lstack_top:
        .long   __stack_top
.Ltls_start:
        .long   __tls_start
.Lzero_start:
        .long   __zero_start
.Lzero_end:
        .long   __zero_end
.Lmain:
        .long   main

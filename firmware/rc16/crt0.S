// Minimal freestanding RC16 startup. Initialized data is already present in
// data memory for both unified and split linker layouts.

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
        LDI16   r7, __stack_top
        LDI16   r0, __tls_start
        MTS     s2, r0
        LDI16   r1, __zero_start
        LDI16   r2, __zero_end
        LDI     r3, 0
        SUB     r0, r2, r1
        BEQZ    .Lzero_done
.Lclear_zero:
        ST      r3, [r1+0]
        ADDI    r1, 2
        ADDI    r0, -2
        BNEZ    .Lclear_zero

.Lzero_done:
#ifdef __RISCC_MIN__
        LDI16   r0, main
        JALR    S7, r0
#else
        JALL    S7, main
#endif
        HALT
        .size _start, . - _start

// Minimal freestanding startup.  Initialized data is already present in data
// memory for both the unified and split linker layouts.

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
#ifndef __RISCC_NANO__
        LDI16   r0, __tls_start
        MTS     s2, r0
#endif
        LDI16   r1, __zero_start
        LDI16   r2, __zero_end
        LDI     r3, 0

.Lclear_zero:
        SUB     r0, r1, r2
        BEQZ    .Lzero_done
        STW     r3, [r1+0]
        ADDI    r1, 2
        JMP8    .Lclear_zero

.Lzero_done:
#ifdef __RISCC_NANO__
        LDI16   r0, code(main)
        JAL     r6, r0
#elif defined(__RISCC_MIN__)
        LDI16   r0, code(main)
        CALL    r0
#else
        CALL16  main
#endif
        HALT
        .size _start, . - _start

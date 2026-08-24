// Minimal freestanding Nano startup. Nano has no TLS system register.

        .section .text._start,"ax",@progbits
        .p2align 1
        .global _start
        .type _start,@function
        .extern main
        .extern __zero_start
        .extern __zero_end
        .extern __stack_top
_start:
        LDI16   r7, __stack_top
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
        LDI16   r0, main
        JALR    r6, r0
        HALT
        .size _start, . - _start

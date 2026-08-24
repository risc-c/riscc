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

        // The active TLS/context anchor is mutable runtime state rather than
        // an asynchronously reserved S register.  Keep it in initialized
        // data so ROM-based startup does not need to write its own image.
        .section .data.riscc_current_context,"aw",@progbits
        .p2align 1
        .global __riscc_current_context
        .type __riscc_current_context,@object
__riscc_current_context:
        .short  __tls_start
        .size __riscc_current_context, 2

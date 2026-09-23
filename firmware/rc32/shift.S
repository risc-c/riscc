// RC32 variable-shift helpers. RC32 Min/Sys provide one-bit right
// shifts and base ADD; iterating those forms avoids recursively lowering the
// helper bodies back to the same compiler calls.
// Size-optimized functions use these loops. Speed builds use the computed
// entry points in constant_shift.S instead.

        .macro RC32_FUNCTION name
        .section .text.\name,"ax",@progbits
        .p2align 1
        .global \name
        .hidden \name
        .type \name,@function
\name:
        .endm

        RC32_FUNCTION __ashlsi3
        MOV     r0, r2
        BEQZ    .Lashl_done
.Lashl_loop:
        ADD     r1, r1, r1
        ADDI    r0, -1
        BNEZ    .Lashl_loop
.Lashl_done:
        RET     s7
        .size __ashlsi3, . - __ashlsi3

        RC32_FUNCTION __lshrsi3
        MOV     r0, r2
        BEQZ    .Llshr_done
.Llshr_loop:
        SRLI    r1, r1, 1
        ADDI    r0, -1
        BNEZ    .Llshr_loop
.Llshr_done:
        RET     s7
        .size __lshrsi3, . - __lshrsi3

        RC32_FUNCTION __ashrsi3
        MOV     r0, r2
        BEQZ    .Lashr_done
.Lashr_loop:
        SRAI    r1, r1, 1
        ADDI    r0, -1
        BNEZ    .Lashr_loop
.Lashr_done:
        RET     s7
        .size __ashrsi3, . - __ashrsi3

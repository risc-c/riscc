// RC32 multiply and unsigned divide/remainder helpers.

        .macro RC32_FUNCTION name
        .section .text.\name,"ax",@progbits
        .p2align 1
        .global \name
        .hidden \name
        .type \name,@function
\name:
        .endm

        RC32_FUNCTION __mulsi3
        LDI     r3, 0
.Lmul_loop:
        MOV     r0, r2
        BEQZ    .Lmul_done
        MOV     r0, r2
        ANDI    r0, 1
        BEQZ    .Lmul_skip_add
        ADD     r3, r3, r1
.Lmul_skip_add:
        ADD     r1, r1, r1
        SRLI    r2, r2, 1
        JMP8    .Lmul_loop
.Lmul_done:
        MOV     r1, r3
        RET     s7
        .size __mulsi3, . - __mulsi3

        // S3 selects quotient (0), remainder (1), or quotient plus a stored
        // remainder (2). It is caller-saved by ABI v0.
        .section .text.__udivmodsi4,"ax",@progbits
        .p2align 1
        .global __divsi3
        .hidden __divsi3
        .type __divsi3,@function
__divsi3:
        LDI     r0, 0
        MTS     s3, r0
        LDI     r3, 0
        JMP8    .Lsdiv_flags
        .size __divsi3, . - __divsi3

        .global __modsi3
        .hidden __modsi3
        .type __modsi3,@function
__modsi3:
        LDI     r0, 1
        MTS     s3, r0
        LDI     r3, 0
        JMP8    .Lsdiv_flags
        .size __modsi3, . - __modsi3

        .global __divmodsi4
        .hidden __divmodsi4
        .type __divmodsi4,@function
__divmodsi4:
        LDI     r0, 2
        MTS     s3, r0

.Lsdiv_flags:
        LDI     r0, 0                  // bit 2: numerator, bit 3: divisor
        MTS     s4, r0
        MOV     r0, r1
        BGEZ    .Lsdiv_numerator_positive
        MFS     r0, s4
        ORI     r0, 4
        MTS     s4, r0
.Lsdiv_numerator_positive:
        MOV     r0, r2
        BGEZ    .Ludiv_common
        MFS     r0, s4
        ORI     r0, 8
        MTS     s4, r0
        JMP8    .Ludiv_common
        .size __divmodsi4, . - __divmodsi4

        .global __udivsi3
        .hidden __udivsi3
        .type __udivsi3,@function
__udivsi3:
        LDI     r0, 0
        MTS     s3, r0
        MTS     s4, r0
        LDI     r3, 0
        JMP8    .Ludiv_common
        .size __udivsi3, . - __udivsi3

        .global __umodsi3
        .hidden __umodsi3
        .type __umodsi3,@function
__umodsi3:
        LDI     r0, 1
        MTS     s3, r0
        LDI     r0, 0
        MTS     s4, r0
        LDI     r3, 0
        JMP8    .Ludiv_common
        .size __umodsi3, . - __umodsi3

        .global __udivmodsi4
        .hidden __udivmodsi4
        .type __udivmodsi4,@function
__udivmodsi4:
        LDI     r0, 2
        MTS     s3, r0
        LDI     r0, 0
        MTS     s4, r0

.Ludiv_common:
        ADDI    r7, -12
        ST      r4, [r7 + 0]
        ST      r5, [r7 + 4]
        ST      r6, [r7 + 8]

        MFS     r0, s4
        ANDI    r0, 4
        BEQZ    .Ludiv_numerator_ready
        LDI     r0, 0
        SUB     r1, r0, r1
.Ludiv_numerator_ready:
        MFS     r0, s4
        ANDI    r0, 8
        BEQZ    .Ludiv_denominator_ready
        LDI     r0, 0
        SUB     r2, r0, r2
.Ludiv_denominator_ready:

        LDI     r4, 0                  // remainder
        LDI     r5, 0                  // quotient
        LDI     r6, 32
        MOV     r0, r2
        BEQZ    .Ludiv_zero
.Ludiv_loop:
        ADD     r4, r4, r4
        LDI     r0, 0
        SLT     r0, r1, r0             // old numerator top bit
        OR      r4, r4, r0
        ADD     r1, r1, r1
        ADD     r5, r5, r5
        SLTU    r0, r4, r2
        BNEZ    .Ludiv_no_subtract
        SUB     r4, r4, r2
        ORI     r5, 1
.Ludiv_no_subtract:
        ADDI    r6, -1
        MOV     r0, r6
        BNEZ    .Ludiv_loop
        JMP8    .Ludiv_finish

.Ludiv_zero:
        /* Match the wide helpers: quotient zero, remainder numerator. */
        MOV     r4, r1

.Ludiv_finish:
        MFS     r0, s4
        ANDI    r0, 4
        BEQZ    .Ludiv_remainder_sign_ready
        LDI     r0, 0
        SUB     r4, r0, r4
.Ludiv_remainder_sign_ready:
        MFS     r0, s4
        ANDI    r0, 12
        BEQZ    .Ludiv_quotient_sign_ready
        CMPI    r0, 12
        BEQZ    .Ludiv_quotient_sign_ready
        LDI     r0, 0
        SUB     r5, r0, r5
.Ludiv_quotient_sign_ready:
        MFS     r0, s3
        BEQZ    .Ludiv_quotient
        ADDI    r0, -1
        BEQZ    .Ludiv_remainder
        MOV     r0, r3
        BEQZ    .Ludiv_quotient
        ST      r4, [r3 + 0]
.Ludiv_quotient:
        MOV     r1, r5
        JMP8    .Ludiv_return
.Ludiv_remainder:
        MOV     r1, r4
.Ludiv_return:
        LD      r4, [r7 + 0]
        LD      r5, [r7 + 4]
        LD      r6, [r7 + 8]
        ADDI    r7, 12
        RET     s7
        .size __udivmodsi4, . - __udivmodsi4

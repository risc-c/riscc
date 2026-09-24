// RC32 multiply and signed/unsigned divide/remainder helpers.

        .macro RC32_FUNCTION name
        .section .text.\name,"ax",@progbits
        .p2align 1
        .global \name
        .hidden \name
        .type \name,@function
\name:
        .endm

        RC32_FUNCTION __mulsi3
        MOV     r0, r2
        LDI     r3, 0
        BEQZ    .Lmul_done
.Lmul_loop:
        ANDI    r0, 1
        BEQZ    .Lmul_skip_add
        ADD     r3, r3, r1
.Lmul_skip_add:
        SRLI    r2, r2, 1
        MOV     r0, r2
        ADD     r1, r1, r1
        BNEZ    .Lmul_loop
.Lmul_done:
        MOV     r1, r3
        RET     s7
        .size __mulsi3, . - __mulsi3

        // S4 holds result mode in bits 0..1 (quotient, remainder, or both)
        // and the original operand signs in bits 2..3. S2..S4 are caller-saved.
        .section .text.__udivmodsi4,"ax",@progbits
        .p2align 1
        .global __divsi3
        .hidden __divsi3
        .type __divsi3,@function
__divsi3:
        OR      r0, r1, r2
        BLTZ    .Lsdiv_quotient
        .size __divsi3, . - __divsi3

        // Nonnegative signed operands share the unsigned fast path.
        .global __udivsi3
        .hidden __udivsi3
        .type __udivsi3,@function
__udivsi3:
        // Quotient-only entries need no mode or sign bookkeeping here.
        // n/2 < d proves d is nonzero and the quotient is zero or one.
        SRLI    r0, r1, 1
        SLTU    r0, r0, r2
        BEQZ    .Ludiv_large_quotient
        SLTU    r1, r1, r2
        XORI    r1, 1
        RET     s7
.Ludiv_large_quotient:
        MOV     r0, r2
        BEQZ    .Ludiv_return_zero
        CMPI    r2, 1
        BEQZ    .Ludiv_return
        LDI     r0, 0
        MTS     s4, r0
        JMP8    .Ludiv_normalize
.Ludiv_return_zero:
        LDI     r1, 0
        RET     s7
        .size __udivsi3, . - __udivsi3

.Lsdiv_quotient:
        LDI     r0, 0
        MTS     s4, r0
        JMP8    .Lsdiv_flags

        .global __modsi3
        .hidden __modsi3
        .type __modsi3,@function
__modsi3:
        LDI     r0, 1
        MTS     s4, r0
        JMP8    .Lsdiv_flags
        .size __modsi3, . - __modsi3

        .global __divmodsi4
        .hidden __divmodsi4
        .type __divmodsi4,@function
__divmodsi4:
        LDI     r0, 2
        MTS     s4, r0

.Lsdiv_flags:
        OR      r0, r1, r2
        BGEZ    .Ludiv_common         // both operands are nonnegative
        MOV     r0, r1
        BGEZ    .Lsdiv_numerator_positive
        LDI     r0, 0
        SUB     r1, r0, r1
        MFS     r0, s4
        ORI     r0, 4
        MTS     s4, r0
.Lsdiv_numerator_positive:
        MOV     r0, r2
        BGEZ    .Ludiv_common
        LDI     r0, 0
        SUB     r2, r0, r2
        MFS     r0, s4
        ORI     r0, 8
        MTS     s4, r0
        JMP8    .Ludiv_common
        .size __divmodsi4, . - __divmodsi4

        .global __umodsi3
        .hidden __umodsi3
        .type __umodsi3,@function
__umodsi3:
        LDI     r0, 1
        MTS     s4, r0
        JMP8    .Ludiv_common
        .size __umodsi3, . - __umodsi3

        .global __udivmodsi4
        .hidden __udivmodsi4
        .type __udivmodsi4,@function
__udivmodsi4:
        LDI     r0, 2
        MTS     s4, r0

.Ludiv_common:
        // Common cases need no working-register saves or division rounds.
        MOV     r0, r2
        BEQZ    .Ludiv_quotient_zero   // runtime zero-divisor convention
        SLTU    r0, r1, r2
        BNEZ    .Ludiv_quotient_zero
        CMPI    r2, 1
        BEQZ    .Ludiv_divisor_one
        SRLI    r0, r1, 1             // numerator / 2 avoids divisor overflow
        SLTU    r0, r0, r2
        BNEZ    .Ludiv_quotient_one    // divisor <= numerator < 2 * divisor

.Ludiv_normalize:
        MTS     s2, r4
        MTS     s3, r6
        MOV     r4, r1                 // remainder
        SRLI    r1, r1, 1             // alignment limit, then quotient
        LDI     r6, 1                  // current quotient bit

        // Quotient >= 2. Align the divisor, then process only useful bits.
.Ludiv_align:
        ADD     r2, r2, r2
        SLTU    r0, r1, r2
        ADD     r6, r6, r6
        BEQZ    .Ludiv_align
        LDI     r1, 0
.Ludiv_loop:
        SLTU    r0, r4, r2
        BNEZ    .Ludiv_no_subtract
        SUB     r4, r4, r2
        OR      r1, r1, r6
.Ludiv_no_subtract:
        SRLI    r6, r6, 1
        MOV     r0, r6
        SRLI    r2, r2, 1
        BNEZ    .Ludiv_loop
        MOV     r2, r4
        MFS     r4, s2
        MFS     r6, s3
        JMP8    .Ludiv_finish

.Ludiv_quotient_zero:
        MOV     r2, r1
        LDI     r1, 0
        JMP8    .Ludiv_finish
.Ludiv_quotient_one:
        SUB     r2, r1, r2
        LDI     r1, 1
        JMP8    .Ludiv_finish
.Ludiv_divisor_one:
        LDI     r2, 0

.Ludiv_finish:
        // R1 is the quotient and R2 the remainder on every path.
        MFS     r0, s4
        BEQZ    .Ludiv_return          // unsigned or positive quotient
        ANDI    r0, 4
        BEQZ    .Ludiv_remainder_sign_ready
        LDI     r0, 0
        SUB     r2, r0, r2
.Ludiv_remainder_sign_ready:
        MFS     r0, s4
        ANDI    r0, 12
        BEQZ    .Ludiv_quotient_sign_ready
        CMPI    r0, 12
        BEQZ    .Ludiv_quotient_sign_ready
        LDI     r0, 0
        SUB     r1, r0, r1
.Ludiv_quotient_sign_ready:
        MFS     r0, s4
        ANDI    r0, 3
        BEQZ    .Ludiv_return
        ADDI    r0, -1
        BEQZ    .Ludiv_remainder
        MOV     r0, r3
        BEQZ    .Ludiv_return
        ST      r2, [r3 + 0]
.Ludiv_return:
        RET     s7
.Ludiv_remainder:
        MOV     r1, r2
        RET     s7
        .size __udivmodsi4, . - __udivmodsi4

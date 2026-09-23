/* RC32 unsigned 64-bit divide, remainder, and combined helper. */

        .section .text.__udivmoddi4,"ax",@progbits
        .p2align 1
        .global __divdi3
        .hidden __divdi3
        .type __divdi3,@function
__divdi3:
        LDI     r0, 0
        MTS     s4, r0
        JMP8    .Lsdivdi_flags
        .size __divdi3, . - __divdi3

        .global __moddi3
        .hidden __moddi3
        .type __moddi3,@function
__moddi3:
        LDI     r0, 1
        MTS     s4, r0
        JMP8    .Lsdivdi_flags
        .size __moddi3, . - __moddi3

        .global __divmoddi4
        .hidden __divmoddi4
        .type __divmoddi4,@function
__divmoddi4:
        LDI     r0, 2
        MTS     s4, r0

.Lsdivdi_flags:
        MOV     r0, r2
        BGEZ    .Lsdivdi_numerator_positive
        MFS     r0, s4
        ORI     r0, 4
        MTS     s4, r0
.Lsdivdi_numerator_positive:
        LD      r0, [r7 + 4]
        BGEZ    .Ludivdi_common
        MFS     r0, s4
        ORI     r0, 8
        MTS     s4, r0
        JMP8    .Ludivdi_common
        .size __divmoddi4, . - __divmoddi4

        .global __udivdi3
        .hidden __udivdi3
        .type __udivdi3,@function
__udivdi3:
        LDI     r0, 0
        MTS     s4, r0
        JMP8    .Ludivdi_common
        .size __udivdi3, . - __udivdi3

        .global __umoddi3
        .hidden __umoddi3
        .type __umoddi3,@function
__umoddi3:
        LDI     r0, 1
        MTS     s4, r0
        JMP8    .Ludivdi_common
        .size __umoddi3, . - __umoddi3

        .global __udivmoddi4
        .hidden __udivmoddi4
        .type __udivmoddi4,@function
__udivmoddi4:
        LDI     r0, 2
        MTS     s4, r0

.Ludivdi_common:
        /* The divisor and optional remainder pointer are stack arguments. */
        MTS     s2, r4
        ADDI    r7, -8
        ST      r5, [r7 + 0]
        ST      r6, [r7 + 4]
        LD      r5, [r7 + 8]
        LD      r6, [r7 + 12]

        MFS     r0, s4
        ANDI    r0, 4
        BEQZ    .Ludivdi_numerator_ready
        LDI     r0, 0
        SLTU    r3, r0, r1             // low-word borrow for two-word negation
        SUB     r1, r0, r1
        SUB     r2, r0, r2
        SUB     r2, r2, r3
.Ludivdi_numerator_ready:
        MFS     r0, s4
        ANDI    r0, 8
        BEQZ    .Ludivdi_denominator_ready
        LDI     r0, 0
        SLTU    r3, r0, r5
        SUB     r5, r0, r5
        SUB     r6, r0, r6
        SUB     r6, r6, r3
.Ludivdi_denominator_ready:
        MOV     r3, r1                 // remainder low
        MOV     r4, r2                 // remainder high
        OR      r0, r5, r6
        BEQZ    .Ludivdi_zero
        SLTU    r0, r4, r6
        BNEZ    .Ludivdi_zero
        SUB     r0, r4, r6
        BNEZ    .Ludivdi_nonzero
        SLTU    r0, r3, r5
        BNEZ    .Ludivdi_zero
.Ludivdi_nonzero:
        MOV     r0, r6
        BNEZ    .Ludivdi_try_one
        CMPI    r5, 1
        BEQZ    .Ludivdi_divisor_one
.Ludivdi_try_one:
        /* n >= d. Subtract once, then test n-d < d without overflowing 2*d. */
        SLTU    r0, r3, r5
        SUB     r3, r3, r5
        SUB     r4, r4, r6
        SUB     r4, r4, r0
        SLTU    r0, r4, r6
        BNEZ    .Ludivdi_quotient_one
        SUB     r0, r4, r6
        BNEZ    .Ludivdi_start
        SLTU    r0, r3, r5
        BNEZ    .Ludivdi_quotient_one

.Ludivdi_start:
        /* If the upper word is smaller than d, the quotient fits 32 bits.
         * Start with that word as the remainder and divide the lower word. */
        MOV     r3, r2
        LDI     r4, 0
        MOV     r0, r6
        BNEZ    .Ludivdi_low_word
        SLTU    r0, r2, r5
        BNEZ    .Ludivdi_low_word
        LDI     r3, 0
        LDI     r0, 64
        JMP8    .Ludivdi_count
.Ludivdi_low_word:
        MOV     r2, r1
        LDI     r1, 0
        LDI     r0, 32
.Ludivdi_count:
        MTS     s3, r0
.Ludivdi_loop:
        /* Shift remainder:numerator; r1:r2 becomes the quotient in place. */
        FSL1    r4, r3
        FSL1    r3, r2
        FSL1    r2, r1
        ADD     r1, r1, r1

        SLTU    r0, r4, r6
        BNEZ    .Ludivdi_keep
        SUB     r0, r4, r6
        BNEZ    .Ludivdi_subtract
        SLTU    r0, r3, r5
        BNEZ    .Ludivdi_keep
.Ludivdi_subtract:
        SLTU    r0, r3, r5
        SUB     r3, r3, r5
        SUB     r4, r4, r6
        SUB     r4, r4, r0
        ORI     r1, 1
.Ludivdi_keep:
        MFS     r0, s3
        ADDI    r0, -1
        MTS     s3, r0
        BNEZ    .Ludivdi_loop
        JMP8    .Ludivdi_finish

.Ludivdi_divisor_one:
        LDI     r3, 0
        LDI     r4, 0
        JMP8    .Ludivdi_finish
.Ludivdi_quotient_one:
        LDI     r1, 1
        LDI     r2, 0
        JMP8    .Ludivdi_finish
.Ludivdi_zero:
        /* Match the runtime convention: quotient zero, remainder numerator. */
        LDI     r1, 0
        LDI     r2, 0

.Ludivdi_finish:
        MFS     r0, s4
        ANDI    r0, 4
        BEQZ    .Ludivdi_remainder_sign_ready
        LDI     r0, 0
        SLTU    r5, r0, r3
        SUB     r3, r0, r3
        SUB     r4, r0, r4
        SUB     r4, r4, r5
.Ludivdi_remainder_sign_ready:
        MFS     r0, s4
        ANDI    r0, 12
        BEQZ    .Ludivdi_quotient_sign_ready
        CMPI    r0, 12
        BEQZ    .Ludivdi_quotient_sign_ready
        LDI     r0, 0
        SLTU    r5, r0, r1
        SUB     r1, r0, r1
        SUB     r2, r0, r2
        SUB     r2, r2, r5
.Ludivdi_quotient_sign_ready:
        MFS     r0, s4
        ANDI    r0, 3
        BEQZ    .Ludivdi_return
        ADDI    r0, -1
        BEQZ    .Ludivdi_remainder
        LD      r0, [r7 + 16]
        BEQZ    .Ludivdi_return
        ST      r3, [r0 + 0]
        ST      r4, [r0 + 4]
        JMP8    .Ludivdi_return
.Ludivdi_remainder:
        MOV     r1, r3
        MOV     r2, r4
.Ludivdi_return:
        MFS     r4, s2
        LD      r5, [r7 + 0]
        LD      r6, [r7 + 4]
        ADDI    r7, 8
        RET     S7
        .size __udivmoddi4, . - __udivmoddi4

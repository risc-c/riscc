; Paired RC32 multiplication, including overlapping sources and R0 results.
.text
.global start
start:
        LDPC    r1, left
        LDPC    r2, right
        MULHU   r3, r1, r2
        LDPC    r4, product_low
        SUB     r0, r3, r4
        BNEZ    fail
        LDPC    r4, product_high
        SUB     r0, r1, r4
        BNEZ    fail

        ; rb may alias the high destination (ra).
        LDPC    r1, all_ones
        MULHU   r3, r1, r1
        LDI     r4, 1
        SUB     r0, r3, r4
        BNEZ    fail
        LDPC    r4, high_square
        SUB     r0, r1, r4
        BNEZ    fail

        ; rb may alias the low destination (rd); its old value is the source.
        LDPC    r1, left
        LDPC    r3, right
        MULHU   r3, r1, r3
        LDPC    r4, product_low
        SUB     r0, r3, r4
        BNEZ    fail
        LDPC    r4, product_high
        SUB     r0, r1, r4
        BNEZ    fail

        ; A high R0 result must survive the subsequent low-result write.
        LDI     r0, 1
        LDI     r2, 1
        MULHU   r3, r0, r2
        BNEZ    fail
        SUB     r0, r3, r2
        BNEZ    fail

        ; A low R0 result must update the branch flags last.
        LDPC    r1, sign_bit
        LDI     r2, 2
        MULHU   r0, r1, r2
        BNEZ    fail
        LDI     r4, 1
        SUB     r0, r1, r4
        BNEZ    fail

        LDPC    r7, pass_value
        JMP8    finish
fail:
        LDPC    r7, fail_value
finish:
        LDPC    r6, result_address
        STH     r7, [r6]
        HALT

        .p2align 2
left:           .long 0x12345678
right:          .long 0x87654321
product_low:    .long 0x70b88d78
product_high:   .long 0x09a0cd05
all_ones:       .long 0xffffffff
high_square:    .long 0xfffffffe
sign_bit:       .long 0x80000000
pass_value:     .long 0x600d
fail_value:     .long 0x0bad
result_address: .long 0xfffe

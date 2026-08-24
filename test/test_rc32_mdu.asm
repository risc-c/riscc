; Self-checking ISS test for the optional compact RC32 MDU instructions.
; No current RC32 RTL core implements this extension.

.macro LIT reg, literal
        LDPC    \reg, \literal
.endm

.text
.global start
start:
        ; 0x12345678 * 0x87654321 = 0x09a0cd0570b88d78.
        LIT     r1, .Lleft_operand
        LIT     r2, .Lright_operand
        MULHU   r3, r1, r2
        LIT     r4, .Lproduct_low
        SUB     r0, r3, r4
        BNEZ    fail
        LIT     r4, .Lproduct_high
        SUB     r0, r1, r4
        BNEZ    fail

        ; 0x123456789abcdef0 / 0x80000001 = 0x2468acf0,
        ; remainder 0x76543200. The high dividend word is below the divisor.
        LIT     r3, .Ldividend_high
        LIT     r1, .Ldividend_low
        LIT     r2, .Ldivisor
        DIVU    r3, r1, r2
        LIT     r4, .Lquotient
        SUB     r0, r1, r4
        BNEZ    fail
        LIT     r4, .Lremainder
        SUB     r0, r3, r4
        BNEZ    fail

pass:
        LIT     r7, .Lpass_code
        JMP8    finish

fail:
        LIT     r7, .Lfail_code

finish:
        LIT     r6, .Lresult_port
        STH     r7, [r6]
        HALT

        .p2align 2
.Lleft_operand:
        .long   0x12345678
.Lright_operand:
        .long   0x87654321
.Lproduct_low:
        .long   0x70b88d78
.Lproduct_high:
        .long   0x09a0cd05
.Ldividend_high:
        .long   0x12345678
.Ldividend_low:
        .long   0x9abcdef0
.Ldivisor:
        .long   0x80000001
.Lquotient:
        .long   0x2468acf0
.Lremainder:
        .long   0x76543200
.Lpass_code:
        .long   0x0000600d
.Lfail_code:
        .long   0x00000bad
.Lresult_port:
        .long   0x0000fffe

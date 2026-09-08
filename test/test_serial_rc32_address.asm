; The fixture mirrors its 64 KiB RAM throughout the RC32 address space.
; Check full-width PC/link arithmetic through those aliases, including JALL's
; five address bits in the first halfword. Run on Min, Sys and Full.

.text
.global start
start:
        JMP8    main
        .p2align 2
entry_address:  .long (high_entry - start) + 0x81230000
sub_address:    .long (high_sub - start) + 0xffff0000
low_link:       .long after_entry
high_link:      .long (after_sub - start) + 0x81230000
check_address:  .long check_long
long_link:      .long after_long_sub + 0x001f0000
result_address: .long 0x0000fffe
pass_value:     .long 0x600d
fail_value:     .long 0x0bad

main:
        LDPC    r1, entry_address
        JALR    S1, r1
after_entry:
.ifdef RISCC_SYS
        JALL    S3, high_long + 0x001f0000
.endif
        LDPC    r7, pass_value
        JMP8    finish

high_entry:
        MFS     r2, S1
        LDPC    r3, low_link
        SUB     r0, r2, r3
        BNEZ    fail
        LDPC    r1, sub_address
        JALR    S2, r1
after_sub:
        MFS     r2, S2
        LDPC    r3, high_link
        SUB     r0, r2, r3
        BNEZ    fail
        RET     S1

high_sub:
        RET     S2

high_long:
        LDPC    r1, check_address
        JALR    S4, r1
after_long_sub:
        RET     S3
check_long:
        MFS     r2, S4
        LDPC    r3, long_link
        SUB     r0, r2, r3
        BNEZ    fail
        RET     S4

fail:
        LDPC    r7, fail_value
finish:
        LDPC    r6, result_address
        STH     r7, [r6]
        HALT

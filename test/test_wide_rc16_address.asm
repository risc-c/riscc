; All RC16 profiles: calls across the sign bit and immediately below MMIO.
.text
.global start
start:
        LDI16   r1, high_entry
        JALR    S1, r1
after_entry:
.ifdef RISCC_SYS
        JALL    S3, high_long
.endif
        LDI16   r7, 0x600d
        JMP8    finish
fail:
        LDI16   r7, 0x0bad
finish:
        LDI16   r6, 0xfffe
        ST      r7, [r6]
        HALT

        .org 0x8000
high_entry:
        MFS     r2, S1
        LDI16   r3, after_entry
        SUB     r0, r2, r3
        BNEZ    high_fail
        LDI16   r1, near_top
        JALR    S2, r1
after_top:
        MFS     r2, S2
        LDI16   r3, after_top
        SUB     r0, r2, r3
        BNEZ    high_fail
        RET     S1
high_fail:
        LDI16   r1, fail
        JMP     r1
high_long:
        RET     S3

        .org 0xffd0
near_top:
        RET     S2

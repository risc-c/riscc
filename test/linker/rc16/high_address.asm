; RC16 upper-address execution and relocation test.
;
; The linked layout deliberately crosses the sign-bit boundary with a compact
; PC-relative jump, calls a function immediately below the I/O page, accesses
; nearby high data through HI8/LO8 relocations, and returns to low memory using
; CODE_HI8/CODE_LO8 relocations.

        .section .vectors,"ax",@progbits
        .globl  start
start:
        JMPL    low_start
        JMPL    fail

        .section .text.low,"ax",@progbits
low_start:
        LDI     r1, 0
        JMPL    boundary_low

        .globl  low_return
low_return:
        LDI     r4, 2
        SUB     r0, r1, r4
        BNEZ    fail

        ; Exercise ordinary data HI8/LO8 relocations at the top of memory.
        LDI16   r3, top_data
        LD      r2, [r3]
        LDI16   r4, 0xcafe
        SUB     r0, r2, r4
        BNEZ    fail

pass:
        LDI16   r7, 0x600d
        LDI16   r6, 0xfffe
        ST      r7, [r6]
        HALT

        .globl  fail
fail:
        LDI16   r7, 0x0bad
        LDI16   r6, 0xfffe
        ST      r7, [r6]
        HALT

        .section .text.boundary.low,"ax",@progbits
        .globl  boundary_low
boundary_low:
        LDI     r1, 1
        ; This relocation is at 0x7ffe and targets 0x8000.
        JMP8    boundary_high

        .section .text.boundary.high,"ax",@progbits
        .globl  boundary_high
boundary_high:
        ; R_RISCC_CODE16 must retain the full high byte of 0xffd8.
        JALL    s7, near_top
        ADDI    r1, 1
        ; Return across 0x8000 through code-address HI8/LO8 relocations.
        LDI16   r0, code(low_return)
        JMP     r0

        .section .rodata.top,"a",@progbits
        .globl  top_data
top_data:
        .short  0xcafe

        .section .text.top,"ax",@progbits
        .globl  near_top
near_top:
        LDI16   r3, top_data
        LD      r2, [r3]
        LDI16   r4, 0xcafe
        SUB     r0, r2, r4
        BEQZ    top_ok
        LDI16   r0, code(fail)
        JMP     r0
top_ok:
        RET     s7

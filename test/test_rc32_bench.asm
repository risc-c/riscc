; RC32 word-copy and dot-product benchmark. The dot product checks the copy.
; 32 signed products accumulate to 7920; success is written as a halfword.
.section .vectors, "ax", @progbits
        JMPL start
        JMPL fail
.text
        .global start
        .p2align 2
source_ptr:     .long samples
copy_ptr:       .long copied
coeff_ptr:      .long coefficients
expected:      .long 7920
result_port:   .long 0xfffe
pass_code:     .long 0x600d
fail_code:     .long 0x0bad
start:
        LDPC r1, source_ptr
        LDPC r2, copy_ptr
        LDI r3, 32
copy_loop:
        LD r5, [r1+0]
        ST r5, [r2+0]
        ADDI r1, 4
        ADDI r2, 4
        ADDI r3, -1
        MOV r0, r3
        BNEZ copy_loop

        LDPC r1, copy_ptr
        LDPC r2, coeff_ptr
        LDI r3, 32
        LDI r4, 0
dot_loop:
        LD r5, [r1+0]
        LD r6, [r2+0]
        MUL r7, r5, r6
        ADD r4, r4, r7
        ADDI r1, 4
        ADDI r2, 4
        ADDI r3, -1
        MOV r0, r3
        BNEZ dot_loop
        LDPC r6, expected
        SUB r0, r4, r6
        BNEZ fail
        LDPC r7, pass_code
        JMP8 finish
fail:
        LDPC r7, fail_code
finish:
        LDPC r6, result_port
        STH r7, [r6]
        HALT
        .p2align 2
samples:
        .long 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16
        .long 17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32
coefficients:
        .long -47,-44,-41,-38,-35,-32,-29,-26,-23,-20,-17,-14,-11,-8,-5,-2
        .long 1,4,7,10,13,16,19,22,25,28,31,34,37,40,43,46
copied:
        .space 128

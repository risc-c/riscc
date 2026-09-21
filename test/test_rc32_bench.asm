; RC32 counterpart of test_riscc_bench.asm: the same eight embedded kernels,
; inputs, loop counts, and checks. Addresses and constants use local LDPC pools.
; Sort and FIR use native words; the int32 kernel uses native arithmetic.
; Division still processes the same 16-bit dividend in sixteen steps.
;
; Kernels: byte copy, strlen, strcmp, CRC16, int32 arithmetic, software divide,
; unsigned bubble sort, and eight-output/eight-tap FIR (64 products).
; Fail codes 0x0BA1..0x0BA8 identify the kernel; success writes 0x600D.

.section .vectors, "ax", @progbits
        JMPL start
        JMPL fail

.text
        .global start
        .p2align 2
.Lcopy_src:     .long src_str
.Lcopy_dst:     .long dst_buf
start:
; 1. Copy the same 24 bytes, then check positions 7 and 15.
k1:
        LDPC r1, .Lcopy_src
        LDPC r2, .Lcopy_dst
        LDI r3, 24
        LDI r4, 0
mc_loop:
        ADD r7, r1, r4
        LDB r5, [r7]
        STB r5, [r2]
        ADDI r2, 1
        ADDI r4, 1
        SUB r0, r4, r3
        BNEZ mc_loop
        LDPC r2, .Lcopy_dst
        LDI r4, 7
        ADD r7, r2, r4
        LDB r5, [r7]
        LDI r6, 0x52
        SUB r0, r5, r6
        BNEZ f1
        LDI r4, 15
        ADD r7, r2, r4
        LDB r5, [r7]
        LDI r6, 0x21
        SUB r0, r5, r6
        BEQZ k2
f1:     LDI r7, 1
        JMPL fail

        .p2align 2
.Lstrlen_src:   .long src_str
; 2. strlen("Hello, RISC-C16!") == 16, using identical input bytes.
k2:
        LDPC r1, .Lstrlen_src
        LDI r2, 0
sl_loop:
        ADD r7, r1, r2
        LDB r5, [r7]
        MOV r0, r5
        BEQZ sl_done
        ADDI r2, 1
        JMP8 sl_loop
sl_done:
        LDI r6, 16
        SUB r0, r2, r6
        BEQZ k3
        LDI r7, 2
        JMPL fail

        .p2align 2
.Lstrcmp_a:    .long cmp_a
.Lstrcmp_b:    .long cmp_b
.Lminus_one:   .long -1
; 3. strcmp: the first differing bytes are 'A' and 'B', giving -1.
k3:
        LDPC r1, .Lstrcmp_a
        LDPC r2, .Lstrcmp_b
        LDI r3, 0
sc_loop:
        ADD r6, r1, r3
        LDB r4, [r6]
        ADD r6, r2, r3
        LDB r5, [r6]
        SUB r0, r4, r5
        BNEZ sc_diff
        MOV r0, r4
        BEQZ sc_eq
        ADDI r3, 1
        JMP8 sc_loop
sc_eq:
        LDI r7, 3
        JMPL fail
sc_diff:
        SUB r4, r4, r5
        LDPC r6, .Lminus_one
        SUB r0, r4, r6
        BEQZ k4
        LDI r7, 3
        JMPL fail

        .p2align 2
.Lcrc_data:    .long crc_dat
.Lcrc_poly:    .long 0xA001
.Lcrc_result:  .long 0xB378
; 4. Reflected CRC16, polynomial 0xA001, over the same eight bytes.
k4:
        LDPC r1, .Lcrc_data
        LDI r2, 0
        LDI r3, 0
c_byte:
        ADD r7, r1, r3
        LDB r4, [r7]
        XOR r2, r2, r4
        LDI r5, 8
c_bit:
        MOV r0, r2
        ANDI r0, 1
        BEQZ c_noxor
        SRLI r2, r2, 1
        LDPC r6, .Lcrc_poly
        XOR r2, r2, r6
        JMP8 c_next
c_noxor:
        SRLI r2, r2, 1
c_next:
        ADDI r5, -1
        MOV r0, r5
        BNEZ c_bit
        ADDI r3, 1
        LDI r6, 8
        SUB r0, r3, r6
        BNEZ c_byte
        LDPC r6, .Lcrc_result
        SUB r0, r2, r6
        BEQZ k5
        LDI r7, 4
        JMPL fail

        .p2align 2
.Lint32_x:     .long 0x00012345
.Lint32_x4:    .long 0x00048D14
.Lint32_x8:    .long 0x00091A28
.Lint32_x10:   .long 0x000B60B2
; 5. Compute and check 4x, 8x, and 10x for the same 32-bit x.
; RC16 carries between two registers; RC32 holds each value in one register.
k5:
        LDPC r1, .Lint32_x
        MOV r3, r1
        LDI r6, 3
i32_add:
        ADD r3, r3, r1
        ADDI r6, -1
        MOV r0, r6
        BNEZ i32_add
        LDPC r5, .Lint32_x4
        SUB r0, r3, r5
        BNEZ f5
        ADD r3, r3, r3
        LDPC r5, .Lint32_x8
        SUB r0, r3, r5
        BNEZ f5
        ADD r5, r1, r1
        ADD r3, r3, r5
        LDPC r5, .Lint32_x10
        SUB r0, r3, r5
        BEQZ k6
f5:     LDI r7, 5
        JMPL fail

        .p2align 2
.Ldividend:    .long 0xBEEF0000
.Lsign_bit:    .long 0x80000000
.Lquotient:    .long 6982
; 6. Software restoring division: 48879 / 7 = 6982 remainder 5.
; Position the 16 dividend bits at the top of the native register, so both
; versions shift one input bit through the sign position on each iteration.
k6:
        LDPC r1, .Ldividend
        LDI r2, 7
        LDI r3, 0
        LDI r4, 0
        LDI r5, 16
        LDPC r7, .Lsign_bit
d_loop:
        SLTU r0, r1, r7
        XORI r0, 1
        ADD r4, r4, r4
        OR r4, r4, r0
        ADD r1, r1, r1
        ADD r3, r3, r3
        SLTU r0, r4, r2
        BNEZ d_skip
        SUB r4, r4, r2
        ORI r3, 1
d_skip:
        ADDI r5, -1
        MOV r0, r5
        BNEZ d_loop
        LDPC r6, .Lquotient
        SUB r0, r3, r6
        BNEZ f6
        LDI r6, 5
        SUB r0, r4, r6
        BEQZ k7
f6:     LDI r7, 6
        JMPL fail

        .p2align 2
.Lsort_data:   .long sort_dat
.Lsort_middle: .long 0x4BEE
.Lsort_last:   .long 0xD00D
; 7. Unsigned bubble sort: the same twelve values and eleven full passes.
k7:
        LDI r5, 11
s_outer:
        LDPC r1, .Lsort_data
        LDI r2, 0
s_inner:
        LD r3, [r1+0]
        LD r4, [r1+4]
        SLTU r0, r4, r3
        BEQZ s_noswap
        ST r3, [r1+4]
        ST r4, [r1+0]
s_noswap:
        ADDI r1, 4
        ADDI r2, 4
        LDI r6, 44
        SUB r0, r2, r6
        BNEZ s_inner
        ADDI r5, -1
        MOV r0, r5
        BNEZ s_outer
        LDPC r1, .Lsort_data
        LD r3, [r1+0]
        LDI r4, 1
        SUB r0, r3, r4
        BNEZ f7
        LD r3, [r1+20]
        LDPC r4, .Lsort_middle
        SUB r0, r3, r4
        BNEZ f7
        LD r3, [r1+44]
        LDPC r4, .Lsort_last
        SUB r0, r3, r4
        BEQZ k8
f7:     LDI r7, 7
        JMPL fail

        .p2align 2
.Lfir_data:    .long fir_data
.Lfir_coeff:   .long fir_coeff
.Lfir_result:  .long -80
; 8. Eight overlapping FIR outputs with eight signed taps each.
; The sum is -80: 0xFFB0 on RC16 and 0xFFFFFFB0 on RC32.
k8:
        LDPC r1, .Lfir_data
        LDI r3, 8
        LDI r4, 0
fir_outer:
        LDPC r2, .Lfir_coeff
        LDI r7, 8
fir_inner:
        LD r5, [r1+0]
        LD r6, [r2+0]
        MUL r5, r5, r6
        ADD r4, r4, r5
        ADDI r1, 4
        ADDI r2, 4
        ADDI r7, -1
        MOV r0, r7
        BNEZ fir_inner
        ADDI r1, -28
        ADDI r3, -1
        MOV r0, r3
        BNEZ fir_outer
        LDPC r6, .Lfir_result
        SUB r0, r4, r6
        BEQZ done
        LDI r7, 8
        JMPL fail

done:
        LDPC r7, .Lpass_code
        LDPC r6, .Lresult_port
        STH r7, [r6]
        HALT
fail:
        LDPC r6, .Lfail_base
        ADD r7, r7, r6
        LDPC r6, .Lresult_port
        STH r7, [r6]
        HALT
        .p2align 2
.Lpass_code:   .long 0x600D
.Lfail_base:   .long 0x0BA0
.Lresult_port: .long 0xFFFE

.data
src_str:      .asciz "Hello, RISC-C16!"
cmp_a:        .asciz "benchmark-Ax"
cmp_b:        .asciz "benchmark-Bx"
crc_dat:      .ascii "RISC-C16"
        .p2align 2
sort_dat:
        .long 0x4BEE, 0x0007, 0xD00D, 0x1234, 0xBEEF, 0x0F0F
        .long 0x8000, 0x0001, 0x7FFF, 0xAAAA, 0x00FF, 0x4BEE
fir_data:
        .long 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
fir_coeff:
        .long 1, -1, 2, -2, 3, -3, 4, -4
dst_buf:
        .space 32

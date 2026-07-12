; RISC-C benchmark: common embedded kernels, self-checking.
;
; Profile-compatible benchmark image. Mainline full and fast builds use the
; native MUL in the final FIR kernel; Nano uses the local __mul16 routine.
;
; Kernels (the op mix mirrors small-embedded suites: loads/stores ~30%,
; branches ~20%, add/sub/compare ~30%, shifts/logic ~15%, plus FIR MULs):
;   1. memcpy   -- 24 bytes through LDB/STB
;   2. strlen   -- 16-char string
;   3. strcmp   -- 12-char strings differing at index 10
;   4. crc16    -- poly 0xA001 (reflected), 8 bytes, bit-serial loop
;   5. int32    -- 32-bit add chain, <<3 via the sign-bit carry idiom, x10
;   6. div16    -- software restoring divide, 48879 / 7
;   7. sort     -- bubble sort, 12 words
;   8. FIR     -- eight outputs, eight taps each
;
; Fail codes 0x0BA1..0x0BA8 identify the kernel; success writes 0x600D
; to the result register in the I/O page (byte 0xFFFE).

.vectors

.text
reset_tramp:
    LDI16 r0, start >> 1
    JMP   r0

fail:                       ; near stub for the (unused) vectors
    LDI16 r7, 0x0BAD
    LDI16 r6, 0xFFFE
    STW   r7, [r6+0]
    HALT

; ---------------------------------------------------------------------
; data
; ---------------------------------------------------------------------
src_str:
    .asciz "Hello, RISC-C16!"
cmp_a:
    .asciz "benchmark-Ax"
cmp_b:
    .asciz "benchmark-Bx"
crc_dat:
    .ascii "RISC-C16"
    .align 2
sort_dat:
    .word 0x4BEE, 0x0007, 0xD00D, 0x1234, 0xBEEF, 0x0F0F
    .word 0x8000, 0x0001, 0x7FFF, 0xAAAA, 0x00FF, 0x4BEE
    .align 2
fir_data:
    .word 1, 2, 3, 4, 5, 6, 7, 8
    .word 9, 10, 11, 12, 13, 14, 15
fir_coeff:
    .word 1, 0xFFFF, 2, 0xFFFE, 3, 0xFFFD, 4, 0xFFFC
dst_buf:
    .space 32
.ifdef RISCC_NANO
nano_taps:
    .word 0
nano_outputs:
    .word 0
.endif

start:
; ---------------------------------------------------------------------
; 1. memcpy: 24 bytes src_str -> dst_buf, byte at a time
; ---------------------------------------------------------------------
    LDI16 r1, src_str       ; src byte pointer
    LDI16 r2, dst_buf       ; dst byte pointer
    LDI   r3, 24            ; count
    LDI   r4, 0             ; index
mc_loop:
    LDB   r5, [r1+r4]
    STB   r5, [r2]
    ADDI  r2, 1
    ADDI  r4, 1
    SUB   r0, r4, r3
    BNEZ  mc_loop
    ; spot-check dst_buf[7] == 'R' (0x52) and dst_buf[15] == '!'
    LDI16 r2, dst_buf
    LDI   r4, 7
    LDB   r5, [r2+r4]
    LDI   r6, 0x52
    SUB   r0, r5, r6
    BNEZ  f1
    LDI   r4, 15
    LDB   r5, [r2+r4]
    LDI   r6, 0x21
    SUB   r0, r5, r6
    BEQZ  k2
f1: LDI16 r7, 0x0BA1
    JMP8  fail_w

; ---------------------------------------------------------------------
; 2. strlen(src_str) == 16
; ---------------------------------------------------------------------
k2:
    LDI16 r1, src_str
    LDI   r2, 0             ; length
sl_loop:
    LDB   r5, [r1+r2]
    MOV   r0, r5
    BEQZ  sl_done
    ADDI  r2, 1
    JMP8  sl_loop
sl_done:
    LDI   r6, 16
    SUB   r0, r2, r6
    BEQZ  k3
    LDI16 r7, 0x0BA2
    JMP8  fail_w

; ---------------------------------------------------------------------
; 3. strcmp(cmp_a, cmp_b): first difference at index 10, 'A' < 'B'
; ---------------------------------------------------------------------
k3:
    LDI16 r1, cmp_a
    LDI16 r2, cmp_b
    LDI   r3, 0             ; index
sc_loop:
    LDB   r4, [r1+r3]
    LDB   r5, [r2+r3]
    SUB   r0, r4, r5
    BNEZ  sc_diff
    MOV   r0, r4
    BEQZ  sc_eq             ; both NUL: equal (would be a failure here)
    ADDI  r3, 1
    JMP8  sc_loop
sc_eq:
    LDI16 r7, 0x0BA3
    JMP8  fail_w
sc_diff:
    SUB   r4, r4, r5        ; 'A' - 'B' = -1
    LDI16 r6, 0xFFFF
    SUB   r0, r4, r6
    BEQZ  k4
    LDI   r6, 10            ; and it must be at index 10
    SUB   r0, r3, r6
    LDI16 r7, 0x0BA3
    JMP8  fail_w

; ---------------------------------------------------------------------
; 4. crc16, poly 0xA001, init 0, over "RISC-C16" -> 0xB378
; ---------------------------------------------------------------------
k4:
    LDI16 r1, crc_dat
    LDI   r2, 0             ; crc
    LDI   r3, 0             ; byte index
c_byte:
    LDB   r4, [r1+r3]
    XOR   r2, r2, r4
    LDI   r5, 8             ; bit count
c_bit:
    MOV   r0, r2
    ANDI  r0, 1
    BEQZ  c_noxor
    SHRI  r2, r2, 1
    LDI16 r6, 0xA001
    XOR   r2, r2, r6
    JMP8  c_next
c_noxor:
    SHRI  r2, r2, 1
c_next:
    ADDI  r5, -1
    MOV   r0, r5
    BNEZ  c_bit
    ADDI  r3, 1
    LDI   r6, 8
    SUB   r0, r3, r6
    BNEZ  c_byte
    LDI16 r6, 0xB378
    SUB   r0, r2, r6
    BEQZ  k5
    LDI16 r7, 0x0BA4
    JMP8  fail_w

; central failure sink, JMP8-reachable from every kernel (r7 = code)
    JMP8  k5                ; fall-through guard
fail_w:
    LDI16 r6, 0xFFFE
    STW   r7, [r6+0]
    HALT

; ---------------------------------------------------------------------
; 5. int32: {r2,r1} = 0x00012345; five 32-bit adds of itself would
;    overflow the loop budget -- do acc += x three times (=> x*4),
;    then <<3 via a sign-bit carry idiom, then compare against precomputed x10.
;    x*4 = 0x00048D14; (x<<3) = 0x00091A28; x*10 = 0x000B60B2
; ---------------------------------------------------------------------
k5:
    LDI16 r1, 0x2345        ; x.lo
    LDI16 r2, 0x0001        ; x.hi
    MOV   r3, r1            ; acc = x
    MOV   r4, r2
    LDI   r6, 3             ; three 32-bit adds: acc = 4x
    LUI   r7, 0x80          ; sign mask for carry-out from <<1
i32_add:
    ADD   r3, r3, r1        ; lo += x.lo
    SLTU  r0, r3, r1        ; carry
    ADD   r4, r4, r2
    ADD   r4, r4, r0
    ADDI  r6, -1
    MOV   r0, r6
    BNEZ  i32_add
    LDI16 r5, 0x8D14
    SUB   r0, r3, r5
    BNEZ  f5
    LDI   r5, 4             ; 0x0004
    SUB   r0, r4, r5
    BNEZ  f5
    ; {r4,r3} = 4x; one more 32-bit <<1 gives 8x = x<<3
    SLTU  r0, r3, r7        ; r0 = lo < 0x8000
    XORI  r0, 1             ; r0 = lo[15]
    ADD   r4, r4, r4
    OR    r4, r4, r0
    ADD   r3, r3, r3
    LDI16 r5, 0x1A28
    SUB   r0, r3, r5
    BNEZ  f5
    LDI   r5, 9
    SUB   r0, r4, r5
    BNEZ  f5
    ; x*10 = 8x + 2x: build 2x, 32-bit add
    MOV   r5, r1
    MOV   r6, r2
    SLTU  r0, r5, r7
    XORI  r0, 1
    ADD   r6, r6, r6
    OR    r6, r6, r0
    ADD   r5, r5, r5        ; {r6,r5} = 2x
    ADD   r3, r3, r5
    SLTU  r0, r3, r5
    ADD   r4, r4, r6
    ADD   r4, r4, r0
    LDI16 r5, 0x60B2
    SUB   r0, r3, r5
    BNEZ  f5
    LDI   r5, 0x0B
    SUB   r0, r4, r5
    BEQZ  k6
f5: LDI16 r7, 0x0BA5
    JMP8  fail_w

; ---------------------------------------------------------------------
; 6. div16: 48879 / 7 = 6982 rem 5 (restoring shift-subtract loop)
; ---------------------------------------------------------------------
k6:
    LDI16 r1, 48879         ; n
    LDI   r2, 7             ; d
    LDI   r3, 0             ; q
    LDI   r4, 0             ; rem
    LDI   r5, 16            ; bits
    LUI   r7, 0x80          ; sign mask for carry-out from <<1
d_loop:
    SLTU  r0, r1, r7        ; r0 = n < 0x8000
    XORI  r0, 1             ; r0 = n[15]
    ADD   r4, r4, r4
    OR    r4, r4, r0        ; rem = rem<<1 | n[15]
    ADD   r1, r1, r1        ; n <<= 1
    ADD   r3, r3, r3        ; q <<= 1
    SLTU  r0, r4, r2
    BNEZ  d_skip
    SUB   r4, r4, r2
    ORI   r3, 1
d_skip:
    ADDI  r5, -1
    MOV   r0, r5
    BNEZ  d_loop
    LDI16 r6, 6982
    SUB   r0, r3, r6
    BNEZ  f6
    LDI   r6, 5
    SUB   r0, r4, r6
    BEQZ  k7
f6: LDI16 r7, 0x0BA6
    JMP8  fail_w

; ---------------------------------------------------------------------
; 7. bubble sort, 12 words in sort_dat (in place)
; ---------------------------------------------------------------------
k7:
    LDI   r5, 11            ; outer passes
s_outer:
    LDI16 r1, sort_dat
    LDI   r2, 0             ; byte index
s_inner:
    LDW   r3, [r1+0]
    LDW   r4, [r1+2]
    SLTU  r0, r4, r3        ; unsigned compare: swap if next < cur
    BEQZ  s_noswap
    STW   r3, [r1+2]
    STW   r4, [r1+0]
s_noswap:
    ADDI  r1, 2
    ADDI  r2, 2
    LDI   r6, 22            ; 11 comparisons per pass
    SUB   r0, r2, r6
    BNEZ  s_inner
    ADDI  r5, -1
    MOV   r0, r5
    BNEZ  s_outer
    ; verify [0]=0x0001, [5]=0x4BEE, [11]=0xD00D
    LDI16 r1, sort_dat
    LDW   r3, [r1+0]
    LDI   r4, 1
    SUB   r0, r3, r4
    BNEZ  f7
    LDW   r3, [r1+10]
    LDI16 r4, 0x4BEE
    SUB   r0, r3, r4
    BNEZ  f7
    LDW   r3, [r1+22]
    LDI16 r4, 0xD00D
    SUB   r0, r3, r4
    BEQZ  k8
f7: LDI16 r7, 0x0BA7
    JMP8  fail_w

; ---------------------------------------------------------------------
; 8. FIR kernel: calculate eight overlapping outputs with eight taps each.
;    The nested loops perform 64 products; the checksum is 0xFFB0.
; ---------------------------------------------------------------------
k8:
.ifdef RISCC_NANO
    ; Nano ABI for __mul16: r1/r2 are operands, r1 is the result; r4-r6
    ; survive the call. The loop counters live in memory so the routine may
    ; use r0-r3 and r7 as its working registers and link register.
    LDI16 r4, fir_data
    LDI16 r5, fir_coeff
    LDI   r6, 0
    LDI16 r0, nano_outputs
    LDI   r3, 8
    STW   r3, [r0+0]
fir_outer_n:
    LDI16 r5, fir_coeff
    LDI16 r0, nano_taps
    LDI   r3, 8
    STW   r3, [r0+0]
fir_inner_n:
    LDW   r1, [r4+0]
    LDW   r2, [r5+0]
    LDI16 r3, __mul16 >> 1
    CALL  r7, r3
    ADD   r6, r6, r1
    ADDI  r4, 2
    ADDI  r5, 2
    LDI16 r0, nano_taps
    LDW   r3, [r0+0]
    ADDI  r3, -1
    STW   r3, [r0+0]
    MOV   r0, r3
    BNEZ  fir_inner_n
    ADDI  r4, -14
    LDI16 r0, nano_outputs
    LDW   r3, [r0+0]
    ADDI  r3, -1
    STW   r3, [r0+0]
    MOV   r0, r3
    BNEZ  fir_outer_n
.else
    LDI16 r1, fir_data
    LDI   r3, 8             ; output count
    LDI   r4, 0
fir_outer:
    LDI16 r2, fir_coeff
    LDI   r7, 8             ; tap count
fir_inner:
    LDW   r5, [r1+0]
    LDW   r6, [r2+0]
    MUL   r5, r5, r6
    ADD   r4, r4, r5
    ADDI  r1, 2
    ADDI  r2, 2
    ADDI  r7, -1
    MOV   r0, r7
    BNEZ  fir_inner
    ADDI  r1, -14        ; advance sample window by one word
    ADDI  r3, -1
    MOV   r0, r3
    BNEZ  fir_outer
.endif
.ifdef RISCC_NANO
    LDI16 r0, 0xFFB0
    SUB   r0, r6, r0
.else
    LDI16 r6, 0xFFB0
    SUB   r0, r4, r6
.endif
    BEQZ  done
    LDI16 r7, 0x0BA8
    LDI16 r6, 0xFFFE
    STW   r7, [r6+0]
    HALT

done:
    LDI16 r7, 0x600D
    LDI16 r6, 0xFFFE
    STW   r7, [r6+0]
    HALT

.ifdef RISCC_NANO
; Software low-half multiply. Inputs are r1/r2; result is r1. The routine
; clobbers r0-r3 and r7, but preserves r4-r6 for the FIR caller.
__mul16:
    MOV   r3, r1
    LDI   r1, 0
    MOV   r0, r2
    ADD   r1, r1, r1
    BGEZ  mul_n1
    ADD   r1, r1, r3
mul_n1:
    ADD   r2, r2, r2
    MOV   r0, r2
    ADD   r1, r1, r1
    BGEZ  mul_n2
    ADD   r1, r1, r3
mul_n2:
    ADD   r2, r2, r2
    MOV   r0, r2
    ADD   r1, r1, r1
    BGEZ  mul_n3
    ADD   r1, r1, r3
mul_n3:
    ADD   r2, r2, r2
    MOV   r0, r2
    ADD   r1, r1, r1
    BGEZ  mul_n4
    ADD   r1, r1, r3
mul_n4:
    ADD   r2, r2, r2
    MOV   r0, r2
    ADD   r1, r1, r1
    BGEZ  mul_n5
    ADD   r1, r1, r3
mul_n5:
    ADD   r2, r2, r2
    MOV   r0, r2
    ADD   r1, r1, r1
    BGEZ  mul_n6
    ADD   r1, r1, r3
mul_n6:
    ADD   r2, r2, r2
    MOV   r0, r2
    ADD   r1, r1, r1
    BGEZ  mul_n7
    ADD   r1, r1, r3
mul_n7:
    ADD   r2, r2, r2
    MOV   r0, r2
    ADD   r1, r1, r1
    BGEZ  mul_n8
    ADD   r1, r1, r3
mul_n8:
    ADD   r2, r2, r2
    MOV   r0, r2
    ADD   r1, r1, r1
    BGEZ  mul_n9
    ADD   r1, r1, r3
mul_n9:
    ADD   r2, r2, r2
    MOV   r0, r2
    ADD   r1, r1, r1
    BGEZ  mul_n10
    ADD   r1, r1, r3
mul_n10:
    ADD   r2, r2, r2
    MOV   r0, r2
    ADD   r1, r1, r1
    BGEZ  mul_n11
    ADD   r1, r1, r3
mul_n11:
    ADD   r2, r2, r2
    MOV   r0, r2
    ADD   r1, r1, r1
    BGEZ  mul_n12
    ADD   r1, r1, r3
mul_n12:
    ADD   r2, r2, r2
    MOV   r0, r2
    ADD   r1, r1, r1
    BGEZ  mul_n13
    ADD   r1, r1, r3
mul_n13:
    ADD   r2, r2, r2
    MOV   r0, r2
    ADD   r1, r1, r1
    BGEZ  mul_n14
    ADD   r1, r1, r3
mul_n14:
    ADD   r2, r2, r2
    MOV   r0, r2
    ADD   r1, r1, r1
    BGEZ  mul_n15
    ADD   r1, r1, r3
mul_n15:
    ADD   r2, r2, r2
    MOV   r0, r2
    ADD   r1, r1, r1
    BGEZ  mul_n16
    ADD   r1, r1, r3
mul_n16:
    ADD   r2, r2, r2
    JMP   r7
.endif

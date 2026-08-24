/* Pack an extended RC32 binary32 significand using round-to-nearest-even. */

        .section .text.__riscc_pack_sf,"ax",@progbits
        .p2align 1
        .global __riscc_pack_sf
        .hidden __riscc_pack_sf
        .type __riscc_pack_sf,@function
/* r1 = 24-bit significand plus GRS, r2 = sign, r3 = biased exponent. */
__riscc_pack_sf:
        MOV     r0, r3
        BLTZ    .Lpack_underflow
        BNEZ    .Lpack_round
.Lpack_underflow:
        LDI     r0, 1
        SUB     r0, r0, r3
        MTS     s3, r0                 // shift = 1 - exponent
        CMPI    r0, 32
        BLTZ    .Lpack_underflow_test
        MOV     r0, r1
        LDI     r1, 0
        BEQZ    .Lpack_underflow_done
        LDI     r1, 1                  // all discarded bits become sticky
        JMP8    .Lpack_underflow_done
.Lpack_underflow_loop:
        MOV     r0, r1
        ANDI    r0, 1
        SRLI    r1, r1, 1
        OR      r1, r1, r0
        MFS     r0, s3
        ADDI    r0, -1
        MTS     s3, r0
.Lpack_underflow_test:
        MFS     r0, s3
        BNEZ    .Lpack_underflow_loop
.Lpack_underflow_done:
        LDI     r3, 1

.Lpack_round:
        MOV     r0, r1
        ANDI    r0, 7
        CMPI    r0, 5
        BGEZ    .Lpack_round_up
        MOV     r0, r1
        ANDI    r0, 7
        CMPI    r0, 4
        BNEZ    .Lpack_rounded
        MOV     r0, r1
        ANDI    r0, 8
        BEQZ    .Lpack_rounded
.Lpack_round_up:
        ADDI    r1, 8

.Lpack_rounded:
        LDPC    r0, .Lpack_overflow
        AND     r0, r1, r0
        BEQZ    .Lpack_range
        LDPC    r1, .Lpack_hidden
        ADDI    r3, 1

.Lpack_range:
        LDI     r0, 255
        SLTU    r0, r3, r0
        BNEZ    .Lpack_subnormal_test
        LDPC    r1, .Lpack_infinity
        OR      r1, r1, r2
        RET     S7

.Lpack_subnormal_test:
        CMPI    r3, 1
        BNEZ    .Lpack_fields
        LDPC    r0, .Lpack_hidden
        AND     r0, r1, r0
        BNEZ    .Lpack_fields
        LDI     r3, 0

.Lpack_fields:
        .rept 3
        SRLI    r1, r1, 1
        .endr
        LDPC    r0, .Lpack_fraction
        AND     r1, r1, r0
#ifdef __RISCC_FULL__
        SLLI    r3, r3, 8
        SLLI    r3, r3, 8
        SLLI    r3, r3, 7
#else
        MTS     s4, r1
        MOV     r1, r3
        MFS     r0, s7
        MTS     s3, r0
        LDPC    r0, .Lpack_shl23_target
        JALR    s7, r0
        MOV     r3, r1
        MFS     r1, s4
        MFS     r0, s3
        MTS     s7, r0
#endif
        OR      r1, r1, r3
        OR      r1, r1, r2
        RET     S7
        .size __riscc_pack_sf, . - __riscc_pack_sf

        .p2align 2
.Lpack_overflow:
        .long   0x08000000
.Lpack_hidden:
        .long   0x04000000
.Lpack_fraction:
        .long   0x007fffff
.Lpack_infinity:
        .long   0x7f800000
#ifndef __RISCC_FULL__
.Lpack_shl23_target:
        .long   __riscc_shlsi23
#endif

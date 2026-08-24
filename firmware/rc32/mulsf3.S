/* Full IEEE-754 binary32 multiplication for RC32. */

        .section .text.__mulsf3,"ax",@progbits
        .p2align 2
.Lmul_sign_mask:
        .long   0x80000000
.Lmul_fraction_mask:
        .long   0x007fffff
.Lmul_hidden:
        .long   0x00800000
.Lmul_quiet_bit:
        .long   0x00400000
.Lmul_qnan:
        .long   0x7fc00000
.Lmul_infinity:
        .long   0x7f800000
#ifndef __RISCC_FULL__
#ifdef __RISCC_SYS__
.Lmul_shr23_target_1:
        .long   call_target(__riscc_lshrsi23)
.Lmul_shr23_target_2:
        .long   call_target(__riscc_lshrsi23)
#else
.Lmul_shr23_target_1:
.Lmul_shr23_target_2:
        .long   __riscc_lshrsi23
#endif
#endif

        .p2align 1
        .global __mulsf3
        .hidden __mulsf3
        .type __mulsf3,@function
__mulsf3:
        ADDI    r7, -12
        ST      r4, [r7 + 0]
        ST      r5, [r7 + 4]
        ST      r6, [r7 + 8]
#ifndef __RISCC_FULL__
        MTS     s2, r1
        MTS     s4, r2
#endif
        MFS     r0, s7
        MTS     s3, r0

        XOR     r0, r1, r2
        LDPC    r3, .Lmul_sign_mask
        AND     r5, r0, r3

#ifdef __RISCC_FULL__
        MOV     r3, r1
        SRLI    r3, r3, 8
        SRLI    r3, r3, 8
        SRLI    r3, r3, 7
        ANDI    r3, 255
        MOV     r4, r2
        SRLI    r4, r4, 8
        SRLI    r4, r4, 8
        SRLI    r4, r4, 7
        ANDI    r4, 255
#else
#ifdef __RISCC_SYS__
        .reloc  ., R_RISCC_RELAX_CALL, .Lmul_shr23_target_1
#endif
        LDPC    r0, .Lmul_shr23_target_1
        JALR    s7, r0
        MOV     r3, r1
        ANDI    r3, 255
        MFS     r1, s4
#ifdef __RISCC_SYS__
        .reloc  ., R_RISCC_RELAX_CALL, .Lmul_shr23_target_2
#endif
        LDPC    r0, .Lmul_shr23_target_2
        JALR    s7, r0
        MOV     r4, r1
        ANDI    r4, 255
        MFS     r1, s2
        MFS     r2, s4
#endif

        LDI     r0, 255
        SUB     r0, r3, r0
        BNEZ    .Lmul_check_right_special
        LDPC    r0, .Lmul_fraction_mask
        AND     r0, r1, r0
        BNEZ    .Lmul_quiet_left
        LDI     r0, 255
        SUB     r0, r4, r0
        BNEZ    .Lmul_left_infinity
        LDPC    r0, .Lmul_fraction_mask
        AND     r0, r2, r0
        BNEZ    .Lmul_quiet_right
.Lmul_left_infinity:
        MOV     r0, r2
        ADD     r0, r0, r0
        BEQZ    .Lmul_return_qnan
        JMP8    .Lmul_return_infinity

.Lmul_check_right_special:
        LDI     r0, 255
        SUB     r0, r4, r0
        BNEZ    .Lmul_finite
        LDPC    r0, .Lmul_fraction_mask
        AND     r0, r2, r0
        BNEZ    .Lmul_quiet_right
        MOV     r0, r1
        ADD     r0, r0, r0
        BEQZ    .Lmul_return_qnan
        JMP8    .Lmul_return_infinity

.Lmul_quiet_left:
        LDPC    r0, .Lmul_quiet_bit
        OR      r1, r1, r0
        JMP8    .Lmul_return
.Lmul_quiet_right:
        MOV     r1, r2
        LDPC    r0, .Lmul_quiet_bit
        OR      r1, r1, r0
        JMP8    .Lmul_return
.Lmul_return_qnan:
        LDPC    r1, .Lmul_qnan
        JMP8    .Lmul_return
.Lmul_return_infinity:
        LDPC    r1, .Lmul_infinity
        OR      r1, r1, r5
.Lmul_return:
        MFS     r0, s3
        MTS     s7, r0
        LD      r4, [r7 + 0]
        LD      r5, [r7 + 4]
        LD      r6, [r7 + 8]
        ADDI    r7, 12
        RET     S7

.Lmul_finite:
        MOV     r0, r1
        ADD     r0, r0, r0
        BEQZ    .Lmul_zero
        MOV     r0, r2
        ADD     r0, r0, r0
        BEQZ    .Lmul_zero

        LDPC    r0, .Lmul_fraction_mask
        AND     r1, r1, r0
        AND     r2, r2, r0
        MOV     r0, r3
        BNEZ    .Lmul_left_normal
        LDI     r3, 1
        JMP8    .Lmul_left_ready
.Lmul_left_normal:
        LDPC    r0, .Lmul_hidden
        OR      r1, r1, r0
.Lmul_left_ready:
        MOV     r0, r4
        BNEZ    .Lmul_right_normal
        LDI     r4, 1
        JMP8    .Lmul_right_ready
.Lmul_right_normal:
        LDPC    r0, .Lmul_hidden
        OR      r2, r2, r0
.Lmul_right_ready:
        ADD     r3, r3, r4
        ADDI    r3, -127

.Lmul_normalize_left:
        LDPC    r0, .Lmul_hidden
        AND     r0, r1, r0
        BNEZ    .Lmul_normalize_right
        ADD     r1, r1, r1
        ADDI    r3, -1
        JMP8    .Lmul_normalize_left
.Lmul_normalize_right:
        LDPC    r0, .Lmul_hidden
        AND     r0, r2, r0
        BNEZ    .Lmul_multiply_ready
        ADD     r2, r2, r2
        ADDI    r3, -1
        JMP8    .Lmul_normalize_right

.Lmul_multiply_ready:
        MTS     s2, r5                 // preserve result sign
        LDI     r4, 0                  // multiplicand high
        LDI     r5, 0                  // product low
        LDI     r6, 0                  // product high
.Lmul_multiply_loop:
        MOV     r0, r2
        ANDI    r0, 1
        BEQZ    .Lmul_no_add
        MOV     r0, r5
        ADD     r5, r5, r1
        SLTU    r0, r5, r0
        ADD     r6, r6, r4
        ADD     r6, r6, r0
.Lmul_no_add:
        FSL1    r4, r1
        ADD     r1, r1, r1
        SRLI    r2, r2, 1
        MOV     r0, r2
        BNEZ    .Lmul_multiply_loop

        LDPC    r0, .Lmul_bit47
        AND     r0, r6, r0
        BEQZ    .Lmul_product_bit46
        LDI     r4, 21
        ADDI    r3, 1
        JMP8    .Lmul_product_shift_ready
.Lmul_product_bit46:
        LDI     r4, 20
.Lmul_product_shift_ready:
        LDI     r2, 0                  // discarded-bit sticky
.Lmul_product_shift:
        MOV     r0, r5
        ANDI    r0, 1
        OR      r2, r2, r0
        FSR1    r5, r6
        SRLI    r6, r6, 1
        ADDI    r4, -1
        MOV     r0, r4
        BNEZ    .Lmul_product_shift
        OR      r1, r5, r2
        MFS     r2, s2
        JMP8    .Lmul_pack

.Lmul_zero:
        LDI     r1, 0
        OR      r1, r1, r5
        JMP8    .Lmul_return

.Lmul_pack:
        MFS     r0, s3
        MTS     s7, r0
        LD      r4, [r7 + 0]
        LD      r5, [r7 + 4]
        LD      r6, [r7 + 8]
        ADDI    r7, 12
#if defined(__RISCC_SYS__) || defined(__RISCC_FULL__)
        .reloc  ., R_RISCC_RELAX_TAIL, .Lmul_pack_target
#endif
        LDPC    r0, .Lmul_pack_target
        JMP     r0
.Lmul_end:
        .size __mulsf3, .Lmul_end - __mulsf3

        .p2align 2
.Lmul_bit47:
        .long   0x00008000
.Lmul_pack_target:
#if defined(__RISCC_SYS__) || defined(__RISCC_FULL__)
        .long   call_target(__riscc_pack_sf)
#else
        .long   __riscc_pack_sf
#endif

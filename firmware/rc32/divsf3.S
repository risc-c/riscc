/* Full IEEE-754 binary32 division for RC32. */

        .section .text.__divsf3,"ax",@progbits
        .p2align 2
.Ldiv_sign_mask:
        .long   0x80000000
.Ldiv_fraction_mask:
        .long   0x007fffff
.Ldiv_hidden:
        .long   0x00800000
.Ldiv_quiet_bit:
        .long   0x00400000
.Ldiv_qnan:
        .long   0x7fc00000
.Ldiv_infinity:
        .long   0x7f800000
#ifndef __RISCC_FULL__
#ifdef __RISCC_SYS__
.Ldiv_shr23_target_1:
        .long   call_target(__riscc_lshrsi23)
.Ldiv_shr23_target_2:
        .long   call_target(__riscc_lshrsi23)
#else
.Ldiv_shr23_target_1:
.Ldiv_shr23_target_2:
        .long   __riscc_lshrsi23
#endif
#endif

        .p2align 1
        .global __divsf3
        .hidden __divsf3
        .type __divsf3,@function
__divsf3:
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
        LDPC    r3, .Ldiv_sign_mask
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
        .reloc  ., R_RISCC_RELAX_CALL, .Ldiv_shr23_target_1
#endif
        LDPC    r0, .Ldiv_shr23_target_1
        JALR    s7, r0
        MOV     r3, r1
        ANDI    r3, 255
        MFS     r1, s4
#ifdef __RISCC_SYS__
        .reloc  ., R_RISCC_RELAX_CALL, .Ldiv_shr23_target_2
#endif
        LDPC    r0, .Ldiv_shr23_target_2
        JALR    s7, r0
        MOV     r4, r1
        ANDI    r4, 255
        MFS     r1, s2
        MFS     r2, s4
#endif

        LDI     r0, 255
        SUB     r0, r3, r0
        BNEZ    .Ldiv_check_right_special
        LDPC    r0, .Ldiv_fraction_mask
        AND     r0, r1, r0
        BNEZ    .Ldiv_quiet_left
        LDI     r0, 255
        SUB     r0, r4, r0
        BNEZ    .Ldiv_return_infinity
        LDPC    r0, .Ldiv_fraction_mask
        AND     r0, r2, r0
        BNEZ    .Ldiv_quiet_right
        JMP8    .Ldiv_return_qnan

.Ldiv_check_right_special:
        LDI     r0, 255
        SUB     r0, r4, r0
        BNEZ    .Ldiv_finite
        LDPC    r0, .Ldiv_fraction_mask
        AND     r0, r2, r0
        BNEZ    .Ldiv_quiet_right
        JMP8    .Ldiv_return_zero

.Ldiv_quiet_left:
        LDPC    r0, .Ldiv_quiet_bit
        OR      r1, r1, r0
        JMP8    .Ldiv_return
.Ldiv_quiet_right:
        MOV     r1, r2
        LDPC    r0, .Ldiv_quiet_bit
        OR      r1, r1, r0
        JMP8    .Ldiv_return
.Ldiv_return_qnan:
        LDPC    r1, .Ldiv_qnan
        JMP8    .Ldiv_return
.Ldiv_return_infinity:
        LDPC    r1, .Ldiv_infinity
        OR      r1, r1, r5
        JMP8    .Ldiv_return
.Ldiv_return_zero:
        LDI     r1, 0
        OR      r1, r1, r5
.Ldiv_return:
        MFS     r0, s3
        MTS     s7, r0
        LD      r4, [r7 + 0]
        LD      r5, [r7 + 4]
        LD      r6, [r7 + 8]
        ADDI    r7, 12
        RET     S7

.Ldiv_finite:
        MOV     r0, r1
        ADD     r0, r0, r0
        BNEZ    .Ldiv_numerator_nonzero
        MOV     r0, r2
        ADD     r0, r0, r0
        BEQZ    .Ldiv_return_qnan
        JMP8    .Ldiv_return_zero
.Ldiv_numerator_nonzero:
        MOV     r0, r2
        ADD     r0, r0, r0
        BEQZ    .Ldiv_return_infinity

        LDPC    r0, .Ldiv_fraction_mask
        AND     r1, r1, r0
        AND     r2, r2, r0
        MOV     r0, r3
        BNEZ    .Ldiv_left_normal
        LDI     r3, 1
        JMP8    .Ldiv_left_ready
.Ldiv_left_normal:
        LDPC    r0, .Ldiv_hidden
        OR      r1, r1, r0
.Ldiv_left_ready:
        MOV     r0, r4
        BNEZ    .Ldiv_right_normal
        LDI     r4, 1
        JMP8    .Ldiv_right_ready
.Ldiv_right_normal:
        LDPC    r0, .Ldiv_hidden
        OR      r2, r2, r0
.Ldiv_right_ready:
        SUB     r3, r3, r4
        ADDI    r3, 127

.Ldiv_normalize_left:
        LDPC    r0, .Ldiv_hidden
        AND     r0, r1, r0
        BNEZ    .Ldiv_normalize_right
        ADD     r1, r1, r1
        ADDI    r3, -1
        JMP8    .Ldiv_normalize_left
.Ldiv_normalize_right:
        LDPC    r0, .Ldiv_hidden
        AND     r0, r2, r0
        BNEZ    .Ldiv_normalized
        ADD     r2, r2, r2
        ADDI    r3, 1
        JMP8    .Ldiv_normalize_right

.Ldiv_normalized:
        SLTU    r0, r1, r2
        BEQZ    .Ldiv_quotient_ready
        ADD     r1, r1, r1
        ADDI    r3, -1
.Ldiv_quotient_ready:
        MTS     s2, r5                 // preserve result sign
        LDI     r4, 0                  // quotient
        LDI     r5, 27
.Ldiv_quotient_loop:
        ADD     r4, r4, r4
        SLTU    r0, r1, r2
        BNEZ    .Ldiv_no_subtract
        SUB     r1, r1, r2
        ORI     r4, 1
.Ldiv_no_subtract:
        ADD     r1, r1, r1
        ADDI    r5, -1
        MOV     r0, r5
        BNEZ    .Ldiv_quotient_loop
        MOV     r0, r1
        BEQZ    .Ldiv_exact
        ORI     r4, 1
.Ldiv_exact:
        MOV     r1, r4
        MFS     r2, s2

        MFS     r0, s3
        MTS     s7, r0
        LD      r4, [r7 + 0]
        LD      r5, [r7 + 4]
        LD      r6, [r7 + 8]
        ADDI    r7, 12
#if defined(__RISCC_SYS__) || defined(__RISCC_FULL__)
        .reloc  ., R_RISCC_RELAX_TAIL, .Ldiv_pack_target
#endif
        LDPC    r0, .Ldiv_pack_target
        JMP     r0
.Ldiv_end:
        .size __divsf3, .Ldiv_end - __divsf3

        .p2align 2
.Ldiv_pack_target:
#if defined(__RISCC_SYS__) || defined(__RISCC_FULL__)
        .long   call_target(__riscc_pack_sf)
#else
        .long   __riscc_pack_sf
#endif

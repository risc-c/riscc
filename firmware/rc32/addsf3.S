/* Full IEEE-754 binary32 addition for RC32. */

        .section .text.__addsf3,"ax",@progbits
        .p2align 2
.Ladd_sign_mask:
        .long   0x80000000
.Ladd_fraction_mask:
        .long   0x007fffff
.Ladd_hidden:
        .long   0x00800000
.Ladd_quiet_bit:
        .long   0x00400000
.Ladd_qnan:
        .long   0x7fc00000
#ifndef __RISCC_FULL__
#ifdef __RISCC_SYS__
.Ladd_shr23_target_1:
        .long   call_target(__riscc_lshrsi23)
.Ladd_shr23_target_2:
        .long   call_target(__riscc_lshrsi23)
#else
.Ladd_shr23_target_1:
.Ladd_shr23_target_2:
        .long   __riscc_lshrsi23
#endif
#endif

        .p2align 1
        .global __addsf3
        .hidden __addsf3
        .type __addsf3,@function
__addsf3:
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

        LDPC    r3, .Ladd_sign_mask
        AND     r5, r1, r3
        AND     r6, r2, r3

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
        .reloc  ., R_RISCC_RELAX_CALL, .Ladd_shr23_target_1
#endif
        LDPC    r0, .Ladd_shr23_target_1
        JALR    s7, r0
        MOV     r3, r1
        ANDI    r3, 255
        MFS     r1, s4
#ifdef __RISCC_SYS__
        .reloc  ., R_RISCC_RELAX_CALL, .Ladd_shr23_target_2
#endif
        LDPC    r0, .Ladd_shr23_target_2
        JALR    s7, r0
        MOV     r4, r1
        ANDI    r4, 255
        MFS     r1, s2
        MFS     r2, s4
#endif

        LDI     r0, 255
        SUB     r0, r3, r0
        BNEZ    .Ladd_check_right_special
        LDPC    r0, .Ladd_fraction_mask
        AND     r0, r1, r0
        BNEZ    .Ladd_quiet_left
        LDI     r0, 255
        SUB     r0, r4, r0
        BNEZ    .Ladd_return
        LDPC    r0, .Ladd_fraction_mask
        AND     r0, r2, r0
        BNEZ    .Ladd_quiet_right
        XOR     r0, r5, r6
        BNEZ    .Ladd_return_qnan
        JMP8    .Ladd_return

.Ladd_check_right_special:
        LDI     r0, 255
        SUB     r0, r4, r0
        BNEZ    .Ladd_finite
        LDPC    r0, .Ladd_fraction_mask
        AND     r0, r2, r0
        BNEZ    .Ladd_quiet_right
        MOV     r1, r2
        JMP8    .Ladd_return

.Ladd_quiet_left:
        LDPC    r0, .Ladd_quiet_bit
        OR      r1, r1, r0
        JMP8    .Ladd_return
.Ladd_quiet_right:
        MOV     r1, r2
        LDPC    r0, .Ladd_quiet_bit
        OR      r1, r1, r0
        JMP8    .Ladd_return
.Ladd_return_qnan:
        LDPC    r1, .Ladd_qnan
.Ladd_return:
        MFS     r0, s3
        MTS     s7, r0
        LD      r4, [r7 + 0]
        LD      r5, [r7 + 4]
        LD      r6, [r7 + 8]
        ADDI    r7, 12
        RET     S7

.Ladd_finite:
        /* Exact zeros return the other operand; two zeros AND their signs. */
        MOV     r0, r1
        ADD     r0, r0, r0
        BNEZ    .Ladd_left_nonzero
        MOV     r0, r2
        ADD     r0, r0, r0
        BNEZ    .Ladd_return_right
        MOV     r1, r5
        AND     r1, r1, r6
        JMP8    .Ladd_return
.Ladd_return_right:
        MOV     r1, r2
        JMP8    .Ladd_return
.Ladd_left_nonzero:
        MOV     r0, r2
        ADD     r0, r0, r0
        BEQZ    .Ladd_return

        LDPC    r0, .Ladd_fraction_mask
        AND     r1, r1, r0
        AND     r2, r2, r0
        MOV     r0, r3
        BNEZ    .Ladd_left_normal
        LDI     r3, 1
        JMP8    .Ladd_left_ready
.Ladd_left_normal:
        LDPC    r0, .Ladd_hidden
        OR      r1, r1, r0
.Ladd_left_ready:
        MOV     r0, r4
        BNEZ    .Ladd_right_normal
        LDI     r4, 1
        JMP8    .Ladd_right_ready
.Ladd_right_normal:
        LDPC    r0, .Ladd_hidden
        OR      r2, r2, r0
.Ladd_right_ready:
        SLTU    r0, r3, r4
        BNEZ    .Ladd_swap
        SUB     r0, r3, r4
        BNEZ    .Ladd_ordered
        SLTU    r0, r1, r2
        BEQZ    .Ladd_ordered
.Ladd_swap:
        MOV     r0, r1
        MOV     r1, r2
        MOV     r2, r0
        MOV     r0, r3
        MOV     r3, r4
        MOV     r4, r0
        MOV     r0, r5
        MOV     r5, r6
        MOV     r6, r0
.Ladd_ordered:
        XOR     r0, r5, r6
        MTS     s2, r0
        .rept 3
        ADD     r1, r1, r1
        ADD     r2, r2, r2
        .endr

        SUB     r4, r3, r4
        LDI     r6, 0                  // alignment sticky
        LDI     r0, 32
        SLTU    r0, r4, r0
        BNEZ    .Ladd_align_test
        LDI     r2, 1
        JMP8    .Ladd_aligned
.Ladd_align_loop:
        MOV     r0, r2
        ANDI    r0, 1
        OR      r6, r6, r0
        SRLI    r2, r2, 1
        ADDI    r4, -1
.Ladd_align_test:
        MOV     r0, r4
        BNEZ    .Ladd_align_loop
        OR      r2, r2, r6
.Ladd_aligned:
        MFS     r0, s2
        BNEZ    .Ladd_subtract

        ADD     r1, r1, r2
        LDPC    r0, .Ladd_extended_overflow
        AND     r0, r1, r0
        BEQZ    .Ladd_pack
        MOV     r0, r1
        ANDI    r0, 1
        SRLI    r1, r1, 1
        OR      r1, r1, r0
        ADDI    r3, 1
        JMP8    .Ladd_pack

.Ladd_subtract:
        SUB     r1, r1, r2
        MOV     r0, r1
        BEQZ    .Ladd_cancelled
.Ladd_normalize:
        LDPC    r0, .Ladd_extended_hidden
        AND     r0, r1, r0
        BNEZ    .Ladd_pack
        CMPI    r3, 1
        BEQZ    .Ladd_pack
        ADD     r1, r1, r1
        ADDI    r3, -1
        JMP8    .Ladd_normalize

.Ladd_cancelled:
        LDI     r1, 0
        MFS     r0, s3
        MTS     s7, r0
        LD      r4, [r7 + 0]
        LD      r5, [r7 + 4]
        LD      r6, [r7 + 8]
        ADDI    r7, 12
        RET     S7

.Ladd_pack:
        MOV     r2, r5
        MFS     r0, s3
        MTS     s7, r0
        LD      r4, [r7 + 0]
        LD      r5, [r7 + 4]
        LD      r6, [r7 + 8]
        ADDI    r7, 12
#if defined(__RISCC_SYS__) || defined(__RISCC_FULL__)
        .reloc  ., R_RISCC_RELAX_TAIL, .Ladd_pack_target
#endif
        LDPC    r0, .Ladd_pack_target
        JMP     r0
.Ladd_end:
        .size __addsf3, .Ladd_end - __addsf3

        .p2align 2
.Ladd_extended_hidden:
        .long   0x04000000
.Ladd_extended_overflow:
        .long   0x08000000
.Ladd_pack_target:
#if defined(__RISCC_SYS__) || defined(__RISCC_FULL__)
        .long   call_target(__riscc_pack_sf)
#else
        .long   __riscc_pack_sf
#endif

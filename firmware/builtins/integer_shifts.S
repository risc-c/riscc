/*
 * Wide variable shifts kept entirely in ABI argument/result registers.
 *
 * Mainline uses one-bit funnel shifts.  Nano has no funnel instructions, so
 * left-shift carries are detected with unsigned comparisons and right-shift
 * carries use a single conditional insertion of bit 15.  Counts passed to
 * these compiler helpers are in range; zero is handled explicitly.
 */

#ifdef __RISCC_NANO__
#define WIDE_RETURN RET r6
#else
#define WIDE_RETURN RETS
#endif

        .macro FUNCTION name
        .section .text.\name,"ax",@progbits
        .p2align 1
        .global \name
        .hidden \name
        .type \name,@function
\name:
        .endm

        FUNCTION __ashlsi3
        MOV     r0, r3
        BEQZ    .Lshlsi_done
.Lshlsi_loop:
#ifdef __RISCC_NANO__
        MOV     r4, r1
        ADD     r1, r1, r1
        SLTU    r0, r1, r4
        ADD     r2, r2, r2
        OR      r2, r2, r0
#else
        FSL1    r2, r2, r1
        ADD     r1, r1, r1
#endif
        ADDI    r3, -1
        MOV     r0, r3
        BNEZ    .Lshlsi_loop
.Lshlsi_done:
        WIDE_RETURN
        .size __ashlsi3, . - __ashlsi3

        FUNCTION __lshrsi3
        MOV     r0, r3
        BEQZ    .Llshrsi_done
#ifdef __RISCC_NANO__
        LUI     r4, 128
#endif
.Llshrsi_loop:
#ifdef __RISCC_NANO__
        MOV     r0, r2
        ANDI    r0, 1
        SHRI    r1, r1, 1
        BEQZ    .Llshrsi_no_carry
        OR      r1, r1, r4
.Llshrsi_no_carry:
        SHRI    r2, r2, 1
#else
        FSR1    r1, r1, r2
        SHRI    r2, r2, 1
#endif
        ADDI    r3, -1
        MOV     r0, r3
        BNEZ    .Llshrsi_loop
.Llshrsi_done:
        WIDE_RETURN
        .size __lshrsi3, . - __lshrsi3

        FUNCTION __ashrsi3
        MOV     r0, r3
        BEQZ    .Lashrsi_done
#ifdef __RISCC_NANO__
        LUI     r4, 128
#endif
.Lashrsi_loop:
#ifdef __RISCC_NANO__
        MOV     r0, r2
        ANDI    r0, 1
        SHRI    r1, r1, 1
        BEQZ    .Lashrsi_no_carry
        OR      r1, r1, r4
.Lashrsi_no_carry:
        SARI    r2, r2, 1
#else
        FSR1    r1, r1, r2
        SARI    r2, r2, 1
#endif
        ADDI    r3, -1
        MOV     r0, r3
        BNEZ    .Lashrsi_loop
.Lashrsi_done:
        WIDE_RETURN
        .size __ashrsi3, . - __ashrsi3

        FUNCTION __ashldi3
#ifdef __RISCC_NANO__
        STW     r5, [r7 - 2]
        LDW     r0, [r7 + 0]
        STW     r0, [r7 - 4]
#else
        MTS     s3, r5
        LDW     r5, [r7 + 0]
        MOV     r0, r5
#endif
        BEQZ    .Lshldi_done
.Lshldi_loop:
#ifdef __RISCC_NANO__
        /* Build each upper result from the still-unmodified lower limb. */
        MOV     r5, r3
        ADD     r0, r5, r5
        SLTU    r0, r0, r5
        ADD     r4, r4, r4
        OR      r4, r4, r0
        MOV     r5, r2
        ADD     r0, r5, r5
        SLTU    r0, r0, r5
        ADD     r3, r3, r3
        OR      r3, r3, r0
        MOV     r5, r1
        ADD     r0, r5, r5
        SLTU    r0, r0, r5
        ADD     r2, r2, r2
        OR      r2, r2, r0
        ADD     r1, r1, r1
        LDW     r0, [r7 - 4]
        ADDI    r0, -1
        STW     r0, [r7 - 4]
#else
        FSL1    r4, r4, r3
        FSL1    r3, r3, r2
        FSL1    r2, r2, r1
        ADD     r1, r1, r1
        ADDI    r5, -1
        MOV     r0, r5
#endif
        BNEZ    .Lshldi_loop
.Lshldi_done:
#ifdef __RISCC_NANO__
        LDW     r5, [r7 - 2]
#else
        MFS     r5, s3
#endif
        WIDE_RETURN
        .size __ashldi3, . - __ashldi3

        FUNCTION __lshrdi3
#ifdef __RISCC_NANO__
        STW     r5, [r7 - 2]
        LDW     r0, [r7 + 0]
        STW     r0, [r7 - 4]
        LUI     r5, 128
#else
        MTS     s3, r5
        LDW     r5, [r7 + 0]
        MOV     r0, r5
#endif
        BEQZ    .Llshrdi_done
.Llshrdi_loop:
#ifdef __RISCC_NANO__
        MOV     r0, r2
        ANDI    r0, 1
        SHRI    r1, r1, 1
        BEQZ    .Llshrdi_carry1_done
        OR      r1, r1, r5
.Llshrdi_carry1_done:
        MOV     r0, r3
        ANDI    r0, 1
        SHRI    r2, r2, 1
        BEQZ    .Llshrdi_carry2_done
        OR      r2, r2, r5
.Llshrdi_carry2_done:
        MOV     r0, r4
        ANDI    r0, 1
        SHRI    r3, r3, 1
        BEQZ    .Llshrdi_carry3_done
        OR      r3, r3, r5
.Llshrdi_carry3_done:
        SHRI    r4, r4, 1
        LDW     r0, [r7 - 4]
        ADDI    r0, -1
        STW     r0, [r7 - 4]
#else
        FSR1    r1, r1, r2
        FSR1    r2, r2, r3
        FSR1    r3, r3, r4
        SHRI    r4, r4, 1
        ADDI    r5, -1
        MOV     r0, r5
#endif
        BNEZ    .Llshrdi_loop
.Llshrdi_done:
#ifdef __RISCC_NANO__
        LDW     r5, [r7 - 2]
#else
        MFS     r5, s3
#endif
        WIDE_RETURN
        .size __lshrdi3, . - __lshrdi3

        FUNCTION __ashrdi3
#ifdef __RISCC_NANO__
        STW     r5, [r7 - 2]
        LDW     r0, [r7 + 0]
        STW     r0, [r7 - 4]
        LUI     r5, 128
#else
        MTS     s3, r5
        LDW     r5, [r7 + 0]
        MOV     r0, r5
#endif
        BEQZ    .Lashrdi_done
.Lashrdi_loop:
#ifdef __RISCC_NANO__
        MOV     r0, r2
        ANDI    r0, 1
        SHRI    r1, r1, 1
        BEQZ    .Lashrdi_carry1_done
        OR      r1, r1, r5
.Lashrdi_carry1_done:
        MOV     r0, r3
        ANDI    r0, 1
        SHRI    r2, r2, 1
        BEQZ    .Lashrdi_carry2_done
        OR      r2, r2, r5
.Lashrdi_carry2_done:
        MOV     r0, r4
        ANDI    r0, 1
        SHRI    r3, r3, 1
        BEQZ    .Lashrdi_carry3_done
        OR      r3, r3, r5
.Lashrdi_carry3_done:
        SARI    r4, r4, 1
        LDW     r0, [r7 - 4]
        ADDI    r0, -1
        STW     r0, [r7 - 4]
#else
        FSR1    r1, r1, r2
        FSR1    r2, r2, r3
        FSR1    r3, r3, r4
        SARI    r4, r4, 1
        ADDI    r5, -1
        MOV     r0, r5
#endif
        BNEZ    .Lashrdi_loop
.Lashrdi_done:
#ifdef __RISCC_NANO__
        LDW     r5, [r7 - 2]
#else
        MFS     r5, s3
#endif
        WIDE_RETURN
        .size __ashrdi3, . - __ashrdi3

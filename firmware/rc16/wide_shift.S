/*
 * RC16 wide variable shifts kept entirely in ABI argument/result registers.
 *
 * Mainline uses one-bit funnel shifts.  Nano has no funnel instructions, so
 * left-shift carries are detected with unsigned comparisons and right-shift
 * carries use a single conditional insertion of bit 15.  Counts passed to
 * these compiler helpers are in range; zero is handled explicitly.
 */

#ifdef __RISCC_NANO__
#define WIDE_RETURN NANO_RETURN

        .macro NANO_SAVE
        ST      r4, [r7 - 6]
        .endm

        .macro NANO_RETURN
        LD      r4, [r7 - 6]
        JMP     r6
        .endm

        .macro NANO_RETURN64
        LD      r0, [r7 - 8]
        ST      r1, [r0 + 0]
        ST      r2, [r0 + 2]
        ST      r3, [r0 + 4]
        ST      r4, [r0 + 6]
        NANO_RETURN
        .endm
#else
#define WIDE_RETURN RET S7

        /*
         * Wide results use an sret pointer in r1; the four input limbs and
         * shift count are stack arguments.  The loops use r1:r4 internally
         * and keep the remaining count in caller-saved r0.
         */
        .macro WIDE_DI_SAVE
        MTS     s2, r4
        MTS     s3, r1
        LD      r1, [r7 + 0]
        LD      r2, [r7 + 2]
        LD      r3, [r7 + 4]
        LD      r4, [r7 + 6]
        .endm

        .macro WIDE_DI_RETURN
        MFS     r0, s3
        ST      r1, [r0 + 0]
        ST      r2, [r0 + 2]
        ST      r3, [r0 + 4]
        ST      r4, [r0 + 6]
        MFS     r4, s2
        RET     S7
        .endm
#endif

        .macro FUNCTION name
        .section .text.\name,"ax",@progbits
        .p2align 1
        .global \name
        .hidden \name
        .type \name,@function
\name:
#ifdef __RISCC_NANO__
        NANO_SAVE
#endif
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
        FSL1    r2, r1
        ADD     r1, r1, r1
#endif
#ifdef __RISCC_NANO__
        ADDI    r3, -1
        MOV     r0, r3
#else
        ADDI    r0, -1
#endif
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
        SRLI    r1, r1, 1
        BEQZ    .Llshrsi_no_carry
        OR      r1, r1, r4
.Llshrsi_no_carry:
        SRLI    r2, r2, 1
#else
        FSR1    r1, r2
        SRLI    r2, r2, 1
#endif
#ifdef __RISCC_NANO__
        ADDI    r3, -1
        MOV     r0, r3
#else
        ADDI    r0, -1
#endif
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
        SRLI    r1, r1, 1
        BEQZ    .Lashrsi_no_carry
        OR      r1, r1, r4
.Lashrsi_no_carry:
        SRAI    r2, r2, 1
#else
        FSR1    r1, r2
        SRAI    r2, r2, 1
#endif
#ifdef __RISCC_NANO__
        ADDI    r3, -1
        MOV     r0, r3
#else
        ADDI    r0, -1
#endif
        BNEZ    .Lashrsi_loop
.Lashrsi_done:
        WIDE_RETURN
        .size __ashrsi3, . - __ashrsi3

        FUNCTION __ashldi3
#ifdef __RISCC_NANO__
        ST     r5, [r7 - 2]
        ST     r1, [r7 - 8]
        LD     r1, [r7 + 0]
        LD     r2, [r7 + 2]
        LD     r3, [r7 + 4]
        LD     r4, [r7 + 6]
        LD     r0, [r7 + 8]
        ST     r0, [r7 - 4]
#else
        WIDE_DI_SAVE
        LD      r0, [r7 + 8]
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
        LD     r0, [r7 - 4]
        ADDI    r0, -1
        ST     r0, [r7 - 4]
#else
        FSL1    r4, r3
        FSL1    r3, r2
        FSL1    r2, r1
        ADD     r1, r1, r1
        ADDI    r0, -1
#endif
        BNEZ    .Lshldi_loop
.Lshldi_done:
#ifdef __RISCC_NANO__
        LD     r5, [r7 - 2]
#else
        WIDE_DI_RETURN
#endif
#ifdef __RISCC_NANO__
        NANO_RETURN64
#endif
        .size __ashldi3, . - __ashldi3

        FUNCTION __lshrdi3
#ifdef __RISCC_NANO__
        ST     r5, [r7 - 2]
        ST     r1, [r7 - 8]
        LD     r1, [r7 + 0]
        LD     r2, [r7 + 2]
        LD     r3, [r7 + 4]
        LD     r4, [r7 + 6]
        LD     r0, [r7 + 8]
        ST     r0, [r7 - 4]
        LUI     r5, 128
#else
        WIDE_DI_SAVE
        LD      r0, [r7 + 8]
#endif
        BEQZ    .Llshrdi_done
.Llshrdi_loop:
#ifdef __RISCC_NANO__
        MOV     r0, r2
        ANDI    r0, 1
        SRLI    r1, r1, 1
        BEQZ    .Llshrdi_carry1_done
        OR      r1, r1, r5
.Llshrdi_carry1_done:
        MOV     r0, r3
        ANDI    r0, 1
        SRLI    r2, r2, 1
        BEQZ    .Llshrdi_carry2_done
        OR      r2, r2, r5
.Llshrdi_carry2_done:
        MOV     r0, r4
        ANDI    r0, 1
        SRLI    r3, r3, 1
        BEQZ    .Llshrdi_carry3_done
        OR      r3, r3, r5
.Llshrdi_carry3_done:
        SRLI    r4, r4, 1
        LD     r0, [r7 - 4]
        ADDI    r0, -1
        ST     r0, [r7 - 4]
#else
        FSR1    r1, r2
        FSR1    r2, r3
        FSR1    r3, r4
        SRLI    r4, r4, 1
        ADDI    r0, -1
#endif
        BNEZ    .Llshrdi_loop
.Llshrdi_done:
#ifdef __RISCC_NANO__
        LD     r5, [r7 - 2]
#else
        WIDE_DI_RETURN
#endif
#ifdef __RISCC_NANO__
        NANO_RETURN64
#endif
        .size __lshrdi3, . - __lshrdi3

        FUNCTION __ashrdi3
#ifdef __RISCC_NANO__
        ST     r5, [r7 - 2]
        ST     r1, [r7 - 8]
        LD     r1, [r7 + 0]
        LD     r2, [r7 + 2]
        LD     r3, [r7 + 4]
        LD     r4, [r7 + 6]
        LD     r0, [r7 + 8]
        ST     r0, [r7 - 4]
        LUI     r5, 128
#else
        WIDE_DI_SAVE
        LD      r0, [r7 + 8]
#endif
        BEQZ    .Lashrdi_done
.Lashrdi_loop:
#ifdef __RISCC_NANO__
        MOV     r0, r2
        ANDI    r0, 1
        SRLI    r1, r1, 1
        BEQZ    .Lashrdi_carry1_done
        OR      r1, r1, r5
.Lashrdi_carry1_done:
        MOV     r0, r3
        ANDI    r0, 1
        SRLI    r2, r2, 1
        BEQZ    .Lashrdi_carry2_done
        OR      r2, r2, r5
.Lashrdi_carry2_done:
        MOV     r0, r4
        ANDI    r0, 1
        SRLI    r3, r3, 1
        BEQZ    .Lashrdi_carry3_done
        OR      r3, r3, r5
.Lashrdi_carry3_done:
        SRAI    r4, r4, 1
        LD     r0, [r7 - 4]
        ADDI    r0, -1
        ST     r0, [r7 - 4]
#else
        FSR1    r1, r2
        FSR1    r2, r3
        FSR1    r3, r4
        SRAI    r4, r4, 1
        ADDI    r0, -1
#endif
        BNEZ    .Lashrdi_loop
.Lashrdi_done:
#ifdef __RISCC_NANO__
        LD     r5, [r7 - 2]
#else
        WIDE_DI_RETURN
#endif
#ifdef __RISCC_NANO__
        NANO_RETURN64
#endif
        .size __ashrdi3, . - __ashrdi3

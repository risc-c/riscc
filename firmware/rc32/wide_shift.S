/* RC32 64-bit shifts. The low and high words remain in r1:r2. */

        .macro RC32_FUNCTION name
        .section .text.\name,"ax",@progbits
        .p2align 1
        .global \name
        .hidden \name
        .type \name,@function
\name:
        .endm

        RC32_FUNCTION __ashldi3
        MOV     r0, r3
        BEQZ    .Lashldi_done
.Lashldi_loop:
        FSL1    r2, r1
        ADD     r1, r1, r1
        ADDI    r3, -1
        MOV     r0, r3
        BNEZ    .Lashldi_loop
.Lashldi_done:
        RET     S7
        .size __ashldi3, . - __ashldi3

        RC32_FUNCTION __lshrdi3
        MOV     r0, r3
        BEQZ    .Llshrdi_done
.Llshrdi_loop:
        FSR1    r1, r2
        SRLI    r2, r2, 1
        ADDI    r3, -1
        MOV     r0, r3
        BNEZ    .Llshrdi_loop
.Llshrdi_done:
        RET     S7
        .size __lshrdi3, . - __lshrdi3

        RC32_FUNCTION __ashrdi3
        MOV     r0, r3
        BEQZ    .Lashrdi_done
.Lashrdi_loop:
        FSR1    r1, r2
        SRAI    r2, r2, 1
        ADDI    r3, -1
        MOV     r0, r3
        BNEZ    .Lashrdi_loop
.Lashrdi_done:
        RET     S7
        .size __ashrdi3, . - __ashrdi3

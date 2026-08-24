/* Compact RC32 wide negation, comparison, and bit-count helpers. */

        .section .text.__riscc_misc,"ax",@progbits
        .p2align 1

        .global __negdi2
        .hidden __negdi2
        .type __negdi2,@function
__negdi2:
        MOV     r3, r1
        LDI     r0, 0
        SUB     r1, r0, r1
        LDI     r0, 0
        SUB     r2, r0, r2
        MOV     r0, r3
        BEQZ    .Lnegdi_done
        ADDI    r2, -1
.Lnegdi_done:
        RET     S7
        .size __negdi2, . - __negdi2

        .global __ucmpdi2
        .hidden __ucmpdi2
        .type __ucmpdi2,@function
__ucmpdi2:
        LD      r3, [r7 + 4]
        SUB     r0, r2, r3
        BNEZ    .Lucmpdi_high
        LD      r3, [r7 + 0]
        SUB     r0, r1, r3
        BEQZ    .Lcmpdi_equal
        SLTU    r0, r1, r3
        BNEZ    .Lcmpdi_less
        JMP8    .Lcmpdi_greater
.Lucmpdi_high:
        SLTU    r0, r2, r3
        BNEZ    .Lcmpdi_less
        JMP8    .Lcmpdi_greater
        .size __ucmpdi2, . - __ucmpdi2

        .global __cmpdi2
        .hidden __cmpdi2
        .type __cmpdi2,@function
__cmpdi2:
        LD      r3, [r7 + 4]
        SUB     r0, r2, r3
        BNEZ    .Lcmpdi_high
        LD      r3, [r7 + 0]
        SUB     r0, r1, r3
        BEQZ    .Lcmpdi_equal
        SLTU    r0, r1, r3
        BNEZ    .Lcmpdi_less
        JMP8    .Lcmpdi_greater
.Lcmpdi_high:
        SLT     r0, r2, r3
        BNEZ    .Lcmpdi_less
.Lcmpdi_greater:
        LDI     r1, 2
        RET     S7
.Lcmpdi_less:
        LDI     r1, 0
        RET     S7
.Lcmpdi_equal:
        LDI     r1, 1
        RET     S7
        .size __cmpdi2, . - __cmpdi2

        .global __clzsi2
        .hidden __clzsi2
        .type __clzsi2,@function
__clzsi2:
        LDI     r2, 0
        LDI     r3, 32
        JMP8    .Lclz_loop
        .size __clzsi2, . - __clzsi2

        .global __clzdi2
        .hidden __clzdi2
        .type __clzdi2,@function
__clzdi2:
        MOV     r0, r2
        BEQZ    .Lclzdi_low
        MOV     r1, r2
        LDI     r2, 0
        LDI     r3, 32
        JMP8    .Lclz_loop
.Lclzdi_low:
        LDI     r2, 32
        LDI     r3, 64
.Lclz_loop:
        MOV     r0, r1
        BLTZ    .Lbit_count_done
        ADD     r1, r1, r1
        ADDI    r2, 1
        SUB     r0, r2, r3
        BNEZ    .Lclz_loop
        JMP8    .Lbit_count_done
        .size __clzdi2, . - __clzdi2

        .global __ctzsi2
        .hidden __ctzsi2
        .type __ctzsi2,@function
__ctzsi2:
        LDI     r2, 0
        LDI     r3, 32
        JMP8    .Lctz_loop
        .size __ctzsi2, . - __ctzsi2

        .global __ctzdi2
        .hidden __ctzdi2
        .type __ctzdi2,@function
__ctzdi2:
        MOV     r0, r1
        BNEZ    .Lctzdi_low
        MOV     r1, r2
        LDI     r2, 32
        LDI     r3, 64
        JMP8    .Lctz_loop
.Lctzdi_low:
        LDI     r2, 0
        LDI     r3, 32
.Lctz_loop:
        MOV     r0, r1
        ANDI    r0, 1
        BNEZ    .Lbit_count_done
        SRLI    r1, r1, 1
        ADDI    r2, 1
        SUB     r0, r2, r3
        BNEZ    .Lctz_loop
.Lbit_count_done:
        MOV     r1, r2
        RET     S7
        .size __ctzdi2, . - __ctzdi2

/* Compact RC32 wide negation, comparison, and bit-count helpers. */

        .section .text.__negdi2,"ax",@progbits
        .p2align 1

        .global __negdi2
        .hidden __negdi2
        .type __negdi2,@function
__negdi2:
        LDI     r0, 0
        SLTU    r3, r0, r1             // borrow iff the low word is nonzero
        SUB     r1, r0, r1
        SUB     r2, r0, r2
        SUB     r2, r2, r3
        RET     S7
        .size __negdi2, . - __negdi2

        // Each family shares its tail; unrelated helpers can be discarded.
        .section .text.__cmpdi2,"ax",@progbits
        .p2align 1
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

        .section .text.__clzdi2,"ax",@progbits
        .p2align 1
        .global __clzsi2
        .hidden __clzsi2
        .type __clzsi2,@function
__clzsi2:
        MOV     r0, r1
        LDI     r1, 0
        JMP8    .Lclz_test
        .size __clzsi2, . - __clzsi2

        .global __clzdi2
        .hidden __clzdi2
        .type __clzdi2,@function
__clzdi2:
        MOV     r0, r2
        BNEZ    .Lclzdi_high
        MOV     r0, r1
        LDI     r1, 32
        JMP8    .Lclz_test
.Lclzdi_high:
        LDI     r1, 0
.Lclz_test:
        // Once zero is excluded, a set bit must reach the sign position.
        // Keep the shifted value in r0 so the loop branches on it directly.
        BEQZ    .Lclz_zero
        BLTZ    .Lclz_done
.Lclz_loop:
        ADD     r0, r0, r0
        ADDI    r1, 1
        BGEZ    .Lclz_loop
.Lclz_done:
        RET     S7
.Lclz_zero:
        ADDI    r1, 32
        RET     S7
        .size __clzdi2, . - __clzdi2

        .section .text.__ctzdi2,"ax",@progbits
        .p2align 1
        .global __ctzsi2
        .hidden __ctzsi2
        .type __ctzsi2,@function
__ctzsi2:
        MOV     r2, r1
        LDI     r1, 0
        JMP8    .Lctz_test
        .size __ctzsi2, . - __ctzsi2

        .global __ctzdi2
        .hidden __ctzdi2
        .type __ctzdi2,@function
__ctzdi2:
        MOV     r0, r1
        BNEZ    .Lctzdi_low
        LDI     r1, 32
        JMP8    .Lctz_test
.Lctzdi_low:
        MOV     r2, r1
        LDI     r1, 0
.Lctz_test:
        MOV     r0, r2
        BEQZ    .Lctz_zero
        ANDI    r0, 1
        BNEZ    .Lctz_done
.Lctz_loop:
        SRLI    r2, r2, 1
        ADDI    r1, 1
        MOV     r0, r2
        ANDI    r0, 1
        BEQZ    .Lctz_loop
.Lctz_done:
        RET     S7
.Lctz_zero:
        ADDI    r1, 32
        RET     S7
        .size __ctzdi2, . - __ctzdi2

/* RC32 low 64 bits of a 64-by-64 product. */

        .section .text.__muldi3,"ax",@progbits
        .p2align 1
        .global __muldi3
        .hidden __muldi3
        .type __muldi3,@function
__muldi3:
        /* The second i64 argument is stack-passed as low, high words. */
        ADDI    r7, -12
        ST      r4, [r7 + 0]
        ST      r5, [r7 + 4]
        ST      r6, [r7 + 8]
        LD      r5, [r7 + 12]
        LD      r6, [r7 + 16]
        LDI     r3, 0
        LDI     r4, 0

        OR      r0, r5, r6
        BEQZ    .Lmuldi_done
.Lmuldi_loop:
        MOV     r0, r5
        ANDI    r0, 1
        BEQZ    .Lmuldi_no_add
        MOV     r0, r3
        ADD     r3, r3, r1
        SLTU    r0, r3, r0
        ADD     r4, r4, r2
        ADD     r4, r4, r0
.Lmuldi_no_add:
        FSL1    r2, r1
        ADD     r1, r1, r1
        FSR1    r5, r6
        SRLI    r6, r6, 1
        OR      r0, r5, r6
        BNEZ    .Lmuldi_loop

.Lmuldi_done:
        MOV     r1, r3
        MOV     r2, r4
        LD      r4, [r7 + 0]
        LD      r5, [r7 + 4]
        LD      r6, [r7 + 8]
        ADDI    r7, 12
        RET     S7
        .size __muldi3, . - __muldi3

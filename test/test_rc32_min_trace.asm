; Compact image for tracing the implemented RC32 Min instruction subset.

.section .vectors, "ax", @progbits
        .global start
start:
        JMP8    main

main:
        LDI     r1, 0x78
        LDI     r2, 0
        ADDI    r2, -2
        SRLI    r3, r1, 1
        SRAI    r4, r1, 1
        FSL1    r5, r3
        FSR1    r6, r4
        XOR     r5, r5, r6
        LDI     r5, 0x60
        ADD     r5, r5, r5
        ADD     r5, r5, r5
        ADD     r5, r5, r5
        ADD     r5, r5, r5
        ADD     r5, r5, r5
        ADD     r5, r5, r5
        ADD     r5, r5, r5
        ADD     r5, r5, r5
        ORI     r5, 0x0d
        STH     r5, [r2]
        HALT
        .p2align 2

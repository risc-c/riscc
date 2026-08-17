; RC32 Sys architectural smoke test.
; Verifies JALL's pc+4 link, STI/CLI/RETI/IE, interrupt entry at byte address
; four, IRQ acknowledgement, and return through saved S0 continuation.

.text
        ; JALL S7, 0x10000 + main.  The fixture aliases the physical 64 KiB
        ; RAM window, so this also checks JALL's five header address bits.
        .short 0x3874
        .short main

irq_vector:
        LDI     r2, 0
        ADDI    r2, -6
        LDH     r3, [r2]
        LDI     r1, 1
        CLI
        STI
        RETI    S0

main:
        MFS     r2, S7
        CMPI    r2, 4
        BNEZ    fail
        JMPL    after_jmpl
        HALT
after_jmpl:
        MFS     r3, S0
        CMPI    r3, 0
        BNEZ    fail

        ; Exercise both byte lanes. The high-lane LDB rotates serial RF writes
        ; by eight bits and is the awkward case for packed MLAB writeback.
        LDI     r4, 0x70
        LDI     r5, 0x34
        STB     r5, [r4]
        ADDI    r4, 1
        LDI     r5, 0x56
        STB     r5, [r4]
        LDB     r2, [r4]
        CMPI    r2, 0x56
        BNEZ    fail
        ADDI    r4, -1
        LDB     r2, [r4]
        CMPI    r2, 0x34
        BNEZ    fail

        ; Enter the same physical window with nonzero architectural PC high
        ; bits before enabling IRQ.  RETI must preserve the full 32-bit EPC.
        .short  0x0074             ; JMPL 0x10000 + irq_wait_high
        .short  irq_wait_high
irq_wait_high:
        STI
loop:
        CMPI    r1, 1
        BNEZ    loop
        LDI     r1, 0x60
        ADD     r1, r1, r1
        ADD     r1, r1, r1
        ADD     r1, r1, r1
        ADD     r1, r1, r1
        ADD     r1, r1, r1
        ADD     r1, r1, r1
        ADD     r1, r1, r1
        ADD     r1, r1, r1
        ORI     r1, 0x0d
        LDI     r7, 0
        ADDI    r7, -2
        .short  0xcf5a             ; STH r1, [r7]

fail:
        HALT

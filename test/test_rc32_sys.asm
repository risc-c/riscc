; RC32 Sys architectural smoke test.
; Verifies JALL's pc+4 link, STI/CLI/RETI/IE, interrupt entry at byte address
; four, IRQ acknowledgement, and return through saved S0 continuation.

.text
        ; The RTL image deliberately enters the fixture's aliased high window
        ; to check JALL's five header address bits.  The ISS image stays in its
        ; sparse low window; both execute the same defined JALL form.
.ifdef RISCC_ISS
        .short 0x3834
.else
        .short 0x3874
.endif
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
.ifdef RISCC_ISS
        .short  0x0034             ; JMPL irq_wait_high
.else
        .short  0x0074             ; JMPL 0x10000 + irq_wait_high
.endif
        .short  irq_wait_high
irq_wait_high:
.ifdef RISCC_ISS
        ; The RTL testbench injects a held external IRQ.  Give the atomic ISS
        ; the equivalent pending level through the shared test MMIO register.
        LDI     r2, 0
        ADDI    r2, -6
        LDI     r1, 1
        STH     r1, [r2]
.endif
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

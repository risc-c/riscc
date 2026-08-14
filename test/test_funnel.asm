; One-bit compact funnel shifts shared by Min, Sys, and Full.

.text
.globl start
start:
    ; Distinct rd/ra: old rd is shifted and ra supplies the endpoint bit.
    LDI16 r5, 0x2468
    LDI   r3, 1
    FSR1  r5, r3             ; -> 0x9234
    LDI16 r4, 0x9234
    SUB   r0, r5, r4
    BNEZ  fail

    LDI16 r5, 0x89AB
    LDI16 r3, 0x8000
    FSR1  r5, r3             ; -> 0x44D5
    LDI16 r4, 0x44D5
    SUB   r0, r5, r4
    BNEZ  fail

    LDI16 r5, 0x89AB
    FSL1  r5, r3             ; -> 0x1357
    LDI16 r4, 0x1357
    SUB   r0, r5, r4
    BNEZ  fail

    LDI16 r5, 0x89AB
    LDI   r3, 1
    FSL1  r5, r3             ; -> 0x1356
    LDI16 r4, 0x1356
    SUB   r0, r5, r4
    BNEZ  fail

    ; rd may alias ra; both inputs are read before the destination is written.
    LDI16 r3, 0x89AB
    FSL1  r3, r3             ; -> 0x1357
    LDI16 r4, 0x1357
    SUB   r0, r3, r4
    BNEZ  fail

    LDI16 r2, 0x89AB
    FSR1  r2, r2             ; -> 0xC4D5
    LDI16 r4, 0xC4D5
    SUB   r0, r2, r4
    BNEZ  fail

pass:
    LDI16 r7, 0x600D
    LDI16 r6, 0xFFFE
    ST   r7, [r6+0]
    HALT

fail:
    LDI16 r7, 0x0BAD
    LDI16 r6, 0xFFFE
    ST   r7, [r6+0]
    HALT

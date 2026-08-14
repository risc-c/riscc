; Self-checking tests for the optional RC16 Full MDU instructions.
; Assemble with RISCC_MULHU for the paired multiply core and with the full
; MDU feature set for the paired multiply/divide core.

.text
.globl start
start:
.ifdef RISCC_MULHU
    ; Paired unsigned product and rb == rh overlap.
    LDI16 r1, 0x1234
    LDI16 r2, 0x4321
    MULHU r3, r1, r2        ; 0x1234 * 0x4321 = 0x04C5F4B4
    LDI16 r4, 0xF4B4
    SUB   r0, r3, r4
    BNEZ  fail
    LDI16 r4, 0x04C5
    SUB   r0, r1, r4
    BNEZ  fail

    LDI16 r6, 0xFFFF
    MULHU r5, r6, r6        ; rb may overlap rh
    LDI   r4, 1
    SUB   r0, r5, r4
    BNEZ  fail
    LDI16 r4, 0xFFFE
    SUB   r0, r6, r4
    BNEZ  fail
.endif

.ifdef RISCC_DIVU
    ; Paired unsigned divide/remainder. The high dividend limb is smaller
    ; than the divisor, so both architectural results fit in 16 bits.
    LDI   r3, 1             ; dividend = 0x00012345
    LDI16 r2, 0x2345
    LDI16 r1, 0x0123
    DIVU  r3, r2, r1        ; quotient = 0x0100, remainder = 0x0045
    LDI16 r4, 0x0100
    SUB   r0, r2, r4
    BNEZ  fail
    LDI   r4, 0x45
    SUB   r0, r3, r4
    BNEZ  fail
.endif

pass:
    LDI16 r7, 0x600D
    JMP8  finish

fail:
    LDI16 r7, 0x0BAD

finish:
    LDI16 r6, 0xFFFE
    ST   r7, [r6+0]
    HALT

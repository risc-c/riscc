; RTL-only Tiny FSR1 prototype.
; Reserved f5=10_010 encodes FSR1 until the experiment is kept or discarded.
; This source intentionally uses a raw word so no assembler or architectural
; profile change is required.

.text
start:
    LDI   r2, 1
    ; Keep ra[0] different from rb[0]. This catches accidentally sampling
    ; the stale ra read instead of preserving rb[0] across INIT.
    LDI16 r3, 0x2468
    .word  0xEB92            ; FSR1 r5, r3, r2 -> 0x9234
    LDI16 r4, 0x9234
    SUB   r0, r5, r4
    BNEZ  fail

pass:
    LDI16 r7, 0x600D
    LDI16 r6, 0xFFFE
    STW   r7, [r6+0]
    HALT

fail:
    LDI16 r7, 0x0BAD
    LDI16 r6, 0xFFFE
    STW   r7, [r6+0]
    HALT

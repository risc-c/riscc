; Interrupt atomicity sweep for the implemented RC16 Full instruction set.
;
; The test driver first stops at the marker store to learn the uninterrupted
; execution window, then reruns this image with a held IRQ asserted at every
; cycle in that window.  The handler preserves every register bank used by the
; instruction sequence.  Success is written only after the handler has
; acknowledged the injected interrupt and returned to the mainline.

.section .vectors, "ax", @progbits
        JMPL    start
        JMPL    irq_handler

.text
irq_handler:
        MTS     S1, r0
        MTS     S2, r1
        MTS     S3, r2
        LDI16   r2, 0xFFFA
        LD      r1, [r2+0]
        LDI16   r2, 0x7E00
        LDI     r1, 1
        ST      r1, [r2+0]
        MFS     r2, S3
        MFS     r1, S2
        MFS     r0, S1
        RETI    S0

start:
        ; Initialize the handler-completion flag before interrupts are enabled.
        CLI
        LDI16   r6, 0x7E00
        LDI     r7, 0
        ST      r7, [r6+0]
        STI

        ; Immediate, register-ALU, compare, and compact branch groups.
        LDI     r3, 0x12
        LUI     r4, 0x34
        ADDI    r3, -1
        CMPI    r3, 0x11
        ANDI    r3, 0x7f
        ORI     r3, 0x40
        XORI    r3, 0x55
        ADD     r5, r3, r4
        SUB     r5, r5, r3
        SLT     r5, r3, r4
        SLTU    r5, r3, r4
        AND     r5, r3, r4
        OR      r5, r3, r4
        XOR     r5, r3, r4

        LDI     r4, 0
        OR      r0, r4, r4
        BEQZ    cover_beq
cover_beq:
        BNEZ    cover_bne
cover_bne:
        ADDI    r0, -1
        BLTZ    cover_blt
cover_blt:
        BGEZ    cover_bge
cover_bge:
        JMP8    cover_jmp8
cover_jmp8:

        ; All implemented compact memory planes and byte behaviors.
        LDI16   r6, 0x7E20
        LDI16   r3, 0x80A5
        ST      r3, [r6+0]
        LD      r4, [r6+0]
        LDI     r5, 0
        LDX     r4, [r6+r5]
        LDB     r4, [r6]
        LDBS    r4, [r6]
        STB     r3, [r6]
        ADDI    r6, 1
        LDB     r4, [r6]
        LDBS    r4, [r6]
        STB     r3, [r6]
        ADDI    r6, -1

        ; Cheap count-one, iterative Full shifts, multiply, and funnels.
        SRLI    r4, r3, 1
        SRAI    r4, r3, 1
        SRLI    r4, r3, 4
        SRAI    r4, r3, 4
        SLLI    r4, r3, 4
        MUL     r4, r3, r5
        FSL1    r4, r3
        FSR1    r4, r3

.ifdef RISCC_MULHU
        LDI16   r3, 0x1234
        LDI16   r4, 0x4321
        MULHU   r5, r3, r4
.endif
.ifdef RISCC_DIVU
        LDI     r5, 1
        LDI16   r4, 0x2345
        LDI16   r3, 0x0123
        DIVU    r5, r4, r3
.endif

        ; S-bank moves, register calls/jumps, and long calls/jumps.  S1-S3 are
        ; reserved by the handler, so mainline control uses S4-S7.
        MTS     S4, r3
        MFS     r4, S4
        LDI16   r3, reg_sub
        JALR    S5, r3
reg_return:
        LDI16   r3, reg_jump
        JMP     r3
reg_sub:
        RET     S5
reg_jump:
        JALL    S6, long_sub
long_return:
        JMPL    long_jump
long_sub:
        RET     S6
long_jump:

        ; Exercise direct IE controls and RETI with an ordinary manufactured
        ; continuation.  An IRQ raised while IE is clear remains pending and
        ; must be taken at the boundary opened by RETI/STI.
        CLI
        LDI16   r3, after_reti
        MTS     S0, r3
        RETI    S0
after_reti:
        CLI
        STI

        ; Baseline discovery stops on this write.  Sweep runs continue and
        ; cannot report success until the injected IRQ has returned.
        LDI16   r6, 0x7EF0
        ST      r7, [r6+0]
        LDI16   r6, 0x7E00
wait_irq:
        LD      r7, [r6+0]
        OR      r0, r7, r7
        BEQZ    wait_irq

        LDI16   r7, 0x600D
        LDI16   r6, 0xFFFE
        ST      r7, [r6+0]
        HALT

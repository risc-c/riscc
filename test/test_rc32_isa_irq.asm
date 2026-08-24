; Interrupt atomicity sweep for the implemented RC32 Sys and Full profiles.

.macro LIT reg, literal
        LDPC    \reg, \literal
.endm

.section .vectors, "ax", @progbits
        .global start
        JALL    S7, start
        JMPL    irq_handler

.text
        .p2align 2
.Lirq_ack_port:
        .long   0x0000FFFA
.Lirq_flag:
        .long   0x00007E00
.Ldata_address:
        .long   0x00007E20
.Ldata_word:
        .long   0x800080A5
.Lreg_sub_address:
        .long   reg_sub
.Lreg_jump_address:
        .long   reg_jump
.Lafter_reti_address:
        .long   after_reti
.Ltrace_port:
        .long   0x00007EF0
.Lpass_code:
        .long   0x0000600D
.Lresult_port:
        .long   0x0000FFFE

irq_handler:
        MTS     S1, r0
        MTS     S2, r1
        MTS     S3, r2
        LIT     r2, .Lirq_ack_port
        LDH     r1, [r2]
        LIT     r2, .Lirq_flag
        LDI     r1, 1
        ST      r1, [r2+0]
        MFS     r2, S3
        MFS     r1, S2
        MFS     r0, S1
        RETI    S0

start:
        CLI
        LIT     r6, .Lirq_flag
        LDI     r7, 0
        ST      r7, [r6+0]
        STI

        ; Compact immediate, ALU, and branch groups.
        LDI     r3, 0x12
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

        ; Word, indexed, byte, and halfword memory forms.
        LIT     r6, .Ldata_address
        LIT     r3, .Ldata_word
        ST      r3, [r6+0]
        LD      r4, [r6+0]
        LDI     r5, 0
        LDX     r4, [r6+r5]
        LDB     r4, [r6]
        LDBS    r4, [r6]
        LDH     r4, [r6]
        LDHS    r4, [r6]
        STB     r3, [r6]
        STH     r3, [r6]

        SRLI    r4, r3, 1
        SRAI    r4, r3, 1
.ifdef RISCC_FULL
        SLLI    r4, r3, 1
        SLLI    r4, r3, 2
        SLLI    r4, r3, 3
        SLLI    r4, r3, 4
        SLLI    r4, r3, 5
        SLLI    r4, r3, 6
        SLLI    r4, r3, 7
        SLLI    r4, r3, 8
        SRLI    r4, r3, 2
        SRLI    r4, r3, 3
        SRLI    r4, r3, 4
        SRLI    r4, r3, 5
        SRLI    r4, r3, 6
        SRLI    r4, r3, 7
        SRLI    r4, r3, 8
        SRAI    r4, r3, 2
        SRAI    r4, r3, 3
        SRAI    r4, r3, 4
        SRAI    r4, r3, 5
        SRAI    r4, r3, 6
        SRAI    r4, r3, 7
        SRAI    r4, r3, 8
        MUL     r4, r3, r5
.endif
        FSL1    r4, r3
        FSR1    r4, r3

        ; Register and long control plus the S-bank moves.
        MTS     S4, r3
        MFS     r4, S4
        LIT     r3, .Lreg_sub_address
        JALR    S5, r3
reg_return:
        LIT     r3, .Lreg_jump_address
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

        CLI
        LIT     r3, .Lafter_reti_address
        MTS     S0, r3
        RETI    S0
after_reti:
        CLI
        STI

        ; Baseline discovery marker, then wait for the injected IRQ to return.
        LIT     r6, .Ltrace_port
        STH     r7, [r6]
        LIT     r6, .Lirq_flag
wait_irq:
        LD      r7, [r6+0]
        OR      r0, r7, r7
        BEQZ    wait_irq

        LIT     r7, .Lpass_code
        LIT     r6, .Lresult_port
        STH     r7, [r6]
        HALT

; Native RC32 loads: complete values, operand aliases, and R0 branch flags.
; Low halfwords deliberately resemble instructions while the high beat waits.

.macro LIT reg, value
        LDPC    \reg, .Lliteral\@
        JMP8    .Lliteral_done\@
        .p2align 2
.Lliteral\@:
        .long   \value
.Lliteral_done\@:
.endm

; Construct the comparison value without relying on another native load.
.macro CONST reg, value
        LDI     \reg, ((\value) >> 24) & 255
        .rept 8
        ADD     \reg, \reg, \reg
        .endr
        ORI     \reg, ((\value) >> 16) & 255
        .rept 8
        ADD     \reg, \reg, \reg
        .endr
        ORI     \reg, ((\value) >> 8) & 255
        .rept 8
        ADD     \reg, \reg, \reg
        .endr
        ORI     \reg, (\value) & 255
.endm

.macro EXPECT_BRANCH branch, code
        \branch .Lbranch_ok\@
        LDI     r7, \code
        LIT     r6, finish
        JMP     r6
.Lbranch_ok\@:
.endm

.macro CHECK reg, value, code, temp=r6
        CONST   \temp, \value
        SUB     r0, \reg, \temp
        EXPECT_BRANCH BEQZ, \code
.endm

; Exercise every native load form; LD aliases its base, LDX its index.
.macro PATTERN value, code
        LIT     r2, \value
        CHECK   r2, \value, \code
        LIT     r3, .Ldata\@
        LD      r3, [r3+0]
        CHECK   r3, \value, (\code)+1
        LIT     r4, .Ldata\@
        LDI     r5, 0
        LDX     r5, [r4+r5]
        CHECK   r5, \value, (\code)+2
        JMP8    .Ldata_done\@
        .p2align 2
.Ldata\@:
        .long   \value
.Ldata_done\@:
.endm

.macro CHECK_FLAGS value, zero_branch, sign_branch, code
        EXPECT_BRANCH \zero_branch, \code
        EXPECT_BRANCH \sign_branch, \code
        CHECK   r0, \value, \code
.endm

.macro FLAGS value, zero_branch, sign_branch, code
        LIT     r0, \value
        CHECK_FLAGS \value, \zero_branch, \sign_branch, \code
        LIT     r0, .Lflag_data\@
        LD      r0, [r0+0]
        CHECK_FLAGS \value, \zero_branch, \sign_branch, (\code)+1
        LIT     r0, .Lflag_data\@
        SRLI    r0, r0, 1
        LDX     r0, [r0+r0]
        CHECK_FLAGS \value, \zero_branch, \sign_branch, (\code)+2
        JMP8    .Lflag_done\@
        .p2align 2
.Lflag_data\@:
        .long   \value
.Lflag_done\@:
.endm

.section .vectors, "ax", @progbits
        .global start
        JMP8    start
        .short  0
.ifdef RISCC_SYS
        JMPL    irq_handler
.endif

.text
.ifdef RISCC_SYS
; Only r0/r1 are touched; restoring r0 also restores its branch flags.
; All other GPRs remain live across every injected IRQ.
irq_handler:
        MTS     S1, r0
        MTS     S2, r1
        LIT     r1, 0xFFFA
        LDH     r0, [r1]
        MFS     r1, S2
        MFS     r0, S1
        RETI    S0
.endif

start:
.ifdef RISCC_SYS
        STI
.endif
        PATTERN 0x89AB4001, 1   ; native store encoding
        PATTERN 0x1357D4FB, 4   ; MTS encoding
        PATTERN 0x24680034, 7   ; JMPL encoding
        PATTERN 0xFEDC88A5, 10  ; compact immediate encoding

        FLAGS   0x00000000, BEQZ, BGEZ, 20
        FLAGS   0x00010000, BNEZ, BGEZ, 23
        FLAGS   0x80000000, BNEZ, BLTZ, 26

        ; Nonzero index with rd == base, and ra == rb with a distinct rd.
        LIT     r1, alias_data-4
        LDI     r2, 4
        LDX     r1, [r1+r2]
        CHECK   r1, 0xDEADCAFE, 30
        LIT     r5, alias_data
        SRLI    r5, r5, 1
        LDX     r6, [r5+r5]
        CHECK   r6, 0xDEADCAFE, 31, r4
        ; Also cover saved destination number seven.
        LIT     r7, 0x12345678
        CHECK   r7, 0x12345678, 32
        JMP8    aliases_done
        .p2align 2
alias_data:
        .long   0xDEADCAFE
aliases_done:
.ifdef RISCC_SYS
        LIT     r7, 0x7EF0
        STH     r7, [r7]       ; test_irq_cycles.py end-of-body marker
        CLI
.endif
        CONST   r7, 0x600D
finish:
        LIT     r6, 0xFFFE
        STH     r7, [r6]
        HALT

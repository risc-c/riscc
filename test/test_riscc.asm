; RISC-C self-checking test suite.
; Mainline profiles and Nano share this source:
;   --profile min    : min profile, replacing sys-only sections
;   --profile full   : full-profile MUL coverage
;   --profile nano   : Nano-compatible branch
; LDBS coverage is excluded from the Nano-compatible branch.
; Failure writes 0x0BAD to the result register (I/O page, byte 0xFFFE)
; and parks.  Success writes 0x600D there and parks.

.ifdef RISCC_NANO
; Nano uses the same test source with its profile-specific instruction set.
.text
.globl start
start:
    ; immediates and boolean ops
    LDI   r7, 0
    LDI16 r1, 0x1234
    LDI   r2, 10
    ADDI  r2, -3
    LDI   r3, 0xF0
    ANDI  r3, 0x3C
    ORI   r3, 0x05
    XORI  r3, 0x0F
    LDI   r4, 0x3A
    SUB   r0, r3, r4
    BNEZ  fail
    LDI16 r4, 0x1234
    SUB   r0, r1, r4
    BNEZ  fail

    ; ALU and compare-as-integer
    ADD   r5, r2, r3
    SUB   r0, r5, r3
    LDI   r4, 7
    SUB   r0, r0, r4
    BNEZ  fail
    LDI   r1, 0xAA
    LDI   r2, 0x55
    OR    r3, r1, r2
    XOR   r4, r1, r2
    SUB   r0, r3, r4
    BNEZ  fail
    AND   r5, r1, r2
    OR    r0, r5, r5
    BNEZ  fail

    LDI   r1, 5
    LDI   r2, 6
    SLTU  r0, r2, r1
    BEQZ  sltu_ok
    JMP8  fail
sltu_ok:
    LDI   r1, 0
    ADDI  r1, -1
    SLTU  r0, r1, r2
    BEQZ  sltu_neg_ok
    JMP8  fail
sltu_neg_ok:
    ; branch group, all using r0
    LDI   r0, 0
    ADDI  r0, -1
    BLTZ  br_neg_ok
    JMP8  fail
br_neg_ok:
    LDI   r0, 0
    BGEZ  br_pos_ok
    JMP8  fail
br_pos_ok:
    BEQZ  br_zero_ok
    JMP8  fail
br_zero_ok:
    ADDI  r0, 1
    BNEZ  br_nz_ok
    JMP8  fail
br_nz_ok:

    ; word and indexed memory
    LDI16 r6, 0x0200
    LDI16 r1, 0xA55A
    ST   r1, [r6+0]
    LD   r2, [r6+0]
    SUB   r0, r2, r1
    BNEZ  fail
    ADDI  r6, 8
    ST   r1, [r6-4]
    LD   r3, [r6-4]
    SUB   r0, r3, r1
    BNEZ  fail
    LDI   r4, 4
    ADD   r3, r6, r4
    ST   r1, [r3+0]
    LDX  r5, [r6+r4]
    SUB   r0, r5, r1
    BNEZ  fail

    ; Compact word displacements are even signed bytes.
    LDI16 r3, 0x0300
    LDI16 r1, 0x1357
    ST   r1, [r3+126]
    LD   r2, [r3+126]
    SUB   r0, r2, r1
    BNEZ  fail
    LDI16 r3, 0x0380
    ST   r1, [r3-128]
    LD   r2, [r3-128]
    SUB   r0, r2, r1
    BNEZ  fail

    ; byte lanes; direct byte operations must not use encoded bbb=000 as r0
    LDI16 r5, 0x1234
    ST   r5, [r6+0]
    LDI16 r5, 0x5678
    ST   r5, [r6+8]
    LDI   r4, 1
    ADD   r1, r6, r4
    LDI   r5, 0x80
    LDI   r0, 7
    STB   r5, [r1]
    LDB   r2, [r1]
    LD   r4, [r6+0]
    LDI16 r5, 0x8034
    SUB   r0, r4, r5
    BNEZ  fail
    LD   r4, [r6+8]
    LDI16 r5, 0x5678
    SUB   r0, r4, r5
    BNEZ  fail
    LDI16 r5, 0x0080
    SUB   r0, r2, r5
    BNEZ  fail

    ; count-one right shifts
    LDI16 r1, 0x8001
    SRLI  r2, r1, 1
    SRAI  r3, r1, 1
    LDI16 r4, 0x4000
    SUB   r0, r2, r4
    BNEZ  fail
    LDI16 r4, 0xC000
    SUB   r0, r3, r4
    BNEZ  fail
    ADD   r5, r2, r2
    LDI16 r4, 0x8000
    SUB   r0, r5, r4
    BNEZ  fail

    ; Nano register call: JALR rd, ra links into rd.
    LDI16 r1, subr
    JALR  r7, r1
after_call:
    LDI16 r4, after_call
    SUB   r0, r7, r4
    BNEZ  fail
    LDI   r4, 0x42
    SUB   r0, r3, r4
    BNEZ  fail

    JMP8  success

fail:
    LDI16 r7, 0x0BAD
    LDI16 r6, 0xFFFE
    ST   r7, [r6+0]
fail_loop:
    JMP8  fail_loop

success:
    LDI16 r7, 0x600D
    LDI16 r6, 0xFFFE
    ST   r7, [r6+0]
done:
    JMP8  done

subr:
    LDI   r3, 0x42
    JMP   r7
.else
.ifdef RISCC_SYS
.section .vectors, "ax", @progbits
    JMPL  start             ; words 0..1: reset vector slot
    JMPL  isr_irq           ; words 2..3: IRQ vector slot
.endif

.text
.globl start
.ifdef RISCC_SYS
fail:
    LDI16 r7, 0x0BAD
    LDI16 r6, 0xFFF6
    ST   r7, [r6+0]
    HALT

; The handlers demonstrate the S-bank save primitive: no free user register
; is needed at entry.  IRQ arrives via vector word 2.  r0 is the branch register, so a
; branching handler saves and restores it like anything else; restoring it
; with MFS keeps the branch shadow coherent.  The handler logs a marker to
; 0xFFFA (read acknowledges the TB's IRQ), counts entries in ordinary RAM,
; and restores everything it touched.
isr_irq:
    MTS   S1, r0
    MTS   S2, r1
    MTS   S3, r2
    LDI16 r2, 0xFFFA
    LD   r1, [r2+0]        ; read IRQ cause and acknowledge it
    LDI16 r2, 0x7F00
    ST   r1, [r2+0]        ; log the cause in ordinary RAM
    LD   r1, [r2+2]        ; entry counter
    ADDI  r1, 1             ; the system half is exactly EPC + 3 saves
    ST   r1, [r2+2]
    MFS   r2, S3
    MFS   r1, S2
    MFS   r0, S1
    RETI  S0
.endif
.ifndef RISCC_SYS
    JMP8  start
fail:
    LDI16 r7, 0x0BAD
    LDI16 r6, 0xFFFE
    ST   r7, [r6+0]
    HALT
.endif

start:
    ; --- immediates ---
    LDI   r7, 0
    LDI16 r1, 0x1234
    LDI   r2, 10
    ADDI  r2, -3            ; r2 = 7
    LDI   r3, 0xF0
    ANDI  r3, 0x3C          ; 0x30
    ORI   r3, 0x05          ; 0x35
    XORI  r3, 0x0F          ; 0x3A
    LDI   r4, 0x3A
    SUB   r0, r3, r4
    BNEZ  fail
    LDI16 r4, 0x1234
    SUB   r0, r1, r4
    BNEZ  fail
    CMPI  r2, 7             ; r0 = r2 - 7
    BNEZ  fail
    CMPI  r2, 8             ; small-range signed compare: 7 - 8 < 0
    BGEZ  fail
    CMPI  r2, -1            ; sign-extended immediate: 7 - (-1) > 0
    BLTZ  fail
    LDI   r4, 7             ; CMPI must not clobber its source register
    SUB   r0, r2, r4
    BNEZ  fail

    ; --- ALU and compare-as-integer ---
    ADD   r5, r2, r3        ; 7 + 0x3A = 0x41
    SUB   r0, r5, r3        ; r0 = 7
    LDI   r4, 7
    SUB   r0, r0, r4
    BNEZ  fail
    LDI   r1, 0xAA
    LDI   r2, 0x55
    OR    r3, r1, r2        ; 0x00FF
    XOR   r4, r1, r2        ; 0x00FF
    SUB   r0, r3, r4
    BNEZ  fail
    AND   r5, r1, r2        ; 0
    OR    r0, r5, r5
    BNEZ  fail

    LDI   r1, 5
    LDI   r2, 6
    SLTU  r0, r2, r1
    BEQZ  sltu_ok
    JMP8  fail
sltu_ok:
    SLT   r0, r1, r2
    BNEZ  slt_s_ok
    JMP8  fail
slt_s_ok:
    LDI   r1, 0
    ADDI  r1, -1            ; 0xFFFF
    SLT   r0, r1, r2        ; signed -1 < 6
    BNEZ  slt_neg_ok
    JMP8  fail
slt_neg_ok:
    SLTU  r0, r1, r2        ; unsigned 0xFFFF < 6 is false
    BEQZ  sltu_neg_ok
    JMP8  fail
sltu_neg_ok:

    ; --- branch group, all using r0 ---
    LDI   r0, 0
    ADDI  r0, -1
    BLTZ  br_neg_ok
    JMP8  fail
br_neg_ok:
    LDI   r0, 0
    BGEZ  br_pos_ok
    JMP8  fail
br_pos_ok:
    BEQZ  br_zero_ok
    JMP8  fail
br_zero_ok:
    ADDI  r0, 1
    BNEZ  br_nz_ok
    JMP8  fail
br_nz_ok:

    ; --- word and byte memory (ordinary high-RAM scratch page) ---
    LDI16 r6, 0x7E00
    LDI16 r1, 0xA55A
    ST   r1, [r6+0]
    LD   r2, [r6+0]
    SUB   r0, r2, r1
    BNEZ  fail_late
    ADDI  r6, 8
    ST   r1, [r6-4]
    LD   r3, [r6-4]
    SUB   r0, r3, r1
    BNEZ  fail_late
    LDI   r4, 4
    ADD   r3, r6, r4
    ST   r1, [r3+0]
    ; Both nonzero address registers are required: LDX remains indexed.
    LDX  r5, [r6+r4]
    SUB   r0, r5, r1
    BNEZ  fail_late

    ; Compact word displacements are even signed bytes.
    LDI16 r3, 0x7000
    LDI16 r1, 0x1357
    ST   r1, [r3+126]
    LD   r2, [r3+126]
    SUB   r0, r2, r1
    BNEZ  fail_late
    LDI16 r3, 0x7080
    ST   r1, [r3-128]
    LD   r2, [r3-128]
    SUB   r0, r2, r1
    BNEZ  fail_late

    LDI16 r5, 0x1234
    ST   r5, [r6+0]
    LDI16 r5, 0x5678
    ST   r5, [r6+8]
    LDI   r4, 1             ; odd byte lane
    ADD   r1, r6, r4
    LDI   r5, 0x80
    LDI   r0, 7             ; direct byte forms must ignore encoded bbb=000
    STB   r5, [r1]
    LDB   r2, [r1]
    LDBS  r3, [r1]
    LD   r4, [r6+0]
    LDI16 r5, 0x8034
    SUB   r0, r4, r5
    BNEZ  fail_late
    LD   r4, [r6+8]
    LDI16 r5, 0x5678
    SUB   r0, r4, r5
    BNEZ  fail_late
    LDI16 r5, 0x0080
    SUB   r0, r2, r5
    BNEZ  fail_late
    LDI16 r5, 0xFF80
    SUB   r0, r3, r5
    BNEZ  fail_late
    LDB   r0, [r1]
    BLTZ  fail_late          ; zero-extended high-lane byte is non-negative
    LDBS  r0, [r1]
    BGEZ  fail_late          ; sign-extended high-lane byte is negative

    LDI16 r5, 0x1234
    ST   r5, [r6+2]
    LDI16 r5, 0x5678
    ST   r5, [r6+8]
    LDI   r4, 2             ; even byte lane
    ADD   r1, r6, r4
    LDI   r5, 0xFF
    LDI   r0, 7
    STB   r5, [r1]
    LDB   r2, [r1]
    LDBS  r3, [r1]
    LD   r4, [r6+2]
    LDI16 r5, 0x12FF
    SUB   r0, r4, r5
    BNEZ  fail_late
    LD   r4, [r6+8]
    LDI16 r5, 0x5678
    SUB   r0, r4, r5
    BNEZ  fail_late
    LDI16 r5, 0x00FF
    SUB   r0, r2, r5
    BNEZ  fail_late
    LDI16 r5, 0xFFFF
    SUB   r0, r3, r5
    BNEZ  fail_late

    JMP8  shifts_start
fail_late:
    LDI16 r7, 0x0BAD
    LDI16 r6, 0xFFFE
    ST   r7, [r6+0]
    HALT
shifts_start:

    LDI16 r3, data_guard
    LDI16 r4, data_probe
    LD    r2, [r4+0]
    LDI16 r5, 0x4C44
    SUB   r0, r2, r5
    BNEZ  fail_late
    ADDI  r4, 2               ; adjacent instruction halfword in byte space
    LD    r2, [r4+0]
    LDI16 r5, 0x5048
    SUB   r0, r2, r5
    BNEZ  fail_late

    ; --- one-bit shifts ---
    LDI16 r1, 0x8001
    SRLI  r2, r1, 1
    SRAI  r3, r1, 1
    LDI16 r4, 0x4000
    SUB   r0, r2, r4
    BNEZ  fail_late
    LDI16 r4, 0xC000
    SUB   r0, r3, r4
    BNEZ  fail_late
    ADD   r5, r2, r2
    LDI16 r4, 0x8000
    SUB   r0, r5, r4
    BNEZ  fail_late

    ; --- register call: link in S7, return via RET S7 ---
.ifdef RISCC_MIN
    LDI16 r1, subr
.else
    LDI16 r1, subr
.endif
    JALR  S7, r1
after_call:
    LDI   r4, 0x42
    SUB   r0, r3, r4
    BNEZ  fail_late

.ifndef RISCC_MIN
    ; --- two-word direct call / jump (JALL / JMPL / RET S7) ---
    LDI   r3, 0
    JALL  S7, subr16        ; link {IE, pc+2} -> S7; subr16 returns via RET S7
    SUB   r0, r3, r4
    BNEZ  fail_late
    JMPL  c16_ok            ; no link: S7 keeps the last call's link
    JMP8  fail_late
.else
    ; --- far call / jump fallback (LDI16 plus register control transfer) ---
    LDI   r3, 0
    LDI16 r1, subr16
    JALR  S7, r1            ; far call = LDI16 + JALR S7,ra; returns via RET S7
    SUB   r0, r3, r4
    BNEZ  fail_late
    LDI16 r1, c16_ok
    JMP   r1                ; far jump; S7 keeps the link
    JMP8  fail_late
.endif
subr16:
    LDI   r3, 0x42
    RET   S7
c16_ok:
.ifndef RISCC_SYS
    ; --- S registers: min-profile spill slots survive round trips ---
    LDI16 r1, 0xBEEF
    MTS   S5, r1
    LDI   r1, 0
    MFS   r1, S5
    LDI16 r2, 0xBEEF
    SUB   r0, r1, r2
    BNEZ  fail_late
    JMP8  feature_tests
.else
    ; --- system profile: S registers, IRQ, RETI ---
    LDI16 r1, 0xBEEF
    MTS   S5, r1
    LDI   r1, 0
    MFS   r1, S5
    LDI16 r2, 0xBEEF
    SUB   r0, r1, r2
    BNEZ  fail_late

    LDI16 r5, 0x7F00
    LDI   r2, 0
    ST   r2, [r5+0]        ; IRQ cause log = 0
    ST   r2, [r5+2]        ; ISR entry counter = 0

    ; Direct IE controls must not use S0 as a return target. RET S0, unlike
    ; RETI S0, must preserve the cleared IE state.
    LDI16 r1, fail_late
    MTS   S0, r1
    CLI
    LDI16 r1, ret_s0_masked
    MTS   S0, r1
    RET   S0
    JMP8  fail_late
ret_s0_masked:
    LDI16 r5, 0xFFFA
    LDI16 r1, 0xAA55
    ST   r1, [r5+0]        ; RET S0 left IE clear: IRQ stays pending
    LDI16 r5, 0x7F00
    LD   r1, [r5+2]
    MOV   r0, r1
    BNEZ  fail_late         ; no ISR entry while IE is clear
    LDI16 r5, 0xFFFA
    LD   r1, [r5+0]        ; acknowledge the still-pending test IRQ
    ADDI  r1, -1
    MOV   r0, r1
    BNEZ  fail_late

    ; RETI S0 takes the same S0 target but sets IE. The next raised IRQ must
    ; therefore enter the handler without an intervening STI.
    LDI16 r1, reti_s0_enabled
    MTS   S0, r1
    RETI  S0
    JMP8  fail_late
reti_s0_enabled:
    LDI16 r5, 0xFFFA
    LDI16 r1, 0xAA55
    ST   r1, [r5+0]
wait_reti_irq:
    LDI16 r5, 0x7F00
    LD   r1, [r5+2]
    ADDI  r1, -1
    MOV   r0, r1
    BNEZ  wait_reti_irq     ; RETI enabled the first ISR entry

    ; CLI must mask a newly pending IRQ; STI must then admit that same IRQ.
    ; S0 remains poisoned until IRQ entry, proving neither direct control
    ; accidentally redirects through it.
    LDI16 r1, fail_late
    MTS   S0, r1
    CLI
    LDI16 r5, 0xFFFA
    LDI16 r1, 0xAA55
    ST   r1, [r5+0]
    LDI16 r5, 0x7F00
    LD   r1, [r5+2]
    ADDI  r1, -1
    MOV   r0, r1
    BNEZ  fail_late         ; CLI kept the entry count at one
    STI                     ; pending IRQ is taken before the next instruction
wait_sti_irq:
    LDI16 r5, 0x7F00
    LD   r1, [r5+2]
    ADDI  r1, -2
    MOV   r0, r1
    BNEZ  wait_sti_irq      ; STI enabled the second ISR entry
    CLI
    LD   r1, [r5+0]        ; IRQ handler logged the asserted test cause = 1
    ADDI  r1, -1
    MOV   r0, r1
    BEQZ  control_irq_log_ok
.ifndef RISCC_MIN
    JMPL  fail_late
.else
    LDI16 r1, fail_late
    JMP   r1
.endif
control_irq_log_ok:
    LD   r1, [r5+2]        ; r1 = 2 entries
    MFS   r2, S5            ; r2 = 0xBEEF (round trip survived the ISR)
    JMP8  feature_tests
.endif

feature_tests:
.ifdef RISCC_FULL
    ; --- immediate shifts: amounts 1..8, sign fill, rd==ra, composed shifts ---
    LDI16 r1, 0x8001
    SRLI  r3, r1, 4         ; 0x0800
    LDI16 r4, 0x0800
    SUB   r0, r3, r4
    BNEZ  feature_fail
    SRAI  r3, r1, 4         ; 0xF800
    LDI16 r4, 0xF800
    SUB   r0, r3, r4
    BNEZ  feature_fail
    LDI   r3, 3
    SLLI  r3, r3, 4         ; rd==ra: 0x30
    LDI   r4, 0x30
    SUB   r0, r3, r4
    BNEZ  feature_fail
    SRLI  r2, r1, 1         ; count-1 cheap opcode: 0x4000
    SRAI  r3, r1, 1         ; count-1 cheap opcode: 0xC000
    LDI16 r4, 0x4000
    SUB   r0, r2, r4
    BNEZ  feature_fail
    LDI16 r4, 0xC000
    SUB   r0, r3, r4
    BNEZ  feature_fail
    LDI16 r1, 0xFF00
    SRLI  r1, r1, 8         ; amount 8: 0x00FF
    LDI16 r4, 0x00FF
    SUB   r0, r1, r4
    BNEZ  feature_fail
    LDI16 r1, 0xF000
    SRLI  r1, r1, 8         ; >>12 composed: >>8 then >>4
    SRLI  r1, r1, 4
    LDI   r4, 15
    SUB   r0, r1, r4
    BNEZ  feature_fail
    LDI   r1, 1
    SLLI  r1, r1, 8         ; <<15 composed
    SLLI  r1, r1, 7
    LDI16 r4, 0x8000
    SUB   r0, r1, r4
    BNEZ  feature_fail
.endif

.ifdef RISCC_FULL
    ; --- MUL extension: low-16 product, truncation, overlap, r0 shadow ---
    LDI16 r1, 0x1234
    LDI   r2, 3
    MUL   r3, r1, r2
    LDI16 r4, 0x369C
    SUB   r0, r3, r4
    BNEZ  feature_fail

    LDI16 r1, 0x8001        ; low-16 truncation: 0x8001 * 2 = 0x0002
    LDI   r2, 2
    MUL   r3, r1, r2
    LDI   r4, 2
    SUB   r0, r3, r4
    BNEZ  feature_fail

    LDI   r6, 0x10          ; destination overlapping the sources
    LDI   r7, 2
    MUL   r7, r6, r7        ; rd == rb
    LDI   r4, 0x20
    SUB   r0, r7, r4
    BNEZ  feature_fail
    LDI   r5, 5
    MUL   r5, r5, r5        ; rd == ra == rb
    LDI   r4, 25
    SUB   r0, r5, r4
    BNEZ  feature_fail

    LDI   r1, 7             ; product into r0 updates the branch shadow
    LDI   r2, 0
    MUL   r0, r1, r2
    BNEZ  feature_fail
.endif

    ; ---- JALR/RET generality (all profiles) ----
.ifdef RISCC_MIN
    LDI16 r1, gen_sub
.else
    LDI16 r1, gen_sub       ; JALR S3: link lands in S3, callee RETs via S3
.endif
    LDI   r3, 0
    JALR  S3, r1
    CMPI  r3, 0x21          ; callee side effect proves the round trip
    BNEZ  feature_fail
    LDI16 r2, 0x1234        ; JALR S0 is a plain jump: S0 must be untouched
    MTS   S0, r2
.ifdef RISCC_MIN
    LDI16 r1, gen_jmp
.else
    LDI16 r1, gen_jmp
.endif
    JMP   r1
gen_back:
    MFS   r2, S0
    LDI16 r4, 0x1234
    SUB   r0, r2, r4
    BNEZ  feature_fail
.ifdef RISCC_MIN
    LDI16 r2, gen_done
.else
    LDI16 r2, gen_done
.endif
                              ; RET Sa: return through a manufactured address
    MTS   S4, r2
    RET   S4
    JMP8  feature_fail      ; must not fall through
gen_sub:
    LDI   r3, 0x21
    RET   S3
gen_jmp:
    JMP8  gen_back
gen_done:
.ifndef RISCC_MIN
    JALL  S5, gen16         ; two-word form with a non-default link
g16r:
    JMP8  g16ok             ; reached again via RET S5
gen16:
    MFS   r2, S5            ; link is the byte address after the two-word JALL
    LDI16 r4, g16r
    SUB   r0, r2, r4
    BNEZ  feature_fail
    RET   S5
g16ok:
.endif

.ifdef RISCC_SYS
    LDI16 r5, 0x7F00        ; restore the IRQ test's final RAM values
    LDI   r1, 1
    ST   r1, [r5+0]
    LDI   r1, 2
    ST   r1, [r5+2]
    LDI   r0, 0             ; restore base-suite final scratch registers
    LDI   r1, 2
    MFS   r2, S5
    LDI   r3, 0x42
    LDI   r4, 0x42
.endif

    JMP8  success

feature_fail:
    LDI16 r7, 0x0BAD
    LDI16 r6, 0xFFFE
    ST   r7, [r6+0]
    HALT

subr:
    LDI   r3, 0x42
    RET   S7

success:
    LDI16 r7, 0x600D
    LDI16 r6, 0xFFFE
    ST   r7, [r6+0]
    HALT
.endif

.balign 4, 0
.rodata
data_probe:
    .short 0x4C44, 0x5048
data_guard:
    .short 0xBAD3

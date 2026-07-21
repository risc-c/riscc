; RISC-C self-checking test suite.
; Mainline profiles and Nano share this source:
;   --profile min    : min profile, replacing sys-only sections
;   --profile full   : full-profile MUL coverage
;   --profile nano   : Nano-compatible branch
; SLT, SLTU, LDB, and LDBS coverage is conditional on the selected profile.
; Failure writes 0x0BAD to the result register (I/O page, byte 0xFFFE)
; and parks.  Success writes 0x600D there and parks.

.ifdef RISCC_NANO
; Nano uses the same test source with its profile-specific instruction set.
.vectors

.text
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
    STW   r1, [r6+0]
    LDW   r2, [r6+0]
    SUB   r0, r2, r1
    BNEZ  fail
    ADDI  r6, 8
    STW   r1, [r6-4]
    LDW   r3, [r6-4]
    SUB   r0, r3, r1
    BNEZ  fail
    LDI   r4, 4
    ADD   r3, r6, r4
    STW   r1, [r3+0]
    LDWX  r5, [r6+r4]
    SUB   r0, r5, r1
    BNEZ  fail

    ; Effective-address alignment: odd base plus odd displacement is valid.
    LDI16 r3, 0x0301
    LDI16 r1, 0x1357
    STW   r1, [r3+1]
    LDW   r2, [r3+1]
    SUB   r0, r2, r1
    BNEZ  fail
    STW   r1, [r3-1]
    LDW   r2, [r3-1]
    SUB   r0, r2, r1
    BNEZ  fail
    LDI16 r3, 0x0301
    STW   r1, [r3+127]
    LDW   r2, [r3+127]
    SUB   r0, r2, r1
    BNEZ  fail
    LDI16 r3, 0x0380
    STW   r1, [r3-128]
    LDW   r2, [r3-128]
    SUB   r0, r2, r1
    BNEZ  fail

    ; byte lanes
    LDI   r4, 1
    LDI   r5, 0x80
    ADD   r1, r6, r4
    STB   r5, [r1]
    LDB   r2, [r6+r4]
    LDI16 r5, 0x0080
    SUB   r0, r2, r5
    BNEZ  fail

    ; count-one right shifts
    LDI16 r1, 0x8001
    SHRI  r2, r1, 1
    SARI  r3, r1, 1
    LDI16 r4, 0x4000
    SUB   r0, r2, r4
    BNEZ  fail
    LDI16 r4, 0xC000
    SUB   r0, r3, r4
    BNEZ  fail
    SHL1  r5, r2
    LDI16 r4, 0x8000
    SUB   r0, r5, r4
    BNEZ  fail

    ; nano register call: CALL rd, ra links into rd; return with JMP rd
    LDI16 r1, subr >> 1
    CALL  r7, r1
after_call:
    LDI16 r4, after_call >> 1
    SUB   r0, r7, r4
    BNEZ  fail
    LDI   r4, 0x42
    SUB   r0, r3, r4
    BNEZ  fail

    JMP8  success

fail:
    LDI16 r7, 0x0BAD
    LDI16 r6, 0xFFFE
    STW   r7, [r6+0]
fail_loop:
    JMP8  fail_loop

success:
    LDI16 r7, 0x600D
    LDI16 r6, 0xFFFE
    STW   r7, [r6+0]
done:
    JMP8  done

subr:
    LDI   r3, 0x42
    JMP   r7
.else
.vectors
.ifdef RISCC_SYS
    JMP16 start             ; words 0..1: reset vector slot
    JMP16 isr_irq           ; words 2..3: IRQ vector slot
.endif

.text
.ifdef RISCC_SYS
fail:
    LDI16 r7, 0x0BAD
    LDI16 r6, 0xFFF6
    STW   r7, [r6+0]
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
    LDW   r1, [r2+0]        ; read IRQ cause and acknowledge it
    LDI16 r2, 0x7F00
    STW   r1, [r2+0]        ; log the cause in ordinary RAM
    LDW   r1, [r2+2]        ; entry counter
    ADDI  r1, 1             ; the system half is exactly EPC + 3 saves
    STW   r1, [r2+2]
    MFS   r2, S3
    MFS   r1, S2
    MFS   r0, S1
    ERET
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
    STW   r1, [r6+0]
    LDW   r2, [r6+0]
    SUB   r0, r2, r1
    BNEZ  fail_late
    ADDI  r6, 8
    STW   r1, [r6-4]
    LDW   r3, [r6-4]
    SUB   r0, r3, r1
    BNEZ  fail_late
    LDI   r4, 4
    ADD   r3, r6, r4
    STW   r1, [r3+0]
    LDWX  r5, [r6+r4]
    SUB   r0, r5, r1
    BNEZ  fail_late

    ; Word alignment applies to the effective address, not separately to
    ; base or displacement. Exercise odd+odd and both simm8 boundaries.
    LDI16 r3, 0x0301        ; odd base + odd positive displacement
    LDI16 r1, 0x1357
    STW   r1, [r3+1]       ; effective address 0x0302
    LDW   r2, [r3+1]
    SUB   r0, r2, r1
    BNEZ  fail_late
    STW   r1, [r3-1]       ; odd base + odd negative displacement = 0x0300
    LDW   r2, [r3-1]
    SUB   r0, r2, r1
    BNEZ  fail_late
    LDI16 r3, 0x0301
    STW   r1, [r3+127]     ; maximum simm8, effective address 0x0380
    LDW   r2, [r3+127]
    SUB   r0, r2, r1
    BNEZ  fail_late
    LDI16 r3, 0x0380
    STW   r1, [r3-128]     ; minimum simm8, effective address 0x0300
    LDW   r2, [r3-128]
    SUB   r0, r2, r1
    BNEZ  fail_late

    LDI   r4, 1             ; odd byte lane
    LDI   r5, 0x80
    ADD   r1, r6, r4
    STB   r5, [r1]
    LDB   r2, [r6+r4]
    LDBS  r3, [r6+r4]
    LDI16 r5, 0x0080
    SUB   r0, r2, r5
    BNEZ  fail_late
    LDI16 r5, 0xFF80
    SUB   r0, r3, r5
    BNEZ  fail_late

    LDI   r4, 2             ; even byte lane
    LDI   r5, 0xFF
    ADD   r1, r6, r4
    STB   r5, [r1]
    LDB   r2, [r6+r4]
    LDBS  r3, [r6+r4]
    LDI16 r5, 0x00FF
    SUB   r0, r2, r5
    BNEZ  fail_late
    LDI16 r5, 0xFFFF
    SUB   r0, r3, r5
    BNEZ  fail_late

    JMP8  shifts_start
.ifndef RISCC_SYS
fail:
.endif
fail_late:
    LDI16 r7, 0x0BAD
    LDI16 r6, 0xFFFE
    STW   r7, [r6+0]
    HALT
shifts_start:

    ; --- one-bit shifts ---
    LDI16 r1, 0x8001
    SHRI  r2, r1, 1
    SARI  r3, r1, 1
    LDI16 r4, 0x4000
    SUB   r0, r2, r4
    BNEZ  fail_late
    LDI16 r4, 0xC000
    SUB   r0, r3, r4
    BNEZ  fail_late
    SHL1  r5, r2            ; pseudo: ADD r5, r2, r2
    LDI16 r4, 0x8000
    SUB   r0, r5, r4
    BNEZ  fail_late

    ; --- register call: link in S7, return via RETS ---
    LDI16 r1, subr >> 1
    CALL  r1
after_call:
    LDI   r4, 0x42
    SUB   r0, r3, r4
    BNEZ  fail_late

.ifndef RISCC_SYS
    ; --- far call / jump fallback (mandatory core has no CALL16/JMP16) ---
    LDI   r3, 0
    LDI16 r1, subr16 >> 1
    CALL  r1                ; far call = LDI16 + CALL ra; returns via RETS
    SUB   r0, r3, r4
    BNEZ  fail_late
    LDI16 r1, far_ok >> 1
    JMP   r1                ; far jump = LDI16 + JMP ra; S7 keeps the link
    JMP8  fail_late
subr16:
    LDI   r3, 0x42
    RETS
far_ok:
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
    ; --- two-word direct call / jump (CALL16 / JMP16 / RETS) ---
    LDI   r3, 0
    CALL16 subr16           ; link {IE, pc+2} -> S7; subr16 returns via RETS
    SUB   r0, r3, r4
    BNEZ  fail_late
    JMP16 c16_ok            ; no link: S7 keeps the last call's link
    JMP8  fail_late
subr16:
    LDI   r3, 0x42
    RETS
c16_ok:
    ; --- system profile: S registers, IRQ, ERET ---
    LDI16 r1, 0xBEEF
    MTS   S5, r1
    LDI   r1, 0
    MFS   r1, S5
    LDI16 r2, 0xBEEF
    SUB   r0, r1, r2
    BNEZ  fail_late

    LDI16 r5, 0x7F00
    LDI   r2, 0
    STW   r2, [r5+0]        ; IRQ cause log = 0
    STW   r2, [r5+2]        ; ISR entry counter = 0

    STI
    LDI16 r5, 0xFFFA
    LDI16 r1, 0xAA55
    STW   r1, [r5+0]        ; magic store: testbench raises irq
wait_irq:
    LDI16 r5, 0x7F00
    LDW   r1, [r5+2]
    ADDI  r1, -1
    MOV   r0, r1
    BNEZ  wait_irq          ; until the ISR has run
    CLI
    LDI16 r5, 0x7F00
    LDW   r1, [r5+0]        ; IRQ handler logged the asserted test cause = 1
    ADDI  r1, -1
    MOV   r0, r1
    BNEZ  fail_late
    LDW   r1, [r5+2]        ; r1 = 1 entry
    MFS   r2, S5            ; r2 = 0xBEEF (round trip survived the ISR)
    JMP8  feature_tests
.endif

feature_tests:
.ifdef RISCC_SYS
    ; --- immediate shifts: amounts 1..8, sign fill, rd==ra, composed shifts ---
    LDI16 r1, 0x8001
    SHRI  r3, r1, 4         ; 0x0800
    LDI16 r4, 0x0800
    SUB   r0, r3, r4
    BNEZ  feature_fail
    SARI  r3, r1, 4         ; 0xF800
    LDI16 r4, 0xF800
    SUB   r0, r3, r4
    BNEZ  feature_fail
    LDI   r3, 3
    SHLI  r3, r3, 4         ; rd==ra: 0x30
    LDI   r4, 0x30
    SUB   r0, r3, r4
    BNEZ  feature_fail
    SHRI  r2, r1, 1         ; count-1 cheap opcode: 0x4000
    SARI  r3, r1, 1         ; count-1 cheap opcode: 0xC000
    LDI16 r4, 0x4000
    SUB   r0, r2, r4
    BNEZ  feature_fail
    LDI16 r4, 0xC000
    SUB   r0, r3, r4
    BNEZ  feature_fail
    LDI16 r1, 0xFF00
    SHRI  r1, r1, 8         ; amount 8: 0x00FF
    LDI16 r4, 0x00FF
    SUB   r0, r1, r4
    BNEZ  feature_fail
    LDI16 r1, 0xF000
    SHRI  r1, r1, 8         ; >>12 composed: >>8 then >>4
    SHRI  r1, r1, 4
    LDI   r4, 15
    SUB   r0, r1, r4
    BNEZ  feature_fail
    LDI   r1, 1
    SHLI  r1, r1, 8         ; <<15 composed
    SHLI  r1, r1, 7
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

    ; ---- JAL/RET generality (all profiles) ----
    LDI16 r1, gen_sub >> 1  ; JAL S3: link lands in S3, callee RETs via S3
    LDI   r3, 0
    JAL   S3, r1
    CMPI  r3, 0x21          ; callee side effect proves the round trip
    BNEZ  feature_fail
    LDI16 r2, 0x1234        ; JAL S0 is a plain jump: S0 must be untouched
    MTS   S0, r2
    LDI16 r1, gen_jmp >> 1
    JAL   S0, r1
gen_back:
    MFS   r2, S0
    LDI16 r4, 0x1234
    SUB   r0, r2, r4
    BNEZ  feature_fail
    LDI16 r2, gen_done >> 1 ; RET Sa: return through a manufactured address
    MTS   S4, r2
    RET   S4
    JMP8  feature_fail      ; must not fall through
gen_sub:
    LDI   r3, 0x21
    RET   S3
gen_jmp:
    JMP8  gen_back
gen_done:
.ifdef RISCC_SYS
    JAL16 S5, gen16         ; two-word form with a non-default link
g16r:
    JMP8  g16ok             ; reached again via RET S5
gen16:
    MFS   r2, S5            ; link must be the word after the two-word JAL16
    LDI16 r4, g16r >> 1
    SUB   r0, r2, r4
    BNEZ  feature_fail
    RET   S5
g16ok:
.endif

.ifdef RISCC_SYS
    LDI16 r5, 0x7F00        ; restore the IRQ test's final RAM values
    LDI   r1, 1
    STW   r1, [r5+0]
    LDI   r1, 2
    STW   r1, [r5+2]
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
    STW   r7, [r6+0]
    HALT

subr:
    LDI   r3, 0x42
    RETS

success:
    LDI16 r7, 0x600D
    LDI16 r6, 0xFFFE
    STW   r7, [r6+0]
    HALT
.endif

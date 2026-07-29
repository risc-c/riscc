# RISC-C Instruction Set Architecture

RISC-C is an open ISA for compact systems that need a tiny controller.

This document is the RISC-C ISA specification. It defines the architectural
state, instruction encodings and semantics, memory-access rules, interrupt
behavior, and profile extensions.

The RISC-C specification and reference implementations are released under
the ISC License and may be used, copied, modified, and distributed for any
purpose, with or without fee.

Version: `v0.17.0`.

Author: Arto Vuori <avuori@iki.fi>

## 1. RISC-C Base Integer Instruction Set

This chapter describes the RISC-C base integer ISA. The `min` profile defines
the base instruction set; section 8 summarizes the profile differences.

The base ISA uses 16-bit instruction halfwords. Most instructions occupy one
halfword; the long forms defined in section 5 occupy two. Instruction
addresses are measured in halfwords. The mainline ISA is
parameterized by the `XLEN` data word size: RC16 has `XLEN = 16` and RC32 has
`XLEN = 32`. Unless a rule names a narrower access or field explicitly, an
operation on a register, an S-register, or a data word is `XLEN` bits wide.

The mainline configurations each provide the ordered `min`, `sys`, and `full`
profiles. Nano is an RC16-only subset profile.

### 1.1 Architectural State

| state | width | description |
|---|---:|---|
| `r0..r7` | XLEN | general-purpose registers |
| `S0..S7` | XLEN | S registers |
| `pc` | XLEN | program counter, in instruction addresses |
| `IE` | 1 | interrupt-enable bit (`sys` profile) |

There are no arithmetic condition codes and no architectural zero register.
All `r`- and S-register writes retain their low XLEN bits. Program-counter
updates retain their low XLEN bits.

`r0` has no special storage behavior. All short conditional branches test
`r0`, and `CMPI` always writes its result to `r0`.

`MFS` and `MTS` let software read and write `S0..S7` as ordinary XLEN-bit
storage. `JAL` uses an S-register destination for its link, and `RET` uses an
S-register operand for its return address. The `sys` profile additionally
provides `RETI`, `CLI`, and `STI`. Only `S0` has special
architectural treatment:

- In `JAL`, destination `S0` suppresses the link write.
- In the `sys` profile, `S0` is `EPC`, the interrupt return program
  counter.

Except for the roles of `S0` defined above, S-register use is unrestricted.
Interrupt entry overwrites `S0`; software executing with interrupts enabled
must not rely on an ordinary value in `S0` surviving an interrupt.

`IE` is initialized to zero by reset. Reset `pc` is platform-defined;
general-register and S-register values are unspecified following reset.

Unless an instruction explicitly assigns `pc`, execution continues at
`pc_next`.

Instruction addresses, S-register values, and general-register values are all
XLEN bits wide. This applies to link addresses written by `JAL` and to the
interrupt return address written to `S0`.

All named source operands and effective-address operands are read from the
architectural state before an instruction writes any architectural
destination. This ordering applies when a destination register is also a
source register.

### 1.2 Instruction Length and Major Opcodes

Each instruction begins with one 16-bit halfword. The two most-significant
bits of that halfword select one of four major opcode spaces:

| bits `[15:14]` | format bits `[15:0]` | instruction class |
|---|---|---|
| `00` | `00 ddd aaa iiiiiiii` | reserved for future ISA extension |
| `01` | `01 ddd aaa iiiiiii S` | compact immediate-offset data-word load or store |
| `10` | `10 ddd ooo iiiiiiii` | immediate or branch instruction |
| `11` | `11 ddd aaa fffff bbb` | register-format instruction |

When present, the named fields retain their positions across formats: `ddd`,
`aaa`, and `bbb` generally select destination or source registers, while
`iiiiiiii` encodes an immediate value. An instruction may give a field a
different meaning.

Every instruction is naturally aligned to two bytes.

Bits are numbered from least significant to most significant: bit 0 is the
least-significant bit of a byte or data word, and bit 15 is the
most-significant bit of a 16-bit instruction or instruction-memory halfword.
Instruction-format diagrams show the most-significant bit at the left. Byte
order does not change bit numbering within a byte.

Unless explicitly defined otherwise, unused instruction fields must be zero
in portable software. Encodings with nonzero unused fields, encodings marked
reserved, instructions not defined by the implemented profile or an
implemented extension, and other invalid encodings have undefined behavior
when executed. An implementation may trap,
execute another instruction, treat the encoding as an alias of a defined
instruction, or exhibit any other behavior. Software must not depend on such
behavior.

## 2. Address Spaces and Memory Access

RISC-C has separate architectural instruction and data address spaces. An
instruction address selects a 16-bit instruction-memory halfword, while a
data address selects an 8-bit byte. An XLEN-bit instruction address therefore
selects `2^XLEN` instruction-memory halfwords, and an XLEN-bit data address
selects `2^XLEN` bytes. RC16 consequently has a 128 KiB architectural
instruction address space. Instruction and data memory may be implemented
with separate physical memories or with a shared physical memory; that choice
does not change the two architectural addressing conventions. An
implementation with a smaller instruction memory may implement only its
required low instruction-address bits; its treatment of addresses outside that
range is platform-defined. A program must explicitly convert a byte address
to an instruction address before using it as an indirect control-flow
destination.

The ISA does not require or prohibit modification of instruction memory. If
instruction and data memory share physical storage, the implementation or
platform must define when a store through the data interface becomes visible
to instruction fetches. Programs that modify instruction memory must use the
applicable platform synchronization mechanism before executing the modified
instructions.

Data memory is little-endian. Effective data addresses use XLEN-bit addition
and wrap modulo `2^XLEN`.

When represented as bytes, instruction-memory halfwords are little-endian:
the low byte precedes the high byte.

### 2.1 Memory Ordering, Atomicity, and Coherence

For each RISC-C core, accesses to ordinary data memory have the same
architectural effect as if they were performed in program order. An
implementation may execute or buffer accesses internally in another order,
provided this does not change the behavior observed by that core.

A byte load or store to ordinary data memory is an indivisible 8-bit access.
An aligned halfword load or store is an indivisible 16-bit access, and an
aligned data-word load or store is an indivisible XLEN-bit access. No observer
may observe only part of an aligned data-word store or a data-word value
assembled from parts of two different aligned data-word stores. Byte stores
may independently replace either byte of a halfword as specified by the
byte-access semantics.

The order and time at which memory accesses become visible to other cores,
devices, DMA engines, or external agents are platform-defined. RISC-C does
not require caches to be coherent, and accesses need not become visible to
other agents in program order unless required by the platform.

A platform may define fence, cache-maintenance, synchronization, or atomic
read-modify-write operations. These operations are not part of the base
RISC-C ISA.

The ordering, atomicity, and side effects of memory-mapped device accesses
are platform-defined.

### 2.2 Alignment

`LDH`, `LDHS`, and `STH` require a two-byte-aligned effective address.
`LDW`, `STW`, and `LDWX` require an effective address aligned to `XLEN / 8`
bytes: two bytes in RC16 and four bytes in RC32. The effective address,
rather than an individual base or displacement, determines alignment. An
unaligned access has undefined behavior; software must not depend on whether
an implementation traps, rounds the address, or performs another action. Byte
accesses have no alignment requirement.

### 2.3 Load and Store Instructions

The compact immediate-offset word format is:

```text
01 ddd aaa iiiiiii S
```

`aaa` selects `ra`; `S` selects the access direction. The displacement is:

```text
RC16: simm = sx8({ i[7:1], 0 })
RC32: simm = sx9({ i[1], i[7:2], 0, 0 })
```

For `LDW`, `ddd` selects `rd`; for `STW`, it selects `rs`.

| encoding | instruction | operation |
|---|---|---|
| `01`, `S=0` | `LDW rd, [ra+simm]` | `R[d] ← MXLEN[R[a] + simm]` |
| `01`, `S=1` | `STW rs, [ra+simm]` | `MXLEN[R[a] + simm] ← R[s]` |

The register-format is:

```text
11 ddd aaa fffff bbb
```

`ddd` and `aaa` select `rd` or `rs` and `ra`; `bbb` selects `rb` unless the
instruction defines it as a sub-operation.

| `fffff` | instruction | operation |
|---|---|---|
| `01_000` | `LDWX rd, [ra+rb]` | `R[d] ← MXLEN[R[a] + R[b]]` |
| `01_001` | `LDH rd, [ra+rb]` | `R[d] ← zx16(M16[R[a] + R[b]])` |
| `01_010` | `LDB rd, [ra+rb]` | `R[d] ← zx8(M8[R[a] + R[b]])` |
| `01_011`, `bbb=000` | `STB rs, [ra]` | `M8[R[a]] ← R[s][7:0]` |
| `01_011`, `bbb=001` | `STH rs, [ra]` | `M16[R[a]] ← R[s][15:0]` |
| `01_110` | `LDBS rd, [ra+rb]` | `R[d] ← sx8(M8[R[a] + R[b]])` |
| `10_001` | `LDHS rd, [ra+rb]` | `R[d] ← sx16(M16[R[a] + R[b]])` |

`LDW` reads one XLEN-bit data word at the effective address formed by adding
the compact signed displacement to `ra`. It is subject to the data-word
alignment requirement in section 2.2.

`STW` writes the complete XLEN-bit value of `rs` at the effective address
formed by adding the compact signed displacement to `ra`. It is subject to the
data-word alignment requirement in section 2.2.

`LDWX` is subject to the data-word alignment requirement in section 2.2.
`LDH`, `LDHS`, and `STH` are subject to the halfword-alignment requirement.
`STB` stores the low byte of its source register.

`LDB` reads a byte at the effective address formed by adding `ra` and `rb`,
then zero-extends it to XLEN bits. `LDBS` uses the same effective address and
sign-extends the loaded byte to XLEN bits. Neither byte load has an alignment
requirement.

## 3. Immediate and Branch Instructions

The immediate format is:

```text
10 ddd ooo iiiiiiii
```

For most non-branch instructions, `ddd` selects `rd` and `ooo` selects the
operation. For `CMPI`, `ddd` selects source register `rs`; the destination is
implicitly `r0`.

| `ooo` | instruction | operation |
|---|---|---|
| `000` | `LDI rd, imm8` | `R[d] ← zx8(imm8)` |
| `001` | `LUI rd, imm8` | `R[d] ← zxXLEN(imm8 << 8)` |
| `010` | `ADDI rd, simm8` | `R[d] ← R[d] + sx8(simm8)` |
| `011` | `CMPI rs, simm8` | `R[0] ← R[s] - sx8(simm8)` |
| `100` | `ANDI rd, imm8` | `R[d] ← R[d] & zx8(imm8)` |
| `101` | `ORI rd, imm8` | `R[d] ← R[d] \| zx8(imm8)` |
| `110` | `XORI rd, imm8` | `R[d] ← R[d] ^ zx8(imm8)` |
| `111` | branch group | specified below |

`LDI` writes the zero-extended 8-bit immediate to `rd`.

`LUI` writes the 8-bit immediate into bits `[15:8]` of `rd` and clears every
other result bit. Its result therefore always fits in the low 16 bits, in
both RC16 and RC32.

`ADDI` adds a sign-extended immediate to the old value of `rd`.

`CMPI` subtracts its sign-extended immediate from `rs` and writes the result
to `r0`; it does not modify `rs`.

`ANDI`, `ORI`, and `XORI` perform bitwise AND, OR, and XOR, respectively,
between `rd` and a zero-extended immediate, then write the result to `rd`.

The branch-group format is:

```text
10 ccc 111 rrrrrrrr
```

`rel8` is a signed displacement in instruction addresses, relative to the
next instruction:

```text
pc_target = pc_next + sx8(rel8)
```

| `ccc` | instruction | operation |
|---|---|---|
| `000` | `BEQZ rel8` | branch if `R[0] == 0` |
| `001` | `BNEZ rel8` | branch if `R[0] != 0` |
| `010` | `BLTZ rel8` | branch if `R[0][XLEN-1] == 1` |
| `011` | `BGEZ rel8` | branch if `R[0][XLEN-1] == 0` |
| `100` | `JMP8 rel8` | unconditional branch |
| `101..111` | reserved | undefined |

`BEQZ` branches when `r0` is zero. Otherwise, execution continues at
`pc_next`.

`BNEZ` branches when `r0` is nonzero. Otherwise, execution continues at
`pc_next`.

`BLTZ` branches when the sign bit of `r0` is one. Otherwise, execution
continues at `pc_next`.

`BGEZ` branches when the sign bit of `r0` is zero. Otherwise, execution
continues at `pc_next`.

`JMP8` always transfers control to `pc_target`.

For a taken branch, `pc ← pc_target`; otherwise `pc ← pc_next`.

## 4. Register-Format Instructions

The register format is:

```text
11 ddd aaa fffff bbb
```

Unless specified otherwise, `ddd`, `aaa`, and `bbb` select `rd`, `ra`, and
`rb`, respectively.

| `fffff` | instruction | operation |
|---|---|---|
| `00_000` | `ADD rd, ra, rb` | `R[d] ← R[a] + R[b]` |
| `00_001` | `SUB rd, ra, rb` | `R[d] ← R[a] - R[b]` |
| `00_010` | `SLT rd, ra, rb` | `R[d] ← (signedXLEN(R[a]) < signedXLEN(R[b])) ? 1 : 0` |
| `00_011` | `SLTU rd, ra, rb` | `R[d] ← (R[a] < R[b]) ? 1 : 0` |
| `00_100` | `AND rd, ra, rb` | `R[d] ← R[a] & R[b]` |
| `00_101` | `OR rd, ra, rb` | `R[d] ← R[a] \| R[b]` |
| `00_110` | `XOR rd, ra, rb` | `R[d] ← R[a] ^ R[b]` |
| `00_111` | `MUL rd, ra, rb` | `R[d] ← (R[a] * R[b])[XLEN-1:0]` |
| `01_000` | `LDWX rd, [ra+rb]` | `R[d] ← MXLEN[R[a] + R[b]]` |
| `01_001` | `LDH rd, [ra+rb]` | `R[d] ← zx16(M16[R[a] + R[b]])` |
| `01_010` | `LDB rd, [ra+rb]` | `R[d] ← zx8(M8[R[a] + R[b]])` |
| `01_011`, `bbb=000` | `STB rs, [ra]` | `M8[R[a]] ← R[s][7:0]` |
| `01_011`, `bbb=001` | `STH rs, [ra]` | `M16[R[a]] ← R[s][15:0]` |
| `01_100` | `SHRI rd, ra, imm` | `R[d] ← R[a] >> (bbb + 1)` |
| `01_101` | `SARI rd, ra, imm` | `R[d] ← signedXLEN(R[a]) >>> (bbb + 1)` |
| `01_110` | `LDBS rd, [ra+rb]` | `R[d] ← sx8(M8[R[a] + R[b]])` |
| `01_111` | `SHLI rd, ra, imm` | `R[d] ← R[a] << (bbb + 1)` |
| `10_000` | `DIVU rr, rq, rb` | paired unsigned divide/remainder; section 7.1 |
| `10_001` | `LDHS rd, [ra+rb]` | `R[d] ← sx16(M16[R[a] + R[b]])` |
| `10_010` | `FSR1 rd, ra, rb` | `R[d] ← (R[a] >> 1) \| (R[b][0] << (XLEN-1))` |
| `10_011` | `FSL1 rd, ra, rb` | `R[d] ← (R[a] << 1) \| R[b][XLEN-1]` |
| `10_100` | `MULHU rl, rh, rb` | paired unsigned product; section 7.1 |
| `10_101..11_110` | reserved | undefined |
| `11_111` | control and S-register group | section 5 |

The load and store instructions in this table are described in section 2.3.

`ADD` adds the two source registers and writes the low XLEN bits of the result
to `rd`.

`SUB` subtracts `rb` from `ra` and writes the low XLEN bits of the result to
`rd`.

`SLT` and `SLTU` perform signed and unsigned less-than comparisons,
respectively. Each writes one to `rd` when `ra` is less than `rb`; otherwise
it writes zero.

`AND`, `OR`, and `XOR` perform the corresponding bitwise operation on `ra`
and `rb`, then write the result to `rd`.

`FSL1` and `FSR1` are one-bit funnel shifts. `FSL1` shifts `ra` left and
inserts the sign-position bit of `rb` at bit 0. `FSR1` shifts `ra` right and
inserts bit 0 of `rb` at the sign position. Both source registers are read
before `rd` is written, so
`rd` may name either source register.

`SHLI` and `SHRI` shift `ra` left and right, respectively, inserting zeros
into the vacated bits. Their shift count is `bbb+1`.

`SARI` shifts `ra` right and copies the original sign bit into vacated high
bits. Its shift count is `bbb+1`.

`MUL` writes the low XLEN bits of the product of `ra` and `rb` to `rd`. This
low XLEN-bit portion is the same for signed and unsigned multiplication.

`SHLI`, `SHRI`, and `SARI` encode shift counts from 1 through 8. In the
`min` profile, `SHRI` and `SARI` always shift by one and their `bbb` field
must be zero; `SHLI` is undefined. `MUL` is available only in the `full`
profile.

## 5. Control Transfer and S-Register Instructions

Most control and S-register instructions have the following format:

```text
11 ddd aaa 11111 bbb
```

For `bbb = 000` and `bbb = 110`, `ddd` is a control selector. Only the
following control-selector values are defined:

| `bbb` | `ddd` | instruction | profile | operation |
|---|---|---|---|---|
| `000` | `000` | `RET Sa` | all | `pc ← S[a]` |
| `000` | `111` | `RETI Sa` | sys | `IE ← 1`; `pc ← S[a]` |
| `110` | `000` | `CLI` | sys | `IE ← 0` |
| `110` | `111` | `STI` | sys | `IE ← 1` |

All other `ddd` values in those two `bbb` rows are reserved and undefined.
`aaa` selects `Sa` for `RET` and `RETI`; `CLI` and `STI` require `aaa = 0`.

The remaining `bbb` values have the following definitions:

| `bbb` | instruction | profile | operation |
|---|---|---|---|
| `001` | `JAL Sd, ra` | all | if `d != 0`, `S[d] ← pc_next`; `pc ← R[a]` |
| `010` | `MFS rd, Sa` | all | `R[d] ← S[a]` |
| `011` | `MTS Sd, ra` | all | `S[d] ← R[a]` |
| `100` | reserved |  | undefined |
| `101` | `JAL16 Sd, target` | sys | specified below |
| `111` | reserved |  | undefined |

`JAL16` requires `aaa = 0`; other `aaa` values in its row are reserved and
undefined.

`RET` transfers control through its S-register operand. It does not change
`IE`.

`RETI` transfers control through its S-register operand and sets `IE` to one.

`CLI` clears `IE`.

`STI` sets `IE` to one.

`JAL` transfers control through `ra` and, unless `Sd` is `S0`, writes the
instruction address of the following instruction to `Sd`. Thus,
`JAL S0, ra` is a register-indirect jump without a link write.

`MFS` copies the selected S-register to `rd`.

`MTS` copies `ra` to the selected S-register.

The long forms have these first-halfword encodings:

| encoding | instruction | profile |
|---|---|---|
| `11 ddd 000 11101 100` | `LDI16 rd, imm16` | sys |
| `11 ddd 000 11111 101` | `JAL16 Sd, target` | sys |

Both long forms occupy two consecutive instruction halfwords. `LDI16` uses
the following halfword as `imm16`, writes `zx16(imm16)` to `rd`, and continues
at `pc + 2`. Each long form is one architectural instruction; interrupts are
not taken between its halfwords.

`JAL16` uses the following halfword as the absolute instruction address
`target`. Unless `Sd` is `S0`, it writes `pc + 2` to `Sd`, then transfers
control to `target`. `JMP16 target` is the alias `JAL16 S0, target`.

## 6. Interrupts

Interrupts are optional and are implemented by some profiles. A platform may
provide
one or more interrupt sources and may use an interrupt controller to select
an interrupt vector. Interrupts are sampled between completed architectural
instructions, using the value of `IE` resulting from the preceding
instruction. A maskable interrupt is taken only when that value is one.

At an interrupt boundary, `pc` is the instruction address of the next
instruction that would have executed had the interrupt not been taken.
On entry:

```text
S[0] ← pc
IE ← 0
pc ← interrupt_vector
```

`interrupt_vector` is the XLEN-bit instruction address selected for the
accepted interrupt. Its value, the number of vectors and sources,
source priority, level or edge triggering, interrupt acknowledgement, and
controller behavior are platform-defined.

`CLI` clears `IE`, so no interrupt can be taken before the following
instruction. `STI` sets `IE`, so an interrupt may be taken before the
following instruction. `RETI` sets `IE` and transfers control, so an
interrupt may be taken before the returned-to instruction executes.

Reset-vector contents and interrupt synchronization are platform
responsibilities.

## 7. Multiply-Divide Instructions Extension

The following optional instructions occupy otherwise reserved three-register
slots:

```text
MULHU  rl, rh, rb
DIVU   rr, rq, rb
```

`MULHU` is the paired unsigned multiply. It uses `ddd = rl`, `aaa = rh`, and
`bbb = rb`; using the input register values:

```text
P     = R[rh] * R[rb]
R[rl] ← P[XLEN-1:0]
R[rh] ← P[2*XLEN-1:XLEN]
```

`rl` and `rh` must be different registers. `rb` may name either input/output
register: both multiplier operands are read before either result is written.
Thus the extension needs no separate low-half multiply instruction; regular
`MUL` remains the non-destructive low-half operation supplied by `full`.

`DIVU` uses `ddd = rr`, `aaa = rq`, and `bbb = rb`. It treats the register
pair `rr:rq` as a two-XLEN-bit unsigned partial dividend. More precisely,
using the input register values:

```text
N       = (R[rr] << XLEN) | R[rq]
divisor = R[rb]
R[rq]   ← N / divisor
R[rr]   ← N % divisor
```

`rr`, `rq`, and `rb` must name different registers. `divisor` must be
nonzero, and `R[rr] < divisor` is required on entry; this guarantees that the
quotient fits in XLEN bits. If any of these requirements is not met, the result
is undefined. These operand restrictions are an exception to the general
source-before-destination ordering rule.

## 8. Profiles

`min`, `sys`, and `full` are ordered ISA subsets: a program using only a
smaller profile's defined instructions is valid on a larger profile. Each
mainline profile is available in RC16 and RC32 configurations. `nano` is an
RC16-only subset profile.

### 8.1 Instruction Availability

An `X` in the `RC32` column marks an instruction absent from RC16 and Nano.

| instruction | `RC32` | `min` | `sys` | `full` | `nano†` |
|---|:---:|:---:|:---:|:---:|:---:|
| `LDW rd, [ra+simm]` |  | X | X | X | X |
| `STW rs, [ra+simm]` |  | X | X | X | X |
| `LDWX rd, [ra+rb]` |  | X | X | X | X |
| `LDH rd, [ra+rb]` | X | X | X | X |  |
| `LDHS rd, [ra+rb]` | X | X | X | X |  |
| `LDB rd, [ra+rb]` |  | X | X | X | X |
| `LDBS rd, [ra+rb]` |  | X | X | X |  |
| `STB rs, [ra]` |  | X | X | X | X |
| `STH rs, [ra]` | X | X | X | X |  |
| `LDI rd, imm8` |  | X | X | X | X |
| `LUI rd, imm8` |  | X | X | X | X |
| `ADDI rd, simm8` |  | X | X | X | X |
| `CMPI rs, simm8` |  | X | X | X |  |
| `ANDI rd, imm8` |  | X | X | X | X |
| `ORI rd, imm8` |  | X | X | X | X |
| `XORI rd, imm8` |  | X | X | X | X |
| `BEQZ rel8` |  | X | X | X | X |
| `BNEZ rel8` |  | X | X | X | X |
| `BLTZ rel8` |  | X | X | X | X |
| `BGEZ rel8` |  | X | X | X | X |
| `JMP8 rel8` |  | X | X | X | X |
| `ADD rd, ra, rb` |  | X | X | X | X |
| `SUB rd, ra, rb` |  | X | X | X | X |
| `SLT rd, ra, rb` |  | X | X | X |  |
| `SLTU rd, ra, rb` |  | X | X | X | X |
| `AND rd, ra, rb` |  | X | X | X | X |
| `OR rd, ra, rb` |  | X | X | X | X |
| `XOR rd, ra, rb` |  | X | X | X | X |
| `FSL1 rd, ra, rb` |  | X | X | X |  |
| `FSR1 rd, ra, rb` |  | X | X | X |  |
| `SHLI rd, ra, 1..8` |  |  | X | X |  |
| `SHRI rd, ra, 1` |  | X | X | X | X |
| `SHRI rd, ra, 2..8` |  |  | X | X |  |
| `SARI rd, ra, 1` |  | X | X | X | X |
| `SARI rd, ra, 2..8` |  |  | X | X |  |
| `MUL rd, ra, rb` |  |  |  | X |  |
| `MULHU rl, rh, rb` § |  |  |  |  |  |
| `DIVU rr, rq, rb` § |  |  |  |  |  |
| `RET Sa` |  | X | X | X |  |
| `JAL Sd, ra` |  | X | X | X |  |
| `LDI16 rd, imm16` |  |  | X | X |  |
| `JAL16 Sd, target` |  |  | X | X |  |
| `JAL rd, ra` ‡ |  |  |  |  | X |
| `MFS rd, Sa` |  | X | X | X |  |
| `MTS Sd, ra` |  | X | X | X |  |
| `RETI Sa` |  |  | X | X |  |
| `CLI` |  |  | X | X |  |
| `STI` |  |  | X | X |  |

† Nano is defined in section 9.

‡ `JAL rd, ra` is Nano's general-register link encoding; its semantics are
defined in section 9.

§ `MULHU` and `DIVU` are optional extension instructions; neither is required
by any profile.

An unaligned halfword or data-word access has undefined behavior unless
another architectural extension defines it.

## 9. Nano Profile

Nano is a separate reduced RISC-C profile, shown as `nano` in the profile
table. Its encodings and architectural state differ from the ordered `min`,
`sys`, and `full` profile family.

Nano has only `r0..r7` and `pc` as architectural state. It has no S-register
bank, `IE`, `EPC`, or interrupt entry. It uses RC16 widths. Instruction and
data addressing, byte order, alignment, and the memory model are otherwise
the same as for mainline RISC-C. Its defined instruction subset is shown in
the `nano` column of the profile table.

Nano redefines the register-indirect `JAL` encoding as
`JAL rd, ra`: it writes `pc_next` to general register `rd` and transfers
control through `R[a]`. With `rd = r0`, no link is written; this is a
plain register jump. Assemblers may spell these forms as `CALL rd, ra` and
`JMP ra`, respectively.

All instructions marked `X` in the `nano` column use their mainline
semantics except where this section defines otherwise. An empty `nano` cell
denotes an undefined Nano encoding; software must not depend on any
implementation alias.

## 10. Notation

| symbol | meaning |
|---|---|
| `R[x]`, `S[x]` | general register or S-register `x` |
| `MXLEN[a]` | XLEN-bit data word at byte address `a` |
| `M16[a]`, `M8[a]` | 16-bit halfword or 8-bit byte at byte address `a` |
| `pc_next` | instruction address immediately following the current instruction |
| `x ← y` | write value `y` to architectural state `x` |
| `x = y` | define temporary value `x` as `y` |
| `sx8`, `zx8` | sign-extend 8 bits; zero-extend 8 bits |
| `sx16`, `zx16` | sign-extend 16 bits; zero-extend 16 bits |
| `signedXLEN(x)` | interpret XLEN-bit value `x` as a signed two's-complement integer |
| `x >>> n` | arithmetic right shift of signed value `x` by `n` bits |
| `x[h:l]` | bit field |

Arithmetic register results wrap modulo `2^XLEN`. `M16` and `MXLEN` accesses
are subject to the alignment rules in section 2.2.

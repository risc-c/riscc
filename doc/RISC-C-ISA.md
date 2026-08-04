# RISC-C Instruction Set Architecture

RISC-C is an open ISA for compact systems that need a tiny controller.

This document is the RISC-C ISA specification. It defines the architectural
state, instruction encodings and semantics, memory-access rules, interrupt
behavior, and profile extensions.

The RISC-C specification and reference implementations are released under
the ISC License and may be used, copied, modified, and distributed for any
purpose, with or without fee.

Version: `v0.19.0`.

Author: Arto Vuori <avuori@iki.fi>

## 1. RC16 Base Integer Instruction Set

This chapter describes the compact RC16 base integer ISA. RC16 has `XLEN = 16`.
The `min` profile defines the base instruction set; section 9 summarizes the
profile differences.

Most base instructions use one 16-bit instruction halfword. Some profiles and
extensions define two-halfword instructions. Instruction addresses are measured
in halfwords. Unless a rule names a narrower access or field explicitly, an
operation on a register, an S-register, or a data word is `XLEN` bits wide.

The mainline ISA provides the ordered `min`, `sys`, and `full` profiles.
Appendix A defines the Nano variant, and Appendix C defines the optional RC32
width extension.

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
storage. `JALR` uses an S-register destination for its link, and `RET` uses an
S-register operand for its return address. The `sys` profile additionally
provides `RETI`, `CLI`, and `STI`. Only `S0` has special
architectural treatment:

- In `JALR`, destination `S0` suppresses the link write.
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
XLEN bits wide. This applies to link addresses written by `JALR` and to the
interrupt return address written to `S0`.

All named source operands and effective-address operands are read from the
architectural state before an instruction writes any architectural
destination. This ordering applies when a destination register is also a
source register.

### 1.2 Instruction Length and Major Opcodes

Most base instructions occupy one 16-bit halfword. Some profiles and extensions
define instructions that occupy two halfwords. The two most-significant bits of
the first halfword select one of four major opcode spaces:

| bits `[15:14]` | format bits `[15:0]` | instruction class |
|---|---|---|
| `00` | `00 ...` | long instruction |
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

### 1.3 Notation and Conventions

| symbol | meaning |
|---|---|
| `R[x]`, `S[x]` | general register or S-register `x` |
| `MXLEN[a]` | XLEN-bit data word at byte address `a` |
| `M32[a]`, `M16[a]`, `M8[a]` | 32-bit word, 16-bit halfword, or 8-bit byte at byte address `a` |
| `PXLEN[a]` | XLEN-bit program-memory word beginning at instruction address `a` |
| `P16[a]` | 16-bit instruction-memory halfword at instruction address `a` |
| `pc_next` | instruction address immediately following the current instruction |
| `x ← y` | write value `y` to architectural state `x` |
| `x = y` | define temporary value `x` as `y` |
| `sxN(x)`, `zxN(x)` | sign-extend or zero-extend the N-bit value `x` to XLEN bits |
| `signedXLEN(x)` | interpret XLEN-bit value `x` as a signed two's-complement integer |
| `x >>> n` | arithmetic right shift of signed value `x` by `n` bits |
| `x[h:l]` | bit field |

Arithmetic register results wrap modulo `2^XLEN`.

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

The ISA does not require or prohibit modification of instruction memory. The
ordering and visibility of modifications to program memory with respect to
program-memory loads and instruction fetch are platform-defined unless an
extension defines synchronization. Programs that modify program memory must
use the applicable platform or extension synchronization mechanism before
depending on the modification through a program-memory load or instruction
fetch.

Data memory is little-endian. Effective data addresses use XLEN-bit addition
and wrap modulo `2^XLEN`.

When represented as bytes, instruction-memory halfwords are little-endian:
the low byte precedes the high byte. Program-memory load addresses are
instruction addresses and therefore select 16-bit halfwords. In RC16,
`PXLEN[a]` is `P16[a]`.

### 2.1 Memory Ordering and Atomicity

For each core, ordinary data-memory accesses have the same architectural effect
as if they were performed in program order. An implementation may buffer or
reorder accesses only when this is not observable by that core.

A byte access is an indivisible 8-bit access. An aligned halfword access is an
indivisible 16-bit access, and an aligned data-word access is an indivisible
XLEN-bit access. No agent may observe only part of an indivisible access.

Visibility and ordering between a core and other cores, devices, or DMA engines
are platform-defined. The base ISA does not define cache coherence, fences,
atomic read-modify-write operations, or memory-mapped device ordering and side
effects. A platform or extension may define them.

### 2.2 Alignment

`LDW`, `STW`, and `LDWX` require a two-byte-aligned effective address. The
effective address, rather than an individual base or displacement, determines
alignment. An unaligned access has undefined behavior; software must not depend
on whether an implementation traps, rounds the address, or performs another
action. Byte accesses have no alignment requirement.

## 3. Load and Store Instructions

This section defines the load and store encodings. Section 2 defines the data
and program address spaces, their ordering, and their alignment requirements.
Native-width data words, typed data bytes, and program-memory halfwords use
different instruction forms and are specified separately below.

### 3.1 Native-Width Data-Word Accesses

The compact immediate-offset format transfers one native XLEN-bit data word:

```text
01 ddd aaa iiiiiii S
```

`aaa` selects the base register `ra`; `S` selects load (`0`) or store (`1`).
The displacement is:

```text
simm = sx8({ i[7:1], 0 })
```

For `LDW`, `ddd` selects `rd`; for `STW`, it selects `rs`.

| `S` | instruction | operation |
|:---:|---|---|
| `0` | `LDW rd, [ra+simm]` | `R[d] ← MXLEN[R[a] + simm]` |
| `1` | `STW rs, [ra+simm]` | `MXLEN[R[a] + simm] ← R[s]` |

The omitted displacement is zero. `LDW` and `STW` must meet the data-word
alignment requirement in section 2.2.

An indexed native-width load uses the register format:

```text
11 ddd aaa 01_000 bbb
```

| `fffff` | instruction | operation |
|:---:|---|---|
| `01_000` | `LDWX rd, [ra+rb]` | `R[d] ← MXLEN[R[a] + R[b]]` |

Here `ddd`, `aaa`, and `bbb` select `rd`, `ra`, and `rb`. `LDWX` has the same
data-word alignment requirement as `LDW` and `STW`. There is no indexed
native-width store: a store uses the immediate-offset form above.

### 3.2 Direct Typed Access Encoding

Direct typed accesses use the register format:

```text
11 ddd aaa fffff bbb
```

`ddd` selects the load destination `rd` or store source `rs`; `aaa` selects
the address register `ra`. In this format, `bbb` is an access selector, not a
register:

```text
bbb = { ww, P }
```

`P=0` selects byte-addressed data memory and `P=1` selects halfword-addressed
program memory. RC16 uses `ww=00` for 8-bit accesses and `ww=01` for its
16-bit program-memory access. Other width/address-space combinations are
specified by the width extensions that define them.

The function field selects the operation class:

| `fffff` | operation class |
|:---:|---|
| `01_010` | direct zero-extending load |
| `01_011` | direct store |
| `01_110` | direct sign-extending load |

### 3.3 RC16 Typed Data-Byte Accesses

RC16 direct data accesses are byte accesses. They use the data selector
`bbb=000` (`ww=00`, `P=0`):

| `fffff` | `bbb` | instruction | operation |
|:---:|:---:|---|---|
| `01_010` | `000` | `LDB rd, [ra]` | `R[d] ← zx8(M8[R[a]])` |
| `01_011` | `000` | `STB rs, [ra]` | `M8[R[a]] ← R[s][7:0]` |
| `01_110` | `000` | `LDBS rd, [ra]` | `R[d] ← sx8(M8[R[a]])` |

`LDB` and `LDBS` zero- and sign-extend the addressed byte to XLEN bits.
`STB` writes the low byte of its source register. Byte data-memory accesses
have no alignment requirement.

### 3.4 RC16 Program-Memory Halfword Access

RC16 defines one direct program-memory access. It uses `bbb=011`
(`ww=01`, `P=1`):

| `fffff` | `bbb` | instruction | operation |
|:---:|:---:|---|---|
| `01_010` | `011` | `LDPH rd, [ra]` | `R[d] ← zx16(P16[R[a]])` |

`LDPH` reads the program-memory halfword at instruction address `ra`,
zero-extends it to XLEN bits, and does not modify `pc`. `LDP` is the
native-width program-memory-load alias; in RC16 it names `LDPH`.

Program-memory byte accesses and stores are not defined in RC16. The direct
store encodings `01_011` with `bbb=011` and `bbb=101` are retained as forward
allocations for `STPH` and `STPW`, respectively.

## 4. Immediate and Branch Instructions

### 4.1 Immediate Operations

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
| `001` | `LUI rd, imm8` | `R[d] ← zx8(imm8) << 8` |
| `010` | `ADDI rd, simm8` | `R[d] ← R[d] + sx8(simm8)` |
| `011` | `CMPI rs, simm8` | `R[0] ← R[s] - sx8(simm8)` |
| `100` | `ANDI rd, imm8` | `R[d] ← R[d] & zx8(imm8)` |
| `101` | `ORI rd, imm8` | `R[d] ← R[d] \| zx8(imm8)` |
| `110` | `XORI rd, imm8` | `R[d] ← R[d] ^ zx8(imm8)` |
| `111` | branch group | specified below |

`LDI` writes the zero-extended 8-bit immediate to `rd`.

`LUI` writes the 8-bit immediate into bits `[15:8]` of `rd` and clears every
other result bit.

`ADDI` adds a sign-extended immediate to the old value of `rd`.

`CMPI` subtracts its sign-extended immediate from `rs` and writes the result
to `r0`; it does not modify `rs`.

`ANDI`, `ORI`, and `XORI` perform bitwise AND, OR, and XOR, respectively,
between `rd` and a zero-extended immediate, then write the result to `rd`.

### 4.2 Branch Group

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

## 5. Register-Format Instructions

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
| `01_000` | indexed native-width load | section 3.1 |
| `01_010` | direct zero-extending load | section 3.2 |
| `01_011` | direct store | section 3.2 |
| `01_100` | `SRLI rd, ra, imm` | `R[d] ← R[a] >> (bbb + 1)` |
| `01_101` | `SRAI rd, ra, imm` | `R[d] ← signedXLEN(R[a]) >>> (bbb + 1)` |
| `01_110` | direct sign-extending load | section 3.2 |
| `01_111` | `SLLI rd, ra, imm` | `R[d] ← R[a] << (bbb + 1)` |
| `10_000` | `DIVU rr, rq, rb` | paired unsigned divide/remainder; Appendix B |
| `10_010` | `FSR1 rd, ra, rb` | `R[d] ← (R[a] >> 1) \| (R[b][0] << (XLEN-1))` |
| `10_011` | `FSL1 rd, ra, rb` | `R[d] ← (R[a] << 1) \| R[b][XLEN-1]` |
| `10_100` | `MULHU rl, rh, rb` | paired unsigned product; Appendix B |
| `11_111` | control and S-register group | section 6 |

All unlisted `fffff` values are reserved and undefined. The load and store
encodings in this table are specified in section 3.

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

`SLLI` and `SRLI` shift `ra` left and right, respectively, inserting zeros
into the vacated bits. Their shift count is `bbb+1`.

`SRAI` shifts `ra` right and copies the original sign bit into vacated high
bits. Its shift count is `bbb+1`.

`MUL` writes the low XLEN bits of the product of `ra` and `rb` to `rd`. This
low XLEN-bit portion is the same for signed and unsigned multiplication.

`SLLI`, `SRLI`, and `SRAI` encode shift counts from 1 through 8. In the
`min` profile, `SRLI` and `SRAI` always shift by one and their `bbb` field
must be zero; `SLLI` is undefined. `MUL` is available only in the `full`
profile.

## 6. Control Transfer and S-Register Instructions

Most control and S-register instructions have the following format:

```text
11 ddd aaa 11111 bbb
```

For `bbb = 000` and `bbb = 110`, `ddd` is a control selector. Only the
following control-selector values are defined:

| `bbb` | `ddd` | instruction | operation |
|---|---|---|---|
| `000` | `000` | `RET Sa` | `pc ← S[a]` |
| `000` | `111` | `RETI Sa` | `IE ← 1`; `pc ← S[a]` |
| `110` | `000` | `CLI` | `IE ← 0` |
| `110` | `111` | `STI` | `IE ← 1` |

All other `ddd` values in those two `bbb` rows are reserved and undefined.
`aaa` selects `Sa` for `RET` and `RETI`; `CLI` and `STI` require `aaa = 0`.

The remaining `bbb` values have the following definitions:

| `bbb` | instruction | operation |
|---|---|---|
| `001` | `JALR Sd, ra` | if `d != 0`, `S[d] ← pc_next`; `pc ← R[a]` |
| `010` | `MFS rd, Sa` | `R[d] ← S[a]` |
| `011` | `MTS Sd, ra` | `S[d] ← R[a]` |
| `100..101` | reserved | undefined |
| `111` | reserved | undefined |

`RET` transfers control through its S-register operand. It does not change
`IE`.

`RETI` transfers control through its S-register operand and sets `IE` to one.

`CLI` clears `IE`.

`STI` sets `IE` to one.

`JALR` transfers control through `ra` and, unless `Sd` is `S0`, writes the
instruction address of the following instruction to `Sd`. Thus,
`JALR S0, ra` is a register-indirect jump without a link write.

`MFS` copies the selected S-register to `rd`.

`MTS` copies `ra` to the selected S-register.

## 7. RC16 Long Call

A long instruction occupies two consecutive instruction halfwords and is one
architectural instruction. Interrupts are not taken between its halfwords.
There are no instructions longer than two halfwords.

The `sys` and `full` profiles define the following absolute long call:

```text
first halfword:  00 ddd 111 00000000
second halfword: aaaaaaaaaaaaaaaa
```

`ddd` selects the S-register link destination, and the second halfword is the
absolute instruction address `addr16`.

| instruction | operation |
|---|---|
| `JAL16 Sd, addr16` | if `d != 0`, `S[d] ← pc_next`; `pc ← addr16` |

`JMP16 addr16` is the alias `JAL16 S0, addr16`. `JAL16` and `JMP16` are absent
from `min`.

## 8. Interrupts

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

## 9. Profiles

`min`, `sys`, and `full` are ordered RC16 ISA subsets: a program using only a
smaller profile's defined instructions is valid on a larger profile.

### 9.1 Instruction Availability

| instruction | `min` | `sys` | `full` |
|---|:---:|:---:|:---:|
| `LDW rd, [ra+simm]` | X | X | X |
| `STW rs, [ra+simm]` | X | X | X |
| `LDWX rd, [ra+rb]` | X | X | X |
| `LDB rd, [ra]` | X | X | X |
| `LDBS rd, [ra]` | X | X | X |
| `STB rs, [ra]` | X | X | X |
| `LDPH rd, [ra]` (`LDP`) | X | X | X |
| `LDI rd, imm8` | X | X | X |
| `LUI rd, imm8` | X | X | X |
| `ADDI rd, simm8` | X | X | X |
| `CMPI rs, simm8` | X | X | X |
| `ANDI rd, imm8` | X | X | X |
| `ORI rd, imm8` | X | X | X |
| `XORI rd, imm8` | X | X | X |
| `BEQZ rel8` | X | X | X |
| `BNEZ rel8` | X | X | X |
| `BLTZ rel8` | X | X | X |
| `BGEZ rel8` | X | X | X |
| `JMP8 rel8` | X | X | X |
| `JAL16 Sd, addr16` |  | X | X |
| `ADD rd, ra, rb` | X | X | X |
| `SUB rd, ra, rb` | X | X | X |
| `SLT rd, ra, rb` | X | X | X |
| `SLTU rd, ra, rb` | X | X | X |
| `AND rd, ra, rb` | X | X | X |
| `OR rd, ra, rb` | X | X | X |
| `XOR rd, ra, rb` | X | X | X |
| `FSL1 rd, ra, rb` | X | X | X |
| `FSR1 rd, ra, rb` | X | X | X |
| `SLLI rd, ra, 1..8` |  | X | X |
| `SRLI rd, ra, 1` | X | X | X |
| `SRLI rd, ra, 2..8` |  | X | X |
| `SRAI rd, ra, 1` | X | X | X |
| `SRAI rd, ra, 2..8` |  | X | X |
| `MUL rd, ra, rb` |  |  | X |
| `MULHU rl, rh, rb` § |  |  |  |
| `DIVU rr, rq, rb` § |  |  |  |
| `RET Sa` | X | X | X |
| `JALR Sd, ra` | X | X | X |
| `MFS rd, Sa` | X | X | X |
| `MTS Sd, ra` | X | X | X |
| `RETI Sa` |  | X | X |
| `CLI` |  | X | X |
| `STI` |  | X | X |



§ `MULHU` and `DIVU` are optional Appendix B instructions; neither is required
by any profile.

# Appendices

## Appendix A. Nano Profile

Nano is a separate reduced RC16 variant rather than a mainline profile. It does
not combine with the extensions in Appendices B, C, or D.

### A.1 Architectural State

Nano has only `r0..r7` and `pc` as architectural state. It has no S-register
bank, `IE`, `EPC`, or interrupt entry. Instruction and data addressing, byte
order, alignment, and the memory model are otherwise the same as for mainline
RC16.

### A.2 Instruction Availability

Nano defines only the following compact instructions:

| class | instructions |
|---|---|
| memory | `LDW`, `STW`, `LDWX`, `LDB`, `STB` |
| immediate | `LDI`, `LUI`, `ADDI`, `ANDI`, `ORI`, `XORI` |
| branch | `BEQZ`, `BNEZ`, `BLTZ`, `BGEZ`, `JMP8` |
| register | `ADD`, `SUB`, `SLTU`, `AND`, `OR`, `XOR` |
| shift | `SRLI rd, ra, 1`, `SRAI rd, ra, 1` |
| indirect control | `JALR rd, ra` |

These instructions use their base RC16 encodings and semantics except for
`JALR`, as specified below. All other instruction encodings, including every
long-instruction encoding, are undefined in Nano.

### A.3 Register-Indirect Control Transfer

Nano redefines the base register-indirect `JALR` encoding as `JALR rd, ra`. It
writes `pc_next` to general register `rd` and transfers control through `R[a]`.
With `rd = r0`, no link is written; this is a plain register jump. Assemblers
may spell these forms as `CALL rd, ra` and `JMP ra`, respectively.

## Appendix B. Multiply-Divide Instructions Extension

This optional extension may be combined with RC16 or RC32. When the optional
X32 extension is implemented with RC32, Appendix D supplies long forms with
five-bit operand selectors. It is required by no profile and has no Nano form.

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

## Appendix C. RC32 Width Extension

RC32 is an optional target configuration that extends the compact RC16 base ISA.
It sets `XLEN = 32`. An implementation selects RC16 or RC32 as an architectural
configuration; RC32 is not enabled or disabled at run time.

RC32 changes register and data width; it does not add registers or widen the
three-bit register selectors in compact instructions. The separately optional
X32 extension in Appendix D adds a five-bit, 32-selector operand namespace and
its associated long formats. Thus an RC32 compact instruction still selects
only `r0..r7` or `S0..S7`, but each selected register holds a 32-bit value.

Unless this appendix specifies otherwise, RC32 retains the compact instruction
encodings, semantics, and profile availability of RC16, with every
`XLEN`-dependent register, address, result, and memory data word widened to 32
bits. RC16 and RC32 binaries are not generally interchangeable: data-word
width, compact word displacement decoding, and defined long instructions differ.

### C.1 Architectural Width and Addressing

In RC32, `r0..r7`, `S0..S7`, and `pc` are 32 bits wide. Register and program
counter writes retain their low 32 bits, and arithmetic results and effective
addresses wrap modulo `2^32`. Link addresses, interrupt return addresses, and
`interrupt_vector` are 32-bit instruction addresses. X32 is not needed to
select or operate on these 32-bit compact-register values.

A 32-bit instruction address selects one of `2^32` instruction-memory
halfwords. A 32-bit data address selects one of `2^32` data-memory bytes. The
separate instruction and data address spaces and their addressing conventions
are otherwise unchanged.

Compact instructions retain their immediate widths and field positions. Their
sign and zero extension is to 32 bits, and signed operations use bit 31 as the
sign bit. Compact `LUI` writes its immediate to bits `[15:8]` and clears all
other result bits, including bits `[31:16]`.

### C.2 RC32 Memory Access

In RC32, `MXLEN[a]` is the 32-bit data word `M32[a]`. `LDW`, `STW`, and `LDWX`
therefore transfer 32 bits. They require a four-byte-aligned effective address.
An unaligned access has undefined behavior unless another architectural
extension defines it. An aligned 32-bit data-word access has the atomicity
specified in section 2.1.

In RC32, `PXLEN[a]` is assembled from two consecutive program-memory
halfwords:

```text
PXLEN[a][15:0]  = P16[a]
PXLEN[a][31:16] = P16[a + 1]
```

The compact `LDW` and `STW` format is unchanged, but its displacement is:

```text
simm = sx9({ i[1], i[7:2], 0, 0 })
```

RC32 defines the following direct typed instructions in the compact memory
families from section 3.2:

| `fffff` | `bbb` | instruction | operation |
|:---:|:---:|---|---|
| `01_010` | `010` | `LDH rd, [ra]` | `R[d] ← zx16(M16[R[a]])` |
| `01_010` | `101` | `LDPW rd, [ra]` | `R[d] ← PXLEN[R[a]]` |
| `01_011` | `010` | `STH rs, [ra]` | `M16[R[a]] ← R[s][15:0]` |
| `01_110` | `010` | `LDHS rd, [ra]` | `R[d] ← sx16(M16[R[a]])` |
| `01_110` | `011` | `LDPHS rd, [ra]` | `R[d] ← sx16(P16[R[a]])` |

`LDH`, `LDHS`, and `STH` require a two-byte-aligned data address. The compact
`LDPH` inherited from RC16 and the optional `LDPHS` access one program-memory
halfword and have no additional alignment requirement. `LDPW` is a 32-bit word
access and follows the normal word-alignment rule: its effective instruction
address must be even. An unaligned access has undefined behavior unless another
architectural extension defines it.

`LDP` is the native-width alias for `LDPW` in RC32. `LDPHS` and `LDPW` are
optional and are required by no RC32 profile; compact `LDPH` remains mandatory
through the inherited mainline profile. The data-memory
`bbb=100` forms remain undefined because native 32-bit access already uses
`LDW` or `STW` with a zero displacement. The direct program-store encodings
`bbb=011` and `bbb=101` remain the forward allocations for `STPH` and `STPW`;
all other program-memory stores and all 64-bit width encodings remain reserved.
RC32 byte loads extend their result to 32 bits.

### C.3 RC32 Long Instructions

The long-instruction length and interrupt rules in section 7 apply. `JAL16` and
`JMP16` are not defined in RC32.

The long instructions in this section are part of RC32 itself and use only the
compact `r` and S-register selectors shown in their formats. They do not
require X32. Appendix D adds separate long formats whose five-bit selectors can
also name the X32 extension registers.

RC32 defines the following U20 format:

```text
first halfword:  00 ddd hhh 00 h p 0100
second halfword: llllllllllllllll
```

`ddd` selects `rd`. The four `h` bits and sixteen `l` bits form `imm20`:

```text
imm20 = { hhhh, llllllllllllllll }
```

| `p` | instruction | operation |
|:---:|---|---|
| `0` | `LUIL rd, imm20` | `R[d] ← imm20 << 12` |
| `1` | reserved | undefined; Appendix D |

RC32 also defines the following I12 format:

```text
first halfword:  00 ddd aaa 00 00 1100
second halfword: ffff iiiiiiiiiiii
```

`ddd` selects `rd`, `aaa` selects `ra`, and the twelve `i` bits form `imm12`.

| `ffff` | instruction | operation |
|:---:|---|---|
| `0000` | `ADDI rd, ra, simm12` | `R[d] ← R[a] + sx12(imm12)` |
| `0001..1111` | reserved | undefined; Appendix D |

RC32 also defines the following relative long call:

```text
first halfword:  00 ddd hhh hhhh 1011
second halfword: llllllllllllllll
```

`ddd` selects the S-register link destination. The seven `h` bits and sixteen
`l` bits form the signed instruction-address displacement:

```text
rel23 = { hhhhhhh, llllllllllllllll }
```

| instruction | operation |
|---|---|
| `JAL Sd, rel23` | if `d != 0`, `S[d] ← pc_next`; `pc ← pc_next + sx23(rel23)` |

The addition wraps modulo `2^32`. Because instruction addresses select 16-bit
halfwords, `rel23` has a signed 24-bit effective byte reach. `JAL S0, rel23`
suppresses the link write and is the direct relative jump form.

### C.4 RC32 Profiles

RC32 defines `min`, `sys`, and `full` profiles corresponding to the RC16
mainline profiles. Each inherits the compact instruction availability of its
RC16 counterpart. The RC16 long instructions `JAL16` and `JMP16` remain
undefined as specified in section C.3. RC32 has no Nano profile.

The following instructions are mandatory in every RC32 mainline profile:

| instruction | `min` | `sys` | `full` |
|---|:---:|:---:|:---:|
| `LDH rd, [ra]` | X | X | X |
| `LDHS rd, [ra]` | X | X | X |
| `STH rs, [ra]` | X | X | X |
| `LUIL rd, imm20` | X | X | X |
| `ADDI rd, ra, simm12` | X | X | X |
| `JAL Sd, rel23` | X | X | X |

Compact shift-count availability remains unchanged: only the encodings from 1
through 8 exist, subject to the selected profile. Appendix D defines the
optional X32 register extension for RC32.

## Appendix D. X32 Register Extension

X32 is an optional RC32-only register-namespace and long-instruction
extension. It does not change `XLEN`: its registers are 32 bits wide because
it requires RC32. RC32 itself retains only the compact `r0..r7` and `S0..S7`
register names; X32 adds the following architectural state:

| state | width | description |
|---|---:|---|
| `x0..x15` | XLEN | X32-extension registers |

X32 supplies a 32-selector operand namespace: the existing eight `r`
registers, the existing eight S-registers, and sixteen new `x` registers. It
retains the existing `r` and S-register names and their architectural roles. A
five-bit X32 register selector has the following mapping:

| selector | register |
|---|---|
| `00_000..00_111` | `r0..r7` |
| `01_000..01_111` | `S0..S7` |
| `10_000..11_111` | `x0..x15` |

This appendix writes an X32-selected register as `X[x]`. The special treatment
of `S0` as interrupt EPC and as a no-link destination is unchanged.

### D.1 Long Instruction Encoding

Every X32 instruction occupies exactly two consecutive instruction halfwords
and is one architectural instruction. Interrupts are not taken between its
halfwords. There are no instructions longer than two halfwords.

Except for the register format in section D.2, an X32 long instruction has its
register selectors and opcode in the first halfword:

```text
first halfword:  00 ddd aaa DD AA oooo
```

`DD` and `AA` extend `ddd` and `aaa` to five-bit register selectors when those
operands are present. `oooo` is the primary long opcode. The U20, I12, and
conditional-branch formats use their own secondary operation fields.

| `oooo` | instruction or format |
|:---:|---|
| `0000` | register format; section D.2 |
| `0001..0011` | reserved |
| `0100` | U20 format; section D.3 |
| `0101` | integer load |
| `0110` | integer store |
| `0111` | sign-extending integer load |
| `1000` | conditional branch; section D.6 |
| `1001..1010` | reserved |
| `1011` | `JAL`; Appendix C |
| `1100` | I12 format; section D.4 |
| `1101..1111` | reserved |

The second halfword contains the low 16 bits of `imm20` for U20 instructions,
`{ ffff, imm12 }` for I12 instructions, the tagged displacement `t16` for
memory instructions, `{ cccc, rel12 }` for conditional branches, or the low 16
bits of the `JAL` displacement. Long register instructions instead use the layout in
section D.2 so that their function and low register fields retain the compact
register-format positions.

Control-transfer and interrupt-control instructions retain their compact
S-register forms. `JAL16` and `JMP16` are RC16-only instructions and are not
part of X32.

### D.2 Long Register Instructions

A long register instruction has:

```text
first halfword:  00 ddd aaa 00000000
second halfword: DD AA BB ww fffff bbb
```

It selects:

```text
xd = { DD, ddd }
xa = { AA, aaa }
xb = { BB, bbb }
```

The zero low byte of the first halfword selects the register format. In the
second halfword, `fffff` and `bbb` occupy the same positions as in a compact
register instruction. For typed indexed data-memory loads, `ww` selects the
access width using the width codes from section 3.2. All other register
instructions require `ww=00`. Stores use the long displacement format in
section D.5, avoiding three-register-input long store operations.

| `ww` | `fffff` | instruction | operation |
|:---:|:---:|---|---|
| `00` | `00_000` | `ADD Xd, Xa, Xb` | `X[xd] ← X[xa] + X[xb]` |
| `00` | `00_001` | `SUB Xd, Xa, Xb` | `X[xd] ← X[xa] - X[xb]` |
| `00` | `00_010` | `SLT Xd, Xa, Xb` | `X[xd] ← (signedXLEN(X[xa]) < signedXLEN(X[xb])) ? 1 : 0` |
| `00` | `00_011` | `SLTU Xd, Xa, Xb` | `X[xd] ← (X[xa] < X[xb]) ? 1 : 0` |
| `00` | `00_100` | `AND Xd, Xa, Xb` | `X[xd] ← X[xa] & X[xb]` |
| `00` | `00_101` | `OR Xd, Xa, Xb` | `X[xd] ← X[xa] \| X[xb]` |
| `00` | `00_110` | `XOR Xd, Xa, Xb` | `X[xd] ← X[xa] ^ X[xb]` |
| `00` | `00_111` | `MUL Xd, Xa, Xb` | `X[xd] ← (X[xa] * X[xb])[31:0]` |
| `00` | `01_000` | `LDWX Xd, [Xa+Xb]` | `X[xd] ← M32[X[xa] + X[xb]]` |
| `00` | `01_010` | `LDB Xd, [Xa+Xb]` | `X[xd] ← zx8(M8[X[xa] + X[xb]])` |
| `01` | `01_010` | `LDH Xd, [Xa+Xb]` | `X[xd] ← zx16(M16[X[xa] + X[xb]])` |
| `00` | `01_100` | `SRLI Xd, Xa, 1..32` | `X[xd] ← X[xa] >> (xb + 1)` |
| `00` | `01_101` | `SRAI Xd, Xa, 1..32` | `X[xd] ← signedXLEN(X[xa]) >>> (xb + 1)` |
| `00` | `01_110` | `LDBS Xd, [Xa+Xb]` | `X[xd] ← sx8(M8[X[xa] + X[xb]])` |
| `01` | `01_110` | `LDHS Xd, [Xa+Xb]` | `X[xd] ← sx16(M16[X[xa] + X[xb]])` |
| `00` | `01_111` | `SLLI Xd, Xa, 1..32` | `X[xd] ← X[xa] << (xb + 1)` |
| `00` | `10_000` | `DIVU Xr, Xq, Xb` § | paired unsigned divide/remainder; Appendix B |
| `00` | `10_010` | `FSR1 Xd, Xa, Xb` | `X[xd] ← (X[xa] >> 1) \| (X[xb][0] << 31)` |
| `00` | `10_011` | `FSL1 Xd, Xa, Xb` | `X[xd] ← (X[xa] << 1) \| X[xb][31]` |
| `00` | `10_100` | `MULHU Xl, Xh, Xb` § | paired unsigned product; Appendix B |

All unlisted `ww` and `fffff` combinations are reserved and undefined. The
indexed integer loads are available in every X32 profile. `ww=11` is reserved
for 64-bit memory operations in a future XLEN=64 extension; that extension may
also define `ww=10` zero- and sign-extending 32-bit indexed loads. Floating-
point memory operations are not defined by X32.

The arithmetic and shift encodings use the same selected-profile availability
as their compact counterparts. The five-bit `MULHU` and `DIVU` forms are
defined only when Appendix B is implemented and retain its operand
restrictions.

For `SLLI`, `SRLI`, and `SRAI`, `xb` is an unsigned five-bit shift-count
encoding rather than a register selector; the shift count is `xb + 1`, from
one through 32. X32 `min` permits only the existing one-bit `SRLI` and `SRAI`
forms, while X32 `sys` and `full` permit the full range and `SLLI`.

### D.3 U20 Instructions

The X32 U20 format is:

```text
first halfword:  00 ddd hhh DD h p 0100
second halfword: llllllllllllllll
```

It selects `xd = { DD, ddd }` and forms
`imm20 = { hhhh, llllllllllllllll }`.

| `p` | instruction | operation |
|:---:|---|---|
| `0` | `LUIL Xd, imm20` | `X[xd] ← imm20 << 12` |
| `1` | `AUIPC Xd, imm20` | `X[xd] ← pc + (imm20 << 12)` |

Appendix C defines `p=0` with `DD=00`. X32 permits `DD` to be nonzero and
defines `p=1` as `AUIPC`.

### D.4 I12 Instructions

The X32 I12 format is:

```text
first halfword:  00 ddd aaa DD AA 1100
second halfword: ffff iiiiiiiiiiii
```

It selects `xd = { DD, ddd }` and `xa = { AA, aaa }`. For `JALR`, `ddd`
selects the S-register link destination, `DD` must be zero, and
`xa = { AA, aaa }`; its link destination therefore remains in the S-register
bank. The twelve `i` bits form `imm12`.

| `ffff` | instruction | operation |
|:---:|---|---|
| `0000` | `ADDI Xd, Xa, simm12` | `X[xd] ← X[xa] + sx12(imm12)` |
| `0001` | `JALR Sd, [Xa+simm12]` | if `d != 0`, `S[d] ← pc_next`; `pc ← X[xa] + sx12(imm12)` |
| `0010` | `SLTI Xd, Xa, simm12` | `X[xd] ← (signedXLEN(X[xa]) < signedXLEN(sx12(imm12))) ? 1 : 0` |
| `0011` | `SLTIU Xd, Xa, simm12` | `X[xd] ← (X[xa] < sx12(imm12)) ? 1 : 0` |
| `0100` | `XORI Xd, Xa, simm12` | `X[xd] ← X[xa] ^ sx12(imm12)` |
| `0101` | `LDP Xd, [Xa+simm12]` | `X[xd] ← PXLEN[X[xa] + sx12(imm12)]` |
| `0110` | `ORI Xd, Xa, simm12` | `X[xd] ← X[xa] \| sx12(imm12)` |
| `0111` | `ANDI Xd, Xa, simm12` | `X[xd] ← X[xa] & sx12(imm12)` |
| `1000..1111` | reserved | undefined |

`SLTIU` compares both operands as unsigned after sign-extending `imm12`.
`JALR S0, [Xa+simm12]` suppresses the link write. The `LDP` effective address
is an instruction address and is subject to the RC32 alignment requirement in
section C.2. Appendix C defines only `ffff=0000` with `DD=AA=00`; X32 widens
that `ADDI` form and defines the additional non-reserved instructions in this
table.

### D.5 Long Memory Instructions

A long memory instruction has:

```text
first halfword:  00 ddd aaa DD AA oooo
second halfword: tttttttttttttttt
```

It selects `xd = { DD, ddd }` and `xa = { AA, aaa }`. `oooo` directly selects
zero-extending or native-width load, store, or sign-extending load. The second
halfword is the tagged displacement field `t16`.

The least-significant end of `t16` selects the access width and determines the
signed effective displacement:

| `t16` form | access width | effective displacement |
|---|---|---|
| `{ disp15, 0 }` | byte | `sx15(disp15)` |
| `{ disp14, 01 }` | halfword | `sx15({ disp14, 0 })` |
| `{ disp13, 011 }` | data word | `sx15({ disp13, 00 })` |
| `{ disp12, 0111 }` | doubleword | `sx15({ disp12, 000 })` |
| ending in `1111` | reserved | undefined |

`disp15`, `disp14`, `disp13`, and `disp12` are signed displacement fields of
the indicated widths. The upper 15 bits of `t16` have fixed connections to the
low 15 displacement inputs of the address adder. Depending on the access width,
the width decode leaves those inputs unchanged or forces the lowest one, two,
or three inputs to zero. It does not shift the displacement field.

| `oooo` | `t16` ending | instruction | operation |
|:---:|:---:|---|---|
| `0101` | `0` | `LDB Xd, [Xa+simm]` | `X[xd] ← zx8(M8[X[xa] + simm])` |
| `0111` | `0` | `LDBS Xd, [Xa+simm]` | `X[xd] ← sx8(M8[X[xa] + simm])` |
| `0110` | `0` | `STB Xd, [Xa+simm]` | `M8[X[xa] + simm] ← X[xd][7:0]` |
| `0101` | `01` | `LDH Xd, [Xa+simm]` | `X[xd] ← zx16(M16[X[xa] + simm])` |
| `0111` | `01` | `LDHS Xd, [Xa+simm]` | `X[xd] ← sx16(M16[X[xa] + simm])` |
| `0110` | `01` | `STH Xd, [Xa+simm]` | `M16[X[xa] + simm] ← X[xd][15:0]` |
| `0101` | `011` | `LDW Xd, [Xa+simm]` | `X[xd] ← M32[X[xa] + simm]` |
| `0110` | `011` | `STW Xd, [Xa+simm]` | `M32[X[xa] + simm] ← X[xd]` |

The doubleword forms are reserved in RC32. A future XLEN=64 extension may
define native-width `LDD` and `STD`; it may also define a sign-extending word
load. A sign-extending doubleword load is not allocated. The normal
effective-address alignment requirements from Appendix C continue to apply.

### D.6 Long Conditional Branch Instructions

A long conditional branch has:

```text
first halfword:  00 ddd aaa DD AA 1000
second halfword: cccc rrrrrrrrrrrr
```

It selects `xd = { DD, ddd }` and `xa = { AA, aaa }`. `cccc` selects the
condition. The twelve `r` bits are the signed `rel12` displacement in
instruction addresses:

```text
pc_target = pc_next + sx12(rel12)
```

| `cccc` | instruction | operation |
|:---:|---|---|
| `0000` | `BEQ Xd, Xa, rel12` | branch when `X[xd] == X[xa]` |
| `0001` | `BNE Xd, Xa, rel12` | branch when `X[xd] != X[xa]` |
| `0010` | `BLT Xd, Xa, rel12` | branch when `signedXLEN(X[xd]) < signedXLEN(X[xa])` |
| `0011` | `BGE Xd, Xa, rel12` | branch when `signedXLEN(X[xd]) >= signedXLEN(X[xa])` |
| `0100` | `BLTU Xd, Xa, rel12` | branch when `X[xd] < X[xa]` |
| `0101` | `BGEU Xd, Xa, rel12` | branch when `X[xd] >= X[xa]` |
| `0110..1111` | reserved | undefined |

Because instruction addresses select 16-bit halfwords, `rel12` has a signed
13-bit effective byte reach. A taken conditional branch writes `pc_target` to
`pc`; an untaken conditional branch writes `pc_next` to `pc`.

### D.7 Extension Composition

X32 may be combined with any RC32 mainline profile. The selected profile
continues to control availability of base operations in the long register
format. X32 adds five-bit-selector forms of the mandatory RC32 `LUIL` and
`ADDI` instructions and supplies the additional U20 and I12 operations in
sections D.3 and D.4. The long memory operations and conditional branches are
also supplied by X32 itself in every X32 mainline profile. The extension has no
Nano form and does not apply to RC16.

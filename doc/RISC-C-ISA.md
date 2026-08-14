# RISC-C Instruction Set Architecture

RISC-C is an open ISA for compact systems that need a compact controller.

This document is the RISC-C ISA specification. It defines the architectural
state, instruction encodings and semantics, memory-access rules, interrupt
behavior, and profile extensions.

The RISC-C specification and reference implementations are released under
the ISC License and may be used, copied, modified, and distributed for any
purpose, with or without fee.

Version: `v0.21.0`.

Author: Arto Vuori <avuori@iki.fi>

## 1. RC16 Base Integer Instruction Set

This chapter describes the compact RC16 base integer ISA. RC16 has `XLEN = 16`.
The `min` profile defines the base instruction set; section 9 summarizes the
profile differences.

Most base instructions use one 16-bit instruction halfword. Some profiles and
extensions define two-halfword instructions. Architectural addresses are byte
addresses; instructions are two-byte aligned. Unless a rule names a narrower
access or field explicitly, an
operation on a register, an S-register, or a data word is `XLEN` bits wide.

The mainline ISA provides the ordered `min`, `sys`, and `full` profiles.
Appendix A defines the Nano variant, and Appendix C defines the optional RC32
width extension.

### 1.1 Architectural State

| state | width | description |
|---|---:|---|
| `r0..r7` | XLEN | general-purpose registers |
| `S0..S7` | XLEN | S registers |
| `pc` | XLEN | byte-addressed program counter |
| `IE` | 1 | interrupt-enable bit (`sys` profile) |

There are no arithmetic condition codes and no architectural zero register.
The RC32X conditional-branch format alone treats its `Xd=r0` selector as a
literal zero source; that encoding rule does not alter `r0` storage or its
meaning for any other instruction.
All `r`- and S-register writes retain their low XLEN bits. Program-counter
updates retain their low XLEN bits.

`r0` has no special storage behavior. All short conditional branches test
`r0`, and `CMPI` always writes its result to `r0`.

`MFS` and `MTS` read and write `S0..S7` as XLEN-bit storage. `JALR` uses an
S-register destination for its link, and `RET` uses an S-register operand for
its return address. The `sys` profile additionally provides `RETI`, `CLI`,
and `STI`. Only `S0` has special
architectural treatment:

- In `JALR`, destination `S0` suppresses the link write.
- In the `sys` profile, `S0` is `EPC`, the interrupt return program
  counter.

Except for the roles of `S0` defined above, S-register use is unrestricted.
Interrupt entry overwrites `S0`.

`IE` is initialized to zero by reset. Reset `pc` is platform-defined;
general-register and S-register values are unspecified following reset.

Unless an instruction explicitly assigns `pc`, execution continues at
`pc_next`.

The PC, links, function pointers, object pointers, S-register values, and
general-register values are all XLEN bits wide. Every architectural address in
one of these objects uses the same byte-addressed representation.

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

Unless explicitly defined otherwise, unused instruction fields must be zero.
Encodings with nonzero unused fields, reserved encodings, instructions absent
from the selected profile or extension set, and all other invalid encodings
are undefined.

### 1.3 Notation and Conventions

| symbol | meaning |
|---|---|
| `R[x]`, `S[x]` | general register or S-register `x` |
| `MXLEN[a]` | XLEN-bit native word at byte address `a` |
| `M32[a]`, `M16[a]`, `M8[a]` | 32-bit word, 16-bit halfword, or 8-bit byte at byte address `a` |
| `pc_next` | byte address immediately following the current instruction |
| `x ← y` | write value `y` to architectural state `x` |
| `x = y` | define temporary value `x` as `y` |
| `sxN(x)`, `zxN(x)` | sign-extend or zero-extend the N-bit value `x` to XLEN bits |
| `signedXLEN(x)` | interpret XLEN-bit value `x` as a signed two's-complement integer |
| `unsignedXLEN(x)` | interpret XLEN-bit value `x` as an unsigned integer |
| `x << n`, `x >> n` | logical left or logical right shift of the XLEN-bit value `x` by `n` bits |
| `x >>> n` | arithmetic right shift of signed value `x` by `n` bits |
| `x[h:l]` | bit field |

Comparison operators applied directly to XLEN-bit values use unsigned
interpretation. Unless an instruction masks the count before shifting, a
logical shift by `n >= XLEN` produces zero and an arithmetic right shift by
`n >= XLEN` produces XLEN copies of the original sign bit.

Arithmetic register results wrap modulo `2^XLEN`.

## 2. Address Spaces and Memory Access

RISC-C has one architectural byte address space for instructions and data.
The PC, control-flow targets, links, function pointers, object pointers, and
all load/store effective addresses use the same representation. RC16 has a
64 KiB architectural address space and RC32 has a 4 GiB architectural address
space.

Memory is little-endian. Effective addresses and PC-relative address
calculations use XLEN-bit addition and wrap modulo `2^XLEN`. Instruction fetch
reads `M16[pc]`; an instruction target must be two-byte aligned.

Whether a region is executable, readable, or writable is platform-defined.
When stores modify executable memory, their ordering and visibility to
instruction fetch are platform-defined unless an extension defines
synchronization.

### 2.1 Memory Ordering and Atomicity

For each core, ordinary memory accesses are observed in program order.

A byte access is an indivisible 8-bit access. An aligned halfword access is an
indivisible 16-bit access, and an aligned data-word access is an indivisible
XLEN-bit access. No agent may observe only part of an indivisible access.

Visibility and ordering between a core and other cores, devices, or DMA engines
are platform-defined. The base ISA does not define cache coherence, fences,
atomic read-modify-write operations, or memory-mapped device ordering and side
effects. A platform or extension may define them.

### 2.2 Alignment

`LD`, `ST`, and `LDX` require a two-byte-aligned effective address in RC16 and
a four-byte-aligned effective address in RC32. RC32 `LDPC` has the same
four-byte alignment requirement. The effective address, rather than an
individual base or displacement, determines alignment. Unaligned accesses are
undefined. Byte accesses have no alignment requirement.

## 3. Load and Store Instructions

This section defines the load and store encodings. Section 2 defines the
unified address space, ordering, and alignment requirements.

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

For `LD`, `ddd` selects `rd`; for `ST`, it selects `rs`.

| `S` | instruction | operation |
|:---:|---|---|
| `0` | `LD rd, [ra+simm]` | `R[d] ← MXLEN[R[a] + simm]` |
| `1` | `ST rs, [ra+simm]` | `MXLEN[R[a] + simm] ← R[s]` |

The omitted displacement is zero. `LD` and `ST` must meet the data-word
alignment requirement in section 2.2.

An indexed native-width load uses the register format:

```text
11 ddd aaa 01_000 bbb
```

| `fffff` | instruction | operation |
|:---:|---|---|
| `01000` | `LDX rd, [ra+rb]` | `R[d] ← MXLEN[R[a] + R[b]]` |

Here `ddd`, `aaa`, and `bbb` select `rd`, `ra`, and `rb`. `LDX` has the same
data-word alignment requirement as `LD` and `ST`. There is no indexed
native-width store: a store uses the immediate-offset form above.

### 3.2 Direct Typed Access Encoding

Direct typed accesses use the register format:

```text
11 ddd aaa fffff bbb
```

`ddd` selects the load destination `rd` or store source `rs`; `aaa` selects
the address register `ra`. In this format, `bbb` is an access-width selector,
not a register. RC16 defines `bbb=000` for bytes. RC32 additionally defines
`bbb=010` for halfwords; other selectors are reserved for wider extensions.

The function field selects the operation class:

| `fffff` | operation class |
|:---:|---|
| `01010` | direct zero-extending load |
| `01011` | direct store |
| `01110` | direct sign-extending load |

### 3.3 RC16 Typed Data-Byte Accesses

RC16 direct typed accesses are byte accesses and use `bbb=000`:

| `fffff` | `bbb` | instruction | operation |
|:---:|:---:|---|---|
| `01010` | `000` | `LDB rd, [ra]` | `R[d] ← zx8(M8[R[a]])` |
| `01011` | `000` | `STB rs, [ra]` | `M8[R[a]] ← R[s][7:0]` |
| `01110` | `000` | `LDBS rd, [ra]` | `R[d] ← sx8(M8[R[a]])` |

`LDB` and `LDBS` zero- and sign-extend the addressed byte to XLEN bits.
`STB` writes the low byte of its source register. Byte memory accesses
have no alignment requirement.

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

`LUI` writes the immediate into bits `[15:8]` and clears bits `[7:0]`.

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

The eight encoded bits hold a rotated signed instruction-halfword
displacement `rel8`, relative to the next instruction:

```text
encoded r[7:1] = rel8[6:0]
encoded r[0]   = rel8[7]
pc_target = pc_next + sx9({ r[0], r[7:1], 0 })
```

The byte reach is therefore -256 through +254 from `pc_next`, in steps of
two bytes.

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
| `00000` | `ADD rd, ra, rb` | `R[d] ← R[a] + R[b]` |
| `00001` | `SUB rd, ra, rb` | `R[d] ← R[a] - R[b]` |
| `00010` | `SLT rd, ra, rb` | `R[d] ← (signedXLEN(R[a]) < signedXLEN(R[b])) ? 1 : 0` |
| `00011` | `SLTU rd, ra, rb` | `R[d] ← (unsignedXLEN(R[a]) < unsignedXLEN(R[b])) ? 1 : 0` |
| `00100` | `AND rd, ra, rb` | `R[d] ← R[a] & R[b]` |
| `00101` | `OR rd, ra, rb` | `R[d] ← R[a] \| R[b]` |
| `00110` | `XOR rd, ra, rb` | `R[d] ← R[a] ^ R[b]` |
| `00111` | `MUL rd, ra, rb` | `R[d] ← (R[a] * R[b])[XLEN-1:0]` |
| `01000` | indexed native-width load | section 3.1 |
| `01010` | direct zero-extending load | section 3.2 |
| `01011` | direct store | section 3.2 |
| `01100` | `SRLI rd, ra, imm` | `R[d] ← R[a] >> (bbb + 1)` |
| `01101` | `SRAI rd, ra, imm` | `R[d] ← signedXLEN(R[a]) >>> (bbb + 1)` |
| `01110` | direct sign-extending load | section 3.2 |
| `01111` | `SLLI rd, ra, imm` | `R[d] ← R[a] << (bbb + 1)` |
| `10000` | `DIVU rr, rq, rb` | paired unsigned divide/remainder; Appendix B |
| `10001` | two-operand group | section 5.1 |
| `10100` | `MULHU rl, rh, rb` | paired unsigned product; Appendix B |
| `11111` | control and S-register group | section 6 |

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

### 5.1 Two-Operand Group

The compact two-operand format is:

```text
11 ddd aaa 10_001 ooo
```

`ddd` selects the read/write register `rd`, `aaa` selects the source register
`ra`, and `ooo = { A, V, R }` selects the operation. `A` selects arithmetic
shifting, `V` selects a variable shift rather than a funnel shift, and `R`
selects right rather than left:

| `ooo` | instruction | operation |
|:---:|---|---|
| `000` | `FSL1 rd, ra` | `R[d] ← (R[d] << 1) \| R[a][XLEN-1]` |
| `001` | `FSR1 rd, ra` | `R[d] ← (R[d] >> 1) \| (R[a][0] << (XLEN-1))` |
| `010` | `SLL rd, ra` | variable logical-left shift; Appendix E |
| `011` | `SRL rd, ra` | variable logical-right shift; Appendix E |
| `100..110` | reserved | undefined |
| `111` | `SRA rd, ra` | variable arithmetic-right shift; Appendix E |

`FSL1` and `FSR1` shift `rd` by one bit and insert one endpoint bit from `ra`.
Both operands are read before `rd` is written, including when `rd` and `ra`
name the same register. The `SLL`, `SRL`, and `SRA` encodings are defined only
when the optional extension in Appendix E is implemented.

## 6. Control Transfer and S-Register Instructions

Most control and S-register instructions have the following format:

```text
11 ddd aaa 11111 bbb
```

For `bbb = 000`, `ddd` is a control selector. Only the following
control-selector values are defined:

| `bbb` | `ddd` | instruction | operation |
|---|---|---|---|
| `000` | `000` | `RET Sa` | `pc ← S[a]` |
| `000` | `101` | `RETI Sa` | `IE ← 1`; `pc ← S[a]` |
| `000` | `010` | `CLI` | `IE ← 0` |
| `000` | `111` | `STI` | `IE ← 1` |

In these selectors, `ddd[1]` selects a return (`0`) or a direct `IE`
operation (`1`), and `ddd[2] = ddd[0]` supplies the zero/one value. The
return/value-zero combination preserves `IE`; the other three combinations
write the selected value.

All other `ddd` values in the `bbb = 000` row are reserved and undefined.
`aaa` selects `Sa` for `RET` and `RETI`; `CLI` and `STI` require `aaa = 0`.

The remaining `bbb` values have the following definitions:

| `bbb` | instruction | operation |
|---|---|---|
| `001` | `JALR Sd, ra` | if `d != 0`, `S[d] ← pc_next`; `pc ← R[a]` |
| `010` | `MFS rd, Sa` | `R[d] ← S[a]` |
| `011` | `MTS Sd, ra` | `S[d] ← R[a]` |
| `100..111` | reserved | undefined |

`RET` transfers control through its S-register operand. It does not change
`IE`.

`RETI` transfers control through its S-register operand and sets `IE` to one.
Consequently, `RET S0` preserves `IE`, while `RETI S0` sets it.

`CLI` clears `IE`.

`STI` sets `IE` to one.

`JALR` transfers control to the byte address in `ra` and, unless `Sd` is `S0`,
writes the byte address of the following instruction to `Sd`. Thus,
`JALR S0, ra` is a register-indirect jump without a link write.

`MFS` copies the selected S-register to `rd`.

`MTS` copies `ra` to the selected S-register.

## 7. Absolute Long Call

A long instruction occupies two consecutive instruction halfwords and is one
architectural instruction. Interrupts are not taken between its halfwords.
There are no instructions longer than two halfwords.

The `sys` and `full` profiles define the following absolute long-call family:

```text
first halfword:  00 ddd hhhhh 11 0100
second halfword: llllllllllllllll
```

`ddd` selects the S-register link destination. RC16 requires `hhhhh=00000`
and uses the second halfword as the complete absolute byte address `addr16`.
RC32 instead forms the absolute byte address:

```text
addr21 = { hhhhh, llllllllllllllll }
```

| ISA | instruction | operation |
|---|---|---|
| RC16 | `JALL Sd, addr16` | if `d != 0`, `S[d] ← pc_next`; `pc ← addr16` |
| RC32 | `JALL Sd, addr21` | if `d != 0`, `S[d] ← pc_next`; `pc ← zx21(addr21)` |

The encoded absolute address must be two-byte aligned. `JALL S0, addr` does
not write a link. The family is absent from `min`.

In RC32, `addr21` selects the low 2 MiB of the byte address space.

## 8. Interrupts

The `sys` and `full` profiles define `IE` and the interrupt-entry mechanism
specified below. The `min` profile and Nano do not define interrupt entry. A
platform may provide zero or more interrupt sources and may use an interrupt
controller to select an interrupt vector.

RISC-C defines only maskable interrupts. Non-maskable interrupt behavior,
if present, must be defined by a platform or extension. Interrupts defined by
this section are sampled between completed architectural instructions, using
the value of `IE` resulting from the preceding instruction, and are taken only
when that value is one.

At an interrupt boundary, `pc` is the byte address of the next
instruction that would have executed had the interrupt not been taken.
On entry:

```text
S[0] ← pc
IE ← 0
pc ← interrupt_vector
```

`interrupt_vector` is the XLEN-bit byte address selected for the
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
| `LD rd, [ra+simm]` | X | X | X |
| `ST rs, [ra+simm]` | X | X | X |
| `LDX rd, [ra+rb]` | X | X | X |
| `LDB rd, [ra]` | X | X | X |
| `LDBS rd, [ra]` | X | X | X |
| `STB rs, [ra]` | X | X | X |
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
| `JALL Sd, addr16` |  | X | X |
| `ADD rd, ra, rb` | X | X | X |
| `SUB rd, ra, rb` | X | X | X |
| `SLT rd, ra, rb` | X | X | X |
| `SLTU rd, ra, rb` | X | X | X |
| `AND rd, ra, rb` | X | X | X |
| `OR rd, ra, rb` | X | X | X |
| `XOR rd, ra, rb` | X | X | X |
| `FSL1 rd, ra` | X | X | X |
| `FSR1 rd, ra` | X | X | X |
| `SLL rd, ra` § |  |  |  |
| `SRL rd, ra` § |  |  |  |
| `SRA rd, ra` § |  |  |  |
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



§ `SLL`, `SRL`, and `SRA` are optional Appendix E instructions. `MULHU` and
`DIVU` are optional Appendix B instructions. None is required by any profile.

# Appendices

## Appendix A. Nano Profile

Nano is a separate reduced RC16 variant rather than a mainline profile. It does
not combine with the extensions in Appendices B through E.

### A.1 Architectural State

Nano has only `r0..r7` and `pc` as architectural state. It has no S-register
bank, `IE`, `EPC`, or interrupt entry. Instruction and data addressing, byte
order, alignment, and the memory model are otherwise the same as for mainline
RC16.

### A.2 Instruction Availability

Nano defines only the following compact instructions:

| class | instructions |
|---|---|
| memory | `LD`, `ST`, `LDX`, `LDB`, `STB` |
| immediate | `LDI`, `LUI`, `ADDI`, `ANDI`, `ORI`, `XORI` |
| branch | `BEQZ`, `BNEZ`, `BLTZ`, `BGEZ`, `JMP8` |
| register | `ADD`, `SUB`, `SLTU`, `AND`, `OR`, `XOR` |
| shift | `SRLI rd, ra, 1`, `SRAI rd, ra, 1` |
| indirect control | `JALR rd, ra` |

These instructions use their base RC16 encodings and semantics except for
`JALR`, which is specified below.
All other instruction encodings, including every long-instruction encoding,
are undefined in Nano.

### A.3 Register-Indirect Control Transfer

Nano redefines the base register-indirect `JALR` encoding as `JALR rd, ra`. It
writes `pc_next` to general register `rd` and transfers control through `R[a]`.
With `rd = r0`, no link is written; this is a plain register jump. Assemblers
may spell these forms as `CALL rd, ra` and `JMP ra`, respectively.

## Appendix B. Multiply-Divide Instructions (MDU) Extension

This optional extension may be combined with RC16 or RC32. When the optional
RC32X extension is implemented with RC32, Appendix D supplies long forms with
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
N       = unsignedXLEN(R[rr]) * 2^XLEN + unsignedXLEN(R[rq])
divisor = R[rb]
R[rq]   ← N / divisor
R[rr]   ← N % divisor
```

`rr`, `rq`, and `rb` must name different registers. `divisor` must be
nonzero, and `unsignedXLEN(R[rr]) < unsignedXLEN(divisor)` is required on
entry; this guarantees that the quotient fits in XLEN bits. If any of these
requirements is not met, the result is undefined. These operand restrictions
are an exception to the general source-before-destination ordering rule.

## Appendix C. RC32 Width Extension

RC32 is an optional target configuration that extends the compact RC16 base
ISA. It sets `XLEN = 32`. RC16 and RC32 are separate architectural
configurations.

RC32 changes register and data width; it does not add registers or widen the
three-bit register selectors in compact instructions. The separately optional
RC32X extension in Appendix D adds a five-bit, 32-selector operand namespace and
its associated long formats. Thus an RC32 compact instruction still selects
only `r0..r7` or `S0..S7`, but each selected register holds a 32-bit value.

Unless this appendix specifies otherwise, RC32 retains the compact instruction
encodings, semantics, and profile availability of RC16, with every
`XLEN`-dependent register, address, result, and memory data word widened to 32
bits.

### C.1 Architectural Width and Addressing

In RC32, `r0..r7`, `S0..S7`, and `pc` are 32 bits wide. Register and
program-counter writes retain their low 32 bits, and arithmetic results and
effective addresses wrap modulo `2^32`. Links, interrupt return addresses,
and `interrupt_vector` are 32-bit byte addresses. RC32X is not needed to select
or operate on these 32-bit compact-register values.

A 32-bit address selects one of `2^32` bytes in the unified address space.
Compact instructions retain their immediate widths and field positions. Their
sign and zero extension is to 32 bits, and signed operations use bit 31 as the
sign bit. RC32 replaces compact `LUI` with `LDPC` and widens compact branch
displacements as specified below.

The RC32 compact `LDPC` encoding is:

```text
10 ddd 001 rrrrrrrr
```

It loads a 32-bit native word relative to the following instruction:

```text
R[d] ← M32[pc_next + sx9({ r[0], r[7:1], 0 })]
```

The effective address must be four-byte aligned. RC32 compact branches use the
same signed instruction-halfword displacement:

```text
encoded r[7:1] = rel8[6:0]
encoded r[0]   = rel8[7]
pc_target = pc_next + sx9({ r[0], r[7:1], 0 })
```

They have the same reach and encoding as RC16 compact branches.

### C.2 RC32 Memory Access

In RC32, `MXLEN[a]` is the 32-bit word `M32[a]`. `LD`, `ST`, `LDX`,
and `LDPC` transfer 32 bits. They require a four-byte-aligned
effective address. An unaligned access has undefined behavior unless another
architectural extension defines it. An aligned 32-bit word access has the
atomicity specified in section 2.1.

The compact `LD` and `ST` format is unchanged, but its displacement is:

```text
simm = sx9({ i[1], i[7:2], 0, 0 })
```

RC32 defines the following direct typed instructions in the compact memory
families from section 3.2:

| `fffff` | `bbb` | instruction | operation |
|:---:|:---:|---|---|
| `01010` | `010` | `LDH rd, [ra]` | `R[d] ← zx16(M16[R[a]])` |
| `01011` | `010` | `STH rs, [ra]` | `M16[R[a]] ← R[s][15:0]` |
| `01110` | `010` | `LDHS rd, [ra]` | `R[d] ← sx16(M16[R[a]])` |

`LDH`, `LDHS`, and `STH` require a two-byte-aligned address. Native
32-bit access uses `LD` or `ST` with a zero displacement, so the other
direct-width selectors remain reserved. RC32 byte and halfword loads extend
their result to 32 bits as specified by the mnemonic.

### C.3 RC32 Long Instructions

The long-instruction length and interrupt rules in section 7 apply. RC32
defines only the shared `JALL` and `JMPL` encoding in its `sys` and
`full` profiles; it remains absent from `min`. All other base-RC32 long
encodings are reserved. Appendix D defines additional long instructions when
RC32X is present.

A full-range absolute call or jump loads its byte target from a nearby literal
and then uses the inherited compact `JALR`:

```text
LDPC rt, target_literal
JALR Sd, rt
.balign 4
target_literal: .word target
```

`JALR S0, rt` suppresses the link write. In `sys` and `full`, `JALL`
provides a one-instruction call to an aligned address in the low 2 MiB and
`JMPL` is its `Sd=S0` alias.

### C.4 RC32 Profiles

RC32 defines `min`, `sys`, and `full` profiles corresponding to the RC16
mainline profiles. Each inherits the instruction availability of its RC16
counterpart except that compact `LUI` is replaced by `LDPC`; `LDPC` and compact
branches use the shared rotated `rel8` field. `JALL`/`JMPL` remain
available in `sys` and `full`. RC32 has no Nano profile.

The following typed halfword instructions are additionally mandatory in every
RC32 mainline profile:

| instruction | `min` | `sys` | `full` |
|---|:---:|:---:|:---:|
| `LDH rd, [ra]` | X | X | X |
| `LDHS rd, [ra]` | X | X | X |
| `STH rs, [ra]` | X | X | X |

Compact shift-count availability remains unchanged: only the encodings from 1
through 8 exist, subject to the selected profile. Appendix D defines the
optional RC32X register extension for RC32.

## Appendix D. RC32X Register Extension

RC32X is an optional RC32-only register-namespace and long-instruction
extension. It does not change `XLEN`: its registers are 32 bits wide because
it requires RC32. RC32 itself retains only the compact `r0..r7` and `S0..S7`
register names; RC32X adds the following architectural state:

| state | width | description |
|---|---:|---|
| `x0..x15` | XLEN | RC32X-extension registers |

RC32X supplies a 32-selector operand namespace: the existing eight `r`
registers, the existing eight S-registers, and sixteen new `x` registers. It
retains the existing `r` and S-register names and their architectural roles. A
five-bit RC32X register selector has the following mapping:

| selector | register |
|---|---|
| `00_000..00_111` | `r0..r7` |
| `01_000..01_111` | `S0..S7` |
| `10_000..11_111` | `x0..x15` |

This appendix writes an RC32X-selected register as `X[x]`. The special treatment
of `S0` as interrupt EPC and as a no-link destination is unchanged.

### D.1 Long Instruction Encoding

Every RC32X instruction occupies exactly two consecutive instruction halfwords
and is one architectural instruction. Interrupts are not taken between its
halfwords. There are no instructions longer than two halfwords.

Except for the register format in section D.2, an RC32X long instruction has its
principal operand fields and opcode in the first halfword:

```text
first halfword:  00 ddd aaa DD AA oooo
```

`DD` and `AA` normally extend `ddd` and `aaa` to five-bit register selectors
when those operands are present. The I16 format in section D.3 instead uses
`aaa` and `AA` to select its operation, uses `DD` as part of the RC32X indirect
target selector for long `JALR`, or uses `{ aaa, DD }` as the high five address
bits for `JALL`. `oooo` is the primary long opcode. The I16 and
conditional-branch formats use secondary operation fields.

| `oooo` | instruction or format |
|:---:|---|
| `0000` | register format; section D.2 |
| `0001..0011` | reserved |
| `0100` | I16 format; section D.3 |
| `0101` | integer load |
| `0110` | integer store |
| `0111` | sign-extending integer load |
| `1000..1011` | reserved |
| `1100` | conditional-branch format; section D.4 |
| `1101..1111` | reserved |

The second halfword is the complete `imm16` for ordinary I16 instructions,
the low 16 bits of `addr21` for `JALL`, `{ ccc, rel13 }` for conditional
branches, or the tagged displacement `t16` for memory instructions. Long
register instructions instead use the layout in section D.2 so that their
function and low register fields retain the compact register-format positions.

The RC32X long `JALR` and shared `JALL` defined in section D.3 retain three-bit
S-register link destinations. Other control-transfer and interrupt-control
instructions retain their compact forms. RC32X does not widen the 21-bit
absolute target or add `JALL` to `min`; its base `sys` and `full` availability
is unchanged.

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
register instruction. For typed indexed loads, `ww` selects the access width
using the width codes from section 3.2. For shifts and the `10001` group,
`ww` extends the operation as listed below. All other register instructions
require `ww=00`. Stores use the long displacement format in section D.5.

| `ww` | `fffff` | instruction | operation |
|:---:|:---:|---|---|
| `00` | `00000` | `ADD Xd, Xa, Xb` | `X[xd] ← X[xa] + X[xb]` |
| `00` | `00001` | `SUB Xd, Xa, Xb` | `X[xd] ← X[xa] - X[xb]` |
| `00` | `00010` | `SLT Xd, Xa, Xb` | `X[xd] ← (signedXLEN(X[xa]) < signedXLEN(X[xb])) ? 1 : 0` |
| `00` | `00011` | `SLTU Xd, Xa, Xb` | `X[xd] ← (unsignedXLEN(X[xa]) < unsignedXLEN(X[xb])) ? 1 : 0` |
| `00` | `00100` | `AND Xd, Xa, Xb` | `X[xd] ← X[xa] & X[xb]` |
| `00` | `00101` | `OR Xd, Xa, Xb` | `X[xd] ← X[xa] \| X[xb]` |
| `00` | `00110` | `XOR Xd, Xa, Xb` | `X[xd] ← X[xa] ^ X[xb]` |
| `00` | `00111` | `MUL Xd, Xa, Xb` | `X[xd] ← (X[xa] * X[xb])[31:0]` |
| `00` | `01000` | `LDX Xd, [Xa+Xb]` | `X[xd] ← M32[X[xa] + X[xb]]` |
| `00` | `01010` | `LDB Xd, [Xa+Xb]` | `X[xd] ← zx8(M8[X[xa] + X[xb]])` |
| `01` | `01010` | `LDH Xd, [Xa+Xb]` | `X[xd] ← zx16(M16[X[xa] + X[xb]])` |
| `00` | `01100` | `SRLI Xd, Xa, 1..32` | `X[xd] ← X[xa] >> (xb + 1)` |
| `01` | `01100` | `SRL Xd, Xa, Xb` § | `X[xd] ← X[xa] >> (X[xb] & 31)` |
| `00` | `01101` | `SRAI Xd, Xa, 1..32` | `X[xd] ← signedXLEN(X[xa]) >>> (xb + 1)` |
| `01` | `01101` | `SRA Xd, Xa, Xb` § | `X[xd] ← signedXLEN(X[xa]) >>> (X[xb] & 31)` |
| `00` | `01110` | `LDBS Xd, [Xa+Xb]` | `X[xd] ← sx8(M8[X[xa] + X[xb]])` |
| `01` | `01110` | `LDHS Xd, [Xa+Xb]` | `X[xd] ← sx16(M16[X[xa] + X[xb]])` |
| `00` | `01111` | `SLLI Xd, Xa, 1..32` | `X[xd] ← X[xa] << (xb + 1)` |
| `01` | `01111` | `SLL Xd, Xa, Xb` § | `X[xd] ← X[xa] << (X[xb] & 31)` |
| `00` | `10000` | `DIVU Xr, Xq, Xb` § | paired unsigned divide/remainder; Appendix B |
| `00` | `10001` | `FSL1 Xd, Xa, Xb` | `X[xd] ← (X[xa] << 1) \| X[xb][31]` |
| `01` | `10001` | `FSR1 Xd, Xa, Xb` | `X[xd] ← (X[xa] >> 1) \| (X[xb][0] << 31)` |
| `00` | `10100` | `MULHU Xl, Xh, Xb` § | paired unsigned product; Appendix B |

All unlisted `ww` and `fffff` combinations are reserved and undefined. The
indexed integer loads are available in every RC32X profile. `ww=11` is reserved
for 64-bit memory operations in a future XLEN=64 extension; that extension may
also define `ww=10` zero- and sign-extending 32-bit indexed loads. Floating-
point memory operations are not defined by RC32X.

The arithmetic and immediate-shift encodings use the same selected-profile
availability as their compact counterparts. § The variable `SLL`, `SRL`, and
`SRA` forms are defined only when Appendix E is implemented. The five-bit
`MULHU` and `DIVU` forms are defined only when Appendix B is implemented and
retain its operand restrictions.

For `SLLI`, `SRLI`, and `SRAI`, `xb` is an unsigned five-bit shift-count
encoding rather than a register selector; the shift count is `xb + 1`, from
one through 32. Appendix E defines the register-count forms. RC32X `min` permits
only the existing one-bit `SRLI` and `SRAI` forms, while RC32X `sys` and `full`
permit the full immediate-shift set. At a count of 32, `SLLI` and `SRLI`
produce zero, while `SRAI` produces 32 copies of the original sign bit.

The long `FSL1` and `FSR1` forms are full three-register operations. The
compact forms in section 5.1 are equivalent to tying `Xa` to `Xd` and using
the compact `ra` as `Xb`.

### D.3 I16 Instructions

The RC32X I16 format is:

```text
first halfword:  00 ddd aaa DD AA 0100
second halfword: iiiiiiiiiiiiiiii
```

The second halfword is the complete 16-bit immediate for ordinary I16
instructions or the low 16 address bits for `JALL`. `AA` selects one of four
non-overlapping pages.

For `AA=00`, the instruction selects `xd = { DD, ddd }`; `aaa` selects a
destination-only or destructive read/modify/write operation. The literal,
upper-literal, arithmetic, and logical operation values align with the compact
immediate format; the two remaining values provide signed and unsigned
comparisons.

| `AA` | `aaa` | instruction | operation |
|:---:|:---:|---|---|
| `00` | `000` | `LDI Xd, uimm16` | `X[xd] ← zx16(uimm16)` |
| `00` | `001` | `LUIL Xd, uimm16` | `X[xd] ← uimm16 << 16` |
| `00` | `010` | `ADDI Xd, simm16` | `X[xd] ← X[xd] + sx16(simm16)` |
| `00` | `011` | `SLTI Xd, simm16` | `X[xd] ← (signedXLEN(X[xd]) < signedXLEN(sx16(simm16))) ? 1 : 0` |
| `00` | `100` | `ANDI Xd, uimm16` | `X[xd] ← X[xd] & zx16(uimm16)` |
| `00` | `101` | `ORI Xd, uimm16` | `X[xd] ← X[xd] \| zx16(uimm16)` |
| `00` | `110` | `XORI Xd, uimm16` | `X[xd] ← X[xd] ^ zx16(uimm16)` |
| `00` | `111` | `SLTIU Xd, simm16` | `X[xd] ← (unsignedXLEN(X[xd]) < unsignedXLEN(sx16(simm16))) ? 1 : 0` |
| `01` | `001` | `AUIPC Xd, imm16` | `X[xd] ← pc + (imm16 << 16)` |
| `10` | any | `JALR Sd, [Xa+simm16]` | if `d != 0`, `S[d] ← pc_next`; `pc ← X[xa] + sx16(simm16)` |
| `11` | any | `JALL Sd, addr21` | if `d != 0`, `S[d] ← pc_next`; `pc ← zx21(addr21)` |

`LDI` and `LUIL` do not read the old value of `Xd`. The other six `AA=00`
operations read and overwrite `Xd`. `ADDI`, `SLTI`, and `SLTIU` sign-extend
their immediate; `SLTIU` then compares both operands as unsigned. The logical
operations zero-extend their immediate.

For `AUIPC`, `xd = { DD, ddd }`; shifting the raw 16-bit field places it in
bits `[31:16]`, so its signedness does not affect the result modulo `2^32`.

The `AA=10` page is the special long `JALR` encoding defined by RC32X. In that
page, `ddd` selects the three-bit S-register link destination and
`xa = { DD, aaa }`. Thus the two `DD` bits, which are not needed to extend the
link destination, instead extend the indirect-target register. `JALR S0,
[Xa+simm16]` suppresses the link write. All eight `aaa` values are operands,
not operation selectors.

The `AA=11` page contains the shared `JALL` encoding from section 7. `ddd`
remains the S-register link destination, and the five contiguous bits
`{ aaa, DD }` form `addr21[20:16]`; the second halfword supplies
`addr21[15:0]`. These bits are an address field rather than an RC32X register
selector.

`AA=01` with `aaa != 001` is reserved and undefined. RC32X defines every
non-reserved instruction in the `AA=00`, `AA=01`, and `AA=10` pages; these
encodings are not part of base RC32. Section 7 defines the shared `JALL`
encoding in `sys` and `full`; RC32X does not alter that `AA=11` page.

### D.4 Conditional-Branch Instructions

The RC32X conditional-branch format is:

```text
first halfword:  00 ddd aaa DD AA 1100
second halfword: ccc rrrrrrrrrrrrr
```

It selects `xd = { DD, ddd }` and `xa = { AA, aaa }`. The three `c` bits
select the condition, and the thirteen `r` bits form the signed
instruction-halfword displacement `rel13`. In this format only, the first
comparison operand is:

```text
D = 0       when xd selects r0 (00_000)
D = X[xd]   otherwise
```

The second operand is always `X[xa]`. This rule does not alter `r0` for other
RC32X or compact instructions.

| `ccc` | instruction | operation |
|:---:|---|---|
| `000` | `BEQ Xd, Xa, rel13` | branch when `D == X[xa]` |
| `001` | `BNE Xd, Xa, rel13` | branch when `D != X[xa]` |
| `010` | `BLT Xd, Xa, rel13` | branch when `signedXLEN(D) < signedXLEN(X[xa])` |
| `011` | `BGE Xd, Xa, rel13` | branch when `signedXLEN(D) >= signedXLEN(X[xa])` |
| `100` | `BLTU Xd, Xa, rel13` | branch when `unsignedXLEN(D) < unsignedXLEN(X[xa])` |
| `101` | `BGEU Xd, Xa, rel13` | branch when `unsignedXLEN(D) >= unsignedXLEN(X[xa])` |
| `110..111` | reserved | undefined |

All instructions in this format are supplied by RC32X; RC32 without RC32X does
not define opcode `1100`.

For a conditional branch:

```text
pc_target = pc_next + (sx13(rel13) << 1)
```

Because `rel13` is measured in instruction halfwords, it has a signed 14-bit
effective byte reach. A taken conditional branch writes `pc_target` to
`pc`; an untaken branch writes `pc_next` to `pc`.

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
the indicated widths.

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

### D.6 Extension Composition

RC32X may be combined with any RC32 mainline profile. The selected profile
continues to control availability of base operations in the long register
format. RC32X defines the I16 operation set, `AUIPC`, long `JALR` with a five-bit
target selector, and every conditional branch in section D.4 in every RC32X
mainline profile. The long memory operations are also
supplied by RC32X itself in every RC32X mainline profile. The extension has no Nano
form and does not apply to RC16. The shared `JALL` availability follows the
selected base profile and is not an RC32X addition.

## Appendix E. Variable-Shift (VSH) Instructions Extension

This optional extension adds register-count logical-left, logical-right, and
arithmetic-right shifts. It may be combined with RC16 or RC32, is required by
no profile, and has no Nano form. The immediate-count `SLLI`, `SRLI`, and
`SRAI` instructions are not part of VSH and retain their base profile
availability.

### E.1 Compact Variable Shifts

VSH defines the following compact two-operand encodings from section 5.1:

| `ooo` | instruction | operation |
|:---:|---|---|
| `010` | `SLL rd, ra` | `R[d] ← R[d] << n` |
| `011` | `SRL rd, ra` | `R[d] ← R[d] >> n` |
| `111` | `SRA rd, ra` | `R[d] ← signedXLEN(R[d]) >>> n` |

In RC16, `n = R[a][3:0]`, from zero through 15. In RC32,
`n = R[a][4:0]`, from zero through 31. Both operands are read before `rd` is
written, including when `rd` and `ra` name the same register.

### E.2 RC32X Variable Shifts

When RC32X is also implemented, VSH defines the following long three-register
forms from section D.2:

| `ww` | `fffff` | instruction | operation |
|:---:|:---:|---|---|
| `01` | `01111` | `SLL Xd, Xa, Xb` | `X[xd] ← X[xa] << n` |
| `01` | `01100` | `SRL Xd, Xa, Xb` | `X[xd] ← X[xa] >> n` |
| `01` | `01101` | `SRA Xd, Xa, Xb` | `X[xd] ← signedXLEN(X[xa]) >>> n` |

Here `n = X[xb] & 31`, from zero through 31. All source operands are read
before `Xd` is written.

## Appendix F. Complete Instruction Encoding Table

This table indexes every defined instruction encoding in RC16, RC32, Nano, and
the optional extensions. In the profile / extension column, `all` includes
RC16, RC32, and Nano. `RC16` instructions are inherited by RC32 unless marked
`RC16 only`; `RC32` identifies instructions added by the width extension. A
profile qualifier includes that profile and every larger ordered profile. A
displayed immediate-shift range constrains the corresponding encoded count;
the `2..8` and `2..32` rows therefore exclude the separately listed one-bit
encoding.

| halfword 1 | halfword 2 | instruction | profile / extension |
|---|---|---|---|
| `01dddaaaiiiiiii0` | — | `LD rd, [ra+simm]` | all |
| `01dddaaaiiiiiii1` | — | `ST rs, [ra+simm]` | all |
| `10ddd000iiiiiiii` | — | `LDI rd, imm8` | all |
| `10ddd001iiiiiiii` | — | `LUI rd, imm8` | RC16 only and Nano |
| `10ddd001rrrrrrrr` | — | `LDPC rd, rel8` | RC32 |
| `10ddd010iiiiiiii` | — | `ADDI rd, simm8` | all |
| `10ddd011iiiiiiii` | — | `CMPI rs, simm8` | RC16 |
| `10ddd100iiiiiiii` | — | `ANDI rd, imm8` | all |
| `10ddd101iiiiiiii` | — | `ORI rd, imm8` | all |
| `10ddd110iiiiiiii` | — | `XORI rd, imm8` | all |
| `10000111rrrrrrrr` | — | `BEQZ rel8` | all |
| `10001111rrrrrrrr` | — | `BNEZ rel8` | all |
| `10010111rrrrrrrr` | — | `BLTZ rel8` | all |
| `10011111rrrrrrrr` | — | `BGEZ rel8` | all |
| `10100111rrrrrrrr` | — | `JMP8 rel8` | all |
| `11dddaaa00000bbb` | — | `ADD rd, ra, rb` | all |
| `11dddaaa00001bbb` | — | `SUB rd, ra, rb` | all |
| `11dddaaa00010bbb` | — | `SLT rd, ra, rb` | RC16 |
| `11dddaaa00011bbb` | — | `SLTU rd, ra, rb` | all |
| `11dddaaa00100bbb` | — | `AND rd, ra, rb` | all |
| `11dddaaa00101bbb` | — | `OR rd, ra, rb` | all |
| `11dddaaa00110bbb` | — | `XOR rd, ra, rb` | all |
| `11dddaaa00111bbb` | — | `MUL rd, ra, rb` | RC16 full |
| `11dddaaa01000bbb` | — | `LDX rd, [ra+rb]` | all |
| `11dddaaa01010000` | — | `LDB rd, [ra]` | all |
| `11dddaaa01010010` | — | `LDH rd, [ra]` | RC32 |
| `11dddaaa01011000` | — | `STB rs, [ra]` | all |
| `11dddaaa01011010` | — | `STH rs, [ra]` | RC32 |
| `11dddaaa01100000` | — | `SRLI rd, ra, 1` | all |
| `11dddaaa01100bbb` | — | `SRLI rd, ra, 2..8` | RC16 sys |
| `11dddaaa01101000` | — | `SRAI rd, ra, 1` | all |
| `11dddaaa01101bbb` | — | `SRAI rd, ra, 2..8` | RC16 sys |
| `11dddaaa01110000` | — | `LDBS rd, [ra]` | RC16 |
| `11dddaaa01110010` | — | `LDHS rd, [ra]` | RC32 |
| `11dddaaa01111bbb` | — | `SLLI rd, ra, 1..8` | RC16 sys |
| `11dddaaa10000bbb` | — | `DIVU rr, rq, rb` | RC16 MDU |
| `11dddaaa10001000` | — | `FSL1 rd, ra` | RC16 |
| `11dddaaa10001001` | — | `FSR1 rd, ra` | RC16 |
| `11dddaaa10001010` | — | `SLL rd, ra` | RC16 VSH |
| `11dddaaa10001011` | — | `SRL rd, ra` | RC16 VSH |
| `11dddaaa10001111` | — | `SRA rd, ra` | RC16 VSH |
| `11dddaaa10100bbb` | — | `MULHU rl, rh, rb` | RC16 MDU |
| `11000aaa11111000` | — | `RET Sa` | RC16 |
| `11101aaa11111000` | — | `RETI Sa` | RC16 sys |
| `11dddaaa11111001` | — | `JALR Sd, ra` | RC16 |
| `11dddaaa11111001` | — | `JALR rd, ra` | Nano |
| `11dddaaa11111010` | — | `MFS rd, Sa` | RC16 |
| `11dddaaa11111011` | — | `MTS Sd, ra` | RC16 |
| `1101000011111000` | — | `CLI` | RC16 sys |
| `1111100011111000` | — | `STI` | RC16 sys |
| `00ddd00000110100` | `llllllllllllllll` | `JALL Sd, addr16` | RC16 sys |
| `0000000000110100` | `llllllllllllllll` | `JMPL addr16` | RC16 sys |
| `00dddhhhhh110100` | `llllllllllllllll` | `JALL Sd, addr21` | RC32 sys |
| `00000hhhhh110100` | `llllllllllllllll` | `JMPL addr21` | RC32 sys |
| `00dddaaa00000000` | `DDAABB0000000bbb` | `ADD Xd, Xa, Xb` | RC32X |
| `00dddaaa00000000` | `DDAABB0000001bbb` | `SUB Xd, Xa, Xb` | RC32X |
| `00dddaaa00000000` | `DDAABB0000010bbb` | `SLT Xd, Xa, Xb` | RC32X |
| `00dddaaa00000000` | `DDAABB0000011bbb` | `SLTU Xd, Xa, Xb` | RC32X |
| `00dddaaa00000000` | `DDAABB0000100bbb` | `AND Xd, Xa, Xb` | RC32X |
| `00dddaaa00000000` | `DDAABB0000101bbb` | `OR Xd, Xa, Xb` | RC32X |
| `00dddaaa00000000` | `DDAABB0000110bbb` | `XOR Xd, Xa, Xb` | RC32X |
| `00dddaaa00000000` | `DDAABB0000111bbb` | `MUL Xd, Xa, Xb` | RC32X full |
| `00dddaaa00000000` | `DDAABB0001000bbb` | `LDX Xd, [Xa+Xb]` | RC32X |
| `00dddaaa00000000` | `DDAABB0001010bbb` | `LDB Xd, [Xa+Xb]` | RC32X |
| `00dddaaa00000000` | `DDAABB0101010bbb` | `LDH Xd, [Xa+Xb]` | RC32X |
| `00dddaaa00000000` | `DDAA000001100000` | `SRLI Xd, Xa, 1` | RC32X |
| `00dddaaa00000000` | `DDAABB0001100bbb` | `SRLI Xd, Xa, 2..32` | RC32X sys |
| `00dddaaa00000000` | `DDAABB0101100bbb` | `SRL Xd, Xa, Xb` | RC32X VSH |
| `00dddaaa00000000` | `DDAA000001101000` | `SRAI Xd, Xa, 1` | RC32X |
| `00dddaaa00000000` | `DDAABB0001101bbb` | `SRAI Xd, Xa, 2..32` | RC32X sys |
| `00dddaaa00000000` | `DDAABB0101101bbb` | `SRA Xd, Xa, Xb` | RC32X VSH |
| `00dddaaa00000000` | `DDAABB0001110bbb` | `LDBS Xd, [Xa+Xb]` | RC32X |
| `00dddaaa00000000` | `DDAABB0101110bbb` | `LDHS Xd, [Xa+Xb]` | RC32X |
| `00dddaaa00000000` | `DDAABB0001111bbb` | `SLLI Xd, Xa, 1..32` | RC32X sys |
| `00dddaaa00000000` | `DDAABB0101111bbb` | `SLL Xd, Xa, Xb` | RC32X VSH |
| `00dddaaa00000000` | `DDAABB0010000bbb` | `DIVU Xr, Xq, Xb` | RC32X MDU |
| `00dddaaa00000000` | `DDAABB0010001bbb` | `FSL1 Xd, Xa, Xb` | RC32X |
| `00dddaaa00000000` | `DDAABB0110001bbb` | `FSR1 Xd, Xa, Xb` | RC32X |
| `00dddaaa00000000` | `DDAABB0010100bbb` | `MULHU Xl, Xh, Xb` | RC32X MDU |
| `00ddd000DD000100` | `iiiiiiiiiiiiiiii` | `LDI Xd, uimm16` | RC32X |
| `00ddd001DD000100` | `iiiiiiiiiiiiiiii` | `LUIL Xd, uimm16` | RC32X |
| `00ddd010DD000100` | `iiiiiiiiiiiiiiii` | `ADDI Xd, simm16` | RC32X |
| `00ddd011DD000100` | `iiiiiiiiiiiiiiii` | `SLTI Xd, simm16` | RC32X |
| `00ddd100DD000100` | `iiiiiiiiiiiiiiii` | `ANDI Xd, uimm16` | RC32X |
| `00ddd101DD000100` | `iiiiiiiiiiiiiiii` | `ORI Xd, uimm16` | RC32X |
| `00ddd110DD000100` | `iiiiiiiiiiiiiiii` | `XORI Xd, uimm16` | RC32X |
| `00ddd111DD000100` | `iiiiiiiiiiiiiiii` | `SLTIU Xd, simm16` | RC32X |
| `00ddd001DD010100` | `iiiiiiiiiiiiiiii` | `AUIPC Xd, imm16` | RC32X |
| `00dddaaaDD100100` | `iiiiiiiiiiiiiiii` | `JALR Sd, [Xa+simm16]` | RC32X |
| `00dddaaaDDAA0101` | `iiiiiiiiiiiiiii0` | `LDB Xd, [Xa+simm]` | RC32X |
| `00dddaaaDDAA0101` | `iiiiiiiiiiiiii01` | `LDH Xd, [Xa+simm]` | RC32X |
| `00dddaaaDDAA0101` | `iiiiiiiiiiiii011` | `LDW Xd, [Xa+simm]` | RC32X |
| `00dddaaaDDAA0110` | `iiiiiiiiiiiiiii0` | `STB Xd, [Xa+simm]` | RC32X |
| `00dddaaaDDAA0110` | `iiiiiiiiiiiiii01` | `STH Xd, [Xa+simm]` | RC32X |
| `00dddaaaDDAA0110` | `iiiiiiiiiiiii011` | `STW Xd, [Xa+simm]` | RC32X |
| `00dddaaaDDAA0111` | `iiiiiiiiiiiiiii0` | `LDBS Xd, [Xa+simm]` | RC32X |
| `00dddaaaDDAA0111` | `iiiiiiiiiiiiii01` | `LDHS Xd, [Xa+simm]` | RC32X |
| `00dddaaaDDAA1100` | `000rrrrrrrrrrrrr` | `BEQ Xd, Xa, rel13` § | RC32X |
| `00dddaaaDDAA1100` | `001rrrrrrrrrrrrr` | `BNE Xd, Xa, rel13` § | RC32X |
| `00dddaaaDDAA1100` | `010rrrrrrrrrrrrr` | `BLT Xd, Xa, rel13` § | RC32X |
| `00dddaaaDDAA1100` | `011rrrrrrrrrrrrr` | `BGE Xd, Xa, rel13` § | RC32X |
| `00dddaaaDDAA1100` | `100rrrrrrrrrrrrr` | `BLTU Xd, Xa, rel13` § | RC32X |
| `00dddaaaDDAA1100` | `101rrrrrrrrrrrrr` | `BGEU Xd, Xa, rel13` § | RC32X |

§ In an RC32X conditional branch, `Xd=r0` supplies a literal zero comparison
operand as specified in section D.4.

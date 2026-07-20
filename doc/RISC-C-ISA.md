# RISC-C Instruction Set Architecture

RISC-C is an open 16-bit instruction set architecture for compact systems
that need a tiny controller. It defines three ordered mainline
profiles: `min`, `sys`, and `full`, plus the incompatible subset `nano`
profile.

This document is the RISC-C ISA specification. It defines the architectural
state, instruction encodings and semantics, memory-access rules, interrupt
behavior, and profile extensions.

The RISC-C specification and reference implementations are released under
the ISC License and may be used, copied, modified, and distributed for any
purpose, with or without fee.

Version: `v0.16.0`.

Author: Arto Vuori <avuori@iki.fi>

### Versioning

RISC-C version identifiers have the form `vMAJOR.MINOR.PATCH`.
`MAJOR`, `MINOR`, and `PATCH` are non-negative decimal integers with no
leading zeros except for zero itself. A major version changes the ISA in an
incompatible way; a minor version adds compatible ISA features or
clarifications; a patch version makes compatible corrections or editorial
changes.

## 1. RISC-C Base Integer Instruction Set

This chapter describes the RISC-C base integer ISA. The `min` profile defines
the base instruction set; the `sys` and `full` profiles add the extensions
defined in section 7.

### 1.1 Programmer's Model

| state | width | description |
|---|---:|---|
| `r0..r7` | 16 | general-purpose registers |
| `S0..S7` | 16 | S-register bank |
| `pc` | 15 | program counter, in word addresses |
| `IE` | 1 | interrupt-enable bit (`sys` profile) |

There are no arithmetic condition codes and no architectural zero register.
All general-register and S-register writes retain their low 16 bits. Program
counter updates retain their low 15 bits.

`r0` has no special storage behavior. All short conditional branches test
`r0`, and `CMPI` always writes its result to `r0`.

The S-register bank is accessed by `JAL`, `RET`, `MFS`, and `MTS`. The `sys`
profile additionally provides `JAL16`, `RETI`, `CLI`, and `STI`. `S0` has two
architectural roles:

- In `JAL` and `JAL16`, destination `S0` suppresses the link write.
- In the `sys` profile, `S0` is `EPC`, the interrupt return program
  counter.

Except for the roles of `S0` defined above, S-register use is unrestricted.
Interrupt entry overwrites `S0`; software executing with interrupts enabled
must not rely on an ordinary value in `S0` surviving an interrupt.

`IE` is initialized to zero by reset. Reset `pc` is platform-defined;
general-register and S-register values are unspecified following reset.

Unless an instruction explicitly assigns `pc`, execution continues at
`pc_next`.

When a 15-bit code address is written to an S-register, it is zero-extended
to 16 bits. This applies to link addresses written by `JAL` and `JAL16` and
to the interrupt return address written to `S0`.

All named source operands and effective-address operands are read from the
architectural state before an instruction writes any architectural
destination. This ordering applies when a destination register is also a
source register.

### 1.2 Instruction Length and Major Opcodes

Instructions are encoded in 16-bit words. `JAL16` is the only instruction
that occupies two words. The two most-significant bits select one of four
major opcode spaces:

| bits `[15:14]` | instruction class |
|---|---|
| `00` | immediate-offset word load |
| `01` | immediate-offset word store |
| `10` | immediate and branch instructions |
| `11` | register, indexed-memory, control, and S-register instructions |

The individual formats and their fields are defined with their instruction
classes. All instruction addresses are word addresses, so every instruction
is naturally aligned.

Bits are numbered from least significant to most significant: bit 0 is the
least-significant bit of a byte or word, and bit 15 is the most-significant
bit of a word. Instruction-format diagrams show the most-significant bit at
the left. Byte order does not change bit numbering within a byte.

Unless explicitly defined otherwise, unused instruction fields must be zero
in portable software. Encodings with nonzero unused fields, encodings marked
reserved, instructions not defined by the implemented profile or an
implemented extension, and other invalid encodings have undefined behavior
when executed. An implementation may trap,
execute another instruction, treat the encoding as an alias of a defined
instruction, or exhibit any other behavior. Software must not depend on such
behavior.

## 2. Address Spaces and Memory Access

RISC-C has separate architectural code and data address spaces. A code
address selects a 16-bit instruction word, while a data address selects an
8-bit byte. Thus a 15-bit code address selects one of 32768 instruction
words, whereas a 16-bit data address selects one of 65536 bytes. Code and
data may be implemented with separate physical memories or with a shared
physical memory; that choice does not change the two architectural addressing
conventions. A program must explicitly convert a byte address to a word
address before using it as an indirect control-flow destination.

The ISA does not require or prohibit self-modifying code. If code and data
share physical storage, the implementation or platform must define when a
store through the data interface becomes visible to instruction fetches.
Programs that modify instructions must use the applicable platform
synchronization mechanism before executing the modified words.

Data memory is little-endian: at byte address `2n`, the byte is the low byte
of word `n`; at byte address `2n+1`, it is the high byte.
Effective data addresses use 16-bit addition and wrap modulo 2^16.

When represented as bytes, instruction words are also little-endian: the
low byte of an instruction word precedes its high byte.

### 2.1 Memory Ordering, Atomicity, and Coherence

For each RISC-C core, accesses to ordinary data memory have the same
architectural effect as if they were performed in program order. An
implementation may execute or buffer accesses internally in another order,
provided this does not change the behavior observed by that core.

A byte load or store to ordinary data memory is an indivisible 8-bit access.
An aligned word load or store is an indivisible 16-bit access. No observer
may observe only part of an aligned word store or a word value assembled from
parts of two different aligned word stores. Byte stores may independently
replace either byte of a word as specified by the byte-access semantics.

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

`LDW`, `STW`, and `LDWX` require an even effective byte address. The
effective address, rather than an individual base or displacement, determines
alignment. An odd word address has undefined behavior; software must not
depend on whether an implementation traps, rounds the address, or performs
another action. Byte accesses have no alignment requirement.

### 2.3 Load and Store Instructions

The immediate-offset format is:

```text
00 ddd aaa iiiiiiii    LDW
01 ddd aaa iiiiiiii    STW
```

`aaa` selects `ra`; `simm8` is sign-extended before address calculation.
For `LDW`, `ddd` selects destination register `rd`; for `STW`, it selects
source register `rs`.

| opcode | instruction | operation |
|---|---|---|
| `00` | `LDW rd, [ra+simm8]` | `R[d] = M16[R[a] + sx8(simm8)]` |
| `01` | `STW rs, [ra+simm8]` | `M16[R[a] + sx8(simm8)] = R[s]` |

The register-format is:

```text
11 ddd aaa fffff bbb
```

`ddd` and `aaa` select `rd` or `rs` and `ra`; `bbb` selects `rb`. For
`STB`, `ddd` selects source register `rs` and `bbb` must be zero.

| `fffff` | instruction | operation |
|---|---|---|
| `01_000` | `LDWX rd, [ra+rb]` | `R[d] = M16[R[a] + R[b]]` |
| `01_010` | `LDB rd, [ra+rb]` | `R[d] = zx8(M8[R[a] + R[b]])` |
| `01_011` | `STB rs, [ra]` | `M8[R[a]] = R[s][7:0]` |
| `01_110` | `LDBS rd, [ra+rb]` | `R[d] = sx8(M8[R[a] + R[b]])` |

`LDW` reads a 16-bit word at the effective address formed by adding the
sign-extended displacement to `ra`. It is subject to the word-alignment
requirement in section 2.2.

`STW` writes the complete 16-bit value of `rs` at the effective address
formed by adding the sign-extended displacement to `ra`. It is subject to the
word-alignment requirement in section 2.2.

`LDWX` is subject to the word-alignment requirement in section 2.2. `STB`
stores the low byte of its source register; its `bbb` field is reserved and
must be zero in portable software.

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
| `000` | `LDI rd, imm8` | `R[d] = zx8(imm8)` |
| `001` | `LUI rd, imm8` | `R[d] = imm8 << 8` |
| `010` | `ADDI rd, simm8` | `R[d] = R[d] + sx8(simm8)` |
| `011` | `CMPI rs, simm8` | `R[0] = R[s] - sx8(simm8)` |
| `100` | `ANDI rd, imm8` | `R[d] = R[d] & zx8(imm8)` |
| `101` | `ORI rd, imm8` | `R[d] = R[d] \| zx8(imm8)` |
| `110` | `XORI rd, imm8` | `R[d] = R[d] ^ zx8(imm8)` |
| `111` | branch group | specified below |

`LDI` writes the zero-extended 8-bit immediate to `rd`.

`LUI` writes the 8-bit immediate into bits `[15:8]` of `rd` and clears bits
`[7:0]`.

`ADDI` adds a sign-extended immediate to the old value of `rd`.

`CMPI` subtracts its sign-extended immediate from `rs` and writes the result
to `r0`; it does not modify `rs`.

`ANDI`, `ORI`, and `XORI` perform bitwise AND, OR, and XOR, respectively,
between `rd` and a zero-extended immediate, then write the result to `rd`.

The branch-group format is:

```text
10 ccc 111 rrrrrrrr
```

`rel8` is a signed displacement in instruction words, relative to the next
instruction:

```text
pc_target = pc_next + sx8(rel8)
```

| `ccc` | instruction | operation |
|---|---|---|
| `000` | `BEQZ rel8` | branch if `R[0] == 0` |
| `001` | `BNEZ rel8` | branch if `R[0] != 0` |
| `010` | `BLTZ rel8` | branch if `R[0][15] == 1` |
| `011` | `BGEZ rel8` | branch if `R[0][15] == 0` |
| `100` | `JMP8 rel8` | unconditional branch |
| `101..111` | reserved | undefined |

`BEQZ` branches when `r0` is zero. Otherwise, execution continues at
`pc_next`.

`BNEZ` branches when `r0` is nonzero. Otherwise, execution continues at
`pc_next`.

`BLTZ` branches when bit 15 of `r0` is one. Otherwise, execution continues
at `pc_next`.

`BGEZ` branches when bit 15 of `r0` is zero. Otherwise, execution continues
at `pc_next`.

`JMP8` always transfers control to `pc_target`.

For a taken branch, `pc = pc_target`; otherwise `pc = pc_next`.

## 4. Register Instructions

The register format is:

```text
11 ddd aaa fffff bbb
```

Unless specified otherwise, `ddd`, `aaa`, and `bbb` select `rd`, `ra`, and
`rb`, respectively.

| `fffff` | instruction | operation |
|---|---|---|
| `00_000` | `ADD rd, ra, rb` | `R[d] = R[a] + R[b]` |
| `00_001` | `SUB rd, ra, rb` | `R[d] = R[a] - R[b]` |
| `00_010` | `SLT rd, ra, rb` | `R[d] = (signed16(R[a]) < signed16(R[b])) ? 1 : 0` |
| `00_011` | `SLTU rd, ra, rb` | `R[d] = (R[a] < R[b]) ? 1 : 0` |
| `00_100` | `AND rd, ra, rb` | `R[d] = R[a] & R[b]` |
| `00_101` | `OR rd, ra, rb` | `R[d] = R[a] \| R[b]` |
| `00_110` | `XOR rd, ra, rb` | `R[d] = R[a] ^ R[b]` |
| `00_111` | `MUL rd, ra, rb` | `R[d] = (R[a] * R[b])[15:0]` |
| `01_000` | `LDWX rd, [ra+rb]` | `R[d] = M16[R[a] + R[b]]` |
| `01_001` | reserved | undefined |
| `01_010` | `LDB rd, [ra+rb]` | `R[d] = zx8(M8[R[a] + R[b]])` |
| `01_011` | `STB rs, [ra]` | `M8[R[a]] = R[s][7:0]` |
| `01_100` | `SHRI rd, ra, imm` | `R[d] = R[a] >> (bbb + 1)` |
| `01_101` | `SARI rd, ra, imm` | `R[d] = signed16(R[a]) >>> (bbb + 1)` |
| `01_110` | `LDBS rd, [ra+rb]` | `R[d] = sx8(M8[R[a] + R[b]])` |
| `01_111` | `SHLI rd, ra, imm` | `R[d] = R[a] << (bbb + 1)` |
| `10_000` | `DIVU rr, rq, rb` | paired unsigned divide/remainder; section 4.1 |
| `10_010` | `FSR1 rd, ra, rb` | `R[d] = (R[a] >> 1) \| (R[b][0] << 15)` |
| `10_011` | `FSL1 rd, ra, rb` | `R[d] = (R[a] << 1) \| R[b][15]` |
| `10_100` | `MULHU rd, ra, rb` | `R[d] = (R[a] * R[b])[31:16]` |
| `10_001`, `10_101..11_110` | reserved | undefined |
| `11_111` | control and S-register group | section 5 |

`ADD` adds the two source registers and writes the low 16 bits of the result
to `rd`.

`SUB` subtracts `rb` from `ra` and writes the low 16 bits of the result to
`rd`.

`SLT` and `SLTU` perform signed and unsigned less-than comparisons,
respectively. Each writes one to `rd` when `ra` is less than `rb`; otherwise
it writes zero.

`AND`, `OR`, and `XOR` perform the corresponding bitwise operation on `ra`
and `rb`, then write the result to `rd`.

`FSL1` and `FSR1` are one-bit funnel shifts. `FSL1` shifts `ra` left and
inserts bit 15 of `rb` at bit 0. `FSR1` shifts `ra` right and inserts bit 0 of
`rb` at bit 15. Both source registers are read before `rd` is written, so
`rd` may name either source register.

`SHLI` and `SHRI` shift `ra` left and right, respectively, inserting zeros
into the vacated bits. Their shift count is `bbb+1`.

`SARI` shifts `ra` right and copies the original sign bit into vacated high
bits. Its shift count is `bbb+1`.

`MUL` writes the low 16 bits of the product of `ra` and `rb` to `rd`. The low
half is the same for signed and unsigned multiplication.

`MULHU` writes the high 16 bits of the unsigned product of `ra` and `rb` to
`rd`. Both sources are read before `rd` is written, so the destination may
name either source register.

`SHLI`, `SHRI`, and `SARI` encode shift counts from 1 through 8. In the
`min` profile, `SHRI` and `SARI` always shift by one and their `bbb` field
must be zero; `SHLI` is undefined. `MUL` returns the low 16 bits of the
product and is available only in the `full` profile.

### 4.1 Multiply-Divide Extension

The optional `mdu` extension adds two unsigned primitives in otherwise
reserved three-register slots:

```text
MULHU  rd, ra, rb
DIVU rr, rq, rb
```

`DIVU` uses `ddd = rr`, `aaa = rq`, and `bbb = rb`. It treats the register
pair `rr:rq` as a two-word unsigned partial dividend. More precisely, using
the input register values:

```text
N       = (R[rr] << 16) | R[rq]
divisor = R[rb]
R[rq]   = N / divisor
R[rr]   = N % divisor
```

`rr`, `rq`, and `rb` must name different registers. `divisor` must be
nonzero, and `R[rr] < divisor` is required on entry; this guarantees that the
quotient fits in 16 bits. If any of these requirements is not met, the result
is undefined. These operand restrictions are an exception to the general
source-before-destination ordering rule.

## 5. Control Transfer and S-Register Instructions

The control and S-register group has the following format:

```text
11 ddd aaa 11111 bbb
```

For `bbb = 000` and `bbb = 110`, `ddd` is a control selector, written as
`ccc` below. Only the following control-selector values are defined:

| `bbb` | `ccc` | instruction | profile | operation |
|---|---|---|---|---|
| `000` | `000` | `RET Sa` | all | `pc = S[a][14:0]` |
| `000` | `111` | `RETI Sa` | sys | `IE = 1`; `pc = S[a][14:0]` |
| `110` | `000` | `CLI` | sys | `IE = 0` |
| `110` | `111` | `STI` | sys | `IE = 1` |

All other `ccc` values in those two `bbb` rows are reserved and undefined.
The defined selectors duplicate the new `IE` value in all three `ccc` bits.
`aaa` selects `Sa` for `RET` and `RETI`; `CLI` and `STI` require `aaa = 0`.

The remaining `bbb` values have the following definitions:

| `bbb` | instruction | profile | operation |
|---|---|---|---|
| `001` | `JAL Sd, ra` | all | if `d != 0`, `S[d] = pc_next`; `pc = R[a][14:0]` |
| `010` | `MFS rd, Sa` | all | `R[d] = S[a]` |
| `011` | `MTS Sd, ra` | all | `S[d] = R[a]` |
| `100` | reserved |  | undefined |
| `101` | `JAL16 Sd` | sys | specified below |
| `111` | reserved |  | undefined |

`RET` transfers control through the low 15 bits of its S-register operand. It
does not change `IE`.

`RETI` transfers control through its S-register operand and sets `IE` to one.

`CLI` clears `IE`.

`STI` sets `IE` to one.

`JAL` transfers control through the low 15 bits of `ra` and, unless `Sd` is
`S0`, writes the word address of the following instruction to `Sd`. Thus,
`JAL S0, ra` is a register-indirect jump without a link write.

`MFS` copies the selected S-register to `rd`.

`MTS` copies `ra` to the selected S-register.

`JAL16` consumes two instruction words:

```text
11 ddd 000 11111 101    first word
tttttttttttttttt        target word address
```

The `aaa` field in the first word must be zero. If `ddd` is nonzero,
`JAL16` sets `S[d] = pc_next`, where `pc_next` is the word after its second
word. It then sets `pc = target[14:0]`. Target bit 15 is reserved and must
be zero in portable code.

## 6. Interrupts (`sys` Profile)

The `sys` profile defines interrupt entry and return. A platform may provide
one or more interrupt sources and may use an interrupt controller to select
an interrupt vector. Interrupts are sampled between completed architectural
instructions, using the value of `IE` resulting from the preceding
instruction. A maskable interrupt is taken only when that value is one.

At an interrupt boundary, `pc` is the word address of the next instruction
that would have executed had the interrupt not been taken. On entry:

```text
S[0] = pc
IE = 0
pc = interrupt_vector
```

`interrupt_vector` is the 15-bit word address selected for the accepted
interrupt. Its value, the number of vectors and sources, source priority,
level or edge triggering, interrupt acknowledgement, and controller behavior
are platform-defined.

`JAL16` is one architectural instruction. An interrupt cannot be taken
between its first and second words.

`CLI` clears `IE`, so no interrupt can be taken before the following
instruction. `STI` sets `IE`, so an interrupt may be taken before the
following instruction. `RETI` sets `IE` and transfers control, so an
interrupt may be taken before the returned-to instruction executes.

Reset-vector contents and interrupt synchronization are platform
responsibilities.

## 7. Profiles

`min`, `sys`, and `full` are ordered ISA subsets: a program using only a
smaller profile's defined instructions is valid on a larger profile. `nano`
is an incompatible RISC-C subset profile; it is not upward-compatible with
the mainline profiles.

| instruction | `min` | `sys` | `full` | `nano†` |
|---|:---:|:---:|:---:|:---:|
| `LDW rd, [ra+simm8]` | X | X | X | X |
| `STW rs, [ra+simm8]` | X | X | X | X |
| `LDWX rd, [ra+rb]` | X | X | X | X |
| `LDB rd, [ra+rb]` | X | X | X | X |
| `LDBS rd, [ra+rb]` | X | X | X |  |
| `STB rs, [ra]` | X | X | X | X |
| `LDI rd, imm8` | X | X | X | X |
| `LUI rd, imm8` | X | X | X | X |
| `ADDI rd, simm8` | X | X | X | X |
| `CMPI rs, simm8` | X | X | X |  |
| `ANDI rd, imm8` | X | X | X | X |
| `ORI rd, imm8` | X | X | X | X |
| `XORI rd, imm8` | X | X | X | X |
| `BEQZ rel8` | X | X | X | X |
| `BNEZ rel8` | X | X | X | X |
| `BLTZ rel8` | X | X | X | X |
| `BGEZ rel8` | X | X | X | X |
| `JMP8 rel8` | X | X | X | X |
| `ADD rd, ra, rb` | X | X | X | X |
| `SUB rd, ra, rb` | X | X | X | X |
| `SLT rd, ra, rb` | X | X | X |  |
| `SLTU rd, ra, rb` | X | X | X | X |
| `AND rd, ra, rb` | X | X | X | X |
| `OR rd, ra, rb` | X | X | X | X |
| `XOR rd, ra, rb` | X | X | X | X |
| `FSL1 rd, ra, rb` | X | X | X |  |
| `FSR1 rd, ra, rb` | X | X | X |  |
| `SHLI rd, ra, 1..8` |  | X | X |  |
| `SHRI rd, ra, 1` | X | X | X | X |
| `SHRI rd, ra, 2..8` |  | X | X |  |
| `SARI rd, ra, 1` | X | X | X | X |
| `SARI rd, ra, 2..8` |  | X | X |  |
| `MUL rd, ra, rb` |  |  | X |  |
| `MULHU rd, ra, rb` |  |  |  |  |
| `DIVU rr, rq, rb` |  |  |  |  |
| `RET Sa` | X | X | X |  |
| `JAL Sd, ra` | X | X | X |  |
| `JAL rd, ra` ‡ |  |  |  | X |
| `MFS rd, Sa` | X | X | X |  |
| `MTS Sd, ra` | X | X | X |  |
| `RETI Sa` |  | X | X |  |
| `JAL16 Sd, target` |  | X | X |  |
| `CLI` |  | X | X |  |
| `STI` |  | X | X |  |

† Nano is an incompatible subset profile; its encodings and architectural
state differ from the mainline profiles and are defined in section 8.

‡ `JAL rd, ra` is Nano's incompatible general-register link encoding; its
semantics are defined in section 8.

The `mdu` extension is optional. It is not required by the `min`, `sys`,
`full`, or `nano` profile.

An unaligned word access has undefined behavior unless another architectural
extension defines it.

## 8. Nano Profile

Nano is an incompatible reduced RISC-C subset profile, shown as `nano` in
the profile table. It is not a member of the ordered `min`, `sys`, and `full`
profile family. A Nano binary is not generally valid for a mainline RISC-C
profile, and a mainline binary is not generally valid for Nano.

Nano has only `r0..r7` and `pc` as architectural state. It has no S-register
bank, `IE`, `EPC`, or interrupt entry. Code and data addressing, byte order,
alignment, and the memory model are otherwise the same as for mainline
RISC-C. Its defined instruction subset is shown in the `nano` column of the
profile table.

Nano redefines the register-indirect `JAL` encoding as
`JAL rd, ra`: it writes `pc_next` to general register `rd` and transfers
control through `R[a][14:0]`. With `rd = r0`, no link is written; this is a
plain register jump. Assemblers may spell these forms as `CALL rd, ra` and
`JMP ra`, respectively.

All instructions marked `X` in the `nano` column use their mainline
semantics except where this section defines otherwise. An empty `nano` cell
denotes an undefined Nano encoding; software must not depend on any
implementation alias.

## 9. Notation

| symbol | meaning |
|---|---|
| `R[x]`, `S[x]` | general register or S-register `x` |
| `M16[a]`, `M8[a]` | 16-bit word or 8-bit byte at byte address `a` |
| `pc_next` | next instruction word address (`pc+1`, or `pc+2` for `JAL16`) |
| `sx8`, `zx8` | sign-extend 8 bits; zero-extend 8 bits |
| `signed16(x)` | interpret 16-bit value `x` as a signed two's-complement integer |
| `x >>> n` | arithmetic right shift of signed value `x` by `n` bits |
| `x[h:l]` | bit field |

Arithmetic register results wrap modulo 2^16. `M16` accesses are subject to
the alignment rule in section 2.2.

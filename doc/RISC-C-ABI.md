# RISC-C C and Object ABI

This document is the normative ABI v0 for freestanding C objects for
RC16 mainline RISC-C, its separately linkable Nano profile, and RC32.
It also defines the RC32X extension's effect on the RC32 ABI. Instruction
semantics and architectural state are specified only by the
[RISC-C ISA specification](RISC-C-ISA.md).

## 1. Scope and target identity

ABI v0 identifies the target as `riscc-none-elf` and uses native-width byte
addresses for both object and function pointers. ABI v0 is pre-stable: its
revisions may change incompatibly. The `-mcpu` option selects a
mainline profile: `full` is the default, and `sys` and `min` select the smaller
profiles. `nano` selects the incompatible RC16 Nano ABI.

### RC32 and RC32X target options

`-mrc32` selects the RC32 configuration and its ABI. It is valid only with the
mainline `full`, `sys`, and `min` profiles; `-mcpu=nano -mrc32` is invalid.
Without `-mrc32`, a mainline target uses the RC16 ABI. `-mrc32x` selects the
separate RC32X ABI, implies `-mrc32`, and is invalid for Nano. The
corresponding negative options are `-mno-rc32` and `-mno-rc32x`; disabling RC32
also disables RC32X. A toolchain that has not implemented an option must reject
it rather than silently select the RC16 ABI.

| ABI configuration | XLEN | C ABI | ELF class | valid profiles |
|---|---:|---|---|---|
| RC16 mainline | 16 | RC16 | ELF32 | `min`, `sys`, `full` |
| RC16 Nano | 16 | Nano | ELF32 | `nano` |
| RC32 | 32 | RC32 | ELF32 | `min`, `sys`, `full` |
| RC32 with RC32X | 32 | RC32X | ELF32 | `min`, `sys`, `full` |

RC32 retains the compact `r0..r7` and `S0..S7` namespace, but its registers,
addresses, and native data words are 32 bits wide. RC32X does not change XLEN or
the C data model; it adds `x0..x15` and the five-bit-selector long-instruction
formats. The ABI uses the ISA's unified byte-addressed architectural space.

ABI v0 is little-endian. It defines C calls, including variadic calls, static
local-exec TLS, and static ELF links. It does not define a hosted environment,
dynamic linking, PIC, exceptions, unwinding, atomics, or a C++ runtime.

## 2. C data model and alignment

| C type | RC16 size | RC16 alignment | RC32 size | RC32 alignment |
|---|---:|---:|---:|---:|
| `char`, `_Bool` | 1 byte | 1 byte | 1 byte | 1 byte |
| `short` | 2 bytes | 2 bytes | 2 bytes | 2 bytes |
| `int` | 2 bytes | 2 bytes | 4 bytes | 4 bytes |
| `long` | 4 bytes | 2 bytes | 4 bytes | 4 bytes |
| `long long` | 8 bytes | 2 bytes | 8 bytes | 4 bytes |
| object pointer | 2 bytes | 2 bytes | 4 bytes | 4 bytes |
| function pointer | 2 bytes | 2 bytes | 4 bytes | 4 bytes |
| `float` | 4 bytes | 2 bytes | 4 bytes | 4 bytes |
| `double`, `long double` | 8 bytes | 2 bytes | 8 bytes | 4 bytes |

Objects and aggregate members use their natural alignment from this table,
capped at two bytes in RC16 and four bytes in RC32. Padding in aggregates
follows the ordinary C layout and is not required to have a value when passed
or returned. RC32 is therefore an ILP32 ABI. In particular, an RC16 definition
whose C type includes `int`, a pointer, or an aggregate must not be shared with
an RC32 object.

`float` uses IEEE 754 binary32. `double` and `long double` both use IEEE 754
binary64; there is no extended `long double` representation. Floating-point
objects have the same little-endian, low-word-first representation in every
profile.

## 3. Stack and registers

The data stack is byte addressed and grows toward lower addresses. `r7` is
aligned to the native slot size at every C call boundary: two bytes in RC16 and
four bytes in RC32. There is no red zone and no register-argument home area.
The caller removes stack arguments.

| Register | ABI status |
|---|---|
| `r0` | Caller-saved scratch register |
| `r1..r3` | Argument/result registers; caller-saved |
| `r4..r6` | Callee-saved; `r6` may be a frame pointer |
| `r7` | Stack pointer; restored to its incoming value before return |
| `S0` | Architectural exception/link-suppression register; unavailable to ordinary allocation |
| `S1` | Runtime interrupt scratch; unavailable to ordinary allocation |
| `S2` | TLS anchor; unavailable to ordinary allocation |
| `S3..S4` | Caller-saved compiler-managed software-cache registers |
| `S5..S6` | Callee-saved compiler-managed software-cache registers |
| `S7` | Public C link register; call-clobbered |

`r0` is a normal general register, not a zero register. Instructions with an
implicit `r0` definition or use, including compare and branch instructions,
have their architectural clobber or dependency.

A callee restores incoming `r4..r6` and `S5..S6` before it returns. `S3` and
`S4` are caller-saved. The compiler uses the non-reserved S bank for links,
callee-saved GPR backups, and spill values; a value in `S3` or `S4` that must
survive a call is saved first. Hand-written code may use the same bank if it
obeys the call convention of every function it calls.

### RC32X register variant

RC32X applies only to RC32, but it is a separate ABI: an RC32X static link must
not contain ordinary RC32 objects. It retains the `r` and S-register roles
above, including the public `S7` link convention and the `r1..r3` C argument
and result slots. Its additional registers are allocatable
as follows:

| Register | ABI status |
|---|---|
| `x0..x7` | Caller-saved temporaries |
| `x8..x15` | Callee-saved registers |

No `x` register is a zero register, stack pointer, link register, or TLS
anchor. An RC32X callee that writes `x8..x15` restores their incoming values
before return. RC32X code may use every `x` register for allocation within a
function, but C arguments and results remain in the compact `r` registers so
that their common operations retain compact encodings.

### Nano register variant

Nano is an RC16-only configuration. It keeps the RC16 stack layout and data
model, but has no S-register bank. It uses the same `r1..r3` argument and
result slots as mainline. `r0..r3` and `r6` are caller-saved;
`r4` and `r5` are callee-saved; and `r7` is the fixed stack pointer. A call
delivers its return address in `r6`, which is not otherwise reserved. A
non-leaf function treats that address like any other live value, so the
compiler may move it to another register or spill it to the stack.

## 4. Calls, arguments, and results

The public mainline call forms are `JALL S7, target` where the selected profile
provides it, `JALR S7, register` for an indirect call, and `RET S7` for return.
RC16 Min materializes a direct target with `LUI`/`ORI`; RC32 Min uses `LDPC`.
Both then call through `JALR`. An RC32X caller whose indirect target is in an
`x` register may use `JALR S7,
[xN+0]`. Link values and function pointers are ordinary byte addresses.

A compiler may give a direct-only local function an object-private S-register
link convention (the current compiler selects `S3`); all direct callers and
the callee then use that same register. Architecturally, no S register other
than `S0` has a private-link-only function. Externally visible, address-taken,
and indirectly called functions always use the public `S7` convention. A
private convention is internal to one object and does not change its ABI.

Nano calls use `JALR r6, register`; direct calls materialize the instruction
address in `r0`. A Nano return uses `JALR r0, register`.
The return-address operand may be any GPR holding the saved incoming link;
`r0` as the destination suppresses creation of a new link.

Mainline arguments occupy native slots, low word first: 16-bit slots in RC16
and 32-bit slots in RC32. `r1`, `r2`, and `r3` hold the first three slots.
Integer
values narrower than a slot are extended to the slot width according to
signedness. An argument is never split between registers and the stack: if all
of its slots do not fit in the remaining argument registers, it and every
following argument are stack arguments. The first stack argument is at `0(r7)`
on callee entry; following arguments use increasing addresses.

Scalar and aggregate results up to three native slots occupy `r1`, `r2`, and
`r3`, low word first: the maximum is six bytes in RC16 and twelve bytes in
RC32. A larger aggregate result uses a hidden pointer in `r1`; explicit
arguments then begin in `r2` and `r3`. The result pointer is
caller-owned and need not be returned separately. Nano uses this same slot
order.

There are no floating-point argument or result registers. A scalar `float`
occupies two RC16 slots or one RC32 slot. A scalar `double` or `long double`
occupies four RC16 slots or two RC32 slots. Aggregates containing floating
members follow the ordinary aggregate rules above; they do not acquire a
separate calling convention.

For a variadic function, its named parameters use the convention above.
Every unnamed argument is stack-passed, regardless of unused argument
registers. Named stack arguments come first; the first unnamed argument is at
the next native-slot boundary. Each unnamed argument occupies a
native-slot-rounded sequence of slots, low word first. There is no register
save area or register-argument home area.

`va_list` is a data pointer to the next unnamed argument: 16 bits in RC16 and
32 bits in RC32. `va_start` initializes that pointer to the first unnamed
argument after the named parameters. `va_arg` reads its requested type at the
current pointer, then advances by its native-slot-rounded size; all ABI type
alignments are at most the native slot size. `va_copy` creates an independent
copy of the current pointer. `va_end` has no runtime effect but must be called
for every initialized or copied list. C default argument promotions apply
before an unnamed argument is passed, and the usual C restrictions on the type
requested by `va_arg` apply.

Tail calls, dynamic `alloca`, and compiler-generated interrupt-function
calling conventions are outside ABI v0.

## 5. Thread-local storage

Nano does not support TLS. The remainder of this section applies only to
mainline profiles.

`S2` is the native-width byte-addressed memory anchor for the current
thread. C TLS occupies non-negative offsets from `S2`; negative offsets are
outside the C TLS ABI and may be used by an interrupt or context-switch
runtime.

ABI v0 supports only C `__thread` and `_Thread_local` objects in the static
local-exec model. A TLS address is `S2 + TPOFF(symbol)`. Mainline code loads a
native-width TPOFF literal using the RC16 `R_RISCC_TPOFF_LO8` and
`R_RISCC_TPOFF_HI8` pair or `R_RISCC_TPOFF32`; RC32X may instead use an I16
pair. Assembly spells the expression `tpoff(symbol)`. A TPOFF relocation must
name an `STT_TLS` symbol.
Dynamic TLS, initial-exec and general-dynamic TLS models, PIC TLS, and shared
links are not supported.

## 6. Pointers and address materialization

Object and function pointers are native-width byte addresses in one
architectural address space: 16 bits in RC16 and 32 bits in RC32. Zero is the
null pointer representation. Converting between object and function pointer
representations does not shift, tag, or otherwise transform the address.
Executable storage may be read through an object pointer when the platform
marks that region readable.

ELF symbol values and section offsets are byte addresses. A static initializer
may refer to either code or data with the same `R_RISCC_ABS16` or
`R_RISCC_ABS32` relocation appropriate to the target width. Function symbols
and control-flow relocations additionally require two-byte alignment.

RC16 materializes a 16-bit address or literal directly:

```text
LUI rd, hi8(value)
ORI rd, lo8(value)
```

The instructions use `R_RISCC_HI8` and `R_RISCC_LO8`; the code-named aliases
perform the additional function-alignment check without changing the value.

RC32 normally materializes a native-width address or word-sized constant from
a nearby literal pool:

```text
LDPC rd, literal
...
.balign XLEN/8
literal: native_word value
```

`R_RISCC_PCREL8_WORD` encodes the halfword-scaled displacement from
`pc_next` to the literal. RC32 literal entries are four-byte aligned; the
compiler or assembler places pools at reachable safe points. The literal
itself uses `R_RISCC_ABS16` or `R_RISCC_ABS32` when it contains an address.
After loading a function address, a call uses `JALR`. There is no PIC code
model.

The `sys` and `full` profiles may use `JALL` for aligned absolute targets
that fit its field. Min has no direct long call. RC32X may additionally
materialize constants with its I16 operations and PC-relative targets with
`AUIPC` plus long `JALR`.

## 7. ELF object ABI

All RISC-C objects are ELF32 little-endian. Every object uses provisional
`EM_RISCC = 0xc8c8`. `e_flags` has ABI bits
`EF_RISCC_ABI_V0 = 0x01`, one profile field, and the following
configuration bits:

| Configuration | `e_flags` bit |
|---|---:|
| RC16 | `0x000` |
| RC32 | `EF_RISCC_RC32 = 0x100` |
| RC32X requirement | `EF_RISCC_RC32X = 0x200` |

| Profile | `e_flags` profile value |
|---|---:|
| `full` | `0x10` |
| `min` | `0x20` |
| `sys` | `0x30` |
| `nano` | `0x40` |

The ABI field is `0x0f`, the profile field is `0xf0`, and the configuration
field is `0x300`; unknown bits are not defined by ABI v0. `EF_RISCC_RC32X`
requires `EF_RISCC_RC32`. RC32 objects must use ELF32 and carry
`EF_RISCC_RC32`; RC16 and Nano objects must use ELF32 and must not carry
either configuration bit. An object produced with `-mrc32x`, or which contains
an RC32X instruction, must also carry `EF_RISCC_RC32X`. Nano must not be combined
with RC32 or RC32X.

Mainline objects in one static link must agree on ABI version and on RC16,
RC32, or RC32X. A static link may combine `min`, `sys`, and `full` objects of
the same ABI; its output profile is the highest required capability, ordered
`min < sys < full`. An RC32X link may contain only RC32X objects and carries
`EF_RISCC_RC32X`, which requires RC32X at run time. An all-Nano link retains the
Nano profile flag.

TLS definitions and references use `STT_TLS`. A linker must reject a TPOFF
relocation against a non-TLS symbol and must reject TPOFF relocations in a
shared or PIC link.

| Relocation | Number | Value written |
|---|---:|---|
| `R_RISCC_NONE` | 0 | no operation |
| `R_RISCC_ABS8` | 1 | range-checked 8-bit byte address or value |
| `R_RISCC_ABS16` | 2 | low 16 bits of `S + A` |
| `R_RISCC_ABS32` | 3 | low 32 bits of `S + A` |
| `R_RISCC_LO8` | 4 | low 8 bits of `S + A` |
| `R_RISCC_HI8` | 5 | bits 15:8 of `S + A` |
| `R_RISCC_CODE16` | 6 | compatibility alias of `R_RISCC_ABS16`; function symbol must be aligned |
| `R_RISCC_CODE_LO8` | 7 | compatibility alias of `R_RISCC_LO8`; function symbol must be aligned |
| `R_RISCC_CODE_HI8` | 8 | compatibility alias of `R_RISCC_HI8`; function symbol must be aligned |
| `R_RISCC_PCREL8_WORD` | 9 | signed halfword-scaled displacement from `pc_next` |
| `R_RISCC_TPOFF_LO8` | 10 | RC16: low 8 bits of `TPOFF(symbol)` |
| `R_RISCC_TPOFF_HI8` | 11 | RC16: bits 15:8 of `TPOFF(symbol)` |
| `R_RISCC_CODE32` | 12 | compatibility alias of `R_RISCC_ABS32`; function symbol must be aligned |
| `R_RISCC_HI16` | 13 | RC32X: rounded high 16 bits of `S + A` |
| `R_RISCC_LO16` | 14 | RC32X: low 16 bits of `S + A` |
| `R_RISCC_CODE_HI16` | 15 | RC32X compatibility code alias of `R_RISCC_HI16` |
| `R_RISCC_CODE_LO16` | 16 | RC32X compatibility code alias of `R_RISCC_LO16` |
| `R_RISCC_JALL21` | 17 | RC32: split 21-bit absolute byte address in `JALL` |
| `R_RISCC_PCREL13_WORD` | 18 | RC32X: signed long-branch displacement in halfwords from `pc_next` |
| `R_RISCC_TPOFF32` | 19 | RC32: 32-bit `TPOFF(symbol)` literal |
| reserved | 20 | reserved |

For `R_RISCC_PCREL8_WORD`, let `P` be the byte address of the compact
instruction and let `D = (S + A - P - 2) / 2`. `D` must fit signed eight
bits. Compact branches encode `{D[6:0], D[7]}`; RC32 `LDPC` uses the same
rotated field. An RC32 `LDPC` relocation additionally verifies that `S + A`
is four-byte aligned. For
`R_RISCC_PCREL13_WORD`, `P` is the address of the
first long-instruction halfword and the checked value is
`(S + A - P - 4) / 2`.

For an RC32X `HI16`/`LO16` pair, let `V = S + A` modulo `2^32`.
`HI16` writes `((V + 0x8000) >> 16) & 0xffff`; `LO16` writes
`V[15:0]`. The low half is interpreted as signed by `ADDI`. Code-named
compatibility relocations use exactly the same byte-address value and add only
the function-alignment check; there is no separate code-address domain.

## 8. Compatibility boundary

This ABI defines interoperable static objects for the stated target
configurations and profiles. RC16 and RC32 objects are incompatible because
their C data layouts, stack slots, and pointer widths differ. RC32X
is a distinct ABI with its own callee-saved `x` registers; it is not linkable
with ordinary RC32 objects, even where the argument and result slots coincide.
ABI v0 revisions may be mutually incompatible; all objects in a static link
must be rebuilt with a matching ABI v0 revision.

It does not define memory protection, privilege, board memory maps, startup
code, linker-script layout, interrupt dispatch, scheduler context layout,
library APIs, or data-image transport. Those operational interfaces are
described by the [Programming manual](PROGRAMMING.md).

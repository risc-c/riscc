# RISC-C C and Object ABI

This document is the normative version 1 ABI for freestanding C objects for
mainline RISC-C and its separately linkable Nano profile. Instruction
semantics and architectural state are specified only by the
[RISC-C ISA specification](RISC-C-ISA.md).

## 1. Scope and target identity

ABI v1 identifies the target as `riscc-none-elf`. The compiler defaults to
`-mcpu=full` and also supports the mainline `sys` and `min` profiles and the
incompatible `nano` profile. An ABI-v1 object may be linked for either a
unified physical memory or distinct instruction and data memories; that choice
does not change the object ABI.

ABI v1 is little-endian. It defines C calls, including variadic calls, static
local-exec TLS, and static ELF links. It does not define a hosted environment,
dynamic linking, PIC, exceptions, unwinding, atomics, or a C++ runtime.

## 2. C data model and alignment

| C type | Size | ABI alignment |
|---|---:|---:|
| `char`, `_Bool` | 1 byte | 1 byte |
| `short`, `int` | 2 bytes | 2 bytes |
| `long` | 4 bytes | 2 bytes |
| `long long` | 8 bytes | 2 bytes |
| object pointer | 2 bytes | 2 bytes |
| function pointer | 2 bytes | 2 bytes |
| `float` | 4 bytes | 2 bytes |
| `double`, `long double` | 8 bytes | 2 bytes |

Objects and aggregate members use their natural alignment from this table,
capped at two bytes. Padding in aggregates follows the ordinary C layout and
is not required to have a value when passed or returned.

`float` uses IEEE 754 binary32. `double` and `long double` both use IEEE 754
binary64; there is no extended `long double` representation. Floating-point
objects have the same little-endian, low-word-first representation in every
profile.

## 3. Stack and registers

The data stack is byte addressed and grows toward lower addresses. `r7` is
two-byte aligned at every C call boundary. There is no red zone and no
register-argument home area. The caller removes stack arguments.

| Register | ABI status |
|---|---|
| `r0` | Allocatable, caller-saved general register |
| `r1..r4` | Argument/result registers; caller-saved |
| `r5..r6` | Callee-saved; `r6` may be a frame pointer |
| `r7` | Stack pointer at C call boundaries; caller-saved otherwise |
| `S0`, `S1` | Interrupt-volatile; unavailable to ordinary allocation |
| `S2` | TLS anchor; unavailable to ordinary allocation |
| `S3..S6` | Compiler-managed software cache; call-clobbered |
| `S7` | Public C link register and compiler-managed software cache; call-clobbered |

`r0` is a normal general register, not a zero register. Instructions with an
implicit `r0` definition or use, including compare and branch instructions,
have their architectural clobber or dependency.

A callee restores incoming `r5` and `r6` before it returns. `S3..S7` are not
callee-saved. The compiler uses them for links, callee-saved GPR backups, and
short-lived spill values; a value that must survive a call is saved first.
Hand-written code may use the same bank if it obeys the call convention of
every function it calls.

### Nano register variant

Nano keeps the same stack layout, argument/result registers, and data model,
but has no S-register bank. `r7` is the fixed stack pointer, `r5` is
callee-saved, and `r0..r4` plus `r6` are caller-saved and allocatable. A call
delivers its return address in `r6`; `r6` is not otherwise reserved. A
non-leaf function treats that address like any other live value, so the
compiler may move it to another register or spill it to the stack.

## 4. Calls, arguments, and results

The public call forms are `JAL16 S7, target` for a direct call, `JAL S7,
register` for an indirect call, and `RET S7` for return. The link value and a
function pointer are instruction-word addresses.

A compiler gives a direct-only local function the private `S3` link register;
all direct callers and the callee then use that same register.
Externally visible, address-taken, and indirectly called functions always use
the public `S7` convention. This private convention is internal to one object
and does not change its ABI.

Nano calls use `JAL r6, register`; direct calls first materialize the
instruction-word address in a GPR. A Nano return uses `JAL r0, register`.
The return-address operand may be any GPR holding the saved incoming link;
`r0` as the destination suppresses creation of a new link.

Arguments occupy 16-bit slots, low word first. `r1`, `r2`, `r3`, and `r4`
hold the first four slots. Integer values narrower than a slot are extended
to 16 bits according to signedness. An argument is never split between
registers and the stack: if all of its slots do not fit in the remaining
argument registers, it and every following argument are stack arguments.
The first stack argument is at `0(r7)` on callee entry; following arguments
use increasing addresses.

Scalar and aggregate results up to eight bytes occupy `r1..r4`, low word
first. A larger aggregate result uses a hidden pointer in `r1`; explicit
arguments then begin in `r2`. The result pointer is caller-owned and need not
be returned separately.

There are no floating-point argument or result registers. A scalar `float`
occupies two ordinary slots and a scalar `double` or `long double` occupies
four. Aggregates containing floating members follow the ordinary aggregate
rules above; they do not acquire a separate calling convention.

For a variadic function, its named parameters use the convention above.
Every unnamed argument is stack-passed, regardless of unused argument
registers. Named stack arguments come first; the first unnamed argument is at
the next two-byte slot. Each unnamed argument occupies an even-byte sequence
of 16-bit slots, low word first, and is rounded up to a two-byte size. There
is no register save area or register-argument home area.

`va_list` is a 16-bit data pointer to the next unnamed argument. `va_start`
initializes that pointer to the first unnamed argument after the named
parameters. `va_arg` reads its requested type at the current pointer, then
advances by its two-byte-rounded size; all ABI type alignments are at most two
bytes. `va_copy` creates an independent copy of the current pointer.
`va_end` has no runtime effect but must be called for every initialized or
copied list. C default argument promotions apply before an unnamed argument is
passed, and the usual C restrictions on the type requested by `va_arg` apply.

Tail calls, dynamic `alloca`, and compiler-generated interrupt-function
calling conventions are outside ABI v1.

## 5. Thread-local storage

Nano does not support TLS. The remainder of this section applies only to
mainline profiles.

`S2` is the 16-bit byte-addressed data-memory anchor for the current thread.
C TLS occupies non-negative offsets from `S2`; negative offsets are outside
the C TLS ABI and may be used by an interrupt or context-switch runtime.

ABI v1 supports only C `__thread` and `_Thread_local` objects in the static
local-exec model. A TLS address is `S2 + TPOFF(symbol)`. TLS references use
the paired `R_RISCC_TPOFF_LO8` and `R_RISCC_TPOFF_HI8` relocations; assembly
spells the expression `tpoff(symbol)`. A TPOFF relocation must name an
`STT_TLS` symbol. Dynamic TLS, initial-exec and general-dynamic TLS models,
PIC TLS, and shared links are not supported.

## 6. Code and data pointers

Data pointers are 16-bit byte addresses in data memory. Function pointers
are 16-bit values containing a zero-extended 15-bit instruction-word address.
Zero is the null pointer representation in each pointer domain.

An ordinary C runtime conversion from a function pointer to an object pointer
maps the word address to a byte address by shifting left one. The inverse
conversion shifts a byte address right one. These conversions are
implementation-defined and do not make instruction memory readable through a
data pointer. ABI v1 does not support link-time constant initializers that
cross these pointer domains.

ELF symbol values and section offsets remain byte based. Code relocations
therefore validate two-byte alignment and encode a code-word value; data
relocations encode a data byte address. A relocation may not be used in the
wrong address domain.

## 7. ELF object ABI

Objects are ELF32 little-endian with provisional `EM_RISCC = 0xc8c8`.
`e_flags` has ABI bits `EF_RISCC_ABI_V1 = 0x01` and one profile field:

| Profile | `e_flags` profile value |
|---|---:|
| `full` | `0x10` |
| `min` | `0x20` |
| `sys` | `0x30` |
| `nano` | `0x40` |

The ABI field is `0x0f` and the profile field is `0xf0`; unknown bits are not
defined by ABI v1. Mainline objects must agree on the ABI version. A static
link may combine `min`, `sys`, and `full` objects; its output profile is the
highest required capability, ordered `min < sys < full`. `nano` has an
incompatible link-register convention and is not C-ABI compatible with
mainline objects. A static link may contain only Nano objects or only mainline
objects; an all-Nano output retains the Nano profile flag.

TLS definitions and references use `STT_TLS`. A linker must reject a TPOFF
relocation against a non-TLS symbol and must reject TPOFF relocations in a
shared or PIC link.

| Relocation | Number | Value written |
|---|---:|---|
| `R_RISCC_NONE` | 0 | no operation |
| `R_RISCC_ABS8` | 1 | range-checked 8-bit data-domain byte address |
| `R_RISCC_ABS16` | 2 | low 16 bits of a data-domain byte address |
| `R_RISCC_ABS32` | 3 | zero-extended 16-bit data-domain byte address |
| `R_RISCC_LO8` | 4 | low 8 bits of a data-domain byte address |
| `R_RISCC_HI8` | 5 | bits 15:8 of a data-domain byte address |
| `R_RISCC_CODE16` | 6 | 16-bit code-word address |
| `R_RISCC_CODE_LO8` | 7 | low 8 bits of a code-word address |
| `R_RISCC_CODE_HI8` | 8 | bits 15:8 of a code-word address |
| `R_RISCC_PCREL8_WORD` | 9 | signed PC-relative code-word displacement |
| `R_RISCC_TPOFF_LO8` | 10 | low 8 bits of `TPOFF(symbol)` |
| `R_RISCC_TPOFF_HI8` | 11 | bits 15:8 of `TPOFF(symbol)` |

For code relocations, the code-word address is `(S + A) >> 1`, after the
alignment and 15-bit code-range checks. For `R_RISCC_PCREL8_WORD`, the linker
writes the checked signed displacement from the next instruction in words,
`(S + A - P - 2) / 2`, where `P` is the branch instruction address. `ABS*`,
`LO8`, and `HI8` are data-domain relocations; `CODE*` and `PCREL8_WORD` are
code-domain relocations. `TPOFF_*` are TLS-domain relocations only.

## 8. Compatibility boundary

This ABI defines interoperable static objects for the stated target and
profiles. It does not define memory protection, privilege, board memory maps,
startup code, linker-script layout, interrupt dispatch, scheduler context
layout, library APIs, or data-image transport. Those operational interfaces
are described by the [Programming manual](PROGRAMMING.md).

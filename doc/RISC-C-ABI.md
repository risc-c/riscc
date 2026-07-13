# RISC-C C and Object ABI

This document is the normative version 1 ABI for freestanding C objects for
mainline RISC-C. Instruction semantics and architectural state are specified
only by the [RISC-C ISA specification](RISC-C.md).

## 1. Scope and target identity

ABI v1 identifies the target as `riscc-none-elf`. The initial compiler
configuration is `-mcpu=full`. An ABI-v1 object may be linked for either a
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
| `S3` | Runtime-reserved; unavailable to ordinary allocation |
| `S4..S6` | Unallocated by the C ABI |
| `S7` | C link register; call-clobbered and unallocated as a general register |

`r0` is a normal general register, not a zero register. Instructions with an
implicit `r0` definition or use, including compare and branch instructions,
have their architectural clobber or dependency.

A callee restores incoming `r5` and `r6` before it returns. `S7` is not
callee-saved: a non-leaf C function preserves the link value it needs before
making a call. Hand-written code may use an unallocated S register as a link
register only if it preserves every live value required by its own convention.

## 4. Calls, arguments, and results

The standard call forms are `JAL16 S7, target` for a direct call, `JAL S7,
register` for an indirect call, and `RET S7` for return. The link value and a
function pointer are instruction-word addresses.

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

`S2` is the 16-bit byte-addressed data-memory anchor for the current thread.
C TLS occupies non-negative offsets from `S2`; negative offsets are outside
the C TLS ABI. `S3` is reserved for runtime use.

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
mainline objects.

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

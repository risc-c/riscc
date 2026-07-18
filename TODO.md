# Compiler TODO

The current baseline supports freestanding C for `riscc-none-elf` across the
`full`, `sys`, `min`, and `nano` profiles, static local-exec TLS, ordinary and
aggregate calls, function pointers, 16/32/64-bit integer operations, and
software binary32/binary64 at `-O0`, `-O2`, and `-Os`. The feature suites under
`test/compiler/` are the executable correctness baseline. Run the focused
toolchain checks with:

```sh
make -j16 check-llvm-riscc
make -j16 test-compiler-profiles-iss
```

## Language and ABI support

- [x] Support and regression-test the `full`, `sys`, `min`, and `nano`
  compiler profiles. Full, Sys, and Min share the mainline ABI; Nano has its
  deliberately incompatible reduced-register ABI.
- [x] Define and implement the variadic ABI.
  - Keep named arguments on the ordinary register/stack convention.
  - Prefer placing every unnamed argument on the stack to avoid a register
    argument home area.
  - Define `va_list`, `va_start`, `va_arg`, `va_copy`, and `va_end` behavior.
  - Add Clang Sema/CodeGen, LLVM lowering, cross-TU ABI, and ISS tests.
- [x] Add soft-float support.
  - Lower scalar and aggregate binary32/binary64 arguments and results through
    the ordinary 16-bit ABI slots.
  - Supply compiler-rt arithmetic, conversion, and comparison helpers as
    separately extractable runtime objects.
  - Cover float, double, long double, NaNs, varargs, wide conversions, and
    mixed integer/float ABI calls on every profile at every tested optimization
    level.
- [ ] Define and test the supported freestanding C++ subset.
  - Cover name mangling, member calls, trivial classes and aggregates, and
    cross-translation-unit calls.
  - Decide whether startup runs global constructors and destructors.
  - Explicitly diagnose or document unsupported non-trivial object passing,
    guard variables, `new`/`delete`, exceptions, RTTI, and runtime facilities.
- [x] Keep VLA and dynamic `alloca` as deliberate non-features; fixed-size
  stack objects remain supported.
- [x] Keep C atomics unsupported; use explicit non-nesting `CLI`/`STI`
  critical sections for coordination between main code and interrupt handlers.
- [x] Keep interrupt entry in assembly; do not add a compiler interrupt
  attribute or calling convention. The assembly wrapper may call ordinary C
  handlers.
- [x] Validate the minimal inline-assembly constraint and clobber interface.

## Code generation and optimization

- [x] Optimize common scalar code without adding target-specific passes:
  immediate materialization, comparisons, zero-valued selects, indexed loads,
  constant multiplication, profile-specific shifts, and small stack frames.
- [x] Keep the profile implementation shared. Model instruction capabilities
  as subtarget features and isolate Nano differences to its register ABI and
  missing instructions.
- [x] Keep Nano's `r6` link/return register allocatable outside its fixed ABI
  uses. Reserve only the `r7` stack pointer among GPRs; special registers stay
  outside ordinary allocation.
- [ ] Add profitable switch jump-table lowering while retaining branch chains
  for small or sparse switches.
- [x] Implement and validate eligible tail calls.
- [ ] Improve wide-integer lowering to avoid unnecessary runtime calls and
  reduce helper overhead.
- [x] Add call/branch relaxation and other size optimizations where linker
  range and address-domain rules permit them.
- [ ] Measure generated code size, instruction count, and ISS cycles across
  every profile at `-O0`, `-O2`, and `-Os` using stable compiler workloads.
  Require a measurable benefit before adding further custom combines or
  post-RA optimizations.
- [ ] Validate `-flto` with lld, section GC, runtime archives, function
  pointers, and every compiler profile.
- [ ] Validate debug information, stack frames, and source-level debugging.

## LLVM verification

- [x] Add a target that runs the RISCC LLVM, Clang, and lld `lit` regression
  directories with `FileCheck`.
- [x] Add an all-profile compiler-to-ISS regression target.
- [x] Exhaustively cross-check Full-profile MC encodings against the project
  assembler.
- [ ] Extend the exhaustive MC oracle to Nano-specific encodings and pseudos.
- [ ] Run representative compiler-generated images on Sys and Min RTL so every
  compiler profile has matching end-to-end hardware coverage.
- [ ] Add explicit static-linker tests for weak symbols, aliases, archive
  ordering, section GC, relocatable links, and mixed-profile archive members.
- [ ] Add negative tests for every deliberately unsupported ABI feature.
- [ ] Run a filtered integer-only subset of LLVM Test Suite through the ISS.
- [ ] Add reduced-input MultiSource applications after the runtime interface is
  sufficient.
- [ ] Track code size and runtime separately from correctness results.

## ABI and toolchain stabilization

- [ ] Replace or formally register the provisional `EM_RISCC = 0xc8c8`
  machine ID and relocation namespace before freezing ABI v1.
- [ ] Define the compatibility policy for ABI revisions and add tests that
  link objects produced by the oldest supported toolchain revision.
- [ ] Validate installation or packaging of Clang, lld, startup objects,
  profile-matched runtime archives, headers, and application Makefile support
  outside the source tree.

## Runtime and ISS prerequisites for broader compiler testing

- [ ] Pass `argc` and `argv` from the ISS runner through startup to `main`.
- [ ] Convert the return value from `main`, `exit`, and `abort` into a host
  process status.
- [x] Add public freestanding headers and basic string, assertion, and heap
  support.
- [x] Add an integer-only formatted-I/O implementation after variadics work.
- [x] Add a small software `libm` with classification, sign manipulation,
  rounding, min/max/difference, decomposition/scaling, adjacent values,
  square root, and remainder for binary32/binary64.
- [ ] Add a read-only filesystem over a generic flash-read interface.
  - Generate deterministic filesystem images under `build/`.
  - Model flash in the ISS and use a board-specific QSPI backend in hardware.
  - Start with `fopen`, `fread`, `fgetc`, `fgets`, `fseek`, `ftell`, `feof`,
    and `fclose` in read-only mode.
- [ ] Add optional file/time semihosting only for tests that cannot use the
  read-only flash image and architectural cycle counts.

## Deferred or explicit non-goals

- PIC, PIE, shared objects, dynamic linking, and dynamic TLS models.
- Hosted-process facilities, virtual memory, and a general-purpose OS.
- C++ exceptions, RTTI, unwinding, and a full C++ runtime.
- A comprehensive `libm` (transcendentals, alternate rounding modes, and the
  floating-point environment) until applications require it.
- Writable flash filesystems until a real application requires them.
- Nano compatibility with the mainline C ABI.

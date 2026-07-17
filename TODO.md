# Compiler TODO

The current baseline supports freestanding integer C for `riscc-none-elf`
across the `full`, `sys`, `min`, and `nano` profiles, static local-exec TLS,
ordinary and aggregate calls, function pointers, and 16/32/64-bit integer
operations at `-O0`, `-O2`, and `-Os`. The feature suite under
`test/compiler/` is the executable correctness baseline.

## Language and ABI support

- [x] Define and implement the variadic ABI.
  - Keep named arguments on the ordinary register/stack convention.
  - Prefer placing every unnamed argument on the stack to avoid a register
    argument home area.
  - Define `va_list`, `va_start`, `va_arg`, `va_copy`, and `va_end` behavior.
  - Add Clang Sema/CodeGen, LLVM lowering, cross-TU ABI, and ISS tests.
- [ ] Add soft-float support.
  - Confirm scalar and aggregate float/double argument and result lowering.
  - Supply the required compiler-rt arithmetic, conversion, and comparison
    helpers.
  - Add float, double, long double, and mixed integer/float ABI tests.
- [x] Keep VLA and dynamic `alloca` as deliberate non-features; fixed-size
  stack objects remain supported.
- [x] Keep C atomics unsupported; use explicit non-nesting `CLI`/`STI`
  critical sections for coordination between main code and interrupt handlers.
- [x] Keep interrupt entry in assembly; do not add a compiler interrupt
  attribute or calling convention. The assembly wrapper may call ordinary C
  handlers.
- [x] Validate the minimal inline-assembly constraint and clobber interface.

## Code generation and optimization

- [ ] Add profitable switch jump-table lowering while retaining branch chains
  for small or sparse switches.
- [x] Implement and validate eligible tail calls.
- [ ] Improve wide-integer lowering to avoid unnecessary runtime calls and
  reduce helper overhead.
- [x] Add call/branch relaxation and other size optimizations where linker
  range and address-domain rules permit them.
- [ ] Measure generated code size and instruction count across `-O0`, `-O2`,
  and `-Os` using stable compiler workloads.
- [ ] Validate debug information, stack frames, and source-level debugging.

## LLVM verification

- [x] Add a target that runs the RISCC LLVM, Clang, and lld `lit` regression
  directories with `FileCheck`.
- [ ] Keep MC encoding verification exhaustive against the project assembler.
- [ ] Add negative tests for every deliberately unsupported ABI feature.
- [ ] Run a filtered integer-only subset of LLVM Test Suite through the ISS.
- [ ] Add reduced-input MultiSource applications after the runtime interface is
  sufficient.
- [ ] Track code size and runtime separately from correctness results.

## Runtime and ISS prerequisites for broader compiler testing

- [ ] Pass `argc` and `argv` from the ISS runner through startup to `main`.
- [ ] Convert the return value from `main`, `exit`, and `abort` into a host
  process status.
- [x] Add public freestanding headers and basic string, assertion, and heap
  support.
- [x] Add an integer-only formatted-I/O implementation after variadics work.
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
- Writable flash filesystems until a real application requires them.
- Nano compatibility with the mainline C ABI.

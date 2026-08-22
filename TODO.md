# Project TODO

This file lists active project work only. Completed, rejected, and speculative
ideas are not retained here.

Tasks marked *HIGH* are the near-term priorities.

## Validation gaps

- [ ] *HIGH* Run compiler-generated RC16 Min and Sys programs on matching RTL,
  including calls, aggregates, variadics, TLS where available, and `-O0`,
  `-O2`, and `-Os` builds.
- [ ] Add RC16 execution and relocation tests at the upper end of the 64 KiB
  byte-address space, including control transfers across `0x8000` and targets
  near `0xfffe`.
- [ ] Add exhaustive LLVM MC encoding coverage for the Nano profile.

## RC32

- [ ] *HIGH* Run compiler-generated C and supported freestanding C++ programs
  on the RC32 Min ISS and RTL at `-O0`, `-O2`, and `-Os`. Cover startup, calls,
  aggregates, variadics, TLS, cross-translation-unit links, and literal-pool
  placement in long functions.
- [ ] Add RC32 application support to `firmware/riscc.mk`, including the RC32
  runtime archives, linker layout, executable application tests, and image
  generation.
- [ ] Implement RC32 Sys and Full RTL after the Min core and common memory
  interface are stable. Add interrupts, multiplication, optional MDU,
  differential traces, and PPA characterization.

## RC32X

- [ ] Implement the defined RC32X instruction formats in LLVM MC, the
  disassembler, ISS, encoding tests, and differential fuzzer.
- [ ] Implement the ABI v0 RC32X convention in LLVM/Clang/lld and the runtime,
  with executable calling-convention and object-compatibility tests. Keep
  `-mrc32x` rejected until this support is complete.
- [ ] Implement and characterize an RC32X reference core, including the cost of
  five-bit register selection and each long-instruction format.

## Compiler and release

- [ ] Improve RC16 code generation using measured workloads, initially
  focusing on wide integers and switch lowering.
- [ ] Define and test the supported freestanding C++ subset, including trivial
  classes, aggregates, and cross-translation-unit calls. Document and test the
  startup-constructor policy; keep exceptions, RTTI, and a full C++ runtime out
  of scope until required.
- [ ] Complete Nano application packaging in `firmware/riscc.mk`; select only
  Nano-compatible startup objects and libraries and add an end-to-end sample
  application build.
- [ ] Replace or register the provisional `EM_RISCC = 0xc8c8` machine ID and
  add installable toolchain/runtime packages after target and ABI naming
  stabilizes.

## Benchmarking

- [ ] Port CoreMark and a representative subset of Embench to the existing
  reproducible benchmark flow.
- [ ] Add focused instruction, branch/call, memory, and interrupt
  microbenchmarks with code-size, instruction-count, cycle, and stack/RAM
  reporting.
- [ ] Add automated regression limits for code size, cycles, area, and Fmax
  where the measurements are reproducible.

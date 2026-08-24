# Project TODO

This file lists active project work only. Completed, rejected, and speculative
ideas are not retained here.

## RC32

- [ ] Implement and characterize optional RC32 MulH and MulDiv RTL variants,
  with directed instruction/interrupt tests and ISS-versus-RTL fuzz coverage.
  The compiler, assembler, disassembler, and ISS already support RC32 MDU.

## RC32X

- [ ] Implement the defined RC32X instruction formats in LLVM MC, the
  disassembler, ISS, encoding tests, and differential fuzzer.
- [ ] Implement the ABI v0 RC32X convention in LLVM/Clang/lld and the runtime,
  with executable calling-convention and object-compatibility tests. Keep
  `-mrc32x` rejected until this support is complete.
- [ ] Implement and characterize an RC32X reference core, including the cost of
  five-bit register selection and each long-instruction format.

## Compiler and release

- [ ] Improve code generation using measured workloads, initially
  focusing on wide integers and switch lowering.
- [ ] Replace or register the provisional `EM_RISCC = 0xc8c8` machine ID and
  add installable toolchain/runtime packages after target and ABI naming
  stabilizes.

## Benchmarking

- [ ] Port CoreMark and a representative subset of Embench to the existing
  reproducible benchmark flow.
- [ ] Add focused instruction, branch/call, memory, and interrupt
  microbenchmarks with code-size, instruction-count, cycle, and stack/RAM
  reporting.

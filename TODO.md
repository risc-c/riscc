# Project TODO

This file lists active project work only. Completed work and distant ideas are
omitted.

Tasks marked *HIGH* are the near-term priorities.

## RC16 stabilization

- [ ] *HIGH* Support the ISA's full RC16 address ranges end to end: 64 KiB data
  and 128 KiB program space in the ABI and ELF model, assembler/disassembler,
  LLVM/Clang/lld, linker scripts and image tools, ISS and other simulators, and
  boundary tests. Remove accidental 15-bit code-address assumptions.
  Parameterize RTL physical address widths so small implementations may expose
  less memory, and add at least one full-range reference configuration.

- [ ] Evaluate `STP` only if a measured use case justifies its hardware and
  program-memory synchronization requirements.
- [ ] Prototype a Nano configuration where the GPR bank and data memory share
  one physical FPGA RAM block while remaining architecturally separate. Compare
  single- and dual-port schedules against existing Nano cores for RAM use,
  LUTs, Fmax, cycles, and benchmark performance.
- [ ] *HIGH* Close RC16 regression gaps: compiler-generated Sys and Min RTL images and
  exhaustive Nano LLVM MC encoding coverage.

## Core bus interface

- [ ] *HIGH* Define a common instruction/data transaction interface using Wishbone B4
  or a small directly compatible subset. It must provide byte selects,
  request/write signaling, stall or busy indication, completion, read data, and
  errors for arbitrary-latency memories and peripherals.
- [ ] *HIGH* Specify request stability, exactly-once completion, reset behavior,
  instruction/data arbitration, and a low-cost zero-wait-state path.
- [ ] *HIGH* Convert representative cores, shared SoCs, memories, and peripherals using
  native interfaces or simple bridges. Test randomized stalls, slow operations,
  back-to-back accesses, and errors; measure area and Fmax changes.

## RC32 bring-up

- [ ] *HIGH* Implement RC32 in the assembler, disassembler, and C++ ISS, including all
  mandatory compact and long instructions and 32-bit memory semantics.
- [ ] *HIGH* Add RC32 architectural and encoding tests plus differential fuzzing before
  broad RTL implementation.
- [ ] *HIGH* Define the RC32 data, object, and calling ABI: data layout, register use,
  stack and TLS layout, aggregates and variadics, ELF attributes, relocations,
  and code models.
- [ ] *HIGH* Bring up one correctness-first RC32 RTL core on the common bus and measure
  the wider datapath and long-instruction costs before extending every core
  family.
- [ ] *HIGH* Add initial RC32 LLVM/Clang/lld, startup, runtime, linker-script, and build
  support. Run C and supported C++ tests through the ISS and reference RTL at
  `-O0`, `-O2`, and `-Os`.

## X32

- [ ] Implement all defined X32 formats in the assembler, disassembler, ISS,
  encoding tests, and differential fuzzer.
- [ ] Define the X32 ABI, including use of the combined `r`, `S`, and `x`
  register namespace, what it inherits from RC32, and RC32/X32 object
  interoperability rules.
- [ ] Implement and characterize an X32 reference core, including the cost of
  five-bit register selection and long register, immediate, memory, branch, and
  U20 formats.
- [ ] Add X32 LLVM/Clang/lld register allocation, ABI lowering, instruction
  selection, MC, relocation, runtime, and linker support with executable ABI
  tests.
- [ ] Compare X32 and equivalent RV32 configurations using the same compiler
  workloads, tracking code size, instructions, cycles, area, and Fmax.

## Compiler and release

- [ ] Use measured workloads to improve RC16 code generation, initially focusing
  on wide integers and switch lowering.
- [ ] Define compiler and linker handling for program-memory constants and
  address spaces, then measure profitable `LDPH` use for constant pools and
  read-only tables on split-memory targets.
- [ ] Define and test the supported freestanding C++ subset, including trivial
  classes, aggregates, cross-TU calls, and the startup-constructor policy. Keep
  exceptions, RTTI, and a full C++ runtime out of scope until required.
- [ ] Complete Nano application packaging in `riscc.mk`.
- [ ] Replace or register the provisional `EM_RISCC = 0xc8c8` machine ID, define
  object compatibility rules, and add installable packages after target and ABI
  naming stabilizes.

## Benchmarking

- [ ] Build a reproducible benchmark runner for the ISS, representative RTL
  cores, and FPGA targets with fixed workloads, compiler options, and timing
  sources.
- [ ] Port CoreMark, suitable Embench workloads, and applicable standalone
  lmbench latency and bandwidth kernels.
- [ ] Add RISC-C microbenchmarks for instructions, branches and calls, memory and
  bus stalls, interrupts, context switches, synchronization, flash/filesystem
  access, and framebuffer traffic.
- [ ] Version results for code size, dynamic instructions, cycles, stack/RAM
  use, area, and Fmax, and flag meaningful compiler or RTL regressions.

## Peripheral and platform support

- [ ] Add SPI-flash controllers and simulation models on boards where flash is
  available to the running design.
- [ ] Add an SDRAM controller and model, then an SDRAM-backed framebuffer on
  Icepi Zero with defined CPU/video arbitration and addressing.

## Firmware

- [ ] Define a small `libos` API and implement single-core cooperative, then
  timer-preemptive threads with per-thread stacks, TLS, and complete ABI context
  switching. Decide Nano support separately.
- [ ] Add critical sections, mutexes, events or semaphores, and a blocking
  queue/wakeup primitive. Use interrupt masking and scheduler control initially;
  defer multicore synchronization until atomics and fences are designed.
- [ ] Make the allocator, relevant libc state, and shared BSP services
  thread-safe, with finite ISS and RTL tests for scheduling, TLS, blocking, and
  interrupt interaction.
- [ ] Add a flash/block-device API, host or ISS model, SPI-flash drivers, a
  minimal filesystem, deterministic image builder, and basic file operations.
- [ ] Update board demos to use OS threads, synchronization, SPI-flash filesystem
  assets, and the SDRAM framebuffer, with finite regression coverage.

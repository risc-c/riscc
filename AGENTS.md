# RISC-C

- RTL is Verilog (`.v`); preserve `default_nettype` and existing macro style.
- Preserve unrelated dirty-tree changes. Do not reset, checkout, or delete.
- Do not commit generated files or vendor checkouts. LLVM backend work lives
  in the `external/llvm-project` submodule on the `riscc-backend` branch;
  never vendor LLVM into this repository.
- Keep generated artifacts exclusively under `build/`; never leave tool
  databases, reports, images, memory initializers, or temporary files in the
  source tree.
- Do not create commits unless explicitly requested. Review the final diff
  before any requested commit, and never push to a remote.
- Keep `README.md` as the high-level project overview and manual navigation.
  Put detailed RTL, board, FPGA-flow, timing, and area material in
  `doc/HARDWARE.md`; put assembly, compiler, runtime, and application material
  in `doc/PROGRAMMING.md`.
- `doc/RISC-C-ISA.md` is the ISA specification. Do not change the ISA unless
  explicitly asked; keep it to normative ISA behavior, without history,
  platform, or implementation material.
- `doc/RISC-C-ABI.md` is the normative C/object ABI. Keep it concise and
  interoperable: do not put runtime, board, linker-script, or library policy
  there.
- Before finishing or committing an implementation or measurement change,
  regenerate affected numbers and update `doc/HARDWARE.md`. Compare them with
  the previous revision; do not build or benchmark `HEAD` merely for
  comparison.
- Reuse `build/llvm-riscc`; do not discard or rebuild it merely because a task
  has no LLVM source changes.  Its CMake C and C++ compiler launchers use the
  project's writable ccache selection.  Preserve that configuration and invoke
  LLVM through the Make target above rather than bypassing it with a fresh
  CMake configuration.

## Validation

Run the narrowest relevant target after an edit:

- Tiny: `make test-<width>-<profile>`
- Tiny16: `make test-16-<profile>`
- Nano: `make test-nano`
- Fast: `make test-fast`
- Faster: `make test-faster`
- Shared RF, assembler, test source, or profiles: `make test-all`
- Atum board RTL/demo: `make atum-a3-demo-rtlsim`

For CPI changes, run `make bench`; it runs all current RTL benchmarks. MIPS and
efficiency use Verilator RTL cycle counts, not ISS counts.

For resource/timing changes or published tables, run:

```sh
make -j16 tables
```

`tables` covers reproducible iCE40/ECP5 area and Fmax, published Agilex ALM
and Fmax tables, plus Tiny, Nano, Fast, and Faster RTL benchmarks. Building
the Atum FPGA image is deliberately separate: `make atum-a3-demo` produces
the SOF only when Quartus is configured. Agilex figures printed by the area
and Fmax reports are published Quartus characterizations.

## Optimization gates

- Do not accept an affected LUT/site increase or Fmax decrease without an
  explicit, measured compensating benefit.
- Tiny and Nano are area-first: preserve or reduce LUTs/sites.
- Fast is performance-per-LUT/LE oriented: improve throughput while keeping
  the implementation efficient. Accept extra logic when it produces a
  worthwhile measured MIPS-per-LUT/LE gain.
- Faster is the higher-performance variant: maximize measured MIPS, with area
  efficiency secondary to the performance target.

Agilex figures require Quartus Pro characterization. Set `QUARTUS_SH` to the
Quartus Pro `quartus_sh` executable when it is not on `PATH`. For requested
Agilex area/Fmax work, use that configured tool; do not infer that Quartus is
unavailable merely because a bare `quartus_sh` lookup fails.
`make atum-a3-demo` builds the Atum SOF. It needs a configured Quartus Pro
installation and is deliberately not an aggregate prerequisite.

Build the Icepi Zero demo with `make icepi-zero-demo-bit`. Hardware programming
requires explicit user approval:

```sh
openFPGALoader -cft231X --pins=7:3:5:6 build/icepi_zero/demo.bit
```

After programming, wait for USB devices to re-enumerate before connecting to
any serial or video interfaces.

Before broad RTL commits: run applicable tests/benchmarks/arrays, then
`git diff --check` and `git status --short`.

## Tables

- iCE40: LUT4; ECP5: label RF inclusion; Agilex: ALMs.
- Efficiency: MIPS/kLUT4 for iCE40/ECP5; MIPS/kLE for Agilex (2.95 LE/ALM).
- Nano's software-multiply benchmark is included in MIPS/efficiency tables;
  keep its separate instruction count visible when comparing results.

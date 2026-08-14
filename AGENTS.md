# RISC-C

- RTL is Verilog (`.v`); preserve `default_nettype` and macro style.
- Preserve unrelated dirty-tree changes. Do not reset, checkout, delete, commit
  generated files/vendor checkouts, or push. Commit only when explicitly asked.
- Keep generated artifacts under `build/`. LLVM backend work belongs in
  `external/llvm-project` on `riscc-backend`; reuse `build/llvm-riscc` and its
  configured ccache rather than making a fresh LLVM build.
- `README.md` is the overview; use `doc/HARDWARE.md` for RTL/board/PPA,
  `doc/PROGRAMMING.md` for software, `doc/RISC-C-ISA.md` for normative ISA,
  and `doc/RISC-C-ABI.md` for normative ABI. Change ISA only when asked.
- Refresh affected measurements and `doc/HARDWARE.md` before finishing an
  implementation or measurement change. Compare with recorded results, not a
  newly built `HEAD` baseline.

## Validation

Run the narrowest functional test after each edit:

- RC16 serial: `make test-<width>-<profile>`; RC16 wide: `make test-16-<profile>`
- Nano: `make test-nano`; Fast: `make test-fast`; Faster: `make test-faster`
- Shared RF, assembler, test, or profile changes: `make test-all`
- Atum RTL/demo: `make atum-a3-demo-rtlsim`

Every RTL change also needs its relevant fuzz target:

- RC16 serial/wide: `make fuzz-min`, `make fuzz-sys`, or `make fuzz-full`
- Nano: `make fuzz-nano`; RC32: `make fuzz-rc32`
- Fast: `make fuzz-fast`; add `make fuzz-fast-ice` for synchronous-RF or
  iCE40-specific changes
- Faster has no trace-differential fuzzer: run focused tests and benchmarks.

Before every commit or release, run `make test-all` and all applicable fuzz
targets; report the commands and results. For CPI changes run `make bench`;
use Verilator RTL cycle counts for MIPS/efficiency.

Check RTL changes for LUT/site and Fmax regressions with the narrowest affected
area/Fmax targets. For shared logic, multiple configurations, or published PPA,
run `make -j16 tables` and compare prior recorded results.

## Optimization gates

- Prefer generic structural improvements across widths, profiles, and targets.
- Mapper/P&R variation and seed luck are noise: use reproducible measurements,
  compare identical configurations/seeds, and do not change seeds for a better
  number.
- Avoid configuration-specific `if`/`else` mazes and synthesis-steering source
  variants. Specialize only for a real architectural need or a reproducible
  benefit unavailable from a generic form.
- Reject affected LUT/site increases or Fmax decreases without a measured
  compensating benefit. RC16/Nano are area-first; Fast targets MIPS-per-LUT/LE;
  Faster prioritizes MIPS.

Quartus Pro is required for Agilex characterization. Set `QUARTUS_SH` to the
configured executable when needed; `make atum-a3-demo` builds the SOF but is
not an aggregate prerequisite. Build Icepi Zero with `make icepi-zero-demo-bit`.
Hardware programming needs explicit approval; after programming, wait for USB
re-enumeration before connecting serial/video interfaces.

Before broad RTL commits also run `git diff --check` and `git status --short`.

## Tables

- iCE40: LUT4; ECP5: label RF inclusion; Agilex: ALMs.
- Efficiency: MIPS/kLUT4 for iCE40/ECP5; MIPS/kLE for Agilex (2.95 LE/ALM).

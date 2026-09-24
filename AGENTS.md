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
- Documentation is for human readers, not an agent's implementation log.
  Describe the current design, usage, constraints, and measurements concisely.
  Omit session narratives, optimization diaries, self-justification, temporary
  artifact inventories, and test-run transcripts. Keep working notes and raw
  logs under `build/`; report task progress and validation in the conversation.
- Refresh affected measurements and `doc/HARDWARE.md` before finishing an
  implementation or measurement change. Compare with recorded results, not a
  newly built `HEAD` baseline.

## Validation

Run the narrowest functional test after each edit:

- RC16: `make test-core PROFILE=<profile> WIDTH=<width>`
- Nano: `make test-nano`; Fast: `make test-fast-all test-fast-irq-all`
- Cached: `make test-cached-all test-cached-irq-all`
- Shared RF, assembler, test, or profile changes: `make test-all`
- Atum RTL/demo: `make atum-a3-demo-rtlsim`

Every RTL change also needs its relevant fuzz target:

- RC16 and Nano: `make fuzz`; RC32: `make fuzz-rc32`
- Fast, including synchronous ECP5 block-RF cases: `make fuzz-fast fuzz-fast32`
  It uses final written-memory comparison and the generated program's
  architectural self-check because Fast has no retirement-trace interface.
- Cached: `make fuzz-cached fuzz-cached32`, with the same architectural checks
  through the internal caches.

Before every commit or release, run `make test-all` and all applicable fuzz
targets; report the commands and results. For CPI changes run `make bench`;
use Verilator RTL cycle counts for MIPS/efficiency.

Check RTL changes with the narrowest generated result, for example
`make build/area/ecp5-block/rc16/sys/4.lut` or
`make build/fmax/ecp5/rc32/min/8.mhz`. For shared logic, multiple
configurations, or published PPA, run `make -j16 tables` and compare prior
recorded results.

## Optimization gates

- Prefer generic structural improvements across widths, profiles, and targets.
- Mapper/P&R variation and seed luck are noise: use reproducible measurements,
  compare identical configurations/seeds, and do not change seeds for a better
  number.
- Avoid configuration-specific `if`/`else` mazes and synthesis-steering source
  variants. Specialize only for a real architectural need or a reproducible
  benefit unavailable from a generic form.
- Reject affected LUT/site increases or Fmax decreases without a measured
  compensating benefit. RC16/Nano are area-first; Fast targets MIPS per LUT/LE.
- For compiler and runtime optimizations, give RC16 and RC32 equal weight.
  Compare speed and linked code size separately at speed and size optimization
  levels. Use per-benchmark ratios within each core/configuration; summed raw
  cycles let long-running workloads dominate. Show results with and without
  the motivating benchmark, and list regressions even when the average improves.
- Justify tradeoffs by the general code pattern and representative workloads,
  including short/common cases and adverse cases for runtime helpers. A
  Dhrystone gain alone does not justify a broad heuristic change, but a
  generally applicable optimization is not disqualified because this suite
  shows its largest benefit there. Weigh the measured costs and benefits. Respect
  `-Os`/`-Oz`; treat code growth as a regression and justify any accepted
  exception explicitly. Keep detailed acceptance evidence under `build/`.

Quartus Pro is required for Agilex characterization. Set `QUARTUS_SH` to the
configured executable and run Quartus outside the sandbox; sandboxed runs can
report a false device-license error. `make atum-a3-demo` builds the SOF but is
not an aggregate prerequisite. Build Icepi Zero with `make icepi-zero-demo-bit`.
Hardware programming needs explicit approval; after programming, wait for USB
re-enumeration before connecting serial/video interfaces.

Before broad RTL commits also run `git diff --check` and `git status --short`.

## Tables

- ECP5: LUT4 sites, with RF implementation labeled; Agilex: ALMs.
- Efficiency: MIPS/kLUT4 for ECP5; MIPS/kLE for Agilex (2.95 LE/ALM).

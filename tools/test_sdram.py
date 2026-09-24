#!/usr/bin/env python3
"""Build and run the SDRAM controller, cache, and board-wrapper checks.

The controller test uses a command-level SDR SDRAM model and a sparse bus
scoreboard.  Each configuration is built once; ``--seeds`` repeats the
binary with deterministic ``+SEED`` values so the randomized bus traffic can
be reproduced with ``--seed``.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path


def run(command: list[str], *, cwd: Path, timeout: int) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(command, cwd=cwd, text=True,
                              stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        output = exc.stdout or ""
        if isinstance(output, bytes):
            output = output.decode(errors="replace")
        return subprocess.CompletedProcess(command, 124, output + "timed out\n")


def save(path: Path, output: str) -> None:
    path.write_text(output)


def build(root: Path, verilator: str, mdir: Path, top: str,
          sources: list[Path], params: list[str]) -> tuple[bool, Path]:
    mdir.mkdir(parents=True, exist_ok=True)
    command = [verilator, "--binary", "--timing", "-j", "8", "-Wno-UNOPTFLAT",
               "--top-module", top, *params, "--Mdir", str(mdir),
               *(str(source) for source in sources)]
    result = run(command, cwd=root, timeout=180)
    save(mdir / "build.log", result.stdout)
    binary = mdir / f"V{top}"
    if result.returncode or not binary.exists():
        sys.stderr.write(f"{top} build failed; see {mdir / 'build.log'}\n")
        sys.stderr.write(result.stdout)
        return False, binary
    return True, binary


def execute(root: Path, binary: Path, log_dir: Path, seeds: list[int],
            timeout: int) -> bool:
    for seed in seeds:
        result = run([str(binary), f"+SEED={seed}"], cwd=root, timeout=timeout)
        log = log_dir / f"seed-{seed}.log"
        save(log, result.stdout)
        if result.returncode or "PASS SDRAM" not in result.stdout:
            sys.stderr.write(f"{binary.name} seed {seed} failed; see {log}\n")
            sys.stderr.write(result.stdout)
            return False
        lines = [line for line in result.stdout.splitlines()
                 if line.startswith(("PASS SDRAM", "SDRAM PERF", "SDRAM MIXED"))]
        print(f"{log_dir.name} seed {seed}: " +
              (" | ".join(lines) if lines else "PASS"), flush=True)
    return True


def run_controller(root: Path, verilator: str, build_root: Path,
                    data_bits: int, clk_mhz: int, init_cycles: int,
                    refresh_cycles: int, t_ac: str, clock_period_ns: str,
                    seeds: list[int], pin_pipeline: int = 0,
                    device_phase_ns: str | None = None,
                    oe_active_low: int = 0) -> bool:
    tag_period = clock_period_ns.replace(".", "p")
    tag_tac = t_ac.replace(".", "p")
    tag_phase = "default" if device_phase_ns is None else device_phase_ns.replace(".", "p")
    name = (f"controller-x{data_bits}-clk{clk_mhz}-period{tag_period}-"
            f"tac{tag_tac}-init{init_cycles}-refresh{refresh_cycles}"
            f"-pin{pin_pipeline}-phase{tag_phase}")
    if oe_active_low:
        name += "-oe-low"
    mdir = build_root / name
    params = [f"-GDATA_BITS={data_bits}", f"-GCLK_MHZ={clk_mhz}",
              f"-GCLOCK_PERIOD_NS={clock_period_ns}",
              f"-GINIT_CYCLES={init_cycles}",
              f"-GREFRESH_CYCLES={refresh_cycles}", f"-GT_AC={t_ac}",
              f"-GPIN_PIPELINE={pin_pipeline}", f"-GOE_ACTIVE_LOW={oe_active_low}"]
    if device_phase_ns is not None:
        params.append(f"-GDEVICE_CLK_PHASE_NS={device_phase_ns}")
    sources = [root / "boards/shared/rtl/riscc_sdram.v",
               root / "test/riscc_sdram_model.v",
               root / "test/riscc_sdram_tb.v"]
    ok, binary = build(root, verilator, mdir, "riscc_sdram_tb", sources, params)
    return ok and execute(root, binary, mdir, seeds, timeout=60)


def run_cache(root: Path, verilator: str, build_root: Path, data_bits: int,
              line_words: int, seeds: list[int], clk_mhz: int = 50,
              clock_period_ns: str = "20.0", t_ac: str = "6.0") -> bool:
    tag_period = clock_period_ns.replace(".", "p")
    tag_tac = t_ac.replace(".", "p")
    name = (f"cache-x{data_bits}-line{4 << line_words}-clk{clk_mhz}-"
            f"period{tag_period}-tac{tag_tac}")
    mdir = build_root / name
    params = [f"-GDATA_BITS={data_bits}", f"-GLINE_WORD_BITS={line_words}",
              f"-GCLK_MHZ={clk_mhz}",
              f"-GCLOCK_PERIOD_NS={clock_period_ns}", f"-GT_AC={t_ac}"]
    sources = [root / "boards/shared/rtl/riscc_sdram.v",
               root / "test/riscc_sdram_model.v",
               root / "rtl/riscc_cached.v",
               root / "test/riscc_sdram_cache_tb.v"]
    ok, binary = build(root, verilator, mdir, "riscc_sdram_cache_tb", sources,
                       params)
    if not ok:
        return False
    # Run once per requested seed so --seeds also exercises cache traffic
    # variants when the fixture's seed plusarg is enabled.
    for seed in seeds:
        result = run([str(binary), f"+SEED={seed}"], cwd=root, timeout=120)
        log = mdir / f"seed-{seed}.log"
        save(log, result.stdout)
        if result.returncode or "PASS SDRAM cache" not in result.stdout:
            sys.stderr.write(f"{name} seed {seed} failed; see {log}\n")
            sys.stderr.write(result.stdout)
            return False
        line = next((line for line in result.stdout.splitlines()
                     if line.startswith("PASS SDRAM cache")), "PASS")
        print(f"{name} seed {seed}: {line}", flush=True)
    return True


def lint_wrappers(root: Path, verilator: str, build_root: Path) -> bool:
    checks = (
        ("icepi-wrapper", "icepi_sdram", root / "boards/icepi_zero/rtl/icepi_sdram.v"),
        ("atum-wrapper", "atum_sdram", root / "boards/atum_a3_nano/rtl/atum_sdram.v"),
    )
    for name, top, wrapper in checks:
        log_dir = build_root / name
        log_dir.mkdir(parents=True, exist_ok=True)
        command = [verilator, "--lint-only", "--timing", "-Wno-UNOPTFLAT",
                   "--top-module", top,
                   str(root / "boards/shared/rtl/riscc_sdram.v"), str(wrapper)]
        result = run(command, cwd=root, timeout=60)
        save(log_dir / "lint.log", result.stdout)
        if result.returncode:
            sys.stderr.write(f"{top} lint failed; see {log_dir / 'lint.log'}\n")
            sys.stderr.write(result.stdout)
            return False
        print(f"{name}: lint PASS")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path,
                        default=Path(__file__).resolve().parents[1])
    parser.add_argument("--verilator",
                        default=shutil.which("verilator") or "verilator")
    parser.add_argument("--build-dir", type=Path,
                        default=Path("build/test-sdram"))
    parser.add_argument("--seed", type=int, default=1,
                        help="first deterministic random seed (default: 1)")
    parser.add_argument("--seeds", type=int, default=1,
                        help="number of seeds per runnable configuration")
    parser.add_argument("--skip-cache", action="store_true",
                        help="skip the write-through cache integration checks")
    args = parser.parse_args()
    if args.seeds < 1:
        parser.error("--seeds must be positive")
    root = args.root.resolve()
    build_root = args.build_dir if args.build_dir.is_absolute() else root / args.build_dir
    build_root.mkdir(parents=True, exist_ok=True)
    seeds = [args.seed + offset for offset in range(args.seeds)]

    # Exercise the board timing across both SDRAM widths.  CLK_MHZ remains an
    # integer because it also drives the controller's cycle-based timing
    # calculations; CLOCK_PERIOD_NS represents the actual board clock period
    # so that the 166.667 MHz case can use a conservative 167 MHz rounding.
    configurations = (
        # Existing 50 MHz stress, refresh, and initialization cases.
        (16, 50, 20, 100, "6.0", "20.0"),
        (16, 50, 20, 10000, "6.0", "20.0"),
        (16, 50, 10000, 100, "6.0", "20.0"),
        (32, 50, 20, 100, "6.0", "20.0"),
        (32, 50, 20, 10000, "6.0", "20.0"),
        # Validate both widths at 100 and 125 MHz with the real model delay.
        (16, 100, 20, 100, "6.0", "10.0"),
        (32, 100, 20, 100, "6.0", "10.0"),
        (16, 125, 20, 100, "6.0", "8.0"),
        (32, 125, 20, 100, "6.0", "8.0"),
        (16, 125, 20, 10000, "6.0", "8.0"),
        (32, 125, 20, 10000, "6.0", "8.0"),
        (32, 125, 25000, 100, "6.0", "8.0"),
        (16, 150, 20, 100, "6.0", "6.666666667"),
        (16, 150, 20, 10000, "6.0", "6.666666667"),
        (16, 150, 30000, 100, "6.0", "6.666666667"),
        # Stress the 166.667 MHz device limit. Round CLK_MHZ up for conservative
        # integer timing calculations while retaining its exact 6 ns period.
        (16, 167, 20, 100, "5.8", "6.0"),
        (32, 167, 20, 100, "5.8", "6.0"),
        # Early data is a useful opposite timing corner at the same rate.
        (16, 167, 20, 100, "2.0", "6.0"),
        (32, 167, 20, 100, "2.0", "6.0"),
    )
    for data_bits, clk_mhz, init_cycles, refresh_cycles, t_ac, period in configurations:
        if not run_controller(root, args.verilator, build_root, data_bits,
                              clk_mhz, init_cycles, refresh_cycles, t_ac,
                              period, seeds):
            return 1
    # Model the native positive-edge SDRAM output registers used by the board
    # wrappers.  The controller's PIN_PIPELINE compensation must preserve the
    # same command/data timing after this extra pin stage.
    pipeline_configurations = (
        (16, 50, 20, 100, "6.0", "20.0"),
        (16, 167, 20, 100, "5.8", "6.0"),
    )
    for data_bits, clk_mhz, init_cycles, refresh_cycles, t_ac, period in pipeline_configurations:
        if not run_controller(root, args.verilator, build_root, data_bits,
                              clk_mhz, init_cycles, refresh_cycles, t_ac,
                              period, seeds, pin_pipeline=1):
            return 1
    # IcePi's PLL/forwarded-clock path presents the device clock about
    # 2.875 ns after a 166.667 MHz controller rising edge: 1.875 ns of PLL
    # phase plus approximately 1 ns of output-clock delay.  Keep both early
    # and nominal tAC corners in the pin-pipelined model.
    phase_pipeline_configurations = (
        (16, 167, 20, 100, "5.0", "6.0", "2.875"),
        (16, 167, 20, 100, "3.0", "6.0", "2.875"),
    )
    for data_bits, clk_mhz, init_cycles, refresh_cycles, t_ac, period, phase in phase_pipeline_configurations:
        if not run_controller(root, args.verilator, build_root, data_bits,
                              clk_mhz, init_cycles, refresh_cycles, t_ac,
                              period, seeds, pin_pipeline=1,
                              device_phase_ns=phase):
            return 1
        # Icepi drives native I/O tristate registers from the controller's
        # active-low output. Both polarities must have identical pin timing.
        if not run_controller(root, args.verilator, build_root, data_bits,
                              clk_mhz, init_cycles, refresh_cycles, t_ac,
                              period, seeds, pin_pipeline=1,
                              device_phase_ns=phase, oe_active_low=1):
            return 1
    if not args.skip_cache:
        cache_rates = ((50, "20.0", "6.0"), (125, "8.0", "6.0"),
                       (150, "6.666666667", "6.0"),
                       (167, "6.0", "5.8"))
        for clk_mhz, period, t_ac in cache_rates:
            for data_bits in (16, 32):
                for line_words in (3, 4):
                    if not run_cache(root, args.verilator, build_root,
                                     data_bits, line_words, seeds, clk_mhz,
                                     period, t_ac):
                        return 1
    if not lint_wrappers(root, args.verilator, build_root):
        return 1
    print("SDRAM controller, cache, and board-wrapper checks PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

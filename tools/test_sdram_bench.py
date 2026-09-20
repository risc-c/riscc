#!/usr/bin/env python3
"""Run the queued SDRAM/cache traffic benchmark in the pin-level model.

The fixture models Icepi pin registers and forwarded-clock phase, or Atum
x32 pins with an inverted SDRAM clock. It independently scores every bus
response while the benchmark covers sequential cache-line writes and reads,
random line traffic, masked stores, mixed traffic, and delayed result reports.
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


def build(root: Path, verilator: str, build_dir: Path, data_bits: int,
          clock_mhz: int, period: str, phase: str, tac: str,
          full_bits: int = 10, corrupt_read: int = 0,
          read_delay: int = 0, direct_capture: int = 0,
          io_capture: int = 0, max_refresh_gap: int = 132,
          forward_phase: str = "0.0") -> tuple[bool, Path]:
    build_dir.mkdir(parents=True, exist_ok=True)
    command = [verilator, "--binary", "--timing", "-j", "8",
               "-Wno-UNOPTFLAT", "-Wno-WIDTHTRUNC", "-Wno-WIDTHEXPAND",
               "--top-module", "riscc_sdram_bench_tb",
               f"-GDATA_BITS={data_bits}", f"-GCLK_MHZ={clock_mhz}",
               f"-GCLOCK_PERIOD_NS={period}",
               f"-GDEVICE_CLK_PHASE_NS={phase}", f"-GT_AC={tac}",
               "-GINIT_CYCLES=20", "-GREFRESH_CYCLES=100",
               f"-GMAX_REFRESH_GAP={max_refresh_gap}", f"-GFULL_BITS={full_bits}",
               f"-GREAD_DELAY={read_delay}",
               f"-GDIRECT_CAPTURE={direct_capture}",
               f"-GIO_CAPTURE={io_capture}",
               f"-GFORWARD_PHASE_NS={forward_phase}",
               "-GRANDOM_BITS=8", f"-GCORRUPT_READ={corrupt_read}",
               "--Mdir", str(build_dir),
               str(root / "boards/shared/rtl/riscc_sdram.v"),
               str(root / "boards/shared/test/sdram/riscc_sdram_bench.v"),
               str(root / "boards/icepi_zero/rtl/icepi_sdram.v"),
               str(root / "boards/atum_a3_nano/rtl/atum_sdram.v"),
               str(root / "test/riscc_sdram_model.v"),
               str(root / "test/riscc_sdram_bench_tb.v")]
    result = run(command, cwd=root, timeout=180)
    (build_dir / "build.log").write_text(result.stdout)
    binary = build_dir / "Vriscc_sdram_bench_tb"
    if result.returncode or not binary.exists():
        print(f"benchmark build failed; see {build_dir / 'build.log'}",
              file=sys.stderr)
        print(result.stdout, file=sys.stderr)
        return False, binary
    return True, binary


def execute(root: Path, binary: Path, build_dir: Path,
            seeds: list[int]) -> bool:
    for seed in seeds:
        result = run([str(binary), f"+SEED={seed}"], cwd=root, timeout=120)
        log = build_dir / f"seed-{seed}.log"
        log.write_text(result.stdout)
        if result.returncode or "PASS SDRAM benchmark" not in result.stdout:
            print(f"benchmark seed {seed} failed; see {log}", file=sys.stderr)
            print(result.stdout, file=sys.stderr)
            return False
        line = next((item for item in result.stdout.splitlines()
                     if item.startswith("PASS SDRAM benchmark")), "PASS")
        print(f"{build_dir.name} seed {seed}: {line}", flush=True)
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path,
                        default=Path(__file__).resolve().parents[1])
    parser.add_argument("--verilator",
                        default=shutil.which("verilator") or "verilator")
    parser.add_argument("--build-dir", type=Path,
                        default=Path("build/test-sdram-bench"))
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--seeds", type=int, default=1,
                        help="number of deterministic runs per configuration")
    args = parser.parse_args()
    if args.seeds < 1:
        parser.error("--seeds must be positive")
    root = args.root.resolve()
    build_root = args.build_dir if args.build_dir.is_absolute() else root / args.build_dir
    build_root.mkdir(parents=True, exist_ok=True)
    seeds = [args.seed + offset for offset in range(args.seeds)]

    # The x16 cases instantiate IcePi's registered output/input path and
    # forwarded clock. The 166-x16-tac3 case checks the early SDRAM tAC corner
    # at the same forwarded-clock phase. FULL_BITS stays small for simulation speed;
    # board capture validates the complete 32 MiB or 64 MiB address space.
    configurations = (
        (16, 50, "20.0", "10.0", "5.0", 10, 0, "50-x16-tac5"),
        (32, 50, "20.0", "10.0", "5.0", 10, 0, "50-x32-tac5"),
        (32, 50, "20.0", "10.0", "5.0", 10, 1, "50-x32-fault"),
        (32, 50, "20.0", "10.0", "5.0", 16, 0, "50-x32-long"),
        (16, 167, "6.0", "5.875", "5.0", 10, 0, "166-x16-tac5"),
        (16, 167, "6.0", "5.875", "3.0", 10, 0, "166-x16-tac3"),
        # Late-return edge of the simulated x16 capture window.
        (16, 167, "6.0", "5.875", "6.0", 10, 0, "166-x16-tac6"),
        # This run is intentionally larger than the normal quick check.  A
        # sequential phase crosses 65535 cycles, exercising the engine's
        # registered carry lookahead in bits 16 and above.  Run it once per
        # invocation; --seeds still fuzzes the normal and fault cases.
        (16, 167, "6.0", "5.875", "5.0", 16, 0, "166-x16-long"),
        # Corrupt one read response and require the engine to report the
        # failing address and expected/actual values through its handshake.
        (16, 167, "6.0", "5.875", "5.0", 10, 1, "166-x16-fault"),
        # Atum's x32 path drives the SDRAM pins directly and uses the
        # inverted controller clock, with no additional pin pipeline.
        (32, 167, "6.0", "3.0", "5.8", 10, 0, "166-x32-tac5p8"),
        (32, 167, "6.0", "3.0", "1.8", 10, 0, "166-x32-tac1p8"),
        (32, 167, "6.0", "3.0", "5.8", 16, 0, "166-x32-long"),
        (32, 167, "6.0", "3.0", "5.8", 10, 1, "166-x32-fault"),
    )
    for data_bits, clock_mhz, period, phase, tac, full_bits, corrupt_read, tag in configurations:
        build_dir = build_root / tag
        ok, binary = build(root, args.verilator, build_dir, data_bits, clock_mhz,
                            period, phase, tac, full_bits, corrupt_read,
                            read_delay=1 if data_bits == 16 and clock_mhz > 100 else 0)
        run_seeds = seeds[:1] if tag in ("50-x32-long", "166-x16-long") else seeds
        if not ok or not execute(root, binary, build_dir, run_seeds):
            return 1

    # Atum can return data after two additional complete controller periods.
    # Increase the model tAC by those periods while retaining the underlying
    # 5.8 ns nominal and 1.8 ns early return points.  These cases exercise the
    # controller's explicit read-return delay rather than changing traffic.
    delayed_configurations = (
        ("17.8", 10, 0, "166-x32-delay2-tac5p8"),
        ("13.8", 10, 0, "166-x32-delay2-tac1p8"),
        ("17.8", 16, 0, "166-x32-delay2-long"),
        ("17.8", 10, 1, "166-x32-delay2-fault"),
    )
    for tac, full_bits, corrupt_read, tag in delayed_configurations:
        build_dir = build_root / tag
        ok, binary = build(root, args.verilator, build_dir, 32, 167,
                            "6.0", "3.0", tac, full_bits, corrupt_read,
                            read_delay=2)
        if not ok or not execute(root, binary, build_dir, seeds):
            return 1

    # Exercise the generic x32 read-return path with one additional clock of
    # response delay.  The model tAC includes that latency while retaining
    # the underlying nominal and early device return points.
    delay1_configurations = (
        ("11.8", 10, 0, "166-x32-delay1-tac5p8"),
        ("7.8", 10, 0, "166-x32-delay1-tac1p8"),
        ("11.8", 16, 0, "166-x32-delay1-long"),
        ("11.8", 10, 1, "166-x32-delay1-fault"),
    )
    for tac, full_bits, corrupt_read, tag in delay1_configurations:
        build_dir = build_root / tag
        ok, binary = build(root, args.verilator, build_dir, 32, 167,
                            "6.0", "3.0", tac, full_bits, corrupt_read,
                            read_delay=1)
        if not ok or not execute(root, binary, build_dir, seeds):
            return 1

    # Model Atum's direct response capture: raw SDRAM DQ is
    # presented to a controller using INPUT_REGISTERED=1 and READ_DELAY=1.
    # These effective return points abstract pad, device, and return-delay
    # timing; they are not a physical SDRAM tAC validation.
    direct_configurations = (
        ("11.8", 10, 0, "166-x32-direct-tac5p8"),
        # 7.8 ns is before the raw-DQ posedge sampling eye in this model;
        # use a 9.2 ns point with margin for the early case.
        ("9.2", 10, 0, "166-x32-direct-tac9p2"),
        ("14.8", 10, 0, "166-x32-direct-tac14p8"),
        ("11.8", 16, 0, "166-x32-direct-long"),
        ("11.8", 10, 1, "166-x32-direct-fault"),
    )
    for tac, full_bits, corrupt_read, tag in direct_configurations:
        build_dir = build_root / tag
        ok, binary = build(root, args.verilator, build_dir, 32, 167,
                            "6.0", "3.0", tac, full_bits, corrupt_read,
                            read_delay=1, direct_capture=1)
        if not ok or not execute(root, binary, build_dir, seeds):
            return 1

    # Exercise the actual Atum wrapper with its packed positive-edge I/O
    # capture register.  The wrapper's Verilator fallback and DQ inout path
    # are included in the build.  Advancing its forwarded clock by 0.666667 ns
    # moves both model capture bounds by the same amount: the early and late
    # points below retain their arrival relative to the core capture edge.
    io_configurations = (
        ("5.8", 10, 0, "166-x32-io-fwdneg666-tac5p8"),
        ("3.866667", 10, 0, "166-x32-io-fwdneg666-tac3p866"),
        ("9.466667", 10, 0, "166-x32-io-fwdneg666-tac9p466"),
        ("5.8", 16, 0, "166-x32-io-fwdneg666-long"),
        ("5.8", 10, 1, "166-x32-io-fwdneg666-fault"),
    )
    for tac, full_bits, corrupt_read, tag in io_configurations:
        build_dir = build_root / tag
        ok, binary = build(root, args.verilator, build_dir, 32, 167,
                            "6.0", "3.0", tac, full_bits, corrupt_read,
                            read_delay=1, io_capture=1,
                            # The actual wrapper leaves REFRESH_CYCLES at
                            # the controller's CLK_MHZ-derived default.
                            max_refresh_gap=1300,
                            forward_phase="-0.666667")
        if not ok or not execute(root, binary, build_dir, seeds):
            return 1
    print("SDRAM queued benchmark checks PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

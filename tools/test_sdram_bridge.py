#!/usr/bin/env python3
"""Exercise the SDRAM bring-up bridge across unrelated clock domains.

The fixture drives randomized 32-bit reads and byte-masked writes through the
host-side credit interface.  Its memory model varies ready delay, pre-accept
stalling, same-cycle completion, and delayed completion while checking that
the payload remains stable.  Each binary is reused for deterministic seeds.
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


def build(root: Path, verilator: str, build_dir: Path, host_period: str,
          memory_period: str, ready_delay: int, requests: int) -> tuple[bool, Path]:
    build_dir.mkdir(parents=True, exist_ok=True)
    command = [
        verilator, "--binary", "--timing", "-j", "8",
        "-Wno-UNOPTFLAT", "-Wno-WIDTHEXPAND", "-Wno-WIDTHTRUNC",
        "--top-module", "riscc_sdram_bridge_tb",
        f"-GHOST_PERIOD_NS={host_period}",
        f"-GMEMORY_PERIOD_NS={memory_period}",
        f"-GREADY_DELAY={ready_delay}",
        f"-GREQUEST_COUNT={requests}",
        "--Mdir", str(build_dir),
        str(root / "boards/shared/rtl/riscc_sdram_bridge.v"),
        str(root / "test/riscc_sdram_bridge_tb.v"),
    ]
    result = run(command, cwd=root, timeout=180)
    save(build_dir / "build.log", result.stdout)
    binary = build_dir / "Vriscc_sdram_bridge_tb"
    if result.returncode or not binary.exists():
        sys.stderr.write(f"bridge build failed; see {build_dir / 'build.log'}\n")
        sys.stderr.write(result.stdout)
        return False, binary
    return True, binary


def execute(root: Path, binary: Path, log_dir: Path, seeds: list[int]) -> bool:
    for seed in seeds:
        result = run([str(binary), f"+SEED={seed}"], cwd=root, timeout=120)
        log = log_dir / f"seed-{seed}.log"
        save(log, result.stdout)
        if result.returncode or "PASS BRIDGE" not in result.stdout:
            sys.stderr.write(f"{binary.name} seed {seed} failed; see {log}\n")
            sys.stderr.write(result.stdout)
            return False
        line = next((line for line in result.stdout.splitlines()
                     if line.startswith("PASS BRIDGE")), "PASS BRIDGE")
        print(f"{log_dir.name} seed {seed}: {line}", flush=True)
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path,
                        default=Path(__file__).resolve().parents[1])
    parser.add_argument("--verilator",
                        default=shutil.which("verilator") or "verilator")
    parser.add_argument("--build-dir", type=Path,
                        default=Path("build/test-sdram-bridge"))
    parser.add_argument("--seed", type=int, default=1,
                        help="first deterministic random seed (default: 1)")
    parser.add_argument("--seeds", type=int, default=1,
                        help="number of seeds per clock configuration")
    parser.add_argument("--requests", type=int, default=96,
                        help="random requests per run (default: 96)")
    args = parser.parse_args()
    if args.seeds < 1:
        parser.error("--seeds must be positive")
    if args.requests < 1:
        parser.error("--requests must be positive")

    root = args.root.resolve()
    build_root = args.build_dir if args.build_dir.is_absolute() else root / args.build_dir
    build_root.mkdir(parents=True, exist_ok=True)
    seeds = [args.seed + offset for offset in range(args.seeds)]

    # Periods represent the two independent domains.  The first pair is the
    # IcePi-style host50/memory166 corner; the second swaps those rates.  The
    # other pairs exercise both domains at slower and opposite ratios.
    configurations = (
        ("host50-mem166", "20.0", "6.0", 3),
        ("host166-mem50", "6.0", "20.0", 3),
        ("host83-mem143", "12.0", "7.0", 5),
        ("host143-mem83", "7.0", "12.0", 1),
    )
    for name, host_period, memory_period, ready_delay in configurations:
        case_dir = build_root / name
        ok, binary = build(root, args.verilator, case_dir, host_period,
                            memory_period, ready_delay, args.requests)
        if not ok or not execute(root, binary, case_dir, seeds):
            return 1
    print("SDRAM bridge clock-crossing checks PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

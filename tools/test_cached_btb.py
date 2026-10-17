#!/usr/bin/env python3
"""Run focused Cached RC16/RC32 BTB checks with held 16-bit responses."""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path


PASS_RE = re.compile(
    r"PASS BTB(?: XLEN=(?P<xlen>\d+))? CASE=(?P<case>\d+) "
    r"(?:warm consecutive commits=76|directed PC sequence)"
)


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


def one_variant(root: Path, verilator: str, build_root: Path, rtl_source: Path,
                case: int, timeout: int, xlen: int, ecp5: bool = False) -> bool:
    name = f"rc{xlen}-{'ecp5' if ecp5 else 'held16'}-case{case}"
    mdir = build_root / name
    mdir.mkdir(parents=True, exist_ok=True)
    binary = mdir / "Vriscc_cached_btb_tb"
    command = [
        verilator, "--binary", "--timing",
        "-Wno-MULTIDRIVEN",
        "--top-module", "riscc_cached_btb_tb",
        f"-GCASE={case}", f"-GXLEN={xlen}",
        "--Mdir", str(mdir),
        str(root / "rtl/riscc_pipeline_shared.v"),
        str(rtl_source),
        str(root / "test/riscc_cached_btb_tb.v"),
    ]
    if ecp5:
        command.append("-DRISCC_ECP5")
    built = run(command, cwd=root, timeout=120)
    if built.returncode or not binary.exists():
        sys.stderr.write(f"{name}: Verilator build failed\n{built.stdout}")
        return False
    result = run([str(binary)], cwd=root, timeout=timeout)
    match = PASS_RE.search(result.stdout)
    if result.returncode or not match:
        sys.stderr.write(f"{name}: test failed\n{result.stdout}")
        return False
    if (match.group("xlen") is None or int(match.group("xlen")) != xlen or
            int(match.group("case")) != case):
        sys.stderr.write(f"{name}: malformed PASS result\n{result.stdout}")
        return False
    print(f"{name}: {match.group(0)}")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path,
                        default=Path(__file__).resolve().parents[1])
    parser.add_argument("--rtl", type=Path,
                        help="Cached RTL source to compile (defaults to rtl/riscc_cached.v)")
    parser.add_argument("--verilator",
                        default=shutil.which("verilator") or "verilator")
    parser.add_argument("--build-dir", type=Path,
                        default=Path("build/test-cached-btb"))
    parser.add_argument("--timeout", type=int, default=60)
    args = parser.parse_args()

    root = args.root.resolve()
    build_root = args.build_dir
    if not build_root.is_absolute():
        build_root = root / build_root
    rtl_source = args.rtl or (root / "rtl/riscc_cached.v")
    if not rtl_source.is_absolute():
        rtl_source = root / rtl_source
    rtl_source = rtl_source.resolve()

    cases = (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 12, 13, 14, 15, 16)
    for xlen in (16, 32):
        for case in cases:
            if not one_variant(root, args.verilator, build_root, rtl_source,
                               case, args.timeout, xlen):
                return 1
        if not one_variant(root, args.verilator, build_root, rtl_source,
                           16, args.timeout, xlen, ecp5=True):
            return 1
    print("Cached BTB focused checks PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

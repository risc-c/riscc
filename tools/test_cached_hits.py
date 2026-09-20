#!/usr/bin/env python3
"""Check warmed Cached I/D-cache hits and native load timing."""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path


PASS_RE = re.compile(
    r"PASS Cached cache hits XLEN=(?P<xlen>\d+) cycles=(?P<cycles>\d+) "
    r"commits=(?P<commits>\d+) writes=(?P<writes>\d+)"
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


def one_variant(root: Path, verilator: str, build_root: Path, xlen: int,
                block_rf: bool, timeout: int) -> bool:
    rf_name = "block" if block_rf else "distributed"
    name = f"xlen{xlen}-dsp-{rf_name}"
    mdir = build_root / name
    mdir.mkdir(parents=True, exist_ok=True)
    binary = mdir / "Vriscc_cached_hits_tb"
    defines = ["-DRISCC_FAST_BLOCK_RF"] if block_rf else []
    command = [
        verilator, "--binary", "--timing",
        "--top-module", "riscc_cached_hits_tb", f"-GXLEN={xlen}",
        "--Mdir", str(mdir), *defines,
        str(root / "rtl/riscc_fast.v"),
        str(root / "rtl/riscc_cached.v"),
        str(root / "test/riscc_cached_hits_tb.v"),
    ]
    built = run(command, cwd=root, timeout=120)
    if built.returncode or not binary.exists():
        sys.stderr.write(f"{name}: Verilator build failed\n{built.stdout}")
        return False
    result = run([str(binary)], cwd=root, timeout=timeout)
    match = PASS_RE.search(result.stdout)
    if result.returncode or not match:
        sys.stderr.write(f"{name}: test failed\n{result.stdout}")
        return False
    if int(match.group("xlen")) != xlen or int(match.group("writes")) != 2:
        sys.stderr.write(f"{name}: malformed PASS result\n{result.stdout}")
        return False
    print(f"{name}: {match.group(0)}")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path,
                        default=Path(__file__).resolve().parents[1])
    parser.add_argument("--verilator",
                        default=shutil.which("verilator") or "verilator")
    parser.add_argument("--build-dir", type=Path,
                        default=Path("build/test-cached-hits"))
    parser.add_argument("--timeout", type=int, default=60)
    args = parser.parse_args()
    root = args.root.resolve()
    build_root = args.build_dir
    if not build_root.is_absolute():
        build_root = root / build_root
    ok = all(one_variant(root, args.verilator, build_root, xlen, block_rf,
                         args.timeout)
             for xlen in (16, 32) for block_rf in (False, True))
    if ok:
        print("Cached cache-hit checks PASS (4 variants)")
        return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(main())

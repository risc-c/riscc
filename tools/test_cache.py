#!/usr/bin/env python3
"""Run the split-cache protocol checks in the Cached core.

The cache testbench exercises the normal write-through data cache and the
read-only instruction-cache specialization with both registered and immediate
backend responses.  It is intentionally independent of the Fast-core image
tests so cache protocol failures are easy to isolate.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path


def run(command: list[str], cwd: Path, timeout: int) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(command, cwd=cwd, text=True,
                              stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        output = exc.stdout or ""
        if isinstance(output, bytes):
            output = output.decode(errors="replace")
        return subprocess.CompletedProcess(command, 124, output + "timed out\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path,
                        default=Path(__file__).resolve().parents[1])
    parser.add_argument("--verilator", default=shutil.which("verilator") or "verilator")
    parser.add_argument("--source", type=Path,
                        help="cache RTL source (defaults to rtl/riscc_cached.v)")
    parser.add_argument("--build-dir", type=Path,
                        default=Path("build/test-cache"))
    args = parser.parse_args()
    root = args.root.resolve()
    build_dir = args.build_dir
    if not build_dir.is_absolute():
        build_dir = root / build_dir
    tb = root / "test/riscc_cache_tb.v"
    source = args.source or (root / "rtl/riscc_cached.v")
    if not source.is_absolute():
        source = root / source
    # The private cache selects one word-address bit. Keep the original
    # fixture bit 13 for protocol tests, then exercise the actual default bit
    # 29 (byte address bit 31). Read-only tests cover the all-cached policy.
    fixture_bit = 13
    configurations = ((32, 0, "rc32-rw", fixture_bit, 3),
                      (32, 1, "rc32-ro", fixture_bit, 3),
                      (16, 1, "rc16-ro", fixture_bit, 3),
                      (32, 0, "rc32-rw-default-bit29", 29, 3),
                      (32, 0, "rc32-rw-line64", fixture_bit, 4),
                      (32, 1, "rc32-ro-line64", fixture_bit, 4),
                      (16, 1, "rc16-ro-line64-default-bit29", 29, 4))
    for cpu_bits, read_only, name, uncached_bit, line_word_bits in configurations:
        mdir = build_dir / name
        mdir.mkdir(parents=True, exist_ok=True)
        binary = mdir / "Vriscc_cache_tb"
        command = [args.verilator, "--binary", "--timing", "-Wno-UNOPTFLAT",
                   "--top-module", "riscc_cache_tb",
                   f"-GCACHE_READ_ONLY={read_only}", f"-GCPU_BITS={cpu_bits}",
                   f"-GUNCACHED_BIT={uncached_bit}",
                   f"-GLINE_WORD_BITS={line_word_bits}",
                   "--Mdir", str(mdir),
                   str(source), str(tb)]
        result = run(command, root, 120)
        if result.returncode or not binary.exists():
            sys.stderr.write(f"cache {name}: Verilator build failed\n{result.stdout}")
            return 1
        for mode in ([], ["+IMMEDIATE"]):
            result = run([str(binary), *mode], root, 30)
            if result.returncode or "PASS riscc_cache" not in result.stdout:
                label = "immediate" if mode else "registered"
                sys.stderr.write(f"cache {name} {label} failed\n{result.stdout}")
                return 1
            print(f"cache {name} {'immediate' if mode else 'registered'}: "
                  f"{result.stdout.strip().splitlines()[0]}")
    print("cache protocol checks PASS (Cached, RC32 read/write and read-only, "
          "RC16 read-only, registered/immediate)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

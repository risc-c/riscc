#!/usr/bin/env python3
"""Run Cached SRAM protocol and production-CPU store boundary checks."""

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


def store_variant(root: Path, verilator: str, build_dir: Path,
                  xlen: int, sram_bits: int, timeout: int) -> bool:
    out = build_dir / f"stores-rc{xlen}-sram{sram_bits}"
    out.mkdir(parents=True, exist_ok=True)
    image = out / "sram.hex"
    image.write_text("11223344\n" * (1 << (sram_bits - 2)))
    mdir = out / "obj"
    binary = mdir / "Vriscc_cached_store_tb"
    command = [verilator, "--binary", "--timing", "-Wno-TIMESCALEMOD",
               "-Wno-UNOPTFLAT", "--top-module", "riscc_cached_store_tb",
               f"-GXLEN={xlen}", f"-GSRAM_ADDR_BITS={sram_bits}",
               f'-GSRAM_HEX="{image}"', "--Mdir", str(mdir),
               str(root / "rtl/riscc_pipeline_shared.v"),
               str(root / "rtl/riscc_cached.v"),
               str(root / "test/riscc_cached_store_tb.v")]
    built = run(command, cwd=root, timeout=120)
    (out / "build.log").write_text(built.stdout)
    if built.returncode or not binary.exists():
        sys.stderr.write(f"{out.name}: build failed\n{built.stdout}")
        return False
    result = run([str(binary)], cwd=root, timeout=timeout)
    (out / "run.log").write_text(result.stdout)
    print(result.stdout, end="")
    return result.returncode == 0 and (
        f"PASS Cached stores XLEN={xlen} SRAM={sram_bits}" in result.stdout)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path,
                        default=Path(__file__).resolve().parents[1])
    parser.add_argument("--verilator",
                        default=shutil.which("verilator") or "verilator")
    parser.add_argument("--build-dir", type=Path,
                        default=Path("build/test-cached-sram"))
    parser.add_argument("--timeout", type=int, default=60)
    args = parser.parse_args()

    root = args.root.resolve()
    build_dir = args.build_dir
    if not build_dir.is_absolute():
        build_dir = root / build_dir
    build_dir.mkdir(parents=True, exist_ok=True)

    image = build_dir / "sram.hex"
    image.write_text("5aa5a55a\n11223344\n")
    source = (root / "rtl/riscc_cached.v").read_text()
    pipe = source.index("\nmodule riscc_cached_pipe")
    cache = source.index("\nmodule riscc_cached_cache", pipe)
    wrapper = build_dir / "riscc_cached_wrapper.v"
    wrapper.write_text(source[:pipe] + source[cache:])
    mdir = build_dir / "obj"
    binary = mdir / "Vriscc_cached_sram_tb"
    command = [
        args.verilator, "--binary", "--timing", "-Wno-fatal",
        "-Wno-UNOPTFLAT", "-Wno-WIDTH", "-Wno-TIMESCALEMOD",
        "--top-module", "riscc_cached_sram_tb", "-GXLEN=32",
        "-GSRAM_ADDR_BITS=14",
        f'-GSRAM_HEX="{image}"', "--Mdir", str(mdir),
        str(root / "rtl/riscc_pipeline_shared.v"),
        str(wrapper),
        str(root / "test/riscc_cached_sram_tb.v"),
    ]
    built = run(command, cwd=root, timeout=120)
    (build_dir / "build.log").write_text(built.stdout)
    if built.returncode or not binary.exists():
        print(f"Cached SRAM build failed; see {build_dir / 'build.log'}",
              file=sys.stderr)
        print(built.stdout, file=sys.stderr)
        return 1

    result = run([str(binary)], cwd=root, timeout=args.timeout)
    (build_dir / "run.log").write_text(result.stdout)
    print(result.stdout, end="")
    if result.returncode or "PASS Cached SRAM:" not in result.stdout:
        print(f"Cached SRAM test failed; see {build_dir / 'run.log'}",
              file=sys.stderr)
        return 1
    for xlen in (16, 32):
        for sram_bits in (6, 8, 14):
            if not store_variant(root, args.verilator, build_dir, xlen,
                                 sram_bits, args.timeout):
                return 1
    print("Cached SRAM checks PASS (protocol plus 6 production-store variants)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

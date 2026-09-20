#!/usr/bin/env python3
"""Run the public Cached high-address and instruction-coherence checks.

The fixture uses a sparse 30-bit-word backing store, so RC32 I-cache tags
cannot pass by accidentally masking address bits.  It covers the RC16 and
RC32 alias programs, RC32 self-modifying code through an explicitly uncached
data bit, and registered, immediate, and delayed/stalled responses.
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path


PASS_RE = re.compile(
    r"PASS Cached address XLEN=(?P<xlen>\d+) case=(?P<case>\d+) "
    r"reads=(?P<reads>\d+) writes=(?P<writes>\d+) "
    r"target_line_reads=(?P<target>\d+) stalls=(?P<stalls>\d+)"
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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path,
                        default=Path(__file__).resolve().parents[1])
    parser.add_argument("--verilator",
                        default=shutil.which("verilator") or "verilator")
    parser.add_argument("--source", type=Path,
                        help="Cached RTL source (defaults to rtl/riscc_cached.v)")
    parser.add_argument("--build-dir", type=Path,
                        default=Path("build/test-cached-address"))
    args = parser.parse_args()

    root = args.root.resolve()
    build_root = args.build_dir
    if not build_root.is_absolute():
        build_root = root / build_root
    source = args.source or (root / "rtl/riscc_cached.v")
    if not source.is_absolute():
        source = root / source
    source = source.resolve()
    tb = root / "test/riscc_cached_address_tb.v"

    # The RC16 program covers high/low I aliases and D-uncached patching.
    # RC32 has a full-tag alias case and a separate target index for the
    # warm-line/self-modifying-code check.  The latter uses D bit 15 so its
    # 0x8000 patch is uncached while I-cache policy remains independent.
    variants = (
        ("rc16-dsp-distributed", 16, 0x4800, 15, 0),
        ("rc32-dsp-distributed", 32, 0x8000, 31, 0),
        ("rc32-coherence-dsp-distributed", 32, 0x40008000, 15, 3),
    )
    modes = (("registered", ()),
             ("immediate-stall", ("+IMMEDIATE", "+STALL")),
             ("delayed-stall", ("+WAIT", "+STALL")))

    for name, xlen, reset_pc, uncached_bit, case in variants:
        mdir = build_root / name
        mdir.mkdir(parents=True, exist_ok=True)
        binary = mdir / "Vriscc_cached_address_tb"
        command = [args.verilator, "--binary", "--timing",
                   "-Wno-UNOPTFLAT",
                   "--top-module", "riscc_cached_address_tb",
                   f"-GXLEN={xlen}", f"-GRESET_PC=0x{reset_pc:x}",
                   f"-GDCACHE_UNCACHED_BIT={uncached_bit}",
                   "--Mdir", str(mdir), str(source),
                   str(root / "rtl/riscc_fast.v"), str(tb)]
        built = run(command, cwd=root, timeout=120)
        if built.returncode or not binary.exists():
            sys.stderr.write(f"address {name}: Verilator build failed\n{built.stdout}")
            return 1

        for mode_name, plusargs in modes:
            result = run([str(binary), f"+CASE={case}", *plusargs],
                         cwd=root, timeout=30)
            match = PASS_RE.search(result.stdout)
            if result.returncode or not match:
                sys.stderr.write(f"address {name} {mode_name} failed\n{result.stdout}")
                return 1
            if int(match.group("xlen")) != xlen or int(match.group("case")) != case:
                sys.stderr.write(f"address {name} {mode_name}: malformed PASS line\n"
                                 f"{result.stdout}")
                return 1
            print(f"address {name} {mode_name}: {match.group(0)}")

    print("Cached public address/tag checks PASS (RC16/RC32, alias/coherence, "
          "registered/immediate/delayed-stall)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Run the standalone Cached pipeline cycle checks.

The testbench is an executable SystemVerilog top, so this driver only needs
Verilator and the production RTL.  Each width, multiplier, and RF mapping is
compiled separately; CASE=0/1 cover one-IPC ALU issue and CASE=2 covers the
split instruction/data memory contract (the data side is one native-word
request). CASE=3 checks JALL's literal and link;
CASE=4 checks dependent r0 zero/negative flags, taken/fall-through branches,
and one-bubble redirects. CASE=8 checks RC32 native loads whose destination
aliases the base or index register. CASE=10 checks MUL destination aliases,
back-to-back dependent MUL, and dependent ALU/store consumers,
including an IRQ before the indexed load. CASE=9 withdraws IRQ while an older
fetch delays interrupt entry. The main programs run with registered
responses, delayed ACK, request STALL, same-cycle ACK, and mixed response
timing.
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path


PASS_RE = re.compile(
    r"PASS CASE (?P<case>\d+) XLEN=(?P<xlen>\d+) cycles=(?P<cycles>\d+) "
    r"commits=(?P<commits>\d+) max_ipc_run=(?P<run>\d+) "
    r"accepts=(?P<accepts>\d+) responses=(?P<responses>\d+) "
    r"early_acks=(?P<early>\d+) ack_stalls=(?P<ack_stalls>\d+) "
    r"stalls=(?P<stalls>\d+) stable_stalls=(?P<stable>\d+) "
    r"response_drops=(?P<drops>\d+) ack_idle=(?P<ack_idle>\d+)"
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
        return subprocess.CompletedProcess(command, 124, output +
                                            "timed out\n")


def one_variant(root: Path, verilator: str, build_root: Path, xlen: int,
                multiplier: str, block_rf: bool, max_cycles: int,
                coverage: dict[str, int], rtl_source: Path) -> bool:
    rf_name = "block" if block_rf else "distributed"
    name = f"xlen{xlen}-{multiplier}-{rf_name}"
    mdir = build_root / name
    mdir.mkdir(parents=True, exist_ok=True)
    binary = mdir / "Vriscc_cached_pipeline_tb"

    defines = []
    if multiplier == "soft":
        defines.append("-DRISCC_FAST_SOFT_MUL")
    if block_rf:
        defines.append("-DRISCC_FAST_BLOCK_RF")
    compile_command = [
        verilator, "--binary", "--timing", "-Wno-UNOPTFLAT",
        "-Wno-WIDTH", "-Wno-INITIALDLY",
        "--top-module", "riscc_cached_pipeline_tb", f"-GXLEN={xlen}",
        "--Mdir", str(mdir), *defines,
        str(rtl_source),
        str(root / "rtl/riscc_fast.v"),
        str(root / "test/riscc_cached_pipeline_tb.v"),
    ]
    built = run(compile_command, cwd=root, timeout=120)
    if built.returncode or not binary.exists():
        sys.stderr.write(f"{name}: Verilator build failed\n{built.stdout}")
        return False

    checks: list[tuple[int, str, int]] = [
        (0, "", 0), (1, "", 0), (2, "", 0), (2, "WAIT", 0),
        (3, "", 0), (3, "WAIT", 0), (4, "", 0), (4, "WAIT", 0),
        (6, "", 0), (6, "ACK_HIGH", 0), (9, "", 0), (9, "STALL", 0),
    ]
    checks.extend((case, "STALL", 0) for case in range(5))
    checks.extend((case, "ZERO", 0) for case in range(5))
    checks.extend((case, "MIX", 0) for case in range(5))
    checks.extend((case, "ACK_HIGH", 0) for case in range(5))
    checks.extend((7, mode, 0)
                  for mode in ("", "WAIT", "STALL", "ZERO", "MIX", "ACK_HIGH"))
    checks.extend((10, mode, 0)
                  for mode in ("", "WAIT", "STALL", "ZERO", "MIX", "ACK_HIGH"))
    if xlen == 32:
        checks.extend((8, mode, 0)
                      for mode in ("", "WAIT", "STALL", "ZERO", "MIX", "ACK_HIGH"))
        # The split raw data port carries one complete RC32 native word.
        # Raise IRQ after that accepted request; the handler uses
        # CLI/STI/RETI and checks that EPC is the following instruction.
        checks.extend((5, mode, 1)
                      for mode in ("", "WAIT", "STALL", "ZERO", "MIX"))
    for case, mode, irq_beat in checks:
        command = [str(binary), f"+CASE={case}"]
        if mode:
            command.append(f"+{mode}")
        if irq_beat:
            command.append(f"+IRQ_BEAT={irq_beat}")
        result = run(command, cwd=root, timeout=30)
        output = result.stdout
        match = PASS_RE.search(output)
        if result.returncode or not match:
            label = f"case={case}{' ' + mode.lower() if mode else ''}"
            if irq_beat:
                label += f" beat{irq_beat}"
            sys.stderr.write(f"{name} {label} failed\n{output}")
            return False
        if int(match.group("case")) != case or int(match.group("xlen")) != xlen:
            sys.stderr.write(f"{name} {case}: malformed PASS line\n{output}")
            return False
        if int(match.group("cycles")) > max_cycles:
            sys.stderr.write(f"{name} {case}: cycle limit exceeded\n{output}")
            return False
        for key in ("early", "ack_stalls", "stalls", "stable", "drops",
                    "ack_idle"):
            coverage[key] += int(match.group(key))
        suffix = f" {mode.lower()}" if mode else ""
        if irq_beat:
            suffix += f" beat{irq_beat}"
        print(f"{name} case={case}{suffix}: {match.group(0)}")
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path,
                        default=Path(__file__).resolve().parents[1])
    parser.add_argument("--rtl", type=Path,
                        help="Cached RTL source to compile (defaults to rtl/riscc_cached.v)")
    parser.add_argument("--verilator", default=shutil.which("verilator") or "verilator")
    parser.add_argument("--build-dir", type=Path,
                        default=Path("build/test-cached-pipeline"))
    parser.add_argument("--max-cycles", type=int, default=10_000)
    parser.add_argument("--no-block-rf", action="store_true",
                        help="skip the block-RF mapping")
    args = parser.parse_args()
    root = args.root.resolve()
    build_root = args.build_dir
    if not build_root.is_absolute():
        build_root = root / build_root
    rtl_source = args.rtl or (root / "rtl/riscc_cached.v")
    if not rtl_source.is_absolute():
        rtl_source = root / rtl_source
    rtl_source = rtl_source.resolve()

    variants = [(xlen, multiplier, block_rf)
                for xlen in (16, 32)
                for multiplier in ("dsp", "soft")
                for block_rf in ((False, True) if not args.no_block_rf else (False,))]
    coverage = {key: 0 for key in ("early", "ack_stalls", "stalls", "stable",
                                   "drops", "ack_idle")}
    for xlen, multiplier, block_rf in variants:
        if not one_variant(root, args.verilator, build_root, xlen, multiplier,
                           block_rf, args.max_cycles, coverage, rtl_source):
            return 1
    if not coverage["early"]:
        sys.stderr.write("Cached pipeline coverage failed: no same-cycle ACK\n")
        return 1
    if not coverage["ack_stalls"] or not coverage["stable"]:
        sys.stderr.write("Cached pipeline coverage failed: no ACK+STALL/stable hold\n")
        return 1
    if not coverage["ack_idle"]:
        sys.stderr.write("Cached pipeline coverage failed: no held idle ACK\n")
        return 1
    print(f"Cached pipeline cycle checks PASS ({len(variants)} variants, "
          f"44 base cases plus 11 RC32-specific cases; early_acks={coverage['early']} "
          f"ack_stalls={coverage['ack_stalls']} stalls={coverage['stalls']} "
          f"stable_stalls={coverage['stable']} response_drops={coverage['drops']} "
          f"ack_idle={coverage['ack_idle']})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

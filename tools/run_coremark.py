#!/usr/bin/env python3
"""Run unchanged CoreMark workloads; short runs are never published scores."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CRCS = {
    "performance": {
        "seedcrc": 0xe9f5,
        "crclist": 0xe714,
        "crcmatrix": 0x1fd7,
        "crcstate": 0x8e3a,
    },
    "validation": {
        "seedcrc": 0x18f2,
        "crclist": 0xe3c1,
        "crcmatrix": 0x0747,
        "crcstate": 0x8d84,
    },
}
SHORT_WARNING = "ERROR! Must execute for at least 10 secs for a valid result!"
TICKS_RE = re.compile(
    r"^RISCC_COREMARK ticks_hi=(\d+) ticks_lo=(\d+) iterations=(\d+) "
    r"hz=(\d+) short=(\d+) errors=(\d+)$", re.MULTILINE)


def check_sources(root: Path = ROOT) -> dict:
    source = root / "external/coremark"
    manifest = json.loads((source / "UPSTREAM.json").read_text())
    for name, expected in manifest["files"].items():
        actual = hashlib.sha256((source / name).read_bytes()).hexdigest()
        if actual != expected:
            raise ValueError(f"modified upstream CoreMark source: {name}")
    return manifest


def parse_output(output: str, mode: str, iterations: int, clock_hz: int) -> dict:
    for line in output.splitlines():
        if "ERROR" in line and line != SHORT_WARNING:
            raise ValueError(line)
        if "Cannot validate" in line:
            raise ValueError(line)
    crcs = {}
    for name, expected in CRCS[mode].items():
        matches = re.findall(
            rf"^(?:\[0\])?{name}\s*:\s*0x([0-9a-fA-F]+)\s*$",
            output,
            re.MULTILINE,
        )
        if len(matches) != 1 or int(matches[0], 16) != expected:
            raise ValueError(
                f"missing or incorrect {name}: {matches}, expected {expected:#06x}"
            )
        crcs[name] = f"0x{expected:04x}"
    if not re.search(r"^\[0\]crcfinal\s*:\s*0x[0-9a-fA-F]+\s*$", output, re.MULTILINE):
        raise ValueError("missing final CRC")
    if not re.search(rf"^Iterations\s*:\s*{iterations}\s*$", output, re.MULTILINE):
        raise ValueError("incorrect iteration count")
    matches = TICKS_RE.findall(output)
    if len(matches) != 1:
        raise ValueError("missing or duplicate timing summary")
    high, low, count, hz, short, errors = map(int, matches[0])
    if count != iterations or hz != clock_hz or errors or high >= 2**32 or low >= 2**32:
        raise ValueError("incorrect timing summary")
    cycles = (high << 32) | low
    if cycles <= 0:
        raise ValueError("RTL timer did not advance")
    compliant_duration = cycles >= 10 * clock_hz
    if short != int(not compliant_duration) or (SHORT_WARNING in output) != bool(short):
        raise ValueError("duration and upstream short-run warning disagree")
    if compliant_duration and "Correct operation validated." not in output:
        raise ValueError("missing upstream validation success")
    result = {
        "status": "PASS",
        "crcs": crcs,
        "iterations": iterations,
        "timed_cycles": cycles,
        "cycles_per_iteration": cycles / iterations,
        "target_clock_hz": clock_hz,
        "duration_seconds": cycles / clock_hz,
        "compliant_duration": compliant_duration,
    }
    if compliant_duration and mode == "performance":
        result["coremark_per_mhz"] = iterations * 1_000_000 / cycles
    return result


def parse_core(value: str) -> tuple[str, Path]:
    name, separator, path = value.partition("=")
    if not separator or name not in ("sram", "cached") or not path:
        raise argparse.ArgumentTypeError("RTL core must be sram=PATH or cached=PATH")
    return name, Path(path).resolve()


def run(args: argparse.Namespace) -> dict:
    manifest = check_sources()
    compiler = subprocess.check_output([args.compiler, "--version"], text=True)
    report = {
        "benchmark": "CoreMark",
        "upstream_commit": manifest["commit"],
        "compiler": compiler.splitlines()[0],
        "optimization": args.optimization,
        "library_optimization": args.library_optimization,
        "architecture": "RC32 Full, hardware multiply, software division",
        "memory": "64 KiB unified SRAM, one-clock native-width responses",
        "cycle_counter_base": args.cycle_base,
        "rtl_defines": ["RISCC_FAST_BLOCK_RF", "RISCC_ECP5"],
        "source_sha256": {
            name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
            for name in (
                "rtl/riscc_cached.v",
                "rtl/riscc_pipeline_shared.v",
                "rtl/riscc_rf.vh",
                "test/riscc_coremark_tb.v",
                "test/compiler/coremark/core_portme.c",
                "test/compiler/coremark/core_portme.h",
                "test/compiler/coremark/link.ld",
            )
        },
        "note": (
            "Short runs report cycles/iteration only, not a compliant CoreMark "
            "score. ISS is correctness-only."
        ),
        "runs": [],
    }
    for mode in CRCS:
        image = args.build_dir / mode / "coremark.bin"
        data = image.read_bytes()
        if len(data) > 0xfff0:
            raise ValueError(f"image exceeds fixture SRAM: {image}")
        memh = image.with_suffix(".memh")
        memh.write_text(
            "".join(
                f"{int.from_bytes(data[i:i+2], 'little'):04x}\n"
                for i in range(0, len(data), 2)
            )
        )
        sizes = subprocess.check_output(
            [args.size_tool, "-A", image.with_suffix(".elf")], text=True
        )
        size_sections = {
            name: int(size)
            for name, size in re.findall(
                r"^(\.\S+)\s+(\d+)\s+\d+$", sizes, re.MULTILINE
            )
        }
        jobs = []
        if args.iss:
            jobs.append(
                (
                    "iss",
                    [
                        str(args.iss.resolve()),
                        str(image.resolve()),
                        "--rc32-full",
                        "--max-insns",
                        str(args.max_insns),
                    ],
                )
            )
        for name, binary in args.rtl or []:
            jobs.append(
                (
                    name,
                    [
                        str(binary),
                        f"+IMAGE={memh.resolve()}",
                        f"+MAX_CYCLES={args.max_cycles}",
                        f"+CYCLE_BASE={args.cycle_base}",
                    ],
                )
            )
        for name, command in jobs:
            log = args.build_dir / f"{mode}-{name}.log"
            try:
                completed = subprocess.run(
                    command,
                    cwd=ROOT,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    timeout=args.timeout,
                )
            except subprocess.TimeoutExpired as error:
                partial = error.stdout or b""
                if isinstance(partial, bytes):
                    partial = partial.decode(errors="replace")
                log.write_text(partial + "\nCoreMark simulator timed out\n")
                raise ValueError(f"{mode}/{name}: timeout; see {log}") from error
            log.write_text(completed.stdout)
            if completed.returncode:
                raise ValueError(f"{mode}/{name}: simulator failed; see {log}")
            if name == "iss":
                if not re.search(r"result=0x600d:\s+PASS", completed.stdout, re.IGNORECASE):
                    raise ValueError(f"{mode}/iss: incorrect terminal result; see {log}")
                result = {
                    "status": "PASS",
                    "validation": "upstream CRC/type checks via port status",
                    "timing": "not measured; ISS used for correctness only",
                }
            else:
                result = parse_output(completed.stdout, mode, args.iterations, args.clock_hz)
                expected = 1 if name == "cached" else 0
                if not re.search(
                    rf"^COREMARK_DONE cached={expected} cycles=\d+$",
                    completed.stdout,
                    re.MULTILINE,
                ):
                    raise ValueError(f"{mode}/{name}: missing terminal result")
            result.update(
                {
                    "mode": mode,
                    "core": name,
                    "image_bytes": len(data),
                    "sections": size_sections,
                    "image_sha256": hashlib.sha256(data).hexdigest(),
                    "log": str(log),
                }
            )
            report["runs"].append(result)
            timing = (
                f", {result['cycles_per_iteration']:.2f} cycles/iteration"
                if "timed_cycles" in result
                else ""
            )
            print(f"PASS CoreMark {mode}/{name}: {len(data)} bytes{timing}", flush=True)
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, required=True)
    parser.add_argument("--compiler", type=Path, default=ROOT / "build/llvm-riscc/bin/clang")
    parser.add_argument("--size-tool", type=Path, default=ROOT / "build/llvm-riscc/bin/llvm-size")
    parser.add_argument("--iterations", type=int, required=True)
    parser.add_argument("--clock-hz", type=int, required=True)
    parser.add_argument("--optimization", required=True)
    parser.add_argument("--library-optimization", required=True)
    parser.add_argument("--iss", type=Path)
    parser.add_argument("--rtl", action="append", type=parse_core)
    parser.add_argument("--max-insns", type=int, default=200_000_000)
    parser.add_argument("--max-cycles", type=int, default=200_000_000)
    parser.add_argument("--timeout", type=int, default=300)
    parser.add_argument("--cycle-base", type=int, default=0)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not (args.iss or args.rtl) or args.iterations <= 0 or args.clock_hz <= 0:
        parser.error("select a simulator and positive iterations/clock rate")
    try:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        report = run(args)
        report["status"] = "PASS"
        args.output.write_text(json.dumps(report, indent=2) + "\n")
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(error, file=sys.stderr)
        # Do not leave a previous successful report looking like this run.
        args.output.write_text(
            json.dumps({"status": "FAIL", "error": str(error)}, indent=2) + "\n"
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Run compiler benchmark images through the existing RTL testbenches."""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


DONE_RE = re.compile(
    r"done after\s+(?P<cycles>\d+)\s+cycles,\s+"
    r"result=0x(?P<result>[0-9a-f]+):\s+(?P<status>PASS|FAIL)",
    re.IGNORECASE,
)
TIMEOUT_RE = re.compile(r"TIMEOUT after\s+(?P<cycles>\d+)\s+cycles", re.IGNORECASE)
NATIVE_PASS_RE = re.compile(
    r"^PASS\s+XLEN=\d+\s+CACHED=\d+\s+(?P<metrics>[^\r\n]+)$",
    re.MULTILINE,
)
METRIC_RE = re.compile(r"(?P<name>\w+)=(?P<value>\d+)")
MARKER_RE = re.compile(r"^MARKER cycle=(\d+) value=(\d+)$", re.MULTILINE)
NATIVE_MAX_IMAGE_BYTES = 64 * 1024


def parse_core(value: str) -> tuple[str, Path]:
    name, separator, path = value.partition("=")
    if not separator or not name or not path:
        raise argparse.ArgumentTypeError("core must be NAME=PATH")
    return name, Path(path)


def native_memh(image: Path) -> Path:
    data = image.read_bytes()
    if len(data) > NATIVE_MAX_IMAGE_BYTES:
        raise ValueError(f"native benchmark image exceeds 64 KiB: {image}")
    memh = image.with_suffix(".memh")
    words = (data[i] | ((data[i + 1] if i + 1 < len(data) else 0) << 8)
             for i in range(0, len(data), 2))
    memh.write_text("".join(f"{word:04x}\n" for word in words), encoding="ascii")
    return memh


def run_core(core_name: str, testbench: Path, image: Path, memh: Path | None,
             max_cycles: int, timeout: float, native: bool) -> tuple[dict, str]:
    if not testbench.is_file() or not testbench.stat().st_mode & 0o111:
        raise FileNotFoundError(f"missing or non-executable RTL testbench: {testbench}")
    command = ([str(testbench), f"+IMAGE={memh}", f"+MAX_CYCLES={max_cycles}"
                ] if native else [str(testbench), str(image), "--max-cycles",
                                  str(max_cycles)])
    timed = image.stem == "dhrystone"
    if timed:
        command += (["+REPORT_WRITE=fffc"] if native else
                    ["--report-write", "0xfffc"])
    result = {"core": core_name, "image": str(image), "testbench": str(testbench)}
    output = ""
    try:
        completed = subprocess.run(
            command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, timeout=timeout, check=False,
        )
    except subprocess.TimeoutExpired as exc:
        output = exc.stdout or b""
        if isinstance(output, bytes):
            output = output.decode(errors="replace")
        timeout_match = TIMEOUT_RE.search(output)
        if timeout_match:
            result["cycles"] = int(timeout_match.group("cycles"))
        result["status"] = "TIMEOUT"
    else:
        output = completed.stdout
        if native:
            match = NATIVE_PASS_RE.search(output)
            if match:
                metrics = {metric.group("name"): int(metric.group("value"))
                           for metric in METRIC_RE.finditer(match.group("metrics"))}
                if "cycles" in metrics:
                    result["cycles"] = metrics["cycles"]
                    for name in ("commits", "backing_reads", "backing_writes",
                                 "i_refills", "d_refills"):
                        if name in metrics:
                            result[name] = metrics[name]
                    result["status"] = "PASS" if completed.returncode == 0 else "FAIL"
                else:
                    result["status"] = "FAIL"
            else:
                timeout_match = TIMEOUT_RE.search(output)
                if timeout_match:
                    result["cycles"] = int(timeout_match.group("cycles"))
                    result["status"] = "TIMEOUT"
                else:
                    result["status"] = "FAIL"
        else:
            match = DONE_RE.search(output)
            if match:
                result["cycles"] = int(match.group("cycles"))
                value = int(match.group("result"), 16)
                result["result"] = f"0x{value:04X}"
                passed = (completed.returncode == 0 and value == 0x600D
                          and match.group("status").upper() == "PASS")
                result["status"] = "PASS" if passed else "FAIL"
            elif timeout_match := TIMEOUT_RE.search(output):
                result["cycles"] = int(timeout_match.group("cycles"))
                result["status"] = "TIMEOUT"
            else:
                result["status"] = "FAIL"
        if timed and result["status"] == "PASS":
            markers = [tuple(map(int, m)) for m in MARKER_RE.findall(output)]
            if (len(markers) != 2 or markers[0][1] <= 0 or markers[1][1] != 0
                    or markers[1][0] <= markers[0][0]):
                result["status"] = "FAIL"
                output += "\nMissing or invalid benchmark timing markers\n"
            else:
                result["loop_cycles"] = markers[1][0] - markers[0][0]
                result["iterations"] = markers[0][1]
                result["dmips_per_mhz"] = (
                    result["iterations"] * 1_000_000 / (1757 * result["loop_cycles"]))
    return result, output


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--benchmark-root", type=Path, required=True)
    parser.add_argument("--benchmarks", nargs="+", required=True)
    parser.add_argument("--opt-levels", nargs="+", required=True)
    parser.add_argument("--core", action="append", type=parse_core)
    parser.add_argument("--native-core", action="append", type=parse_core)
    parser.add_argument("--max-cycles", type=int, required=True)
    parser.add_argument("--timeout", type=float, required=True)
    parser.add_argument("--xlen", type=int, required=True)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not args.core and not args.native_core:
        parser.error("at least one --core or --native-core is required")

    results = []
    failures = 0
    native_images = {}
    for opt_level in args.opt_levels:
        for benchmark in args.benchmarks:
            image = args.benchmark_root / opt_level / f"{benchmark}.bin"
            if not image.is_file():
                print(f"missing benchmark image: {image}", file=sys.stderr)
                return 2
            memh = None
            if args.native_core:
                try:
                    if image not in native_images:
                        native_images[image] = native_memh(image)
                    memh = native_images[image]
                except (OSError, ValueError) as exc:
                    print(exc, file=sys.stderr)
                    return 2
            for native, cores in ((False, args.core or []), (True, args.native_core or [])):
                for core_name, testbench in cores:
                    try:
                        result, output = run_core(
                            core_name, testbench, image, memh, args.max_cycles,
                            args.timeout, native,
                        )
                    except FileNotFoundError as exc:
                        print(exc, file=sys.stderr)
                        return 2
                    result.update({"benchmark": benchmark, "opt_level": opt_level})
                    results.append(result)
                    label = f"{core_name} {opt_level} {benchmark}"
                    if result["status"] == "PASS":
                        timing = (f", {result['loop_cycles']} loop cycles, "
                                  f"{result['dmips_per_mhz']:.3f} DMIPS/MHz"
                                  if "loop_cycles" in result else "")
                        print(f"{label}: {result['cycles']} cycles{timing} PASS", flush=True)
                    else:
                        failures += 1
                        print(f"{label}: {result['status']}\n{output}", file=sys.stderr)

    document = {
        "xlen": args.xlen,
        "profile": args.profile,
        "max_cycles": args.max_cycles,
        "status": "PASS" if failures == 0 else "FAIL",
        "failures": failures,
        "results": results,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(document, indent=2) + "\n")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())

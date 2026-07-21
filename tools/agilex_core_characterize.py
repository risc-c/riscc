#!/usr/bin/env python3
"""Characterize Tiny and Nano core-only Agilex 3 implementations.

Every project uses the same registered timing harness and explicitly selects
the shared MLAB register-file implementation.  Results are generated under
build/ and are intentionally not source-controlled.
"""

import argparse
import re
import subprocess
from pathlib import Path


DEVICE = "A3CZ135BB18AE7S"
TARGET_NS = 4.0


def project_specs(root: Path):
    top = root / "rtl/test/riscc_fmax_top.v"
    specs = []
    for profile, rtl, profile_macro in (
        ("min", root / "rtl/riscc_tiny_min.v", "RISCC_FMAX_MIN"),
        ("sys", root / "rtl/riscc_tiny_sys.v", None),
        ("full", root / "rtl/riscc_tiny_full.v", None),
    ):
        for width in (1, 2, 4, 8):
            macros = ["RISCC_FMAX_TINY", f"RISCC_FMAX_WIDTH={width}"]
            if profile_macro:
                macros.append(profile_macro)
            specs.append((f"{profile}{width}", profile, width, rtl, macros, top))
    specs.extend(
        (
            ("min16", "min", 16, root / "rtl/riscc_tiny16_min.v",
             ["RISCC_FMAX_TINY16_MIN"], top),
            ("sys16", "sys", 16, root / "rtl/riscc_tiny16_sys.v", [], top),
            ("full16", "full", 16, root / "rtl/riscc_tiny16_full.v", [], top),
            ("nano", "nano", 1, root / "rtl/riscc_nano1.v",
             ["RISCC_FMAX_NANO"], top),
        )
    )
    return specs


def write_project(directory: Path, name: str, root: Path, rtl: Path,
                  macros, top: Path, jobs: int):
    directory.mkdir(parents=True, exist_ok=True)
    (directory / f"{name}.qpf").write_text(
        f'QUARTUS_VERSION = "26.1"\nPROJECT_REVISION = "{name}"\n')
    qsf = [
        'set_global_assignment -name FAMILY "Agilex 3"',
        f"set_global_assignment -name DEVICE {DEVICE}",
        "set_global_assignment -name TOP_LEVEL_ENTITY riscc_fmax_top",
        f"set_global_assignment -name SEARCH_PATH {root}",
        f"set_global_assignment -name VERILOG_FILE {rtl}",
        f"set_global_assignment -name VERILOG_FILE {top}",
        "set_global_assignment -name VERILOG_MACRO RISCC_INFERRED_SYNC_RF",
        f"set_global_assignment -name SDC_FILE {directory / (name + '.sdc')}",
        f"set_global_assignment -name NUM_PARALLEL_PROCESSORS {jobs}",
        'set_global_assignment -name OPTIMIZATION_MODE "HIGH PERFORMANCE EFFORT"',
        'set_global_assignment -name LAST_QUARTUS_VERSION "26.1.0 Pro Edition"',
    ]
    qsf.extend(f"set_global_assignment -name VERILOG_MACRO {macro}"
               for macro in macros)
    (directory / f"{name}.qsf").write_text("\n".join(qsf) + "\n")
    (directory / f"{name}.sdc").write_text(
        f"create_clock -name clk -period {TARGET_NS:.3f} [get_ports {{clk}}]\n")


def parse_results(directory: Path, name: str):
    place = (directory / f"{name}.fit.place.rpt").read_text()
    cpu = re.search(r"^;\s*\|cpu\|.*?;\s*([0-9.]+)\s+\(", place,
                    flags=re.MULTILINE)
    if not cpu:
        raise RuntimeError(f"could not find CPU ALMs in {name}.fit.place.rpt")
    sta = (directory / f"{name}.sta.rpt").read_text()
    slack = re.search(r"Worst-case setup slack is\s+(-?[0-9.]+)", sta)
    if not slack:
        raise RuntimeError(f"could not find setup slack in {name}.sta.rpt")
    fmax = 1000.0 / (TARGET_NS - float(slack.group(1)))
    return float(cpu.group(1)), fmax


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--quartus", required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--jobs", type=int, default=8)
    parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[1]
    output_dir = args.out.resolve()
    quartus_dir = Path(args.quartus).resolve().parent
    quartus_syn = quartus_dir / "quartus_syn"
    quartus_fit = quartus_dir / "quartus_fit"
    quartus_sta = quartus_dir / "quartus_sta"
    if not all(tool.is_file() for tool in (quartus_syn, quartus_fit, quartus_sta)):
        raise RuntimeError(f"could not find Quartus tools beside {args.quartus}")
    results = []
    for name, profile, width, rtl, macros, top in project_specs(root):
        directory = output_dir / name
        write_project(directory, name, root, rtl, macros, top, args.jobs)
        if args.prepare_only:
            continue
        subprocess.run([quartus_syn, name, "-c", name],
                       cwd=directory, check=True)
        subprocess.run([quartus_fit, name, "-c", name, "--plan", "--place",
                        "--route", "--retime", "--finalize"],
                       cwd=directory, check=True)
        subprocess.run([quartus_sta, name, "-c", name],
                       cwd=directory, check=True)
        alms, fmax = parse_results(directory, name)
        results.append((profile, width, alms, fmax))
        print(f"{name}: {alms:.1f} ALMs, {fmax:.2f} MHz", flush=True)

    if args.prepare_only:
        return

    output = output_dir / "results.tsv"
    output.write_text("profile\twidth\talms\tfmax_mhz\n" + "".join(
        f"{profile}\t{width}\t{alms:.1f}\t{fmax:.2f}\n"
        for profile, width, alms, fmax in results))


if __name__ == "__main__":
    main()

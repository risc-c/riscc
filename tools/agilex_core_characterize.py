#!/usr/bin/env python3
"""Characterize core-only Agilex 3 implementations.

Every project uses the same registered timing harness and explicitly selects
the shared MLAB register-file implementation.  Results are generated under
build/ and are intentionally not source-controlled.
"""

import argparse
import concurrent.futures
import csv
import re
import shutil
import subprocess
from pathlib import Path


DEVICE = "A3CZ135BB18AE7S"
FIT_SEED = 1
TARGET_NS = 4.0
AREA_OPTIMIZATION = "AGGRESSIVE AREA"
PERFORMANCE_OPTIMIZATION = "HIGH PERFORMANCE EFFORT"
AREA_PROFILES = {"full", "rc32full", "mulh", "muldiv"}
AUTO_CONFIG_MEMORY_KIB = 3 * 1024 * 1024


def available_memory_kib():
    try:
        for line in Path("/proc/meminfo").read_text().splitlines():
            if line.startswith("MemAvailable:"):
                return int(line.split()[1])
    except (OSError, ValueError, IndexError):
        pass
    return None


def project_specs(root: Path, family: str):
    top = root / "rtl/test/riscc_fmax_top.v"
    specs = []
    if family in ("rc16", "all"):
        for profile, rtl, profile_macro in (
            ("min", root / "rtl/riscc_min.v", "RISCC_FMAX_MIN"),
            ("sys", root / "rtl/riscc_sys.v", None),
            ("full", root / "rtl/riscc_full.v", None),
        ):
            for width in (1, 2, 4, 8):
                macros = ["RISCC_FMAX_RC16", f"RISCC_FMAX_WIDTH={width}"]
                if profile_macro:
                    macros.append(profile_macro)
                specs.append(
                    (f"{profile}{width}", profile, width, rtl, macros, top))
        specs.extend(
            (
                ("min16", "min", 16, root / "rtl/riscc16_min.v",
                 ["RISCC_FMAX_RC16_MIN"], top),
                ("sys16", "sys", 16, root / "rtl/riscc16_sys.v",
                 [], top),
                ("full16", "full", 16, root / "rtl/riscc16_full.v",
                 [], top),
                ("nano", "nano", 1, root / "rtl/riscc_nano.v",
                 ["RISCC_FMAX_NANO"], top),
            )
        )
    if family in ("rc32", "all"):
        for profile, rtl, macro in (
            ("rc32min", root / "rtl/riscc32_min.v", "RISCC_FMAX_RC32_MIN"),
            ("rc32sys", root / "rtl/riscc32_sys.v", "RISCC_FMAX_RC32_SYS"),
            ("rc32full", root / "rtl/riscc32_full.v", "RISCC_FMAX_RC32_FULL"),
        ):
            for width in (1, 2, 4, 8, 16):
                specs.append((
                    f"{profile}{width}", profile, width, rtl,
                    [macro, f"RISCC_FMAX_WIDTH={width}"], top,
                ))
    if family in ("other", "all"):
        specs.extend((
            ("mulh16", "mulh", 16, root / "rtl/riscc16_full_mulh.v",
             [], top),
            ("muldiv16", "muldiv", 16,
             root / "rtl/riscc16_full_muldiv.v", [], top),
            ("fast_soft", "fast_soft", 16, root / "rtl/riscc16_fast.v",
             ["RISCC_FMAX_FAST", "RISCC_FAST_AGILEX"], top),
            ("fast_dsp", "fast_dsp", 16, root / "rtl/riscc16_fast.v",
             ["RISCC_FMAX_FAST", "RISCC_FAST_AGILEX", "RISCC_FAST_DSP"],
             top),
            ("faster_dsp", "faster_dsp", 16,
             root / "rtl/riscc16_faster.v", ["RISCC_FMAX_FASTER"], top),
            ("faster_soft", "faster_soft", 16,
             root / "rtl/riscc16_faster.v",
             ["RISCC_FMAX_FASTER", "RISCC_FASTER_SOFT_MUL"], top),
        ))
    return specs


def write_project(directory: Path, name: str, profile: str, root: Path,
                  rtl: Path, macros, top: Path, jobs: int):
    directory.mkdir(parents=True, exist_ok=True)
    (directory / f"{name}.qpf").write_text(
        f'QUARTUS_VERSION = "26.1"\nPROJECT_REVISION = "{name}"\n')
    optimization = (AREA_OPTIMIZATION if profile in AREA_PROFILES
                    else PERFORMANCE_OPTIMIZATION)
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
        f"set_global_assignment -name SEED {FIT_SEED}",
        f'set_global_assignment -name OPTIMIZATION_MODE "{optimization}"',
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
    fmax_match = re.search(
        r"^;\s*([0-9.]+) MHz\s*;\s*[0-9.]+ MHz\s*;\s*clk\s*;",
        sta, flags=re.MULTILINE)
    if not fmax_match:
        raise RuntimeError(f"could not find Fmax in {name}.sta.rpt")
    fmax = float(fmax_match.group(1))
    return float(cpu.group(1)), fmax


def read_results(path: Path):
    if not path.is_file():
        return {}
    with path.open(newline="") as stream:
        return {
            (row["profile"], int(row["width"])):
                (float(row["alms"]), float(row["fmax_mhz"]))
            for row in csv.DictReader(stream, delimiter="\t")
        }


def write_results(path: Path, results):
    path.write_text("profile\twidth\talms\tfmax_mhz\n" + "".join(
        f"{profile}\t{width}\t{alms:.1f}\t{fmax:.2f}\n"
        for (profile, width), (alms, fmax) in sorted(results.items())))


def characterize(spec, output_dir: Path, root: Path, quartus_syn: Path,
                 quartus_fit: Path, quartus_sta: Path, project_jobs: int,
                 prepare_only: bool):
    name, profile, width, rtl, macros, top = spec
    directory = output_dir / name
    write_project(directory, name, profile, root, rtl, macros, top,
                  project_jobs)
    if prepare_only:
        return None
    log_path = directory / f"{name}.build.log"
    commands = (
        [quartus_syn, name, "-c", name],
        [quartus_fit, name, "-c", name, "--plan", "--place", "--route",
         "--retime", "--finalize"],
        [quartus_sta, name, "-c", name],
    )
    with log_path.open("w") as log:
        for command in commands:
            subprocess.run(command, cwd=directory, check=True,
                           stdout=log, stderr=subprocess.STDOUT)
    alms, fmax = parse_results(directory, name)
    return name, profile, width, alms, fmax


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--quartus", required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--jobs", type=int, default=8)
    parser.add_argument(
        "--parallel-configs", type=int, default=0,
        help=("independent Quartus projects to compile concurrently; "
              "0 selects one project per two --jobs threads, capped by "
              "available memory"))
    parser.add_argument("--family", choices=("rc16", "rc32", "other", "all"),
                        default="rc16")
    parser.add_argument("--only", action="append", default=[], metavar="NAME",
                        help="characterize only this configuration (repeatable)")
    parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args()
    if args.jobs < 1 or args.parallel_configs < 0:
        parser.error("--jobs must be positive and --parallel-configs nonnegative")

    root = Path(__file__).resolve().parents[1]
    output_dir = args.out.resolve()
    quartus_sh = shutil.which(args.quartus)
    if quartus_sh is None:
        quartus_sh = args.quartus
    quartus_dir = Path(quartus_sh).resolve().parent
    quartus_syn = quartus_dir / "quartus_syn"
    quartus_fit = quartus_dir / "quartus_fit"
    quartus_sta = quartus_dir / "quartus_sta"
    if not all(tool.is_file() for tool in (quartus_syn, quartus_fit, quartus_sta)):
        raise RuntimeError(f"could not find Quartus tools beside {args.quartus}")
    specs = project_specs(root, args.family)
    if args.only:
        requested = set(args.only)
        known = {name for name, *_ in specs}
        unknown = requested - known
        if unknown:
            parser.error("unknown configuration(s): " + ", ".join(sorted(unknown)))
        specs = [spec for spec in specs if spec[0] in requested]

    results_path = output_dir / "results.tsv"
    # Family/subset runs update the canonical result set. Only a complete
    # all-family run replaces it wholesale.
    results = (
        read_results(results_path)
        if args.only or args.family != "all"
        else {}
    )
    if args.parallel_configs:
        parallel_configs = args.parallel_configs
    else:
        parallel_configs = max(1, (args.jobs + 1) // 2)
        memory_kib = available_memory_kib()
        if memory_kib is not None:
            parallel_configs = min(
                parallel_configs,
                max(1, memory_kib // AUTO_CONFIG_MEMORY_KIB))
    parallel_configs = min(parallel_configs, len(specs))
    project_jobs = max(1, args.jobs // parallel_configs)
    print(f"Quartus concurrency: {parallel_configs} projects, "
          f"{project_jobs} threads/project ({args.jobs} total jobs)", flush=True)
    with concurrent.futures.ThreadPoolExecutor(
            max_workers=parallel_configs) as executor:
        pending = [
            executor.submit(
                characterize, spec, output_dir, root, quartus_syn,
                quartus_fit, quartus_sta, project_jobs, args.prepare_only)
            for spec in specs
        ]
        for future in concurrent.futures.as_completed(pending):
            characterized = future.result()
            if characterized is None:
                continue
            name, profile, width, alms, fmax = characterized
            results[(profile, width)] = (alms, fmax)
            print(f"{name}: {alms:.1f} ALMs, {fmax:.2f} MHz", flush=True)

    if args.prepare_only:
        return

    write_results(results_path, results)


if __name__ == "__main__":
    main()

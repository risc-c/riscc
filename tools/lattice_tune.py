#!/usr/bin/env python3
"""Search Lattice mapper recipes and place-and-route seeds in parallel."""

import argparse
import csv
import os
import re
import shlex
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path


# Keep the search combinationally equivalent to the RTL.  Yosys sequential
# retiming is intentionally excluded: a retimed Fast netlist passed synthesis
# but failed both the normal and wait-state gate-level regressions.
RECIPES = {
    "ecp5": {
        "default": "",
        "dff": "-dff",
        "abc2": "-abc2",
        "abc2-dff": "-abc2 -dff",
        "abc9": "-abc9",
        "abc9-dff": "-abc9 -dff",
        "noccu2": "-noccu2",
        "noccu2-dff": "-noccu2 -dff",
    },
}

CORES = (
    "min", "sys", "full", "rc32-min", "rc32-sys", "nano",
    "mulh", "muldiv", "fast-soft", "fast-dsp",
    "faster-soft", "faster-dsp",
)
WIDTHS = (1, 2, 4, 8, 16)
MATRIX_CORES = ("min", "sys", "full", "rc32-min", "rc32-sys")
OTHER_CORES = ("nano", "mulh", "muldiv", "fast-soft", "fast-dsp",
               "faster-soft", "faster-dsp")


@dataclass(frozen=True)
class CoreSpec:
    source: Path
    top: str
    defines: tuple[str, ...]
    block_defines: tuple[str, ...]
    synth_options: tuple[str, ...] = ()
    width: int | None = None


@dataclass(frozen=True)
class SynthResult:
    recipe: str
    options: str
    json: Path
    area: int
    block_area: int | None = None


def core_spec(root: Path, target: str, core: str, width: int) -> CoreSpec:
    rtl = root / "rtl"
    defines = []
    synth_options = []

    if target == "ecp5":
        defines.append("RISCC_ECP5")

    if core in ("min", "sys", "full"):
        if width not in (1, 2, 4, 8, 16):
            raise ValueError("RC16 width must be 1, 2, 4, 8, or 16")
        if width == 16:
            source = rtl / f"riscc16_{core}.v"
            top = "riscc16_min" if core == "min" else "riscc16"
            if core == "min":
                defines.append("RISCC_FMAX_RC16_MIN")
        else:
            source = rtl / f"riscc_{core}.v"
            top = "riscc_min" if core == "min" else "riscc"
            defines.extend(("RISCC_FMAX_RC16", f"RISCC_FMAX_WIDTH={width}"))
            if core == "min":
                defines.append("RISCC_FMAX_MIN")
    elif core in ("rc32-min", "rc32-sys"):
        if width not in (1, 2, 4, 8, 16):
            raise ValueError("RC32 width must be 1, 2, 4, 8, or 16")
        profile = core.removeprefix("rc32-")
        source = rtl / f"riscc32_{profile}.v"
        top = f"riscc32_{profile}"
        defines.extend((f"RISCC_FMAX_RC32_{profile.upper()}",
                        f"RISCC_FMAX_WIDTH={width}"))
    elif core == "nano":
        source = rtl / "riscc_nano.v"
        top = "riscc_nano"
        defines.append("RISCC_FMAX_NANO")
    elif core in ("mulh", "muldiv"):
        source = rtl / f"riscc16_full_{core}.v"
        top = "riscc16"
    elif core.startswith("fast-"):
        source = rtl / "riscc16_fast.v"
        top = "riscc16_fast"
        defines.append("RISCC_FMAX_FAST")
        if core.endswith("dsp"):
            defines.append("RISCC_FAST_DSP")
    else:
        source = rtl / "riscc16_faster.v"
        top = "riscc16_faster"
        defines.append("RISCC_FMAX_FASTER")
        if core.endswith("soft"):
            defines.append("RISCC_FASTER_SOFT_MUL")

    parameter_width = (
        width if core.startswith("rc32-") or
        (core in ("min", "sys", "full") and width != 16) else None
    )
    block_defines = list(defines)
    if core.startswith("fast-"):
        block_defines.remove("RISCC_ECP5")
        block_defines.append("RISCC_FAST_SYNC_RF")
    elif core.startswith("faster-"):
        block_defines.remove("RISCC_ECP5")
        block_defines.append("RISCC_FASTER_BLOCK_RF")
    else:
        block_defines.append("RISCC_ECP5_BLOCK_RF")
    return CoreSpec(source, top, tuple(defines), tuple(block_defines),
                    tuple(synth_options), parameter_width)


def run(command, cwd: Path):
    return subprocess.run(command, cwd=cwd, text=True,
                          stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, check=True).stdout


def check_synthesis(log: str):
    if "Warning: ABC: execution" in log and "failed: return code" in log:
        raise RuntimeError(log)


def cell_count(log: str, target: str) -> int:
    def last(cell):
        matches = re.findall(rf"^\s*{cell}\s+(\d+)\s*$", log, re.MULTILINE)
        return int(matches[-1]) if matches else 0

    return last("LUT4") + 2 * last("CCU2C") + 6 * last("TRELLIS_DPR16X4")


def synthesize(root: Path, out: Path, target: str, spec: CoreSpec,
               recipe: str, options: str) -> SynthResult:
    directory = out / recipe
    directory.mkdir(parents=True, exist_ok=True)
    json = directory / "core.json"
    defines = [f"-D{define}" for define in spec.defines]
    block_defines = [f"-D{define}" for define in spec.block_defines]
    synth_options = [*spec.synth_options, *shlex.split(options)]
    timing_script = ["read_verilog", *block_defines, str(spec.source),
                     str(root / "rtl/test/riscc_fmax_top.v"), ";"]
    timing_script.extend(("synth_ecp5", *synth_options, "-nowidelut",
                          "-top", "riscc_fmax_top", "-json", str(json)))
    timing_log = run(["yosys", "-p", " ".join(timing_script)], root)
    (directory / "timing-synth.log").write_text(timing_log)
    check_synthesis(timing_log)

    def measure_area(selected_defines):
        script = ["read_verilog", *selected_defines, str(spec.source), ";"]
        if spec.width is not None:
            script.extend(("chparam", "-set", "W", str(spec.width),
                           spec.top, ";"))
        script.extend(("synth_ecp5", *synth_options, "-nowidelut",
                       "-top", spec.top, ";", "stat"))
        return run(["yosys", "-p", " ".join(script)], root)

    area_log = measure_area(defines)
    (directory / "area-synth.log").write_text(area_log)
    check_synthesis(area_log)
    block_log = measure_area(block_defines)
    (directory / "block-area-synth.log").write_text(block_log)
    check_synthesis(block_log)
    block_area = cell_count(block_log, target)
    return SynthResult(recipe, options, json, cell_count(area_log, target),
                       block_area)


def route(out: Path, target: str, synth: SynthResult, seed: int,
          frequency: int):
    directory = synth.json.parent
    log_path = directory / f"seed-{seed}.log"
    command = [
        "nextpnr-ecp5", "--25k", "--package", "CABGA256",
        "--speed", "6", "--lpf-allow-unconstrained",
        "--freq", str(frequency), "--seed", str(seed),
        "--json", str(synth.json),
        "--textcfg", str(directory / f"seed-{seed}.config"),
    ]
    try:
        log = run(command, out)
        matches = re.findall(
            r"Max frequency for clock[^:]*:\s*([0-9.]+) MHz", log)
        if not matches:
            raise RuntimeError("nextpnr did not report Fmax")
        fmax = float(matches[-1])
        status = "ok"
    except (subprocess.CalledProcessError, RuntimeError) as error:
        log = getattr(error, "stdout", "") or str(error)
        fmax = 0.0
        status = "failed"
    log_path.write_text(log)
    return synth, seed, fmax, status


def matrix_cases():
    return [(core, width) for core in MATRIX_CORES for width in WIDTHS] + [
        (core, 16) for core in OTHER_CORES
    ]


def result_directory(base: Path, core: str, width: int) -> Path:
    suffix = f"-{width}" if core in MATRIX_CORES else ""
    return base / f"{core}{suffix}"


def read_selection(path: Path, target: str, recipes, seeds):
    with path.open(newline="") as stream:
        rows = [row for row in csv.DictReader(stream, delimiter="\t")
                if row["status"] == "ok" and row["recipe"] in recipes and
                int(row["seed"]) in seeds]
    if not rows:
        raise RuntimeError(f"no successful routes in {path}")
    area = min(rows, key=lambda row: int(row["area"]))
    block = min(rows, key=lambda row: int(row["block_area"]))
    fastest = max(rows, key=lambda row: float(row["fmax_mhz"]))
    efficient = max(rows, key=lambda row:
                    float(row["fmax_mhz"]) / int(row["block_area"]))
    return area, block, fastest, efficient


def print_matrix(selections, target: str, output: Path):
    def table(title, field, decimals=0):
        print(title)
        print(f"{'profile':<16} {'/1':>8} {'/2':>8} {'/4':>8} "
              f"{'/8':>8} {'/16':>8}")
        for core in MATRIX_CORES:
            values = [selections[(core, width)][field] for width in WIDTHS]
            formatted = [f"{float(value):.2f}" if decimals else str(value)
                         for value in values]
            print(f"{core:<16}" + "".join(f"{value:>9}" for value in formatted))
        for core in OTHER_CORES:
            value = selections[(core, 16)][field]
            formatted = f"{float(value):.2f}" if decimals else str(value)
            print(f"{core:<16} {formatted:>8}")

    table("Tuned ECP5 area (LUTRAM RF included)", "area")
    table("Tuned ECP5 area (block RAM RF)", "block_area")
    table(f"Tuned {target} Fmax (MHz, fastest recipe and seed)", "fmax", 2)
    table(f"Tuned {target} block-RF efficiency (MHz/kLUT, one recipe and seed)",
          "mhz_per_klut", 2)
    print(f"selections: {output}")


def tune_matrix(args, root: Path):
    base = (args.out or root / "build/tune" / args.target).resolve()
    base.mkdir(parents=True, exist_ok=True)
    script = Path(__file__).resolve()

    expected_recipes = set(args.only or RECIPES[args.target])
    expected_seeds = set(range(args.seed_start, args.seed_start + args.seeds))

    def complete(case):
        path = result_directory(base, *case) / "results.tsv"
        if not path.exists():
            return False
        try:
            with path.open(newline="") as stream:
                rows = list(csv.DictReader(stream, delimiter="\t"))
            found = {(row["recipe"], int(row["seed"])) for row in rows}
            return all(
                {(recipe, seed) for seed in expected_seeds}.issubset(found) or
                (result_directory(base, *case) / f"{recipe}-failed.log").exists()
                for recipe in expected_recipes
            )
        except (KeyError, ValueError):
            return False

    cases = matrix_cases()
    pending = ([case for case in cases if not complete(case)]
               if args.resume else cases)
    outer_jobs = min(len(pending), max(1, args.jobs // 4)) if pending else 1
    inner_jobs = max(1, args.jobs // outer_jobs)

    def tune(case):
        core, width = case
        command = [sys.executable, str(script), args.target, core,
                   "--width", str(width), "--seeds", str(args.seeds),
                   "--seed-start", str(args.seed_start), "-j", str(inner_jobs),
                   "--out", str(result_directory(base, core, width))]
        for recipe in args.only or ():
            command.extend(("--only", recipe))
        run(command, root)
        return case

    failures = []
    if pending:
        print(f"tuning {len(pending)} configurations with "
              f"{outer_jobs} cases x {inner_jobs} workers")
    with ThreadPoolExecutor(max_workers=outer_jobs) as pool:
        tasks = {pool.submit(tune, case): case for case in pending}
        for task in as_completed(tasks):
            try:
                task.result()
            except (subprocess.CalledProcessError, RuntimeError) as error:
                failures.append((tasks[task],
                                 getattr(error, "stdout", "") or str(error)))
    if failures:
        for case, log in failures:
            print(f"{case[0]}-{case[1]} failed:\n{log}")
        raise SystemExit(f"{len(failures)} tuning cases failed")

    selections = {}
    output = base / "best.tsv"
    with output.open("w", newline="") as stream:
        fields = ("core", "width", "area_recipe", "area_options", "area",
                  "block_area_recipe", "block_area_options", "block_area",
                  "fmax_recipe", "fmax_options", "seed", "fmax_mhz",
                  "efficient_recipe", "efficient_options", "efficient_area",
                  "efficient_seed", "efficient_fmax_mhz", "mhz_per_klut")
        writer = csv.DictWriter(stream, fields, delimiter="\t")
        writer.writeheader()
        for core, width in cases:
            path = result_directory(base, core, width) / "results.tsv"
            area, block, fastest, efficient = read_selection(
                path, args.target, expected_recipes, expected_seeds)
            selected = {
                "area": int(area["area"]),
                "block_area": int(block["block_area"]) if block else "",
                "fmax": float(fastest["fmax_mhz"]),
                "mhz_per_klut": (
                    1000 * float(efficient["fmax_mhz"]) /
                    int(efficient["block_area"])
                ),
            }
            selections[(core, width)] = selected
            writer.writerow({
                "core": core, "width": width,
                "area_recipe": area["recipe"],
                "area_options": area["synth_options"], "area": selected["area"],
                "block_area_recipe": block["recipe"] if block else "",
                "block_area_options": block["synth_options"] if block else "",
                "block_area": selected["block_area"],
                "fmax_recipe": fastest["recipe"],
                "fmax_options": fastest["synth_options"],
                "seed": fastest["seed"], "fmax_mhz": f"{selected['fmax']:.2f}",
                "efficient_recipe": efficient["recipe"],
                "efficient_options": efficient["synth_options"],
                "efficient_area": efficient["block_area"],
                "efficient_seed": efficient["seed"],
                "efficient_fmax_mhz": efficient["fmax_mhz"],
                "mhz_per_klut": (
                    f"{1000 * float(efficient['fmax_mhz']) / int(efficient['block_area']):.2f}"
                ),
            })
    print_matrix(selections, args.target, output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", choices=tuple(RECIPES))
    parser.add_argument("core", choices=(*CORES, "all"))
    parser.add_argument("--width", type=int, default=16)
    parser.add_argument("--seeds", type=int, default=10,
                        help="number of consecutive seeds (default: 10)")
    parser.add_argument("--seed-start", type=int, default=1)
    parser.add_argument("-j", "--jobs", type=int,
                        default=min(os.cpu_count() or 1, 32))
    parser.add_argument("--only", action="append", metavar="RECIPE",
                        help="search only this built-in recipe (repeatable)")
    parser.add_argument("--resume", action="store_true",
                        help="reuse complete cases from an interrupted all run")
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()

    if args.seeds < 1 or args.jobs < 1:
        parser.error("--seeds and --jobs must be positive")
    recipes = RECIPES[args.target]
    if args.only:
        unknown = set(args.only) - set(recipes)
        if unknown:
            parser.error("unknown recipe(s): " + ", ".join(sorted(unknown)))
        recipes = {name: recipes[name] for name in args.only}

    root = Path(__file__).resolve().parents[1]
    if args.core == "all":
        tune_matrix(args, root)
        return
    spec = core_spec(root, args.target, args.core, args.width)
    suffix = f"-{args.width}" if args.core in ("min", "sys", "full",
                                                "rc32-min", "rc32-sys") else ""
    out = (args.out or root / "build/tune" / args.target /
           f"{args.core}{suffix}").resolve()
    out.mkdir(parents=True, exist_ok=True)

    synths = []
    failures = []
    with ThreadPoolExecutor(max_workers=min(args.jobs, len(recipes))) as pool:
        tasks = {
            pool.submit(synthesize, root, out, args.target, spec, name, options): name
            for name, options in recipes.items()
        }
        for task in as_completed(tasks):
            try:
                synths.append(task.result())
                (out / f"{tasks[task]}-failed.log").unlink(missing_ok=True)
            except (subprocess.CalledProcessError, RuntimeError) as error:
                failures.append((tasks[task],
                                 getattr(error, "stdout", "") or str(error)))
    if failures:
        for name, log in failures:
            (out / f"{name}-failed.log").write_text(log)
            print(f"{name}: synthesis failed")
    if not synths:
        raise SystemExit("all synthesis recipes failed")

    frequency = 40
    seeds = range(args.seed_start, args.seed_start + args.seeds)
    results = []
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        tasks = [pool.submit(route, out, args.target, synth, seed, frequency)
                 for synth in synths for seed in seeds]
        for task in as_completed(tasks):
            results.append(task.result())

    results.sort(key=lambda row: (row[0].recipe, row[1]))
    with (out / "results.tsv").open("w", newline="") as stream:
        writer = csv.writer(stream, delimiter="\t")
        writer.writerow(("recipe", "synth_options", "area", "block_area",
                         "seed", "fmax_mhz", "status"))
        for synth, seed, fmax, status in results:
            writer.writerow((synth.recipe, synth.options, synth.area,
                             synth.block_area if synth.block_area is not None else "",
                             seed, f"{fmax:.2f}", status))

    print(f"{'recipe':<14} {'block':>7} {'seed':>7} {'Fmax MHz':>10}")
    best_rows = []
    for synth in sorted(synths, key=lambda item: item.recipe):
        routed = [row for row in results
                  if row[0].recipe == synth.recipe and row[3] == "ok"]
        if not routed:
            continue
        best = max(routed, key=lambda row: row[2])
        best_rows.append(best)
        print(f"{synth.recipe:<14} {synth.block_area:>7} "
              f"{best[1]:>7} {best[2]:>10.2f}")

    smallest = min(synths, key=lambda item: item.block_area)
    if not best_rows:
        raise SystemExit("all place-and-route runs failed")
    fastest = max(best_rows, key=lambda row: row[2])
    efficient = max(best_rows, key=lambda row: row[2] / row[0].block_area)
    print(f"smallest: {smallest.recipe}, {smallest.block_area} LUT sites + EBR")
    print(f"fastest:  {fastest[0].recipe}, seed {fastest[1]}, "
          f"{fastest[2]:.2f} MHz")
    print(f"efficient:{efficient[0].recipe:>12}, seed {efficient[1]}, "
          f"{1000 * efficient[2] / efficient[0].block_area:.2f} MHz/kLUT")
    print(f"results:  {out / 'results.tsv'}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Read and report generated Agilex core-characterization results."""

import argparse
import csv
from pathlib import Path


WIDTHS = (1, 2, 4, 8, 16)
MATRIX_ROWS = (
    ("min", "min"),
    ("sys", "sys"),
    ("full", "full"),
    ("RC32 min", "rc32min"),
    ("RC32 sys", "rc32sys"),
)
OTHER_ROWS = (
    ("nano", "nano", 1),
    ("full paired MulH /16", "mulh", 16),
    ("full paired MulDiv /16", "muldiv", 16),
    ("fast soft", "fast_soft", 16),
    ("fast DSP", "fast_dsp", 16),
    ("faster DSP (default)", "faster_dsp", 16),
    ("faster soft", "faster_soft", 16),
)


def load_results(paths):
    results = {}
    for path in paths:
        with path.open(newline="") as stream:
            for row in csv.DictReader(stream, delimiter="\t"):
                key = (row["profile"], int(row["width"]))
                if key in results:
                    raise RuntimeError(
                        f"duplicate Agilex result for {key[0]}/{key[1]}")
                results[key] = row
    return results


def value(results, profile, width, metric):
    try:
        row = results[(profile, width)]
    except KeyError as error:
        raise RuntimeError(
            f"missing Agilex result for {profile}/{width}; "
            "run the applicable characterize-agilex target") from error
    return row["alms" if metric == "area" else "fmax_mhz"]


def print_table(results, metric):
    heading = (
        "Agilex 3 ALMs (MLAB RF included)"
        if metric == "area"
        else "Agilex 3 Fmax (MHz)"
    )
    print(heading)
    print(f"{'profile':<32} {'/1':>7} {'/2':>7} {'/4':>7} {'/8':>7} {'/16':>7}")
    for label, profile in MATRIX_ROWS:
        values = " ".join(
            f"{value(results, profile, width, metric):>7}" for width in WIDTHS)
        print(f"{label:<32} {values}")
    for label, profile, width in OTHER_ROWS:
        print(f"{label:<32} {value(results, profile, width, metric):>7}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--metric", choices=("area", "fmax"), required=True)
    parser.add_argument("--profile")
    parser.add_argument("--width", type=int)
    parser.add_argument("results", nargs="+", type=Path)
    args = parser.parse_args()

    if (args.profile is None) != (args.width is None):
        parser.error("--profile and --width must be used together")

    try:
        results = load_results(args.results)
        if args.profile is None:
            print_table(results, args.metric)
        else:
            print(value(results, args.profile, args.width, args.metric))
    except (OSError, KeyError, RuntimeError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()

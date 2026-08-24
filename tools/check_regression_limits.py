#!/usr/bin/env python3
"""Check deterministic image, cycle, area, and Fmax regression limits."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


CYCLES_RE = re.compile(r"done after (\d+) cycles, result=0x600D: PASS")


def check_bound(name: str, value: float, item: dict) -> bool:
    failed = False
    if "min" in item and value < item["min"]:
        print(f"FAIL {name}: {value:g} < minimum {item['min']:g}")
        failed = True
    if "max" in item and value > item["max"]:
        print(f"FAIL {name}: {value:g} > maximum {item['max']:g}")
        failed = True
    if not failed:
        bounds = []
        if "min" in item:
            bounds.append(f"min {item['min']:g}")
        if "max" in item:
            bounds.append(f"max {item['max']:g}")
        print(f"PASS {name}: {value:g} ({', '.join(bounds)})")
    return not failed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("limits", type=Path)
    args = parser.parse_args()
    limits = json.loads(args.limits.read_text(encoding="utf-8"))
    passed = True

    for item in limits.get("file_sizes", []):
        path = Path(item["path"])
        passed &= check_bound(item["name"], path.stat().st_size, item)

    for item in limits.get("cycles", []):
        result = subprocess.run(
            [item["tb"], item["image"], "--max-cycles",
             str(max(2_000_000, item["max"] * 2))],
            capture_output=True, text=True,
        )
        output = result.stdout + result.stderr
        match = CYCLES_RE.search(output)
        if result.returncode or match is None:
            print(f"FAIL {item['name']}: benchmark did not pass")
            print(output, end="")
            passed = False
            continue
        passed &= check_bound(item["name"] + " cycles",
                              int(match.group(1)), item)

    for item in limits.get("numbers", []):
        fields = Path(item["path"]).read_text(encoding="ascii").split()
        value = float(fields[item.get("field", 0)])
        passed &= check_bound(item["name"], value, item)

    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())

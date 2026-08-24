#!/usr/bin/env python3
"""Check the relocations and linked layout of the RC16 high-address test."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path


def output(command: list[str]) -> str:
    return subprocess.run(
        command, check=True, text=True, stdout=subprocess.PIPE
    ).stdout


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--readobj", required=True)
    parser.add_argument("--nm", required=True)
    parser.add_argument("--object", required=True, type=Path)
    parser.add_argument("--elf", required=True, type=Path)
    args = parser.parse_args()

    relocations = output([args.readobj, "--relocations", str(args.object)])
    expected_relocations = {
        ("R_RISCC_PCREL8_WORD", "boundary_high"),
        ("R_RISCC_CODE16", "near_top"),
        ("R_RISCC_CODE_HI8", "low_return"),
        ("R_RISCC_CODE_LO8", "low_return"),
        ("R_RISCC_HI8", "top_data"),
        ("R_RISCC_LO8", "top_data"),
    }
    missing = [
        f"{kind} {symbol}"
        for kind, symbol in sorted(expected_relocations)
        if not re.search(rf"\b{kind}\s+{symbol}\b", relocations)
    ]
    if missing:
        print("missing high-address relocations: " + ", ".join(missing),
              file=sys.stderr)
        return 1

    symbols: dict[str, int] = {}
    for line in output([args.nm, "--numeric-sort", str(args.elf)]).splitlines():
        match = re.match(r"^([0-9a-fA-F]+)\s+\w\s+(\S+)$", line)
        if match:
            symbols[match.group(2)] = int(match.group(1), 16)

    expected_symbols = {
        "boundary_low": 0x7FFC,
        "boundary_high": 0x8000,
        "top_data": 0xFFD0,
        "near_top": 0xFFD8,
    }
    wrong = [
        f"{name}=0x{symbols.get(name, -1):x}, expected 0x{address:x}"
        for name, address in expected_symbols.items()
        if symbols.get(name) != address
    ]
    if wrong:
        print("incorrect high-address layout: " + ", ".join(wrong),
              file=sys.stderr)
        return 1

    print("RC16 high-address relocations and linked layout PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

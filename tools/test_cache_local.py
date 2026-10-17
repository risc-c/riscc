#!/usr/bin/env python3
"""Check Cached's retained local classification with both lookup timings."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from pathlib import Path

from test_cache import run


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path,
                        default=Path(__file__).resolve().parents[1])
    parser.add_argument("--verilator", default=shutil.which("verilator") or "verilator")
    parser.add_argument("--source", type=Path,
                        help="cache RTL source (defaults to rtl/riscc_cached.v)")
    parser.add_argument("--build-dir", type=Path,
                        default=Path("build/test-cache-local"))
    args = parser.parse_args()
    root = args.root.resolve()
    build_dir = args.build_dir
    if not build_dir.is_absolute():
        build_dir = root / build_dir
    source = args.source or (root / "rtl/riscc_cached.v")
    if not source.is_absolute():
        source = root / source
    os.environ.setdefault("CCACHE_DIR", str(root / "build/ccache"))
    makeflags = os.environ.get(
        "VERILATOR_MAKEFLAGS",
        "OPT_FAST=-O1 OPT_GLOBAL=-O1 OBJCACHE=" + (shutil.which("ccache") or ""))

    for registered_lookup in (0, 1):
        out = build_dir / f"lookup-{registered_lookup}"
        out.mkdir(parents=True, exist_ok=True)
        mdir = out / "obj"
        binary = mdir / "Vriscc_cache_local_tb"
        # One build worker per recipe respects the enclosing Make job budget.
        command = [args.verilator, "--binary", "--timing", "-j", "1",
                   "-Wno-UNOPTFLAT", "-MAKEFLAGS", makeflags,
                   "--top-module", "riscc_cache_local_tb",
                   f"-GREGISTER_LOOKUP={registered_lookup}", "--Mdir", str(mdir),
                   str(source), str(root / "test/riscc_cache_local_tb.v")]
        built = run(command, root, 120)
        (out / "build.log").write_text(built.stdout)
        record = {"build_command": command, "build_exit": built.returncode}
        (out / "commands.json").write_text(json.dumps(record, indent=2) + "\n")
        if built.returncode or not binary.exists():
            sys.stderr.write(f"cache local lookup-{registered_lookup}: build failed\n{built.stdout}")
            return 1
        result = run([str(binary)], root, 30)
        (out / "run.log").write_text(result.stdout)
        record.update(run_command=[str(binary)], run_exit=result.returncode)
        (out / "commands.json").write_text(json.dumps(record, indent=2) + "\n")
        if result.returncode or "PASS cache local classification" not in result.stdout:
            sys.stderr.write(f"cache local lookup-{registered_lookup}: failed\n{result.stdout}")
            return 1
        print(result.stdout.strip().splitlines()[0])
    print("Cached local classification checks PASS (LOCAL_WORD_BITS=2, REGISTER_LOOKUP=0/1)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

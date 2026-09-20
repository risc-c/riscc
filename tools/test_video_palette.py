#!/usr/bin/env python3
"""Test the dual-clock indexed-video palette and its FPGA RAM mapping."""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path


def run(command: list[str], *, cwd: Path, output: Path, timeout: int) -> int:
    try:
        result = subprocess.run(command, cwd=cwd, text=True,
                                stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        text = exc.stdout or ""
        if isinstance(text, bytes):
            text = text.decode(errors="replace")
        output.write_text(text + "timed out\n")
        return 124
    output.write_text(result.stdout)
    if result.stdout:
        print(result.stdout, end="")
    return result.returncode


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path,
                        default=Path(__file__).resolve().parents[1])
    parser.add_argument("--iverilog", default=shutil.which("iverilog") or "iverilog")
    parser.add_argument("--vvp", default=shutil.which("vvp") or "vvp")
    parser.add_argument("--yosys", default=shutil.which("yosys") or "yosys")
    parser.add_argument("--build-dir", type=Path,
                        default=Path("build/test-video-palette"))
    args = parser.parse_args()
    root = args.root.resolve()
    build_dir = args.build_dir if args.build_dir.is_absolute() else root / args.build_dir
    build_dir.mkdir(parents=True, exist_ok=True)
    vvp_file = build_dir / "video_palette_tb.vvp"
    compile_log = build_dir / "iverilog.log"
    compile_command = [
        args.iverilog, "-g2012", "-s", "video_palette_tb", "-o", str(vvp_file),
        str(root / "boards/shared/rtl/riscc_video_palette.v"),
        str(root / "test/video_palette_tb.v"),
    ]
    if run(compile_command, cwd=root, output=compile_log, timeout=30):
        print(f"palette simulation build failed; see {compile_log}", file=sys.stderr)
        return 1
    run_log = build_dir / "simulation.log"
    if run([args.vvp, str(vvp_file)], cwd=root, output=run_log, timeout=30):
        print(f"palette simulation failed; see {run_log}", file=sys.stderr)
        return 1

    synth_log = build_dir / "synth-ecp5.log"
    json_file = build_dir / "palette-ecp5.json"
    synth_command = [
        args.yosys, "-p",
        "read_verilog -DRISCC_ECP5 "
        f"boards/shared/rtl/riscc_video_palette.v; "
        f"synth_ecp5 -top riscc_video_palette -json {json_file}; stat",
    ]
    if run(synth_command, cwd=root, output=synth_log, timeout=60):
        print(f"palette ECP5 synthesis failed; see {synth_log}", file=sys.stderr)
        return 1
    synth_text = synth_log.read_text()
    if "DP16KD                          1" not in synth_text:
        print("palette did not synthesize to exactly one DP16KD", file=sys.stderr)
        return 1
    if "DP16KD                          2" in synth_text:
        print("palette synthesized to two DP16KD blocks", file=sys.stderr)
        return 1
    print("PASS video palette: simulation and one ECP5 DP16KD")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

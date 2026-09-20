#!/usr/bin/env python3
"""Run the Atum scanout, SDRAM line buffer, and palette integration test."""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path,
                        default=Path(__file__).resolve().parents[1])
    parser.add_argument("--iverilog", default=shutil.which("iverilog") or "iverilog")
    parser.add_argument("--vvp", default=shutil.which("vvp") or "vvp")
    parser.add_argument("--build-dir", type=Path,
                        default=Path("build/test-video-palette-scanout"))
    args = parser.parse_args()
    root = args.root.resolve()
    build_dir = args.build_dir if args.build_dir.is_absolute() else root / args.build_dir
    build_dir.mkdir(parents=True, exist_ok=True)
    vvp_file = build_dir / "video_palette_scanout_tb.vvp"
    compile_log = build_dir / "iverilog.log"
    sources = [
        root / "boards/shared/rtl/riscc_video_palette.v",
        root / "boards/shared/rtl/riscc_sdram_scanout.v",
        root / "boards/atum_a3_nano/rtl/atum_fb_hdmi.v",
        root / "test/video_palette_scanout_tb.v",
    ]
    command = [args.iverilog, "-g2012", "-s", "video_palette_scanout_tb",
               "-o", str(vvp_file)] + [str(source) for source in sources]
    result = subprocess.run(command, cwd=root, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            timeout=60)
    compile_log.write_text(result.stdout)
    if result.returncode:
        print(result.stdout, file=sys.stderr)
        print(f"scanout test build failed; see {compile_log}", file=sys.stderr)
        return 1
    run_log = build_dir / "simulation.log"
    result = subprocess.run([args.vvp, str(vvp_file)], cwd=root, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            timeout=60)
    run_log.write_text(result.stdout)
    print(result.stdout, end="")
    if result.returncode or "PASS Atum video palette scanout" not in result.stdout:
        print(f"scanout test failed; see {run_log}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

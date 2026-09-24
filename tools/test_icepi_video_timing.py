#!/usr/bin/env python3
"""Check one complete IcePi 1280x720 raster at the external TMDS pins."""

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
                        default=Path("build/test-icepi-video-timing"))
    args = parser.parse_args()

    root = args.root.resolve()
    build_dir = args.build_dir if args.build_dir.is_absolute() else root / args.build_dir
    build_dir.mkdir(parents=True, exist_ok=True)
    sources = [
        root / "boards/shared/rtl/riscc_video_palette.v",
        root / "boards/shared/rtl/riscc_sdram_scanout.v",
        root / "boards/icepi_zero/rtl/icepi_tmds_encoder.v",
        root / "boards/icepi_zero/rtl/icepi_tmds_ddr.v",
        root / "boards/icepi_zero/rtl/icepi_fb_dvi.v",
        root / "test/tmds_serializer_tb.v",
        root / "test/icepi_video_timing_tb.v",
    ]
    for phase in (0.0, 0.35):
        tag = f"phase-{phase:.2f}"
        vvp_file = build_dir / f"{tag}.vvp"
        compile_log = build_dir / f"{tag}-iverilog.log"
        command = [args.iverilog, "-g2012", "-DICEPI_VIDEO_TEST", "-s",
                   "icepi_video_timing_tb", "-P",
                   f"icepi_video_timing_tb.PHASE_NS={phase}", "-o",
                   str(vvp_file)] + [str(source) for source in sources]
        result = subprocess.run(command, cwd=root, text=True,
                                stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=120)
        compile_log.write_text(result.stdout)
        if result.returncode:
            print(result.stdout, file=sys.stderr)
            print(f"IcePi timing {tag} build failed; see {compile_log}",
                  file=sys.stderr)
            return 1

        run_log = build_dir / f"{tag}.log"
        result = subprocess.run([args.vvp, str(vvp_file)], cwd=root, text=True,
                                stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=300)
        run_log.write_text(result.stdout)
        print(result.stdout, end="")
        if result.returncode or "PASS IcePi external 720p raster" not in result.stdout:
            print(f"IcePi timing {tag} test failed; see {run_log}",
                  file=sys.stderr)
            return 1
    print("PASS IcePi external 720p raster: phase offsets")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

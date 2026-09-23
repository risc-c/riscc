#!/usr/bin/env python3
"""Run the IcePi TMDS DDR serializer reconstruction test."""

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
                        default=Path("build/test-tmds-serializer"))
    args = parser.parse_args()
    root = args.root.resolve()
    build_dir = args.build_dir if args.build_dir.is_absolute() else root / args.build_dir
    build_dir.mkdir(parents=True, exist_ok=True)
    sources = [
        str(root / "boards/icepi_zero/rtl/icepi_tmds_ddr.v"),
        str(root / "boards/icepi_zero/rtl/icepi_tmds_encoder.v"),
        str(root / "test/tmds_serializer_tb.v"),
    ]
    # Exercise distinct phase relationships between the 5x edge clock and
    # pixel clock, including fractional offsets and jitter across a sampling edge.
    cases = [(phase, 0.0) for phase in
             (0.0, 0.35, 0.8, 1.35, 1.8, 2.35, 2.8, 3.35, 3.8)]
    cases.append((0.0, 0.1))
    for phase, jitter in cases:
        tag = f"phase-{phase:.2f}-jitter-{jitter:.2f}"
        vvp_file = build_dir / f"{tag}.vvp"
        compile_log = build_dir / f"{tag}-iverilog.log"
        command = [args.iverilog, "-g2012", "-s", "tmds_serializer_tb",
                   "-P", f"tmds_serializer_tb.PHASE_NS={phase}",
                   "-P", f"tmds_serializer_tb.PIXEL_JITTER_NS={jitter}",
                   "-o", str(vvp_file)] + sources
        result = subprocess.run(command, cwd=root, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                timeout=30)
        compile_log.write_text(result.stdout)
        if result.returncode:
            print(result.stdout, file=sys.stderr)
            print(f"TMDS serializer {tag} build failed; see {compile_log}",
                  file=sys.stderr)
            return 1
        run_log = build_dir / f"{tag}.log"
        result = subprocess.run([args.vvp, str(vvp_file)], cwd=root, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                timeout=30)
        run_log.write_text(result.stdout)
        print(result.stdout, end="")
        if result.returncode or "PASS TMDS serializer" not in result.stdout:
            print(f"TMDS serializer {tag} test failed; see {run_log}",
                  file=sys.stderr)
            return 1
    print("PASS TMDS serializer: phase offsets and pixel-clock jitter")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

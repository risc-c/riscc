#!/usr/bin/env python3
"""Build and run the HDMI I2C protocol and transmitter-init checks."""

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
                        default=Path("build/test-board-i2c"))
    args = parser.parse_args()

    root = args.root.resolve()
    build_dir = args.build_dir if args.build_dir.is_absolute() else root / args.build_dir
    build_dir.mkdir(parents=True, exist_ok=True)
    vvp_file = build_dir / "board_i2c_tb.vvp"
    compile_log = build_dir / "iverilog.log"
    run_log = build_dir / "simulation.log"

    engine_source = root / "boards/shared/rtl/riscc_i2c_reg.v"
    if not engine_source.exists():
        print(f"board I2C test: missing {engine_source}", file=sys.stderr)
        return 1

    adv_source = root / "boards/de23_lite/rtl/adv7513_init.v"
    if not adv_source.exists():
        print(f"board I2C test: missing {adv_source}", file=sys.stderr)
        return 1

    command = [args.iverilog, "-g2012", "-s", "board_i2c_tb", "-o", str(vvp_file),
        str(engine_source),
        str(root / "boards/atum_a3_nano/rtl/atum_tfp410_init.v"),
        str(adv_source),
        str(root / "test/board_i2c_tb.v"),
    ]
    result = subprocess.run(command, cwd=root, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            timeout=30)
    compile_log.write_text(result.stdout)
    if result.returncode:
        print(result.stdout, file=sys.stderr)
        print(f"board I2C build failed; see {compile_log}", file=sys.stderr)
        return 1

    result = subprocess.run([args.vvp, str(vvp_file)], cwd=root, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            timeout=30)
    run_log.write_text(result.stdout)
    print(result.stdout, end="")
    if result.returncode or "PASS board I2C:" not in result.stdout:
        print(f"board I2C test failed; see {run_log}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

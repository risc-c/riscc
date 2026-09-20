#!/usr/bin/env python3
"""Check native RC32 bus decoding in both board SoCs, independently of the CPU."""
import argparse
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verilator", default="verilator")
    parser.add_argument("--build-dir", type=Path, default=ROOT / "build/test-board-map")
    args = parser.parse_args()
    for board, led_bits in (("atum_a3_nano", 4), ("icepi_zero", 5)):
        output = args.build_dir.resolve() / board
        output.mkdir(parents=True, exist_ok=True)
        sources = [ROOT / "boards/shared/test/rc32_map_tb.v",
                   ROOT / f"boards/{board}/rtl/{board}_soc.v"]
        sources += [ROOT / f"boards/shared/rtl/riscc_{name}.v"
                    for name in ("uart_mmio", "timer_mmio", "irq_ctrl")]
        command = [args.verilator, "--binary", "--timing", "-j", "4",
                   "--top-module", "board_map_tb", "--Mdir", str(output),
                   f"-DSOC_NAME={board}_soc",
                   f"-DLED_BITS={led_bits}",
                   "-DSDRAM_END=32\'h" + ("14000000" if board == "atum_a3_nano" else "12000000"), *map(str, sources)]
        with (output / "build.log").open("w") as log:
            subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
        result = subprocess.run([str(output / "Vboard_map_tb")], cwd=ROOT,
                                text=True, capture_output=True)
        (output / "run.log").write_text(result.stdout + result.stderr)
        print(f"{board}: {result.stdout.strip()}")
        result.check_returncode()


if __name__ == "__main__":
    main()

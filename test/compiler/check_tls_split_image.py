#!/usr/bin/env python3
"""Check that split RISC-C data images include .tdata but not .tbss."""

from __future__ import annotations

import argparse
import subprocess
import tempfile
from pathlib import Path


def extract(objcopy: Path, elf: Path, sections: list[str], output: Path) -> bytes:
    subprocess.run(
        [str(objcopy), "-O", "binary", *[f"--only-section={section}"
         for section in sections], str(elf), str(output)],
        check=True,
    )
    return output.read_bytes()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--llvm-objcopy", type=Path, required=True)
    parser.add_argument("--elf", type=Path, required=True)
    parser.add_argument("--data-bin", type=Path, required=True)
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="riscc-tls-image-") as tmp_name:
        tmp = Path(tmp_name)
        tdata = extract(args.llvm_objcopy, args.elf, [".tdata"],
                        tmp / "tdata.bin")
        expected = extract(args.llvm_objcopy, args.elf,
                           [".rodata", ".data", ".tdata"],
                           tmp / "expected-data.bin")

    data_image = args.data_bin.read_bytes()
    if not tdata:
        raise SystemExit("error: split ELF has no initialized TLS template")
    if tdata not in data_image:
        raise SystemExit("error: split data image does not contain .tdata")
    if data_image != expected:
        raise SystemExit("error: split data image contains sections beyond "
                         ".rodata, .data, and .tdata")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

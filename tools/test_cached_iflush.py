#!/usr/bin/env python3
"""Run public riscc_cached IFLUSH/self-modifying-JALL directed checks."""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path


PASS_RE = re.compile(
    r"PASS Cached IFLUSH.*XLEN=(?P<xlen>\d+).*SRAM=(?P<sram>\d+).*cycles=(?P<cycles>\d+)"
)


def run(command: list[str], *, cwd: Path, timeout: int) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(command, cwd=cwd, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        output = exc.stdout or ""
        if isinstance(output, bytes):
            output = output.decode(errors="replace")
        return subprocess.CompletedProcess(command, 124, output + "timed out\n")


def enc_i(rd: int, op: int, imm: int) -> int:
    return (0b10 << 14) | (rd << 11) | (op << 8) | (imm & 0xff)


def local_hex(path: Path, sram_bits: int, xlen: int, drain: bool) -> None:
    """Emit the low SRAM image; external backing is initialized by the TB."""
    line_bytes = 64 if xlen == 32 else 32
    long_at = 62
    iflush_at = 0x50
    successor_at = iflush_at + 2
    literal_at = 0xe0
    words = [0] * (1 << (sram_bits - 2))

    def put16(address: int, value: int) -> None:
        index = address >> 2
        if index >= len(words):
            return
        if address & 2:
            words[index] = (words[index] & 0xffff) | ((value & 0xffff) << 16)
        else:
            words[index] = (words[index] & 0xffff0000) | (value & 0xffff)

    def jall(link: int, target: int) -> int:
        return 0x0034 | (link << 11) | (((target >> 16) & 31) << 6)

    def r(rd: int, ra: int, func: int, rb: int) -> int:
        return (0b11 << 14) | (rd << 11) | (ra << 8) | (func << 3) | rb

    def enc_mem(store: int, rs: int, ra: int, disp: int) -> int:
        offset = (disp & 0xfc) | ((disp < 0) << 1) if xlen == 32 else disp & 0xfe
        return (0b01 << 14) | (rs << 11) | (ra << 8) | offset | store

    def store_ins(rs: int, ra: int) -> int:
        return r(rs, ra, 0x0b, 2) if xlen == 32 else enc_mem(1, rs, ra, 0)

    def branch(cc: int, relative: int) -> int:
        rel = relative & 0xff
        return enc_i(cc, 7, ((rel & 0x7f) << 1) | ((rel >> 7) & 1))

    if drain:
        for address in range(0, 1 << sram_bits, 2):
            put16(address, 0xc000)
        put16(0, enc_i(7, 0, 192))
        put16(2, branch(4, 6))
        put16(4, r(5, 0, 0x1f, 0))
        put16(16, r(7, 0, 0x1f, 0))
        put16(18, branch(4, line_bytes // 2 - 11))
        put16(line_bytes - 2, r(3, 0, 0x1f, 0))
        path.write_text("".join(f"{value:08x}\n" for value in words))
        return

    put16(0, jall(1, long_at))
    put16(2, long_at)
    put16(4, jall(1, long_at))
    put16(6, long_at)
    put16(8, r(2, 0, 0x1f, 0))
    put16(0x0a, enc_i(7, 0, long_at + 2))
    put16(0x0c, enc_i(2, 0, 0x90))
    put16(0x0e, store_ins(2, 7))
    put16(0x10, enc_i(7, 0, literal_at))
    put16(0x12, enc_mem(0, 2, 7, 0))
    put16(0x14, enc_i(7, 0, successor_at))
    put16(0x16, store_ins(2, 7))
    put16(0x18, r(7, 0, 0x1f, 0))
    put16(0x1a, branch(4, (iflush_at - 6 - 0x1c) >> 1))
    put16(iflush_at - 6, enc_i(7, 0, 0xf8))
    put16(iflush_at - 4, enc_mem(0, 2, 7, 0))
    put16(iflush_at - 2, store_ins(2, 7))
    put16(long_at, jall(2, 0x80))
    put16(long_at + 4, r(0, 1, 0x1f, 0))
    put16(iflush_at, r(3, 0, 0x1f, 0))
    put16(iflush_at + 6, jall(1, long_at))
    put16(iflush_at + 8, long_at)
    put16(iflush_at + 12, r(3, 1, 0x1f, 2))
    put16(iflush_at + 18, enc_i(3, 0, 0xd0))
    path.write_text("".join(f"{value:08x}\n" for value in words))


def one_variant(root: Path, verilator: str, build_root: Path, sram_bits: int, timeout: int,
                source: Path | None = None,
                expect_fail: bool = False, xlen: int = 32, drain: bool = False) -> bool:
    name = f"rc{xlen}-{'drain' if drain else 'btb'}-sram{sram_bits}"
    out = build_root / name
    out.mkdir(parents=True, exist_ok=True)
    image = ""
    if sram_bits:
        image_path = out / "sram.hex"
        local_hex(image_path, sram_bits, xlen, drain)
        image = str(image_path)
    mdir = out / "obj"
    top = "riscc_cached_iflush_drain_tb" if drain else "riscc_cached_iflush_tb"
    binary = mdir / f"V{top}"
    command = [verilator, "--binary", "--timing", "-Wno-TIMESCALEMOD",
               "-Wno-UNOPTFLAT", "--top-module", top,
               f"-GXLEN={xlen}", f"-GSRAM_ADDR_BITS={sram_bits}"]
    if image:
        command.append(f'-GSRAM_HEX="{image}"')
    command += ["--Mdir", str(mdir),
                str(root / "rtl/riscc_pipeline_shared.v"),
                str(source or root / "rtl/riscc_cached.v"),
                str(root / f"test/{top}.v")]
    built = run(command, cwd=root, timeout=120)
    (out / "build.log").write_text(built.stdout)
    if built.returncode or not binary.exists():
        sys.stderr.write(f"{name}: build failed\n{built.stdout}")
        return False
    result = run([str(binary), "+READ_DELAY=2", "+WRITE_DELAY=80"],
                 cwd=root, timeout=timeout)
    (out / "run.log").write_text(result.stdout)
    match = PASS_RE.search(result.stdout)
    if expect_fail:
        if result.returncode and "IFLUSH ACK preceded" in result.stdout:
            print(f"{name}: expected directed failure observed")
            return True
        sys.stderr.write(f"{name}: negative control unexpectedly passed\n"
                         f"{result.stdout}")
        return False
    if result.returncode or not match:
        sys.stderr.write(f"{name}: test failed\n{result.stdout}")
        return False
    if int(match.group("xlen")) != xlen or int(match.group("sram")) != sram_bits:
        sys.stderr.write(f"{name}: wrong configuration in PASS line\n{result.stdout}")
        return False
    print(f"{name}: {match.group(0)}")
    return True


def make_negative_source(root: Path, out: Path, kind: str) -> Path:
    text = (root / "rtl/riscc_cached.v").read_text()
    if kind == "icache-clear":
        needle = ".rst(rst || iflush_start),"
        replacement = ".rst(rst),"
    elif kind == "btb-clear":
        needle = "if (rst || iflush_start) begin\n                clearing_q <= 1;"
        replacement = "if (rst) begin\n                clearing_q <= 1;"
    else:
        raise ValueError(kind)
    if text.count(needle) != 1:
        raise RuntimeError(f"negative source replacement not unique: {kind}")
    out.mkdir(parents=True, exist_ok=True)
    path = out / f"riscc_cached_{kind}.v"
    path.write_text(text.replace(needle, replacement))
    return path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path,
                        default=Path(__file__).resolve().parents[1])
    parser.add_argument("--verilator",
                        default=shutil.which("verilator") or "verilator")
    parser.add_argument("--build-dir", type=Path,
                        default=Path("build/test-cached-iflush"))
    parser.add_argument("--timeout", type=int, default=90)
    parser.add_argument("--quick", action="store_true",
                        help="skip local-SRAM cases")
    parser.add_argument("--negative-controls", action="store_true",
                        help="also run disabled-clear build-only controls")
    args = parser.parse_args()
    root = args.root.resolve()
    build_root = args.build_dir if args.build_dir.is_absolute() else root / args.build_dir
    cases = [(xlen, drain, sram_bits) for xlen in (16, 32)
             for drain in (False, True)
             for sram_bits in ((0,) if args.quick else
                              (0, 5 if drain and xlen == 16 else 6))]
    ok = True
    for xlen, drain, sram_bits in cases:
        ok = one_variant(root, args.verilator, build_root, sram_bits,
                         args.timeout, xlen=xlen, drain=drain) and ok
    if args.negative_controls:
        negative_root = build_root / "negative-controls"
        no_i = make_negative_source(root, negative_root, "icache-clear")
        no_b = make_negative_source(root, negative_root, "btb-clear")
        ok = one_variant(root, args.verilator, negative_root / "icache-clear",
                         0, args.timeout, no_i, True) and ok
        ok = one_variant(root, args.verilator, negative_root / "btb-clear",
                         0, args.timeout, no_b, True) and ok
    if ok:
        print(f"Cached public IFLUSH checks PASS ({len(cases)} XLEN/SRAM/program variants)")
        return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(main())

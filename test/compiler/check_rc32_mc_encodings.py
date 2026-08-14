#!/usr/bin/env python3
"""Seeded RC32 MC encoding differential fuzzer.

The test emits a mixed RC32 Min stream, assembles it with LLVM MC, and checks
the raw .text bytes against this small, independent encoder.  It covers random
register/immediate operands as well as forward and backward branch and LDPC
fixups, including their rotated signed-halfword fields.
"""

from __future__ import annotations

import argparse
import random
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def parse_args() -> argparse.Namespace:
    default_bin = ROOT / "build" / "llvm-riscc" / "bin"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--llvm-mc", type=Path, default=default_bin / "llvm-mc")
    parser.add_argument("--llvm-objcopy", type=Path,
                        default=default_bin / "llvm-objcopy")
    parser.add_argument("--seed", type=lambda text: int(text, 0), default=0x5A17C32)
    parser.add_argument("--iterations", type=int, default=4096)
    return parser.parse_args()


def word(value: int) -> bytes:
    return (value & 0xffff).to_bytes(2, "little")


def rr(rd: int, ra: int, func: int, rb: int) -> bytes:
    return word(0xc000 | (rd << 11) | (ra << 8) | (func << 3) | rb)


def ri(rd: int, op: int, imm: int) -> bytes:
    return word(0x8000 | (rd << 11) | (op << 8) | (imm & 0xff))


def rotated_rel8(rel: int) -> int:
    assert -128 <= rel <= 127
    encoded = rel & 0xff
    return ((encoded << 1) & 0xfe) | (encoded >> 7)


def mem(rd: int, base: int, disp: int, store: bool) -> bytes:
    assert disp % 4 == 0 and -256 <= disp <= 252
    words = (disp // 4) & 0x7f
    encoded = ((words & 0x3f) << 2) | ((words & 0x40) >> 5)
    return word(0x4000 | (rd << 11) | (base << 8) | encoded | int(store))


def direct(rd: int, base: int, func: int, width: int) -> bytes:
    return rr(rd, base, func, width)


def fail(message: str, expected: bytes, actual: bytes,
         emitted: list[tuple[int, str]]) -> int:
    mismatch = next((index for index, (want, got) in
                     enumerate(zip(expected, actual)) if want != got),
                    min(len(expected), len(actual)))
    lo = max(0, mismatch - 8)
    hi = mismatch + 10
    context = next((line for offset, line in reversed(emitted)
                    if offset <= mismatch), "section padding")
    print(
        f"{message} at .text+0x{mismatch:x}\n"
        f"near: {context}\n"
        f"oracle: {expected[lo:hi].hex(' ')}\n"
        f"llvm-mc: {actual[lo:hi].hex(' ')}",
        file=sys.stderr,
    )
    return 1


def main() -> int:
    args = parse_args()
    if args.iterations < 1:
        print("--iterations must be positive", file=sys.stderr)
        return 2
    for tool in (args.llvm_mc, args.llvm_objcopy):
        if not tool.is_file():
            print(f"tool not found: {tool}", file=sys.stderr)
            return 2

    rng = random.Random(args.seed)
    expected = bytearray()
    instruction_count = 0
    label_id = 0
    emitted: list[tuple[int, str]] = []

    with tempfile.TemporaryDirectory(prefix="riscc-rc32-mc-") as tmp_name:
        tmp = Path(tmp_name)
        source_path = tmp / "rc32-fuzz.s"
        object_path = tmp / "rc32-fuzz.o"
        binary_path = tmp / "rc32-fuzz.bin"

        with source_path.open("w", encoding="ascii") as source:
            def emit(line: str, encoding: bytes) -> None:
                nonlocal instruction_count
                emitted.append((len(expected), line))
                source.write(f"  {line}\n")
                expected.extend(encoding)
                instruction_count += 1

            def space(size: int) -> None:
                source.write(f"  .space {size}\n")
                expected.extend(bytes(size))

            def label(name: str) -> None:
                source.write(name + ":\n")

            def fresh(stem: str) -> str:
                nonlocal label_id
                label_id += 1
                return f".{stem}_{label_id}"

            source.write(".text\n")
            for _ in range(args.iterations):
                rd, ra, rb = (rng.randrange(8) for _ in range(3))
                kind = rng.randrange(16)
                if kind == 0:
                    imm = rng.randrange(256)
                    emit(f"ldi r{rd}, {imm}", ri(rd, 0, imm))
                elif kind == 1:
                    imm = rng.randrange(-128, 128)
                    emit(f"addi r{rd}, {imm}", ri(rd, 2, imm))
                elif kind == 2:
                    imm = rng.randrange(-128, 128)
                    emit(f"cmpi r{rd}, {imm}", ri(rd, 3, imm))
                elif kind in (3, 4, 5):
                    op, opcode = (("andi", 4), ("ori", 5), ("xori", 6))[kind - 3]
                    imm = rng.randrange(256)
                    emit(f"{op} r{rd}, {imm}", ri(rd, opcode, imm))
                elif kind in (6, 7):
                    disp = rng.randrange(-64, 64) * 4
                    op = "st" if kind == 7 else "ld"
                    emit(f"{op} r{rd}, [r{ra} + {disp}]",
                         mem(rd, ra, disp, kind == 7))
                elif kind == 8:
                    op, func = rng.choice((("add", 0), ("sub", 1), ("slt", 2),
                                           ("sltu", 3), ("and", 4), ("or", 5),
                                           ("xor", 6)))
                    emit(f"{op} r{rd}, r{ra}, r{rb}", rr(rd, ra, func, rb))
                elif kind == 9:
                    emit(f"ldx r{rd}, [r{ra} + r{rb}]", rr(rd, ra, 8, rb))
                elif kind in (10, 11, 12, 13, 14, 15):
                    op, func, width = (
                        ("ldb", 0x0a, 0), ("ldbs", 0x0e, 0),
                        ("stb", 0x0b, 0), ("ldh", 0x0a, 2),
                        ("ldhs", 0x0e, 2), ("sth", 0x0b, 2),
                    )[kind - 10]
                    emit(f"{op} r{rd}, [r{ra}]", direct(rd, ra, func, width))

            for opcode, mnemonic in enumerate(("beqz", "bnez", "bltz", "bgez", "jmp8")):
                for _ in range(32):
                    rel = rng.randrange(-128, 128)
                    target = fresh("branch")
                    if rel < 0:
                        label(target)
                        space(-2 * rel - 2)
                        emit(f"{mnemonic} {target}",
                             ri(opcode, 7, rotated_rel8(rel)))
                    else:
                        emit(f"{mnemonic} {target}",
                             ri(opcode, 7, rotated_rel8(rel)))
                        space(2 * rel)
                        label(target)

            # LDPC shares the rotated field but requires a word-aligned
            # target.  Exercise both signs with offsets at the field limits.
            for rel in (-128, -127, -2, -1, 0, 1, 2, 126, 127):
                rd = rng.randrange(8)
                target = fresh("literal")
                if rel < 0:
                    # Specify a zero fill: otherwise MC uses the target's
                    # executable-text NOP pattern for the alignment gap.
                    source.write("  .balign 4, 0\n")
                    while len(expected) & 3:
                        expected.append(0)
                    label(target)
                    space(-2 * rel - 2)
                    emit(f"ldpc r{rd}, {target}",
                         ri(rd, 1, rotated_rel8(rel)))
                else:
                    # Make pc_next + 2*rel word aligned without changing rel.
                    if ((len(expected) + 2 + 2 * rel) & 3) != 0:
                        source.write("  .space 2\n")
                        expected.extend(b"\0\0")
                    emit(f"ldpc r{rd}, {target}",
                         ri(rd, 1, rotated_rel8(rel)))
                    space(2 * rel)
                    label(target)
                    source.write("  .long 0\n")
                    expected.extend(b"\0\0\0\0")

        mc = subprocess.run(
            [str(args.llvm_mc), "-triple=riscc-none-elf", "-mcpu=min",
             "-mattr=+rc32", "-filetype=obj", "-o", str(object_path),
             str(source_path)],
            capture_output=True, text=True,
        )
        if mc.returncode:
            print(mc.stderr, file=sys.stderr, end="")
            return mc.returncode
        objcopy = subprocess.run(
            [str(args.llvm_objcopy), "-O", "binary", "--only-section=.text",
             str(object_path), str(binary_path)],
            capture_output=True, text=True,
        )
        if objcopy.returncode:
            print(objcopy.stderr, file=sys.stderr, end="")
            return objcopy.returncode
        actual = binary_path.read_bytes()
        if expected != actual:
            return fail("RC32 LLVM MC encoding mismatch", expected, actual,
                        emitted)

    print(f"RC32 MC fuzz: seed=0x{args.seed:x}, {instruction_count} instructions, "
          f"{len(expected)} bytes matched")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

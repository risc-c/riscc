#!/usr/bin/env python3
"""Deterministically compare every implemented RC32 encoding field to LLVM MC.

Compact formats enumerate every legal register and immediate combination.
JALL's much larger 21-bit address is covered independently by every S-register
value, every high-field value, every aligned low-16 value, and cross-field
boundaries. Optional MDU forms are exhaustive over their three register fields.
"""

from __future__ import annotations

import argparse
import bisect
import subprocess
import sys
import tempfile
from array import array
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def parse_args() -> argparse.Namespace:
    default_bin = ROOT / "build" / "llvm-riscc" / "bin"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--llvm-mc", type=Path, default=default_bin / "llvm-mc")
    parser.add_argument("--llvm-objcopy", type=Path,
                        default=default_bin / "llvm-objcopy")
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


def mem(reg: int, base: int, disp: int, store: bool) -> bytes:
    assert disp % 4 == 0 and -256 <= disp <= 252
    words = (disp // 4) & 0x7f
    encoded = ((words & 0x3f) << 2) | ((words & 0x40) >> 5)
    return word(0x4000 | (reg << 11) | (base << 8) |
                encoded | int(store))


def sysop(sd: int, ra: int, sub: int) -> bytes:
    return word(0xc0f8 | (sd << 11) | (ra << 8) | sub)


def jall(sd: int, target: int) -> bytes:
    assert target % 2 == 0 and 0 <= target <= 0x1ffffe
    head = (sd << 11) | (((target >> 16) & 0x1f) << 6) | 0x34
    return word(head) + word(target)


class Corpus:
    def __init__(self, name: str, cpu: str, attributes: str = "+rc32"):
        self.name = name
        self.cpu = cpu
        self.attributes = attributes
        self.lines = [".text"]
        self.expected = bytearray()
        self.offsets = array("I")
        self.contexts: list[str] = []
        self.instructions = 0
        self.label_id = 0

    def emit(self, spelling: str, encoding: bytes) -> None:
        self.offsets.append(len(self.expected))
        self.contexts.append(spelling)
        self.lines.append("  " + spelling)
        self.expected.extend(encoding)
        self.instructions += 1

    def space(self, size: int) -> None:
        if size:
            self.lines.append(f"  .space {size}, 0")
            self.expected.extend(bytes(size))

    def align(self, alignment: int) -> None:
        self.lines.append(f"  .balign {alignment}, 0")
        while len(self.expected) % alignment:
            self.expected.append(0)

    def label(self, name: str) -> None:
        self.lines.append(name + ":")

    def fresh(self, stem: str) -> str:
        self.label_id += 1
        return f".{stem}_{self.label_id}"


def emit_relative(corpus: Corpus, mnemonic: str, encoding_rd: int,
                  encoding_op: int, rel: int, prefix: str = "") -> None:
    label = corpus.fresh(mnemonic)
    encoding = ri(encoding_rd, encoding_op, rotated_rel8(rel))
    if rel < 0:
        corpus.label(label)
        corpus.space(-2 * rel - 2)
        corpus.emit(f"{prefix}{mnemonic} {label}", encoding)
    else:
        corpus.emit(f"{prefix}{mnemonic} {label}", encoding)
        corpus.space(2 * rel)
        corpus.label(label)


def emit_ldpc(corpus: Corpus, rd: int, rel: int) -> None:
    label = corpus.fresh("ldpc")
    encoding = ri(rd, 1, rotated_rel8(rel))
    if rel < 0:
        corpus.align(4)
        corpus.label(label)
        corpus.space(-2 * rel - 2)
        corpus.emit(f"ldpc r{rd}, {label}", encoding)
    else:
        if (len(corpus.expected) + 2 + 2 * rel) & 3:
            corpus.space(2)
        corpus.emit(f"ldpc r{rd}, {label}", encoding)
        corpus.space(2 * rel)
        corpus.label(label)
        corpus.lines.append("  .long 0")
        corpus.expected.extend(b"\0\0\0\0")


def make_min_corpus() -> Corpus:
    corpus = Corpus("min", "min")

    for mnemonic, store in (("ld", False), ("st", True)):
        for reg in range(8):
            for base in range(8):
                for disp in range(-256, 256, 4):
                    corpus.emit(f"{mnemonic} r{reg}, [r{base} + {disp}]",
                                mem(reg, base, disp, store))

    for mnemonic, opcode, signed in (
            ("ldi", 0, False), ("addi", 2, True), ("cmpi", 3, True),
            ("andi", 4, False), ("ori", 5, False), ("xori", 6, False)):
        values = range(-128, 128) if signed else range(256)
        for rd in range(8):
            for immediate in values:
                corpus.emit(f"{mnemonic} r{rd}, {immediate}",
                            ri(rd, opcode, immediate))

    for rd in range(8):
        for rel in range(-128, 128):
            emit_ldpc(corpus, rd, rel)

    for condition, mnemonic in enumerate(
            ("beqz", "bnez", "bltz", "bgez", "jmp8")):
        for rel in range(-128, 128):
            emit_relative(corpus, mnemonic, condition, 7, rel)

    for mnemonic, func in (
            ("add", 0), ("sub", 1), ("slt", 2), ("sltu", 3),
            ("and", 4), ("or", 5), ("xor", 6)):
        for rd in range(8):
            for ra in range(8):
                for rb in range(8):
                    corpus.emit(f"{mnemonic} r{rd}, r{ra}, r{rb}",
                                rr(rd, ra, func, rb))

    for rd in range(8):
        for ra in range(8):
            for rb in range(8):
                corpus.emit(f"ldx r{rd}, [r{ra} + r{rb}]",
                            rr(rd, ra, 8, rb))

    for mnemonic, func, selector in (
            ("ldb", 0x0a, 0), ("ldbs", 0x0e, 0),
            ("stb", 0x0b, 0), ("ldh", 0x0a, 2),
            ("ldhs", 0x0e, 2), ("sth", 0x0b, 2)):
        for rd in range(8):
            for ra in range(8):
                corpus.emit(f"{mnemonic} r{rd}, [r{ra}]",
                            rr(rd, ra, func, selector))

    for mnemonic, selector in (("fsl1", 0), ("fsr1", 1)):
        for rd in range(8):
            for ra in range(8):
                corpus.emit(f"{mnemonic} r{rd}, r{ra}",
                            rr(rd, ra, 0x11, selector))

    for mnemonic, func in (("srli", 0x0c), ("srai", 0x0d)):
        for rd in range(8):
            for ra in range(8):
                corpus.emit(f"{mnemonic} r{rd}, r{ra}, 1",
                            rr(rd, ra, func, 0))

    for sreg in range(8):
        corpus.emit(f"ret s{sreg}", sysop(0, sreg, 0))
    for sd in range(8):
        for ra in range(8):
            corpus.emit(f"jalr s{sd}, r{ra}", sysop(sd, ra, 1))
    for rd in range(8):
        for sa in range(8):
            corpus.emit(f"mfs r{rd}, s{sa}", sysop(rd, sa, 2))
    for sd in range(8):
        for ra in range(8):
            corpus.emit(f"mts s{sd}, r{ra}", sysop(sd, ra, 3))

    for rd in range(8):
        for ra in range(8):
            corpus.emit(f"mov r{rd}, r{ra}", rr(rd, ra, 5, ra))
    for ra in range(8):
        corpus.emit(f"jmp r{ra}", sysop(0, ra, 1))
    corpus.emit("nop", rr(0, 0, 5, 0))
    corpus.emit("halt", ri(4, 7, rotated_rel8(-1)))
    return corpus


def make_sys_corpus() -> Corpus:
    corpus = Corpus("sys", "sys")
    for sreg in range(8):
        corpus.emit(f"reti s{sreg}", sysop(5, sreg, 0))
    corpus.emit("cli", sysop(2, 0, 0))
    corpus.emit("sti", sysop(7, 0, 0))

    cases = {(sd, 0) for sd in range(8)}
    cases.update((7, high << 16) for high in range(32))
    cases.update((7, low) for low in range(0, 0x10000, 2))
    for sd in range(8):
        for target in (0, 2, 0xfffe, 0x10000, 0x10002, 0x1ffffe):
            cases.add((sd, target))
    for sd, target in sorted(cases):
        corpus.emit(f"jall s{sd}, {target}", jall(sd, target))
    for target in (0, 2, 0xfffe, 0x10000, 0x10002, 0x1ffffe):
        corpus.emit(f"jmpl {target}", jall(0, target))
    return corpus


def make_full_corpus() -> Corpus:
    corpus = Corpus("full", "full")
    for rd in range(8):
        for ra in range(8):
            for rb in range(8):
                corpus.emit(f"mul r{rd}, r{ra}, r{rb}", rr(rd, ra, 7, rb))
    for mnemonic, func, amounts in (
            ("slli", 0x0f, range(1, 9)),
            ("srli", 0x0c, range(2, 9)),
            ("srai", 0x0d, range(2, 9))):
        for rd in range(8):
            for ra in range(8):
                for amount in amounts:
                    corpus.emit(f"{mnemonic} r{rd}, r{ra}, {amount}",
                                rr(rd, ra, func, amount - 1))
    return corpus


def make_mdu_corpus() -> Corpus:
    corpus = Corpus("mdu", "full", "+rc32,+mdu")
    for mnemonic, func in (("divu", 0x10), ("mulhu", 0x14)):
        for first in range(8):
            for second in range(8):
                for source in range(8):
                    corpus.emit(
                        f"{mnemonic} r{first}, r{second}, r{source}",
                        rr(first, second, func, source),
                    )
    return corpus


def assemble(corpus: Corpus, llvm_mc: Path, llvm_objcopy: Path,
             tmp: Path) -> tuple[bool, str]:
    source_path = tmp / f"rc32-{corpus.name}.s"
    object_path = tmp / f"rc32-{corpus.name}.o"
    binary_path = tmp / f"rc32-{corpus.name}.bin"
    source_path.write_text("\n".join(corpus.lines) + "\n", encoding="ascii")
    mc = subprocess.run(
        [str(llvm_mc), "-triple=riscc-none-elf", f"-mcpu={corpus.cpu}",
         f"-mattr={corpus.attributes}", "-filetype=obj", "-o",
         str(object_path), str(source_path)],
        capture_output=True, text=True,
    )
    if mc.returncode:
        return False, mc.stderr
    objcopy = subprocess.run(
        [str(llvm_objcopy), "-O", "binary", "--only-section=.text",
         str(object_path), str(binary_path)],
        capture_output=True, text=True,
    )
    if objcopy.returncode:
        return False, objcopy.stderr
    actual = binary_path.read_bytes()
    expected = corpus.expected
    mismatch = next((index for index, (want, got) in
                     enumerate(zip(expected, actual)) if want != got), None)
    if mismatch is None and len(expected) != len(actual):
        mismatch = min(len(expected), len(actual))
    if mismatch is None:
        return True, ""
    index = bisect.bisect_right(corpus.offsets, mismatch) - 1
    context = corpus.contexts[index] if index >= 0 else "section padding"
    lo = max(0, mismatch - 8)
    hi = mismatch + 10
    return False, (
        f"{corpus.name} encoding mismatch at .text+0x{mismatch:x}\n"
        f"near: {context}\n"
        f"oracle: {expected[lo:hi].hex(' ')}\n"
        f"llvm-mc: {actual[lo:hi].hex(' ')}\n"
    )


def expect_rejection(llvm_mc: Path, tmp: Path, cpu: str,
                     instruction: str) -> tuple[bool, str]:
    output = tmp / "reject.o"
    result = subprocess.run(
        [str(llvm_mc), "-triple=riscc-none-elf", f"-mcpu={cpu}",
         "-mattr=+rc32", "-filetype=obj", "-o", str(output)],
        input=".text\n  " + instruction + "\n",
        capture_output=True, text=True,
    )
    if result.returncode:
        return True, ""
    return False, f"{cpu} unexpectedly accepted `{instruction}`\n"


def main() -> int:
    args = parse_args()
    for tool in (args.llvm_mc, args.llvm_objcopy):
        if not tool.is_file():
            print(f"tool not found: {tool}", file=sys.stderr)
            return 2

    corpora = (make_min_corpus(), make_sys_corpus(),
               make_full_corpus(), make_mdu_corpus())
    total_instructions = 0
    total_bytes = 0
    with tempfile.TemporaryDirectory(prefix="riscc-rc32-mc-") as tmp_name:
        tmp = Path(tmp_name)
        for corpus in corpora:
            ok, detail = assemble(corpus, args.llvm_mc, args.llvm_objcopy, tmp)
            if not ok:
                print(detail, file=sys.stderr, end="")
                return 1
            total_instructions += corpus.instructions
            total_bytes += len(corpus.expected)

        for cpu, instruction in (
                ("min", "jall s0, 0"),
                ("min", "reti s0"),
                ("min", "slli r0, r0, 1"),
                ("min", "srli r0, r0, 2"),
                ("min", "srai r0, r0, 8"),
                ("sys", "mul r0, r0, r0"),
                ("sys", "slli r0, r0, 1"),
                ("sys", "srli r0, r0, 2"),
                ("sys", "srai r0, r0, 8"),
                ("full", "ldi16 r0, 0"),
                ("full", "slli r0, r0, 0"),
                ("full", "srai r0, r0, 9")):
            ok, detail = expect_rejection(args.llvm_mc, tmp, cpu, instruction)
            if not ok:
                print(detail, file=sys.stderr, end="")
                return 1

    print(
        f"RC32 MC encoding oracle: {total_instructions:,} instructions, "
        f"{total_bytes:,} .text bytes matched; profile rejection PASS"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

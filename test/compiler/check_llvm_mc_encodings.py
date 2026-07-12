#!/usr/bin/env python3
"""Exhaustively compare LLVM MC's full-profile encodings to riscc_asm.py.

The test enumerates every operand bit-pattern accepted by each canonical
instruction format, including every signed short-branch displacement and all
15-bit JAL16 targets.  It also exhausts LI and the direct-call pseudos because
they are emitted by the compiler, then samples the spelling-only aliases.

LLVM MC is run once over the generated assembly.  Its raw .text bytes are
compared to calls to riscc_asm.encode_insn(), so the comparison does not let
either assembler parse the other one's output.
"""

from __future__ import annotations

import argparse
import bisect
import importlib.util
import subprocess
import sys
import tempfile
from array import array
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
ORACLE_PATH = ROOT / "tools" / "riscc_asm.py"


def load_oracle():
    spec = importlib.util.spec_from_file_location("riscc_asm_oracle", ORACLE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load encoding oracle: {ORACLE_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def parse_args() -> argparse.Namespace:
    default_bin = ROOT / "build" / "llvm-riscc" / "bin"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--llvm-mc", type=Path, default=default_bin / "llvm-mc",
        help="RISCC-enabled llvm-mc executable",
    )
    parser.add_argument(
        "--llvm-objcopy", type=Path, default=default_bin / "llvm-objcopy",
        help="llvm-objcopy executable paired with llvm-mc",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    for tool in (args.llvm_mc, args.llvm_objcopy):
        if not tool.is_file():
            print(f"error: tool not found: {tool}", file=sys.stderr)
            return 2

    oracle = load_oracle()
    expected = bytearray()
    instruction_offsets = array("I")
    source_positions = array("I")
    instruction_count = 0

    with tempfile.TemporaryDirectory(prefix="riscc-llvm-mc-") as tmp_name:
        tmp = Path(tmp_name)
        source_path = tmp / "all-full-encodings.s"
        object_path = tmp / "all-full-encodings.o"
        binary_path = tmp / "all-full-encodings.bin"

        with source_path.open("w", encoding="ascii") as source:
            source_position = 0

            def write(line: str) -> None:
                nonlocal source_position
                text = line + "\n"
                source.write(text)
                source_position += len(text)

            def emit(
                spelling: str,
                oracle_op: str,
                operands: list[str],
                labels: dict[str, int] | None = None,
            ) -> None:
                nonlocal instruction_count
                pc = len(expected)
                encoded = oracle.encode_insn(
                    oracle_op, operands, labels or {}, pc
                )
                instruction_offsets.append(pc)
                source_positions.append(source_position)
                write("  " + spelling)
                expected.extend(encoded)
                instruction_count += 1

            def emit_space(size: int) -> None:
                if size:
                    write(f"  .space {size}")
                    expected.extend(bytes(size))

            def emit_label(name: str) -> None:
                write(name + ":")

            write(".text")

            # Byte-displacement memory format.
            for op in ("LDW", "STW"):
                for rd in range(8):
                    for base in range(8):
                        for disp in range(-128, 128):
                            operands = [f"r{rd}", f"[r{base} + {disp}]"]
                            emit(f"{op.lower()} {', '.join(operands)}", op, operands)

            # Immediate format: unsigned and signed domains are both complete.
            for op in ("LDI", "LUI", "ANDI", "ORI", "XORI"):
                for rd in range(8):
                    for imm in range(256):
                        operands = [f"r{rd}", str(imm)]
                        emit(f"{op.lower()} {', '.join(operands)}", op, operands)
            for op in ("ADDI", "CMPI"):
                for rd in range(8):
                    for imm in range(-128, 128):
                        operands = [f"r{rd}", str(imm)]
                        emit(f"{op.lower()} {', '.join(operands)}", op, operands)

            # All five branch opcodes and all signed 8-bit word displacements.
            # Local labels make MC resolve the fixups rather than leaving relocs.
            branch_id = 0
            for op in ("BEQZ", "BNEZ", "BLTZ", "BGEZ", "JMP8"):
                for rel in range(-128, 128):
                    label = f"branch_target_{branch_id}"
                    branch_id += 1
                    if rel < 0:
                        target = len(expected)
                        emit_label(label)
                        emit_space(-2 * rel - 2)
                        emit(
                            f"{op.lower()} {label}", op, [label],
                            {label.upper(): target},
                        )
                    else:
                        pc = len(expected)
                        target = pc + 2 + 2 * rel
                        emit(
                            f"{op.lower()} {label}", op, [label],
                            {label.upper(): target},
                        )
                        emit_space(2 * rel)
                        emit_label(label)

            # Three-register ALU and indexed-load formats.
            for op in ("ADD", "SUB", "SLT", "SLTU", "AND", "OR", "XOR", "MUL"):
                for rd in range(8):
                    for ra in range(8):
                        for rb in range(8):
                            operands = [f"r{rd}", f"r{ra}", f"r{rb}"]
                            emit(f"{op.lower()} {', '.join(operands)}", op, operands)
            for op in ("LDWX", "LDB", "LDBS"):
                for rd in range(8):
                    for ra in range(8):
                        for rb in range(8):
                            operands = [f"r{rd}", f"[r{ra} + r{rb}]"]
                            emit(f"{op.lower()} {', '.join(operands)}", op, operands)
            for rd in range(8):
                for ra in range(8):
                    operands = [f"r{rd}", f"[r{ra}]"]
                    emit(f"stb {', '.join(operands)}", "STB", operands)

            # Biased three-bit shift counts.
            for op in ("SHLI", "SHRI", "SARI"):
                for rd in range(8):
                    for ra in range(8):
                        for amount in range(1, 9):
                            operands = [f"r{rd}", f"r{ra}", str(amount)]
                            emit(f"{op.lower()} {', '.join(operands)}", op, operands)

            # System-register forms.
            for sa in range(8):
                operands = [f"s{sa}"]
                emit(f"ret {operands[0]}", "RET", operands)
            for sd in range(8):
                for ra in range(8):
                    operands = [f"s{sd}", f"r{ra}"]
                    emit(f"jal {', '.join(operands)}", "JAL", operands)
            for rd in range(8):
                for sa in range(8):
                    operands = [f"r{rd}", f"s{sa}"]
                    emit(f"mfs {', '.join(operands)}", "MFS", operands)
            for sd in range(8):
                for ra in range(8):
                    operands = [f"s{sd}", f"r{ra}"]
                    emit(f"mts {', '.join(operands)}", "MTS", operands)
            for sa in range(8):
                operands = [f"s{sa}"]
                emit(f"reti {operands[0]}", "RETI", operands)

            # JAL16 has an eight-way S-register field and a 15-bit word target.
            for sd in range(8):
                for word_target in range(1 << 15):
                    target = word_target * 2
                    operands = [f"s{sd}", str(target)]
                    emit(f"jal16 {', '.join(operands)}", "JAL16", operands)
            emit("cli", "CLI", [])
            emit("sti", "STI", [])

            # Compiler-emitted pseudos.  LI is exhaustive because its paired
            # high/low emission has historically been a source of fixup bugs.
            for rd in range(8):
                for imm in range(1 << 16):
                    operands = [f"r{rd}", str(imm)]
                    emit(f"li {', '.join(operands)}", "LI", operands)
            for ra in range(8):
                operands = [f"r{ra}"]
                emit(f"call {operands[0]}", "CALL", operands)
            for op in ("CALL16", "JMP16"):
                for word_target in range(1 << 15):
                    operands = [str(word_target * 2)]
                    emit(f"{op.lower()} {operands[0]}", op, operands)
            emit("rets", "RETS", [])
            for rd in range(8):
                for ra in range(8):
                    operands = [f"r{rd}", f"r{ra}"]
                    emit(f"mov {', '.join(operands)}", "MOV", operands)
            emit("nop", "NOP", [])
            emit("halt", "HALT", [])

            # Parser-only legacy spellings share encodings with the canonical
            # forms above; one boundary-oriented sample each is sufficient.
            aliases = (
                ("ldi16 r7, 65535", "LI", ["r7", "65535"]),
                ("ldi8 r7, 255", "LDI", ["r7", "255"]),
                ("lui8 r0, 0", "LUI", ["r0", "0"]),
                ("addi8 r1, -128", "ADDI", ["r1", "-128"]),
                ("cmpi8 r2, 127", "CMPI", ["r2", "127"]),
                ("andi8 r3, 255", "ANDI", ["r3", "255"]),
                ("ori8 r4, 0", "ORI", ["r4", "0"]),
                ("xori8 r5, 165", "XORI", ["r5", "165"]),
            )
            for spelling, op, operands in aliases:
                emit(spelling, op, operands)

        mc = subprocess.run(
            [
                str(args.llvm_mc), "-triple=riscc-none-elf", "-mcpu=full",
                "-filetype=obj", "-o", str(object_path), str(source_path),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        if mc.returncode:
            print(mc.stderr, file=sys.stderr, end="")
            return mc.returncode

        objcopy = subprocess.run(
            [
                str(args.llvm_objcopy), "-O", "binary", "--only-section=.text",
                str(object_path), str(binary_path),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        if objcopy.returncode:
            print(objcopy.stderr, file=sys.stderr, end="")
            return objcopy.returncode

        actual = binary_path.read_bytes()
        mismatch = next(
            (i for i, (want, got) in enumerate(zip(expected, actual)) if want != got),
            None,
        )
        if mismatch is None and len(expected) != len(actual):
            mismatch = min(len(expected), len(actual))
        if mismatch is not None:
            index = bisect.bisect_right(instruction_offsets, mismatch) - 1
            context = "<section padding or end of file>"
            if index >= 0:
                with source_path.open("r", encoding="ascii") as source:
                    source.seek(source_positions[index])
                    context = source.readline().strip()
            lo = max(0, mismatch - 8)
            hi = mismatch + 10
            print(
                f"encoding mismatch at .text+0x{mismatch:x} near `{context}`\n"
                f"oracle: {expected[lo:hi].hex(' ')}\n"
                f"llvm-mc: {actual[lo:hi].hex(' ')}",
                file=sys.stderr,
            )
            return 1

    print(
        f"RISCC LLVM MC encoding oracle: {instruction_count:,} instructions, "
        f"{len(expected):,} .text bytes matched"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

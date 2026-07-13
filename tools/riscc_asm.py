#!/usr/bin/env python3
"""Assembler for RISC-C (see doc/RISC-C.md).

Flat two-pass assembler.  Labels evaluate to byte addresses.  Branch
displacements are word-relative from PC+1; register jump/call targets are word
addresses, so use expressions such as ``target >> 1`` when materializing them.

The source preprocessor supports simple conditional assembly:
``.ifdef NAME``, ``.ifndef NAME``, ``.else``, and ``.endif``.  Define symbols
with ``-D NAME`` on the command line, or select an ISA profile with
``--profile min|sys|full|nano``.  The default profile is ``sys``.  A profile
selection defines its corresponding ``RISCC_*`` symbol; ``full`` also defines
``RISCC_SYS`` because it includes the system profile.
"""
import argparse
import ast
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Tuple


RISCC_VERSION = (Path(__file__).resolve().parents[1] / "VERSION").read_text().strip()


REGS: Dict[str, int] = {f"R{i}": i for i in range(8)}

SECTION_ORDER = [".VECTORS", ".TEXT", ".RODATA", ".DATA", ".BSS"]
SECTION_ALIGN = {name: 2 for name in SECTION_ORDER}

I_OP = {
    "LDI": 0, "LDI8": 0,
    "LUI": 1, "LUI8": 1,
    "ADDI": 2, "ADDI8": 2,
    "CMPI": 3, "CMPI8": 3,
    "ANDI": 4, "ANDI8": 4,
    "ORI": 5, "ORI8": 5,
    "XORI": 6, "XORI8": 6,
}

BR_CC = {
    "BEQZ": 0,
    "BNEZ": 1,
    "BLTZ": 2,
    "BGEZ": 3,
    "JMP8": 4,
}

R_FUNC = {
    "ADD": 0x00,
    "SUB": 0x01,
    "SLT": 0x02,
    "SLTU": 0x03,
    "AND": 0x04,
    "OR": 0x05,
    "XOR": 0x06,
    "MUL": 0x07,
    "LDWX": 0x08,
    "LDB": 0x0A,
    "STB": 0x0B,
    "SHRI": 0x0C,
    "SARI": 0x0D,
    "LDBS": 0x0E,
    "SHLI": 0x0F,
    "SYS": 0x1F,
}

# RET/RETI share bbb=000 and CLI/STI share bbb=110.  ccc occupies ddd and is
# 000 for the IE-preserving/clearing form and 111 for the IE-setting form.
# MFEPC/MTEPC are aliases of MFS/MTS with S0 (EPC).
# reset starts at word 0, IRQ enters at word 2.
SYS_SUB = {"RET": 0, "JAL": 1, "MFS": 2, "MTS": 3,
           "JAL16": 5, "IE": 6}
CONTROL_CCC = {"RET": 0, "RETI": 7, "CLI": 0, "STI": 7}

SREGS = {f"S{i}": i for i in range(8)}

MNEMONIC_ALIASES = {
    "MOV": "OR",
    "SHL1": "ADD",
    }


class AsmError(Exception):
    pass


@dataclass
class Item:
    section: str
    offset: int
    size: int
    kind: str
    op: str
    operands: List[str]
    lineno: int
    raw: str


def strip_comment(line: str) -> str:
    out: List[str] = []
    quote = ""
    escape = False
    for ch in line:
        if quote:
            out.append(ch)
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == quote:
                quote = ""
            continue
        if ch in ("'", '"'):
            quote = ch
            out.append(ch)
            continue
        if ch in (";", "#"):
            break
        out.append(ch)
    return "".join(out).strip()


def split_operands(text: str) -> List[str]:
    parts: List[str] = []
    cur: List[str] = []
    depth = 0
    for ch in text:
        if ch == "[":
            depth += 1
        elif ch == "]":
            depth -= 1
        elif ch == "," and depth == 0:
            part = "".join(cur).strip()
            if part:
                parts.append(part)
            cur = []
            continue
        cur.append(ch)
    part = "".join(cur).strip()
    if part:
        parts.append(part)
    return parts


def parse_string(token: str) -> str:
    try:
        value = ast.literal_eval(token)
    except Exception as exc:
        raise AsmError(f"invalid string literal: {token}") from exc
    if not isinstance(value, str):
        raise AsmError(f"expected string literal: {token}")
    return value


def eval_expr(text: str, labels: Dict[str, int]) -> int:
    token = text.strip()
    if (token.startswith("'") and token.endswith("'")) or (
        token.startswith('"') and token.endswith('"')
    ):
        value = parse_string(token)
        if len(value) != 1:
            raise AsmError(f"character literal must be length 1: {text}")
        return ord(value)

    try:
        node = ast.parse(token, mode="eval")
    except SyntaxError as exc:
        raise AsmError(f"invalid expression: {text}") from exc

    def visit(expr: ast.AST) -> int:
        if isinstance(expr, ast.Expression):
            return visit(expr.body)
        if isinstance(expr, ast.Constant) and isinstance(expr.value, int):
            return expr.value
        if isinstance(expr, ast.UnaryOp) and isinstance(expr.op, ast.USub):
            return -visit(expr.operand)
        if isinstance(expr, ast.UnaryOp) and isinstance(expr.op, ast.UAdd):
            return visit(expr.operand)
        if isinstance(expr, ast.BinOp) and isinstance(expr.op, ast.Add):
            return visit(expr.left) + visit(expr.right)
        if isinstance(expr, ast.BinOp) and isinstance(expr.op, ast.Sub):
            return visit(expr.left) - visit(expr.right)
        if isinstance(expr, ast.BinOp) and isinstance(expr.op, ast.LShift):
            return visit(expr.left) << visit(expr.right)
        if isinstance(expr, ast.BinOp) and isinstance(expr.op, ast.RShift):
            return visit(expr.left) >> visit(expr.right)
        if isinstance(expr, ast.BinOp) and isinstance(expr.op, ast.BitOr):
            return visit(expr.left) | visit(expr.right)
        if isinstance(expr, ast.BinOp) and isinstance(expr.op, ast.BitAnd):
            return visit(expr.left) & visit(expr.right)
        if isinstance(expr, ast.Name):
            key = expr.id.upper()
            if key not in labels:
                raise AsmError(f"unknown symbol: {expr.id}")
            return labels[key]
        raise AsmError(f"unsupported expression: {text}")

    return visit(node)


def reg(token: str) -> int:
    key = token.strip().upper()
    if key not in REGS:
        raise AsmError(f"expected register r0..r7, got: {token}")
    return REGS[key]


def sreg(token: str) -> int:
    key = token.strip().upper()
    if key not in SREGS:
        raise AsmError(f"expected system register S0..S7, got: {token}")
    return SREGS[key]


def enc_u8(value: int, what: str) -> int:
    if not (0 <= value <= 0xFF):
        raise AsmError(f"{what} out of u8 range: {value}")
    return value


def enc_i8(value: int, what: str) -> int:
    if not (-128 <= value <= 127):
        raise AsmError(f"{what} out of i8 range: {value}")
    return value & 0xFF


def encode_word(word: int) -> bytes:
    return bytes((word & 0xFF, (word >> 8) & 0xFF))


def parse_mem(token: str) -> List[str]:
    text = token.strip()
    if not text.startswith("[") or not text.endswith("]"):
        raise AsmError(f"invalid memory operand: {token}")
    inner = text[1:-1].strip()
    match = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*(.*)$", inner)
    if not match:
        raise AsmError(f"invalid memory operand: {token}")
    base, rest = match.group(1), match.group(2).strip()
    if not rest:
        return [base]
    if rest.startswith("+"):
        return [base, rest[1:].strip()]
    if rest.startswith("-"):
        return [base, rest]
    raise AsmError(f"invalid memory operand: {token}")


def parse_section_name(text: str) -> str:
    name = text.strip().upper()
    if not name.startswith("."):
        name = "." + name
    if name not in SECTION_ORDER:
        raise AsmError(f"unknown section: {text}")
    return name


def to_word_addr(value: int, what: str) -> int:
    if value & 1:
        raise AsmError(f"{what} must be word-aligned: {value:#x}")
    return (value >> 1) & 0xFFFF


def insn_size(op: str, operands: List[str]) -> int:
    op = op.upper()
    if op in ("LDI16", "LI", "CALL16", "JMP16", "JAL16"):
        return 4
    if MNEMONIC_ALIASES.get(op, op) == "OR" and op == "MOV":
        return 2
    if MNEMONIC_ALIASES.get(op, op) == "ADD" and op == "SHL1":
        return 2
    return 2


def define_name(text: str) -> str:
    name = text.strip().split("=", 1)[0].upper()
    if not re.match(r"^[A-Z_][A-Z0-9_]*$", name):
        raise AsmError(f"invalid define name: {text}")
    return name


def preprocess_source(lines: List[str], defines: set[str]) -> List[str]:
    out: List[str] = []
    # Stack entries are (parent_active, condition_true, seen_else).
    stack: List[Tuple[bool, bool, bool]] = []
    active = True

    for lineno, raw in enumerate(lines, start=1):
        line = strip_comment(raw)
        parts = line.split(None, 1)
        directive = parts[0].lower() if parts and parts[0].startswith(".") else ""
        arg = parts[1].strip() if len(parts) > 1 else ""

        if directive in (".ifdef", ".ifndef"):
            if not arg:
                raise AsmError(f"line {lineno}: {directive} requires a symbol")
            cond = define_name(arg) in defines
            if directive == ".ifndef":
                cond = not cond
            stack.append((active, cond, False))
            active = active and cond
            out.append("\n")
            continue

        if directive == ".else":
            if not stack:
                raise AsmError(f"line {lineno}: .else without .ifdef/.ifndef")
            parent, cond, seen_else = stack[-1]
            if seen_else:
                raise AsmError(f"line {lineno}: duplicate .else")
            stack[-1] = (parent, cond, True)
            active = parent and not cond
            out.append("\n")
            continue

        if directive == ".endif":
            if not stack:
                raise AsmError(f"line {lineno}: .endif without .ifdef/.ifndef")
            parent, _cond, _seen_else = stack.pop()
            active = parent
            out.append("\n")
            continue

        out.append(raw if active else "\n")

    if stack:
        raise AsmError("unterminated .ifdef/.ifndef")
    return out


def parse_source(lines: List[str]) -> Tuple[List[Item], Dict[str, Tuple[str, int]]]:
    items: List[Item] = []
    labels: Dict[str, Tuple[str, int]] = {}
    offsets = {name: 0 for name in SECTION_ORDER}
    section = ".TEXT"

    for lineno, raw in enumerate(lines, start=1):
        line = strip_comment(raw)
        if not line:
            continue

        rest = line
        while True:
            match = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$", rest)
            if not match:
                break
            name = match.group(1).upper()
            if name in labels:
                raise AsmError(f"line {lineno}: duplicate label {name}")
            labels[name] = (section, offsets[section])
            rest = match.group(2).strip()
            if not rest:
                break

        if not rest:
            continue

        if rest.startswith("."):
            parts = rest.split(None, 1)
            directive = parts[0].lower()
            arg_text = parts[1] if len(parts) > 1 else ""
            if directive in (".vectors", ".text", ".rodata", ".data", ".bss"):
                section = parse_section_name(directive)
                continue
            if directive == ".byte":
                ops = split_operands(arg_text)
                items.append(Item(section, offsets[section], len(ops), "BYTE", directive, ops, lineno, raw.rstrip()))
                offsets[section] += len(ops)
                continue
            if directive == ".word":
                ops = split_operands(arg_text)
                items.append(Item(section, offsets[section], 2 * len(ops), "WORD", directive, ops, lineno, raw.rstrip()))
                offsets[section] += 2 * len(ops)
                continue
            if directive in (".ascii", ".asciz"):
                value = parse_string(arg_text.strip())
                size = len(value) + (1 if directive == ".asciz" else 0)
                items.append(Item(section, offsets[section], size, "ASCII", directive, [value], lineno, raw.rstrip()))
                offsets[section] += size
                continue
            if directive == ".space":
                size = eval_expr(arg_text, {})
                if size < 0:
                    raise AsmError(f"line {lineno}: negative .space")
                items.append(Item(section, offsets[section], size, "SPACE", directive, [arg_text], lineno, raw.rstrip()))
                offsets[section] += size
                continue
            if directive == ".align":
                align = eval_expr(arg_text, {}) if arg_text else 2
                cur = offsets[section]
                size = ((cur + align - 1) & -align) - cur
                items.append(Item(section, offsets[section], size, "SPACE", directive, [], lineno, raw.rstrip()))
                offsets[section] += size
                continue
            raise AsmError(f"line {lineno}: unsupported directive {directive}")

        parts = rest.split(None, 1)
        op = parts[0].upper()
        operands = split_operands(parts[1]) if len(parts) > 1 else []
        items.append(Item(section, offsets[section], insn_size(op, operands), "INSN", op, operands, lineno, raw.rstrip()))
        offsets[section] += items[-1].size

    return items, labels


def layout_sections(items: List[Item]) -> Dict[str, int]:
    sizes = {name: 0 for name in SECTION_ORDER}
    for item in items:
        sizes[item.section] = max(sizes[item.section], item.offset + item.size)
    bases: Dict[str, int] = {}
    cursor = 0
    for section in SECTION_ORDER:
        align = SECTION_ALIGN[section]
        cursor = (cursor + align - 1) & -align
        bases[section] = cursor
        cursor += sizes[section]
    return bases


def final_label_map(labels: Dict[str, Tuple[str, int]], bases: Dict[str, int]) -> Dict[str, int]:
    return {name: bases[section] + offset for name, (section, offset) in labels.items()}


def enc_mem_i(store: bool, rd: int, ra: int, imm8: int) -> int:
    return ((1 if store else 0) << 14) | (rd << 11) | (ra << 8) | imm8


def enc_i(rd: int, op: int, imm8: int) -> int:
    return (2 << 14) | (rd << 11) | (op << 8) | imm8


def enc_r(rd: int, ra: int, func: int, rb: int) -> int:
    return (3 << 14) | (rd << 11) | (ra << 8) | (func << 3) | rb


def enc_branch(cc: int, rel8: int) -> int:
    return enc_i(cc, 7, rel8)


def encode_insn(op: str, operands: List[str], labels: Dict[str, int], pc: int) -> bytes:
    op = op.upper()

    def n_ops(count: int, usage: str) -> None:
        if len(operands) != count:
            raise AsmError(f"{op} requires {count} operand(s): {usage}")

    if op in ("JAL16", "CALL16", "JMP16"):
        # Two-word direct jump-and-link: word 1 is the target word address.
        # Sd == S0 writes no link; CALL16 = JAL16 S7, JMP16 = JAL16 S0.
        if op == "JAL16":
            n_ops(2, "JAL16 Sd, target")
            sd = sreg(operands[0])
            target = eval_expr(operands[1], labels)
        else:
            n_ops(1, f"{op} target")
            sd = 7 if op == "CALL16" else 0
            target = eval_expr(operands[0], labels)
        return (encode_word(enc_r(sd, 0, R_FUNC["SYS"], SYS_SUB["JAL16"]))
                + encode_word(to_word_addr(target, f"{op} target")))

    if op in ("RET", "RETS", "RETI", "ERET"):
        # RET Sa: pc = S[aaa], IE untouched; RETI Sa also sets IE.
        # RETS = RET S7; ERET = RETI S0.  RET ra (general register) is the
        # link-free register jump, i.e. JAL S0, ra.
        sub = "RETI" if op in ("RETI", "ERET") else "RET"
        if len(operands) == 0:
            sa = 7 if op in ("RET", "RETS") else 0
        else:
            n_ops(1, f"{op} Sa")
            tok = operands[0].strip().upper()
            if tok in REGS and op == "RET":
                return encode_word(enc_r(0, REGS[tok],
                                         R_FUNC["SYS"], SYS_SUB["JAL"]))
            sa = sreg(operands[0])
        return encode_word(enc_r(CONTROL_CCC[sub], sa, R_FUNC["SYS"],
                                 SYS_SUB["RET"]))

    if op in ("LDI16", "LI"):
        n_ops(2, "LDI16 rd, imm16")
        rd = reg(operands[0])
        imm = eval_expr(operands[1], labels) & 0xFFFF
        return encode_word(enc_i(rd, I_OP["LUI"], (imm >> 8) & 0xFF)) + \
            encode_word(enc_i(rd, I_OP["ORI"], imm & 0xFF))

    if op == "NOP":
        n_ops(0, "NOP")
        return encode_word(enc_r(0, 0, R_FUNC["OR"], 0))

    if op in ("LDW", "STW"):
        n_ops(2, f"{op} rd, [ra+simm8]")
        rd = reg(operands[0])
        mem = parse_mem(operands[1])
        if not (1 <= len(mem) <= 2):
            raise AsmError(f"{op} expects [ra] or [ra+simm8]")
        ra = reg(mem[0])
        disp = 0 if len(mem) == 1 else eval_expr(mem[1], labels)
        imm8 = enc_i8(disp, f"{op} simm8")
        return encode_word(enc_mem_i(op == "STW", rd, ra, imm8))

    if op in I_OP:
        n_ops(2, f"{op} rd, imm8")
        rd = reg(operands[0])
        value = eval_expr(operands[1], labels)
        imm = enc_i8(value, f"{op} simm8") if op in ("ADDI", "ADDI8", "CMPI", "CMPI8") else enc_u8(value & 0xFF, f"{op} imm8")
        return encode_word(enc_i(rd, I_OP[op], imm))

    if op in BR_CC:
        n_ops(1, f"{op} target")
        target = eval_expr(operands[0], labels)
        if target & 1:
            raise AsmError(f"{op} target must be word-aligned: {target:#x}")
        rel = (target >> 1) - ((pc >> 1) + 1)
        return encode_word(enc_branch(BR_CC[op], enc_i8(rel, f"{op} rel8")))

    if op in ("MOV", "SHL1"):
        if op == "MOV":
            n_ops(2, "MOV rd, ra")
            rd = reg(operands[0])
            ra = reg(operands[1])
            return encode_word(enc_r(rd, ra, R_FUNC["OR"], ra))
        n_ops(2, "SHL1 rd, ra")
        rd = reg(operands[0])
        ra = reg(operands[1])
        return encode_word(enc_r(rd, ra, R_FUNC["ADD"], ra))

    if op in ("ADD", "SUB", "AND", "OR", "XOR", "SLT", "SLTU", "MUL"):
        n_ops(3, f"{op} rd, ra, rb")
        return encode_word(enc_r(reg(operands[0]), reg(operands[1]), R_FUNC[op], reg(operands[2])))

    if op in ("SHLI", "SHRI", "SARI"):
        # Shift by immediate: amount 1..8, encoded biased in the rb field.
        n_ops(3, f"{op} rd, ra, imm")
        amount = eval_expr(operands[2], labels)
        if not 1 <= amount <= 8:
            raise AsmError(f"{op} amount must be 1..8, got {amount}")
        return encode_word(enc_r(reg(operands[0]), reg(operands[1]),
                                 R_FUNC[op], amount - 1))

    if op in ("LDWX", "LDB", "LDBS"):
        n_ops(2, f"{op} rd, [ra+rb]")
        rd = reg(operands[0])
        mem = parse_mem(operands[1])
        if len(mem) != 2:
            raise AsmError(f"{op} requires [ra+rb]")
        return encode_word(enc_r(rd, reg(mem[0]), R_FUNC[op], reg(mem[1])))

    if op == "STB":
        n_ops(2, f"{op} rd, [ra]")
        rd = reg(operands[0])
        mem = parse_mem(operands[1])
        if len(mem) != 1:
            raise AsmError(f"{op} requires [ra]")
        return encode_word(enc_r(rd, reg(mem[0]), R_FUNC["STB"], 0))

    if op in ("JAL", "JMP", "CALL"):
        # JAL Sd, ra: S[ddd] = pc_next unless ddd == S0, pc = ra.
        # JMP ra = JAL S0, ra; CALL ra = JAL S7, ra.  Nano's dialect links
        # into a general register: CALL rd, ra (same encoding, ddd names rd).
        if op == "JMP" or len(operands) == 1:
            n_ops(1, f"{op} ra")
            d = 0 if op == "JMP" else 7
            return encode_word(enc_r(d, reg(operands[0]),
                                     R_FUNC["SYS"], SYS_SUB["JAL"]))
        n_ops(2, f"{op} Sd, ra")
        tok = operands[0].strip().upper()
        d = REGS[tok] if tok in REGS else sreg(operands[0])
        return encode_word(enc_r(d, reg(operands[1]),
                                 R_FUNC["SYS"], SYS_SUB["JAL"]))

    if op in ("CLI", "STI"):
        n_ops(0, op)
        return encode_word(enc_r(CONTROL_CCC[op], 0, R_FUNC["SYS"],
                                 SYS_SUB["IE"]))

    if op == "MFS":
        n_ops(2, "MFS rd, Sn")
        return encode_word(enc_r(reg(operands[0]), sreg(operands[1]),
                                 R_FUNC["SYS"], SYS_SUB["MFS"]))

    if op == "MTS":
        n_ops(2, "MTS Sn, ra")
        return encode_word(enc_r(sreg(operands[0]), reg(operands[1]),
                                 R_FUNC["SYS"], SYS_SUB["MTS"]))

    if op == "MFEPC":
        n_ops(1, "MFEPC rd")
        return encode_word(enc_r(reg(operands[0]), 0,
                                 R_FUNC["SYS"], SYS_SUB["MFS"]))

    if op == "MTEPC":
        n_ops(1, "MTEPC ra")
        return encode_word(enc_r(0, reg(operands[0]),
                                 R_FUNC["SYS"], SYS_SUB["MTS"]))

    if op == "HALT":
        n_ops(0, "HALT")
        return encode_word(enc_branch(BR_CC["JMP8"], enc_i8(-1, "HALT rel8")))

    raise AsmError(f"unknown instruction: {op}")


def emit_item(item: Item, labels: Dict[str, int], bases: Dict[str, int]) -> bytes:
    pc = bases[item.section] + item.offset
    if item.kind == "INSN":
        if pc & 1:
            raise AsmError(f"line {item.lineno}: instruction address not word-aligned")
        try:
            return encode_insn(item.op, item.operands, labels, pc)
        except AsmError as exc:
            raise AsmError(f"line {item.lineno}: {exc}") from exc
    if item.kind == "BYTE":
        data = bytearray()
        for operand in item.operands:
            data.append(eval_expr(operand, labels) & 0xFF)
        return bytes(data)
    if item.kind == "WORD":
        data = bytearray()
        for operand in item.operands:
            data += encode_word(eval_expr(operand, labels) & 0xFFFF)
        return bytes(data)
    if item.kind == "ASCII":
        data = item.operands[0].encode("latin1")
        if item.op == ".asciz":
            data += b"\x00"
        return data
    if item.kind == "SPACE":
        return bytes(item.size)
    raise AsmError(f"internal error: unknown item kind {item.kind}")


def assemble(lines: List[str], defines: set[str] | None = None) -> bytes:
    filtered = preprocess_source(lines, defines or set())
    items, label_defs = parse_source(filtered)
    bases = layout_sections(items)
    labels = final_label_map(label_defs, bases)

    sizes = {name: 0 for name in SECTION_ORDER}
    for item in items:
        sizes[item.section] = max(sizes[item.section], item.offset + item.size)

    blobs = {name: bytearray(sizes[name]) for name in SECTION_ORDER}
    for item in items:
        data = emit_item(item, labels, bases)
        if len(data) != item.size:
            raise AsmError(
                f"line {item.lineno}: internal size mismatch for {item.op}: "
                f"expected {item.size}, got {len(data)}"
            )
        blobs[item.section][item.offset:item.offset + item.size] = data

    image = bytearray()
    cursor = 0
    for section in SECTION_ORDER:
        align = SECTION_ALIGN[section]
        base = (cursor + align - 1) & -align
        if len(image) < base:
            image.extend(bytes(base - len(image)))
        image.extend(blobs[section])
        cursor = base + len(blobs[section])
    return bytes(image)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", action="version", version=f"riscc-asm {RISCC_VERSION}")
    parser.add_argument("--profile", choices=("min", "sys", "full", "nano"),
                        default="sys",
                        help="profile symbol for conditional assembly (default: sys)")
    parser.add_argument("input")
    parser.add_argument("-o", "--output", required=True)
    parser.add_argument("-D", "--define", action="append", default=[],
                        help="define a conditional assembly symbol")
    args = parser.parse_args()

    try:
        defines = {define_name(name) for name in args.define}
        defines.add(f"RISCC_{args.profile.upper()}")
        if args.profile == "full":
            defines.add("RISCC_SYS")
        with open(args.input, "r", encoding="utf-8") as src:
            image = assemble(src.readlines(), defines)
        with open(args.output, "wb") as out:
            out.write(image)
    except (OSError, AsmError, SyntaxError) as exc:
        print(f"riscc_asm: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

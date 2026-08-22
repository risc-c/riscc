#!/usr/bin/env python3
"""RISC-C differential fuzzer.

Generates seeded random programs, predicts their final architectural
state with the C++ ISS,
and emits SELF-CHECKING binaries: the epilogue compares every register
(and probed memory words, and the IRQ/BRK counters) against the ISS
prediction and writes the standard 0x600D/0x0BAD result word.  The same
binary then runs unchanged under any RTL core's testbench -- a divergence
between the RTL and the ISS shows up as a FAIL with a distinct code per
checked item.

Program shape (per seed): random straight-line ALU/imm/memory ops over
r1..r6 with a high-RAM data window,
forward-branch blocks, bounded counted loops, explicit-link subroutines,
MTS/MFS spills, and -- in sys
configs -- STI/CLI and testbench-IRQ triggers (counted in S1) with a
save/restore handler. Vector layout follows the exception model: reset
enters at word 0 and IRQ at word 2; min images have no vector table.

Usage:
  riscc_fuzz.py --seed 42 --config sys
  riscc_fuzz.py --campaign 25 --cores rc16-1,rc16-2,rc16-4,rc16-8,rc16-16
  riscc_fuzz.py --campaign 25                 # random campaign base seed
  riscc_fuzz.py --campaign 25 --base-seed 12345
  riscc_fuzz.py --family nano --campaign 25
  riscc_fuzz.py --family rc32 --campaign 25
  riscc_fuzz.py --campaign 25 --config sys --cores rc16-1
"""

import argparse
import os
import random
import shlex
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
with open(os.path.join(ROOT, "VERSION"), encoding="utf-8") as version_file:
    RISCC_VERSION = version_file.read().strip()
RTL = os.path.join(ROOT, "rtl")
TEST = os.path.join(ROOT, "test")
WIN = 0xFC00              # data window, high RAM below the suite scratch
WIN_WORDS = 32
NANO_SCRATCH = 0xFB00     # saved nano GPR image, below WIN
RC32_WIN = 0xFC00         # 4-byte aligned RC32 data window
RC32_WIN_WORDS = 16
TEST_IRQ = 0xFFFA         # I/O page: write trigger, read acknowledge
RESULT = 0xFFFE           # I/O page: result register
FAILBASE = 0x0B00         # fail codes 0x0B01.. per checked item

RC16_CONFIGS = ("min", "sys", "full")
NANO_CONFIGS = ("nano",)
# Sys executes this Min-subset corpus on its own RTL; the dedicated RC32 Sys
# smoke test covers IE, IRQ, RETI, JALL, and JMPL until the ISS models them.
RC32_CONFIGS = ("min", "sys")
RC32_WIDTHS = (1, 2, 4, 8, 16)


def parse_config(config):
    if config not in RC16_CONFIGS:
        raise ValueError("unknown config: %s" % config)
    return {
        "sys": config != "min",
        "shifts": config == "full",
        "long_calls": config in ("sys", "full"),
        "full": config == "full",
    }


def config_defs(config):
    cfg = parse_config(config)
    defs = []
    if not cfg["sys"]:
        defs.append("-DRISCC_MIN")
    else:
        defs.append("-DRISCC_SYS")
    if cfg["full"]:
        defs.append("-DRISCC_FULL")
    return " ".join(defs)


class Gen:
    def __init__(self, seed, config):
        cfg = parse_config(config)
        self.rng = random.Random(seed)
        self.seed = seed
        self.config = config
        self.sys = cfg["sys"]
        self.shifts = cfg["shifts"]
        self.long_calls = cfg["long_calls"]
        self.full = cfg["full"]
        self.label = 0

    def new_label(self, stem):
        self.label += 1
        return "%s_%d" % (stem, self.label)

    def reg(self):
        return "r%d" % self.rng.randint(1, 6)

    # ---- random body pieces -------------------------------------------
    def op_alu(self):
        ops = ["ADD", "SUB", "SLT", "SLTU", "AND", "OR", "XOR"]
        op = self.rng.choice(ops)
        return ["    %-5s %s, %s, %s" % (op, self.reg(), self.reg(), self.reg())]

    def op_imm(self):
        op = self.rng.choice(["LDI", "LUI", "ADDI", "CMPI", "ANDI", "ORI", "XORI"])
        v = self.rng.randint(-128, -1) if op in ("ADDI", "CMPI") and self.rng.random() < 0.5 \
            else self.rng.randint(0, 127 if op in ("ADDI", "CMPI") else 255)
        return ["    %-5s %s, %d" % (op, self.reg(), v)]

    def op_shift(self):
        if self.shifts:
            op = self.rng.choice(["SRLI", "SRAI", "SLLI"])
            n = self.rng.randint(1, 8)
        else:
            op = self.rng.choice(["SRLI", "SRAI"])
            n = 1
        return ["    %-5s %s, %s, %d" % (op, self.reg(), self.reg(), n)]

    def op_mul(self):
        return ["    MUL   %s, %s, %s" % (self.reg(), self.reg(), self.reg())]

    def op_mem(self):
        off = self.rng.randrange(0, WIN_WORDS) * 2
        lines = ["    LDI16 r7, 0x%04X" % WIN]
        k = self.rng.random()
        if k < 0.35:
            lines.append("    ST   %s, [r7+%d]" % (self.reg(), off))
        elif k < 0.70:
            lines.append("    LD   %s, [r7+%d]" % (self.reg(), off))
        elif k < 0.85:
            boff = self.rng.randrange(0, WIN_WORDS * 2)
            lines.append("    LDI   r0, %d" % boff)
            lines.append("    ADD   r0, r7, r0")
            op = self.rng.choice(["LDB", "LDBS"])
            lines.append("    %-5s %s, [r0]" % (op, self.reg()))
        else:
            boff = self.rng.randrange(0, WIN_WORDS * 2)
            lines.append("    LDI   r0, %d" % boff)
            lines.append("    ADD   r0, r7, r0")
            lines.append("    STB   %s, [r0]" % self.reg())
        return lines

    def op_sreg(self):
        s = self.rng.randint(4, 6)
        if self.rng.random() < 0.5:
            return ["    MTS   S%d, %s" % (s, self.reg())]
        return ["    MFS   %s, S%d" % (self.reg(), s)]

    def op_branch_block(self):
        lab = self.new_label("fwd")
        cc = self.rng.choice(["BEQZ", "BNEZ", "BLTZ", "BGEZ"])
        lines = ["    CMPI  %s, %d" % (self.reg(), self.rng.randint(0, 127)),
                 "    %-5s %s" % (cc, lab)]
        for _ in range(self.rng.randint(1, 4)):
            lines += self.simple_op()
        lines.append("%s:" % lab)
        return lines

    def op_loop(self):
        lab = self.new_label("loop")
        cnt = "r%d" % self.rng.randint(1, 6)
        body = []
        for _ in range(self.rng.randint(1, 3)):
            body += self.simple_op(exclude=cnt)
        return (["    LDI   %s, %d" % (cnt, self.rng.randint(1, 5)),
                 "%s:" % lab] + body +
                ["    ADDI  %s, -1" % cnt,
                 "    MOV   r0, %s" % cnt,
                 "    BNEZ  %s" % lab])

    def op_call(self, subs):
        lab = self.new_label("sub")
        body = []
        for _ in range(self.rng.randint(1, 3)):
            body += self.simple_op()
        subs.append(("%s:" % lab, body + ["    RET S7"]))
        if self.long_calls and self.rng.random() < 0.5:
            return ["    JALL S7, %s" % lab]
        r = self.reg()
        return ["    LDI16 %s, %s" % (r, lab),
                "    JALR S7, %s" % r]

    def op_irq(self):
        return ["    STI",
                "    LDI16 r7, 0x%04X" % TEST_IRQ,
                "    ST   r7, [r7+0]"]

    def simple_op(self, exclude=None):
        while True:
            k = self.rng.random()
            if k < 0.35:
                lines = self.op_alu()
            elif k < 0.65:
                lines = self.op_imm()
            elif k < 0.80:
                lines = self.op_shift()
            elif k < 0.90 and self.full:
                lines = self.op_mul()
            else:
                lines = self.op_sreg()
            if exclude is None or not any((exclude + ",") in l or l.rstrip().endswith(exclude)
                                          for l in lines):
                return lines

    # ---- program assembly ----------------------------------------------
    def body(self):
        subs = []
        lines = []
        # deterministic window init
        lines.append("    LDI16 r7, 0x%04X" % WIN)
        for w in range(WIN_WORDS):
            lines.append("    LDI16 r1, 0x%04X" % self.rng.randint(0, 0xFFFF))
            lines.append("    ST   r1, [r7+%d]" % (w * 2))
        for _ in range(self.rng.randint(25, 45)):
            k = self.rng.random()
            if k < 0.45:
                lines += self.simple_op()
            elif k < 0.60:
                lines += self.op_mem()
            elif k < 0.72:
                lines += self.op_branch_block()
            elif k < 0.82:
                lines += self.op_loop()
            elif k < 0.90:
                lines += self.op_call(subs)
            elif self.sys:
                lines += self.op_irq()
            else:
                lines += self.simple_op()
        return lines, subs

    def emit(self, expect=None):
        """expect = None -> probe build (dump state, always 'pass').
           expect = dict -> self-checking build."""
        head = [
            "; generated by riscc_fuzz.py seed=%d config=%s"
            % (self.seed, self.config),
            ".vectors",
        ]
        if self.sys:
            if self.long_calls:
                head += [
                    "    JMPL reset_tramp",
                    "    JMPL irq_h",
                    "    JMPL brk_h",
                ]
            else:
                head += [
                    "    JMP8 reset_tramp",
                    "    LDI   r0, 0",
                    "    JMP8 irq_h",
                ]
        head += [
            ".text",
            "reset_tramp:",
            "    LDI16 r0, start",
            "    JMP   r0",
            "fail:",
            "    LDI16 r7, 0x0BAD",
            "    LDI16 r6, 0x%04X" % RESULT,
            "    ST   r7, [r6+0]",
            "    HALT",
        ]
        if self.sys:
            head += [
                "irq_h:",                       # count in S1, ack, resume
                "    MTS   S2, r1",
                "    MFS   r1, S1",
                "    ADDI  r1, 1",
                "    MTS   S1, r1",
                "    LDI16 r1, 0x%04X" % TEST_IRQ,
                "    LD   r1, [r1+0]",
                "    MFS   r1, S2",
                "    RETI S0",
                "brk_h:",                       # count in S3, resume
                "    MTS   S2, r1",
                "    MFS   r1, S3",
                "    ADDI  r1, 1",
                "    MTS   S3, r1",
                "    MFS   r1, S2",
                "    RETI S0",
            ]
        self.rng = random.Random(self.seed)     # regenerate identically
        self.label = 0
        body, subs = self.body()

        # subroutines live at a fixed place BEFORE the epilogue so that
        # label addresses (captured into registers by LDI16 sub) are
        # identical in the probe and self-checking builds
        for lab, code_lines in subs:
            head.append(lab)
            head += code_lines
        head.append("start:")

        tail = []
        if expect is None:
            # probe epilogue: stash state where the driver can read it
            tail.append("    MTS   S4, r7")
            tail += ["    LDI16 r7, 0x600D",
                     "    LDI16 r0, 0x%04X" % RESULT,
                     "    ST   r7, [r0+0]",
                     "    HALT"]
        else:
            code = FAILBASE
            tail.append("    MTS   S4, r7")     # preserve r7 for its own check
            for k in range(1, 7):
                code += 1
                tail += self.check_reg("r%d" % k, expect["r"][k], code)
            code += 1
            tail += ["    MFS   r6, S4"] + self.check_reg("r6", expect["r7"], code)
            for sidx in (1, 5, 6):              # irq count, spills
                code += 1
                tail += ["    MFS   r6, S%d" % sidx] + \
                    self.check_reg("r6", expect["s"][sidx], code)
            for w in expect["probes"]:
                code += 1
                tail += ["    LDI16 r7, 0x%04X" % (WIN + 2 * w),
                         "    LD   r6, [r7+0]"] + \
                    self.check_reg("r6", expect["mem"][w], code)
            tail += ["    LDI16 r7, 0x600D",
                     "    LDI16 r6, 0x%04X" % RESULT,
                     "    ST   r7, [r6+0]",
                     "    HALT"]
        return "\n".join(head + body + tail) + "\n"

    def check_reg(self, reg, want, code):
        scratch = "r7" if reg != "r7" else "r6"
        return ["    LDI16 %s, 0x%04X" % (scratch, want),
                "    SUB   r0, %s, %s" % (reg, scratch),
                "    BEQZ  ok_%x" % code,
                "    LDI16 r7, 0x%04X" % code,
                "    LDI16 r6, 0x%04X" % RESULT,
                "    ST   r7, [r6+0]",
                "    HALT",
                "ok_%x:" % code]


class NanoGen:
    def __init__(self, seed, config):
        self.rng = random.Random(seed)
        self.seed = seed
        self.config = config
        self.label = 0

    def new_label(self, stem):
        self.label += 1
        return "%s_%d" % (stem, self.label)

    def reg(self):
        return "r%d" % self.rng.randint(1, 6)

    def op_alu(self):
        ops = ["ADD", "SUB", "SLTU", "AND", "OR", "XOR"]
        op = self.rng.choice(ops)
        return ["    %-5s %s, %s, %s" % (op, self.reg(), self.reg(), self.reg())]

    def op_imm(self):
        op = self.rng.choice(["LDI", "LUI", "ADDI", "ANDI", "ORI", "XORI"])
        v = self.rng.randint(-128, -1) if op == "ADDI" and self.rng.random() < 0.5 \
            else self.rng.randint(0, 127 if op == "ADDI" else 255)
        return ["    %-5s %s, %d" % (op, self.reg(), v)]

    def op_shift(self):
        if self.rng.random() < 0.75:
            op = self.rng.choice(["SRLI", "SRAI"])
            return ["    %-5s %s, %s, 1" % (op, self.reg(), self.reg())]
        return ["    SHL1  %s, %s" % (self.reg(), self.reg())]

    def op_mem(self):
        off = self.rng.randrange(0, WIN_WORDS) * 2
        lines = ["    LDI16 r7, 0x%04X" % WIN]
        k = self.rng.random()
        if k < 0.35:
            lines.append("    ST   %s, [r7+%d]" % (self.reg(), off))
        elif k < 0.70:
            lines.append("    LD   %s, [r7+%d]" % (self.reg(), off))
        elif k < 0.85:
            boff = self.rng.randrange(0, WIN_WORDS * 2)
            lines.append("    LDI   r0, %d" % boff)
            lines.append("    ADD   r0, r7, r0")
            lines.append("    LDB   %s, [r0]" % self.reg())
        else:
            boff = self.rng.randrange(0, WIN_WORDS * 2)
            lines.append("    LDI   r0, %d" % boff)
            lines.append("    ADD   r0, r7, r0")
            lines.append("    STB   %s, [r0]" % self.reg())
        return lines

    def simple_op(self, exclude=None):
        while True:
            k = self.rng.random()
            if k < 0.40:
                lines = self.op_alu()
            elif k < 0.70:
                lines = self.op_imm()
            elif k < 0.85:
                lines = self.op_shift()
            elif exclude == "r7":
                lines = self.op_alu()
            else:
                lines = self.op_mem()
            if exclude is None or not any((exclude + ",") in l or l.rstrip().endswith(exclude)
                                          for l in lines):
                return lines

    def op_branch_block(self):
        lab = self.new_label("fwd")
        cc = self.rng.choice(["BEQZ", "BNEZ", "BLTZ", "BGEZ"])
        lines = ["    LDI   r0, %d" % self.rng.randint(0, 127),
                 "    SUB   r0, %s, r0" % self.reg(),
                 "    %-5s %s" % (cc, lab)]
        for _ in range(self.rng.randint(1, 4)):
            lines += self.simple_op()
        lines.append("%s:" % lab)
        return lines

    def op_loop(self):
        lab = self.new_label("loop")
        cnt = "r%d" % self.rng.randint(1, 6)
        body = []
        for _ in range(self.rng.randint(1, 3)):
            body += self.simple_op(exclude=cnt)
        return (["    LDI   %s, %d" % (cnt, self.rng.randint(1, 5)),
                 "%s:" % lab] + body +
                ["    ADDI  %s, -1" % cnt,
                 "    MOV   r0, %s" % cnt,
                 "    BNEZ  %s" % lab])

    def op_call(self, subs):
        lab = self.new_label("nsub")
        body = []
        for _ in range(self.rng.randint(1, 3)):
            body += self.simple_op(exclude="r7")
        subs.append(("%s:" % lab, body + ["    JMP   r7"]))
        return ["    LDI16 r1, %s" % lab,
                "    JALR  r7, r1"]

    def body(self):
        subs = []
        lines = ["    LDI16 r7, 0x%04X" % WIN]
        for w in range(WIN_WORDS):
            lines.append("    LDI16 r1, 0x%04X" % self.rng.randint(0, 0xFFFF))
            lines.append("    ST   r1, [r7+%d]" % (w * 2))
        for _ in range(self.rng.randint(25, 45)):
            k = self.rng.random()
            if k < 0.48:
                lines += self.simple_op()
            elif k < 0.66:
                lines += self.op_mem()
            elif k < 0.80:
                lines += self.op_branch_block()
            elif k < 0.91:
                lines += self.op_loop()
            else:
                lines += self.op_call(subs)
        return lines, subs

    def save_regs(self):
        lines = ["    LDI16 r0, 0x%04X" % NANO_SCRATCH]
        for r in range(1, 8):
            lines.append("    ST   r%d, [r0+%d]" % (r, r * 2))
        return lines

    def check_word(self, load_lines, want, code):
        return load_lines + [
            "    LDI16 r3, 0x%04X" % want,
            "    SUB   r0, r2, r3",
            "    BEQZ  nok_%x" % code,
            "    LDI16 r7, 0x%04X" % code,
            "    LDI16 r6, 0x%04X" % RESULT,
            "    ST   r7, [r6+0]",
            "    HALT",
            "nok_%x:" % code,
        ]

    def emit(self, expect=None):
        head = [
            "; generated by riscc_fuzz.py seed=%d family=nano config=%s"
            % (self.seed, self.config),
            ".vectors",
            ".text",
            "reset_tramp:",
            "    LDI16 r0, start",
            "    JMP   r0",
            "fail:",
            "    LDI16 r7, 0x0BAD",
            "    LDI16 r6, 0x%04X" % RESULT,
            "    ST   r7, [r6+0]",
            "    HALT",
        ]
        self.rng = random.Random(self.seed)
        self.label = 0
        body, subs = self.body()
        for lab, code_lines in subs:
            head.append(lab)
            head += code_lines
        head.append("start:")

        tail = self.save_regs()
        if expect is None:
            tail += ["    LDI16 r7, 0x600D",
                     "    LDI16 r6, 0x%04X" % RESULT,
                     "    ST   r7, [r6+0]",
                     "    HALT"]
        else:
            code = FAILBASE
            for r in range(1, 8):
                code += 1
                tail += self.check_word([
                    "    LDI16 r5, 0x%04X" % NANO_SCRATCH,
                    "    LD   r2, [r5+%d]" % (r * 2),
                ], expect["r"][r], code)
            for w in expect["probes"]:
                code += 1
                tail += self.check_word([
                    "    LDI16 r5, 0x%04X" % (WIN + 2 * w),
                    "    LD   r2, [r5+0]",
                ], expect["mem"][w], code)
            tail += ["    LDI16 r7, 0x600D",
                     "    LDI16 r6, 0x%04X" % RESULT,
                     "    ST   r7, [r6+0]",
                     "    HALT"]
        return "\n".join(head + body + tail) + "\n"


class RC32Gen:
    """Seeded RC32 Min-subset programs with local literal pools.

    Every full-width constant goes through a nearby LDPC pool.  This keeps the
    programs valid independently of their random body length and continuously
    exercises the RC32-specific PC-relative load path.
    """

    def __init__(self, seed, config):
        self.rng = random.Random(seed)
        self.seed = seed
        self.config = config
        self.label = 0

    def new_label(self, stem):
        self.label += 1
        return ".%s_%d" % (stem, self.label)

    def reg(self):
        return "r%d" % self.rng.randint(1, 6)

    def literal(self, reg, value):
        literal = self.new_label("literal")
        after = self.new_label("after_literal")
        return [
            "    ldpc  %s, %s" % (reg, literal),
            "    jmp8  %s" % after,
            "    .balign 4",
            "%s:" % literal,
            "    .long %s" % value,
            "%s:" % after,
        ]

    def literal_value(self, reg, value):
        return self.literal(reg, "0x%08X" % (value & 0xffffffff))

    def op_alu(self):
        op = self.rng.choice(["add", "sub", "slt", "sltu", "and", "or", "xor"])
        return ["    %-5s %s, %s, %s" % (op, self.reg(), self.reg(), self.reg())]

    def op_imm(self):
        op = self.rng.choice(["ldi", "addi", "cmpi", "andi", "ori", "xori"])
        if op in ("addi", "cmpi"):
            value = self.rng.randint(-128, 127)
        else:
            value = self.rng.randint(0, 255)
        return ["    %-5s %s, %d" % (op, self.reg(), value)]

    def op_shift(self):
        op = self.rng.choice(["srli", "srai"])
        return ["    %-5s %s, %s, 1" % (op, self.reg(), self.reg())]

    def op_mem(self):
        kind = self.rng.randrange(6)
        offset = self.rng.randrange(RC32_WIN_WORDS) * 4
        lines = self.literal_value("r7", RC32_WIN)
        if kind == 0:
            lines.append("    st    %s, [r7 + %d]" % (self.reg(), offset))
        elif kind == 1:
            lines.append("    ld    %s, [r7 + %d]" % (self.reg(), offset))
        elif kind == 2:
            lines += self.literal_value("r0", self.rng.randrange(RC32_WIN_WORDS * 4))
            lines += ["    add   r0, r7, r0",
                      "    %s   %s, [r0]" % (self.rng.choice(["ldb", "ldbs"]), self.reg())]
        elif kind == 3:
            lines += self.literal_value("r0", self.rng.randrange(RC32_WIN_WORDS * 4))
            lines += ["    add   r0, r7, r0", "    stb   %s, [r0]" % self.reg()]
        elif kind == 4:
            lines += self.literal_value("r0", self.rng.randrange(RC32_WIN_WORDS * 2) * 2)
            lines += ["    add   r0, r7, r0",
                      "    %s   %s, [r0]" % (self.rng.choice(["ldh", "ldhs"]), self.reg())]
        else:
            lines += self.literal_value("r0", self.rng.randrange(RC32_WIN_WORDS * 2) * 2)
            lines += ["    add   r0, r7, r0", "    sth   %s, [r0]" % self.reg()]
        return lines

    def simple_op(self, exclude=None):
        while True:
            chance = self.rng.random()
            if chance < 0.40:
                lines = self.op_alu()
            elif chance < 0.70:
                lines = self.op_imm()
            elif chance < 0.80:
                lines = self.op_shift()
            else:
                lines = self.op_mem()
            if exclude is None or not any((exclude + ",") in line or
                                          line.rstrip().endswith(exclude)
                                          for line in lines):
                return lines

    def op_branch_block(self):
        target = self.new_label("branch")
        cc = self.rng.choice(["beqz", "bnez", "bltz", "bgez"])
        lines = ["    cmpi  %s, %d" % (self.reg(), self.rng.randint(-128, 127)),
                 "    %-5s %s" % (cc, target)]
        for _ in range(self.rng.randint(1, 3)):
            lines += self.simple_op()
        lines.append("%s:" % target)
        return lines

    def op_loop(self):
        target = self.new_label("loop")
        count = "r%d" % self.rng.randint(1, 6)
        body = []
        for _ in range(self.rng.randint(1, 2)):
            body += self.simple_op(exclude=count)
        return (["    ldi   %s, %d" % (count, self.rng.randint(1, 5)),
                 "%s:" % target] + body +
                ["    addi  %s, -1" % count,
                 "    or    r0, %s, %s" % (count, count),
                 "    bnez  %s" % target])

    def body(self):
        lines = self.literal_value("r7", RC32_WIN)
        for word in range(RC32_WIN_WORDS):
            lines += self.literal_value("r1", self.rng.getrandbits(32))
            lines.append("    st    r1, [r7 + %d]" % (word * 4))
        for _ in range(self.rng.randint(20, 32)):
            chance = self.rng.random()
            if chance < 0.55:
                lines += self.simple_op()
            elif chance < 0.76:
                lines += self.op_mem()
            elif chance < 0.90:
                lines += self.op_branch_block()
            else:
                lines += self.op_loop()

        sub = self.new_label("sub")
        literal = self.new_label("sub_literal")
        after = self.new_label("after_sub_literal")
        lines += [
            "    ldpc  r4, %s" % literal,
            "    jalr  s3, r4",
            "    jmp8  %s" % after,
            "    .balign 4",
            "%s:" % literal,
            "    .long %s" % sub,
            "%s:" % after,
            # The literal carries the subroutine's absolute address.  It
            # moves when the self-checking tail is appended, so do not retain
            # it as an architectural result to compare with the probe image.
            "    ldi   r4, 0",
        ]
        # Keep this body independent of the absolute target value held in
        # r4.  The probe and self-check image have different tail sizes, so
        # that pointer itself legitimately changes between the two links.
        sub_body = ["    add   r5, r5, r5", "    ret   s3"]
        return lines, (sub, sub_body)

    def store_result(self, value):
        return (self.literal_value("r7", value) +
                self.literal_value("r6", RESULT) +
                ["    sth   r7, [r6]", "    halt"])

    def check_reg(self, reg, value, code):
        ok = self.new_label("check_ok")
        return (self.literal_value("r7", value) +
                ["    sub   r0, %s, r7" % reg,
                 "    beqz  %s" % ok] +
                self.store_result(code) + ["%s:" % ok])

    def emit(self, expect=None):
        head = [
            "; generated by riscc_fuzz.py seed=%d family=rc32 config=%s" %
            (self.seed, self.config),
            ".text",
            ".globl start",
            "start:",
        ]
        self.rng = random.Random(self.seed)
        self.label = 0
        body, (sub, sub_body) = self.body()
        if expect is None:
            tail = ["    mts   s4, r6", "    mts   s5, r7"] + self.store_result(0x600D)
        else:
            tail = ["    mts   s4, r6", "    mts   s5, r7"]
            code = FAILBASE
            for index in range(1, 6):
                code += 1
                tail += self.check_reg("r%d" % index, expect["r"][index], code)
            for sreg in (3, 4, 5):
                code += 1
                tail += ["    mfs   r6, s%d" % sreg]
                tail += self.check_reg("r6", expect["s"][sreg], code)
            for word in expect["probes"]:
                code += 1
                tail += self.literal_value("r7", RC32_WIN + word * 4)
                tail += ["    ld    r6, [r7 + 0]"]
                tail += self.check_reg("r6", expect["mem"][word], code)
            tail += self.store_result(0x600D)
        return "\n".join(head + body + tail + ["%s:" % sub] + sub_body) + "\n"


def assemble(asm_path, bin_path, profile=None):
    cmd = [sys.executable, os.path.join(HERE, "riscc_asm.py")]
    if profile is not None:
        cmd += ["--profile", profile]
    cmd += [asm_path, "-o", bin_path]
    subprocess.run(cmd, check=True,
                   stdout=subprocess.DEVNULL)


def llvm_rc32_tools():
    bindir = os.environ.get("RISCC_LLVM_BIN",
                            os.path.join(ROOT, "build", "llvm-riscc", "bin"))
    tools = [os.path.join(bindir, name)
             for name in ("llvm-mc", "ld.lld", "llvm-objcopy")]
    if not all(os.path.isfile(tool) for tool in tools):
        raise RuntimeError("RC32 LLVM tools are missing; build them with make llvm-riscc "
                           "or set RISCC_LLVM_BIN")
    return tools


def assemble_rc32(asm_path, bin_path, config):
    mc, lld, objcopy = llvm_rc32_tools()
    obj_path = bin_path + ".o"
    elf_path = bin_path + ".elf"
    subprocess.run([mc, "-triple=riscc-none-elf", "-mcpu=" + config, "-mattr=+rc32",
                    "-filetype=obj", asm_path, "-o", obj_path], check=True,
                   stdout=subprocess.DEVNULL)
    subprocess.run([lld, "-m", "elf32lriscc", "-Ttext=0", "-e", "start",
                    "-o", elf_path, obj_path], check=True, stdout=subprocess.DEVNULL)
    subprocess.run([objcopy, "-O", "binary", elf_path, bin_path], check=True,
                   stdout=subprocess.DEVNULL)


def writable_or_creatable_dir(path):
    if not path:
        return False
    if os.path.isdir(path):
        return os.access(path, os.W_OK)
    parent = os.path.dirname(path) or "."
    return not os.path.exists(path) and os.access(parent, os.W_OK)


def ccache_usable(ccache):
    if os.environ.get("CCACHE_DIR") is not None:
        return True
    try:
        cache_dir = subprocess.run([ccache, "--get-config", "cache_dir"],
                                   check=True, capture_output=True,
                                   text=True).stdout.strip()
    except subprocess.SubprocessError:
        return False
    if writable_or_creatable_dir(cache_dir):
        return True

    fallback = os.environ.get("CCACHE_FALLBACK_DIR", "/tmp/riscc8-ccache")
    if writable_or_creatable_dir(fallback):
        os.environ["CCACHE_DIR"] = fallback
        return True
    return False


def verilator_makeflags():
    makeflags = os.environ.get("VERILATOR_MAKEFLAGS")
    if makeflags is not None:
        return makeflags

    opt_fast = os.environ.get("VERILATOR_OPT_FAST", "-O1")
    opt_global = os.environ.get("VERILATOR_OPT_GLOBAL", opt_fast)
    flags = ["OPT_FAST=%s" % opt_fast, "OPT_GLOBAL=%s" % opt_global]

    objcache = os.environ.get("OBJCACHE")
    if objcache is not None:
        if objcache:
            flags.append("OBJCACHE=%s" % objcache)
        return " ".join(flags)

    ccache = os.environ.get("CCACHE")
    if ccache and ccache_usable(ccache):
        flags.append("OBJCACHE=%s" % ccache)
        return " ".join(flags)

    ccache = shutil.which("ccache")
    if not ccache:
        return " ".join(flags)

    if ccache_usable(ccache):
        flags.append("OBJCACHE=%s" % ccache)
    return " ".join(flags)


def make_rc16_case(seed, config, outdir):
    cfg = parse_config(config)
    g = Gen(seed, config)
    stem = os.path.join(outdir, "fuzz_%s_%d" % (config, seed))
    with open(stem + "_probe.asm", "w") as f:
        f.write(g.emit(None))
    assemble(stem + "_probe.asm", stem + "_probe.bin", config)
    sim = rc16_state(stem + "_probe.bin", config)
    if sim["outcome"] != "DONE":
        raise RuntimeError("probe did not finish (seed %d)" % seed)
    rng = random.Random(seed ^ 0x5EED)
    expect = {
        "r": list(sim["r"]),
        "r7": sim["s"][4],                      # r7 was stashed in S4
        "s": list(sim["s"]),
        "mem": list(sim["mem"]),
        "probes": sorted(rng.sample(range(WIN_WORDS), 4)),
    }
    g2 = Gen(seed, config)
    with open(stem + ".asm", "w") as f:
        f.write(g2.emit(expect))
    assemble(stem + ".asm", stem + ".bin", config)
    chk = rc16_state(stem + ".bin", config, dump_window=False)
    if chk["outcome"] != "DONE" or chk["result"] != 0x600D:
        raise RuntimeError("self-check failed under ISS (seed %d, result 0x%04X)"
                           % (seed, chk["result"]))
    return stem + ".bin"


def make_nano_case(seed, config, outdir):
    g = NanoGen(seed, config)
    stem = os.path.join(outdir, "fuzz_nano_%s_%d" % (config, seed))
    with open(stem + "_probe.asm", "w") as f:
        f.write(g.emit(None))
    assemble(stem + "_probe.asm", stem + "_probe.bin", "nano")
    sim = nano_state(stem + "_probe.bin", config)
    if sim["outcome"] != "DONE":
        raise RuntimeError("nano probe did not finish (seed %d)" % seed)
    rng = random.Random(seed ^ 0x5EED)
    expect = {
        "r": list(sim["r"]),
        "mem": list(sim["mem"]),
        "probes": sorted(rng.sample(range(WIN_WORDS), 4)),
    }
    g2 = NanoGen(seed, config)
    with open(stem + ".asm", "w") as f:
        f.write(g2.emit(expect))
    assemble(stem + ".asm", stem + ".bin", "nano")
    chk = nano_state(stem + ".bin", config, dump_window=False)
    if chk["outcome"] != "DONE" or chk["result"] != 0x600D:
        raise RuntimeError("nano self-check failed under ISS (seed %d, result 0x%04X)"
                           % (seed, chk["result"]))
    return stem + ".bin"


def make_rc32_case(seed, config, outdir):
    stem = os.path.join(outdir, "fuzz_rc32_%s_%d" % (config, seed))
    generator = RC32Gen(seed, config)
    with open(stem + "_probe.s", "w") as source:
        source.write(generator.emit(None))
    assemble_rc32(stem + "_probe.s", stem + "_probe.bin", config)
    probe = rc32_state(stem + "_probe.bin", dump_window=True)
    if probe["outcome"] != "DONE" or probe["result"] != 0x600D:
        raise RuntimeError("RC32 probe did not finish (seed %d, result 0x%08X)" %
                           (seed, probe["result"]))
    rng = random.Random(seed ^ 0x5EED)
    expect = {
        "r": list(probe["r"]),
        "s": list(probe["s"]),
        "mem": list(probe["mem"]),
        "probes": sorted(rng.sample(range(RC32_WIN_WORDS), 4)),
    }
    checker = RC32Gen(seed, config)
    with open(stem + ".s", "w") as source:
        source.write(checker.emit(expect))
    assemble_rc32(stem + ".s", stem + ".bin", config)
    checked = rc32_state(stem + ".bin", dump_window=False)
    if checked["outcome"] != "DONE" or checked["result"] != 0x600D:
        raise RuntimeError("RC32 self-check failed under ISS (seed %d, result 0x%08X)" %
                           (seed, checked["result"]))
    return stem + ".bin"


def make_case(seed, family, config, outdir):
    if family == "nano":
        return make_nano_case(seed, config, outdir)
    if family == "rc32":
        return make_rc32_case(seed, config, outdir)
    return make_rc16_case(seed, config, outdir)


def shell_join(args):
    return " ".join(shlex.quote(str(a)) for a in args)


def replay_command(args, config, seed, core=None):
    cmd = [sys.argv[0], "--campaign", "1", "--base-seed", seed,
           "--family", args.family, "--config", config]
    if core:
        cmd += ["--cores", core]
    elif args.cores:
        cmd += ["--cores", args.cores]
    if args.outdir != os.path.join(ROOT, "build", "fuzz"):
        cmd += ["--outdir", args.outdir]
    return shell_join(cmd)


def trace_supported(family, core):
    return (family == "nano" and core == "nano") or (
        family == "rc16" and core in (
            "rc16-1", "rc16-2", "rc16-4", "rc16-8", "rc16-16")) or (
        family == "fast" and core in (
            "fast", "fast-dsp", "fast-ecp5", "fast-ecp5-dsp",
            "fast-block", "fast-block-dsp")) or (
        family == "rc32" and core in
        tuple("rc32-%d" % width for width in RC32_WIDTHS))


def fast_iss_path():
    env = os.environ.get("RISCC_SIM")
    if env:
        return env
    candidate = os.path.join(ROOT, "build", "tools", "riscc_sim")
    if os.path.exists(candidate):
        return candidate
    raise RuntimeError("C++ ISS not found; build it with make sim-cpp or set RISCC_SIM")


def sim_base_args(family, config, image, fast_iss):
    if family == "rc32":
        return [fast_iss, image, "--rc32"]
    if family == "nano":
        return [fast_iss, image, "--nano"]

    cfg = parse_config(config)
    args = [fast_iss, image]
    if not cfg["sys"]:
        args.append("--min")
    if cfg["full"]:
        args.append("--full")
    return args


def parse_fast_state(stdout, dump_base=None, dump_len=0):
    state = {}
    dumped = {}
    for line in stdout.splitlines():
        if line.startswith("STATE "):
            for item in line.split()[1:]:
                key, val = item.split("=", 1)
                if key == "insns":
                    state[key] = int(val, 0)
                elif key == "cycles":
                    state[key] = int(val, 0)
                elif key == "result":
                    state[key] = int(val, 0)
                else:
                    state[key] = val
        elif line.startswith("R "):
            state["r"] = [int(x, 0) for x in line.split()[1:]]
        elif line.startswith("S "):
            state["s"] = [int(x, 0) for x in line.split()[1:]]
        else:
            stripped = line.strip()
            if stripped.startswith("[0x"):
                parts = stripped.replace("[", "").replace("]", "").replace("=", "").split()
                if len(parts) == 2:
                    dumped[int(parts[0], 0) & 0x7fff] = int(parts[1], 0)
    if "outcome" not in state or "result" not in state:
        raise RuntimeError("C++ ISS did not print state")
    if dump_base is not None:
        state["mem"] = [dumped[(dump_base + i) & 0x7fff] for i in range(dump_len)]
    return state


def run_fast_state(family, config, image, max_insns=500000, dump_base=None, dump_len=0):
    fast_iss = fast_iss_path()
    args = sim_base_args(family, config, image, fast_iss)
    args += ["--max-insns", str(max_insns), "--state"]
    if dump_base is not None:
        args += ["--dump", "0x%04X" % dump_base, str(dump_len)]
    run = subprocess.run(args, capture_output=True, text=True)
    output = run.stdout + run.stderr
    state = parse_fast_state(output, dump_base, dump_len)
    state["returncode"] = run.returncode
    state["stdout"] = output
    state["stderr"] = run.stderr
    return state


def sim_trace_args(family, config, image):
    fast_iss = fast_iss_path()
    args = sim_base_args(family, config, image, fast_iss)
    args += ["--trace", "--dump-written"]
    return args


def rc16_state(image, config, dump_window=True):
    state = run_fast_state("rc16", config, image, dump_base=(WIN >> 1),
                           dump_len=WIN_WORDS) if dump_window else \
        run_fast_state("rc16", config, image)
    return state


def nano_state(image, config, dump_window=True):
    if dump_window:
        scratch_w = NANO_SCRATCH >> 1
        win_w = WIN >> 1
        dump_len = (win_w - scratch_w) + WIN_WORDS
        state = run_fast_state("nano", config, image, dump_base=scratch_w,
                               dump_len=dump_len)
        dumped = state["mem"]
        regs = [0] * 8
        for r in range(1, 8):
            regs[r] = dumped[r]
        state["r"] = regs
        state["mem"] = dumped[win_w - scratch_w:win_w - scratch_w + WIN_WORDS]
    else:
        state = run_fast_state("nano", config, image)
    return state


def rc32_state(image, dump_window=True):
    if not dump_window:
        return run_fast_state("rc32", "min", image)
    state = run_fast_state("rc32", "min", image, dump_base=(RC32_WIN >> 1),
                           dump_len=RC32_WIN_WORDS * 2)
    halves = state["mem"]
    state["mem"] = [halves[index * 2] | (halves[index * 2 + 1] << 16)
                    for index in range(RC32_WIN_WORDS)]
    return state


def trace_lines(output):
    return [line for line in output.splitlines() if line.startswith("TRACE ")]


def memory_lines(output):
    return [line for line in output.splitlines() if line.startswith("MEM ")]


def compare_trace(core, family, config, seed, image, tb):
    iss_run = subprocess.run(sim_trace_args(family, config, image),
                             capture_output=True, text=True)
    rtl_args = [tb, image, "--trace", "--dump-written",
                "--max-cycles", "400000"]
    if family in ("rc16", "rc32", "nano", "fast"):
        rtl_args += ["--mem-stall-seed", str(seed)]
    rtl_run = subprocess.run(rtl_args,
                             capture_output=True, text=True)
    iss_output = iss_run.stdout + iss_run.stderr
    iss_trace = trace_lines(iss_output)
    rtl_trace = trace_lines(rtl_run.stdout)
    iss_mem = memory_lines(iss_output)
    rtl_mem = memory_lines(rtl_run.stdout)

    if iss_run.returncode != 0:
        return False, "ISS trace failed", iss_output, rtl_run.stdout
    if rtl_run.returncode != 0:
        return False, "RTL trace failed", iss_output, rtl_run.stdout

    limit = min(len(iss_trace), len(rtl_trace))
    for idx in range(limit):
        if iss_trace[idx] != rtl_trace[idx]:
            msg = ("trace mismatch at step %d\n"
                   "  ISS: %s\n"
                   "  RTL: %s" % (idx, iss_trace[idx], rtl_trace[idx]))
            return False, msg, iss_output, rtl_run.stdout
    if len(iss_trace) != len(rtl_trace):
        msg = "trace length mismatch ISS=%d RTL=%d" % (len(iss_trace), len(rtl_trace))
        if limit < len(iss_trace):
            msg += "\n  next ISS: %s" % iss_trace[limit]
        if limit < len(rtl_trace):
            msg += "\n  next RTL: %s" % rtl_trace[limit]
        return False, msg, iss_output, rtl_run.stdout

    limit = min(len(iss_mem), len(rtl_mem))
    for idx in range(limit):
        if iss_mem[idx] != rtl_mem[idx]:
            msg = ("final memory mismatch at written word %d\n"
                   "  ISS: %s\n"
                   "  RTL: %s" % (idx, iss_mem[idx], rtl_mem[idx]))
            return False, msg, iss_output, rtl_run.stdout
    if len(iss_mem) != len(rtl_mem):
        msg = "written-memory length mismatch ISS=%d RTL=%d" % (len(iss_mem), len(rtl_mem))
        if limit < len(iss_mem):
            msg += "\n  next ISS: %s" % iss_mem[limit]
        if limit < len(rtl_mem):
            msg += "\n  next RTL: %s" % rtl_mem[limit]
        return False, msg, iss_output, rtl_run.stdout

    last = rtl_run.stdout.strip().splitlines()[-1] if rtl_run.stdout else "?"
    if "PASS" not in last:
        return False, "RTL self-check failed: %s" % last, iss_output, rtl_run.stdout
    return True, "PASS", iss_output, rtl_run.stdout


def build_tb(core, family, config, outdir):
    if not trace_supported(family, core):
        raise ValueError("trace compare does not support %s" % core)

    if family == "rc32":
        try:
            width = int(core.removeprefix("rc32-"))
        except ValueError as error:
            raise ValueError("invalid RC32 core name: %s" % core) from error
        if width not in RC32_WIDTHS:
            raise ValueError("unsupported RC32 datapath width: %d" % width)
        d = os.path.join(outdir, "v_trace_%s_%s" % (core, config))
        top = "riscc32_sys" if config == "sys" else "riscc32_min"
        rtl = os.path.join(RTL, "riscc32_sys.v" if config == "sys" else
                           "riscc32_min.v")
        defs = ["-GW=%d" % width]
    elif family == "nano":
        d = os.path.join(outdir, "v_trace_nano")
        top = "riscc_nano"
        rtl = os.path.join(RTL, "riscc_nano.v")
        defs = []
    elif family == "fast":
        d = os.path.join(outdir, "v_trace_%s" % core)
        top = "riscc16_fast"
        rtl = os.path.join(RTL, "riscc16_fast.v")
        defs = []
        if "dsp" in core:
            defs.append("-DRISCC_FAST_DSP")
        if "ecp5" in core:
            defs.append("-DRISCC_ECP5")
        if "block" in core:
            defs.append("-DRISCC_FAST_SYNC_RF")
    else:
        d = os.path.join(outdir, "v_trace_%s_%s" % (core, config))
        width = int(core.removeprefix("rc16-"))
        if width == 16 and config == "min":
            top = "riscc16_min"
            rtl = os.path.join(RTL, "riscc16_min.v")
            width_args = []
        elif width == 16:
            top = "riscc16"
            rtl = os.path.join(RTL, "riscc16_full.v" if config == "full" else "riscc16_sys.v")
            width_args = []
        elif config == "min":
            top = "riscc_min"
            rtl = os.path.join(RTL, "riscc_min.v")
            width_args = ["-GW=%d" % width]
        else:
            top = "riscc"
            rtl = os.path.join(RTL, "riscc_full.v" if config == "full" else "riscc_sys.v")
            width_args = ["-GW=%d" % width]
        defs = config_defs(config).split()
        defs += width_args
    defs.append("-DRISCC_TRACE")
    tb = os.path.join(d, "tb")
    trace_rtl = os.path.join(RTL, "test")
    newest_src = max(os.path.getmtime(rtl),
                     os.path.getmtime(__file__),
                     os.path.getmtime(os.path.join(trace_rtl, "riscc_trace_ports.vh")),
                     os.path.getmtime(os.path.join(trace_rtl, "riscc_trace_state.vh")),
                     os.path.getmtime(os.path.join(trace_rtl, "riscc_trace_ports32.vh")),
                     os.path.getmtime(os.path.join(trace_rtl, "riscc_trace_state32.vh")),
                     os.path.getmtime(os.path.join(TEST, "riscc_test.cpp")))
    if os.path.exists(tb) and os.path.getmtime(tb) > newest_src:
        return tb

    cmd = [os.environ.get("VERILATOR", "verilator"), "-cc", "--exe", "--build"]
    makeflags = verilator_makeflags()
    if makeflags:
        cmd += ["-MAKEFLAGS", makeflags]
    cmd += [
        "--top-module", top,
        "--prefix", "Vriscc",
        "-Mdir", d,
        "-I%s" % RTL,
        "-I%s" % trace_rtl,
    ] + defs + [
        "-CFLAGS", os.environ.get("TB_CXXFLAGS", "-std=c++17") +
        " -DRISCC_TB_TRACE" +
        (" -DRISCC_TB_MEM_HANDSHAKE"
         if family in ("rc16", "rc32", "fast") else "") +
        (" -DRISCC_TB_MEM_OE_N" if family == "nano" else "") +
        (" -DRISCC_TB_RC32" if family == "rc32" else "") +
        (" -DRISCC_TB_TRACE_DRAIN=1" if family == "fast" else
         " -DRISCC_TB_TRACE_DRAIN=0"
        if family == "rc16" and core == "rc16-16" else ""),
        "-o", "tb",
        rtl,
        os.path.join(TEST, "riscc_test.cpp"),
    ]
    subprocess.run(cmd, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return tb


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", action="version", version=f"riscc-fuzz {RISCC_VERSION}")
    ap.add_argument("--seed", type=int)
    ap.add_argument("--campaign", type=int, help="number of seeds per config")
    ap.add_argument("--base-seed", type=lambda x: int(x, 0),
                    help="first deterministic campaign seed")
    ap.add_argument("--random-seed", action="store_true",
                    help="choose and print a fresh random campaign base seed")
    ap.add_argument("--family", default="rc16", choices=["rc16", "nano", "fast", "rc32"])
    ap.add_argument("--config")
    ap.add_argument("--cores")
    ap.add_argument("--outdir", default=os.path.join(ROOT, "build", "fuzz"))
    args = ap.parse_args()
    os.makedirs(args.outdir, exist_ok=True)

    valid_configs = (NANO_CONFIGS if args.family == "nano" else
                     RC32_CONFIGS if args.family == "rc32" else
                     ("full",) if args.family == "fast" else RC16_CONFIGS)
    if args.config is not None and args.config not in valid_configs:
        ap.error("--config must be one of: %s" % ", ".join(valid_configs))
    if args.random_seed and args.base_seed is not None:
        ap.error("--random-seed and --base-seed are mutually exclusive")

    if args.campaign is None:
        if args.seed is None:
            ap.error("need --seed or --campaign")
        if args.config is None:
            ap.error("--seed mode needs --config")
        b = make_case(args.seed, args.family, args.config, args.outdir)
        print("OK (ISS self-check): %s" % b)
        return

    cores = args.cores.split(",") if args.cores else (
        ["nano"] if args.family == "nano" else
        ["rc32-%d" % width for width in RC32_WIDTHS]
        if args.family == "rc32" else
        ["fast", "fast-dsp"] if args.family == "fast" else
        ["rc16-1", "rc16-2", "rc16-4", "rc16-8", "rc16-16"])
    configs = [args.config] if args.config else valid_configs
    base_seed = (args.base_seed if args.base_seed is not None
                 else random.SystemRandom().randrange(0, 1 << 31))
    print("campaign seeds: base=%d count=%d" % (base_seed, args.campaign))
    fails = 0
    total = 0
    first_failure = None
    for config in configs:
        bins = []
        for seed_idx in range(args.campaign):
            seed = base_seed + seed_idx
            try:
                bins.append((seed, make_case(seed, args.family, config, args.outdir)))
            except Exception as e:
                print("GENFAIL %s/%s seed=%d: %s" %
                      (args.family, config, seed, e))
                print("replay: %s" % replay_command(args, config, seed))
                sys.exit(1)
        for core in cores:
            tb = build_tb(core, args.family, config, args.outdir)
            for seed, b in bins:
                total += 1
                ok, detail, _, _ = compare_trace(core, args.family, config, seed, b, tb)
                if not ok:
                    fails += 1
                    print("TRACE-DIVERGE %s %s/%s seed=%d: %s\n%s"
                          % (core, args.family, config, seed,
                             os.path.basename(b), detail))
                    if first_failure is None:
                        first_failure = (core, config, seed)
                        print("replay: %s" %
                              replay_command(args, config, seed, core))
        print("config %s/%s done" % (args.family, config))
    print("campaign: %d runs, %d divergences" % (total, fails))
    if first_failure is not None:
        core, config, seed = first_failure
        print("first failing seed: family=%s config=%s core=%s seed=%d"
              % (args.family, config, core, seed))
        print("replay first failure: %s" %
              replay_command(args, config, seed, core))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()

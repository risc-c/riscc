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

Program shape (per seed): a deterministic block that executes every operation
implemented by the selected profile, followed by random straight-line
ALU/imm/memory ops over r1..r6 with a high-RAM data window, forward-branch
blocks, bounded counted loops, and explicit-link subroutines. Sys configurations
also vary STI/CLI around the random blocks.  After the normal differential run,
each RTL core reruns the image with IRQ asserted externally at a seeded random
cycle before an end-of-body marker.  Vector layout follows the exception model:
reset enters at word 0 and IRQ at word 2; Min and Nano images have no vector
table.

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
import concurrent.futures
import os
import random
import re
import shlex
import shutil
import subprocess
import sys
import zlib

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
IRQ_MARKER = 0x7EF0       # end of externally interruptible fuzz body
FAILBASE = 0x0B00         # fail codes 0x0B01.. per checked item

NANO_CONFIGS = ("nano",)
RC32_CONFIGS = ("min", "sys", "full")
RC32_WIDTHS = (1, 2, 4, 8, 16)
RC16_CONFIGS = ("min", "sys", "full", "full-mulh", "full-muldiv")


def available_cpu_count():
    if hasattr(os, "sched_getaffinity"):
        return len(os.sched_getaffinity(0))
    return os.cpu_count() or 1


def parse_config(config):
    if config not in RC16_CONFIGS:
        raise ValueError("unknown config: %s" % config)
    profile, _, extension = config.partition("-")
    return {
        "profile": profile,
        "sys": profile != "min",
        "shifts": profile == "full",
        "long_calls": profile in ("sys", "full"),
        "full": profile == "full",
        "mulhu": extension in ("mulh", "muldiv"),
        "divu": extension == "muldiv",
        "mdu": bool(extension),
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
        self.mulhu = cfg["mulhu"]
        self.divu = cfg["divu"]
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

    def op_mdu(self):
        if self.divu and self.rng.random() < 0.5:
            rr, rq, rb = self.rng.sample(range(1, 7), 3)
            divisor = self.rng.randint(1, 0xffff)
            remainder = self.rng.randrange(divisor)
            quotient = self.rng.randint(0, 0xffff)
            return [
                "    LDI16 r%d, 0x%04X" % (rr, remainder),
                "    LDI16 r%d, 0x%04X" % (rq, quotient),
                "    LDI16 r%d, 0x%04X" % (rb, divisor),
                "    DIVU  r%d, r%d, r%d" % (rr, rq, rb),
            ]
        low, high = self.rng.sample(range(1, 7), 2)
        source = self.rng.randint(1, 6)
        high_value = self.rng.randint(0, 0xffff)
        source_value = self.rng.randint(0, 0xffff)
        lines = ["    LDI16 r%d, 0x%04X" % (high, high_value)]
        if source != high:
            lines.append("    LDI16 r%d, 0x%04X" % (source, source_value))
        lines.append("    MULHU r%d, r%d, r%d" % (low, high, source))
        return lines

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

    def op_ie_window(self):
        """Vary interrupt masking without generating an IRQ in-band."""
        return ["    CLI"] + self.simple_op() + ["    STI"]

    def supported_isa_ops(self):
        """Execute every instruction implemented by this RC16 configuration."""
        beq = self.new_label("cover_beq")
        bne = self.new_label("cover_bne")
        blt = self.new_label("cover_blt")
        bge = self.new_label("cover_bge")
        after_jmp = self.new_label("cover_after_jmp")
        reg_sub = self.new_label("cover_reg_sub")
        reg_done = self.new_label("cover_reg_done")
        lines = [
            "    LDI16 r7, 0x%04X" % WIN,
            "    LDI16 r1, 0x80A5",
            "    ST    r1, [r7+0]",
            "    LD    r2, [r7+0]",
            "    LDI   r3, 0",
            "    LDX   r2, [r7+r3]",
            "    LDB   r2, [r7]",
            "    LDBS  r2, [r7]",
            "    STB   r1, [r7]",
            "    LDI   r1, 0x12",
            "    LUI   r2, 0x34",
            "    ADDI  r1, -1",
            "    CMPI  r1, 0x11",
            "    ANDI  r2, 0x7F",
            "    ORI   r2, 0x40",
            "    XORI  r2, 0x55",
            "    ADD   r3, r1, r2",
            "    SUB   r3, r3, r1",
            "    SLT   r4, r1, r2",
            "    SLTU  r4, r1, r2",
            "    AND   r4, r1, r2",
            "    OR    r4, r1, r2",
            "    XOR   r4, r1, r2",
            "    SRLI  r4, r2, 1",
            "    SRAI  r4, r2, 1",
            "    FSL1  r4, r1",
            "    FSR1  r4, r1",
            "    LDI   r0, 0",
            "    BEQZ  %s" % beq,
            "%s:" % beq,
            "    BNEZ  %s" % bne,
            "%s:" % bne,
            "    ADDI  r0, -1",
            "    BLTZ  %s" % blt,
            "%s:" % blt,
            "    BGEZ  %s" % bge,
            "%s:" % bge,
            "    JMP8  %s" % after_jmp,
            "    LDI   r6, 0x5A",
            "%s:" % after_jmp,
            "    MTS   S5, r1",
            "    MFS   r2, S5",
            "    LDI16 r3, %s" % reg_sub,
            "    JALR  S4, r3",
            "    JMP8  %s" % reg_done,
            "%s:" % reg_sub,
            "    RET   S4",
            "%s:" % reg_done,
        ]
        if self.full:
            lines += [
                "    SLLI  r4, r2, 4",
                "    SRLI  r4, r2, 4",
                "    SRAI  r4, r2, 4",
                "    MUL   r4, r1, r2",
            ]
        if self.mulhu:
            lines += [
                "    LDI16 r3, 0x1234",
                "    LDI16 r4, 0x4321",
                "    MULHU r5, r3, r4",
            ]
        if self.divu:
            lines += [
                "    LDI   r3, 1",
                "    LDI16 r4, 0x2345",
                "    LDI16 r5, 0x0123",
                "    DIVU  r3, r4, r5",
            ]
        if self.sys:
            long_sub = self.new_label("cover_long_sub")
            long_done = self.new_label("cover_long_done")
            after_reti = self.new_label("cover_after_reti")
            lines += [
                "    JALL  S6, %s" % long_sub,
                "    JMPL  %s" % long_done,
                "%s:" % long_sub,
                "    RET   S6",
                "%s:" % long_done,
                "    CLI",
                "    LDI16 r3, %s" % after_reti,
                "    MTS   S0, r3",
                "    RETI  S0",
                "%s:" % after_reti,
                "    STI",
            ]
        return lines

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
                lines = self.op_mdu() if self.mulhu and self.rng.random() < 0.5 \
                    else self.op_mul()
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
        lines += self.supported_isa_ops()
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
                lines += self.op_ie_window()
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
                "irq_h:",                       # preserve, ack, resume
                "    MTS   S2, r1",
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
        if self.sys:
            head.append("    STI")

        if self.sys:
            body += [
                "    LDI16 r7, 0x%04X" % IRQ_MARKER,
                "    ST    r7, [r7+0]",
            ]

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

    def supported_isa_ops(self):
        """Execute every instruction implemented by Nano."""
        beq = self.new_label("cover_beq")
        bne = self.new_label("cover_bne")
        blt = self.new_label("cover_blt")
        bge = self.new_label("cover_bge")
        after_jmp = self.new_label("cover_after_jmp")
        sub = self.new_label("cover_sub")
        done = self.new_label("cover_done")
        return [
            "    LDI16 r7, 0x%04X" % WIN,
            "    LDI16 r1, 0x80A5",
            "    ST    r1, [r7+0]",
            "    LD    r2, [r7+0]",
            "    LDI   r3, 0",
            "    LDX   r2, [r7+r3]",
            "    LDB   r2, [r7]",
            "    STB   r1, [r7]",
            "    LDI   r1, 0x12",
            "    LUI   r2, 0x34",
            "    ADDI  r1, -1",
            "    ANDI  r2, 0x7F",
            "    ORI   r2, 0x40",
            "    XORI  r2, 0x55",
            "    ADD   r3, r1, r2",
            "    SUB   r3, r3, r1",
            "    SLTU  r4, r1, r2",
            "    AND   r4, r1, r2",
            "    OR    r4, r1, r2",
            "    XOR   r4, r1, r2",
            "    SRLI  r4, r2, 1",
            "    SRAI  r4, r2, 1",
            "    LDI   r0, 0",
            "    BEQZ  %s" % beq,
            "%s:" % beq,
            "    BNEZ  %s" % bne,
            "%s:" % bne,
            "    ADDI  r0, -1",
            "    BLTZ  %s" % blt,
            "%s:" % blt,
            "    BGEZ  %s" % bge,
            "%s:" % bge,
            "    JMP8  %s" % after_jmp,
            "    LDI   r6, 0x5A",
            "%s:" % after_jmp,
            "    LDI16 r1, %s" % sub,
            "    JALR  r7, r1",
            "    JMP8  %s" % done,
            "%s:" % sub,
            "    JMP   r7",
            "%s:" % done,
        ]

    def body(self):
        subs = []
        lines = ["    LDI16 r7, 0x%04X" % WIN]
        for w in range(WIN_WORDS):
            lines.append("    LDI16 r1, 0x%04X" % self.rng.randint(0, 0xFFFF))
            lines.append("    ST   r1, [r7+%d]" % (w * 2))
        lines += self.supported_isa_ops()
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
    """Seeded RC32 programs with local literal pools.

    Every full-width constant goes through a nearby LDPC pool.  This keeps the
    programs valid independently of their random body length and continuously
    exercises the RC32-specific PC-relative load path.
    """

    def __init__(self, seed, config):
        self.rng = random.Random(seed)
        self.seed = seed
        self.config = config
        self.sys = config != "min"
        self.full = config == "full"
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
        ops = ["add", "sub", "slt", "sltu", "and", "or", "xor"]
        if self.full:
            ops.append("mul")
        op = self.rng.choice(ops)
        return ["    %-5s %s, %s, %s" % (op, self.reg(), self.reg(), self.reg())]

    def op_imm(self):
        op = self.rng.choice(["ldi", "addi", "cmpi", "andi", "ori", "xori"])
        if op in ("addi", "cmpi"):
            value = self.rng.randint(-128, 127)
        else:
            value = self.rng.randint(0, 255)
        return ["    %-5s %s, %d" % (op, self.reg(), value)]

    def op_shift(self):
        ops = ["srli", "srai"]
        if self.full:
            ops.append("slli")
        op = self.rng.choice(ops)
        amount = self.rng.randint(1, 8) if self.full else 1
        return ["    %-5s %s, %s, %d" %
                (op, self.reg(), self.reg(), amount)]

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

    def op_ie_window(self):
        """Vary interrupt masking without generating an IRQ in-band."""
        return ["    cli"] + self.simple_op() + ["    sti"]

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

    def supported_isa_ops(self):
        """Deterministically execute every operation in this RC32 profile.

        Random bodies remain useful for operand and ordering coverage, but a
        fixed regression seed must not decide whether an instruction is
        exercised at all.  Keep this block side-effect-safe: the probe and
        self-checking images deliberately append different tails.
        """
        beq = self.new_label("cover_beq")
        bne = self.new_label("cover_bne")
        blt = self.new_label("cover_blt")
        bge = self.new_label("cover_bge")
        after_jmp = self.new_label("cover_after_jmp")
        jump_literal = self.new_label("cover_jump_literal")
        lines = [
            "    ldi   r1, 0x12",
            "    ldi   r2, 0x34",
            "    addi  r1, -1",
            "    cmpi  r1, 0x11",
            "    andi  r2, 0xf0",
            "    ori   r2, 3",
            "    xori  r2, 0x55",
            "    add   r3, r1, r2",
            "    sub   r3, r3, r1",
            "    slt   r4, r1, r2",
            "    sltu  r4, r1, r2",
            "    and   r4, r1, r2",
            "    or    r4, r1, r2",
            "    xor   r4, r1, r2",
            "    srli  r4, r2, 1",
            "    srai  r4, r2, 1",
            "    fsl1  r4, r1",
            "    fsr1  r4, r1",
            "    ldi   r5, 0",
            "    st    r1, [r7]",
            "    ld    r3, [r7]",
            "    ldx   r3, [r7 + r5]",
            "    ldb   r3, [r7]",
            "    ldbs  r3, [r7]",
            "    ldh   r3, [r7]",
            "    ldhs  r3, [r7]",
            "    stb   r3, [r7]",
            "    sth   r3, [r7]",
            "    mts   s5, r3",
            "    mfs   r3, s5",
            "    or    r0, r5, r5",
            "    beqz  %s" % beq,
            "%s:" % beq,
            "    bnez  %s" % bne,
            "%s:" % bne,
            "    addi  r0, -1",
            "    bltz  %s" % blt,
            "%s:" % blt,
            "    bgez  %s" % bge,
            "%s:" % bge,
            "    ldpc  r4, %s" % jump_literal,
            "    jmp   r4",
            "    .balign 4",
            "%s:" % jump_literal,
            "    .long %s" % after_jmp,
            "%s:" % after_jmp,
        ]
        if self.sys:
            long_sub = self.new_label("cover_long_sub")
            long_done = self.new_label("cover_long_done")
            after_reti = self.new_label("cover_after_reti")
            lines += [
                "    jall  s4, %s" % long_sub,
                "    jmpl  %s" % long_done,
                "%s:" % long_sub,
                "    ret   s4",
                "%s:" % long_done,
                "    cli",
            ] + self.literal("r3", after_reti) + [
                "    mts   s0, r3",
                "    reti  s0",
                "%s:" % after_reti,
                "    sti",
            ]
        if self.full:
            for amount in range(1, 9):
                lines += [
                    "    slli  r4, r2, %d" % amount,
                    "    srli  r4, r2, %d" % amount,
                    "    srai  r4, r2, %d" % amount,
                ]
            lines.append("    mul   r4, r1, r2")
        return lines

    def body(self):
        lines = self.literal_value("r7", RC32_WIN)
        for word in range(RC32_WIN_WORDS):
            lines += self.literal_value("r1", self.rng.getrandbits(32))
            lines.append("    st    r1, [r7 + %d]" % (word * 4))
        lines += self.supported_isa_ops()
        for _ in range(self.rng.randint(20, 32)):
            chance = self.rng.random()
            if chance < 0.55:
                lines += self.simple_op()
            elif chance < 0.76:
                lines += self.op_mem()
            elif chance < 0.90:
                lines += self.op_branch_block()
            elif self.sys and chance < 0.95:
                lines += self.op_ie_window()
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
        self.rng = random.Random(self.seed)
        self.label = 0
        head = [
            "; generated by riscc_fuzz.py seed=%d family=rc32 config=%s" %
            (self.seed, self.config),
            ".text",
            ".globl start",
        ]
        if self.sys:
            # RC32 Sys resets at byte 0 and vectors IRQs through byte 4.
            # Keep both vectors and the handler in .text so -Ttext=0 fixes
            # their exact locations without a fuzzer-specific linker script.
            head += [
                "    jall  s7, start",
                "    jmpl  .irq_handler",
                ".irq_handler:",
                "    mts   s1, r0",
                "    mts   s2, r1",
            ] + self.literal_value("r1", TEST_IRQ) + [
                "    ldh   r0, [r1]",
                "    mfs   r1, s2",
                "    mfs   r0, s1",
                "    reti  s0",
            ]
        head += ["start:"]
        if self.sys:
            head += ["    ldi   r0, 0", "    mts   s6, r0", "    sti"]
        body, (sub, sub_body) = self.body()
        if self.sys:
            body += self.literal_value("r7", IRQ_MARKER)
            body += ["    sth   r7, [r7]"]
        if expect is None:
            tail = ["    mts   s4, r6", "    mts   s5, r7"] + self.store_result(0x600D)
        else:
            tail = ["    mts   s4, r6", "    mts   s5, r7"]
            code = FAILBASE
            for index in range(1, 6):
                code += 1
                tail += self.check_reg("r%d" % index, expect["r"][index], code)
            checked_sregs = (3, 4, 5, 6) if self.sys else (3, 4, 5)
            for sreg in checked_sregs:
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


def assemble(asm_path, bin_path, profile=None, mdu=False):
    cmd = [sys.executable, os.path.join(HERE, "riscc_asm.py")]
    if profile is not None:
        cmd += ["--profile", profile]
    if mdu:
        cmd.append("--mdu")
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
    subprocess.run([mc, "-triple=riscc-none-elf", "-mcpu=" + config,
                    "-mattr=+rc32",
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
    assemble(stem + "_probe.asm", stem + "_probe.bin", cfg["profile"], cfg["mdu"])
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
    assemble(stem + ".asm", stem + ".bin", cfg["profile"], cfg["mdu"])
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
    probe = rc32_state(stem + "_probe.bin", config, dump_window=True)
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
    checked = rc32_state(stem + ".bin", config, dump_window=False)
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
    cmd = [sys.executable, sys.argv[0],
           "--campaign", "1", "--base-seed", seed,
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
            "rc16-1", "rc16-2", "rc16-4", "rc16-8", "rc16-16",
            "rc16-mulh", "rc16-muldiv")) or (
        family == "fast" and core in (
            "fast", "fast-dsp", "fast-ecp5", "fast-ecp5-dsp",
            "fast-block", "fast-block-dsp", "fast-agilex",
            "fast-agilex-dsp")) or (
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
        rc32_flag = ("--rc32" if config == "min" else
                     "--rc32-sys" if config == "sys" else
                     "--rc32-full")
        args = [fast_iss, image, rc32_flag]
        if "-" in config:
            args.append("--mdu")
        return args
    if family == "nano":
        return [fast_iss, image, "--nano"]

    cfg = parse_config(config)
    args = [fast_iss, image]
    if not cfg["sys"]:
        args.append("--min")
    if cfg["full"]:
        args.append("--full")
    if cfg["mdu"]:
        args.append("--mdu")
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


def rc32_state(image, config, dump_window=True):
    if not dump_window:
        return run_fast_state("rc32", config, image)
    state = run_fast_state("rc32", config, image, dump_base=(RC32_WIN >> 1),
                           dump_len=RC32_WIN_WORDS * 2)
    halves = state["mem"]
    state["mem"] = [halves[index * 2] | (halves[index * 2 + 1] << 16)
                    for index in range(RC32_WIN_WORDS)]
    return state


def trace_lines(output):
    return [line for line in output.splitlines() if line.startswith("TRACE ")]


def memory_lines(output):
    return [line for line in output.splitlines() if line.startswith("MEM ")]


def interrupt_supported(family, config):
    if family == "rc32":
        return config != "min"
    if family in ("rc16", "fast", "faster"):
        return parse_config(config)["sys"]
    return False


MARKER_RE = re.compile(r"MARKER cycle=(\d+)")


def compare_trace(core, family, config, seed, image, tb):
    iss_run = subprocess.run(sim_trace_args(family, config, image),
                             capture_output=True, text=True)
    rtl_args = [tb, image, "--trace", "--dump-written",
                "--max-cycles", "400000"]
    irq_cycle = None
    if interrupt_supported(family, config):
        rtl_args += ["--report-write", "0x%04X" % IRQ_MARKER]
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

    if interrupt_supported(family, config):
        marker = MARKER_RE.search(rtl_run.stdout)
        if marker is None:
            return False, "RTL did not report the IRQ body marker", \
                iss_output, rtl_run.stdout
        marker_cycle = int(marker.group(1))
        low_cycle = max(5, marker_cycle // 20)
        high_cycle = marker_cycle - 1
        if high_cycle < low_cycle:
            return False, "IRQ body marker is too early at cycle %d" % marker_cycle, \
                iss_output, rtl_run.stdout

        core_tag = zlib.crc32(core.encode("utf-8"))
        irq_rng = random.Random(seed ^ core_tag ^ 0x1A2B3C4D)
        irq_cycle = irq_rng.randint(low_cycle, high_cycle)
        irq_args = [tb, image, "--dump-written", "--max-cycles", "400000",
                    "--irq-at", str(irq_cycle)]
        if family in ("rc16", "rc32", "nano", "fast"):
            irq_args += ["--mem-stall-seed", str(seed)]
        irq_run = subprocess.run(irq_args, capture_output=True, text=True)
        if irq_run.returncode != 0:
            return False, "external IRQ failed at cycle %d" % irq_cycle, \
                iss_output, irq_run.stdout + irq_run.stderr

        irq_mem = memory_lines(irq_run.stdout)
        if irq_mem != iss_mem:
            limit = min(len(iss_mem), len(irq_mem))
            mismatch = next((index for index in range(limit)
                             if iss_mem[index] != irq_mem[index]), limit)
            detail = "external IRQ final memory mismatch at cycle %d" % irq_cycle
            if mismatch < limit:
                detail += ("\n  ISS: %s\n  RTL: %s" %
                           (iss_mem[mismatch], irq_mem[mismatch]))
            else:
                detail += " (ISS=%d words RTL=%d words)" % (len(iss_mem), len(irq_mem))
            return False, detail, iss_output, irq_run.stdout
    detail = ("PASS external IRQ at cycle %d" % irq_cycle
              if irq_cycle is not None else "PASS")
    return True, detail, iss_output, rtl_run.stdout


def compare_final_state(core, family, config, seed, image, tb):
    """Compare self-checked final state when a core has no retirement trace."""
    iss_args = sim_base_args(family, config, image, fast_iss_path())
    iss_args += ["--dump-written"]
    iss_run = subprocess.run(iss_args, capture_output=True, text=True)
    rtl_args = [tb, image, "--dump-written", "--max-cycles", "400000",
                "--mem-stall-seed", str(seed)]
    if interrupt_supported(family, config):
        rtl_args += ["--report-write", "0x%04X" % IRQ_MARKER]
    rtl_run = subprocess.run(rtl_args, capture_output=True, text=True)
    iss_output = iss_run.stdout + iss_run.stderr
    iss_mem = memory_lines(iss_output)
    rtl_mem = memory_lines(rtl_run.stdout)

    if iss_run.returncode != 0:
        return False, "ISS final-state run failed", iss_output, rtl_run.stdout
    if rtl_run.returncode != 0:
        return False, "RTL final-state run failed", iss_output, rtl_run.stdout
    if iss_mem != rtl_mem:
        limit = min(len(iss_mem), len(rtl_mem))
        mismatch = next((index for index in range(limit)
                         if iss_mem[index] != rtl_mem[index]), limit)
        detail = "final memory mismatch"
        if mismatch < limit:
            detail += "\n  ISS: %s\n  RTL: %s" % (
                iss_mem[mismatch], rtl_mem[mismatch])
        else:
            detail += " (ISS=%d words RTL=%d words)" % (
                len(iss_mem), len(rtl_mem))
        return False, detail, iss_output, rtl_run.stdout

    last = rtl_run.stdout.strip().splitlines()[-1] if rtl_run.stdout else "?"
    if "PASS" not in last:
        return False, "RTL self-check failed: %s" % last, \
            iss_output, rtl_run.stdout

    irq_cycle = None
    if interrupt_supported(family, config):
        marker = MARKER_RE.search(rtl_run.stdout)
        if marker is None:
            return False, "RTL did not report the IRQ body marker", \
                iss_output, rtl_run.stdout
        marker_cycle = int(marker.group(1))
        low_cycle = max(5, marker_cycle // 20)
        if marker_cycle - 1 < low_cycle:
            return False, "IRQ body marker is too early at cycle %d" % marker_cycle, \
                iss_output, rtl_run.stdout
        core_tag = zlib.crc32(core.encode("utf-8"))
        irq_rng = random.Random(seed ^ core_tag ^ 0x1A2B3C4D)
        irq_cycle = irq_rng.randint(low_cycle, marker_cycle - 1)
        irq_args = [tb, image, "--dump-written", "--max-cycles", "400000",
                    "--irq-at", str(irq_cycle),
                    "--mem-stall-seed", str(seed)]
        irq_run = subprocess.run(irq_args, capture_output=True, text=True)
        if irq_run.returncode != 0:
            return False, "external IRQ failed at cycle %d" % irq_cycle, \
                iss_output, irq_run.stdout + irq_run.stderr
        irq_mem = memory_lines(irq_run.stdout)
        if irq_mem != iss_mem:
            return False, "external IRQ final memory mismatch at cycle %d" % \
                irq_cycle, iss_output, irq_run.stdout

    detail = ("PASS external IRQ at cycle %d" % irq_cycle
              if irq_cycle is not None else "PASS")
    return True, detail, iss_output, rtl_run.stdout


def build_tb(core, family, config, outdir):
    if family != "faster" and not trace_supported(family, core):
        raise ValueError("trace compare does not support %s" % core)

    if family == "rc32":
        try:
            width = int(core.removeprefix("rc32-"))
        except ValueError as error:
            raise ValueError("invalid RC32 core name: %s" % core) from error
        if width not in RC32_WIDTHS:
            raise ValueError("unsupported RC32 datapath width: %d" % width)
        d = os.path.join(outdir, "v_trace_%s_%s" % (core, config))
        suffix = config.replace("-", "_")
        top = "riscc32_" + suffix
        rtl = os.path.join(RTL, "riscc32_" + suffix + ".v")
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
        if "agilex" in core:
            defs.append("-DRISCC_FAST_AGILEX")
    elif family == "faster":
        if core not in ("faster", "faster-dsp"):
            raise ValueError("invalid Faster core name: %s" % core)
        d = os.path.join(outdir, "v_state_%s" % core)
        top = "riscc16_faster"
        rtl = os.path.join(RTL, "riscc16_faster.v")
        defs = ["-DRISCC_FASTER_BLOCK_RF"]
        if core == "faster":
            defs.append("-DRISCC_FASTER_SOFT_MUL")
    else:
        d = os.path.join(outdir, "v_trace_%s_%s" % (core, config))
        if core in ("rc16-mulh", "rc16-muldiv"):
            required = "full-" + core.removeprefix("rc16-")
            if config != required:
                raise ValueError("%s requires --config %s" % (core, required))
            top = "riscc16"
            rtl = os.path.join(
                RTL, "riscc16_full_%s.v" % core.removeprefix("rc16-"))
            width_args = []
        else:
            width = int(core.removeprefix("rc16-"))
            if parse_config(config)["mdu"]:
                raise ValueError("%s requires an MDU core" % config)
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
    with_trace = family != "faster"
    if with_trace:
        defs.append("-DRISCC_TRACE")
    tb = os.path.join(d, "tb")
    trace_rtl = os.path.join(RTL, "test")
    rtl_dependencies = [rtl]
    newest_src = max(*(os.path.getmtime(path) for path in rtl_dependencies),
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
        (" -DRISCC_TB_TRACE" if with_trace else "") +
        (" -DRISCC_TB_MEM_HANDSHAKE"
         if family in ("rc16", "rc32", "fast", "faster") else "") +
        (" -DRISCC_TB_MEM_OE_N" if family == "nano" else "") +
        (" -DRISCC_TB_RC32" if family == "rc32" else "") +
        (" -DRISCC_TB_TRACE_DRAIN=1" if family == "fast" else
         " -DRISCC_TB_TRACE_DRAIN=0"
        if family == "rc16" and core in
        ("rc16-16", "rc16-mulh", "rc16-muldiv") else ""),
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
    ap.add_argument("--family", default="rc16",
                    choices=["rc16", "nano", "fast", "faster", "rc32"])
    ap.add_argument("--config")
    ap.add_argument("--cores")
    ap.add_argument("-j", "--jobs", type=int, default=available_cpu_count(),
                    help="parallel generator/simulator jobs (default: all CPUs)")
    ap.add_argument("--outdir", default=os.path.join(ROOT, "build", "fuzz"))
    args = ap.parse_args()
    os.makedirs(args.outdir, exist_ok=True)

    valid_configs = (NANO_CONFIGS if args.family == "nano" else
                     RC32_CONFIGS if args.family == "rc32" else
                     ("full",) if args.family in ("fast", "faster") else
                     RC16_CONFIGS)
    if args.config is not None and args.config not in valid_configs:
        ap.error("--config must be one of: %s" % ", ".join(valid_configs))
    if args.random_seed and args.base_seed is not None:
        ap.error("--random-seed and --base-seed are mutually exclusive")
    if args.jobs < 1:
        ap.error("--jobs must be positive")
    if args.campaign is not None and args.campaign < 1:
        ap.error("--campaign must be positive")

    if args.campaign is None:
        if args.seed is None:
            ap.error("need --seed or --campaign")
        if args.config is None:
            ap.error("--seed mode needs --config")
        b = make_case(args.seed, args.family, args.config, args.outdir)
        print("OK (ISS self-check): %s" % b)
        return

    requested_cores = args.cores.split(",") if args.cores else None
    configs = [args.config] if args.config else valid_configs
    base_seed = (args.base_seed if args.base_seed is not None
                 else random.SystemRandom().randrange(0, 1 << 31))
    print("campaign seeds: base=%d count=%d jobs=%d" %
          (base_seed, args.campaign, args.jobs))
    fails = 0
    total = 0
    external_irqs = 0
    first_failure = None
    for config in configs:
        cores = requested_cores
        if cores is None:
            if args.family == "nano":
                cores = ["nano"]
            elif args.family == "rc32":
                cores = ["rc32-%d" % width for width in RC32_WIDTHS]
            elif args.family == "fast":
                cores = ["fast", "fast-dsp"]
            elif args.family == "faster":
                cores = ["faster", "faster-dsp"]
            elif config == "full-mulh":
                cores = ["rc16-mulh"]
            elif config == "full-muldiv":
                cores = ["rc16-muldiv"]
            else:
                cores = ["rc16-1", "rc16-2", "rc16-4", "rc16-8", "rc16-16"]
        seeds = [base_seed + seed_idx for seed_idx in range(args.campaign)]

        def generate(seed):
            try:
                return seed, make_case(seed, args.family, config, args.outdir), None
            except Exception as error:
                return seed, None, error

        with concurrent.futures.ThreadPoolExecutor(
                max_workers=min(args.jobs, len(seeds))) as executor:
            generated = list(executor.map(generate, seeds))
        bins = []
        for seed, image, error in generated:
            if error is not None:
                print("GENFAIL %s/%s seed=%d: %s" %
                      (args.family, config, seed, error))
                print("replay: %s" % replay_command(args, config, seed))
                sys.exit(1)
            bins.append((seed, image))

        def build_core(core):
            return core, build_tb(core, args.family, config, args.outdir)

        with concurrent.futures.ThreadPoolExecutor(
                max_workers=min(args.jobs, len(cores))) as executor:
            testbenches = list(executor.map(build_core, cores))

        comparisons = [
            (core, tb, seed, image)
            for core, tb in testbenches
            for seed, image in bins
        ]

        def compare(item):
            core, tb, seed, image = item
            checker = (compare_final_state if args.family == "faster"
                       else compare_trace)
            return (core, seed, image,
                    checker(core, args.family, config, seed, image, tb))

        with concurrent.futures.ThreadPoolExecutor(
                max_workers=min(args.jobs, len(comparisons))) as executor:
            results = executor.map(compare, comparisons)
            for core, seed, image, result in results:
                total += 1
                ok, detail, _, _ = result
                if not ok:
                    fails += 1
                    divergence = ("STATE-DIVERGE" if args.family == "faster"
                                  else "TRACE-DIVERGE")
                    print("%s %s %s/%s seed=%d: %s\n%s"
                          % (divergence, core, args.family, config, seed,
                             os.path.basename(image), detail))
                    if first_failure is None:
                        first_failure = (core, config, seed)
                        print("replay: %s" %
                              replay_command(args, config, seed, core))
                elif detail.startswith("PASS external IRQ"):
                    external_irqs += 1
        print("config %s/%s done" % (args.family, config))
    print("campaign: %d runs, %d divergences" % (total, fails))
    if external_irqs:
        print("external IRQ injections: %d" % external_irqs)
    if first_failure is not None:
        core, config, seed = first_failure
        print("first failing seed: family=%s config=%s core=%s seed=%d"
              % (args.family, config, core, seed))
        print("replay first failure: %s" %
              replay_command(args, config, seed, core))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()

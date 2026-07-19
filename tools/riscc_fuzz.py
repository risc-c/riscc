#!/usr/bin/env python3
"""RISC-C differential fuzzer.

Generates seeded random programs, predicts their final architectural
state with the ISS (compiled RISCC_SIM when available, Python fallback),
and emits SELF-CHECKING binaries: the epilogue compares every register
(and probed memory words, and the IRQ/BRK counters) against the ISS
prediction and writes the standard 0x600D/0x0BAD result word.  The same
binary then runs unchanged under any RTL core's testbench -- a divergence
between the RTL and the ISS shows up as a FAIL with a distinct code per
checked item.

Program shape (per seed): random straight-line ALU/imm/memory ops over
r1..r6 with a high-RAM data window, forward-branch blocks, bounded
counted loops, CALL/RETS subroutines, MTS/MFS spills, and -- in sys
configs -- STI/CLI and testbench-IRQ triggers (counted in S1) with a
save/restore handler.  Vector layout follows the current exception
model: reset enters at word 0 (JMP16 slot), IRQ at word 2; min images
have no vector table.

Usage:
  riscc_fuzz.py --seed 42 --config sys
  riscc_fuzz.py --campaign 25 --cores tiny1,tiny2,tiny4,tiny8,tiny16
  riscc_fuzz.py --campaign 25                 # random campaign base seed
  riscc_fuzz.py --campaign 25 --base-seed 12345
  riscc_fuzz.py --family nano --campaign 25
  riscc_fuzz.py --campaign 25 --config sys --cores tiny1
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
sys.path.insert(0, HERE)
import riscc_sim as iss  # noqa: E402

WIN = 0xFC00              # data window, high RAM below the suite scratch
WIN_WORDS = 32
NANO_SCRATCH = 0xFB00     # saved nano GPR image, below WIN
IRQ_TRIG = 0xFFFA         # I/O page: irq trigger register
IRQ_ACK = 0xFFF8          # I/O page: irq acknowledge register
RESULT = 0xFFFE           # I/O page: result register
FAILBASE = 0x0B00         # fail codes 0x0B01.. per checked item

TINY_CONFIGS = ("min", "sys", "full")
NANO_CONFIGS = ("nano",)


def parse_config(config):
    if config not in TINY_CONFIGS:
        raise ValueError("unknown config: %s" % config)
    return {
        "sys": config != "min",
        "shifts": config != "min",
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
            op = self.rng.choice(["SHRI", "SARI", "SHLI"])
            n = self.rng.randint(1, 8)
        else:
            op = self.rng.choice(["SHRI", "SARI"])
            n = 1
        return ["    %-5s %s, %s, %d" % (op, self.reg(), self.reg(), n)]

    def op_mul(self):
        return ["    MUL   %s, %s, %s" % (self.reg(), self.reg(), self.reg())]

    def op_mem(self):
        off = self.rng.randrange(0, WIN_WORDS) * 2
        lines = ["    LDI16 r7, 0x%04X" % WIN]
        k = self.rng.random()
        if k < 0.35:
            lines.append("    STW   %s, [r7+%d]" % (self.reg(), off))
        elif k < 0.70:
            lines.append("    LDW   %s, [r7+%d]" % (self.reg(), off))
        elif k < 0.85:
            boff = self.rng.randrange(0, WIN_WORDS * 2)
            lines.append("    LDI   r0, %d" % boff)
            op = self.rng.choice(["LDB", "LDBS"])
            lines.append("    %-5s %s, [r7+r0]" % (op, self.reg()))
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
        subs.append(("%s:" % lab, body + ["    RETS"]))
        if self.sys and self.rng.random() < 0.5:
            return ["    CALL16 %s" % lab]
        r = self.reg()
        return ["    LDI16 %s, %s >> 1" % (r, lab),
                "    CALL  %s" % r]

    def op_irq(self):
        return ["    STI",
                "    LDI16 r7, 0x%04X" % IRQ_TRIG,
                "    STW   r7, [r7+0]"]

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
            lines.append("    STW   r1, [r7+%d]" % (w * 2))
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
            head += [
                "    JMP16 reset_tramp",
                "    JMP16 irq_h",
                "    JMP16 brk_h",
            ]
        head += [
            ".text",
            "reset_tramp:",
            "    LDI16 r0, start >> 1",
            "    JMP   r0",
            "fail:",
            "    LDI16 r7, 0x0BAD",
            "    LDI16 r6, 0x%04X" % RESULT,
            "    STW   r7, [r6+0]",
            "    HALT",
        ]
        if self.sys:
            head += [
                "irq_h:",                       # count in S1, ack, resume
                "    MTS   S2, r1",
                "    MFS   r1, S1",
                "    ADDI  r1, 1",
                "    MTS   S1, r1",
                "    LDI16 r1, 0x%04X" % IRQ_ACK,
                "    STW   r1, [r1+0]",
                "    MFS   r1, S2",
                "    ERET",
                "brk_h:",                       # count in S3, resume
                "    MTS   S2, r1",
                "    MFS   r1, S3",
                "    ADDI  r1, 1",
                "    MTS   S3, r1",
                "    MFS   r1, S2",
                "    ERET",
            ]
        self.rng = random.Random(self.seed)     # regenerate identically
        self.label = 0
        body, subs = self.body()

        # subroutines live at a fixed place BEFORE the epilogue so that
        # label addresses (captured into registers by LDI16 sub>>1) are
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
                     "    STW   r7, [r0+0]",
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
                         "    LDW   r6, [r7+0]"] + \
                    self.check_reg("r6", expect["mem"][w], code)
            tail += ["    LDI16 r7, 0x600D",
                     "    LDI16 r6, 0x%04X" % RESULT,
                     "    STW   r7, [r6+0]",
                     "    HALT"]
        return "\n".join(head + body + tail) + "\n"

    def check_reg(self, reg, want, code):
        scratch = "r7" if reg != "r7" else "r6"
        return ["    LDI16 %s, 0x%04X" % (scratch, want),
                "    SUB   r0, %s, %s" % (reg, scratch),
                "    BEQZ  ok_%x" % code,
                "    LDI16 r7, 0x%04X" % code,
                "    LDI16 r6, 0x%04X" % RESULT,
                "    STW   r7, [r6+0]",
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
            op = self.rng.choice(["SHRI", "SARI"])
            return ["    %-5s %s, %s, 1" % (op, self.reg(), self.reg())]
        return ["    SHL1  %s, %s" % (self.reg(), self.reg())]

    def op_mem(self):
        off = self.rng.randrange(0, WIN_WORDS) * 2
        lines = ["    LDI16 r7, 0x%04X" % WIN]
        k = self.rng.random()
        if k < 0.35:
            lines.append("    STW   %s, [r7+%d]" % (self.reg(), off))
        elif k < 0.70:
            lines.append("    LDW   %s, [r7+%d]" % (self.reg(), off))
        elif k < 0.85:
            boff = self.rng.randrange(0, WIN_WORDS * 2)
            lines.append("    LDI   r0, %d" % boff)
            lines.append("    LDB   %s, [r7+r0]" % self.reg())
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
        return ["    LDI16 r1, %s >> 1" % lab,
                "    CALL  r7, r1"]

    def body(self):
        subs = []
        lines = ["    LDI16 r7, 0x%04X" % WIN]
        for w in range(WIN_WORDS):
            lines.append("    LDI16 r1, 0x%04X" % self.rng.randint(0, 0xFFFF))
            lines.append("    STW   r1, [r7+%d]" % (w * 2))
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
            lines.append("    STW   r%d, [r0+%d]" % (r, r * 2))
        return lines

    def check_word(self, load_lines, want, code):
        return load_lines + [
            "    LDI16 r3, 0x%04X" % want,
            "    SUB   r0, r2, r3",
            "    BEQZ  nok_%x" % code,
            "    LDI16 r7, 0x%04X" % code,
            "    LDI16 r6, 0x%04X" % RESULT,
            "    STW   r7, [r6+0]",
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
            "    LDI16 r0, start >> 1",
            "    JMP   r0",
            "fail:",
            "    LDI16 r7, 0x0BAD",
            "    LDI16 r6, 0x%04X" % RESULT,
            "    STW   r7, [r6+0]",
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
                     "    STW   r7, [r6+0]",
                     "    HALT"]
        else:
            code = FAILBASE
            for r in range(1, 8):
                code += 1
                tail += self.check_word([
                    "    LDI16 r5, 0x%04X" % NANO_SCRATCH,
                    "    LDW   r2, [r5+%d]" % (r * 2),
                ], expect["r"][r], code)
            for w in expect["probes"]:
                code += 1
                tail += self.check_word([
                    "    LDI16 r5, 0x%04X" % (WIN + 2 * w),
                    "    LDW   r2, [r5+0]",
                ], expect["mem"][w], code)
            tail += ["    LDI16 r7, 0x600D",
                     "    LDI16 r6, 0x%04X" % RESULT,
                     "    STW   r7, [r6+0]",
                     "    HALT"]
        return "\n".join(head + body + tail) + "\n"


def assemble(asm_path, bin_path):
    subprocess.run([sys.executable, os.path.join(HERE, "riscc_asm.py"),
                    asm_path, "-o", bin_path], check=True,
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


def make_tiny_case(seed, config, outdir):
    cfg = parse_config(config)
    g = Gen(seed, config)
    stem = os.path.join(outdir, "fuzz_%s_%d" % (config, seed))
    with open(stem + "_probe.asm", "w") as f:
        f.write(g.emit(None))
    assemble(stem + "_probe.asm", stem + "_probe.bin")
    sim = tiny_state(stem + "_probe.bin", config, cfg)
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
    assemble(stem + ".asm", stem + ".bin")
    chk = tiny_state(stem + ".bin", config, cfg, dump_window=False)
    if chk["outcome"] != "DONE" or chk["result"] != 0x600D:
        raise RuntimeError("self-check failed under ISS (seed %d, result 0x%04X)"
                           % (seed, chk["result"]))
    return stem + ".bin"


def make_nano_case(seed, config, outdir):
    g = NanoGen(seed, config)
    stem = os.path.join(outdir, "fuzz_nano_%s_%d" % (config, seed))
    with open(stem + "_probe.asm", "w") as f:
        f.write(g.emit(None))
    assemble(stem + "_probe.asm", stem + "_probe.bin")
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
    assemble(stem + ".asm", stem + ".bin")
    chk = nano_state(stem + ".bin", config, dump_window=False)
    if chk["outcome"] != "DONE" or chk["result"] != 0x600D:
        raise RuntimeError("nano self-check failed under ISS (seed %d, result 0x%04X)"
                           % (seed, chk["result"]))
    return stem + ".bin"


def make_case(seed, family, config, outdir):
    if family == "nano":
        return make_nano_case(seed, config, outdir)
    return make_tiny_case(seed, config, outdir)


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
    return (family == "nano" and core == "nano1") or (
        family == "tiny" and core in ("tiny1", "tiny2", "tiny4", "tiny8", "tiny16")) or (
        family == "fast" and core in ("fast", "fast-dsp", "fast-ice", "fast-ice-dsp"))


def fast_iss_path():
    env = os.environ.get("RISCC_SIM")
    if env:
        return env
    candidate = os.path.join(ROOT, "build", "tools", "riscc_sim")
    return candidate if os.path.exists(candidate) else None


def sim_base_args(family, config, image, fast_iss):
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
    if not fast_iss:
        return None
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
    if family == "nano":
        if fast_iss:
            args = sim_base_args(family, config, image, fast_iss)
            args += ["--trace", "--dump-written"]
        else:
            args = [sys.executable, os.path.join(HERE, "riscc_sim.py"),
                    image, "--nano", "--trace", "--dump-written"]
        return args

    if fast_iss:
        args = sim_base_args(family, config, image, fast_iss)
        args += ["--trace", "--dump-written"]
    else:
        cfg = parse_config(config)
        args = [sys.executable, os.path.join(HERE, "riscc_sim.py"),
                image, "--trace", "--dump-written"]
        if not cfg["sys"]:
            args.append("--min")
        if cfg["full"]:
            args.append("--full")
    return args


def python_tiny_state(image, cfg):
    with open(image, "rb") as f:
        sim = iss.Sim(f.read(), sys_tier=cfg["sys"], full=cfg["full"])
    outcome = sim.run(500000)
    return {
        "outcome": outcome,
        "result": sim.mem[iss.RESULT_W],
        "r": list(sim.r),
        "s": list(sim.s),
        "mem": [sim.mem[(WIN >> 1) + w] for w in range(WIN_WORDS)],
    }


def python_nano_state(image):
    with open(image, "rb") as f:
        sim = iss.Sim(f.read(), sys_tier=False, nano=True)
    outcome = sim.run(500000)
    regs = [0] * 8
    for r in range(1, 8):
        regs[r] = sim.mem[(NANO_SCRATCH >> 1) + r]
    return {
        "outcome": outcome,
        "result": sim.mem[iss.RESULT_W],
        "r": regs,
        "mem": [sim.mem[(WIN >> 1) + w] for w in range(WIN_WORDS)],
    }


def tiny_state(image, config, cfg, dump_window=True):
    state = run_fast_state("tiny", config, image, dump_base=(WIN >> 1),
                           dump_len=WIN_WORDS) if dump_window else \
        run_fast_state("tiny", config, image)
    if state is None:
        return python_tiny_state(image, cfg)
    return state


def nano_state(image, config, dump_window=True):
    if dump_window:
        scratch_w = NANO_SCRATCH >> 1
        win_w = WIN >> 1
        dump_len = (win_w - scratch_w) + WIN_WORDS
        state = run_fast_state("nano", config, image, dump_base=scratch_w,
                               dump_len=dump_len)
        if state is not None:
            dumped = state["mem"]
            regs = [0] * 8
            for r in range(1, 8):
                regs[r] = dumped[r]
            state["r"] = regs
            state["mem"] = dumped[win_w - scratch_w:win_w - scratch_w + WIN_WORDS]
    else:
        state = run_fast_state("nano", config, image)
    if state is None:
        return python_nano_state(image)
    return state


def trace_lines(output):
    return [line for line in output.splitlines() if line.startswith("TRACE ")]


def memory_lines(output):
    return [line for line in output.splitlines() if line.startswith("MEM ")]


def compare_trace(core, family, config, seed, image, tb):
    iss_run = subprocess.run(sim_trace_args(family, config, image),
                             capture_output=True, text=True)
    rtl_run = subprocess.run([tb, image, "--trace", "--dump-written",
                              "--max-cycles", "400000"],
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

    if family == "nano":
        d = os.path.join(outdir, "v_trace_nano")
        top = "riscc_nano1"
        rtl = os.path.join(RTL, "riscc_nano1.v")
        defs = []
    elif family == "fast":
        d = os.path.join(outdir, "v_trace_%s" % core)
        top = "riscc_fast"
        rtl = os.path.join(RTL, "riscc_fast.v")
        defs = []
        if "dsp" in core:
            defs.append("-DRISCC_FAST_DSP")
        if "ice" in core:
            defs.append("-DRISCC_FAST_SYNC_RF")
    else:
        d = os.path.join(outdir, "v_trace_%s_%s" % (core, config))
        width = int(core.removeprefix("tiny"))
        if width == 16 and config == "min":
            top = "riscc_tiny16_min"
            rtl = os.path.join(RTL, "riscc_tiny16_min.v")
            width_args = []
        elif width == 16:
            top = "riscc_tiny16"
            rtl = os.path.join(RTL, "riscc_tiny16_full.v" if config == "full" else "riscc_tiny16_sys.v")
            width_args = []
        elif config == "min":
            top = "riscc_tiny_min"
            rtl = os.path.join(RTL, "riscc_tiny_min.v")
            width_args = ["-GW=%d" % width]
        else:
            top = "riscc_tiny"
            rtl = os.path.join(RTL, "riscc_tiny_full.v" if config == "full" else "riscc_tiny_sys.v")
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
        (" -DRISCC_TB_TRACE_DRAIN=1" if family == "fast" else
         " -DRISCC_TB_TRACE_DRAIN=0"
         if family == "tiny" and core == "tiny16" else ""),
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
    ap.add_argument("--family", default="tiny", choices=["tiny", "nano", "fast"])
    ap.add_argument("--config")
    ap.add_argument("--cores")
    ap.add_argument("--outdir", default=os.path.join(ROOT, "build", "fuzz"))
    args = ap.parse_args()
    os.makedirs(args.outdir, exist_ok=True)

    valid_configs = (NANO_CONFIGS if args.family == "nano" else
                     ("full",) if args.family == "fast" else TINY_CONFIGS)
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
        ["nano1"] if args.family == "nano" else
        ["fast", "fast-dsp"] if args.family == "fast" else
        ["tiny1", "tiny2", "tiny4", "tiny8", "tiny16"])
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

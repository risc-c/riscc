#!/usr/bin/env python3
"""RISC-C instruction-set simulator (golden model).

Executes a little-endian binary image with the same architectural
semantics as the tiny RTL cores, including the reserved I/O page at
the top of the address space (UART 0xFFF0..0xFFF6, irq ack 0xFFF8,
irq trigger 0xFFFA, result word 0xFFFE) and the IRQ-at-instruction-boundary rule, so
self-checking programs behave identically here and under
riscc_test.cpp.

Profile model mirrors the three RTL builds:
    --min           SLT/LDBS, count-one shifts, no sys profile
    sys (default)   min + IRQ/ERET + CALL16/JMP16 + variable shifts
    --full          sys + MUL
    --nano          nano ABI: no S-bank/sys profile/CMPI/JAL16, JAL links to rd
In min, SHRI/SARI shift by exactly 1 and SHLI/MUL are undefined.

Usage: riscc_sim.py image.bin [--min] [--full]
                       [--nano]
                       [--max-insns N] [--trace] [--dump ADDR LEN] [--dump-written]
                       [--uart] [--uart-in FILE] [--uart-in-text TEXT]
                       [--uart-out FILE] [--uart-expect TEXT]
                       [--fb-window] [--fb-scale N] [--fb-dump-png FILE]
Exit status follows the result-word protocol like the RTL testbench.
"""

import argparse
import struct
import sys
import zlib

# I/O page: top 16 bytes are word-wide registers (see riscc_test.cpp)
UART_TX_W     = 0x7FF8    # byte 0xFFF0
UART_RX_W     = 0x7FF9    # byte 0xFFF2
UART_STATUS_W = 0x7FFA    # byte 0xFFF4
UART_CTRL_W   = 0x7FFB    # byte 0xFFF6
IRQ_ACK_W     = 0x7FFC    # byte 0xFFF8
IRQ_RAISE_W   = 0x7FFD    # byte 0xFFFA
RESULT_W      = 0x7FFF    # byte 0xFFFE
RESET_PC    = 0x0000

FB_BASE_W = 0x4000        # byte 0x8000
FB_WORDS  = 160 * 120 // 4
FB_WIDTH  = 160
FB_HEIGHT = 120
FB_PALETTE = (
    (0x02, 0x04, 0x0a), (0x06, 0x11, 0x2b), (0x0a, 0x1f, 0x4d), (0x0d, 0x32, 0x74),
    (0x10, 0x49, 0x9c), (0x14, 0x64, 0xc4), (0x1a, 0x82, 0xe6), (0x25, 0xa4, 0xff),
    (0x45, 0xbd, 0xff), (0x6d, 0xd3, 0xff), (0x98, 0xe5, 0xff), (0xbd, 0xf1, 0xff),
    (0xd8, 0xf8, 0xff), (0xea, 0xfc, 0xff), (0xf6, 0xfe, 0xff), (0xff, 0xff, 0xff),
)


def sx8(v):
    return v - 256 if v & 0x80 else v


class Undefined(Exception):
    pass


def framebuffer_pixels(mem):
    rows = []
    for y in range(FB_HEIGHT):
        row = []
        for x in range(FB_WIDTH):
            pix = y * FB_WIDTH + x
            word = mem[FB_BASE_W + (pix >> 2)]
            row.append(FB_PALETTE[(word >> ((pix & 3) * 4)) & 0xF])
        rows.append(row)
    return rows


def png_chunk(kind, data):
    return (struct.pack(">I", len(data)) + kind + data +
            struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF))


def write_framebuffer_png(mem, path):
    raw = bytearray()
    for row in framebuffer_pixels(mem):
        raw.append(0)  # PNG filter type 0: no filter.
        for r, g, b in row:
            raw.extend((r, g, b))
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(png_chunk(b"IHDR", struct.pack(">IIBBBBB",
                                               FB_WIDTH, FB_HEIGHT,
                                               8, 2, 0, 0, 0)))
        f.write(png_chunk(b"IDAT", zlib.compress(bytes(raw), 9)))
        f.write(png_chunk(b"IEND", b""))


class FramebufferWindow:
    def __init__(self, sim, scale=2, title="RISC-C framebuffer"):
        import tkinter as tk

        self.tk = tk
        self.sim = sim
        self.scale = max(1, int(scale))
        self.root = tk.Tk()
        self.root.title(title)
        self.root.protocol("WM_DELETE_WINDOW", self.close)
        self.closed = False
        self.image = tk.PhotoImage(width=FB_WIDTH, height=FB_HEIGHT)
        self.zoomed = None
        self.canvas = tk.Canvas(self.root, width=FB_WIDTH * self.scale,
                                height=FB_HEIGHT * self.scale, highlightthickness=0)
        self.canvas.pack(fill=tk.BOTH, expand=True)
        self.item = self.canvas.create_image(0, 0, anchor=tk.NW)
        self.canvas.bind("<Configure>", self.resize)
        self.status = tk.StringVar()
        tk.Label(self.root, textvariable=self.status, anchor=tk.W).pack(fill=tk.X)
        self.redraw_zoom()

    def close(self):
        self.closed = True
        self.root.destroy()

    def redraw_zoom(self):
        self.zoomed = self.image.zoom(self.scale, self.scale)
        self.canvas.itemconfigure(self.item, image=self.zoomed)
        self.canvas.config(scrollregion=(0, 0, FB_WIDTH * self.scale, FB_HEIGHT * self.scale))
        self.place_image()

    def place_image(self):
        width = max(1, self.canvas.winfo_width())
        height = max(1, self.canvas.winfo_height())
        x = max(0, (width - FB_WIDTH * self.scale) // 2)
        y = max(0, (height - FB_HEIGHT * self.scale) // 2)
        self.canvas.coords(self.item, x, y)

    def resize(self, event):
        scale = max(1, min(max(1, event.width) // FB_WIDTH,
                           max(1, event.height) // FB_HEIGHT))
        if scale != self.scale:
            self.scale = scale
            self.redraw_zoom()
        else:
            self.place_image()

    def update(self):
        if self.closed:
            return
        rows = []
        for row in framebuffer_pixels(self.sim.mem):
            rows.append("{" + " ".join("#%02x%02x%02x" % rgb for rgb in row) + "}")
        self.image.put(" ".join(rows), to=(0, 0, FB_WIDTH, FB_HEIGHT))
        self.redraw_zoom()
        self.status.set("insns=%d uart-rx=%s uart-tx=%d" %
                        (self.sim.insns,
                         "ready" if self.sim.uart_rx_ready else "idle",
                         len(self.sim.uart_out)))
        self.root.update_idletasks()
        self.root.update()


class Sim:
    def __init__(self, image, sys_tier=True, full=False, nano=False,
                 trace=False, uart=False, uart_in=b""):
        self.mem = [0] * 32768
        for i in range(0, min(len(image), 65536), 2):
            hi = image[i + 1] if i + 1 < len(image) else 0
            self.mem[i >> 1] = image[i] | (hi << 8)
        self.r = [0] * 8          # r0..r7
        self.s = [0] * 8          # S0..S7
        self.pc = RESET_PC
        self.ie = 0
        self.irq_line = 0
        self.nano = nano
        self.sys_tier = False if nano else sys_tier
        self.shifts = nano or sys_tier or full
        self.full = full and not nano
        self.insns = 0
        self.trace = trace
        self.trace_steps = 0
        self.mem_written = [False] * 32768
        self.irq_taken = 0
        self.done = False
        self.uart = uart
        self.uart_in = bytearray(uart_in)
        self.uart_out = bytearray()
        self.uart_rx_data = 0
        self.uart_rx_ready = False
        self.uart_rx_overflow = False
        self.uart_irq_en = 0
        self.uart_tx_ready = True
        self.halted = False

    def service_uart(self):
        if self.uart and not self.uart_rx_ready and self.uart_in:
            self.uart_rx_data = self.uart_in.pop(0)
            self.uart_rx_ready = True

    def uart_irq(self):
        if not self.uart:
            return False
        return ((self.uart_irq_en & 1) and self.uart_rx_ready) or \
               ((self.uart_irq_en & 2) and self.uart_tx_ready)

    # -- memory helpers (byte addressing, word-aligned word access) -------
    def ldw(self, baddr):
        waddr = (baddr >> 1) & 0x7FFF
        if self.uart:
            if waddr == UART_RX_W:
                val = self.uart_rx_data
                self.uart_rx_ready = False
                self.uart_rx_overflow = False
                return val
            if waddr == UART_STATUS_W:
                return ((4 if self.uart_rx_overflow else 0) |
                        (2 if self.uart_rx_ready else 0) |
                        (1 if self.uart_tx_ready else 0))
            if waddr == UART_CTRL_W:
                return self.uart_irq_en & 3
        val = self.mem[waddr]
        return val

    def stw(self, baddr, val, mask=3):
        w = (baddr >> 1) & 0x7FFF
        if self.uart and w in (UART_TX_W, UART_CTRL_W):
            self.mem_written[w] = True
            if w == UART_TX_W and (mask & 1):
                self.uart_out.append(val & 0xFF)
                self.uart_tx_ready = True
            elif w == UART_CTRL_W and (mask & 1):
                self.uart_irq_en = val & 3
            return
        old = self.mem[w]
        if mask & 1:
            old = (old & 0xFF00) | (val & 0x00FF)
        if mask & 2:
            old = (old & 0x00FF) | (val & 0xFF00)
        self.mem[w] = old
        self.mem_written[w] = True
        if w == IRQ_RAISE_W:
            self.irq_line = 1
        if w == IRQ_ACK_W:
            self.irq_line = 0
        if w == RESULT_W:
            self.done = True

    def ldb(self, baddr, signed):
        waddr = (baddr >> 1) & 0x7FFF
        w = self.mem[waddr]
        b = (w >> 8) & 0xFF if baddr & 1 else w & 0xFF
        if signed and b & 0x80:
            b |= 0xFF00
        return b

    def stb(self, baddr, val):
        if baddr & 1:
            self.stw(baddr, (val & 0xFF) << 8, mask=2)
        else:
            self.stw(baddr, val & 0xFF, mask=1)

    def emit_trace(self, pc_before, ir):
        if not self.trace:
            return
        regs = ",".join("%04X" % x for x in self.r)
        sregs = ",".join("%04X" % x for x in self.s)
        print("TRACE step=%u pc=%04X ir=%04X ie=%u r=%s s=%s"
              % (self.trace_steps, self.pc & 0x7FFF, ir & 0xFFFF,
                 self.ie & 1, regs, sregs))
        self.trace_steps += 1

    # -- one architectural step -------------------------------------------
    def step(self):
        # level-sensitive IRQ, taken at the fetch/decode boundary
        self.service_uart()
        pc_before = self.pc
        ir = self.mem[self.pc & 0x7FFF]
        if self.sys_tier and self.ie and (self.irq_line or self.uart_irq()):
            self.s[0] = self.pc & 0x7FFF
            self.ie = 0
            self.pc = 2
            self.irq_taken += 1
            self.emit_trace(pc_before, ir)
            return
        self.insns += 1
        pc_next = (self.pc + 1) & 0x7FFF

        opc = ir >> 14
        ddd = (ir >> 11) & 7
        aaa = (ir >> 8) & 7
        f5 = (ir >> 3) & 0x1F
        bbb = ir & 7
        imm8 = ir & 0xFF

        if opc == 0:                                    # LDW rd, [ra+simm8]
            self.r[ddd] = self.ldw((self.r[aaa] + sx8(imm8)) & 0xFFFF)
        elif opc == 1:                                  # STW rd, [ra+simm8]
            addr = (self.r[aaa] + sx8(imm8)) & 0xFFFF
            self.stw(addr, self.r[ddd])
        elif opc == 2:
            if aaa == 0:                                # LDI
                self.r[ddd] = imm8
            elif aaa == 1:                              # LUI
                self.r[ddd] = (imm8 << 8) & 0xFFFF
            elif aaa == 2:                              # ADDI
                self.r[ddd] = (self.r[ddd] + sx8(imm8)) & 0xFFFF
            elif aaa == 3:                              # CMPI (writes r0 only)
                if self.nano:
                    raise Undefined("CMPI in nano")
                self.r[0] = (self.r[ddd] - sx8(imm8)) & 0xFFFF
            elif aaa == 4:
                self.r[ddd] &= imm8
            elif aaa == 5:
                self.r[ddd] |= imm8
            elif aaa == 6:
                self.r[ddd] ^= imm8
            else:                                       # branch group
                rel = sx8(imm8)
                if ddd < 4:
                    t = [self.r[0] == 0, self.r[0] != 0,
                         bool(self.r[0] & 0x8000), not (self.r[0] & 0x8000)][ddd]
                    if t:
                        pc_next = (pc_next + rel) & 0x7FFF
                elif ddd == 4:                          # JMP8
                    pc_next = (pc_next + rel) & 0x7FFF
                    # HALT is the canonical JMP8 -1 encoding.  Hardware
                    # parks at that address; the ISS can terminate instead.
                    if rel == -1:
                        self.halted = True
                else:
                    raise Undefined("branch cc 101/110/111 reserved")
        else:                                           # register format
            if f5 < 0x08:                               # ALU / MUL
                a, b = self.r[aaa], self.r[bbb]
                if f5 == 0:
                    res = (a + b) & 0xFFFF
                elif f5 == 1:
                    res = (a - b) & 0xFFFF
                elif f5 == 2:
                    if self.nano:
                        res = 1 if a < b else 0
                    else:
                        res = 1 if sx16(a) < sx16(b) else 0
                elif f5 == 3:
                    res = 1 if a < b else 0
                elif f5 == 4:
                    res = a & b
                elif f5 == 5:
                    res = a | b
                elif f5 == 6:
                    res = a ^ b
                elif f5 == 0x07:
                    if not self.full:
                        raise Undefined("MUL without the full profile")
                    res = (a * b) & 0xFFFF
                self.r[ddd] = res
            elif f5 in (0x08, 0x0A, 0x0E):              # indexed loads
                addr = (self.r[aaa] + self.r[bbb]) & 0xFFFF
                if f5 == 0x08:
                    self.r[ddd] = self.ldw(addr)
                elif f5 == 0x0A:
                    self.r[ddd] = self.ldb(addr, False)
                else:
                    self.r[ddd] = self.ldb(addr, True)
            elif f5 in (0x0C, 0x0D):                    # SHRI / SARI
                n = 1 if self.nano else ((bbb + 1) if self.shifts else 1)
                v = self.r[aaa]
                for _ in range(n):
                    fill = 0x8000 if (f5 == 0x0D and v & 0x8000) else 0
                    v = (v >> 1) | fill
                self.r[ddd] = v
            elif f5 == 0x0F:                            # SHLI
                if self.nano or not self.shifts:
                    raise Undefined("SHLI is not in the min profile")
                self.r[ddd] = (self.r[aaa] << (bbb + 1)) & 0xFFFF
            elif f5 == 0x0B:                            # STB rd, [ra]
                if bbb != 0:
                    raise Undefined("STB sub-op reserved")
                self.stb(self.r[aaa], self.r[ddd])
            elif f5 == 0x1F:                            # S/control group
                if self.nano:
                    if bbb != 1:
                        raise Undefined("non-JAL sys op in nano")
                    target = self.r[aaa] & 0x7FFF
                    if ddd != 0:
                        self.r[ddd] = pc_next & 0xFFFF
                    pc_next = target
                    self.pc = pc_next
                    self.emit_trace(pc_before, ir)
                    return
                if bbb == 0:                            # RET/RETI Sa
                    if ddd == 0:
                        pc_next = self.s[aaa] & 0x7FFF
                    elif ddd == 7 and self.sys_tier:
                        self.ie = 1
                        pc_next = self.s[aaa] & 0x7FFF
                    else:
                        raise Undefined("return control selector reserved")
                elif bbb == 1:                          # JAL Sd, ra
                    target = self.r[aaa] & 0x7FFF
                    if ddd != 0:
                        self.s[ddd] = pc_next & 0xFFFF
                    pc_next = target
                elif bbb == 2:                          # MFS rd, Sa
                    self.r[ddd] = self.s[aaa]
                elif bbb == 3:                          # MTS Sd, ra
                    self.s[ddd] = self.r[aaa]
                elif bbb == 5:                          # JAL16 Sd (two words)
                    if not self.sys_tier:
                        raise Undefined("sys-profile op in min")
                    target = self.mem[pc_next & 0x7FFF]
                    if ddd != 0:
                        self.s[ddd] = (self.pc + 2) & 0xFFFF
                    pc_next = target & 0x7FFF
                elif bbb == 6:                          # CLI / STI
                    if not self.sys_tier:
                        raise Undefined("sys-profile op in min")
                    if aaa != 0:
                        raise Undefined("CLI/STI aaa field reserved")
                    if ddd == 0:
                        self.ie = 0
                    elif ddd == 7:
                        self.ie = 1
                    else:
                        raise Undefined("IE control selector reserved")
                else:
                    raise Undefined("system sub-op reserved")
            else:
                raise Undefined("register-format reserved")
        self.pc = pc_next
        self.emit_trace(pc_before, ir)

    def run(self, max_insns=2_000_000, update=None, update_insns=20000):
        next_update = update_insns
        try:
            while ((max_insns <= 0 or self.insns < max_insns) and
                   not self.done and not self.halted):
                self.step()
                if update is not None and self.insns >= next_update:
                    if update() is False:
                        break
                    next_update = self.insns + update_insns
            if self.done:
                return "DONE"
            return "HALT" if self.halted else "TIMEOUT"
        except Undefined:
            raise


def sx16(v):
    return v - 0x10000 if v & 0x8000 else v


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("--min", action="store_true", help="min profile (no sys/variable shifts)")
    ap.add_argument("--full", action="store_true")
    ap.add_argument("--nano", action="store_true",
                    help="nano ABI/subset (JAL links to rd, no S-bank/sys profile)")
    ap.add_argument("--max-insns", type=int, default=2_000_000,
                    help="maximum committed instructions; 0 runs until DONE or window close")
    ap.add_argument("--trace", action="store_true")
    ap.add_argument("--dump", nargs=2, type=lambda x: int(x, 0), metavar=("WADDR", "LEN"))
    ap.add_argument("--dump-written", action="store_true")
    ap.add_argument("--uart", action="store_true",
                    help="enable UART MMIO model")
    ap.add_argument("--uart-in", metavar="FILE",
                    help="feed bytes from FILE into the UART RX device")
    ap.add_argument("--uart-in-text", metavar="TEXT",
                    help="feed TEXT bytes into the UART RX device")
    ap.add_argument("--uart-out", metavar="FILE",
                    help="write captured UART TX bytes to FILE")
    ap.add_argument("--uart-expect", metavar="TEXT",
                    help="succeed if captured UART TX contains TEXT")
    ap.add_argument("--fb-window", action="store_true",
                    help="show Icepi Zero 160x120 framebuffer in a live window")
    ap.add_argument("--fb-scale", type=int, default=2,
                    help="integer framebuffer window scale factor")
    ap.add_argument("--fb-update-insns", type=int, default=20000,
                    help="instructions between framebuffer window refreshes")
    ap.add_argument("--fb-dump-png", metavar="FILE",
                    help="write final framebuffer image as a PNG")
    args = ap.parse_args()
    if args.min and args.full:
        ap.error("--min and --full are mutually exclusive")
    if args.nano and (args.min or args.full):
        ap.error("--nano cannot be combined with a tiny profile")

    with open(args.image, "rb") as f:
        image = f.read()
    uart_in = bytearray()
    if args.uart_in:
        with open(args.uart_in, "rb") as f:
            uart_in.extend(f.read())
    if args.uart_in_text is not None:
        uart_in.extend(args.uart_in_text.encode("latin1"))
    sim = Sim(image, sys_tier=not args.min, full=args.full,
              nano=args.nano, trace=args.trace,
              uart=args.uart or args.uart_in or args.uart_in_text is not None or
              args.uart_out or args.uart_expect is not None,
              uart_in=bytes(uart_in))
    fb_window = None
    update = None
    if args.fb_window:
        fb_window = FramebufferWindow(sim, scale=args.fb_scale)

        def update():
            if fb_window.closed:
                return False
            fb_window.update()
            return True

    outcome = sim.run(args.max_insns, update=update, update_insns=args.fb_update_insns)
    if fb_window is not None and not fb_window.closed:
        fb_window.update()
    if args.fb_dump_png:
        write_framebuffer_png(sim.mem, args.fb_dump_png)
    result = sim.mem[RESULT_W]
    normal_halt = outcome == "HALT" and result == 0
    passed = result == 0x600D or normal_halt
    uart_ok = None
    if args.uart_expect is not None:
        uart_ok = args.uart_expect.encode("latin1") in bytes(sim.uart_out)
        print("%s after %d insns, result=0x%04X, UART expect %r: %s"
              % (outcome, sim.insns, result, args.uart_expect,
                 "PASS" if uart_ok else "FAIL"))
    else:
        print("%s after %d insns, result=0x%04X: %s"
              % (outcome, sim.insns, result,
                 "PASS" if passed else "FAIL"))
    if sim.uart:
        if args.uart_out:
            with open(args.uart_out, "wb") as f:
                f.write(sim.uart_out)
        else:
            text = sim.uart_out.decode("latin1", errors="replace")
            print("UART-TX: %r" % text)
    if args.dump_written:
        for i, touched in enumerate(sim.mem_written):
            if touched:
                print("MEM 0x%04X 0x%04X" % (i, sim.mem[i]))
    if args.dump:
        base, ln = args.dump
        for i in range(ln):
            print("  [0x%04X] = 0x%04X" % (base + i, sim.mem[base + i]))
    if uart_ok is not None:
        sys.exit(0 if uart_ok else 1)
    sys.exit(0 if passed else 1)


if __name__ == "__main__":
    main()

# RISC-C Hardware Manual

This manual covers RISC-C RTL implementations, FPGA targets, validation,
measurement, and board demos. The normative instruction definition is the
[ISA specification](RISC-C.md). Software development, assembly, C, runtime,
and linker-layout guidance is in the [Programming manual](PROGRAMMING.md).

## 1. Implementation family

RISC-C is implemented as several in-order cores sharing the ISA profiles
defined by the [ISA specification](RISC-C.md). The implementation and profile
are independent build choices.

| Implementation | RTL | Organization | Profiles |
|---|---|---|---|
| RISC-C/1, /2, /4, /8 | [`rtl/riscc_tiny.v`](../rtl/riscc_tiny.v) | parameterized serial datapath, width `W = 1, 2, 4, 8` | `min`, `sys`, `full` |
| RISC-C/16 | [`rtl/riscc_tiny16.v`](../rtl/riscc_tiny16.v) | 16-bit multi-cycle datapath | `min`, `sys`, `full` |
| RISC-C/nano | [`rtl/riscc_nano1.v`](../rtl/riscc_nano1.v) | fixed one-bit serial datapath | `nano` |
| RISC-C/fast | [`rtl/riscc_fast.v`](../rtl/riscc_fast.v) | two-stage in-order pipeline | `full` |
| RISC-C/faster | [`rtl/riscc_faster.v`](../rtl/riscc_faster.v) | three-stage interlocked pipeline | `full` |

Nano is an incompatible subset profile, not a smaller implementation of
mainline `min`. Fast implements only `full`; Faster is an Agilex-oriented
experiment rather than a mainline width-ladder member.

### Serial Tiny cores

Tiny is one parameterized multi-cycle design. It fetches from a synchronous
unified memory port, then streams a 16-bit operand through a `W`-bit data path
least-significant bits first. The same serial ALU path performs arithmetic,
comparison, effective-address, and PC updates. A one-port register file holds
`r0..r7` and `S0..S7`; a second source is staged before register-register
operations. Loads, stores, shifts, and multiplication add the needed transfer
or iteration passes rather than additional wide datapaths.

![Serial RISC-C microarchitecture](riscc_serial_microarch.svg)

The four serial widths are elaborations of the same source. RISC-C/16 is
deliberately separate: it retains a small multi-cycle control machine but uses
a full 16-bit datapath and shared 17-bit result/adder path.

### Nano and RISC-C/16

Nano uses its own fixed one-bit register file, staging, and control structure;
it omits the mainline S-register/system paths. RISC-C/16 uses one-hot
multi-cycle control, synchronous unified memory, and a shared MDR stage for
second operands, loads, byte lanes, and the second word of `JAL16`.

![RISC-C/16 microarchitecture](riscc_tiny16_microarch.svg)

### Pipelined cores

Fast overlaps a synchronous fetch response with the execution of the current
instruction in a straight two-stage F/X in-order pipeline. Loads, multi-bit
shifts, and soft multiply use small side states. Its register file is
replicated for two reads: ECP5 uses distributed LUTRAM, iCE40 uses EBRs, and
Agilex uses MLAB LUTRAM plus a registered write overlay. There is no branch
predictor or forwarding network; iCE40 can add a RAW stall due to its
synchronous EBR reads.

![RISC-C/fast pipeline](riscc_fast_pipeline.svg)

Faster is a separate three-stage IF/Decode/Execute design for Agilex 3. It
uses two synchronous MLAB register-file replicas and no bypass network; RAW
dependencies interlock in Decode. Its default multiplier is a registered DSP
block, and `RISCC_FASTER_SOFT_MUL` substitutes iterative ALM logic.

![RISC-C/faster pipeline and Execute ownership states](riscc_faster_pipeline.svg)

## 2. FPGA platforms and configuration

The reference RTL targets iCE40, ECP5, and Agilex 3. The mainline iCE40 cores
use one EBR for the register file and one unified 16-bit synchronous memory
port. With `RISCC_ECP5`, the mainline RF maps to packed distributed LUTRAM;
Fast has its separate replicated two-read RF. On Agilex 3, Tiny/Nano use an
inferred MLAB RF, while Faster uses two MLAB replicas and a registered DSP.

The demonstrated boards are:

- [Icepi Zero](https://github.com/cheyao/icepi-zero), ECP5
  `LFE5U-25F-6BG256C`, using a Fast SoC with on-chip program RAM, DVI
  framebuffer, LEDs, and UART.
- Terasic Atum A3 Nano, Agilex 3 `A3CZ135BB18AE7S`, using a Faster SoC with
  program RAM, UART, framebuffer, and TFP410 HDMI output.

Build profiles are selected at build time. Tiny target names use
`<verb>-<width>-<profile>` for widths `1`, `2`, `4`, `8`, and `16`; Nano uses
`<verb>-nano`. `full` includes `sys`; Fast and Faster have their own targets.
Examples: `make test-16-sys`, `make area-2-min`, and `make fmax-8-full`.

## 3. Current implementation results

Resource use, clock rate, and benchmark throughput are the primary comparison
points. Cycle counts follow them as a reference for implementation work.

| iCE40 LUT4 | /1 | /2 | /4 | /8 | /16 |
|---|---:|---:|---:|---:|---:|
| `min` | 121 | 134 | 162 | 219 | 252 |
| `sys` | 148 | 165 | 198 | 260 | 279 |
| `full` | 169 | 189 | 228 | 296 | 332 |
| nano | 93 | — | — | — | — |
| Fast soft / DSP | — | — | — | — | 480 / 440 |

| ECP5 LUTs (RF included) | /1 | /2 | /4 | /8 | /16 |
|---|---:|---:|---:|---:|---:|
| `min` | 164 | 179 | 201 | 255 | 278 |
| `sys` | 192 | 205 | 235 | 293 | 306 |
| `full` | 213 | 232 | 267 | 331 | 364 |
| nano | 114 | — | — | — | — |

| ECP5 LUTs (block RF) | /1 | /2 | /4 | /8 | /16 |
|---|---:|---:|---:|---:|---:|
| `min` | 125 | 139 | 165 | 233 | 274 |
| `sys` | 153 | 165 | 200 | 273 | 303 |
| `full` | 171 | 189 | 229 | 309 | 358 |
| nano | 93 | — | — | — | — |

| Agilex 3 ALMs (RF included) | /1 | /2 | /4 | /8 | /16 |
|---|---:|---:|---:|---:|---:|
| `min` | 99.3 | 111.9 | 118.0 | 132.4 | 125.1 |
| `sys` | 116.8 | 121.5 | 133.9 | 151.9 | 151.4 |
| `full` | 131.9 | 144.6 | 151.4 | 170.4 | 218.6 |
| nano | 90.2 | — | — | — | — |
| Fast soft / DSP | — | — | — | — | 308 / 310 |
| Faster DSP / soft | — | — | — | — | 299.3 / 326.4 |

| Fmax (MHz) | /1 | /2 | /4 | /8 | /16 | nano | fast soft | fast DSP | faster DSP | faster soft |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| iCE40 UP5K | 33.67 | 29.67 | 27.15 | 24.99 | 25.28 | 31.56 | 24.47 | 21.98 | — | — |
| iCE40 HX8K | 101.53 | 85.90 | 82.82 | 77.30 | 74.02 | 92.26 | 64.15 | — | — | — |
| ECP5 LFE5U-25F | 101.90 | 106.61 | 85.40 | 81.11 | 84.98 | 104.07 | 68.14 | 67.00 | — | — |
| Agilex 3 | 277.16 | 266.81 | 242.95 | 222.87 | 211.51 | 306.37 | 185.29 | 152.93 | 222.97 | 207.99 |

Tiny Fmax values use the `sys` profile width ladder. Nano uses its fixed
profile; Fast and Faster use `full`.

The iCE40/ECP5 figures are reproducible open-FPGA results. Agilex results are
Quartus Pro 26.1 post-fit characterizations for `A3CZ135BB18AE7S`; Fmax is a
restricted-Fmax estimate, not closure at every listed clock. Run
`make -j16 tables` to regenerate the open-FPGA area/Fmax matrices, benchmarks,
and the published Agilex report. Faster has validation and benchmark targets
but no standalone open-FPGA area/Fmax target.

The common benchmark retires 3,165 instructions on mainline, Fast, and Faster,
and 8,418 on Nano because Nano uses software multiply. The Tiny rates combine
the mainline benchmark cycle counts with the `sys` width-ladder clocks above;
Fast and Faster use their matching full-profile clocks.

| Benchmark MIPS | /1 | /2 | /4 | /8 | /16 | nano | fast soft | fast DSP | faster DSP | faster soft |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| iCE40 UP5K | 0.94 | 1.53 | 2.40 | 3.46 | 6.00 | 1.02 | 13.59 | 14.88 | — | — |
| iCE40 HX8K | 2.85 | 4.43 | 7.33 | 10.70 | 17.56 | 2.97 | 35.63 | — | — | — |
| ECP5 | 2.86 | 5.50 | 7.56 | 11.23 | 20.16 | 3.35 | 37.85 | 45.37 | — | — |
| Agilex 3 | 7.77 | 13.75 | 21.50 | 30.86 | 50.18 | 9.88 | 102.92 | 103.56 | 106.07 | 87.20 |

| Benchmark MIPS/kLUT4 (kLE on Agilex) | /1 | /2 | /4 | /8 | /16 | nano | fast soft | fast DSP | faster DSP | faster soft |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| iCE40 UP5K | 5.6 | 8.1 | 10.5 | 11.7 | 18.1 | 10.9 | 28.3 | 33.8 | — | — |
| iCE40 HX8K | 16.9 | 23.4 | 32.1 | 36.2 | 52.9 | 32.0 | 74.2 | — | — | — |
| ECP5 block RF | 16.7 | 29.1 | 33.0 | 36.3 | 56.3 | 36.1 | 75.5 | 100.8 | — | — |
| ECP5 LUTRAM RF | 13.4 | 23.7 | 28.3 | 33.9 | 55.4 | 29.4 | 75.5 | 100.8 | — | — |
| Agilex 3 (kLE) | 20.0 | 32.2 | 48.1 | 61.4 | 77.8 | 109.5 | 113.3 | 113.2 | 120.1 | 90.6 |

### Cycle counts

All cycle counts run self-checking images to the result-word write. Fast and
Faster implement `full` only; Nano runs its separate profile.

| Validation cycles | /1 | /2 | /4 | /8 | /16 | nano | fast soft | fast DSP | faster DSP | faster soft |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `min` | 5516 | 3076 | 1856 | 1246 | 737 | — | — | — | — | — |
| `sys` | 9011 | 4971 | 2967 | 1965 | 1194 | — | — | — | — | — |
| `full` | 10973 | 6013 | 3541 | 2297 | 1381 | — | 558 | 478 | 685 | 755 |
| `nano` | — | — | — | — | — | 3659 | — | — | — | — |

| Common benchmark cycles | /1 | /2 | /4 | /8 | /16 | nano | fast soft | fast DSP | faster DSP | faster soft |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `test_riscc_bench` | 112841 | 61393 | 35765 | 22855 | 13340 | 261136 | 5698 | 4674 | 6653 | 7549 |

## 4. FPGA toolchain

The open-source flow needs yosys, Verilator 5 or newer, g++, Python 3,
nextpnr-ice40, nextpnr-ecp5, icestorm, prjtrellis, and optionally ccache and
openFPGALoader. On Debian/Ubuntu:

```sh
sudo apt-get install -y build-essential make python3 ccache libsdl2-dev libstb-dev \
  verilator yosys nextpnr-ice40 nextpnr-ecp5 fpga-icestorm fpga-trellis \
  openfpgaloader
```

The Makefile finds tools on `PATH`; override them per command when necessary,
for example:

```sh
make VERILATOR=/opt/verilator/bin/verilator YOSYS=/opt/yosys/bin/yosys test-all
make NEXTPNR_ECP5=/opt/oss-cad-suite/bin/nextpnr-ecp5 icepi-zero-demo-bit
make QUARTUS_SH=/opt/intelFPGA_pro/26.1/quartus/bin/quartus_sh atum-a3-demo
```

When installed, ccache is automatically used for generated Verilator C++, the
C++ ISS, and host C/C++ compilation for the LLVM build. It uses ccache's
configured persistent directory (normally `~/.cache/ccache`), not `/tmp`.
Yosys synthesis is not a ccache workload.

## 5. Board builds and demos

The current board SoCs are demonstrations, not a stable general-purpose
platform SDK. Their small common map is useful for the supplied firmware:

| Byte address or range | Demo function |
|---:|---|
| `0x0000..0x7fff` | unified program/data RAM |
| `0x8000..0xa57f` | displayed 160x120 framebuffer: four adjacent 4-bit pixels per 16-bit word; CPU writes only |
| `0xffe8` | LED output; Icepi uses five low bits and Atum uses four |
| `0xfff0..0xfff6` | UART; see the [Programming manual](PROGRAMMING.md#1-software-tools-and-the-iss) for register semantics |

The active framebuffer is 4,800 words. The surrounding display aperture and
other high-MMIO addresses are board implementation details; in particular,
the ISS/generic-testbench registers at `0xfff8..0xfffe` are not board devices.
The UART divisor is likewise a board-build setting, not a RISC-C platform
standard.

### Icepi Zero

The Icepi demo is in [`boards/icepi_zero`](../boards/icepi_zero). It runs a
50 MHz Fast SoC, a 160x120 4-bit framebuffer scaled to 640x480 DVI, UART,
LEDs, and the Julia-set demo firmware.

```sh
make icepi-zero-demo-bin
make icepi-zero-demo-iss
make icepi-zero-demo-iss-test
make icepi-zero-demo-rtlsim
make icepi-zero-demo-json
make icepi-zero-demo-bit
```

For the multiplier/UART smoke image, use:

```sh
make -B ICEPI_ASM=boards/icepi_zero/sw/mul_uart_test.asm icepi-zero-demo-bit
```

The bit target only builds a bitstream. The tested SRAM-load command is:

```sh
openFPGALoader -cft231X --pins=7:3:5:6 build/icepi_zero/demo.bit
```

After loading, wait for USB devices to re-enumerate, then identify any serial
or video interfaces using the host operating system's normal tooling.

The following is a video-capture frame from the Icepi Zero FPGA's physical
video output.

![Video capture of RISC-C running on Icepi Zero](riscc_on_icepi-zero.jpg)

*Video capture of RISC-C running on the Icepi Zero FPGA board.*

### Terasic Atum A3 Nano

[`boards/atum_a3_nano`](../boards/atum_a3_nano) is the Quartus Pro Agilex 3
demo. It runs a 100 MHz Faster SoC, UART, on-chip program RAM, and a 160x120
4-bit framebuffer expanded to 1920x1080p60 through the TFP410. Firmware
assembly, ISS use, and RTL simulation need no external board checkout:

```sh
make atum-a3-demo-bin
make atum-a3-demo-iss
make atum-a3-demo-rtlsim
```

Generating a `.sof` additionally needs Quartus Pro with Agilex 3 device
support. The project directly instantiates the required IOPLL and
configuration-reset primitives, so it has no external vendor-checkout
dependency:

```sh
make atum-a3-demo
```

The staged project and `.sof` live under `build/atum_a3_nano/quartus`.

#### Running on the board

The normal development flow configures the FPGA through JTAG; it is
temporary and does not change the board's QSPI flash or factory image.

1. Power the board, connect a display to HDMI, and connect the host to the
   board's USB-Blaster III Type-C connector (J4). Install the USB-Blaster III
   driver supplied with Quartus if the cable is not detected.
2. Build the SRAM configuration image:

   ```sh
   make -j16 atum-a3-demo
   ```

3. List the detected programmer cables and devices. Use the cable name printed
   by the first command; `Atum A3 Nano [USB-0]` below is only an example.

   ```sh
   quartus_pgm -l
   quartus_pgm -c "Atum A3 Nano [USB-0]" -a
   ```

4. Configure the FPGA:

   ```sh
   quartus_pgm -c "Atum A3 Nano [USB-0]" -m jtag \
     -o "p;build/atum_a3_nano/quartus/output_files/atum_a3_nano.sof"
   ```

The demo starts when configuration completes. It outputs the 1080p framebuffer
on HDMI and writes `RISC-C on Atum A3 Nano` to the board's USB-UART at 115200
8N1. Identify the serial device with the host operating system's normal
tooling; its name is host-specific. A power cycle or another configuration
restores the image selected by the board's normal boot configuration.

For persistent QSPI programming, generate a `.jic` and follow Terasic's
[Atum A3 Nano documentation](https://www.terasic.com.tw/cgi-bin/page/archive.pl?CategoryNo=44&Language=English&No=1373&PartNo=4).
That intentionally replaces the flash image and is outside this project's
normal development flow.

The Quartus Pro 26.1 post-fit demo uses 533 ALMs, 21 M20K blocks, one DSP
block, and two IOPLLs. Both the 100 MHz system and 148.5 MHz pixel-clock
constraints meet setup timing (2.880 ns and 3.902 ns slack respectively).

![Video capture of RISC-C running on Atum A3 Nano](riscc_on_atum-a3.jpg)

*Video capture of RISC-C running on the Atum-A3-Nano FPGA board.*

## 6. Validation and measurement

```sh
make test-<width>-<profile>   # Tiny width 1/2/4/8/16
make test-nano
make test-fast
make test-faster
make test-all
make sim-all
make fuzz-all
make bench
make area-table
make fmax-table
make -j16 tables
```

The shared Verilator testbench models synchronous single-port memory and can
inject an external IRQ. Trace builds expose a post-step architectural record:
the next PC, current instruction context, IE, `r0..r7`, and `S0..S7`. The ISS
and RTL must produce identical trace records for the same image; written-memory
records are compared as well.

### Trace comparison

The `trace-*` targets build a trace-enabled Verilator testbench. Build the
matching image first, then compare trace records. The C++ ISS writes traces to
stderr, so redirect it before filtering:

```sh
make trace-16-full > rtl.log 2>&1
build/tools/riscc_sim build/bin/riscc-full.bin --full --trace --dump-written \
  > iss.log 2>&1
grep '^TRACE ' iss.log > iss.trace
grep '^TRACE ' rtl.log > rtl.trace
diff -u iss.trace rtl.trace
```

Use `make trace-nano`, `make trace-<width>-<profile>`, or `make trace-fast`
for the relevant implementation. On a mismatch, compare the first differing
`TRACE` record and then the `MEM` records from `--dump-written`; this separates
an architectural state error from a final-memory error.

### Differential fuzzing

`tools/riscc_fuzz.py` generates deterministic, self-checking assembly programs
from a seed. For each generated binary it first derives the expected state with
the C++ ISS when available (otherwise the Python ISS), then runs a trace-enabled
RTL testbench. It compares every `TRACE` record and every written-memory record,
and the generated program independently checks its final architectural state.

The random programs cover ALU and immediate operations, loads/stores,
forward branches, bounded loops, calls, S-register spills, and for system
profiles IRQ enable/disable and testbench IRQ delivery. Nano uses its own
compatible program shape; Fast uses the full profile.

```sh
make fuzz-all                              # default: 100 fresh seeds/config
FUZZ_SEEDS=1 FUZZ_BASE_SEED=12345 make fuzz-sys
FUZZ_SEEDS=10 FUZZ_BASE_SEED=12345 make fuzz-nano
FUZZ_SEEDS=10 FUZZ_BASE_SEED=12345 make fuzz-fast
```

The command prints the campaign base seed and, on failure, a one-command
replay using the failing seed, profile, and core. For a direct focused run:

```sh
python3 tools/riscc_fuzz.py --seed 12345 --config sys
python3 tools/riscc_fuzz.py --campaign 1 --base-seed 12345 \
  --config sys --cores tiny16
```

Build artifacts, generated programs, traces, and reports belong under
`build/`; keep source-tree RTL and board directories free of generated flow
output.

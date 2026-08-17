# RISC-C Hardware Manual

This manual covers RISC-C RTL implementations, FPGA targets, validation,
measurement, and board demos. The normative instruction definition is the
[ISA specification](RISC-C-ISA.md). Software development, assembly, C, runtime,
and linker-layout guidance is in the [Programming manual](PROGRAMMING.md).

## 1. Implementation family

RISC-C has serial and pipelined in-order implementations. The serial machines
reuse a small datapath over several cycles; Fast and Faster duplicate more
state and logic to overlap work. Every core uses one synchronous, unified
memory port for instruction fetches and data transfers. The
[ISA specification](RISC-C-ISA.md) defines the architectural configurations;
this section describes how the RTL realizes them.

### Core families

| Implementation | Microarchitecture | RTL |
|---|---|---|
| Nano | fixed one-bit serial controller and register file | [`riscc_nano.v`](../rtl/riscc_nano.v) |
| RC16 serial `/1`–`/8` | `W`-bit sliced ALU and one-port register file | [`riscc_min.v`](../rtl/riscc_min.v), [`riscc_sys.v`](../rtl/riscc_sys.v), [`riscc_full.v`](../rtl/riscc_full.v) |
| RC16 serial `/16` | 16-bit datapath with multi-cycle control | [`riscc16_min.v`](../rtl/riscc16_min.v), [`riscc16_sys.v`](../rtl/riscc16_sys.v), [`riscc16_full.v`](../rtl/riscc16_full.v) |
| RC32 serial `/1`–`/16` | `W`-bit serial 32-bit datapath over a 16-bit memory port | [`riscc32_min.v`](../rtl/riscc32_min.v), [`riscc32_sys.v`](../rtl/riscc32_sys.v) |
| Fast | two-stage Fetch/Execute pipeline | [`riscc16_fast.v`](../rtl/riscc16_fast.v) |
| Faster | three-stage Fetch/Decode/Execute pipeline | [`riscc16_faster.v`](../rtl/riscc16_faster.v) |

### Serial cores

The sliced RC16 `/1` through `/8` and RC32 `/1` through `/16` cores stream an
architectural word through a `W`-bit ALU, least-significant slice first. The
ALU performs arithmetic, comparison, and effective-address formation. A
time-multiplexed register file has one read port and one write port, so a
register-register operation shifts one source through staging before reading
the other: the staging stream is 16 bits in RC16 and 32 bits in RC32. RC32
keeps its 16-bit unified memory port, so every native 32-bit load or store
uses two halfword transfers. Fetch request/capture, decode, operand
preparation, memory transfer, and result writeback are distinct controller
phases.

RC16 sliced cores use a separate `W`-bit PC-slice adder. RC32 `/1` through
`/4` do likewise; RC32 `/8` and `/16` reuse the serial ALU for PC work in an
extra execution pass.

The sliced controller starts at `FETCH_WAIT` and `FETCH_CAPTURE`, then
`DECODE`. Simple operations proceed to `EXECUTE`; forms needing staged
operands use `INIT2` and `INIT`, and memory transfers add `MEM_WAIT` and
`MEM_XFER`. Iterative operations repeat `EXECUTE` across slices, with the last
pass writing the result before the next fetch.

The Sys controllers add saved control state and an interrupt-entry path to the
same serial datapath. RC16 Full adds iterative arithmetic control. Nano is a
separate fixed `/1` design: its one-bit register file, compact decode, and
preparation phase are tailored to the minimal serial schedule rather than
being a parameter setting of the RC16 or RC32 controllers.

RC16 `/16` is a separate multi-cycle implementation with a full-width
datapath. Its single 17-bit ALU completes ordinary arithmetic,
effective-address formation, and PC updates in word-wide passes. Its
full-word register-file read and MDR replace the sliced RF access and shifting
staging register; the MDR holds an operand, effective address, or load value
between controller phases.

The `/16` controller cycles its full-width datapath through fetch request,
instruction capture, decode, operand load, and execute. A memory read adds
memory access, load capture, and MDR writeback; separate commit states update
links, comparisons, and control state. The Full controller adds an
operand-load/iterate pair for multi-cycle shifts and multiplication.

The three forms have the same single-read/single-write RF, unified-memory,
in-order dataflow; they differ in execution width, staging, memory-word
transfer width, and PC-update hardware.

| Structure | RC16 `/1`–`/8` | RC16 `/16` | RC32 `/1`–`/16` |
|---|---|---|---|
| Register and operand staging | `W`-bit RF slices; one operand shifts through a 16-bit staging register | 16-bit RF word; full operand held in MDR | `W`-bit RF slices; 32-bit staging stream |
| Execution | `W+1`-bit ALU with carried state across slices | 17-bit ALU produces a full-word result per pass | `W+1`-bit ALU with carried state across 32-bit words |
| PC update | separate `W`-bit PC adder and carry state | uses the main 17-bit ALU | `/1`–`/4`: dedicated `W`-bit adder; `/8`–`/16`: reuse the serial ALU |
| Store data | uses the RF read output | uses the RF read output | RF slices stream through the staging register into two 16-bit writes |

![RISC-C serial multi-cycle datapath](riscc_multicycle_datapath.svg)

### Pipelined cores

Fast overlaps a tagged synchronous fetch with Execute. Its two-read register
file is replicated: it maps to EBRs on iCE40, LUTRAM on ECP5, and MLABs on
Agilex. There is no branch predictor or general forwarding network. The
synchronous iCE40 register file stalls a read-after-write dependency; memory,
shifts, and multiplication use short side states while the normal pipeline is
paused.

Faster separates Fetch, Decode/register-file read, and Execute. Decode drives
two replicated synchronous register files, and their registered outputs feed
Execute. A write-edge bypass handles the normal dependent-writeback case.
Loads, iterative shifts, multiplication, and long forms hold the instruction
and operands in Execute-side states until commit. A registered DSP multiplier
is the default; `RISCC_FASTER_SOFT_MUL` selects the iterative fabric version.

![RISC-C/fast pipeline](riscc16_fast_pipeline.svg)

![RISC-C/faster pipeline](riscc16_faster_pipeline.svg)

### Serial arithmetic variants

The normal Full `/16` controller has an iterative low-half multiplier. The
paired `mulh` variant adds the high-half path, and `muldiv` adds an iterative
divider. Both retain the shared register file, memory port, and multi-cycle
controller; they are area/latency trade-offs rather than separate
high-throughput execution units. Their architectural definition is in the
[ISA specification](RISC-C-ISA.md#appendix-b-multiply-divide-instructions-mdu-extension).

### FPGA targets and build names

The reference targets are iCE40, ECP5, and Agilex 3. RC16 target names follow
`<verb>-<width>-<profile>`; Nano uses `<verb>-nano`. The optional RC16 Full
cores use the `mulh` and `muldiv` suffixes. Examples: `make test-16-sys`,
`make test-16-muldiv`, `make area-2-min`, and `make fmax-8-full`.

## 2. Measurements

### Scope and provenance

The resource figures are **core-only**: they count the register file but
exclude instruction/data memory, peripherals, and board logic. Agilex values
are Quartus post-fit measurements, and Agilex Fmax is a restricted-Fmax
estimate, not timing closure at every listed clock. RC32 Fmax results use one
seed.

Reproduce the tables with:

```sh
make -j16 tables-lattice
```

Include Agilex 3 by providing Quartus Pro:

```sh
make -j16 QUARTUS_SH=/path/to/quartus/bin/quartus_sh tables
```

### Area

| iCE40 LUT4 (+ 1 RF EBR) | /1 | /2 | /4 | /8 | /16 |
|---|---:|---:|---:|---:|---:|
| `min` | 119 | 133 | 161 | 216 | 258 |
| `sys` | 145 | 157 | 186 | 243 | 278 |
| `full` | 171 | 188 | 232 | 297 | 335 |
| RC32 `min` | 145 | 154 | 179 | 222 | 305 |
| RC32 `sys` | 170 | 179 | 207 | 265 | 338 |

| ECP5 LUT sites (LUTRAM RF included) | /1 | /2 | /4 | /8 | /16 |
|---|---:|---:|---:|---:|---:|
| `min` | 164 | 180 | 201 | 252 | 286 |
| `sys` | 182 | 198 | 226 | 279 | 305 |
| `full` | 209 | 231 | 270 | 333 | 360 |
| RC32 `min` | 229 | 242 | 264 | 293 | 373 |
| RC32 `sys` | 257 | 270 | 286 | 338 | 404 |

| ECP5 LUT4 (+ 1 RF EBR) | /1 | /2 | /4 | /8 | /16 |
|---|---:|---:|---:|---:|---:|
| `min` | 121 | 140 | 165 | 220 | 261 |
| `sys` | 140 | 158 | 190 | 245 | 281 |
| `full` | 166 | 190 | 234 | 300 | 336 |
| RC32 `min` | 149 | 162 | 189 | 234 | 307 |
| RC32 `sys` | 174 | 189 | 210 | 269 | 338 |

On iCE40, RC32 Min uses 3–22% more LUT4 than RC16 Min at the same width.
RC32 Sys uses 25–43 more LUT4 than RC32 Min.

| Agilex 3 ALMs (MLAB RF included) | /1 | /2 | /4 | /8 | /16 |
|---|---:|---:|---:|---:|---:|
| `min` | 93.7 | 100.1 | 108.0 | 120.1 | 118.0 |
| `sys` | 104.1 | 106.9 | 120.7 | 137.7 | 150.7 |
| `full` | 100.8 | 121.9 | 127.8 | 148.6 | 170.8 |
| RC32 `min` | 115.7 | 127.5 | 137.1 | 144.3 | 188.5 |
| RC32 `sys` | 134.1 | 132.5 | 150.1 | 167.9 | 198.7 |

| Other implementation area | UP5K LUT4, RF EBR separate | ECP5 LUT sites, RF included | Agilex 3 ALM, RF included |
|---|---:|---:|---:|
| nano | 94 | 115 | 88.4 |
| Full paired MulH `/16` | 346 | 370 | 179.6 |
| Full paired MulDiv `/16` | 374 | 401 | 202.6 |
| Fast soft | 486 | 536 | 271.3 |
| Fast DSP | 454 | 488 | 262.4 |
| Faster DSP | 668 | 734 | 318.5 |
| Faster soft | 726 | 812 | 342.6 |

The table headings state whether LUT/ALM values include the register file. On
iCE40, Nano and paired Full use one RF EBR, while Fast and Faster use two.
DSP-named rows use one DSP. Instruction/data memory and peripherals are
excluded.

### Clock rate and benchmark throughput

| UP5K Fmax (MHz, EBR RF) | /1 | /2 | /4 | /8 | /16 |
|---|---:|---:|---:|---:|---:|
| `min` | 36.39 | 34.95 | 32.01 | 29.34 | 27.77 |
| `sys` | 35.63 | 32.19 | 32.17 | 28.86 | 29.25 |
| `full` | 34.19 | 30.73 | 30.50 | 28.13 | 27.52 |
| RC32 `min` | 36.61 | 29.11 | 25.70 | 28.00 | 25.04 |
| RC32 `sys` | 34.60 | 29.34 | 27.84 | 27.12 | 26.16 |

| ECP5 Fmax (MHz, LUTRAM RF) | /1 | /2 | /4 | /8 | /16 |
|---|---:|---:|---:|---:|---:|
| `min` | 104.44 | 104.94 | 88.72 | 76.07 | 89.18 |
| `sys` | 107.87 | 106.88 | 93.53 | 86.60 | 87.23 |
| `full` | 94.93 | 95.16 | 84.76 | 76.75 | 84.23 |
| RC32 `min` | 99.22 | 92.34 | 81.68 | 78.64 | 76.86 |
| RC32 `sys` | 94.84 | 94.56 | 88.12 | 81.48 | 79.96 |

| Agilex 3 Fmax (MHz, MLAB RF) | /1 | /2 | /4 | /8 | /16 |
|---|---:|---:|---:|---:|---:|
| `min` | 323.42 | 317.76 | 289.44 | 278.71 | 270.12 |
| `sys` | 308.64 | 290.78 | 264.62 | 268.67 | 245.04 |
| `full` | 304.79 | 313.28 | 313.68 | 283.37 | 245.46 |
| RC32 `min` | 300.39 | 290.53 | 268.67 | 255.36 | 244.80 |
| RC32 `sys` | 269.11 | 284.90 | 269.91 | 254.13 | 235.79 |

| Other implementation routed Fmax (MHz) | UP5K, EBR RF | ECP5, LUTRAM RF | Agilex 3, MLAB RF |
|---|---:|---:|---:|
| nano | 34.27 | 99.73 | 306.28 |
| Full paired MulH `/16` | 26.94 | 84.90 | 246.67 |
| Full paired MulDiv `/16` | 23.38 | 82.64 | 244.80 |
| Fast soft | 24.67 | 70.86 | 191.83 |
| Fast DSP | 24.25 | 68.68 | 145.94 |
| Faster DSP | 22.84 | 66.03 | 236.24 |
| Faster soft | 23.69 | 74.60 | 247.34 |

Each throughput entry combines the listed Fmax with the measured cycles of a
common benchmark. The serial columns use the `sys` area/Fmax point. Fast uses
its synchronous-RF cycle count on iCE40 and its generic cycle count on ECP5
and Agilex; Faster uses its common pipeline cycle count on all three families.

| Benchmark MIPS | /1 | /2 | /4 | /8 | /16 | nano | fast soft | fast DSP | faster DSP | faster soft |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| iCE40 UP5K | 1.01 | 1.68 | 2.87 | 4.02 | 7.02 | 1.10 | 11.04 | 12.51 | 13.47 | 12.01 |
| ECP5 | 3.06 | 5.56 | 8.35 | 12.08 | 20.93 | 3.21 | 39.76 | 46.85 | 38.94 | 37.82 |
| Agilex 3 | 8.75 | 15.14 | 23.62 | 37.47 | 58.80 | 9.86 | 107.63 | 99.55 | 139.31 | 125.39 |

| Benchmark MIPS per thousand logic units | /1 | /2 | /4 | /8 | /16 | nano | fast soft | fast DSP | faster DSP | faster soft |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| iCE40 UP5K, LUT4 | 7.0 | 10.7 | 15.4 | 16.6 | 25.2 | 11.7 | 22.7 | 27.6 | 20.2 | 16.5 |
| ECP5, LUTRAM RF sites | 16.8 | 28.1 | 36.9 | 43.3 | 68.6 | 27.9 | 74.2 | 96.0 | 53.0 | 46.6 |
| Agilex 3, ALM | 84.0 | 141.6 | 195.7 | 272.1 | 390.1 | 111.6 | 396.7 | 379.4 | 437.4 | 366.0 |

The common benchmark retires 3238 instructions; Nano's software-multiply
version retires 8491. For versions with different dynamic instruction counts,
Fmax divided by benchmark cycles is the fixed-workload throughput measure.

### Benchmark cycles

| Common benchmark cycles | /1 | /2 | /4 | /8 | /16 | nano | fast soft | fast DSP | faster DSP | faster soft |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `test_riscc_bench` | 114228 | 62196 | 36276 | 23220 | 13495 | 263691 | 5771 | 4747 | 5491 | 6387 |

The iCE40 Fast cycle counts are 7236 (soft multiply) and 6276 (DSP multiply)
for the synchronous-EBR register-file configuration.

### Arithmetic-option cycles

This RTL-cycle comparison uses the baseline Full `/16` core and its MulDiv
variant at `-O2`. Their area and Fmax are reported in the tables above.

| Compiler benchmark | Full cycles | Full + MulDiv cycles | cycle change |
|---|---:|---:|---:|
| `int32` | 218649 | 205597 | -5.97% |
| `softfloat` | 540249 | 512180 | -5.20% |
| `libm32` | 42025 | 40858 | -2.78% |
| `matrix` | 268233 | 234811 | -12.46% |
| `structures` | 11441 | 11441 | 0.00% |
| all five workloads | 1080597 | 1004887 | -7.01% |

This is a cycle comparison; use the routed Fmax table when judging elapsed
time for a target FPGA.

## 3. FPGA toolchain

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

When installed, ccache accelerates generated Verilator C++, the C++ ISS, and
the LLVM host build. Yosys synthesis is not a ccache workload.

## 4. Validation

```sh
make test-all
make test-compiler
make fuzz-all
make -j16 QUARTUS_SH=/opt/intelFPGA_pro/26.1/quartus/bin/quartus_sh tables
```

`test-all` runs the serial RC16 matrix, Nano, optional MulH/MulDiv cores, RC32
Min at every width, every Fast target variant, and both Faster variants.
`test-compiler` adds compiler, libc, Nano compiler/RTL, and encoding tests.
`fuzz-all` differentially compares self-checking generated programs between
the ISS and trace-enabled RTL, reporting a replay command for any failure.

Trace targets (`trace-nano`, `trace-<width>-<profile>`, and `trace-fast`)
record architectural state and written memory after every instruction. Use
them to locate the first divergent instruction when a differential test fails.

## 5. Board builds and demos

Each board SoC provides:

- on-chip program/data RAM;
- a 4-bit framebuffer and board-local video output;
- a UART, a 1 kHz timer, and a two-source interrupt controller; and
- LED outputs and button inputs.

The shared software-visible map is:

| Byte address or range | Demo function |
|---:|---|
| `0x0000..0x7fff` | Icepi unified program/data RAM |
| `0x0000..0x5fff` | Atum unified program/data RAM |
| `0x8000..0xffee` | Icepi framebuffer aperture; its first 14,400 words are the displayed 320x180 framebuffer, four adjacent 4-bit pixels per 16-bit word; CPU writes only |
| `0x6000..0xd07f` | Atum displayed 320x180 framebuffer: four adjacent 4-bit pixels per 16-bit word; CPU writes only |
| `0xfff0..0xfff2` | UART; see the [Programming manual](PROGRAMMING.md#1-software-tools-and-the-iss) for register semantics |
| `0xfff4` | timer: write a non-zero 1 kHz delay to arm/rearm; read the free-running 16-bit millisecond tick counter |
| `0xfff6` | interrupt state: read pending UART/timer bits 0/1; write enable mask |
| `0xfff8` | LED output; Icepi uses five low bits and Atum uses four |

Both active framebuffers use 14,400 16-bit words. The rest of the Icepi
framebuffer aperture is reserved; only `0xfff0..0xffff` is MMIO. The UART
divisor is board-local. [`<riscc/platform.h>`](../firmware/include/riscc/platform.h)
defines the shared C interface.

The interrupt controller is a two-bit level mask for UART and timer sources.
It has no priority, vectoring, edge capture, or acknowledgement register. The
timer uses a board-local 1 kHz timebase, and both boards retain the fixed
RISC-C IRQ vector.

### Icepi Zero

The Icepi demo is in [`boards/icepi_zero`](../boards/icepi_zero). It uses a
50 MHz Fast SoC, a 320x180 4-bit framebuffer scaled to 640x480 DVI, UART,
LEDs, buttons, and freestanding C++ Julia-set firmware. The complete ECP5
design uses 902 LUT4s, 32 EBRs, and one DSP block. Its PLL, TMDS encoder, and
DDR serializer are maintained in-tree.

```sh
make icepi-zero-demo-iss
make icepi-zero-demo-iss-test
make icepi-zero-demo-rtlsim
make icepi-zero-demo-bit
```

The default shared source is
[`demo.cpp`](../boards/shared/sw/demo.cpp), compiled as freestanding C++
without a C++ standard library, exceptions, RTTI, or constructors. For an
alternate C++ or assembly image on both boards, set `DEMO_PROGRAM`. Set
`ICEPI_PROGRAM` or `ATUM_PROGRAM` to override only that board.

The bit target only builds a bitstream. Load it temporarily through SRAM with:

```sh
openFPGALoader -cft231X --pins=7:3:5:6 build/icepi_zero/demo.bit
```

![Video capture of RISC-C running on Icepi Zero](riscc_on_icepi-zero.jpg)

*Video capture of RISC-C running on the Icepi Zero FPGA board.*

### Terasic Atum A3 Nano

[`boards/atum_a3_nano`](../boards/atum_a3_nano) is the Quartus Pro Agilex 3
demo. It combines a Faster SoC, UART, on-chip program RAM, and a 320x180
4-bit framebuffer expanded to 1920x1080p60 through the TFP410. Firmware, ISS,
and RTL simulation use the same freestanding C++ demo as Icepi, with an
Atum-specific banner:

```sh
make atum-a3-demo-bin
make atum-a3-demo-iss
make atum-a3-demo-rtlsim
```

Generating a `.sof` needs Quartus Pro with Agilex 3 device support:

```sh
make atum-a3-demo
```

The staged project and `.sof` live under `build/atum_a3_nano/quartus`. JTAG
configuration is temporary and leaves the QSPI flash unchanged:

```sh
quartus_pgm -l
quartus_pgm -c "Atum A3 Nano [USB-0]" -m jtag \
  -o "p;build/atum_a3_nano/quartus/output_files/atum_a3_nano.sof"
```

The Quartus Pro 26.1 post-fit design uses 719.3 ALMs, 27 M20K blocks, one DSP
block, and two IOPLLs. The 148.5 MHz pixel clock meets timing. The 225 MHz
system target has not closed timing; its current restricted Fmax is 195.47 MHz.
Persistent QSPI programming is outside the normal flow; see Terasic's
[Atum A3 Nano documentation](https://www.terasic.com.tw/cgi-bin/page/archive.pl?CategoryNo=44&Language=English&No=1373&PartNo=4).

![Video capture of RISC-C running on Atum A3 Nano](riscc_on_atum-a3.jpg)

*Video capture of RISC-C running on the Atum-A3-Nano FPGA board.*

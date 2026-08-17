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

### FPGA build selection

The reference targets are iCE40, ECP5, and Agilex 3. A single-case build uses
named axes instead of a separate target for every combination. For example:

Run `make help` for the complete list of user targets and selection variables.

```sh
make test-core PROFILE=sys WIDTH=16 MODE=native
make test-extension EXTENSION=muldiv MODE=ecp5-lutram
make trace PROFILE=min WIDTH=2
make test-fast MEMORY=ice40 MULTIPLIER=dsp
```

Aggregate targets such as `test-cores`, `test-extensions`, `area-lattice`, and
`fmax-lattice` iterate the profile, width, memory, and multiplier lists.

## 2. Measurements

### Scope and provenance

The resource figures are **core-only**: they count the register file but
exclude instruction/data memory, peripherals, and board logic. Agilex values
are Quartus post-fit measurements, and Agilex Fmax is a restricted-Fmax
estimate, not timing closure at every listed clock. Lattice tables select the
smallest area recipe and the fastest recipe/seed from the recorded tuning
matrix. Agilex runs use seed 1 and a 4 ns target; Quartus uses Aggressive Area
for the Full family, including MulH and MulDiv, and High Performance Effort for
the other cores.

Reproduce the tables with:

```sh
make -j16 tables-lattice
```

This searches 10 routing seeds by default. Set `TUNE_SEEDS=128` for a larger
search; selected recipes, options, and seeds are recorded in
`build/tune/{ice40,ecp5}/best.tsv`.

Include Agilex 3 by providing Quartus Pro:

```sh
make -j16 QUARTUS_SH=/path/to/quartus/bin/quartus_sh tables
```

Run a focused or whole-matrix tuning search directly with:

```sh
python3 tools/lattice_tune.py ice40 full --width 4 --seeds 128 -j 16
python3 tools/lattice_tune.py ecp5 sys --width 8 --seeds 128 -j 16
python3 tools/lattice_tune.py ice40 all --seeds 128 -j 16
```

Each mapper recipe is synthesized once, its seeds are routed in parallel, and
the script reports the best seed per recipe plus the smallest, fastest, and
best-MHz-per-LUT choices. All results are written under `build/tune/` as TSV;
add `--resume` to continue an interrupted whole-matrix run.

### Area

| iCE40 LUT4 (+ 1 RF EBR) | /1 | /2 | /4 | /8 | /16 |
|---|---:|---:|---:|---:|---:|
| `min` | 119 | 133 | 161 | 216 | 258 |
| `sys` | 144 | 159 | 189 | 246 | 278 |
| `full` | 173 | 190 | 230 | 297 | 334 |
| RC32 `min` | 145 | 153 | 181 | 222 | 305 |
| RC32 `sys` | 170 | 179 | 209 | 264 | 338 |

| ECP5 LUT sites (LUTRAM RF included) | /1 | /2 | /4 | /8 | /16 |
|---|---:|---:|---:|---:|---:|
| `min` | 162 | 177 | 201 | 252 | 285 |
| `sys` | 182 | 201 | 228 | 281 | 305 |
| `full` | 210 | 232 | 268 | 333 | 360 |
| RC32 `min` | 228 | 241 | 260 | 293 | 373 |
| RC32 `sys` | 254 | 270 | 286 | 338 | 404 |

| ECP5 LUT4 (+ 1 RF EBR) | /1 | /2 | /4 | /8 | /16 |
|---|---:|---:|---:|---:|---:|
| `min` | 121 | 137 | 165 | 220 | 263 |
| `sys` | 140 | 161 | 192 | 248 | 281 |
| `full` | 167 | 191 | 232 | 300 | 336 |
| RC32 `min` | 149 | 161 | 186 | 228 | 307 |
| RC32 `sys` | 174 | 189 | 210 | 268 | 338 |

On iCE40, RC32 Min uses 3–22% more LUT4 than RC16 Min at the same width.
RC32 Sys uses 25–42 more LUT4 than RC32 Min.

| Agilex 3 ALMs (MLAB RF included) | /1 | /2 | /4 | /8 | /16 |
|---|---:|---:|---:|---:|---:|
| `min` | 95.1 | 101.4 | 109.6 | 128.6 | 125.5 |
| `sys` | 101.8 | 106.5 | 120.7 | 137.7 | 136.5 |
| `full` | 106.5 | 118.8 | 124.9 | 152.6 | 169.8 |
| RC32 `min` | 115.7 | 127.5 | 137.1 | 144.3 | 188.5 |
| RC32 `sys` | 135.1 | 132.9 | 150.1 | 167.7 | 199.2 |

| Other implementation area | UP5K LUT4, RF EBR separate | ECP5 LUT sites, RF included | Agilex 3 ALM, RF included |
|---|---:|---:|---:|
| nano | 94 | 115 | 90.2 |
| Full paired MulH `/16` | 344 | 370 | 179.6 |
| Full paired MulDiv `/16` | 374 | 401 | 202.6 |
| Fast soft | 486 | 517 | 271.3 |
| Fast DSP | 454 | 488 | 262.2 |
| Faster DSP | 664 | 721 | 318.5 |
| Faster soft | 703 | 790 | 342.6 |

The table headings state whether LUT/ALM values include the register file. On
iCE40, Nano and paired Full use one RF EBR, while Fast and Faster use two.
DSP-named rows use one DSP. Instruction/data memory and peripherals are
excluded.

### Clock rate and benchmark throughput

| UP5K Fmax (MHz, EBR RF) | /1 | /2 | /4 | /8 | /16 |
|---|---:|---:|---:|---:|---:|
| `min` | 36.70 | 35.11 | 35.09 | 29.93 | 30.41 |
| `sys` | 36.26 | 34.18 | 33.26 | 29.39 | 30.44 |
| `full` | 34.25 | 32.95 | 29.06 | 28.52 | 28.62 |
| RC32 `min` | 37.76 | 31.27 | 28.15 | 28.88 | 26.07 |
| RC32 `sys` | 34.95 | 29.91 | 29.36 | 29.30 | 26.16 |

| ECP5 Fmax (MHz, LUTRAM RF) | /1 | /2 | /4 | /8 | /16 |
|---|---:|---:|---:|---:|---:|
| `min` | 113.40 | 111.93 | 98.14 | 89.08 | 92.58 |
| `sys` | 111.96 | 109.55 | 99.08 | 90.66 | 93.77 |
| `full` | 106.16 | 105.91 | 91.07 | 83.96 | 91.63 |
| RC32 `min` | 101.96 | 99.86 | 93.14 | 87.97 | 83.57 |
| RC32 `sys` | 102.76 | 101.48 | 93.48 | 86.33 | 82.07 |

| Agilex 3 Fmax (MHz, MLAB RF) | /1 | /2 | /4 | /8 | /16 |
|---|---:|---:|---:|---:|---:|
| `min` | 326.05 | 317.06 | 289.77 | 264.90 | 269.03 |
| `sys` | 300.12 | 313.87 | 264.62 | 276.78 | 251.51 |
| `full` | 266.10 | 276.09 | 285.39 | 268.60 | 248.88 |
| RC32 `min` | 300.39 | 290.53 | 268.67 | 255.36 | 244.80 |
| RC32 `sys` | 283.61 | 282.01 | 269.91 | 274.42 | 255.23 |

| Other implementation routed Fmax (MHz) | UP5K, EBR RF | ECP5, LUTRAM RF | Agilex 3, MLAB RF |
|---|---:|---:|---:|
| nano | 35.21 | 124.25 | 336.25 |
| Full paired MulH `/16` | 27.58 | 87.33 | 246.67 |
| Full paired MulDiv `/16` | 24.79 | 84.94 | 244.80 |
| Fast soft | 26.00 | 76.20 | 191.83 |
| Fast DSP | 24.75 | 76.48 | 145.03 |
| Faster DSP | 22.84 | 75.76 | 236.24 |
| Faster soft | 23.99 | 79.78 | 247.34 |

Each throughput entry combines the listed Fmax with the measured cycles of a
common benchmark. The serial columns use the `sys` area/Fmax point. Fast uses
its synchronous-RF cycle count on iCE40 and its generic cycle count on ECP5
and Agilex; Faster uses its common pipeline cycle count on all three families.

| Benchmark MIPS | /1 | /2 | /4 | /8 | /16 | nano | fast soft | fast DSP | faster DSP | faster soft |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| iCE40 UP5K | 1.03 | 1.78 | 2.97 | 4.10 | 7.30 | 1.13 | 11.63 | 12.77 | 13.47 | 12.16 |
| ECP5 | 3.17 | 5.70 | 8.84 | 12.64 | 22.50 | 4.00 | 42.75 | 52.17 | 44.68 | 40.45 |
| Agilex 3 | 8.51 | 16.34 | 23.62 | 38.60 | 60.35 | 10.83 | 107.63 | 98.93 | 139.31 | 125.39 |

The Lattice area and Fmax tables are independent optima and can select
different synthesis parameters. Each Lattice efficiency entry instead uses a
single recipe and seed selected for maximum routed Fmax divided by that same
recipe's area; it does not divide the separately fastest and smallest results.

| Benchmark MIPS per thousand logic units | /1 | /2 | /4 | /8 | /16 | nano | fast soft | fast DSP | faster DSP | faster soft |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| iCE40 UP5K, LUT4 | 6.9 | 10.2 | 14.0 | 15.6 | 25.0 | 10.5 | 22.9 | 27.1 | 20.3 | 16.5 |
| ECP5, LUTRAM RF sites | 17.3 | 27.9 | 37.5 | 41.8 | 71.4 | 31.5 | 80.8 | 106.9 | 59.8 | 49.9 |
| Agilex 3, ALM | 83.6 | 153.4 | 195.7 | 280.3 | 442.1 | 120.0 | 396.7 | 377.3 | 437.4 | 366.0 |

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

`test-all` runs the RC16 matrix, Nano, optional MulH/MulDiv cores, RC32
Min and Sys at every width, every Fast target variant, and both Faster variants.
`test-compiler` adds compiler, libc, Nano compiler/RTL, and encoding tests.
`fuzz-all` differentially compares self-checking generated programs between
the ISS and trace-enabled RTL, reporting a replay command for any failure.

Trace targets (`trace PROFILE=<profile> WIDTH=<width>`, `trace-nano`, and
`trace-fast`) record architectural state and written memory after every
instruction. Use them to locate the first divergent instruction when a
differential test fails.

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
without a C++ standard library, exceptions, RTTI, or constructors. Set
`DEMO_PROGRAM` to use another C++ source on both boards, or `ICEPI_PROGRAM`
or `ATUM_PROGRAM` to override one board.

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

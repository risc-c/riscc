# RISC-C Hardware Manual

This manual describes the cores, memory interfaces, FPGA measurements, and
board builds. See the [ISA specification](RISC-C-ISA.md) for instructions and
the [Programming manual](PROGRAMMING.md) for software development.

## 1. Implementation family

RISC-C has serial, full-width multicycle, and pipelined implementations.
Serial cores process a register in slices; wide cores process a whole register
at once. Fast overlaps instruction fetch, decode, and execution.
Every core uses one synchronous, unified
memory port for instruction fetches and data transfers. The
[ISA specification](RISC-C-ISA.md) defines the architectural configurations;
this section describes how the RTL realizes them.

### Core families

| Implementation | Microarchitecture | RTL |
|---|---|---|
| Nano | fixed one-bit serial controller and register file | [`riscc_nano.v`](../rtl/riscc_nano.v) |
| RC16 serial `/1`–`/8` | `W`-bit sliced ALU and one-port register file; `XLEN=16` | [`riscc_serial.v`](../rtl/riscc_serial.v) |
| RC32 serial `/1`–`/16` | `W`-bit sliced ALU over a 16-bit memory port; `XLEN=32` | [`riscc_serial.v`](../rtl/riscc_serial.v) |
| RC16 `/16`, RC32 `/32` | full-width multicycle ALU; Min/Sys/Full and optional MDU | [`riscc_wide.v`](../rtl/riscc_wide.v) |
| Fast | RC16/RC32 Full, three-stage Fetch/Decode/Execute pipeline | [`riscc_fast.v`](../rtl/riscc_fast.v) |

### External memory interfaces

Directions are relative to the core.

| Signal | Direction | Width | Cores | Meaning |
|---|---|---:|---|---|
| `mem_addr` | output | 15 or 31 | all | Halfword address; RC32 uses 31 bits, RC16 and Nano use 15 |
| `mem_rdata` | input | 16 | all | Read data |
| `mem_wdata` | output | 16 | all | Write data |
| `mem_wmask` | output | 2 | all | Enables the low and high byte lanes |
| `mem_we` | output | 1 | all | Write direction; a one-cycle write strobe on Nano |
| `mem_valid` | output | 1 | except Nano | Request is active |
| `mem_ready` | input | 1 | except Nano | Completes the request; read data is valid |
| `mem_oe_n` | output | 1 | Nano | Active-low read enable |

On RC16, RC32, and Fast, `mem_valid` starts a transfer. The core holds
the address, direction, byte enables, and write data stable until
`mem_ready`. Only one transfer can be outstanding. Halfword accesses enable
both byte lanes; byte accesses enable the addressed lane only.

This handshake is compatible with a small subset of Wishbone B4 Classic:
`mem_addr` maps to `ADR`, `mem_rdata` and `mem_wdata` to `DAT`, `mem_wmask` to
`SEL`, `mem_we` to `WE`, `mem_valid` to both `CYC` and `STB`, and `mem_ready`
to `ACK`. A zero-wait target may tie `mem_ready` high. Bursts, pipelined
transfers, `ERR`, and `RTY` are not supported. Interface outputs are don't-care
when `mem_valid` is low.

Nano keeps a smaller synchronous-SRAM interface. `mem_oe_n` is the active-low
read enable, and `mem_we` is a one-cycle write enable. Memory returns read data
on the next cycle and must hold it while Nano serializes the 16-bit value.
There is no acknowledge signal or wait-state support. Qualify MMIO read side
effects with `!mem_oe_n` and writes with `mem_we`; address decoding alone can
repeat an access while the address is held.

The sliced cores hold their request state until `mem_ready`, then latch each
16-bit read and consume it a slice at a time. Fast freezes its
pipeline while a request waits. Fast samples its level IRQ only on a core-advance
boundary, so an outstanding memory transfer completes before interrupt entry.
The in-tree SoCs acknowledge their synchronous RAM and MMIO one cycle after
the request. Random-stall tests check both delayed responses and request
stability.

### Serial cores

`riscc_serial` implements RC16 `/1` through `/8` and RC32 `/1` through `/16`
for Min, Sys, and Full. `XLEN` selects 16- or 32-bit registers; `W` is a
power of two smaller than `XLEN`, up to 16. `PROFILE=0/1/2` selects
Min/Sys/Full, and `RESET_PC` is an `XLEN`-bit byte address. Min ignores `irq`;
Sys and Full sample it between instructions.

The core streams each word through a `W`-bit ALU, least-significant slice
first. Its synchronous register file has one read port and one write port;
reads run one slice ahead of consumption. Register-register operations stage
one operand in `data_q` before reading the other. The ALU forms arithmetic
results, comparisons, and effective addresses. `address_q` holds the memory
address, and `response_q` captures each 16-bit memory response.

The normal flow is `FETCH → DECODE → [STAGE] → [PREPARE] → EXECUTE → FETCH`.
`FETCH` accepts the instruction, and `DECODE` selects the required passes or
interrupt entry. `STAGE` fills the operand buffer; `PREPARE` forms an address,
compares operands, or initializes multiplication. Each pass visits all
`XLEN/W` slices. `EXECUTE` writes the result and advances PC.

Memory instructions add `MEMORY`, which waits for acknowledgement, and
`TRANSFER`, which moves slices between the RF and memory buffers. Loads follow
`PREPARE → MEMORY → TRANSFER` and write the response directly to the RF.
Stores follow `PREPARE → TRANSFER → MEMORY`, assembling a halfword in
`data_q` before issuing it. Native RC32 loads and stores repeat the memory
transfer for the second halfword. Long jumps also use these states to fetch
and stage their literal target before the final `EXECUTE` pass.

At `W < 8`, a separate `W`-bit adder updates PC alongside the data pass. At
`W >= 8`, PC updates reuse the ALU in a separate execution pass, except that
RC16 Full retains its separate PC adder. RC32 LDPC uses the PC arithmetic
path during `PREPARE` to form its load address and temporarily update PC;
after the load, it subtracts the displacement to restore the next PC. Narrow
configurations use the dedicated PC adder for this sequence, and wide ones
use the shared ALU.

R0 writes maintain saved zero and sign predicates for conditional branches.
Byte-lane selection and funnel shifts share a saved low bit of ra; left
funnels carry ra's high bit into the result. Full repeats `EXECUTE` for
fixed-count shifts and low-half multiplication. MUL accumulates in rd,
shifts ra in `data_q`, and holds rb in `address_q`, using one add/shift pass
per multiplier bit and a single-bit multiplier latch. Only Full recycles
shift results.

Nano is a fixed `/1` design with its own one-bit register file, decode, and
instruction schedule.

RC16 `/16` and RC32 `/32` use `riscc_wide`, which reads and processes a
complete register word at a time. All forms use one RF read port and one
write port.

| Structure | RC16 `/1`–`/8` | RC32 `/1`–`/16` | RC16 `/16`, RC32 `/32` |
|---|---|---|---|
| Operand staging | `W`-bit slices through a 16-bit register | `W`-bit slices through a 32-bit register | complete `XLEN`-bit operand in `data_q` |
| ALU | `W+1` bits; carry between slices | `W+1` bits; carry between slices | `XLEN+1` bits |
| PC update | separate adder at `/1`–`/4` and Full `/8`; Min/Sys `/8` share the ALU | separate adder at `/1`–`/4`; `/8`–`/16` share the ALU | shares the ALU |
| Store data | RF slices assemble one halfword | RF slices assemble two successive halfwords | RF read output; two beats for a native RC32 word |

### Parameterized full-width core

`riscc_wide` uses one `XLEN`-bit datapath and a synchronous register file.
`XLEN=16/32` selects the architecture; `PROFILE=0/1/2` selects Min/Sys/Full.
`RESET_PC` is a byte address. The Full profile supports three arithmetic
options on both architectures:

| Variant | Parameter | Multiply/divide instructions |
|---|---|---|
| Full | `MDU=0` | MUL |
| Full + MulH | `MDU=1` | MUL, MULHU |
| Full + MulDiv | `MDU=2` | MUL, MULHU, DIVU |

The [ISA specification](RISC-C-ISA.md#appendix-b-multiply-divide-instructions-mdu-extension)
defines the paired-register results of MULHU and DIVU.

Decode advances PC and reads the first operand. Two-source instructions
save that operand in `data_q`, then read the other for execution. The same
adder handles PC, addresses, arithmetic and multiply; logical results and
right shifts pass through it with A cleared. Boolean operations share two
control bits decoded before Execute. RC32 records R0's zero condition per
nibble, then combines those flags for branches to shorten the carry path.

Loads keep their address in `data_q` and assemble the response in
`scratch_q`, which also holds the multiply accumulator. RC32 preserves the
first halfword there while the second arrives. The address supplies the
byte lane directly. Stores keep their source register on the RF read port
through both memory beats.

MUL takes one add/shift step per bit. MULHU writes the saved high word to
`ra`, then the low word to `rd`. DIVU keeps quotient and remainder in the RF
and uses three clocks per bit: shift quotient, test shifted remainder minus
divisor, then commit the shift or subtraction. The subtraction decision is
registered before writeback. Without DIVU's shifted ALU input, FSL1 uses two
additions; with it, FSL1 completes in one execution clock.

The RC16 `/16`, RC32 `/32`, and arithmetic-extension targets use this module. Select RC32 or
an explicit MDU setting with `test-wide`:

```sh
make test-wide XLEN=32 PROFILE=full MDU=2 MODE=ecp5-block
make test-core PROFILE=sys WIDTH=16
make test-extension EXTENSION=mulh
make -j16 test-wide-all
make fuzz-wide fuzz-wide32
python3 tools/lattice_tune.py ecp5 wide16-full --seeds 32 -j 16
```

### Pipelined core

`riscc_fast` implements Full with `XLEN=16` or `XLEN=32` (default: 16).
Its memory port is 16 bits wide; `RESET_PC` is a halfword address.
RC32 native loads and stores transfer the low halfword first and hold
Execute until the high halfword completes. Interrupts cannot split a word
transfer. Byte and halfword accesses take one beat.

Fast separates Fetch, Decode/register-file read, and Execute. Decode drives
two replicated synchronous register files, and their registered outputs feed
Execute. Write-first registered reads handle the normal dependent-writeback
case; the ECP5 block-RF form folds that choice into the read registers instead
of retaining separate wide bypass state.
Loads complete directly on ACK. The DSP form also completes JALL on ACK and
needs three Execute states in a two-bit state register; the fabric form
retains a fourth state for the registered long target. Iterative shifts and
multiplication hold the instruction and operands in Execute-side states until
commit. Logical, move, and shift results bypass the arithmetic adder.
A registered DSP multiplier is the default. `RISCC_FAST_SOFT_MUL` selects
radix-4 Booth multiplication through the ALU: one setup clock followed by
`XLEN/2` add/shift steps. The next multiplier digit is decoded during the
current step. DSP multiplication takes two Execute clocks at either width.
RC32 registers the low product and the cross-product sum separately, then
adds the upper half at writeback. ECP5 uses one DSP for RC16 and three for RC32.

![RISC-C/fast pipeline](riscc_fast_pipeline.svg)

### FPGA build selection

The reference targets are ECP5 and Agilex 3. Select the profile, datapath
width, and register file with Make variables. `make help` lists the targets
and options.

```sh
make test-core PROFILE=sys WIDTH=16 MODE=native
make test-extension EXTENSION=muldiv MODE=ecp5-lutram
make trace PROFILE=min WIDTH=2
make test-fast XLEN=32 MEMORY=ecp5-block MULTIPLIER=dsp
make test-fast-irq XLEN=32
make fuzz-fast32
make bench-fast32
```

Aggregate targets such as `test-cores`, `test-extensions`, `area-lattice`, and
`fmax-lattice` iterate the profile, width, memory, and multiplier lists.

## 2. Measurements

### Measurement conditions

Area includes the core and register file; it excludes program/data memory,
peripherals, and board logic. `/W` is the datapath width in bits. RC16 `/16`
and RC32 `/32` use `riscc_wide`; smaller widths use `riscc_serial`. MulH and
MulDiv are Full-profile options available only at full width. A dash marks
an unsupported configuration.

ECP5 results target the LFE5U-25F, speed grade 6. Area is the minimum LUT4
site count across mapping recipes. Clock rates are medians over routing
seeds 1–32, or 1–128 for Nano. Serial and wide cores use the minimum block-RF
area, with ties resolved by median Fmax. Fast uses the recipe with
the highest median MIPS per LUT4 site. Efficiency uses the area of that
timed recipe.

Agilex 3 results use Quartus Pro 26.1, seed 1, and a 4 ns target. The recipe
is Aggressive Area for Full, MulH, and MulDiv, and High Performance Effort
for other profiles. ALMs include the MLAB register file. Fmax is the
post-fit restricted-Fmax estimate, not a clock at which timing closure is
guaranteed. One ALM is counted as 2.95 LEs for efficiency.

### Area

| ECP5 LUT4 sites (+ 1 RF EBR) | /1 | /2 | /4 | /8 | /16 | /32 |
|---|---:|---:|---:|---:|---:|---:|
| RC16 Min | 123 | 137 | 169 | 193 | 232 | — |
| RC16 Sys | 145 | 155 | 187 | 221 | 253 | — |
| RC16 Full | 175 | 188 | 228 | 297 | 313 | — |
| RC16 Full + MulH | — | — | — | — | 323 | — |
| RC16 Full + MulDiv | — | — | — | — | 357 | — |
| RC32 Min | 147 | 161 | 184 | 217 | 299 | 382 |
| RC32 Sys | 172 | 181 | 212 | 250 | 335 | 410 |
| RC32 Full | 203 | 220 | 259 | 303 | 430 | 508 |
| RC32 Full + MulH | — | — | — | — | — | 518 |
| RC32 Full + MulDiv | — | — | — | — | — | 569 |

| ECP5 LUT4 sites (LUTRAM RF included) | /1 | /2 | /4 | /8 | /16 | /32 |
|---|---:|---:|---:|---:|---:|---:|
| RC16 Min | 165 | 179 | 206 | 225 | 256 | — |
| RC16 Sys | 187 | 198 | 223 | 255 | 277 | — |
| RC16 Full | 218 | 229 | 264 | 330 | 337 | — |
| RC16 Full + MulH | — | — | — | — | 347 | — |
| RC16 Full + MulDiv | — | — | — | — | 381 | — |
| RC32 Min | 233 | 244 | 260 | 284 | 364 | 430 |
| RC32 Sys | 256 | 265 | 289 | 319 | 401 | 458 |
| RC32 Full | 289 | 305 | 335 | 372 | 496 | 556 |
| RC32 Full + MulH | — | — | — | — | — | 566 |
| RC32 Full + MulDiv | — | — | — | — | — | 617 |

| Agilex 3 ALMs (MLAB RF included) | /1 | /2 | /4 | /8 | /16 | /32 |
|---|---:|---:|---:|---:|---:|---:|
| RC16 Min | 96.4 | 111.0 | 113.3 | 122.0 | 121.8 | — |
| RC16 Sys | 112.6 | 117.8 | 121.7 | 130.2 | 150.3 | — |
| RC16 Full | 107.4 | 115.0 | 123.0 | 143.3 | 153.8 | — |
| RC16 Full + MulH | — | — | — | — | 169.1 | — |
| RC16 Full + MulDiv | — | — | — | — | 178.5 | — |
| RC32 Min | 121.3 | 136.3 | 135.0 | 144.0 | 190.1 | 222.6 |
| RC32 Sys | 130.1 | 143.0 | 150.5 | 159.8 | 219.1 | 237.5 |
| RC32 Full | 130.5 | 143.4 | 150.1 | 171.5 | 223.7 | 251.2 |
| RC32 Full + MulH | — | — | — | — | — | 253.4 |
| RC32 Full + MulDiv | — | — | — | — | — | 261.8 |

| Nano and Fast minimum area | ECP5 block RF LUT4 sites | ECP5 LUTRAM RF sites | Agilex 3 ALM, RF included |
|---|---:|---:|---:|
| Nano | 94 | 115 | 78.9 |
| RC16 Fast DSP | 641 | 684 | 276.9 |
| RC16 Fast soft | 687 | 747 | 313.5 |
| RC32 Fast DSP | 1233 | 1330 | 491.9 |
| RC32 Fast soft | 1293 | 1369 | 580.3 |

ECP5 Nano uses one RF EBR; Fast uses two at either width. Fast DSP uses
one DSP block at XLEN=16 and three at XLEN=32. The LUTRAM column includes
the complete register file.

The Fast DSP builds used for Fmax and efficiency use 670 LUT4 sites for
RC16 and 1241 for RC32. The fabric-MUL timed builds match their minimum area.

### Clock rate

| ECP5 Fmax (MHz, EBR RF) | /1 | /2 | /4 | /8 | /16 | /32 |
|---|---:|---:|---:|---:|---:|---:|
| RC16 Min | 88.16 | 79.58 | 72.38 | 69.91 | 74.73 | — |
| RC16 Sys | 82.78 | 80.24 | 75.44 | 71.01 | 74.28 | — |
| RC16 Full | 78.40 | 78.12 | 71.70 | 68.17 | 74.52 | — |
| RC16 Full + MulH | — | — | — | — | 73.79 | — |
| RC16 Full + MulDiv | — | — | — | — | 72.25 | — |
| RC32 Min | 86.84 | 79.40 | 70.17 | 64.01 | 65.92 | 68.40 |
| RC32 Sys | 80.38 | 78.63 | 73.97 | 63.00 | 65.89 | 71.35 |
| RC32 Full | 75.64 | 81.16 | 71.47 | 63.83 | 67.99 | 72.37 |
| RC32 Full + MulH | — | — | — | — | — | 73.19 |
| RC32 Full + MulDiv | — | — | — | — | — | 71.35 |

| Agilex 3 Fmax (MHz, MLAB RF) | /1 | /2 | /4 | /8 | /16 | /32 |
|---|---:|---:|---:|---:|---:|---:|
| RC16 Min | 314.47 | 301.30 | 266.88 | 270.86 | 273.75 | — |
| RC16 Sys | 318.07 | 308.17 | 282.33 | 273.37 | 260.96 | — |
| RC16 Full | 290.44 | 279.49 | 265.04 | 262.33 | 223.61 | — |
| RC16 Full + MulH | — | — | — | — | 245.28 | — |
| RC16 Full + MulDiv | — | — | — | — | 242.31 | — |
| RC32 Min | 301.66 | 283.53 | 268.46 | 261.78 | 238.04 | 239.06 |
| RC32 Sys | 295.07 | 287.85 | 273.30 | 267.17 | 253.23 | 247.89 |
| RC32 Full | 267.31 | 291.63 | 267.45 | 243.96 | 217.49 | 213.77 |
| RC32 Full + MulH | — | — | — | — | — | 205.80 |
| RC32 Full + MulDiv | — | — | — | — | — | 218.25 |

| Other implementation Fmax (MHz) | ECP5 median, EBR RF | Agilex 3, MLAB RF |
|---|---:|---:|
| Nano | 87.11 | 291.80 |
| RC16 Fast DSP | 55.46 | 244.50 |
| RC16 Fast soft | 51.61 | 250.06 |
| RC32 Fast DSP | 50.39 | 215.75 |
| RC32 Fast soft | 49.76 | 222.97 |

### RC16 benchmark throughput

`test_riscc_bench` retires 3238 instructions. Nano runs a software-multiply
version with 8491 instructions. MIPS uses each version's instruction count;
compare elapsed time when judging the same workload across those versions.
The benchmark uses MUL but does not exercise MULHU or DIVU.

Throughput combines the clock rates above with the Verilator cycle counts
below. ECP5 uses the block RF. All cores have the same cycle count on both targets.

| Core | ECP5 MIPS | Agilex MIPS | ECP5 MIPS/kLUT4 | Agilex MIPS/kLE |
|---|---:|---:|---:|---:|
| RC16 Full /1 | 2.29 | 8.47 | 13.1 | 26.7 |
| RC16 Full /2 | 4.28 | 15.33 | 22.8 | 45.2 |
| RC16 Full /4 | 7.03 | 25.98 | 30.8 | 71.6 |
| RC16 Full /8 | 11.02 | 42.41 | 37.1 | 100.3 |
| RC16 Full /16 | 24.76 | 74.29 | 79.1 | 163.7 |
| RC16 Full + MulH /16 | 24.52 | 81.49 | 75.9 | 163.4 |
| RC16 Full + MulDiv /16 | 24.00 | 80.50 | 67.2 | 152.9 |
| Nano | 2.80 | 9.40 | 29.8 | 40.4 |
| RC16 Fast DSP | 37.32 | 164.56 | 55.7 | 201.5 |
| RC16 Fast soft | 31.77 | 153.96 | 46.2 | 166.5 |

| Core | ECP5 cycles | Agilex cycles |
|---|---:|---:|
| RC16 Full /1 | 111084 | 111084 |
| RC16 Full /2 | 59052 | 59052 |
| RC16 Full /4 | 33036 | 33036 |
| RC16 Full /8 | 20028 | 20028 |
| RC16 Full /16 | 9746 | 9746 |
| RC16 Full + MulH /16 | 9746 | 9746 |
| RC16 Full + MulDiv /16 | 9746 | 9746 |
| Nano | 263691 | 263691 |
| RC16 Fast DSP | 4811 | 4811 |
| RC16 Fast soft | 5259 | 5259 |

### RC32 word-copy and dot-product benchmark

`test_rc32_bench` copies 32 words, then computes 32 signed products from the
copy and checks their sum. It retires 527 instructions. These rates describe
this workload; they are not directly comparable with the RC16 benchmark.
Cycle counts come from Verilator with ready memory and match both RF mappings.

| Core | Cycles | ECP5 MIPS | Agilex MIPS | ECP5 MIPS/kLUT4 | Agilex MIPS/kLE |
|---|---:|---:|---:|---:|---:|
| RC32 Full /16 | 5882 | 6.09 | 19.49 | 14.2 | 29.5 |
| RC32 Full /32 | 2619 | 14.56 | 43.02 | 28.7 | 58.0 |
| RC32 Fast soft | 1441 | 18.20 | 81.54 | 14.1 | 47.6 |
| RC32 Fast DSP | 960 | 27.66 | 118.44 | 22.3 | 81.6 |

### Compiler benchmark cycles

The RC16 full-width variants below run the same Full `-O2` binaries.
MulDiv's shifted ALU input also speeds up FSL1; these programs do not need
to use DIVU to benefit from that path.

| RC16 benchmark | Full /16 | Full + MulH /16 | Full + MulDiv /16 |
|---|---:|---:|---:|
| `int32` | 163018 | 163018 | 158318 |
| `softfloat` | 386225 | 386225 | 381526 |
| `libm32` | 30726 | 30726 | 30320 |
| `matrix` | 197998 | 197998 | 195793 |
| `structures` | 8102 | 8102 | 8102 |
| Total | 786069 | 786069 | 774059 |

### Reproducing measurements

```sh
make -j16 tables-lattice
make -j16 QUARTUS_SH=/path/to/quartus/bin/quartus_sh tables
```

`tables-lattice` evaluates mapping recipes at routing seed 1 by default and
runs the common RTL benchmark. Set `TUNE_SEEDS=32` for a 32-seed sweep.
Recipe choices and raw results are written under `build/tune/`.

For one full-width configuration:

```sh
python3 tools/lattice_tune.py ecp5 wide32-muldiv --seeds 32 -j 16
```

Each recipe is synthesized once and routed at every requested seed.
`--resume` continues an interrupted sweep. Sequential-retiming recipes are
excluded from the search.

## 3. FPGA toolchain

The open-source flow needs yosys, Verilator 5 or newer, g++, Python 3,
nextpnr-ecp5, prjtrellis, and optionally ccache and openFPGALoader. On
Debian/Ubuntu:

```sh
sudo apt-get install -y build-essential make python3 ccache libsdl2-dev libstb-dev \
  verilator yosys nextpnr-ecp5 fpga-trellis \
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
make test-rtl
make test-compiler
make test-isa
make test-fast-irq-all test-wide-irq-all
make fuzz-all
make check-regressions
make -j$(nproc) QUARTUS_SH=/opt/intelFPGA_pro/26.1/quartus/bin/quartus_sh tables
```

`test-all` runs the LLVM/Clang/lld tests, `test-isa`, and `test-compiler`.
Fuzzing and FPGA measurements have separate targets.

`test-rtl` covers Nano, all RC16 and RC32 profiles and widths, full-width
MulH/MulDiv options, and the Fast RF and multiplier variants.
`test-compiler` covers compiler, libc, Nano compiler/RTL, and encoding tests.

`test-isa` runs assembler and disassembler checks, directed ISS/RTL
instruction tests, and asserts an
external IRQ at every cycle of the interrupt-safe image on every
interrupt-capable RTL width. It additionally injects at every actual memory
wait cycle and ready transition under a fixed stalled-memory schedule. Optional
unimplemented RC32X instructions are not part of this target. `test-wide-all`
tests both full-width architectures and their arithmetic options;
`test-wide-irq-all` sweeps their interrupt timing. `test-fast-irq-all` checks
both Fast architectures, RF mappings, and multiplier options. Run these two
IRQ targets separately from `test-all`.
`fuzz-all` differentially compares self-checking generated programs between
the ISS and trace-enabled RTL, including both full-width architectures and
their MDU options, reporting a replay command for any failure.
Fast, which has no retirement trace interface, receives final written-memory
comparison plus the generated program's full architectural self-check and a
random external IRQ injection.

`check-regressions` enforces deterministic benchmark image-size and cycle
limits and guarded ECP5 area/Fmax limits for representative RC16, Nano, RC32,
Fast configurations. The PPA bounds deliberately allow a small
mapper/P&R margin; published table updates still require the full identical-
seed characterization flow.

Trace targets (`trace PROFILE=<profile> WIDTH=<width>`, `trace-nano`,
and `trace-rc32 PROFILE=<profile> WIDTH=<width>`) record
architectural state and written memory after every instruction. The RC32
target selects a Min, Sys, or Full image matching `PROFILE`. Use them to locate
the first divergent instruction when a differential test fails.

## 5. Board builds and demos

Each board SoC provides:

- on-chip program/data RAM;
- a 4-bit framebuffer and board-local video output;
- a UART, a 1 kHz timer, and a two-source interrupt controller; and
- LED outputs and button inputs.

The shared software-visible map is:

| Byte address or range | Demo function |
|---:|---|
| `0x0000..0x7fff` | Unified program/data RAM |
| `0x8000..0xf07f` | 320x180 framebuffer, four 4-bit pixels per 16-bit word; CPU writes only |
| `0xf080..0xffef` | Reserved |
| `0xfff0..0xfff2` | UART; see the [Programming manual](PROGRAMMING.md#bsp-services-and-mmio) for register semantics |
| `0xfff4` | timer: write a non-zero 1 kHz delay to arm/rearm; read the free-running 16-bit millisecond tick counter |
| `0xfff6` | interrupt state: read pending UART/timer bits 0/1; write enable mask |
| `0xfff8` | LED output; Icepi uses five low bits and Atum uses four |

Each displayed framebuffer contains 14,400 16-bit words. The UART divisor is board-local.
[`<riscc/platform.h>`](../firmware/include/riscc/platform.h) defines the shared
C interface.

The interrupt controller is a two-bit level mask for UART and timer sources.
It has no priority, vectoring, edge capture, or acknowledgement register. The
timer uses a board-local 1 kHz timebase, and both boards retain the fixed
RISC-C IRQ vector.

### Icepi Zero

The Icepi demo is in [`boards/icepi_zero`](../boards/icepi_zero). It uses a
50 MHz Fast SoC, a 320x180 4-bit framebuffer scaled to 640x480 DVI, UART,
LEDs, buttons, and freestanding C++ Julia-set firmware. The complete ECP5
design uses 1,638 LUT4s, 34 EBRs, and one DSP block. Its PLL, TMDS encoder, and
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
demo. It combines a Fast SoC, UART, on-chip program RAM, and a 320x180
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

The Quartus Pro 26.1 post-fit design uses 689.5 ALMs, 31 M20K blocks, one DSP
block, and two IOPLLs. The 148.5 MHz pixel clock meets timing. The 225 MHz
system target does not close timing; its restricted Fmax is 196.73 MHz.
Persistent QSPI programming is outside the normal flow; see Terasic's
[Atum A3 Nano documentation](https://www.terasic.com.tw/cgi-bin/page/archive.pl?CategoryNo=44&Language=English&No=1373&PartNo=4).

![Video capture of RISC-C running on Atum A3 Nano](riscc_on_atum-a3.jpg)

*Video capture of RISC-C running on the Atum-A3-Nano FPGA board.*

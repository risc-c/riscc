# RISC-C

Author: Arto Vuori <avuori@iki.fi>

RISC-C is an open processor architecture for compact systems. Its mainline
instruction set architecture (ISA) has 16- and 32-bit data-word configurations.
The project provides a family of synthesizable Verilog cores that scale from
bit-serial processors for very small systems to pipelined cores for higher
throughput.

RISC-C is genuinely tiny: its smallest Nano implementation uses only 93 iCE40
LUT4s. That size does not come from reducing the programming model to an
accumulator, stack machine, or narrowly specialized instruction subset. Nano
retains a conventional register-based architecture with a complete,
general-purpose RISC-style instruction set for compiled C and C++. The ISA maps
naturally to LLVM, and the family scales beyond minimal controllers to
system-capable and pipelined cores with interrupts, basic operating-system
support, hardware multiplication, and optional division.

This repository contains the ISA and C application binary interface (ABI)
specifications, a C/C++ compiler based on LLVM/Clang, an assembler, an
instruction set simulator (ISS), a firmware runtime, register
transfer level (RTL) cores, self-checking tests, field programmable gate array
(FPGA) flows, and board demonstrations.

RISC-C is free and open source under the [ISC License](LICENSE), with no
restrictions on its use. All project tools can be built and the demonstrations
can be run using only free and open-source software. The RISC-C demonstration
also runs on the
[Icepi Zero](https://github.com/cheyao/icepi-zero), an open-source hardware
board.

## Getting started

On Debian or Ubuntu, install the host build, hardware simulation, synthesis,
routing, and demonstration dependencies with:

```sh
sudo apt-get update
sudo apt-get install build-essential cmake git ninja-build pkg-config \
  python3 verilator yosys nextpnr-ice40 nextpnr-ecp5 \
  fpga-trellis openfpgaloader libsdl2-dev libstb-dev
```

The two `nextpnr` packages are needed for routed timing measurements and
open-source FPGA implementation flows. Simple DirectMedia Layer 2 (SDL2) and
the STB image library support the interactive display and image output;
the compiler, firmware, and command-line ISS can be built without them.

Clone the repository together with its LLVM/Clang compiler sources:

```sh
git clone --recurse-submodules https://github.com/risc-c/riscc.git
cd riscc
```

Build the RISC-C LLVM/Clang toolchain, firmware libraries, and C++ ISS:

```sh
make -j16 riscc-firmware build/tools/riscc_sim
```

The first build compiles the local toolchain under `build/llvm-riscc` and can
take several minutes. Subsequent application builds reuse it.

### Compile and run Hello World

The complete example is in [`firmware/hello`](firmware/hello). Build it from
the repository root and run the resulting image through the ISS:

```sh
make -C firmware/hello
build/tools/riscc_sim build/hello/hello.bin --full --uart
```

This takes `hello.c` through Clang, the LLVM RISC-C code generator, the LLVM
linker (LLD), the firmware runtime, binary-image generation, and finally the
ISS.

It prints:

```text
Hello, RISC-C!
```

Edit [`firmware/hello/hello.c`](firmware/hello/hello.c), or copy that directory
as the starting point for another freestanding C application. The generated
Executable and Linkable Format (ELF) file, binary image, and assembly listing
are placed in `build/hello`.

Run the same binary on the Verilated Tiny16 Full RTL implementation with:

```sh
make -j16 build/tb/tiny16-full/tb
build/tb/tiny16-full/tb build/hello/hello.bin --max-cycles 1000000 \
  --uart-expect-line 'Hello, RISC-C!'
```

The RTL testbench models instruction/data memory and the universal asynchronous
receiver-transmitter (UART), and checks the line emitted by the processor.

### Run a demonstration in the ISS

The RISC-C demonstration uses SDL2 to display its simulated framebuffer. Its
source is [`boards/shared/sw/demo.cpp`](boards/shared/sw/demo.cpp). Build and
run it in the ISS with:

```sh
make -j16 icepi-zero-demo-iss
```

The command opens the simulated display and connects the target UART to
the terminal. Close the window to stop the simulation.

### Run the demonstration on an FPGA board

The Icepi Zero system and FPGA files are in
[`boards/icepi_zero`](boards/icepi_zero). Build its bitstream and load it onto
the board with:

```sh
make -j16 icepi-zero-demo-bit
openFPGALoader -cft231X --pins=7:3:5:6 build/icepi_zero/demo.bit
```

The `make` command only produces the bitstream. `openFPGALoader` temporarily
configures the FPGA without overwriting its flash.

The demonstration also runs on the Atum A3 Nano board. If Quartus Pro is
available, provide its `quartus_sh` executable to build the FPGA image:

```sh
make -j16 QUARTUS_SH=/path/to/quartus/bin/quartus_sh atum-a3-demo
```

This produces the Intel configuration file without programming the board. See
the [Hardware manual](doc/HARDWARE.md#terasic-atum-a3-nano) for programming
commands.

## Documentation

- [Hardware manual](doc/HARDWARE.md) — microarchitectures, FPGA families,
  validation, timing/area results, and examples of running RISC-C on FPGA
  boards.
- [Programming manual](doc/PROGRAMMING.md) — assembly and ISS use,
  LLVM/Clang, application Makefiles, runtime libraries, startup/layouts,
  thread-local storage, interrupts, and split images.
- [RISC-C ISA specification](doc/RISC-C-ISA.md) — the normative instruction
  definition.
- [RISC-C C and object ABI](doc/RISC-C-ABI.md) — the
  normative static C and object-file interoperability contract.

## Repository map

| Path | Contents |
|---|---|
| `rtl/` | processor implementations and shared RTL logic |
| `boards/` | FPGA board system-on-chip (SoC) designs and demonstration firmware |
| `tools/` | assembler, ISS implementations, fuzzing, and image helpers |
| `firmware/` | startup, linker layouts, minimal runtime libraries, and application Makefile support |
| `external/llvm-project/` | LLVM/Clang compiler source submodule; development branch `riscc-backend` |
| `test/` | ISA, RTL, and compiler tests |

## Common commands

The usual complete non-interactive check is:

```sh
make -j16 all
make -j16 test-compiler
```

| Command | Purpose |
|---|---|
| `make -j16 test-all` | Deterministic Verilator RTL regression for every core family. |
| `make -j16 sim-all` | C++ ISS runs for the mainline images and benchmark. |
| `make -j16 test-compiler` | Builds LLVM/Clang when needed, then tests the compiler, C library, thread-local storage (TLS), interrupt requests (IRQs), ISS, and board RTL. |
| `make -j16 all` | Hardware aggregate: RTL regression, ISS runs, benchmarks, and area reports. It does not include the compiler suite. |
| `make -j16 fuzz-all` | Longer randomized ISS-versus-RTL differential fuzzing. |
| `make -j16 tables` | Regenerates area, maximum clock frequency (Fmax), and benchmark measurement tables; substantially slower. |
| `make icepi-zero-demo-iss` | Builds and runs the Icepi Zero demo in the Fast digital signal processing (DSP) multiplier ISS model with its display window. |
| `make icepi-zero-demo-bit` | Builds the Icepi Zero demo bitstream only; it does not program hardware. |
| `make atum-a3-demo-iss` | Builds and runs the Atum A3 Nano demo in the Faster DSP multiplier ISS model with its display window. |
| `make QUARTUS_SH=/path/to/quartus/bin/quartus_sh atum-a3-demo` | Builds the Atum A3 Nano Intel configuration file (`.sof`); firmware-only changes update the fitted on-chip memory image and reassemble, while RTL or project changes run the full Quartus flow. Quartus Pro must be provided and the command does not program hardware. |

See the Hardware manual before running FPGA flows or programming a board, and
the Programming manual before building an application image.

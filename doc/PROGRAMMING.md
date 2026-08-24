# Programming RISC-C

RISC-C is a freestanding target: a program is linked with the supplied startup
code and small runtime, loaded as a flat binary, and run directly on a core.
There is no operating system or process environment.

This manual starts with a complete C program and follows it through compilation
and simulation. The later sections are references for profiles, tools, the
runtime libraries, platform I/O, and interrupts.

The [ISA specification](RISC-C-ISA.md) defines the instruction set. The
[C and object ABI](RISC-C-ABI.md) defines calling conventions and ELF
compatibility. RTL, FPGA boards, and performance results are covered by the
[Hardware manual](HARDWARE.md).

## 1. Build and run your first program

The repository contains a complete Hello World application in
[`firmware/hello`](../firmware/hello/). Its source is ordinary freestanding C:

```c
#include <stdio.h>

int main(void)
{
    puts("Hello, RISC-C!");
    return 0;
}
```

The default target is RC16 Full. From the repository root, build the LLVM
toolchain, matching runtime, and instruction-set simulator (ISS):

```sh
make -j32 llvm-riscc firmware build/tools/riscc_sim
```

Compile and link the application:

```sh
make -C firmware/hello
```

This creates:

- `build/hello/hello.elf`, the linked ELF file;
- `build/hello/hello.bin`, the flat memory image; and
- `build/hello/hello.s`, the compiler-generated assembly.

Run the binary in the ISS. `--full` selects the matching CPU profile and
`--uart` connects the simulated UART to the terminal:

```sh
build/tools/riscc_sim build/hello/hello.bin --full --uart
```

It prints `Hello, RISC-C!`. Returning from `main` enters the startup code's
`HALT` loop, which the ISS treats as normal completion.

### Run the same binary on RTL

Build the RC16 Full Verilator model and give it the same flat image:

```sh
make -j32 build/test/rc16/native/full/16/tb
build/test/rc16/native/full/16/tb build/hello/hello.bin \
  --max-cycles 1000000 --uart-expect-line 'Hello, RISC-C!'
```

The ISS is the convenient place to develop software; matching RTL simulation
checks the real hardware implementation and exact cycle behavior.

### Start a new application

Copy [`firmware/hello`](../firmware/hello/) and replace `hello.c`. Its Makefile
is deliberately small: it includes [`firmware/riscc.mk`](../firmware/riscc.mk)
for compiler flags and runtime paths, while keeping all compile and link rules
visible in the application.

If an application lives outside this repository, point `RISCC_ROOT` at the
checkout before including the fragment:

```make
RISCC_ROOT := /path/to/riscc
PROFILE := full
RISCC_XLEN := 16
include $(RISCC_ROOT)/firmware/riscc.mk
```

Build the matching runtime once in the RISC-C repository. The application's
own Makefile then uses `RISCC_CLANG`, `RISCC_CFLAGS`, `RISCC_STARTFILES`,
`RISCC_LIBRARIES`, and `RISCC_LDFLAGS` supplied by the fragment.

## 2. Choose a target

RISC-C has two native data widths and four profiles. RC16 is the default;
RC32 is selected with `RISCC_XLEN=32` or Clang's `-mrc32` option.

| Profile | Intended use | Runtime selection | ISS selection |
|---|---|---|---|
| Nano | Smallest RC16 core; reduced registers, no TLS or interrupts | `PROFILE=nano` | `--nano` |
| Min | Small mainline core without interrupts | `PROFILE=min` | `--min` or `--rc32` |
| Sys | Mainline core with system and interrupt support | `PROFILE=sys` | no flag for RC16; `--rc32-sys` for RC32 |
| Full | Complete base profile | `PROFILE=full` | `--full` or `--rc32-full` |

Nano exists only for RC16. Min, Sys, and Full are implemented for both RC16
and RC32.

For example, build the RC32 Sys runtime, compile the repository's mixed C/C++
test application, and run its self-check in the RC32 ISS:

```sh
make -j32 RISCC_XLEN=32 PROFILE=sys firmware
make -C test/application RISCC_ROOT="$PWD" RISCC_XLEN=32 PROFILE=sys \
  BUILD="$PWD/build/application-rc32-sys"
build/tools/riscc_sim build/application-rc32-sys/application.bin \
  --rc32-sys --require-result
```

The compiler defines one of `__RISCC_NANO__`, `__RISCC_MIN__`,
`__RISCC_SYS__`, or `__RISCC_FULL__`. RC32 additionally defines
`__RISCC_RC32__`.

Full has an optional multiply/divide extension selected with
`RISCC_TARGET_FEATURES=mdu` or `-mmdu`. RC16 has matching implementations;
the RC32 toolchain and ISS support the extension, but current RC32 RTL does
not. RC32X remains unsupported and `-mrc32x` is intentionally rejected.

RC32 direct calls are address-range independent. The compiler places a
full-width target literal, and the linker automatically replaces each Sys or
Full call whose final target is at or below `0x1ffffe` with `JALL` or `JMPL`.
Far calls retain `LDPC` plus `JALR`; no code-model option is required.

## 3. Compile, link, and inspect programs

### Application Makefiles

[`firmware/riscc.mk`](../firmware/riscc.mk) selects the correct startup files,
linker script, and libraries from `PROFILE` and `RISCC_XLEN`. It defines
variables only; it does not add hidden recipes.

The essential application rules are:

```make
$(OBJ): program.c
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_CFLAGS) -c $< -o $@

$(ELF): $(OBJ) $(RISCC_STARTFILES) $(RISCC_LIBRARIES)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_LDFLAGS) \
	  $(RISCC_STARTFILES) $(OBJ) $(RISCC_LIBRARIES) -o $@

program.bin: $(ELF)
	$(RISCC_OBJCOPY) -O binary $< $@
```

The supplied flags use one section per function or data item and link with
`--gc-sections`, so unused parts of the runtime are not included.

### Direct tool invocation

The application fragment is preferred because it keeps profiles and runtime
paths consistent. For debugging a build, the equivalent RC16 Full commands
begin as follows:

```sh
build/llvm-riscc/bin/clang --target=riscc-none-elf -mcpu=full \
  -Os -ffreestanding -fno-builtin -ffunction-sections -fdata-sections \
  -Ifirmware/include -c program.c -o program.o

build/llvm-riscc/bin/clang --target=riscc-none-elf -mcpu=full \
  -fuse-ld=lld -nostdlib -Wl,--gc-sections \
  -Wl,-T,firmware/rc16/unified.ld \
  build/firmware/rc16/full/vectors.o \
  build/firmware/rc16/full/crt0.o program.o \
  build/firmware/rc16/full/libc.a build/firmware/rc16/full/libm.a \
  build/firmware/rc16/full/libbsp.a build/firmware/rc16/full/libirq.a \
  build/firmware/rc16/full/libbuiltins.a -o program.elf

build/llvm-riscc/bin/llvm-objcopy -O binary program.elf program.bin
```

The library order matters because earlier archives refer to services supplied
by later ones. Let `RISCC_LIBRARIES` provide it unless a custom platform needs
a different runtime.

Useful inspection commands are:

```sh
build/llvm-riscc/bin/llvm-objdump -d program.elf
build/llvm-riscc/bin/llvm-readobj -h -S -r program.elf
build/llvm-riscc/bin/llvm-nm -n program.elf
build/llvm-riscc/bin/llvm-size program.elf
```

### Handwritten assembly

LLVM MC, LLD, and LLVM objcopy use the same byte-addressed ELF representation
as compiler output and the runtime:

```sh
build/llvm-riscc/bin/llvm-mc -triple=riscc-none-elf -mcpu=full \
  -filetype=obj program.asm -o program.o
build/llvm-riscc/bin/ld.lld -T firmware/rc16/unified.ld \
  program.o -o program.elf
build/llvm-riscc/bin/llvm-objcopy -O binary program.elf program.bin
```

Use `--mattr=+rc32` for RC32 assembly and `--mattr=+mdu` when assembling the
optional MDU instructions. The [ISA specification](RISC-C-ISA.md) is the
instruction reference; the [ABI](RISC-C-ABI.md) gives register and stack rules
for assembly that calls C or is called by C.

### C and C++ language support

The compiler supports freestanding C, including cross-file calls, aggregates,
variadic functions, function pointers, TLS on mainline profiles, integer types
through 64 bits, and software floating point.

The C++ flags select a small C++17 language subset. Trivial classes,
aggregates, `constexpr`, namespaces, ordinary constructors for automatic
objects, and cross-translation-unit calls are supported. There is no C++
standard library or runtime: exceptions, RTTI, virtual dispatch, `new` and
`delete`, thread-safe local statics, and dynamic global construction are not
supported. The linker rejects constructor/finalizer arrays instead of silently
ignoring them.

GNU inline assembly supports `r`, `i`, and `m` constraints. Code must list all
fixed registers it changes and use a `memory` clobber when it touches memory
not named by an operand. Do not modify `r7` or ABI-reserved S registers from
ordinary C inline assembly.

## 4. Use the simulator

The main ISS is [`tools/riscc_sim.cpp`](../tools/riscc_sim.cpp), built as
`build/tools/riscc_sim`. Its first argument is a flat binary, followed by the
profile option from the table above.

Common options are:

| Option | Purpose |
|---|---|
| `--uart` | Connect RC16 target UART TX to stdout and RX to stdin |
| `--trace` | Print committed instructions and accepted interrupts |
| `--state` | Print final registers and execution summary |
| `--dump WADDR LEN` | Dump a range of memory words |
| `--dump-written` | Show only memory written during execution |
| `--max-insns N` | Set the instruction limit; zero means no limit |
| `--mhz N` | Throttle execution and select the simulated timer clock |
| `--fb-window` | Display the modeled framebuffer |
| `--fb-dump-png FILE` | Save the final framebuffer image |

For example:

```sh
build/tools/riscc_sim program.bin --full --trace --state 2>&1 | less
printf 'input line\n' | build/tools/riscc_sim program.bin --full --uart
```

`--width 1|2|4|8|16` selects an RC16 instruction-cycle estimate. `--fast`,
`--fast-dsp`, and `--faster` provide approximate timing for those cores. Use
RTL simulation whenever exact cycle behavior matters.

The ISS stops when the program halts, exceeds its instruction limit, or writes
the test result register. Address `0xfffe` is a testbench convention, not an
application `exit()` service. RC32 modes currently model the architectural
core and generic test fixture, but not UART, timer, or framebuffer devices.

## 5. Runtime and platform reference

Build one runtime with `make PROFILE=<profile> firmware`, optionally adding
`RISCC_XLEN=32`. Build every supported runtime with:

```sh
make -j32 firmware-all
```

### Startup and memory

The default image contains `vectors.o`, `crt0.o`, application code, and static
libraries. Startup initializes the stack, clears `.bss` and `.tbss`, sets the
mainline TLS anchor, calls `main`, and halts if `main` returns. Nano omits TLS
and interrupt setup.

The linker scripts are:

- [`firmware/rc16/unified.ld`](../firmware/rc16/unified.ld);
- [`firmware/rc32/unified.ld`](../firmware/rc32/unified.ld); and
- [`firmware/nano/unified.ld`](../firmware/nano/unified.ld).

They place code and data in one byte-addressed memory. By default the address
space is 64 KiB and the high MMIO area starts at `0xfff0`. Current demo boards
provide 32 KiB of memory below a framebuffer at `0x8000`. A platform can set
`__riscc_ram_length` and `__riscc_io_start` from its link to describe a
different memory map.

The heap grows upward from `__heap_start`; the stack grows downward from
`__stack_top`. There is no memory protection or automatic stack/heap collision
recovery.

### Libraries

| Archive | Interface |
|---|---|
| `libc.a` | Memory and strings, ASCII character handling, integer utilities, heap allocation, console streams, and integer formatting |
| `libm.a` | The floating-point functions declared by `<math.h>` |
| `libbsp.a` | Demo-platform UART, clock, and uptime services |
| `libirq.a` | Sys/Full interrupt wrapper and control API |
| `libbuiltins.a` | Integer and software-floating-point helpers emitted by the compiler |

These are static archives. Only referenced objects and sections enter the
application image.

### C library headers

| Header | Available interface |
|---|---|
| `<stddef.h>`, `<stdint.h>`, `<stdbool.h>`, `<limits.h>`, `<stdarg.h>` | Target types, limits, constants, and variadic arguments |
| [`<assert.h>`](../firmware/include/assert.h) | `assert`; failure halts through `abort` |
| [`<errno.h>`](../firmware/include/errno.h) | `errno`, `ENOMEM`, `EINVAL`, and `ERANGE` |
| [`<string.h>`](../firmware/include/string.h) | C90 byte and narrow-string functions |
| [`<ctype.h>`](../firmware/include/ctype.h) | ASCII/C-locale classification and case conversion |
| [`<stdlib.h>`](../firmware/include/stdlib.h) | Integer conversion, search/sort, PRNG, allocation, and termination |
| [`<stdio.h>`](../firmware/include/stdio.h) | UART-backed streams and integer-only formatted output |
| [`<time.h>`](../firmware/include/time.h) | `clock` and, on Sys/Full, interrupt-backed `time` |
| [`<math.h>`](../firmware/include/math.h) | Classification, rounding, decomposition, scaling, and the math functions below |
| [`<riscc/platform.h>`](../firmware/include/riscc/platform.h) | Demo-platform MMIO and timer helpers |
| [`<riscc/interrupt.h>`](../firmware/include/riscc/interrupt.h) | Sys/Full interrupt API |

`<stdio.h>` provides `getchar`, `putchar`, `puts`, `fgetc`, `fputc`, `fgets`,
and `fputs`. Its `printf`, `fprintf`, `sprintf`, and `snprintf` families support
`%%`, `%c`, `%s`, `%d`, `%i`, `%u`, `%x`, `%X`, `%p`, decimal width, `-`, `0`,
and `l`. There is no file system, `scanf`, floating-point formatting,
precision, or `long long` formatting. UART input has no EOF indication.

`<stdlib.h>` includes `malloc`, `free`, `calloc`, and `realloc`. The allocator
is single-threaded and must not be called from interrupt handlers. `exit`,
`_Exit`, and `abort` halt immediately; status values and `atexit` handlers are
not implemented.

### Math library

The following functions have `float`, `double`, and `long double` forms:

| Category | Functions |
|---|---|
| Sign and comparison | `fabs`, `copysign`, `fmin`, `fmax`, `fdim` |
| Rounding | `trunc`, `floor`, `ceil`, `round`, `lround`, `llround` |
| Decomposition and scaling | `modf`, `frexp`, `ldexp`, `scalbn`, `scalbln`, `ilogb`, `logb` |
| Representation | `nextafter`, `nexttoward`, `nan` |
| Arithmetic | `sqrt`, `fmod` |

`long double` uses the same binary64 representation as `double`. The library
does not implement transcendental functions, floating exceptions, alternate
rounding modes, or `errno` reporting. Nano uses a size-oriented binary32
implementation with a reduced exceptional-value contract; Min, Sys, and Full
provide the complete binary32 behavior.

### BSP services and MMIO

The default BSP connects libc streams to the demo UART. A custom platform can
provide its own `getchar`, `putchar`, `puts`, `clock`, and `time` services and
set `RISCC_BSP_LIBRARY` before including `firmware/riscc.mk`.

The current demo SoCs and the RC16 ISS peripheral model use this interface.
The RC32 ISS implements only the generic test IRQ and result registers.

| Byte address | Interface |
|---:|---|
| `0xfff0` | UART data: write TX byte; read and consume RX byte |
| `0xfff2` | UART status and IRQ-enable bits |
| `0xfff4` | One-shot timer on write; free-running 1 kHz counter on read |
| `0xfff6` | Timer/UART interrupt pending bits on read and enable mask on write |
| `0xfff8` | Board LED output |
| `0xfffa` | Test IRQ injection/acknowledgement; ISS and generic RTL tests only |
| `0xfffe` | Test result; ISS and generic RTL tests only |

Use the names in
[`<riscc/platform.h>`](../firmware/include/riscc/platform.h) instead of
embedding addresses in application code.

`clock()` reads the wrapping 16-bit 1 kHz counter. `time()` is uptime in whole
seconds, not wall-clock time. Its first call installs the default timer
handler, so it is available only on Sys and Full and consumes the runtime's
single C interrupt handler. Call `riscc_time_init()` when uptime should begin
before the first call to `time()`.

### Thread-local storage

RC16 and RC32 mainline startup create one initial TLS instance and keep its
base in `S2`. An RTOS must allocate and initialize one TLS block per thread and
restore `S2` during context switches. Nano has no TLS support.

### Interrupts

Sys and Full have one hardware IRQ vector. The default C interface is:

```c
#include <riscc/interrupt.h>

void riscc_irq_set_handler(void (*handler)(void));
void riscc_irq_enable(void);
void riscc_irq_disable(void);
```

Install the handler before enabling interrupts. The handler must acknowledge
every level-sensitive source that it services. The supplied wrapper does not
support nested interrupts and owns one global handler slot; applications that
need dispatching or context switching should provide a strong assembly
definition of `__riscc_irq_vector` instead.

## 6. Validation targets

Use these targets when changing software or checking a new application setup:

```sh
make -j32 test-all          # complete deterministic correctness gate
make -j32 test-applications  # public application flow on ISS and matching RTL
make -j32 test-compiler      # compiler, ABI, C++, libc, and runtime programs
make -j32 test-isa           # implemented ISA on ISS and RTL, including IRQ timing
```

For one profile or subsystem, use the narrower targets documented by
`make help`, such as `test-core`, `test-nano`, `test-rc32`,
`compiler-features`, or `compiler-libc`.

Hardware trace comparison, fuzzing, synthesis, and board programming belong in
the [Hardware manual](HARDWARE.md#4-validation).

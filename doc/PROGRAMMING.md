# RISC-C Programming Manual

This manual describes the software environment around the RISC-C ISA: writing
assembly and C, the compiler/runtime, and application images. The normative
instruction definition is the [ISA specification](RISC-C-ISA.md); the normative
C and ELF interoperability contract is the [C and object ABI](RISC-C-ABI.md).
Hardware implementation, board builds, and FPGA flows are in the
[Hardware manual](HARDWARE.md).

## 1. Software tools and the ISS

Production builds use LLVM MC for compiler-generated objects and assembly
sources. The in-tree Python assembler is a compact reference encoder for ISA
work and small standalone assembly programs:

```sh
python3 tools/riscc_asm.py --profile full program.asm -o program.bin
python3 tools/riscc_asm.py --profile nano program.asm -o program.bin
```

It accepts `.ifdef NAME`, `.ifndef NAME`, `.else`, and `.endif`; pass
`-D NAME` to define a symbol. Selecting `--profile min`, `sys`, `full`, or
`nano` also defines the corresponding profile symbol. `make
check-llvm-mc-encodings` cross-checks LLVM MC encodings against
`riscc_asm.py`.

The normal interactive ISS is `tools/riscc_sim.cpp`, built as
`build/tools/riscc_sim`. It executes the architectural ISA and provides the
same testbench MMIO page used by the RTL tests, including the result register,
UART, and framebuffer model. `tools/riscc_sim.py` is a compact standalone
reference ISS; project tests use the C++ ISS.

Build the C++ ISS once, then select the profile that matches the image:

```sh
make build/tools/riscc_sim
build/tools/riscc_sim program.bin             # sys profile, /16 cycle model
build/tools/riscc_sim program.bin --min
build/tools/riscc_sim program.bin --full --width 4
build/tools/riscc_sim program.bin --nano
build/tools/riscc_sim program.bin --faster
```

`--min` and `--full` are mutually exclusive; no profile option selects `sys`.
`--nano` is separate and cannot be combined with either mainline option.
`--width 1|2|4|8|16` selects the Tiny cycle model, not a different ISA. For an
approximate Fast timing model use `--fast` or `--fast-dsp`; these are useful
for interactive estimates but are not RTL timing results. `--faster` selects
the lightweight Faster DSP timing estimate. RTL simulation remains the
reference for exact timing.

The default limit is two million committed instructions. Use
`--max-insns N` to choose another limit, or `--max-insns 0` to run until the
test result register is written, the program halts, or a framebuffer window
closes. A normal application can return from `main`; the default startup then
emits `HALT`. `HALT` is the assembler spelling of `JMP8 -1`: hardware parks
at that instruction, while the ISS treats it as normal completion when the
result word is untouched. An ISS/RTL self-checking test instead writes
`0x600d` to byte address `0xfffe`; that testbench completion mechanism is not
a general target `exit()` interface.

The four UART words below are implemented by the ISSes and current demo-board
SoCs. They are the default demo-BSP UART contract, not general-purpose RAM:

| Byte address | Register | Availability |
|---:|---|---|
| `0xfff0` | UART data: write TX byte; read RX byte and consume it | ISSes and current demo boards |
| `0xfff2` | UART state: read TX-ready bit 0, RX-ready bit 1, RX-overflow bit 2; write RX/TX IRQ-enable bits 0/1 | ISSes and current demo boards |
| `0xfff4` | Timer: write a one-shot delay in milliseconds; read the free-running 16-bit millisecond tick counter | C++ ISS and current demo boards |
| `0xfff6` | Interrupt state: write UART/timer enable bits 0/1; read pending UART/timer bits 0/1 | C++ ISS and current demo boards |
| `0xfff8` | LED output; Icepi uses five low bits and Atum uses four | current demo boards |
| `0xfffa` | Test IRQ: write raises it; read returns its cause and acknowledges it | ISSes and generic RTL testbench only |
| `0xfffe` | Test result word: write `0x600d` for pass | ISSes and generic RTL testbench only |

The demo SoCs reserve their high MMIO aperture, but do not implement these
testbench functions. Board firmware must not use `0xfffa..0xfffe` as RAM or
expect test-result/IRQ behavior there.

The current demo boards also share a tiny source-level interrupt controller:
`0xfff6` reads pending UART (bit 0) and timer (bit 1), and writes the same
two-bit enable mask (reset to zero). `0xfff4` is a 16-bit one-shot
1 kHz timer ticks: a non-zero write to `0xfff4` loads and arms it, terminal
count latches the timer source, and a subsequent timer write both clears that
source and re-arms (or disarms with zero). Reading `0xfff4` returns the
free-running 16-bit millisecond tick counter. It wraps every 65.536 seconds,
so an application that needs a
longer clock must extend it from a periodic timer interrupt. The default BSP
does this for its narrow `time()` service with one IRQ per second. There is no
priority, vector, edge latch, or controller acknowledgement. Use
[`<riscc/platform.h>`](../firmware/include/riscc/platform.h) for the timer
helpers. The ISS implements the same timer/controller registers for firmware
tests. Its 1 kHz timebase advances from modeled CPU cycles: `--mhz N` selects
an `N` MHz simulated clock, while an unthrottled ISS run without `--mhz` uses
a deterministic 50 MHz virtual clock.

### Run a UART hello world

`--uart` bridges the simulated UART: target transmit bytes go to host standard
output and host standard input supplies target receive bytes. With the default
demo BSP, the freestanding [`<stdio.h>`](../firmware/include/stdio.h) front end
exposes unbuffered `stdin`, `stdout`, and `stderr`; standard output and standard
error are the same UART sink. `getchar`/`putchar`/`puts` and
`fgetc`/`fputc`/`fgets`/`fputs` block on the UART as needed. RX has no EOF, so
`fgets` returns after a newline or a full buffer, not end-of-file.

The integer-only formatter supplies `printf`, `fprintf`, `sprintf`,
`snprintf`, and their `v` forms. It accepts `%%`, `%c`, `%s`, `%d`/`%i`, `%u`,
`%x`/`%X`, `%p`, decimal width, `-`, `0`, and `l` for the 32-bit `long` type.
`snprintf` has the C99 result and truncation rules: it always counts the full
would-have-written output and NUL terminates when its size is non-zero.
There is no buffering, file I/O, EOF-producing device, `scanf`, precision,
floating-point formatting, or `long long` formatting.

The complete source is in [`firmware/hello`](../firmware/hello):
[`hello.c`](../firmware/hello/hello.c) and its visible
[`Makefile`](../firmware/hello/Makefile). From the repository root, build the
SDK and ISS once, then build the unified image and run it with UART output:

```sh
make -j16 riscc-firmware build/tools/riscc_sim
make -C firmware/hello
build/tools/riscc_sim build/hello/hello.bin --full --uart
```

The example Makefile includes the SDK's small
[`firmware/riscc.mk`](../firmware/riscc.mk) variable fragment, then contains
the direct Clang, linker, and objcopy commands. It invokes no parent Makefile
and uses the prebuilt toolchain/runtime paths from that fragment.

The greeting appears on host stdout. Returning from `main` executes the
default startup's `HALT` loop. To feed an RX-using program, use a pipe, for
example `printf 'abc' | build/tools/riscc_sim app.bin --full --uart`.

### Inspection, traces, and devices

`--state` prints the final registers and summary. `--dump WADDR LEN` dumps
words from a word address; `--dump-written` lists only words written during the
run. `--trace` emits one architectural trace record per committed instruction
or accepted interrupt. Trace and state records are written to stderr, so use
`2>&1` when piping them:

```sh
build/tools/riscc_sim program.bin --full --trace --dump-written 2>&1 \
  | grep -E '^(TRACE|MEM) '
```

`--uart` also enables the ISS UART MMIO model. `--fb-window` displays the
selected board framebuffer (320x240 with `--fast-dsp`, 320x180 with
`--faster`; the generic default remains 160x120), `--fb-scale N` chooses its
initial scale, and `--fb-dump-png FILE` writes the final image. `--mhz N` throttles a long-running
simulation to approximately N simulated MHz; omit it to run as fast as the
host permits. RTL trace comparison and fuzzing are hardware-validation work;
see [Hardware validation](HARDWARE.md#6-validation-and-measurement).

## 2. LLVM/Clang C toolchain

The downstream LLVM checkout is the `external/llvm-project` submodule on the
`riscc-backend` work branch. Clone with `--recurse-submodules`, or initialize
it after cloning with `git submodule update --init --recursive`. Build the
reusable local toolchain and the shared firmware objects with:

```sh
make -j16 llvm-riscc
make -j16 riscc-firmware
```

The build directory is `build/llvm-riscc`. It contains the RISCC backend,
Clang, LLD, and the small developer tool set: `llvm-ar`, `llvm-mc`,
`llvm-objcopy`, `llvm-objdump`, `llvm-readobj`, `llvm-nm`, `llvm-size`, `llc`,
`opt`, `llvm-as`, and `llvm-dis`. Upstream targets, tests, examples, docs,
bindings, runtimes, static analysis, plugins, and optional host libraries are
disabled. The top-level Makefile preserves that build directory and
automatically passes the normal persistent ccache launcher to CMake when
`ccache` is installed. Do not create a separate CMake build merely to compile
an application.

Use `llvm-objdump -d` for RISC-C disassembly, `llvm-readobj -r -s` for ELF
sections and relocations, `llvm-nm -n` for symbols, and `llvm-size` for image
size. `llc`, `opt`, `llvm-as`, and `llvm-dis` are provided for backend and IR
debugging; no C++ runtime or Clang development-tool suite is included.

Top-level `make clean` preserves the prebuilt LLVM toolchain and RISC-C
runtime; use `make distclean` only when those SDK artifacts must be discarded.

The C target is freestanding `riscc-none-elf`; `-mcpu=full` is the default.
`-mcpu=sys` and `-mcpu=min` select the smaller mainline profiles, while
`-mcpu=nano` selects the incompatible reduced-register Nano ABI. Clang defines
exactly one of `__RISCC_FULL__`, `__RISCC_SYS__`, `__RISCC_MIN__`, or
`__RISCC_NANO__`. The backend replaces unavailable multiplication with
`__mulhi3`, expands shifts to instructions legal for the selected profile, and
uses register-target calls and jumps where a profile lacks `JAL16`. Nano has
no S-register bank or TLS and receives a call link in allocatable `r6`; see the
[C and object ABI](RISC-C-ABI.md#nano-register-variant).
On the mainline profiles, one-bit LLVM funnel shifts and the corresponding
limb patterns in 32-bit shifts select `FSL1`/`FSR1`; Nano expands the same
operations using its base instruction set.

The compiler supports C at `-O0`, `-O2`, and `-Os`, ordinary global and TLS
objects, stack frames, aggregate calls and returns, function pointers,
16-/32-/64-bit integer operations, and software `float`, `double`, and
`long double`. It has no hosted environment; the supplied tiny libc provides
standard type/utility headers, C90 narrow strings, ASCII/C-locale `<ctype.h>`,
`<errno.h>`, integer `<stdlib.h>`, and the small stdio surface described
below. Variadic functions keep named arguments on the ordinary ABI convention
and place unnamed arguments on the stack; see the normative
[C and object ABI](RISC-C-ABI.md#4-calls-arguments-and-results) for `va_list`
semantics. It has no VLA/dynamic `alloca`, PIC, atomics, exceptions, unwinding,
jump tables, compiler interrupt attributes, or C++ runtime. The backend emits
direct sibling tail calls when the caller and callee signatures match and no
stack arguments are needed. This is a code-generation optimization, not a
separate ABI calling convention; indirect and otherwise ineligible tail calls
remain ordinary calls.

### Inline assembly

GNU-style inline assembly supports the target `r` constraint for an
allocatable general register and the generic `i` and `m` constraints for an
integer constant and a memory operand. Standard output, read/write, matching,
and early-clobber modifiers work normally. RISC-C defines no target-specific
immediate constraint letters and has no condition-code clobber.

The compiler does not infer effects from the assembly text. List every fixed
register written by the instructions, including implicit `r0` writes, and use
the `memory` clobber when the assembly accesses unlisted memory or acts as a
compiler barrier. Use `volatile` when the assembly must not be removed. Do not
modify `r7` or ABI-reserved S registers from ordinary C inline assembly.

### Application Makefiles

An application should include [`firmware/riscc.mk`](../firmware/riscc.mk)
after setting `RISCC_ROOT`. The fragment only supplies visible variables for
tool paths, target flags, start files, static libraries, linker script, and
the unified application layout; it supplies no recipes or hidden build graph.
[`firmware/hello/Makefile`](../firmware/hello/Makefile) is the complete
direct-Clang example. Copy that directory for a new application, replace
`hello.c`, and set `RISCC_ROOT=/path/to/riscc` if the copy is outside this
checkout. Its default unified build emits `build/hello/hello.elf` and
`build/hello/hello.bin`, plus `build/hello/hello.s` for inspection.
Applications that need a different startup, linker layout, or image-conversion
policy can replace the visible rules in their own Makefile.

Set `RISCC_CPU := sys` or `RISCC_CPU := min` before including `riscc.mk` to
select a smaller mainline profile. Build its matching runtime first with
`make -j16 riscc-firmware-sys` or `make -j16 riscc-firmware-min`. The Min
runtime omits interrupt support because that profile has no system extension.
The compiler and top-level build also provide `-mcpu=nano` and
`make -j16 riscc-firmware-nano`; Nano applications use the archives under
`build/firmware/nano` without the mainline interrupt library, TLS, or the
interrupt-driven `time()` service. Nano packaging in the application
`riscc.mk` fragment remains to be completed.

The essentials of the direct invocation are:

```sh
build/llvm-riscc/bin/clang --target=riscc-none-elf -mcpu=full \
  -Os -ffreestanding -fno-builtin -ffunction-sections -fdata-sections \
  -Ifirmware/include -c hello.c -o hello.o
build/llvm-riscc/bin/clang --target=riscc-none-elf -mcpu=full \
  -fuse-ld=lld -nostdlib -Wl,--gc-sections -Wl,-T,firmware/unified.ld \
  build/firmware/vectors.o build/firmware/crt0.o hello.o \
  build/firmware/libc.a build/firmware/libm.a build/firmware/libbsp.a \
  build/firmware/libirq.a build/firmware/libbuiltins.a -o hello.elf
```

`-ffunction-sections -fdata-sections` and `--gc-sections` are deliberate:
they keep static runtime support pay-for-what-is-referenced. Archive extraction
selects only needed object files, and section garbage collection discards
unreachable functions and data within selected objects.

## 3. Runtime libraries

The runtime is an intentionally small freestanding SDK, not a port of
picolibc. Build the archives that match the selected compiler profile:

```sh
make -j16 riscc-firmware        # Full, under build/firmware/
make -j16 riscc-firmware-sys    # Sys,  under build/firmware/sys/
make -j16 riscc-firmware-min    # Min,  under build/firmware/min/
make -j16 riscc-firmware-nano   # Nano, under build/firmware/nano/
```

### 3.1 Archives and link order

| Archive | Profiles | Source and responsibility |
|---|---|---|
| `libc.a` | All | [`firmware/libc`](../firmware/libc/): board-independent memory, strings, ASCII character handling, integer utilities, heap, streams, and integer formatting |
| `libm.a` | All | [`firmware/libm`](../firmware/libm/): small binary32/binary64 math API |
| `libbsp.a` | All | [`firmware/bsp/demo`](../firmware/bsp/demo/): board-specific console and clock/uptime services |
| `libirq.a` | Full, Sys | [`firmware/irq*.S`](../firmware/irq.S): interrupt fallback, control API, and ordinary-C handler wrapper |
| `libbuiltins.a` | All | [`firmware/builtins`](../firmware/builtins/) plus [compiler-rt builtins](../external/llvm-project/compiler-rt/lib/builtins/): compiler-generated integer and soft-float helper calls |

The normal order is startup objects, application objects, `libc.a`, `libm.a`,
`libbsp.a`, optional `libirq.a`, then `libbuiltins.a`. This is significant:
generic libc stream code refers to `getchar`, `putchar`, and `puts`, which the
later BSP supplies, while libc and libm may refer to compiler helpers supplied
last.

All runtime C files use function/data sections, and applications link with
`--gc-sections`. Archive extraction selects relevant object files and section
GC removes unused functions within those objects. A program which does not
use floating point, the heap, formatting, time, or interrupts does not pay for
those facilities.

### 3.2 Compiler support library: `libbuiltins.a`

`libbuiltins.a` has no public application header. Clang and LLVM emit its
symbols when an operation is wider or more complex than the selected profile
implements directly.

- The RISC-C integer runtime supplies 16-, 32-, and 64-bit multiply,
  divide/remainder, wide shift, negate, and 64-bit comparison helpers. Its
  wide algorithms operate on little-endian 16-bit limbs. Hot 16-/32-/64-bit
  multiply and divide/remainder plus 32-/64-bit shift entry points are
  profile-tuned assembly; quotient, remainder, and combined
  quotient/remainder entry points share the wide restoring-divider cores.
  Full uses `MUL`, mainline uses `FSL1`/`FSR1`, and Nano has reduced-register
  base-ISA loops.
- Min and Nano can use shared fixed-count shift entry points when a call is
  smaller than repeating the instruction at each call site.
- RISC-C-specific binary32 addition, multiplication, and division use
  explicit 16-bit limbs. They avoid recursively calling the wide integer
  helpers and let leaf functions use the mainline S-register cache. Min, Sys,
  and Full use whole-routine assembly and a shared IEEE packer for gradual
  underflow and round-to-nearest/ties-to-even. Sys and Full use their
  fixed-count shifts directly; Full computes the binary32 24-by-24
  significand product from native byte products. The optional `mdu`
  extension is not required.
- Compiler-rt supplies the binary32 subtraction wrapper and comparisons,
  binary32 integer and format conversions, and all binary64 arithmetic,
  comparison, and conversion helpers.

Soft-float arithmetic and format conversion use round-to-nearest,
ties-to-even. Conversion to an integer truncates toward zero as required by C.
`long double` is the same binary64 format as `double`. There is no hardware
floating-point ABI, floating-point environment, or alternate rounding mode.
Nano's size-tuned binary32 add/subtract, multiply, and divide entry points are
the deliberate exception: they support finite normal arithmetic with
round-to-nearest/ties-to-even and treat exponent-zero operands as signed zero.
A finite-normal numerator divided by an exponent-zero denominator produces
signed infinity. NaNs, infinities, zero divided by zero, gradual underflow, and
result exponent overflow are otherwise outside the Nano arithmetic contract.
Min, Sys, and Full retain the complete binary32 behavior.

### 3.3 Public headers and `libc.a`

The table below is the implemented public surface, not a claim of complete
hosted-C compatibility.

| Header | Implemented surface |
|---|---|
| [`<stddef.h>`](../firmware/include/stddef.h), [`<stdint.h>`](../firmware/include/stdint.h), [`<stdbool.h>`](../firmware/include/stdbool.h), [`<limits.h>`](../firmware/include/limits.h), [`<stdarg.h>`](../firmware/include/stdarg.h) | Target types, limits, constants, `offsetof`, and the RISC-C variadic ABI |
| [`<assert.h>`](../firmware/include/assert.h) | `assert`; `NDEBUG` removes the check, failure calls `abort` |
| [`<errno.h>`](../firmware/include/errno.h) | Global `errno`; `ENOMEM`, `EINVAL`, and `ERANGE` |
| [`<string.h>`](../firmware/include/string.h) | Complete C90 narrow memory/string set, including `memcpy`, `memmove`, `strtok`, `strerror`, and the C-locale `strcoll`/`strxfrm` behavior |
| [`<ctype.h>`](../firmware/include/ctype.h) | ASCII/C-locale classification and case conversion, plus `isascii` and `toascii` |
| [`<stdlib.h>`](../firmware/include/stdlib.h) | Integer conversion, integer arithmetic utilities, search/sort, PRNG, heap allocation, and immediate termination |
| [`<stdio.h>`](../firmware/include/stdio.h) | Unbuffered console streams and integer-only formatted output |
| [`<time.h>`](../firmware/include/time.h) | Declares BSP-provided `clock` and `time`; profile availability is described under [BSP services](#35-bsp-boundary-and-services) |
| [`<math.h>`](../firmware/include/math.h) | `libm.a`; listed under [Math library](#34-math-library-libma) |
| [`<riscc/platform.h>`](../firmware/include/riscc/platform.h) | Default demo-SoC MMIO definitions and timer helpers |
| [`<riscc/interrupt.h>`](../firmware/include/riscc/interrupt.h) | Optional `libirq.a` API; specified in [Interrupt runtime](#4-interrupt-runtime-libirq) |

`<stdlib.h>` provides:

- `atoi`, `atol`, `strtol`, and `strtoul`;
- `abs`, `labs`, `div`, and `ldiv`;
- `bsearch` and a small selection-sort `qsort`;
- `rand` and `srand`;
- `malloc`, `free`, `calloc`, and `realloc`; and
- `abort`, `exit`, and `_Exit`.

`calloc` checks multiplication overflow. `realloc` is deliberately
allocate/copy/free rather than an in-place growth optimization. `abort`,
`exit`, and `_Exit` ignore process status and halt immediately; there are no
destructors or `atexit` handlers.

The unbuffered `<stdio.h>` layer exposes `stdin`, `stdout`, and `stderr`, plus
`getchar`, `putchar`, `puts`, `fgetc`, `fputc`, `fgets`, and `fputs`.
`printf`, `fprintf`, `sprintf`, `snprintf`, and all four corresponding `v`
forms accept:

- `%%`, `%c`, and `%s`;
- `%d`/`%i`, `%u`, `%x`/`%X`, and `%p`;
- decimal field width and the `-` and `0` flags; and
- `l` for the 32-bit `long` type.

There is no buffering, EOF-producing device, `scanf`, precision, floating
formatting, or `long long` formatting. The console behavior is described in
[Run a UART hello world](#run-a-uart-hello-world).

#### Heap model

The allocator is deliberately small and single-threaded. Allocated blocks
have one 16-bit total-size word; a freed block reuses its first payload word
as the address-ordered free-list link. `free` only inserts, while `malloc`
lazily coalesces adjacent free blocks during a first-fit scan and splits only
a useful remainder. This makes allocation unsuitable for interrupt handlers.

There is no fixed heap or reserved stack. The linker exports `__heap_start`
immediately after the image and `__heap_end` at the RAM ceiling. The private
`sbrk` implementation also compares each proposed heap break with the live
`r7` stack pointer, so allocation may use all memory below the current stack
frame. That check is only a point-in-time limit: a later deeper stack frame can
still collide with and corrupt heap memory, exactly like any unchecked stack
overflow. This is intentional for the tiny single-stack runtime. A future
scheduler can replace the private heap-limit provider with the lowest active
stack bound and add allocator locking without changing the public allocation
API.

### 3.4 Math library: `libm.a`

Classification and ordered comparisons are compiler-backed macros in
`<math.h>`. Every function below has `float`, `double`, and `long double`
forms; `long double` reuses the binary64 implementation.

| Category | Implemented functions |
|---|---|
| Sign | `fabs`, `copysign` |
| Rounding | `trunc`, `floor`, `ceil`, `round`, `lround`, `llround` |
| Comparison/difference | `fmin`, `fmax`, `fdim` |
| Decomposition/scaling | `modf`, `frexp`, `ldexp`, `scalbn`, `scalbln`, `ilogb`, `logb` |
| Representation | `nextafter`, `nexttoward`, `nan` |
| Arithmetic | `sqrt`, `fmod` |

`sqrt` is correctly rounded to nearest with ties to even. Outside Nano's
reduced multiply contract, scaling uses exact powers of two and the
compiler-rt multiply helpers to preserve IEEE rounding at subnormal
boundaries. Wide bit operations use explicit little-endian 16-bit limbs
instead of expanded 64-bit compiler helpers.

The library neither sets `errno` nor exposes floating exceptions;
`math_errhandling` is zero. Transcendentals, `fma`, alternate-rounding-mode
operations such as `rint`, and nearest-quotient operations such as
`remainder` are intentionally absent.

### 3.5 BSP boundary and services

`libc.a` contains no board MMIO definitions. The selected BSP supplies the
hardware-facing services: `getchar`, `putchar`, and `puts` for generic libc
streams, plus any supported `clock` and `time` implementations. The default
`libbsp.a` uses the shared demo UART and timer hardware for these services.

A custom BSP can provide the console functions and whichever clock services it
supports, then set `RISCC_BSP_LIBRARY` before including
[`firmware/riscc.mk`](../firmware/riscc.mk). Objects for unused services are
not extracted from either BSP archive.

[`<riscc/platform.h>`](../firmware/include/riscc/platform.h) describes the
current demo-SoC framebuffer, UART, interrupt-controller, timer, tick-counter,
and LED addresses. It is a default BSP interface, not generic libc.

#### Clock and uptime

`clock()` returns the 1 kHz free-running hardware counter and
`CLOCKS_PER_SEC` is 1000. It is cheap and does not install an IRQ handler, but
it wraps after 65.536 seconds. It measures board ticks, not CPU execution time.

`time()` returns whole seconds since the uptime service was first initialized;
there is no wall-clock epoch. Its first call is sufficient: it installs the
one BSP timer handler through `libirq`, arms the one-shot timer for 1000 ticks,
enables the timer source and global IRQs, and increments a private 32-bit
seconds counter on each timer interrupt. `riscc_time_init()` in
[`<riscc/platform.h>`](../firmware/include/riscc/platform.h) is available when
an application wants that setup earlier. It is idempotent.

Generic startup deliberately performs no BSP initialization before `main`.
An application owns board policy and explicitly initializes any optional BSP
service it needs before first use; calling `riscc_time_init()` near the start
of `main` makes this uptime counter begin at program startup. This keeps a
program which does not use a peripheral from linking or enabling it.

The service has one interrupt per nominal second and re-arms the one-shot from
the handler, so handler latency introduces a small accumulating delay. It is a
tiny uptime clock, not a precision timebase. A scheduler or precision-timer BSP
can replace it without changing generic libc.

`time()` owns `libirq`'s single global C handler and acknowledges the timer by
rearming the one-shot. Do not enable UART IRQs or install another C handler in
an application using this minimal service; the default UART console is polling
and needs neither. A future BSP dispatcher can combine timer and UART callbacks
when an IRQ-driven second device is actually needed. A custom assembly IRQ
vector owns its timer policy and therefore does not use this default time
service.

Supported default services are:

| Service | Full | Sys | Min | Nano |
|---|---:|---:|---:|---:|
| `clock()` | Yes | Yes | Yes | Yes |
| Interrupt-backed `time()` | Yes | Yes | No | No |

`time()` requires `libirq`; Min has no interrupt support, and Nano omits the
uptime object entirely.

### 3.6 Startup and memory layouts

The default startup objects are `vectors.o` and `crt0.o`. The vector table
contains reset and IRQ slots. `crt0.o` establishes `r7` from `__stack_top`,
clears the zero-initialized range, calls `main`, then executes the `HALT`
(`JMP8 -1`) loop if `main` returns. On non-Nano profiles it also establishes
the initial `S2` TLS anchor from `__tls_start`.

[`firmware/unified.ld`](../firmware/unified.ld) places vectors, code, constants,
initialized data, TLS, and ordinary data in one 32 KiB RAM address space.
[`firmware/split.ld`](../firmware/split.ld) keeps code and data logically
separate: executable VMAs begin at zero and data VMAs use the ELF-only
`0x10000` tag. That tag never reaches a RISC-C data pointer.

In both layouts, `.tdata` follows ordinary initialized data and supplies the
initial TLS template; `.tbss` is followed by `.bss` in the range cleared by
startup. The linker exports `__tls_start`, `__tdata_end`, `__tbss_start`,
`__tls_end`, `__bss_start`, `__bss_end`, `__zero_start`, `__zero_end`,
`__heap_start`, `__heap_end`, and `__stack_top` for startup or platform code.

For a split image, extract executable and initialized data sections separately:

```sh
llvm-objcopy -O binary --only-section=.vectors --only-section='.text*' app.elf app.code.bin
llvm-objcopy -O binary --only-section='.rodata*' --only-section='.data*' \
  --only-section='.tdata*' app.elf app.data.bin
```

`.bss` and `.tbss` are absent from images. A split-memory platform must preload
the data image or provide an equivalent data-initialization transport; the
generic startup never reads instruction memory as data. Current board targets
use the unified layout.

### 3.7 TLS runtime use

The mainline ABI assigns non-negative `S2` offsets to C TLS. Its default
startup makes one initial TLS instance by placing `S2` at `__tls_start` and
clearing `.tbss`. A scheduler or RTOS which creates another thread allocates
its own context and TLS block, copies the `.tdata` template, clears its
`.tbss`, and installs that thread's `S2` on a context switch. Negative `S2`
offsets are runtime-private; their layout is not a C ABI interface.

RISC-C currently has no memory protection or privilege model. The register
convention is therefore a cooperation contract among mutually trusted
software. Interrupt and context-switch code preserves the TLS anchor in `S2`
and any live compiler-managed state in `S3..S7`; a context switch
saves/restores those registers with the other thread state.

Nano has no S-register bank or TLS. Its startup therefore omits the `S2`
initialization described above.

### 3.8 Deliberate omissions

The runtime currently provides none of the following:

- floating-point parsing or formatted output;
- transcendental or comprehensive hosted libm facilities;
- `scanf`, files, or an EOF-producing input device;
- locale beyond ASCII/C, or multibyte/wide-character APIs;
- calendar conversion and time APIs other than `clock` and `time`;
- threads, atomics, processes, environment variables, or POSIX APIs;
- destructors and `atexit`; or
- shared libraries and dynamic linking.

## 4. Interrupt runtime (`libirq`)

There is one hardware IRQ vector. The default vector slot transfers to
`__riscc_irq_vector`; application code may provide a strong assembly definition
of that symbol and own the entire entry/exit convention. If it does not, the
weak `libirq.a` fallback is a two-byte halt loop. This keeps an application
that does not use C interrupt handling from pulling in a wrapper or IRQ state.

The public API is:

```c
typedef void (*riscc_irq_handler_t)(void);
void riscc_irq_set_handler(riscc_irq_handler_t handler);
void riscc_irq_enable(void);
void riscc_irq_disable(void);
```

Calling `riscc_irq_set_handler(fn)` extracts the C wrapper and installs the
single global handler pointer. Passing null selects the default halt loop.
`riscc_irq_enable()` and `riscc_irq_disable()` are independent C-callable
`STI`/`CLI` helpers and remain usable with a custom assembly vector. Install a
normal C handler before enabling interrupts; it must acknowledge each
level-sensitive source it services.

The supplied wrapper is non-nesting. Hardware arrives with `S0` containing
EPC and interrupts masked; the wrapper returns with `RETI S0`. It saves only
the interrupted caller-volatile GPRs (`r0..r4` and `r7`) and all
compiler-managed `S3..S7`, not a full task context. It never assumes the
interrupted `r7` is a stack pointer: it saves that state in a 22-byte prefix
immediately below `S2`, then runs the C handler on one 64-byte global
downward-growing IRQ stack. `r5` and `r6` are ordinary callee-saved registers.
Consequently, the hand-written runtime's leaf routines can use fixed negative
offsets from their incoming `r7` for short-lived scratch without moving the
stack pointer. Known internal caller/callee pairs reserve non-overlapping
scratch words. This is an implementation convention inside the supplied
runtime, not an ABI red zone available to arbitrary C code.

The wrapper keeps interrupts disabled and cannot support nesting because the
architecture has one EPC register. A handler must not execute `STI`, `RETI`,
or otherwise enable nested interrupts. A future nested design must switch to
another stack and, where appropriate, another TLS/context before enabling an
inner interrupt. An RTOS using this wrapper reserves its 22-byte prefix for
each thread; custom vectors need not use the prefix or global stack.

## 5. Compiler checks and smoke programs

`make -j16 test-compiler` rebuilds the current firmware dependencies,
exhaustively checks Full-profile LLVM MC encoding against the in-tree
assembler, and runs the multi-file C smoke suite in the ISS, Tiny16/full RTL,
Fast RTL, Icepi Zero UART simulation, and Atum UART simulation. Nano-specific
MC encodings and profile restrictions have focused LLVM `lit` coverage but are
not yet part of that exhaustive oracle. `make compiler-smoke` uses the Icepi
Zero RTL run as its default target.

The smoke program covers globals, constants, BSS, TLS, calls, recursion,
aggregates, function pointers, and 16/32/64-bit integer arithmetic.  The
`compiler-features-iss` matrix adds focused C11 language, control-flow,
promotion, layout, bit-field, pointer, memory, aggregate-call, hidden-result,
callee-save, sibling-tail-call, and complete integer-runtime-helper checks. It
also executes `memcpy`, `memmove`, and `memset`, including overlap and
zero-length cases. Both programs run at `-O0`, `-O2`, and `-Os` on the ISS.
The separate `compiler-float-iss` matrix covers binary32/binary64 arithmetic,
comparisons and NaNs, signed and unsigned 32-/64-bit conversions, cross-file
scalar and aggregate calls, `long double`, stack arguments, and variadic
promotion. Mainline binary32 cases include signed zero, overflow, subnormal
boundaries, and ties-to-even rounding; Nano instead exercises its documented
finite-normal arithmetic and signed flush-to-zero contract.
`compiler-libm-iss` runs two separately linked images that check archive
extraction, classification, signed zero, NaNs and infinities, subnormal
boundaries, and the public
float/double/long-double functions at the same three optimization levels. The
focused LLVM regression also checks the backend lowering for each supported
math intrinsic.
`test-compiler-profiles-iss` runs all three matrices for `full`, `sys`, `min`,
and `nano`; the individual
integer feature targets are
`compiler-features-sys-iss`, `compiler-features-min-iss`, and
`compiler-features-nano-iss`. The corresponding focused floating-point targets
are `compiler-float-sys-iss`, `compiler-float-min-iss`, and
`compiler-float-nano-iss`.
`compiler-features-nano-rtl` runs the same Nano binaries at all three
optimization levels on the Nano RTL model.

`compiler-benchmarks-iss` runs small, deterministic workloads at `-O2` and
`-Os`: 32-bit arithmetic, soft-float/libm, float matrix multiplication with
LU, Cholesky, and QR decompositions, and linked-list, tree, and graph
algorithms. These are intended for before/after code-size and cycle
comparisons; the focused suites above remain the correctness baseline.

`compiler-libc-iss` separately links each tiny-runtime probe through the
runtime archives at the same three optimization levels. It covers string and
ctype boundaries,
integer conversion and search utilities, UART stream and every formatter entry
point, allocator splitting/coalescing/reallocation and heap collision, the
small libm surface, and immediate termination through `abort`, `exit`, `_Exit`,
and failed `assert`.
It also verifies that an application-provided BSP console works without
extracting the default UART backend, and that `clock()` does not pull IRQ
state while `time()` installs and arms its BSP service. UART probes compare
exact byte streams. `compiler-libc-size` checks the all-features image remains
within 4 KiB of `.text` and 32 bytes of combined `.data`/`.bss`;
`test-compiler` runs both targets.

`compiler-libc-nano-iss` runs the portable libc probes on Nano at the same
three optimization levels. It excludes only `time()` and the timer probe,
which require the S-register interrupt facility that Nano does not have.
`test-compiler-nano` combines this libc matrix with the Nano feature tests on
both the ISS and RTL model.

The remaining compiler suite exercises C-wrapper and assembly-owned IRQ
vectors. The split-image check verifies that `.tdata` appears in the data image
and `.tbss` does not. It also pipes one byte into a C `getchar()` call in the
ISS, verifies the `putchar()` echo and `puts()` newline, and verifies that
returning from `main` halts normally.

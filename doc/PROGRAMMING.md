# RISC-C Programming Manual

This manual describes the software environment around the RISC-C ISA: writing
assembly and C, the compiler/runtime, and application images. The normative
instruction definition is the [ISA specification](RISC-C.md); the normative
C and ELF interoperability contract is the [C and object ABI](RISC-C-ABI.md).
Hardware implementation, board builds, and FPGA flows are in the
[Hardware manual](HARDWARE.md).

## 1. Software tools and the ISS

The in-tree assembler is the useful reference encoder for ISA work and small
standalone assembly programs:

```sh
python3 tools/riscc_asm.py --profile full program.asm -o program.bin
python3 tools/riscc_asm.py --profile nano program.asm -o program.bin
```

It accepts `.ifdef NAME`, `.ifndef NAME`, `.else`, and `.endif`; pass
`-D NAME` to define a symbol. Selecting `--profile min`, `sys`, `full`, or
`nano` also defines the corresponding profile symbol. LLVM MC is the
production assembler for compiler objects; `make check-llvm-mc-encodings`
cross-checks its encodings against `riscc_asm.py`.

The normal interactive ISS is `tools/riscc_sim.cpp`, built as
`build/tools/riscc_sim`. It executes the architectural ISA and provides the
same testbench MMIO page used by the RTL tests, including the result register,
UART, and framebuffer model. `tools/riscc_sim.py` is the slower reference and
fallback ISS; it has the same basic ISA, trace, UART, and framebuffer behavior.

Build the C++ ISS once, then select the profile that matches the image:

```sh
make build/tools/riscc_sim
build/tools/riscc_sim program.bin             # sys profile, /16 cycle model
build/tools/riscc_sim program.bin --min
build/tools/riscc_sim program.bin --full --width 4
build/tools/riscc_sim program.bin --nano
```

`--min` and `--full` are mutually exclusive; no profile option selects `sys`.
`--nano` is separate and cannot be combined with either mainline option.
`--width 1|2|4|8|16` selects the Tiny cycle model, not a different ISA. For an
approximate Fast timing model use `--fast` or `--fast-dsp`; these are useful
for interactive estimates but are not RTL timing results.

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
SoCs. They are the current runtime UART contract, not general-purpose RAM:

| Byte address | Register | Availability |
|---:|---|---|
| `0xfff0` | UART TX data | ISSes and current demo boards |
| `0xfff2` | UART RX data (read consumes the byte) | ISSes and current demo boards |
| `0xfff4` | UART status: TX-ready bit 0, RX-ready bit 1, RX-overflow bit 2 | ISSes and current demo boards |
| `0xfff6` | UART IRQ control: RX enable bit 0, TX enable bit 1 | ISSes and current demo boards |
| `0xfff8` | Testbench IRQ acknowledge / cause log | ISSes and generic RTL testbench only |
| `0xfffa` | Testbench IRQ trigger | ISSes and generic RTL testbench only |
| `0xfffc` | Testbench scratch word | ISSes and generic RTL testbench only |
| `0xfffe` | Test result word | ISSes and generic RTL testbench only |

The demo SoCs reserve their high MMIO aperture, but do not implement the four
testbench devices. Board firmware must not use `0xfff8..0xfffe` as RAM or
expect test-result/IRQ behavior there.

### Run a UART hello world

`--uart` bridges the simulated UART: target transmit bytes go to host standard
output and host standard input supplies target receive bytes. The freestanding
runtime provides a deliberately small [`<stdio.h>`](../firmware/include/stdio.h)
subset: `putchar(int)`, `getchar(void)`, and `puts(const char *)`. `putchar`
blocks for TX-ready and returns the written unsigned byte. `getchar` blocks
for RX-ready and returns a value from 0 through 255; there is no EOF. `puts`
writes its string followed by a newline and returns zero. `FILE`, `printf`,
and every other hosted stdio interface remain unavailable.

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
160x120 framebuffer, `--fb-scale N` chooses its initial scale, and
`--fb-dump-png FILE` writes the final image. `--mhz N` throttles a long-running
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

The C target is freestanding `riscc-none-elf -mcpu=full`. The initial compiler
supports integer C at `-O0`, `-O2`, and `-Os`, ordinary global and TLS objects,
stack frames, aggregate calls and returns, function pointers, and 16-, 32-,
and 64-bit integer operations. It has no hosted environment or full libc;
the supplied headers include minimal `<stdio.h>`, `<stdarg.h>`, and
`<riscc/interrupt.h>`. Variadic functions keep named arguments on the ordinary
ABI convention and place unnamed arguments on the stack; see the normative
[C and object ABI](RISC-C-ABI.md#4-calls-arguments-and-results) for `va_list`
semantics. It has no VLA/dynamic allocation, soft float, PIC, atomics, exceptions,
unwinding, jump tables, tail calls, compiler interrupt attributes, or C++
runtime.

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

The essentials of the direct invocation are:

```sh
build/llvm-riscc/bin/clang --target=riscc-none-elf -mcpu=full \
  -Os -ffreestanding -fno-builtin -ffunction-sections -fdata-sections \
  -Ifirmware/include -c hello.c -o hello.o
build/llvm-riscc/bin/clang --target=riscc-none-elf -mcpu=full \
  -fuse-ld=lld -nostdlib -Wl,--gc-sections -Wl,-T,firmware/unified.ld \
  build/firmware/vectors.o build/firmware/crt0.o hello.o \
  build/firmware/libirq.a build/firmware/libbuiltins.a \
  build/firmware/libc.a -o hello.elf
```

`-ffunction-sections -fdata-sections` and `--gc-sections` are deliberate:
they keep static runtime support pay-for-what-is-referenced. Archive extraction
selects only needed object files, and section garbage collection discards
unreachable functions and data within selected objects.

## 3. Runtime libraries

`make riscc-firmware` produces these archives under `build/firmware`:

| Archive | Purpose |
|---|---|
| `libbuiltins.a` | compiler helpers for division, remainder, wide integer arithmetic, shifts, comparisons, and related lowering |
| `libc.a` | `memcpy`, `memmove`, `memset`, and UART-backed `putchar`/`getchar`/`puts` |
| `libirq.a` | optional interrupt fallback, control helpers, and C-handler wrapper |

They are intentionally not a general libc. Public headers are the minimal
[`<stdio.h>`](../firmware/include/stdio.h) subset and
[`<riscc/interrupt.h>`](../firmware/include/riscc/interrupt.h); standard C
headers and a port of picolibc are future work. The static archive is built
with per-function sections and linked with `--gc-sections`, so using
`puts` does not retain `getchar` or unrelated routines.

### Startup and layouts

The default startup objects are `vectors.o` and `crt0.o`. The vector table
contains reset and IRQ slots. `crt0.o` establishes `r7` from `__stack_top`,
establishes the initial `S2` TLS anchor from `__tls_start`, clears the
zero-initialized range, calls `main`, then executes the `HALT` (`JMP8 -1`)
loop if `main` returns.

[`firmware/unified.ld`](../firmware/unified.ld) places vectors, code, constants,
initialized data, TLS, and ordinary data in one 32 KiB RAM address space.
[`firmware/split.ld`](../firmware/split.ld) keeps code and data logically
separate: executable VMAs begin at zero and data VMAs use the ELF-only
`0x10000` tag. That tag never reaches a RISC-C data pointer.

In both layouts, `.tdata` follows ordinary initialized data and supplies the
initial TLS template; `.tbss` is followed by `.bss` in the range cleared by
startup. The linker exports `__tls_start`, `__tdata_end`, `__tbss_start`,
`__tls_end`, `__bss_start`, `__bss_end`, `__zero_start`, `__zero_end`, and
`__stack_top` for startup or platform code.

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

### TLS runtime use

The ABI assigns non-negative `S2` offsets to C TLS. The default startup makes
one initial TLS instance by placing `S2` at `__tls_start` and clearing `.tbss`.
A scheduler or RTOS which creates another thread allocates its own context and
TLS block, copies the `.tdata` template, clears its `.tbss`, and installs that
thread's `S2` on a context switch. Negative `S2` offsets are runtime-private;
their layout is not a C ABI interface.

RISC-C currently has no memory protection or privilege model. The register
convention is therefore a cooperation contract among mutually trusted
software. Interrupt and context-switch code conventionally preserves `S2` and
`S3`; a context switch saves/restores `S2` with the other thread state.

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
the ordinary-call clobbers (`r0..r4`, `r7`, and `S7`), not a full task context.
It never assumes the interrupted `r7` is a stack pointer: it saves that value
in a 14-byte prefix immediately below `S2`, then runs the C handler on one
64-byte global downward-growing IRQ stack. `r5` and `r6` are ordinary
callee-saved registers, and generated C does not allocate `S2..S6`.

The wrapper keeps interrupts disabled and cannot support nesting because the
architecture has one EPC register. A handler must not execute `STI`, `RETI`,
or otherwise enable nested interrupts. A future nested design must switch to
another stack and, where appropriate, another TLS/context before enabling an
inner interrupt. An RTOS using this wrapper reserves its 14-byte prefix for
each thread; custom vectors need not use the prefix or global stack.

## 5. Compiler checks and smoke programs

`make -j16 test-compiler` rebuilds the current firmware dependencies, checks
LLVM MC encoding against the in-tree assembler, and runs the multi-file C
smoke suite in the ISS, Tiny16/full RTL, Fast RTL, Icepi Zero UART simulation,
and Atum UART simulation. `make compiler-smoke` uses the Icepi Zero RTL run
as its default target.

The smoke program covers globals, constants, BSS, TLS, calls, recursion,
aggregates, function pointers, and 16/32/64-bit integer arithmetic.  The
`compiler-features-iss` matrix adds focused C11 language, control-flow,
promotion, layout, bit-field, pointer, memory, aggregate-call, hidden-result,
callee-save, and complete integer-runtime-helper checks.  It also executes
`memcpy`, `memmove`, and `memset`, including overlap and zero-length cases.
Both programs run at `-O0`, `-O2`, and `-Os` on the ISS.

The remaining compiler suite exercises C-wrapper and assembly-owned IRQ
vectors. The split-image check verifies that `.tdata` appears in the data image
and `.tbss` does not. It also pipes one byte into a C `getchar()` call in the
ISS, verifies the `putchar()` echo and `puts()` newline, and verifies that
returning from `main` halts normally.

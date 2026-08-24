.DEFAULT_GOAL := all

PROFILES := nano min sys full
RC16_PROFILES := min sys full
RC32_PROFILES := min sys full
WIDTHS := 1 2 4 8 16
TEST_MODES := native ecp5-lutram ecp5-block
EXTENSIONS := mulh muldiv
FAST_MEMORIES := async ecp5 ecp5-block agilex
FASTER_MEMORIES := ecp5-block agilex
MULTIPLIERS := soft dsp
PIPELINES := fast faster
OPT_LEVELS := o0 o2 os
BENCH_OPT_LEVELS := o2 os

PROFILE ?= full
WIDTH ?= 16
MODE ?= native
EXTENSION ?= muldiv
MEMORY ?= async
MULTIPLIER ?= soft

PYTHON ?= python3
PYTHONDONTWRITEBYTECODE ?= 1
export PYTHONDONTWRITEBYTECODE
CXX ?= g++
RISCC_VERSION := $(strip $(shell cat VERSION))
PKG_CONFIG ?= pkg-config
VERILATOR ?= verilator
YOSYS ?= yosys
NEXTPNR_ECP5 ?= nextpnr-ecp5
PNR_SEED ?= 1
TUNE_SEEDS ?= 1
ECPPACK ?= ecppack
QUARTUS_SH ?= quartus_sh
QUARTUS_CDB ?= $(patsubst %quartus_sh,%quartus_cdb,$(QUARTUS_SH))
QUARTUS_ASM ?= $(patsubst %quartus_sh,%quartus_asm,$(QUARTUS_SH))
QUARTUS_FLOW_ARGS ?=

# Pass Make's -j value to nested LLVM and Quartus builds.  Without an explicit
# -j, nested tools use every host CPU; use `make -jN` for parallel prerequisites.
RISCC_BUILD_JOBS ?= $(or \
	$(patsubst -j%,%,$(filter -j%,$(MAKEFLAGS))), \
	$(patsubst --jobs=%,%,$(filter --jobs=%,$(MAKEFLAGS))),$(shell nproc))
CCACHE ?= $(shell command -v ccache 2>/dev/null)
CCACHE_DIR ?= $(CURDIR)/build/ccache
export CCACHE_DIR

TB_CXXFLAGS ?= -std=c++17
RISCC_SIM_CXXFLAGS ?= -std=c++17 -O3 -DNDEBUG -DRISCC_VERSION=\"$(RISCC_VERSION)\"
SDL2_CFLAGS ?= $(shell $(PKG_CONFIG) --cflags sdl2 2>/dev/null)
SDL2_LIBS ?= $(shell $(PKG_CONFIG) --libs sdl2 2>/dev/null)
STB_CFLAGS ?= $(shell $(PKG_CONFIG) --cflags stb 2>/dev/null)
STB_LIBS ?= $(shell $(PKG_CONFIG) --libs stb 2>/dev/null)
VERILATOR_OPT_FAST ?= -O1
VERILATOR_OPT_GLOBAL ?= -O1
OBJCACHE ?= $(CCACHE)
VERILATOR_MAKEFLAGS ?= $(strip \
	OPT_FAST=$(VERILATOR_OPT_FAST) OPT_GLOBAL=$(VERILATOR_OPT_GLOBAL) \
	OBJCACHE=$(OBJCACHE))
VERILATOR_MAKEFLAGS_ARG = -MAKEFLAGS "$(VERILATOR_MAKEFLAGS)"

TB_SRC := test/riscc_test.cpp
RTL_TEST_DIR := rtl/test
TRACE_RTL := $(RTL_TEST_DIR)/riscc_trace_ports.vh $(RTL_TEST_DIR)/riscc_trace_state.vh
RISCC_RF_RTL := rtl/riscc_rf.vh
RISCC_SIM := build/tools/riscc_sim
BENCH_BIN := build/bin/bench.bin
NANO_BENCH_BIN := build/bin/bench-nano.bin
FUNNEL_BIN := build/bin/funnel.bin
RC32_SYS_BIN := build/bin/rc32-sys.bin
RC32_SYS_ISS_BIN := build/bin/rc32-sys-iss.bin
ISA_IRQ_BIN := build/bin/isa-irq.bin
ISA_IRQ_MDU_BIN := build/bin/isa-irq-mdu.bin
RC32_ISA_IRQ_BIN := build/bin/rc32-isa-irq.bin
RC32_FULL_ISA_IRQ_BIN := build/bin/rc32-full-isa-irq.bin
RC32_MDU_BIN := build/bin/rc32-mdu.bin
RC32_MIN_TRACE_BIN := build/bin/rc32-min-trace.bin
HIGH_ADDRESS_BIN := build/bin/high-address.bin
PERIPHERAL_TB := build/tb/peripherals/tb
PERIPHERAL_RTL := boards/shared/rtl/riscc_timer_mmio.v \
	boards/shared/rtl/riscc_irq_ctrl.v \
	$(RTL_TEST_DIR)/riscc_peripherals_top.v

empty :=
space := $(empty) $(empty)
comma := ,
join_with_commas = $(subst $(space),$(comma),$(strip $(1)))

# The /16 cores are separate modules; narrower cores share a serial module.
RC16_MODULE_PREFIX_1 := riscc
RC16_MODULE_PREFIX_2 := riscc
RC16_MODULE_PREFIX_4 := riscc
RC16_MODULE_PREFIX_8 := riscc
RC16_MODULE_PREFIX_16 := riscc16

RC16_IMPLEMENTATION_1 := serial
RC16_IMPLEMENTATION_2 := serial
RC16_IMPLEMENTATION_4 := serial
RC16_IMPLEMENTATION_8 := serial
RC16_IMPLEMENTATION_16 := wide

RC16_TOP_SUFFIX_min := _min
RC16_TOP_SUFFIX_sys :=
RC16_TOP_SUFFIX_full :=

RC16_VERILATOR_WIDTH_1 := -GW=1
RC16_VERILATOR_WIDTH_2 := -GW=2
RC16_VERILATOR_WIDTH_4 := -GW=4
RC16_VERILATOR_WIDTH_8 := -GW=8
RC16_VERILATOR_WIDTH_16 :=

RC16_YOSYS_WIDTH_1 = chparam -set W 1 $(call rc16_top,1,$(1));
RC16_YOSYS_WIDTH_2 = chparam -set W 2 $(call rc16_top,2,$(1));
RC16_YOSYS_WIDTH_4 = chparam -set W 4 $(call rc16_top,4,$(1));
RC16_YOSYS_WIDTH_8 = chparam -set W 8 $(call rc16_top,8,$(1));
RC16_YOSYS_WIDTH_16 :=

rc16_implementation = $(RC16_IMPLEMENTATION_$(1))
rc16_source = rtl/$(RC16_MODULE_PREFIX_$(1))_$(2).v
rc16_top = $(RC16_MODULE_PREFIX_$(1))$(RC16_TOP_SUFFIX_$(2))
rc16_verilator_width = $(RC16_VERILATOR_WIDTH_$(1))
rc16_yosys_width = $(call RC16_YOSYS_WIDTH_$(1),$(2))

SIM_FLAGS_min := --min
SIM_FLAGS_sys :=
SIM_FLAGS_full := --full
SIM_FLAGS_nano := --nano

ASM_DEFINES_min := RISCC_MIN
ASM_DEFINES_sys := RISCC_SYS
ASM_DEFINES_full := RISCC_FULL RISCC_SYS
ASM_DEFINES_nano := RISCC_NANO

RF_DEFINES_native :=
RF_DEFINES_ecp5-lutram := -DRISCC_ECP5
RF_DEFINES_ecp5-block := -DRISCC_ECP5 -DRISCC_ECP5_BLOCK_RF

MEMORY_DEFINES_async :=
MEMORY_DEFINES_ecp5 := -DRISCC_ECP5
MEMORY_DEFINES_ecp5-block := -DRISCC_FAST_SYNC_RF
MEMORY_DEFINES_agilex := -DRISCC_FAST_AGILEX
FASTER_MEMORY_DEFINES_ecp5-block := -DRISCC_FASTER_BLOCK_RF
FASTER_MEMORY_DEFINES_agilex :=
MULTIPLIER_DEFINES_soft :=
MULTIPLIER_DEFINES_dsp := -DRISCC_FAST_DSP
fast_defines = $(MEMORY_DEFINES_$(1)) $(MULTIPLIER_DEFINES_$(2))

include mk/toolchain.mk
include mk/firmware.mk
include mk/rtl.mk
include mk/boards.mk
include mk/measure.mk
include mk/compiler-tests.mk

.PHONY: help clean distclean

help:
	@printf '%s\n' \
	  'Usage: make TARGET [VARIABLE=value]' \
	  '' \
	  'Build' \
	  '  all                         correctness tests and benchmarks' \
	  '  firmware                    runtime for PROFILE' \
	  '  firmware-all                runtimes for all profiles' \
	  '  firmware-rc32               RC32 Min, Sys, and Full runtimes' \
	  '  llvm-riscc-configure        configure the LLVM toolchain' \
	  '  llvm-riscc                  build the LLVM toolchain' \
	  '  clean                       remove generated tests and reports' \
	  '  distclean                   also remove the toolchain and runtimes' \
	  '' \
	  'RTL and instruction simulator' \
	  '  asm                         assemble every test image' \
	  '  sim-cpp                     build the instruction simulator' \
	  '  sim                         simulate PROFILE' \
	  '  sim-all                     simulate every profile' \
	  '  sim-fast                    simulate fast core instructions' \
	  '  test                        test PROFILE, WIDTH, and MODE' \
	  '  test-core                   same as test' \
	  '  test-cores                  test all RC16 profiles and widths' \
	  '  test-extension              test EXTENSION and MODE' \
	  '  test-extensions             test all arithmetic extensions' \
	  '  test-nano                   test Nano' \
	  '  test-fast                   test MEMORY and MULTIPLIER' \
	  '  test-fast-all               test all fast-core variants' \
	  '  test-faster                 test Faster ECP5/Agilex RF variants' \
	  '  test-funnel                 test interrupt funneling' \
	  '  test-peripherals            test timer and interrupt peripherals' \
	  '  test-rc32                   test and fuzz RC32 Min, Sys, and Full' \
	  '  test-nano-application       build/run riscc.mk Nano application' \
	  '  test-rc32-application       build/run riscc.mk RC32 application' \
	  '  test-isa                    test every supported ISA instruction' \
	  '  test-high-address           test RC16 execution near 0x8000/0xfffe' \
	  '  test-rtl                    run the complete RTL regression' \
	  '  test-all                    run all deterministic correctness tests' \
	  '  fuzz                        fuzz RC16 and Nano' \
	  '  fuzz-rc32                   fuzz RC32' \
	  '  fuzz-fast                   fuzz fast cores' \
	  '  fuzz-faster                 final-state fuzz Faster cores' \
	  '  fuzz-all                    run all fuzz campaigns' \
	  '  trace                       trace PROFILE and WIDTH' \
	  '  trace-nano                  trace Nano' \
	  '  trace-rc32                  trace RC32 PROFILE and WIDTH' \
	  '  trace-fast                  trace MEMORY and MULTIPLIER' \
	  '  bench                       run core benchmarks' \
	  '  check-regressions           enforce size/cycle/ECP5 PPA limits' \
	  '' \
	  'Compiler and libraries' \
	  '  compiler-smoke              compiler smoke tests in ISS and RTL' \
	  '  compiler-stdio              stdio UART test' \
	  '  compiler-irqs               compiler interrupt tests' \
	  '  compiler-smoke-matrix       smoke tests at O0, O2, and Os' \
	  '  compiler-features           C and ABI feature tests' \
	  '  compiler-features-rtl       feature tests on Nano RTL' \
	  '  compiler-benchmarks         compiler benchmark programs' \
	  '  compiler-float              floating-point compiler tests' \
	  '  compiler-profiles           feature tests for every profile' \
	  '  compiler-libc               libc tests' \
	  '  compiler-libm               libm tests' \
	  '  compiler-libc-size          report and check libc size' \
	  '  compiler-nano               Nano compiler and library tests' \
	  '  compiler-cpp                freestanding C++ matrix and policy' \
	  '  check-llvm-mc-encodings     compare assembler encodings' \
	  '  check-rc32-mc-encodings     compare RC32 encodings' \
	  '  check-llvm-riscc            run LLVM RISC-C lit tests' \
	  '  test-compiler               run the compiler/runtime regression' \
	  '' \
	  'FPGA measurements' \
	  '  area                        Lattice area tables' \
	  '  area-lattice                Lattice area tables' \
	  '  area-agilex                 Agilex area table' \
	  '  area-all                    all area tables' \
	  '  fmax                        Lattice Fmax tables' \
	  '  fmax-lattice                Lattice Fmax tables' \
	  '  fmax-agilex                 Agilex Fmax table' \
	  '  fmax-all                    all Fmax tables' \
	  '  characterize-agilex         characterize AGILEX_FAMILY' \
	  '  tables-lattice              tuned Lattice area, Fmax, and benchmarks' \
	  '  tables                      all FPGA tables and benchmarks' \
	  '' \
	  'Boards' \
	  '  icepi-zero-demo-bin         Icepi Zero demo firmware' \
	  '  icepi-zero-demo-iss         run the demo in the ISS' \
	  '  icepi-zero-demo-iss-test    check the demo ISS output' \
	  '  icepi-zero-demo-rtlsim      run the demo in RTL simulation' \
	  '  icepi-zero-demo-json        synthesize the Icepi Zero demo' \
	  '  icepi-zero-demo-bit         build the Icepi Zero bitstream' \
	  '  icepi-zero-video-test-bit   build the video-test bitstream' \
	  '  atum-a3-demo-bin            Atum A3 Nano demo firmware' \
	  '  atum-a3-demo-iss            run the demo in the ISS' \
	  '  atum-a3-demo-rtlsim         run the demo in RTL simulation' \
	  '  atum-a3-demo                build the Atum A3 Nano image' \
	  '' \
	  'Utilities' \
	  '  version                     print the RISC-C version' \
	  '  check-version               compare VERSION with the ISA manual' \
	  '  help                        show this list' \
	  '' \
	  'Selections' \
	  '  PROFILE=nano|min|sys|full   default: full' \
	  '  WIDTH=1|2|4|8|16           default: 16' \
	  '  MODE=native|ecp5-lutram|ecp5-block' \
	  '  EXTENSION=mulh|muldiv       default: muldiv' \
	  '  MEMORY=async|ecp5|ecp5-block|agilex' \
	  '  MULTIPLIER=soft|dsp         default: soft' \
	  '  TUNE_SEEDS=N                seeds searched by tables-lattice (default: 1)' \
	  '  QUARTUS_SH=/path/quartus_sh required for Agilex targets'

clean:
	rm -rf __pycache__ tools/build
	@if test -d build; then \
	  find build -mindepth 1 -maxdepth 1 ! -name llvm-riscc ! -name firmware \
	    -exec rm -rf {} +; \
	fi

distclean: clean
	rm -rf build/llvm-riscc build/firmware

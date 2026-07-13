PYTHON ?= python3
# Build and test helpers import project modules; do not leave their bytecode
# caches in the source tree.
PYTHONDONTWRITEBYTECODE ?= 1
export PYTHONDONTWRITEBYTECODE
CXX ?= g++
RISCC_VERSION := $(strip $(shell cat VERSION))
PKG_CONFIG ?= pkg-config
VERILATOR ?= verilator
YOSYS ?= yosys
NEXTPNR_ECP5 ?= nextpnr-ecp5
NEXTPNR_ICE40 ?= nextpnr-ice40
ECP5_FMAX_SEED ?= 1
ICE40_FMAX_SEED ?= 1
ECPPACK ?= ecppack
QUARTUS_SH ?= quartus_sh
QUARTUS_FLOW_ARGS ?=
# External tools use the same numeric job count as the invoking Make. A plain
# `make` is single-threaded; use `make -j16 ...` to give Make, LLVM, and
# Quartus the same cap.
RISCC_BUILD_JOBS ?= $(or $(patsubst -j%,%,$(filter -j%,$(MAKEFLAGS))),$(patsubst --jobs=%,%,$(filter --jobs=%,$(MAKEFLAGS))),1)
CCACHE_EXE ?= $(shell command -v ccache 2>/dev/null)
# Use ccache's configured persistent cache directory (normally
# ~/.cache/ccache).  Do not fall back to /tmp: a compiler cache must survive
# normal reboots and be shared with the user's other builds.
CCACHE_DIR ?= $(shell c="$(CCACHE_EXE)"; \
	if [ -n "$$c" ]; then $$c --get-config cache_dir 2>/dev/null; fi)
ifneq ($(strip $(CCACHE_DIR)),)
export CCACHE_DIR
endif
CCACHE ?= $(if $(strip $(CCACHE_DIR)),$(CCACHE_EXE))

TB_CXXFLAGS ?= -std=c++17
RISCC_SIM_CXXFLAGS ?= -std=c++17 -O3 -DNDEBUG -DRISCC_VERSION=\"$(RISCC_VERSION)\"
SDL2_CFLAGS ?= $(shell $(PKG_CONFIG) --cflags sdl2 2>/dev/null)
SDL2_LIBS ?= $(shell $(PKG_CONFIG) --libs sdl2 2>/dev/null)
STB_CFLAGS ?= $(shell $(PKG_CONFIG) --cflags stb 2>/dev/null)
STB_LIBS ?= $(shell $(PKG_CONFIG) --libs stb 2>/dev/null)
VERILATOR_OPT_FAST ?= -O1
VERILATOR_OPT_GLOBAL ?= -O1
TB_SRC := test/riscc_test.cpp
RTL_TEST_DIR := rtl/test
TRACE_RTL := $(RTL_TEST_DIR)/riscc_trace_ports.vh $(RTL_TEST_DIR)/riscc_trace_state.vh
RISCC_RF_RTL := rtl/riscc_rf.vh
RISCC_SIM := build/tools/riscc_sim

OBJCACHE ?= $(CCACHE)
VERILATOR_MAKEFLAGS ?= $(strip OPT_FAST=$(VERILATOR_OPT_FAST) OPT_GLOBAL=$(VERILATOR_OPT_GLOBAL) $(if $(OBJCACHE),OBJCACHE=$(OBJCACHE)))
VERILATOR_MAKEFLAGS_ARG = $(if $(strip $(VERILATOR_MAKEFLAGS)),-MAKEFLAGS "$(VERILATOR_MAKEFLAGS)")

TINY_WIDTHS := 1 2 4 8 16
SERIAL_WIDTHS := 1 2 4 8

tiny_rtl = $(if $(filter 16,$(1)),rtl/riscc_tiny16.v,rtl/riscc_tiny.v)
tiny_top = $(if $(filter 16,$(1)),riscc_tiny16,riscc_tiny)
tiny_width_arg = $(if $(filter 16,$(1)),,-GW=$(1))
tiny_yosys_width = $(if $(filter 16,$(1)),,chparam -set W $(1) riscc_tiny;)

# ---- Naming helpers ---------------------------------------------------

empty :=
space := $(empty) $(empty)
comma := ,
comma_join = $(subst $(space),$(comma),$(strip $(1)))

bench_bin = build/bin/riscc-bench.bin
nano_bench_bin = build/bin/riscc-bench-nano.bin

tiny_tb = build/tb/tiny$(1)-$(2)/tb
tiny_matrix_tb = build/matrix/tb/tiny$(1)-$(2)/tb
tiny_trace_tb = build/trace/tiny$(1)-$(2)/tb

area_cell = build/area/$(1)/tiny$(2)/$(3).lut
ecp5_rf_area_cell = build/area/ecp5-$(1)/tiny$(2)/$(3).lut
ecp5_rf_nano_area_cell = build/area/ecp5-$(1)/nano/nano.lut

TINY_CONFIGS := min sys full

NANO_CONFIGS := nano
nano_label = nano

tiny_bin = build/bin/riscc-$(1).bin
nano_bin = build/bin/nano.bin
nano_tb = build/tb/nano/tb
nano_matrix_tb = build/matrix/tb/nano/tb
nano_matrix_ok = build/matrix/ok/nano.ok
nano_area_cell = build/area/$(1)/nano/nano.lut
nano_test_target = test-nano
nano_area_target = area-nano
nano_fuzz_target = fuzz-nano

fast_tb = build/tb/fast$(if $(1),-$(1))/tb
fast_trace_tb = build/trace/fast$(if $(1),-$(1))/tb
fast_defs = $(strip \
  $(if $(findstring dsp,$(1)),-DRISCC_FAST_DSP) \
  $(if $(findstring ice,$(1)),-DRISCC_FAST_SYNC_RF))
fast_area_cell = build/area/$(1)/fast/$(2).cells
faster_tb = build/tb/faster/tb
ecp5_fmax_cell = build/fmax/ecp5/tiny$(1)-$(2).mhz
ecp5_nano_fmax_cell = build/fmax/ecp5/nano.mhz
ice40_fmax_cell = build/fmax/ice40/$(1)/tiny$(2)-$(3).mhz
ice40_nano_fmax_cell = build/fmax/ice40/$(1)/nano.mhz

tiny_cpp_defs = $(strip \
  $(if $(filter min,$(1)),-DRISCC_MIN) \
  $(if $(filter sys full,$(1)),-DRISCC_SYS) \
  $(if $(filter full,$(1)),-DRISCC_FULL))

tiny_sim_opts = $(strip \
  $(if $(filter min,$(1)),--min) \
  $(if $(filter full,$(1)),--full))

# Area-best mapper options differ by datapath and profile. Serial min uses
# two-pass ABC; selected /16, sys /1, and full /2 builds also benefit from
# flip-flop-aware mapping.
tiny_area_synth_opts = $(strip \
  $(if $(and $(filter 16,$(1)),$(filter min,$(2))),-dff, \
  $(if $(and $(filter 1,$(1)),$(filter sys,$(2))),-abc2 -dff, \
  $(if $(and $(filter 16,$(1)),$(filter sys,$(2))),-abc2, \
  $(if $(and $(filter 2 16,$(1)),$(filter full,$(2))),-abc2 -dff, \
  $(if $(and $(filter 1 2 4 8,$(1)),$(filter min,$(2))),-abc2))))))

# Two serial /2 profiles have different area-best ABC settings on ECP5.
tiny_ecp5_area_synth_opts = $(strip \
  $(if $(and $(filter 2,$(1)),$(filter min,$(2))),-abc2 -dff, \
  $(if $(and $(filter 2,$(1)),$(filter full,$(2))),-abc2, \
  $(call tiny_area_synth_opts,$(1),$(2)))))

TINY_BINS := $(foreach c,$(TINY_CONFIGS),$(call tiny_bin,$(c)))
NANO_BINS := $(foreach c,$(NANO_CONFIGS),$(call nano_bin,$(c)))
TINY_TEST_TARGETS := $(foreach w,$(TINY_WIDTHS),$(foreach c,$(TINY_CONFIGS),test-$(w)-$(c)))
TINY_FMAX_TARGETS := $(foreach w,$(TINY_WIDTHS),$(foreach c,$(TINY_CONFIGS),fmax-$(w)-$(c)))
NANO_TEST_TARGETS := $(foreach c,$(NANO_CONFIGS),$(call nano_test_target,$(c)))
TINY_SIM_TARGETS := $(foreach c,$(TINY_CONFIGS),sim-$(c))
TINY_TRACE_TARGETS := $(foreach w,$(TINY_WIDTHS),$(foreach c,$(TINY_CONFIGS),trace-$(w)-$(c)))
FUZZ_CONFIGS := $(TINY_CONFIGS)
TINY_FUZZ_TARGETS := $(foreach c,$(FUZZ_CONFIGS),fuzz-$(c))
NANO_FUZZ_TARGETS := $(foreach c,$(NANO_CONFIGS),$(call nano_fuzz_target,$(c)))
FUZZ_TARGETS := $(TINY_FUZZ_TARGETS) $(NANO_FUZZ_TARGETS) fuzz-fast fuzz-fast-ice
TINY_AREA_TARGETS := $(foreach w,$(TINY_WIDTHS),$(foreach c,$(TINY_CONFIGS),area-$(w)-$(c)))
NANO_AREA_TARGETS := $(foreach c,$(NANO_CONFIGS),$(call nano_area_target,$(c)))
ECP5_FMAX_CELLS := $(foreach w,$(TINY_WIDTHS),$(foreach c,$(TINY_CONFIGS),$(call ecp5_fmax_cell,$(w),$(c)))) \
                   $(ecp5_nano_fmax_cell)
ICE40_FMAX_CELLS := $(foreach d,up5k hx8k, \
                      $(foreach w,$(TINY_WIDTHS), \
                        $(foreach c,$(TINY_CONFIGS),$(call ice40_fmax_cell,$(d),$(w),$(c)))) \
                      $(call ice40_nano_fmax_cell,$(d)))
ECP5_MAINLINE_RF_SITES := 24
ECP5_NANO_RF_SITES := 12

# Public selection targets are test-<width>-<profile>, area-<width>-<profile>,
# and fmax-<width>-<profile> for Tiny,
# plus the fixed Nano, Fast, and Faster targets.  The aggregate area/Fmax
# targets below are the supported way to regenerate published matrices.
.PHONY: all test-all clean FORCE version check-version asm asm-tiny asm-nano sim sim-all sim-cpp fuzz fuzz-all bench \
        icepi-zero-demo-bin icepi-zero-demo-iss icepi-zero-demo-iss-test icepi-zero-demo-rtlsim \
        icepi-zero-demo-json icepi-zero-demo-bit icepi-zero-video-test-bit \
        atum-a3-demo-bin atum-a3-demo-iss atum-a3-demo-rtlsim atum-a3-demo \
        $(TINY_TRACE_TARGETS) $(foreach w,$(TINY_WIDTHS),trace-$(w)) trace-nano \
        $(FUZZ_TARGETS) \
        $(TINY_TEST_TARGETS) $(NANO_TEST_TARGETS) $(TINY_FMAX_TARGETS) fmax-nano $(TINY_SIM_TARGETS) \
        $(foreach w,$(TINY_WIDTHS),test-$(w) tb-$(w)) tb-nano \
        test-nano \
        test-tiny-matrix test-matrix test-matrix-parallel \
        $(TINY_AREA_TARGETS) $(NANO_AREA_TARGETS) \
        $(foreach w,$(TINY_WIDTHS),area-$(w)) area-nano \
        test-fast test-fast-dsp test-fast-ice test-fast-ice-dsp test-faster test-faster-soft \
        sim-fast sim-fast-dsp trace-fast trace-fast-dsp trace-fast-ice trace-fast-ice-dsp \
        fuzz-fast fuzz-fast-ice bench-nano bench-fast bench-fast-dsp bench-fast-ice bench-fast-ice-dsp bench-faster bench-faster-soft \
        area-fast area-agilex check-fast-dsp check-fast-ice \
        fmax-fast fmax-ice40 fmax-ecp5 fmax-agilex fmax-table fmax-all tables \
        area area-all area-table area-ecp5

all: test-all sim-all bench area-all

version:
	@printf '%s\n' '$(RISCC_VERSION)'

check-version:
	@test "$$(sed -n 's/^Version: `\([^`]*\)`\.$$/\1/p' doc/RISC-C.md)" = "$(RISCC_VERSION)"

test-all: test-matrix test-fast test-fast-dsp test-fast-ice test-fast-ice-dsp test-faster test-faster-soft

# ---- Assembler / ISS --------------------------------------------------

asm: asm-tiny
asm-tiny: $(TINY_BINS) $(call bench_bin)
asm-nano: $(NANO_BINS) $(nano_bench_bin)

sim-cpp: $(RISCC_SIM)

$(RISCC_SIM): tools/riscc_sim.cpp VERSION
	@mkdir -p $(@D)
	$(CCACHE) $(CXX) $(RISCC_SIM_CXXFLAGS) $(SDL2_CFLAGS) $(STB_CFLAGS) $< -o $@ $(SDL2_LIBS) $(STB_LIBS)

$(call tiny_bin,%): test/test_riscc.asm tools/riscc_asm.py
	@mkdir -p $(@D)
	$(PYTHON) tools/riscc_asm.py --profile $* $< -o $@

$(call nano_bin,nano): test/test_riscc.asm tools/riscc_asm.py
	@mkdir -p $(@D)
	$(PYTHON) tools/riscc_asm.py --profile nano $< -o $@

$(call bench_bin): test/test_riscc_bench.asm tools/riscc_asm.py
	@mkdir -p $(@D)
	$(PYTHON) tools/riscc_asm.py --profile full $< -o $@

$(nano_bench_bin): test/test_riscc_bench.asm tools/riscc_asm.py
	@mkdir -p $(@D)
	$(PYTHON) tools/riscc_asm.py --profile nano $< -o $@

define TINY_SIM_TARGET_RULE
sim-$(1): $(call tiny_bin,$(1)) $$(RISCC_SIM)
	$$(RISCC_SIM) $$(call tiny_bin,$(1)) $(call tiny_sim_opts,$(1))
endef

$(foreach c,$(TINY_CONFIGS),$(eval $(call TINY_SIM_TARGET_RULE,$(c))))

sim: sim-all
sim-all: $(TINY_SIM_TARGETS) $(call bench_bin) $(RISCC_SIM)
	$(RISCC_SIM) $(call bench_bin) --full

sim-fast: $(call tiny_bin,full) $(RISCC_SIM)
	$(RISCC_SIM) $< --fast

sim-fast-dsp: $(call tiny_bin,full) $(RISCC_SIM)
	$(RISCC_SIM) $< --fast-dsp

FUZZ_SEEDS ?= 100
FUZZ_BASE_SEED ?=
FUZZ_CORES ?= $(foreach w,$(TINY_WIDTHS),tiny$(w))
FUZZ_CORE_ARG = $(call comma_join,$(FUZZ_CORES))
FUZZ_SEED_ARGS = $(if $(strip $(FUZZ_BASE_SEED)),--base-seed $(FUZZ_BASE_SEED),--random-seed)

fuzz: fuzz-all
fuzz-all: $(FUZZ_TARGETS)

define FUZZ_TARGET_RULE
fuzz-$(1): $$(RISCC_SIM)
	RISCC_SIM=$$(abspath $$(RISCC_SIM)) $$(PYTHON) tools/riscc_fuzz.py \
	  --campaign $$(FUZZ_SEEDS) $$(FUZZ_SEED_ARGS) --config $(1) \
	  --cores $$(FUZZ_CORE_ARG)
endef

$(foreach c,$(FUZZ_CONFIGS),$(eval $(call FUZZ_TARGET_RULE,$(c))))

define NANO_FUZZ_TARGET_RULE
$(call nano_fuzz_target,$(1)): $$(RISCC_SIM)
	RISCC_SIM=$$(abspath $$(RISCC_SIM)) $$(PYTHON) tools/riscc_fuzz.py \
	  --family nano --campaign $$(FUZZ_SEEDS) \
	  $$(FUZZ_SEED_ARGS) --config $(1)
endef

$(foreach c,$(NANO_CONFIGS),$(eval $(call NANO_FUZZ_TARGET_RULE,$(c))))

fuzz-fast: $(RISCC_SIM)
	RISCC_SIM=$(abspath $(RISCC_SIM)) $(PYTHON) tools/riscc_fuzz.py \
	  --family fast --campaign $(FUZZ_SEEDS) $(FUZZ_SEED_ARGS) --config full

fuzz-fast-ice: $(RISCC_SIM)
	RISCC_SIM=$(abspath $(RISCC_SIM)) $(PYTHON) tools/riscc_fuzz.py \
	  --family fast --campaign $(FUZZ_SEEDS) $(FUZZ_SEED_ARGS) --config full \
	  --cores fast-ice,fast-ice-dsp

# ---- Architectural trace debug builds --------------------------------

TRACE_CXXFLAGS = $(TB_CXXFLAGS) -DRISCC_TB_TRACE

.PRECIOUS: $(foreach w,$(TINY_WIDTHS),build/trace/tiny$(w)-%/tb) build/trace/nano/tb

define TINY_TRACE_TB_RULE
$(call tiny_trace_tb,$(1),$(2)): $(TB_SRC) $(call tiny_rtl,$(1)) $(TRACE_RTL) $(RISCC_RF_RTL)
	@mkdir -p $$(@D)
	$$(VERILATOR) -cc --exe --build $$(VERILATOR_MAKEFLAGS_ARG) --top-module $(call tiny_top,$(1)) \
	  $(call tiny_width_arg,$(1)) \
	  --prefix Vriscc -Mdir $$(@D) -I$$(abspath rtl) -I$$(abspath rtl/test) -DRISCC_TRACE $(call tiny_cpp_defs,$(2)) \
	  -CFLAGS "$$(TRACE_CXXFLAGS)" -o tb \
	  $$(abspath $(call tiny_rtl,$(1))) $$(abspath $(TB_SRC))
endef

define TINY_TRACE_TARGET_RULE
trace-$(1)-$(2): $(call tiny_trace_tb,$(1),$(2)) $(call tiny_bin,$(2))
	$$< $(call tiny_bin,$(2)) --trace --max-cycles 10000000
endef

$(foreach w,$(TINY_WIDTHS),$(foreach c,$(TINY_CONFIGS),$(eval $(call TINY_TRACE_TB_RULE,$(w),$(c)))))
$(foreach w,$(TINY_WIDTHS),$(foreach c,$(TINY_CONFIGS),$(eval $(call TINY_TRACE_TARGET_RULE,$(w),$(c)))))
$(foreach w,$(TINY_WIDTHS),$(eval trace-$(w): trace-$(w)-sys))

build/trace/nano/tb: $(TB_SRC) rtl/riscc_nano1.v $(TRACE_RTL) $(RISCC_RF_RTL)
	@mkdir -p $(@D)
	$(VERILATOR) -cc --exe --build $(VERILATOR_MAKEFLAGS_ARG) --top-module riscc_nano1 \
	  --prefix Vriscc -Mdir $(@D) -I$(abspath rtl) -I$(abspath rtl/test) -DRISCC_TRACE \
	  -CFLAGS "$(TRACE_CXXFLAGS)" -o tb \
	  $(abspath rtl/riscc_nano1.v) $(abspath $(TB_SRC))

trace-nano: build/trace/nano/tb $(call nano_bin,nano)
	$< $(call nano_bin,nano) --trace --max-cycles 200000

define FAST_TRACE_TB_RULE
$(call fast_trace_tb,$(1)): $(TB_SRC) rtl/riscc_fast.v $(TRACE_RTL)
	@mkdir -p $$(@D)
	$$(VERILATOR) -cc --exe --build $$(VERILATOR_MAKEFLAGS_ARG) --top-module riscc_fast \
	  --prefix Vriscc -Mdir $$(@D) -I$$(abspath rtl) -I$$(abspath rtl/test) -DRISCC_TRACE $(call fast_defs,$(1)) \
	  -CFLAGS "$$(TRACE_CXXFLAGS) -DRISCC_TB_TRACE_DRAIN=1" -o tb \
	  $$(abspath rtl/riscc_fast.v) $$(abspath $(TB_SRC))
endef

$(eval $(call FAST_TRACE_TB_RULE,))
$(eval $(call FAST_TRACE_TB_RULE,dsp))
$(eval $(call FAST_TRACE_TB_RULE,ice))
$(eval $(call FAST_TRACE_TB_RULE,ice-dsp))

trace-fast: $(call fast_trace_tb,) $(call tiny_bin,full)
	$< $(call tiny_bin,full) --trace --max-cycles 1000000

trace-fast-dsp: $(call fast_trace_tb,dsp) $(call tiny_bin,full)
	$< $(call tiny_bin,full) --trace --max-cycles 1000000

trace-fast-ice: $(call fast_trace_tb,ice) $(call tiny_bin,full)
	$< $(call tiny_bin,full) --trace --max-cycles 1000000

trace-fast-ice-dsp: $(call fast_trace_tb,ice-dsp) $(call tiny_bin,full)
	$< $(call tiny_bin,full) --trace --max-cycles 1000000

# ---- Verilator tests --------------------------------------------------

define TINY_TB_RULE
$(call tiny_tb,$(1),$(2)): $(TB_SRC) $(call tiny_rtl,$(1)) $(RISCC_RF_RTL)
	@mkdir -p $$(@D)
	$$(VERILATOR) -cc --exe --build $$(VERILATOR_MAKEFLAGS_ARG) --top-module $(call tiny_top,$(1)) \
	  $(call tiny_width_arg,$(1)) \
	  --prefix Vriscc -Mdir $$(@D) $(call tiny_cpp_defs,$(2)) \
	  -CFLAGS "$$(TB_CXXFLAGS)" -o tb \
	  $$(abspath $(call tiny_rtl,$(1))) $$(abspath $(TB_SRC))
endef

define TINY_TEST_RULE
test-$(1)-$(2): $(call tiny_tb,$(1),$(2)) $(call tiny_bin,$(2))
	$$< $(call tiny_bin,$(2)) --max-cycles 10000000
endef

$(foreach w,$(TINY_WIDTHS),$(foreach c,$(TINY_CONFIGS),$(eval $(call TINY_TB_RULE,$(w),$(c)))))
$(foreach w,$(TINY_WIDTHS),$(foreach c,$(TINY_CONFIGS),$(eval $(call TINY_TEST_RULE,$(w),$(c)))))

$(foreach w,$(TINY_WIDTHS),$(eval test-$(w): test-$(w)-sys))
$(foreach w,$(TINY_WIDTHS),$(eval tb-$(w): $(call tiny_tb,$(w),sys)))

define NANO_TB_RULE
$(call nano_tb,$(1)): $(TB_SRC) rtl/riscc_nano1.v $(RISCC_RF_RTL)
	@mkdir -p $$(@D)
	$$(VERILATOR) -cc --exe --build $$(VERILATOR_MAKEFLAGS_ARG) --top-module riscc_nano1 \
	  --prefix Vriscc -Mdir $$(@D) \
	  -CFLAGS "$$(TB_CXXFLAGS)" -o tb \
	  $$(abspath rtl/riscc_nano1.v) $$(abspath $(TB_SRC))
endef

define NANO_TEST_RULE
$(call nano_test_target,$(1)): $(call nano_tb,$(1)) $(call nano_bin,$(1))
	$$< $(call nano_bin,$(1)) --max-cycles 200000
endef

$(foreach c,$(NANO_CONFIGS),$(eval $(call NANO_TB_RULE,$(c))))
$(foreach c,$(NANO_CONFIGS),$(eval $(call NANO_TEST_RULE,$(c))))

tb-nano: $(call nano_tb,nano)

define FAST_TB_RULE
$(call fast_tb,$(1)): $(TB_SRC) rtl/riscc_fast.v
	@mkdir -p $$(@D)
	$$(VERILATOR) -cc --exe --build $$(VERILATOR_MAKEFLAGS_ARG) --top-module riscc_fast \
	  --prefix Vriscc -Mdir $$(@D) -I$$(abspath rtl) $(call fast_defs,$(1)) \
	  -CFLAGS "$$(TB_CXXFLAGS)" -o tb \
	  $$(abspath rtl/riscc_fast.v) $$(abspath $(TB_SRC))
endef

$(eval $(call FAST_TB_RULE,))
$(eval $(call FAST_TB_RULE,dsp))
$(eval $(call FAST_TB_RULE,ice))
$(eval $(call FAST_TB_RULE,ice-dsp))

test-fast: $(call fast_tb,) $(call tiny_bin,full)
	$< $(call tiny_bin,full) --max-cycles 1000000

test-fast-dsp: $(call fast_tb,dsp) $(call tiny_bin,full)
	$< $(call tiny_bin,full) --max-cycles 1000000

test-fast-ice: $(call fast_tb,ice) $(call tiny_bin,full)
	$< $(call tiny_bin,full) --max-cycles 1000000

test-fast-ice-dsp: $(call fast_tb,ice-dsp) $(call tiny_bin,full)
	$< $(call tiny_bin,full) --max-cycles 1000000

$(faster_tb): $(TB_SRC) rtl/riscc_faster.v
	@mkdir -p $(@D)
	$(VERILATOR) -cc --exe --build $(VERILATOR_MAKEFLAGS_ARG) --top-module riscc_faster \
	  --prefix Vriscc -Mdir $(@D) \
	  -CFLAGS "$(TB_CXXFLAGS)" -o tb \
	  $(abspath rtl/riscc_faster.v) $(abspath $(TB_SRC))

test-faster: $(faster_tb) $(call tiny_bin,full)
	$< $(call tiny_bin,full) --max-cycles 1000000

build/tb/faster-soft/tb: $(TB_SRC) rtl/riscc_faster.v
	@mkdir -p $(@D)
	$(VERILATOR) -cc --exe --build $(VERILATOR_MAKEFLAGS_ARG) --top-module riscc_faster \
	  --prefix Vriscc -Mdir $(@D) -DRISCC_FASTER_SOFT_MUL \
	  -CFLAGS "$(TB_CXXFLAGS)" -o tb \
	  $(abspath rtl/riscc_faster.v) $(abspath $(TB_SRC))

test-faster-soft: build/tb/faster-soft/tb $(call tiny_bin,full)
	$< $(call tiny_bin,full) --max-cycles 1000000

BENCH_CORES ?= $(foreach w,$(TINY_WIDTHS),tiny$(w))
BENCH_TARGETS := $(foreach c,$(BENCH_CORES),bench-$(c))

.PHONY: $(BENCH_TARGETS)

bench: $(BENCH_TARGETS) bench-nano bench-fast bench-fast-dsp bench-fast-ice bench-fast-ice-dsp bench-faster bench-faster-soft

define BENCH_TB_RULE
build/tb/bench-tiny$(1)/tb: $(TB_SRC) $(call tiny_rtl,$(1)) $(RISCC_RF_RTL)
	@mkdir -p $$(@D)
	@$$(VERILATOR) -cc --exe --build $$(VERILATOR_MAKEFLAGS_ARG) \
	  --top-module $(call tiny_top,$(1)) $(call tiny_width_arg,$(1)) \
	  --prefix Vriscc -Mdir $$(@D) -DRISCC_SYS -DRISCC_FULL \
	  -CFLAGS "$$(TB_CXXFLAGS)" -o tb \
	  $$(abspath $(call tiny_rtl,$(1))) $$(abspath $(TB_SRC)) \
	  >/dev/null 2>&1
endef

$(foreach w,$(TINY_WIDTHS),$(eval $(call BENCH_TB_RULE,$(w))))

define BENCH_TARGET_RULE
bench-$(1): build/tb/bench-$(1)/tb $$(call bench_bin)
	@out="$$$$($$< $$(call bench_bin) --max-cycles 800000 2>&1 | tail -1)"; \
	printf '%-8s %s\n' $(1) "$$$$out"
endef

$(foreach c,$(BENCH_CORES),$(eval $(call BENCH_TARGET_RULE,$(c))))

bench-nano: $(call nano_tb,nano) $(nano_bench_bin)
	@out="$$($< $(nano_bench_bin) --max-cycles 2000000 2>&1 | tail -1)"; \
	printf '%-8s %s\n' nano "$$out"

build/tb/bench-fast/tb: $(TB_SRC) rtl/riscc_fast.v
	@mkdir -p $(@D)
	@$(VERILATOR) -cc --exe --build $(VERILATOR_MAKEFLAGS_ARG) \
	  --top-module riscc_fast --prefix Vriscc -Mdir $(@D) \
	  -CFLAGS "$(TB_CXXFLAGS)" -o tb \
	  $(abspath rtl/riscc_fast.v) $(abspath $(TB_SRC)) >/dev/null 2>&1

bench-fast: build/tb/bench-fast/tb $(call bench_bin)
	@out="$$($< $(call bench_bin) --max-cycles 800000 2>&1 | tail -1)"; \
	printf '%-8s %s\n' fast "$$out"

build/tb/bench-fast-dsp/tb: $(TB_SRC) rtl/riscc_fast.v
	@mkdir -p $(@D)
	@$(VERILATOR) -cc --exe --build $(VERILATOR_MAKEFLAGS_ARG) \
	  --top-module riscc_fast --prefix Vriscc -Mdir $(@D) -DRISCC_FAST_DSP \
	  -CFLAGS "$(TB_CXXFLAGS)" -o tb \
	  $(abspath rtl/riscc_fast.v) $(abspath $(TB_SRC)) >/dev/null 2>&1

bench-fast-dsp: build/tb/bench-fast-dsp/tb $(call bench_bin)
	@out="$$($< $(call bench_bin) --max-cycles 800000 2>&1 | tail -1)"; \
	printf '%-8s %s\n' fast-dsp "$$out"

bench-fast-ice: $(call fast_tb,ice) $(call bench_bin)
	@out="$$($< $(call bench_bin) --max-cycles 800000 2>&1 | tail -1)"; \
	printf '%-8s %s\n' fast-ice "$$out"

bench-fast-ice-dsp: $(call fast_tb,ice-dsp) $(call bench_bin)
	@out="$$($< $(call bench_bin) --max-cycles 800000 2>&1 | tail -1)"; \
	printf '%-8s %s\n' fast-ice-dsp "$$out"

build/tb/bench-faster/tb: $(TB_SRC) rtl/riscc_faster.v
	@mkdir -p $(@D)
	@$(VERILATOR) -cc --exe --build $(VERILATOR_MAKEFLAGS_ARG) \
	  --top-module riscc_faster --prefix Vriscc -Mdir $(@D) \
	  -CFLAGS "$(TB_CXXFLAGS)" -o tb \
	  $(abspath rtl/riscc_faster.v) $(abspath $(TB_SRC)) >/dev/null 2>&1

bench-faster: build/tb/bench-faster/tb $(call bench_bin)
	@out="$$($< $(call bench_bin) --max-cycles 800000 2>&1 | tail -1)"; \
	printf '%-8s %s\n' faster "$$out"

build/tb/bench-faster-soft/tb: $(TB_SRC) rtl/riscc_faster.v
	@mkdir -p $(@D)
	@$(VERILATOR) -cc --exe --build $(VERILATOR_MAKEFLAGS_ARG) \
	  --top-module riscc_faster --prefix Vriscc -Mdir $(@D) \
	  -DRISCC_FASTER_SOFT_MUL \
	  -CFLAGS "$(TB_CXXFLAGS)" -o tb \
	  $(abspath rtl/riscc_faster.v) $(abspath $(TB_SRC)) >/dev/null 2>&1

bench-faster-soft: build/tb/bench-faster-soft/tb $(call bench_bin)
	@out="$$($< $(call bench_bin) --max-cycles 800000 2>&1 | tail -1)"; \
	printf '%-12s %s\n' faster-soft "$$out"

# ---- Full test matrix -------------------------------------------------

MATRIX_WIDTHS ?= $(TINY_WIDTHS)
MATRIX_TINY_OK := $(foreach w,$(MATRIX_WIDTHS),$(foreach c,$(TINY_CONFIGS),build/matrix/ok/tiny$(w)-$(c).ok))
MATRIX_NANO_OK := $(foreach c,$(NANO_CONFIGS),$(call nano_matrix_ok,$(c)))

define MATRIX_TINY_TB_RULE
$(call tiny_matrix_tb,$(1),$(2)): $(TB_SRC) $(call tiny_rtl,$(1)) $(RISCC_RF_RTL)
	@mkdir -p $$(@D)
	@log=$$@.build.log; \
	if $$(VERILATOR) -cc --exe --build $$(VERILATOR_MAKEFLAGS_ARG) --top-module $(call tiny_top,$(1)) \
	    $(call tiny_width_arg,$(1)) \
	    --prefix Vriscc -Mdir $$(@D) $(call tiny_cpp_defs,$(2)) \
	    -CFLAGS "$$(TB_CXXFLAGS)" -o tb \
	    $$(abspath $(call tiny_rtl,$(1))) $$(abspath $(TB_SRC)) > $$$$log 2>&1; then \
	  :; \
	else \
	  cat $$$$log; exit 1; \
	fi
endef

define MATRIX_TINY_OK_RULE
build/matrix/ok/tiny$(1)-$(2).ok: $(call tiny_matrix_tb,$(1),$(2)) $(call tiny_bin,$(2)) FORCE
	@mkdir -p $$(@D)
	@log=$$@.log; \
	if $$< $(call tiny_bin,$(2)) --max-cycles 10000000 > $$$$log 2>&1; then \
	  printf 'PASS tiny%-4s %s\n' $(1) $(2); touch $$@; \
	else \
	  cat $$$$log; exit 1; \
	fi
endef

define MATRIX_NANO_TB_RULE
$(call nano_matrix_tb,$(1)): $(TB_SRC) rtl/riscc_nano1.v $(RISCC_RF_RTL)
	@mkdir -p $$(@D)
	@log=$$@.build.log; \
	if $$(VERILATOR) -cc --exe --build $$(VERILATOR_MAKEFLAGS_ARG) --top-module riscc_nano1 \
	    --prefix Vriscc -Mdir $$(@D) \
	    -CFLAGS "$$(TB_CXXFLAGS)" -o tb \
	    $$(abspath rtl/riscc_nano1.v) $$(abspath $(TB_SRC)) > $$$$log 2>&1; then \
	  :; \
	else \
	  cat $$$$log; exit 1; \
	fi
endef

define MATRIX_NANO_OK_RULE
$(call nano_matrix_ok,$(1)): $(call nano_matrix_tb,$(1)) $(call nano_bin,$(1)) FORCE
	@mkdir -p $$(@D)
	@log=$$@.log; \
	if $$< $(call nano_bin,$(1)) --max-cycles 10000000 > $$$$log 2>&1; then \
	  printf 'PASS nano1   %s\n' $(call nano_label,$(1)); touch $$@; \
	else \
	  cat $$$$log; exit 1; \
	fi
endef

$(foreach w,$(MATRIX_WIDTHS),$(foreach c,$(TINY_CONFIGS),$(eval $(call MATRIX_TINY_TB_RULE,$(w),$(c)))))
$(foreach w,$(MATRIX_WIDTHS),$(foreach c,$(TINY_CONFIGS),$(eval $(call MATRIX_TINY_OK_RULE,$(w),$(c)))))
$(foreach c,$(NANO_CONFIGS),$(eval $(call MATRIX_NANO_TB_RULE,$(c))))
$(foreach c,$(NANO_CONFIGS),$(eval $(call MATRIX_NANO_OK_RULE,$(c))))

test-tiny-matrix: $(MATRIX_TINY_OK)
test-matrix: test-tiny-matrix $(MATRIX_NANO_OK)
test-matrix-parallel:
	$(MAKE) test-matrix

# ---- Icepi Zero SoC demo ---------------------------------------------

ICEPI_DIR := boards/icepi_zero
ICEPI_BUILD := build/icepi_zero
ICEPI_BIN := $(ICEPI_BUILD)/demo.bin
ICEPI_ASM ?= $(ICEPI_DIR)/sw/demo.asm
ICEPI_MEMH := $(ICEPI_BUILD)/demo.memh
ICEPI_JSON := $(ICEPI_BUILD)/demo.json
ICEPI_CONFIG := $(ICEPI_BUILD)/demo.config
ICEPI_BIT := $(ICEPI_BUILD)/demo.bit
ICEPI_VIDEO_TEST_JSON := $(ICEPI_BUILD)/video_test.json
ICEPI_VIDEO_TEST_CONFIG := $(ICEPI_BUILD)/video_test.config
ICEPI_VIDEO_TEST_BIT := $(ICEPI_BUILD)/video_test.bit
ICEPI_RTLSIM := $(ICEPI_BUILD)/rtlsim/Vicepi_zero_soc_sim
ICEPI_CPU_DEFS := -DRISCC_FAST_DSP
ICEPI_SPEED ?= 6
ICEPI_NEXTPNR_OPTS ?= --seed 31 --tmg-ripup
ICEPI_DVI_RTL := \
  $(ICEPI_DIR)/rtl/icepi_fb_dvi.v \
  $(ICEPI_DIR)/rtl/icepi_tmds_ddr.v \
  $(ICEPI_DIR)/vendor/dvi/tmds_encoder.v \
  $(ICEPI_DIR)/vendor/dvi/pll.v
ICEPI_SOC_RTL := \
  $(ICEPI_DIR)/rtl/fb_ram.v \
  $(ICEPI_DIR)/rtl/uart_mmio.v \
  $(ICEPI_DIR)/rtl/icepi_zero_soc.v
ICEPI_SYNTH_RTL := \
  $(ICEPI_DIR)/rtl/top.v \
  $(ICEPI_SOC_RTL) \
  $(ICEPI_DVI_RTL) \
  rtl/riscc_fast.v
ICEPI_SIM_RTL := \
  $(ICEPI_DIR)/rtl/icepi_zero_soc_sim.v \
  $(ICEPI_SOC_RTL) \
  $(ICEPI_DIR)/rtl/icepi_fb_dvi.v \
  $(ICEPI_DIR)/rtl/icepi_tmds_ddr.v \
  $(ICEPI_DIR)/vendor/dvi/tmds_encoder.v \
  rtl/riscc_fast.v

$(ICEPI_BIN): $(ICEPI_ASM) tools/riscc_asm.py
	@mkdir -p $(@D)
	$(PYTHON) tools/riscc_asm.py $< -o $@

$(ICEPI_MEMH): $(ICEPI_BIN) tools/bin_to_memh.py
	$(PYTHON) tools/bin_to_memh.py $< -o $@

icepi-zero-demo-bin: FORCE
	$(MAKE) -B $(ICEPI_BIN) $(ICEPI_MEMH)

icepi-zero-demo-iss: $(ICEPI_BIN) $(RISCC_SIM)
	$(RISCC_SIM) $< --uart --full --fb-window --mhz 50 --max-insns 0

icepi-zero-demo-iss-test: $(ICEPI_BIN) $(RISCC_SIM)
	@mkdir -p build/icepi_zero
	@printf '12+' | $(RISCC_SIM) $< --uart --full --max-insns 3000000 \
	  > build/icepi_zero/demo_uart.txt 2> build/icepi_zero/demo_iss.log || true
	@grep -q 'RISC-C on icepi-zero' build/icepi_zero/demo_uart.txt || { cat build/icepi_zero/demo_iss.log; exit 1; }
	@echo "ISS UART expect PASS"

$(ICEPI_RTLSIM): $(ICEPI_MEMH) $(ICEPI_SIM_RTL) $(ICEPI_DIR)/sim/icepi_zero_soc_tb.cpp Makefile
	@mkdir -p $(@D)
	$(VERILATOR) -cc --exe --build $(VERILATOR_MAKEFLAGS_ARG) \
	  --top-module icepi_zero_soc_sim --prefix Vicepi_zero_soc_sim \
	  -Mdir $(@D) $(ICEPI_CPU_DEFS) -I$(abspath rtl) -I$(abspath $(ICEPI_DIR)/vendor/dvi) \
	  -CFLAGS "$(TB_CXXFLAGS)" -o Vicepi_zero_soc_sim \
	  $(abspath $(ICEPI_SIM_RTL)) $(abspath $(ICEPI_DIR)/sim/icepi_zero_soc_tb.cpp)

icepi-zero-demo-rtlsim: $(ICEPI_RTLSIM)
	$(ICEPI_RTLSIM)

$(ICEPI_JSON): $(ICEPI_MEMH) $(ICEPI_SYNTH_RTL) $(RISCC_RF_RTL) Makefile
	@mkdir -p $(@D)
	@$(YOSYS) -p 'read_verilog -DRISCC_ECP5 $(ICEPI_CPU_DEFS) $(ICEPI_SYNTH_RTL); synth_ecp5 -top top -json $@' \
	  >$(ICEPI_BUILD)/demo-yosys.log 2>&1 || { tail -80 $(ICEPI_BUILD)/demo-yosys.log; exit 1; }
	@awk '/Number of cells:/{cells=$$4} $$1=="LUT4"{lut=$$2} $$1=="DP16KD"{ebr=$$2} $$1=="MULT18X18D"{dsp=$$2} END{printf "Icepi synth: %d cells, %d LUT4, %d EBR, %d DSP\n",cells,lut,ebr,dsp}' \
	  $(ICEPI_BUILD)/demo-yosys.log

$(ICEPI_CONFIG): $(ICEPI_JSON) $(ICEPI_DIR)/icepi-zero.lpf
	@$(NEXTPNR_ECP5) --25k --package CABGA256 --speed $(ICEPI_SPEED) $(ICEPI_NEXTPNR_OPTS) --lpf $(ICEPI_DIR)/icepi-zero.lpf \
	  --json $< --textcfg $@ >$(ICEPI_BUILD)/demo-nextpnr.log 2>&1 || \
	  { tail -80 $(ICEPI_BUILD)/demo-nextpnr.log; exit 1; }
	@awk '/Max frequency for clock/{first=second; second=latest; latest=$$0} END{if(first) print first; if(second) print second; print latest}' \
	  $(ICEPI_BUILD)/demo-nextpnr.log

$(ICEPI_BIT): $(ICEPI_CONFIG)
	@$(ECPPACK) --compress $< $@
	@printf 'Icepi bitstream: %s\n' '$@'

icepi-zero-demo-json: $(ICEPI_JSON)
icepi-zero-demo-bit: $(ICEPI_BIT)

$(ICEPI_VIDEO_TEST_JSON): $(ICEPI_MEMH) $(ICEPI_SYNTH_RTL) $(RISCC_RF_RTL) Makefile
	@mkdir -p $(@D)
	@$(YOSYS) -p 'read_verilog -DRISCC_ECP5 $(ICEPI_CPU_DEFS) -DICEPI_VIDEO_TEST $(ICEPI_SYNTH_RTL); synth_ecp5 -top top -json $@' \
	  >$(ICEPI_BUILD)/video-test-yosys.log 2>&1 || { tail -80 $(ICEPI_BUILD)/video-test-yosys.log; exit 1; }
	@echo 'Icepi video-test synthesis PASS'

$(ICEPI_VIDEO_TEST_CONFIG): $(ICEPI_VIDEO_TEST_JSON) $(ICEPI_DIR)/icepi-zero.lpf
	@$(NEXTPNR_ECP5) --25k --package CABGA256 --speed $(ICEPI_SPEED) --lpf $(ICEPI_DIR)/icepi-zero.lpf \
	  --json $< --textcfg $@ >$(ICEPI_BUILD)/video-test-nextpnr.log 2>&1 || \
	  { tail -80 $(ICEPI_BUILD)/video-test-nextpnr.log; exit 1; }
	@awk '/Max frequency for clock/{first=second; second=latest; latest=$$0} END{if(first) print first; if(second) print second; print latest}' \
	  $(ICEPI_BUILD)/video-test-nextpnr.log

$(ICEPI_VIDEO_TEST_BIT): $(ICEPI_VIDEO_TEST_CONFIG)
	@$(ECPPACK) --compress $< $@
	@printf 'Icepi video-test bitstream: %s\n' '$@'

icepi-zero-video-test-bit: $(ICEPI_VIDEO_TEST_BIT)

# ---- Terasic Atum A3 Nano SoC demo ----------------------------------

ATUM_DIR := boards/atum_a3_nano
ATUM_BUILD := build/atum_a3_nano
ATUM_BIN := $(ATUM_BUILD)/demo.bin
ATUM_ASM ?= $(ICEPI_DIR)/sw/demo.asm
ATUM_MEMH := $(ATUM_BUILD)/mem/demo.memh
ATUM_RTLSIM := $(ATUM_BUILD)/rtlsim/Vatum_a3_nano_soc_sim
ATUM_QUARTUS_BUILD := $(ATUM_BUILD)/quartus
ATUM_QUARTUS_QPF := $(ATUM_QUARTUS_BUILD)/atum_a3_nano.qpf
ATUM_QUARTUS_QSF := $(ATUM_QUARTUS_BUILD)/atum_a3_nano.qsf
ATUM_QUARTUS_MEM := $(ATUM_QUARTUS_BUILD)/mem
ATUM_SOF := $(ATUM_QUARTUS_BUILD)/output_files/atum_a3_nano.sof
ATUM_SOC_RTL := \
  $(ATUM_DIR)/rtl/atum_a3_nano_soc.v \
  $(ATUM_DIR)/rtl/atum_uart_mmio.v
ATUM_SIM_RTL := \
  $(ATUM_DIR)/rtl/atum_a3_nano_soc_sim.v \
  $(ATUM_SOC_RTL) \
  rtl/riscc_faster.v
ATUM_HW_RTL := \
  $(ATUM_DIR)/rtl/top.v \
  $(ATUM_DIR)/rtl/atum_sys_pll.v \
  $(ATUM_DIR)/rtl/atum_reset_release.v \
  $(ATUM_SOC_RTL) \
  $(ATUM_DIR)/rtl/atum_fb_hdmi.v \
  $(ATUM_DIR)/rtl/atum_tfp410_init.v \
  rtl/riscc_faster.v
ATUM_PROJECT_FILES := \
  $(ATUM_DIR)/atum_a3_nano.qpf \
  $(ATUM_DIR)/atum_a3_nano.qsf \
  $(ATUM_DIR)/atum_a3_nano.sdc \
  $(ATUM_HW_RTL)

$(ATUM_BIN): $(ATUM_ASM) tools/riscc_asm.py
	@mkdir -p $(@D)
	$(PYTHON) tools/riscc_asm.py -D RISCC_ATUM_A3 $< -o $@

$(ATUM_MEMH): $(ATUM_BIN) tools/bin_to_memh.py
	@mkdir -p $(@D)
	$(PYTHON) tools/bin_to_memh.py $< -o $@ --depth 16384

atum-a3-demo-bin: FORCE
	$(MAKE) -B $(ATUM_BIN) $(ATUM_MEMH)

atum-a3-demo-iss: $(ATUM_BIN) $(RISCC_SIM)
	$(RISCC_SIM) $< --uart --full --fb-window --fb-scale 4 --mhz 225 --max-insns 0

$(ATUM_RTLSIM): $(ATUM_MEMH) $(ATUM_SIM_RTL) $(ATUM_DIR)/sim/atum_a3_nano_soc_tb.cpp Makefile
	@mkdir -p $(@D)
	$(VERILATOR) -cc --exe --build $(VERILATOR_MAKEFLAGS_ARG) \
	  --top-module atum_a3_nano_soc_sim --prefix Vatum_a3_nano_soc_sim \
	  -Mdir $(@D) -I$(abspath rtl) \
	  -CFLAGS "$(TB_CXXFLAGS)" -o Vatum_a3_nano_soc_sim \
	  $(abspath $(ATUM_SIM_RTL)) $(abspath $(ATUM_DIR)/sim/atum_a3_nano_soc_tb.cpp)

atum-a3-demo-rtlsim: $(ATUM_RTLSIM)
	$(ATUM_RTLSIM)

$(ATUM_QUARTUS_QPF): $(ATUM_DIR)/atum_a3_nano.qpf
	@mkdir -p $(@D)
	cp $< $@

$(ATUM_QUARTUS_QSF): $(ATUM_DIR)/atum_a3_nano.qsf
	@mkdir -p $(@D)
	cp $< $@

$(ATUM_QUARTUS_MEM): $(ATUM_MEMH) | $(ATUM_QUARTUS_QSF)
	ln -sfn ../mem $@

$(ATUM_SOF): $(ATUM_MEMH) $(ATUM_PROJECT_FILES) $(ATUM_QUARTUS_QPF) $(ATUM_QUARTUS_QSF) $(ATUM_QUARTUS_MEM) $(RISCC_RF_RTL) Makefile
	# Quartus Pro 26.1's incremental flow may stop after synthesis when only a
	# source dependency changed.  Explicit stage bounds ensure this target never
	# reports an older .sof as current.
	@cd $(ATUM_QUARTUS_BUILD) && RISCC_BUILD_JOBS=$(RISCC_BUILD_JOBS) $(QUARTUS_SH) $(QUARTUS_FLOW_ARGS) --flow compile \
	  atum_a3_nano -start dni_ipgenerate -end dni_analysis_and_synthesis
	@cd $(ATUM_QUARTUS_BUILD) && RISCC_BUILD_JOBS=$(RISCC_BUILD_JOBS) $(QUARTUS_SH) $(QUARTUS_FLOW_ARGS) --flow compile \
	  atum_a3_nano -start fitter_plan -end sta_signoff
	@cd $(ATUM_QUARTUS_BUILD) && RISCC_BUILD_JOBS=$(RISCC_BUILD_JOBS) $(QUARTUS_SH) $(QUARTUS_FLOW_ARGS) --flow compile \
	  atum_a3_nano -start assembler
	@test -f $@
	@printf 'Atum A3 Nano SOF: %s\n' '$@'

atum-a3-demo: $(ATUM_SOF)

# ---- Area -------------------------------------------------------------

# Published Quartus Pro core characterization for Agilex 3.  These values are
# included in the per-core reports and aggregate table; the open-FPGA area
# recipes above remain reproducible locally.
AGILEX_AREA_MIN := 99.3 111.9 118.0 132.4 125.1
AGILEX_AREA_SYS := 116.8 121.5 133.9 151.9 151.4
AGILEX_AREA_FULL := 131.9 144.6 151.4 170.4 218.6
AGILEX_AREA_min := $(AGILEX_AREA_MIN)
AGILEX_AREA_sys := $(AGILEX_AREA_SYS)
AGILEX_AREA_full := $(AGILEX_AREA_FULL)
AGILEX_AREA_NANO := 90.2
AGILEX_AREA_FAST_SOFT := 277.2
AGILEX_AREA_FAST_DSP := 235.3
AGILEX_AREA_FASTER_DSP := 310.4
AGILEX_AREA_FASTER_SOFT := 328.7
AGILEX_FMAX_SYS := 277.16 266.81 242.95 222.87 211.51
AGILEX_FMAX_NANO := 306.37
AGILEX_FMAX_FAST_SOFT := 192.57
AGILEX_FMAX_FAST_DSP := 153.63
AGILEX_FMAX_FASTER_DSP := 251.76
AGILEX_FMAX_FASTER_SOFT := 250.31

agilex_area_index = $(if $(filter 1,$(1)),1,$(if $(filter 2,$(1)),2,$(if $(filter 4,$(1)),3,$(if $(filter 8,$(1)),4,5))))
agilex_tiny_area = $(word $(call agilex_area_index,$(1)),$(AGILEX_AREA_$(2)))

AREA_RTL := $(wildcard rtl/riscc_*.v rtl/riscc_*.vh)
ICE40_CELLS := $(foreach w,$(TINY_WIDTHS),$(foreach c,$(TINY_CONFIGS),$(call area_cell,ice40,$(w),$(c)))) \
               $(foreach c,$(NANO_CONFIGS),$(call nano_area_cell,ice40,$(c)))
ECP5_CELLS := $(foreach w,$(TINY_WIDTHS),$(foreach c,$(TINY_CONFIGS),$(call area_cell,ecp5,$(w),$(c)))) \
              $(foreach c,$(NANO_CONFIGS),$(call nano_area_cell,ecp5,$(c)))
ECP5_BLOCK_CELLS := $(foreach w,$(TINY_WIDTHS),$(foreach c,$(TINY_CONFIGS),$(call ecp5_rf_area_cell,block,$(w),$(c)))) \
                    $(foreach c,$(NANO_CONFIGS),$(call ecp5_rf_nano_area_cell,block,$(c)))
ECP5_LUTRAM_CELLS := $(foreach w,$(TINY_WIDTHS),$(foreach c,$(TINY_CONFIGS),$(call ecp5_rf_area_cell,lutram,$(w),$(c)))) \
                     $(foreach c,$(NANO_CONFIGS),$(call ecp5_rf_nano_area_cell,lutram,$(c)))

ecp5_rf_def = $(if $(filter block,$(1)),-DRISCC_ECP5_BLOCK_RF)

define ICE40_AREA_RULE
$(call area_cell,ice40,$(1),$(2)): $$(AREA_RTL) Makefile
	@mkdir -p $$(@D)
	@$$(YOSYS) -p "read_verilog $(call tiny_cpp_defs,$(2)) $(call tiny_rtl,$(1)); $(call tiny_yosys_width,$(1)) synth_ice40 $(call tiny_area_synth_opts,$(1),$(2)) -top $(call tiny_top,$(1)); stat" \
	  2>/dev/null | awk '$$$$1=="SB_LUT4"{v=$$$$2} END{print v+0}' > $$@
endef

define ECP5_AREA_RULE
$(call area_cell,ecp5,$(1),$(2)): $$(AREA_RTL) Makefile
	@mkdir -p $$(@D)
	@$$(YOSYS) -p "read_verilog -DRISCC_ECP5 $(call tiny_cpp_defs,$(2)) $(call tiny_rtl,$(1)); $(call tiny_yosys_width,$(1)) synth_ecp5 $(call tiny_ecp5_area_synth_opts,$(1),$(2)) -top $(call tiny_top,$(1)) -nowidelut; stat" \
	  2>/dev/null | awk '$$$$1=="LUT4"{l=$$$$2} $$$$1=="CCU2C"{c=$$$$2} END{print l+2*c}' > $$@
endef

define ICE40_NANO_AREA_RULE
$(call nano_area_cell,ice40,$(1)): $$(AREA_RTL) Makefile
	@mkdir -p $$(@D)
	@$$(YOSYS) -p "read_verilog rtl/riscc_nano1.v; synth_ice40 -abc2 -top riscc_nano1; stat" \
	  2>/dev/null | awk '$$$$1=="SB_LUT4"{v=$$$$2} END{print v+0}' > $$@
endef

define ECP5_NANO_AREA_RULE
$(call nano_area_cell,ecp5,$(1)): $$(AREA_RTL) Makefile
	@mkdir -p $$(@D)
	@$$(YOSYS) -p "read_verilog -DRISCC_ECP5 rtl/riscc_nano1.v; synth_ecp5 -abc2 -top riscc_nano1 -nowidelut; stat" \
	  2>/dev/null | awk '$$$$1=="LUT4"{l=$$$$2} $$$$1=="CCU2C"{c=$$$$2} END{print l+2*c}' > $$@
endef

# Report the ECP5 RF alternatives on the same strict site basis. A mapped
# DPR16X4 occupies four RAM LUT sites plus two RAMW sites, hence 6*r. The
# result includes RF glue logic and the memory primitive; a block-RAM RF
# consumes one DP16KD but no LUT-equivalent memory sites.
define ECP5_RF_AREA_RULE
$(call ecp5_rf_area_cell,$(1),$(2),$(3)): $$(AREA_RTL) Makefile
	@mkdir -p $$(@D)
	@$$(YOSYS) -p "read_verilog -DRISCC_ECP5 $(call ecp5_rf_def,$(1)) $(call tiny_cpp_defs,$(3)) $(call tiny_rtl,$(2)); $(call tiny_yosys_width,$(2)) synth_ecp5 $(call tiny_ecp5_area_synth_opts,$(2),$(3)) -top $(call tiny_top,$(2)) -nowidelut; stat" \
	  2>/dev/null | awk '$$$$1=="LUT4"{l=$$$$2} $$$$1=="CCU2C"{c=$$$$2} $$$$1=="TRELLIS_DPR16X4"{r=$$$$2} END{print l+2*c+6*r}' > $$@
endef

define ECP5_RF_NANO_AREA_RULE
$(call ecp5_rf_nano_area_cell,$(1),$(2)): $$(AREA_RTL) Makefile
	@mkdir -p $$(@D)
	@$$(YOSYS) -p "read_verilog -DRISCC_ECP5 $(call ecp5_rf_def,$(1)) rtl/riscc_nano1.v; synth_ecp5 -abc2 -top riscc_nano1 -nowidelut; stat" \
	  2>/dev/null | awk '$$$$1=="LUT4"{l=$$$$2} $$$$1=="CCU2C"{c=$$$$2} $$$$1=="TRELLIS_DPR16X4"{r=$$$$2} END{print l+2*c+6*r}' > $$@
endef

$(foreach w,$(TINY_WIDTHS),$(foreach c,$(TINY_CONFIGS),$(eval $(call ICE40_AREA_RULE,$(w),$(c)))))
$(foreach w,$(TINY_WIDTHS),$(foreach c,$(TINY_CONFIGS),$(eval $(call ECP5_AREA_RULE,$(w),$(c)))))
$(foreach c,$(NANO_CONFIGS),$(eval $(call ICE40_NANO_AREA_RULE,$(c))))
$(foreach c,$(NANO_CONFIGS),$(eval $(call ECP5_NANO_AREA_RULE,$(c))))
$(foreach m,block lutram,$(foreach w,$(TINY_WIDTHS),$(foreach c,$(TINY_CONFIGS),$(eval $(call ECP5_RF_AREA_RULE,$(m),$(w),$(c))))))
$(foreach m,block lutram,$(foreach c,$(NANO_CONFIGS),$(eval $(call ECP5_RF_NANO_AREA_RULE,$(m),$(c)))))

$(call fast_area_cell,ice40,soft): $(AREA_RTL) Makefile
	@mkdir -p $(@D)
	@$(YOSYS) -p "read_verilog -DRISCC_FAST_SYNC_RF rtl/riscc_fast.v; synth_ice40 -abc2 -dff -top riscc_fast; stat" 2>/dev/null | \
	  awk '$$1=="SB_LUT4"{l=$$2} $$1=="SB_MAC16"{d=$$2} $$1=="SB_RAM40_4K"{r=$$2} END{print l+0,d+0,r+0}' > $@

$(call fast_area_cell,ice40,dsp): $(AREA_RTL) Makefile
	@mkdir -p $(@D)
	@$(YOSYS) -p "read_verilog -DRISCC_FAST_SYNC_RF -DRISCC_FAST_DSP rtl/riscc_fast.v; synth_ice40 -dsp -abc2 -top riscc_fast; stat" 2>/dev/null | \
	  awk '$$1=="SB_LUT4"{l=$$2} $$1=="SB_MAC16"{d=$$2} $$1=="SB_RAM40_4K"{r=$$2} END{print l+0,d+0,r+0}' > $@

$(call fast_area_cell,ecp5,dsp): $(AREA_RTL) Makefile
	@mkdir -p $(@D)
	@$(YOSYS) -p "read_verilog -DRISCC_ECP5 -DRISCC_FAST_DSP rtl/riscc_fast.v; synth_ecp5 -nowidelut -abc2 -top riscc_fast; stat" 2>/dev/null | \
	  awk '$$1=="LUT4"{l=$$2} $$1=="CCU2C"{c=$$2} $$1=="MULT18X18D"{d=$$2} $$1=="TRELLIS_DPR16X4"{r=$$2} END{print l+2*c+6*r,l+0,2*c,4*r,2*r,d+0,r+0}' > $@

$(call fast_area_cell,ecp5,soft): $(AREA_RTL) Makefile
	@mkdir -p $(@D)
	@$(YOSYS) -p "read_verilog -DRISCC_ECP5 rtl/riscc_fast.v; synth_ecp5 -nowidelut -abc2 -top riscc_fast; stat" 2>/dev/null | \
	  awk '$$1=="LUT4"{l=$$2} $$1=="CCU2C"{c=$$2} $$1=="MULT18X18D"{d=$$2} $$1=="TRELLIS_DPR16X4"{r=$$2} END{print l+2*c+6*r,l+0,2*c,4*r,2*r,d+0,r+0}' > $@


area-fast: $(call fast_area_cell,ice40,soft) $(call fast_area_cell,ice40,dsp) \
           $(call fast_area_cell,ecp5,soft) $(call fast_area_cell,ecp5,dsp)
	@set -- $$(cat $(call fast_area_cell,ice40,soft)); ilut=$$1; idsp=$$2; ieb=$$3; \
	  set -- $$(cat $(call fast_area_cell,ecp5,soft)); elut=$$1; edsp=$$6; \
	  printf 'fast soft: iCE40 %s LUT4/%s DSP/%s EBR; ECP5 %s LUT sites/%s DSP; Agilex %s ALM/%s DSP\n' \
	    "$$ilut" "$$idsp" "$$ieb" "$$elut" "$$edsp" "$(AGILEX_AREA_FAST_SOFT)" 0
	@set -- $$(cat $(call fast_area_cell,ice40,dsp)); ilut=$$1; idsp=$$2; ieb=$$3; \
	  set -- $$(cat $(call fast_area_cell,ecp5,dsp)); elut=$$1; edsp=$$6; \
	  printf 'fast DSP:  iCE40 %s LUT4/%s DSP/%s EBR; ECP5 %s LUT sites/%s DSP; Agilex %s ALM/%s DSP\n' \
	    "$$ilut" "$$idsp" "$$ieb" "$$elut" "$$edsp" "$(AGILEX_AREA_FAST_DSP)" 1
	@printf 'faster DSP: Agilex %s ALM/%s DSP\n' "$(AGILEX_AREA_FASTER_DSP)" 1
	@printf 'faster soft: Agilex %s ALM/%s DSP\n' "$(AGILEX_AREA_FASTER_SOFT)" 0

check-fast-dsp: $(call fast_area_cell,ecp5,dsp)
	@set -- $$(cat $(call fast_area_cell,ecp5,dsp)); test "$$1" -lt 460 -a "$$6" = 1 -a "$$7" = 8
	@echo "fast ECP5 mapping PASS (<460 occupied LUT sites including RF, one DSP)"

check-fast-ice: $(call fast_area_cell,ice40,soft) $(call fast_area_cell,ice40,dsp)
	@set -- $$(cat $(call fast_area_cell,ice40,soft)); test "$$1" -lt 490 -a "$$2" = 0 -a "$$3" = 2
	@set -- $$(cat $(call fast_area_cell,ice40,dsp)); test "$$1" -lt 450 -a "$$2" = 1 -a "$$3" = 2
	@echo "fast iCE40 mapping PASS (two RF EBRs; soft <490 LUT4, DSP <450 LUT4)"

# ---- Routed core timing ----------------------------------------------

FMAX_TOP := $(RTL_TEST_DIR)/riscc_fmax_top.v
FMAX_RTL := $(FMAX_TOP) rtl/riscc_fast.v rtl/riscc_tiny.v rtl/riscc_tiny16.v \
            rtl/riscc_nano1.v rtl/riscc_rf.vh Makefile

ice40_tiny_fmax_defs = $(strip $(call tiny_cpp_defs,$(3)) \
  $(if $(filter 16,$(2)),,-DRISCC_FMAX_TINY -DRISCC_FMAX_WIDTH=$(2)))

define ICE40_FMAX_RULE
$(call ice40_fmax_cell,$(1),$(2),$(3)): $$(FMAX_RTL)
	@mkdir -p $$(@D)
	@$$(YOSYS) -q -p "read_verilog $(call ice40_tiny_fmax_defs,$(1),$(2),$(3)) $(call tiny_rtl,$(2)) $(FMAX_TOP); synth_ice40 -top riscc_fmax_top -json $$(@:.mhz=.json)"
	@$$(NEXTPNR_ICE40) --$(1) --package $(if $(filter up5k,$(1)),sg48,ct256) $(if $(filter hx8k,$(1)),--no-promote-globals,) --pcf-allow-unconstrained --freq 10 --seed $$(ICE40_FMAX_SEED) \
	  --json $$(@:.mhz=.json) --asc $$(@:.mhz=.asc) >$$(@:.mhz=.log) 2>&1
	@awk '/Max frequency for clock/{for(i=1;i<NF;i++) if($$$$(i+1)=="MHz") v=$$$$i} END{print v}' $$(@:.mhz=.log) > $$@
endef

$(foreach d,up5k hx8k,$(foreach w,$(TINY_WIDTHS),$(foreach c,$(TINY_CONFIGS),$(eval $(call ICE40_FMAX_RULE,$(d),$(w),$(c))))))

define ICE40_NANO_FMAX_RULE
$(call ice40_nano_fmax_cell,$(1)): $$(FMAX_RTL)
	@mkdir -p $$(@D)
	@$$(YOSYS) -q -p "read_verilog -DRISCC_FMAX_NANO rtl/riscc_nano1.v $(FMAX_TOP); synth_ice40 -top riscc_fmax_top -json $$(@:.mhz=.json)"
	@$$(NEXTPNR_ICE40) --$(1) --package $(if $(filter up5k,$(1)),sg48,ct256) $(if $(filter hx8k,$(1)),--no-promote-globals,) --pcf-allow-unconstrained --freq 10 --seed $$(ICE40_FMAX_SEED) \
	  --json $$(@:.mhz=.json) --asc $$(@:.mhz=.asc) >$$(@:.mhz=.log) 2>&1
	@awk '/Max frequency for clock/{for(i=1;i<NF;i++) if($$$$(i+1)=="MHz") v=$$$$i} END{print v}' $$(@:.mhz=.log) > $$@
endef

$(foreach d,up5k hx8k,$(eval $(call ICE40_NANO_FMAX_RULE,$(d))))

build/fmax/ice40/tiny16.mhz: $(FMAX_RTL)
	@mkdir -p $(@D)
	@$(YOSYS) -q -p "read_verilog -DRISCC_SYS -DRISCC_FULL rtl/riscc_tiny16.v $(FMAX_TOP); synth_ice40 -top riscc_fmax_top -json $(@:.mhz=.json)"
	@$(NEXTPNR_ICE40) --hx8k --package ct256 --pcf-allow-unconstrained --freq 50 \
	  --json $(@:.mhz=.json) --asc $(@:.mhz=.asc) >$(@:.mhz=.log) 2>&1
	@awk '/Max frequency for clock/{for(i=1;i<NF;i++) if($$(i+1)=="MHz") v=$$i} END{print v}' $(@:.mhz=.log) > $@

build/fmax/ice40/fast.mhz: $(FMAX_RTL)
	@mkdir -p $(@D)
	@$(YOSYS) -q -p "read_verilog -DRISCC_FMAX_FAST -DRISCC_FAST_SYNC_RF rtl/riscc_fast.v $(FMAX_TOP); synth_ice40 -abc2 -top riscc_fmax_top -json $(@:.mhz=.json)"
	@$(NEXTPNR_ICE40) --hx8k --package ct256 --pcf-allow-unconstrained --freq 40 \
	  --json $(@:.mhz=.json) --asc $(@:.mhz=.asc) >$(@:.mhz=.log) 2>&1
	@awk '/Max frequency for clock/{for(i=1;i<NF;i++) if($$(i+1)=="MHz") v=$$i} END{print v}' $(@:.mhz=.log) > $@

build/fmax/ice40/fast-dsp.mhz: $(FMAX_RTL)
	@mkdir -p $(@D)
	@$(YOSYS) -q -p "read_verilog -DRISCC_FMAX_FAST -DRISCC_FAST_SYNC_RF -DRISCC_FAST_DSP rtl/riscc_fast.v $(FMAX_TOP); synth_ice40 -dsp -abc2 -top riscc_fmax_top -json $(@:.mhz=.json)"
	@$(NEXTPNR_ICE40) --up5k --package sg48 --pcf-allow-unconstrained --freq 10 \
	  --json $(@:.mhz=.json) --asc $(@:.mhz=.asc) >$(@:.mhz=.log) 2>&1
	@awk '/Max frequency for clock/{for(i=1;i<NF;i++) if($$(i+1)=="MHz") v=$$i} END{print v}' $(@:.mhz=.log) > $@

build/fmax/ice40/fast-soft-up5k.mhz: $(FMAX_RTL)
	@mkdir -p $(@D)
	@$(YOSYS) -q -p "read_verilog -DRISCC_FMAX_FAST -DRISCC_FAST_SYNC_RF rtl/riscc_fast.v $(FMAX_TOP); synth_ice40 -abc2 -top riscc_fmax_top -json $(@:.mhz=.json)"
	@$(NEXTPNR_ICE40) --up5k --package sg48 --pcf-allow-unconstrained --freq 10 \
	  --json $(@:.mhz=.json) --asc $(@:.mhz=.asc) >$(@:.mhz=.log) 2>&1
	@awk '/Max frequency for clock/{for(i=1;i<NF;i++) if($$(i+1)=="MHz") v=$$i} END{print v}' $(@:.mhz=.log) > $@

build/fmax/ecp5/tiny16.mhz: $(FMAX_RTL)
	@mkdir -p $(@D)
	@$(YOSYS) -q -p "read_verilog -DRISCC_ECP5 -DRISCC_SYS -DRISCC_FULL rtl/riscc_tiny16.v $(FMAX_TOP); synth_ecp5 -nowidelut -top riscc_fmax_top -json $(@:.mhz=.json)"
	@$(NEXTPNR_ECP5) --25k --package CABGA256 --speed 6 --lpf-allow-unconstrained --freq 40 \
	  --json $(@:.mhz=.json) --textcfg $(@:.mhz=.config) >$(@:.mhz=.log) 2>&1
	@awk '/Max frequency for clock/{for(i=1;i<NF;i++) if($$(i+1)=="MHz") v=$$i} END{print v}' $(@:.mhz=.log) > $@

build/fmax/ecp5/fast-dsp.mhz: $(FMAX_RTL)
	@mkdir -p $(@D)
	@$(YOSYS) -q -p "read_verilog -DRISCC_ECP5 -DRISCC_FMAX_FAST -DRISCC_FAST_DSP rtl/riscc_fast.v $(FMAX_TOP); synth_ecp5 -nowidelut -abc2 -top riscc_fmax_top -json $(@:.mhz=.json)"
	@$(NEXTPNR_ECP5) --25k --package CABGA256 --speed 6 --lpf-allow-unconstrained --freq 50 \
	  --json $(@:.mhz=.json) --textcfg $(@:.mhz=.config) >$(@:.mhz=.log) 2>&1
	@awk '/Max frequency for clock/{for(i=1;i<NF;i++) if($$(i+1)=="MHz") v=$$i} END{print v}' $(@:.mhz=.log) > $@

build/fmax/ecp5/fast-soft.mhz: $(FMAX_RTL)
	@mkdir -p $(@D)
	@$(YOSYS) -q -p "read_verilog -DRISCC_ECP5 -DRISCC_FMAX_FAST rtl/riscc_fast.v $(FMAX_TOP); synth_ecp5 -nowidelut -abc2 -top riscc_fmax_top -json $(@:.mhz=.json)"
	@$(NEXTPNR_ECP5) --25k --package CABGA256 --speed 6 --lpf-allow-unconstrained --freq 50 \
	  --json $(@:.mhz=.json) --textcfg $(@:.mhz=.config) >$(@:.mhz=.log) 2>&1
	@awk '/Max frequency for clock/{for(i=1;i<NF;i++) if($$(i+1)=="MHz") v=$$i} END{print v}' $(@:.mhz=.log) > $@

tiny_fmax_defs = $(strip -DRISCC_ECP5 $(call tiny_cpp_defs,$(2)) \
  $(if $(filter 16,$(1)),,-DRISCC_FMAX_TINY -DRISCC_FMAX_WIDTH=$(1)))

define ECP5_FMAX_RULE
$(call ecp5_fmax_cell,$(1),$(2)): $$(FMAX_RTL)
	@mkdir -p $$(@D)
	@$$(YOSYS) -q -p "read_verilog $(call tiny_fmax_defs,$(1),$(2)) $(call tiny_rtl,$(1)) $(FMAX_TOP); synth_ecp5 -nowidelut -top riscc_fmax_top -json $$(@:.mhz=.json)"
	@$$(NEXTPNR_ECP5) --25k --package CABGA256 --speed 6 --lpf-allow-unconstrained --freq 40 --seed $$(ECP5_FMAX_SEED) \
	  --json $$(@:.mhz=.json) --textcfg $$(@:.mhz=.config) >$$(@:.mhz=.log) 2>&1
	@awk '/Max frequency for clock/{for(i=1;i<NF;i++) if($$$$(i+1)=="MHz") v=$$$$i} END{print v}' $$(@:.mhz=.log) > $$@
endef

$(foreach w,$(TINY_WIDTHS),$(foreach c,$(TINY_CONFIGS),$(eval $(call ECP5_FMAX_RULE,$(w),$(c)))))

$(ecp5_nano_fmax_cell): $(FMAX_RTL)
	@mkdir -p $(@D)
	@$(YOSYS) -q -p "read_verilog -DRISCC_ECP5 -DRISCC_FMAX_NANO rtl/riscc_nano1.v $(FMAX_TOP); synth_ecp5 -nowidelut -top riscc_fmax_top -json $(@:.mhz=.json)"
	@$(NEXTPNR_ECP5) --25k --package CABGA256 --speed 6 --lpf-allow-unconstrained --freq 40 --seed $(ECP5_FMAX_SEED) \
	  --json $(@:.mhz=.json) --textcfg $(@:.mhz=.config) >$(@:.mhz=.log) 2>&1
	@awk '/Max frequency for clock/{for(i=1;i<NF;i++) if($$(i+1)=="MHz") v=$$i} END{print v}' $(@:.mhz=.log) > $@

fmax-fast: build/fmax/ice40/fast-soft-up5k.mhz build/fmax/ice40/fast-dsp.mhz \
           build/fmax/ice40/fast.mhz \
           build/fmax/ecp5/fast-soft.mhz build/fmax/ecp5/fast-dsp.mhz
	@printf 'fast soft: UP5K %s MHz; HX8K %s MHz; ECP5 %s MHz; Agilex %s MHz\n' \
	  "$$(cat build/fmax/ice40/fast-soft-up5k.mhz)" \
	  "$$(cat build/fmax/ice40/fast.mhz)" \
	  "$$(cat build/fmax/ecp5/fast-soft.mhz)" \
	  "$(AGILEX_FMAX_FAST_SOFT)"
	@printf 'fast DSP:  UP5K %s MHz; ECP5 %s MHz; Agilex %s MHz\n' \
	  "$$(cat build/fmax/ice40/fast-dsp.mhz)" \
	  "$$(cat build/fmax/ecp5/fast-dsp.mhz)" \
	  "$(AGILEX_FMAX_FAST_DSP)"
	@printf 'faster DSP: Agilex %s MHz\n' "$(AGILEX_FMAX_FASTER_DSP)"
	@printf 'faster soft: Agilex %s MHz\n' "$(AGILEX_FMAX_FASTER_SOFT)"

fmax-ecp5: $(ECP5_FMAX_CELLS)
	@echo "ECP5 LFE5U-25F speed 6, nextpnr seed $(ECP5_FMAX_SEED)"
	@printf '%-24s %7s %7s %7s %7s %7s\n' profile /1 /2 /4 /8 /16
	@for t in $(TINY_CONFIGS); do printf '%-24s' $$t; \
	  for w in $(TINY_WIDTHS); do printf ' %7s' "$$(cat build/fmax/ecp5/tiny$$w-$$t.mhz)"; done; echo; done
	@printf '%-24s %7s\n' nano "$$(cat $(ecp5_nano_fmax_cell))"

define TINY_FMAX_TARGET_RULE
fmax-$(1)-$(2): $(call ice40_fmax_cell,up5k,$(1),$(2)) \
                $(call ice40_fmax_cell,hx8k,$(1),$(2)) \
                $(call ecp5_fmax_cell,$(1),$(2))
	@printf 'tiny%-2s %-5s: UP5K %s MHz; HX8K %s MHz; ECP5 %s MHz\n' \
	  $(1) $(2) \
	  "$$$$(cat $(call ice40_fmax_cell,up5k,$(1),$(2)))" \
	  "$$$$(cat $(call ice40_fmax_cell,hx8k,$(1),$(2)))" \
	  "$$$$(cat $(call ecp5_fmax_cell,$(1),$(2)))"
endef

$(foreach w,$(TINY_WIDTHS),$(foreach c,$(TINY_CONFIGS),$(eval $(call TINY_FMAX_TARGET_RULE,$(w),$(c)))))

fmax-nano: $(call ice40_nano_fmax_cell,up5k) \
           $(call ice40_nano_fmax_cell,hx8k) \
           $(ecp5_nano_fmax_cell)
	@printf 'nano: UP5K %s MHz; HX8K %s MHz; ECP5 %s MHz\n' \
	  "$$(cat $(call ice40_nano_fmax_cell,up5k))" \
	  "$$(cat $(call ice40_nano_fmax_cell,hx8k))" \
	  "$$(cat $(ecp5_nano_fmax_cell))"

define ICE40_FMAX_PRINT
	@echo "$(1) iCE40, nextpnr seed $(ICE40_FMAX_SEED)"
	@printf '%-24s %7s %7s %7s %7s %7s\n' profile /1 /2 /4 /8 /16
	@for t in $(TINY_CONFIGS); do printf '%-24s' $$t; \
	  for w in $(TINY_WIDTHS); do printf ' %7s' "$$(cat build/fmax/ice40/$(1)/tiny$$w-$$t.mhz)"; done; echo; done
	@printf '%-24s %7s\n' nano "$$(cat $(call ice40_nano_fmax_cell,$(1)))"
endef

fmax-ice40: $(ICE40_FMAX_CELLS)
	$(call ICE40_FMAX_PRINT,up5k)
	$(call ICE40_FMAX_PRINT,hx8k)

define FMAX_AGILEX_PRINT
	@echo "Agilex 3 Fmax (MHz; published Quartus core characterization)"
	@printf '%-24s %7s %7s %7s %7s %7s\n' profile /1 /2 /4 /8 /16
	@printf '%-24s %7s %7s %7s %7s %7s\n' sys $(AGILEX_FMAX_SYS)
	@printf '%-24s %7s\n' nano $(AGILEX_FMAX_NANO)
	@printf '%-24s %7s\n' 'fast soft' $(AGILEX_FMAX_FAST_SOFT)
	@printf '%-24s %7s\n' 'fast DSP' $(AGILEX_FMAX_FAST_DSP)
	@printf '%-24s %7s\n' 'faster DSP (default)' $(AGILEX_FMAX_FASTER_DSP)
	@printf '%-24s %7s\n' 'faster soft' $(AGILEX_FMAX_FASTER_SOFT)
endef

fmax-agilex:
	$(call FMAX_AGILEX_PRINT)

# Keep reports readable under a parallel top-level make.  Each recursive make
# still receives the jobserver and can build its own timing cells in parallel.
fmax-table:
	+$(MAKE) --no-print-directory fmax-ice40
	+$(MAKE) --no-print-directory fmax-ecp5
	+$(MAKE) --no-print-directory fmax-fast
	+$(MAKE) --no-print-directory fmax-agilex

fmax-all: fmax-table

tables: area-all fmax-all bench

define TINY_AREA_TARGET_RULE
area-$(1)-$(2): $(call area_cell,ice40,$(1),$(2)) \
                $(call ecp5_rf_area_cell,block,$(1),$(2)) \
                $(call ecp5_rf_area_cell,lutram,$(1),$(2))
	@printf 'tiny%-2s %-5s: iCE40 %s LUT4; ECP5 block %s; ECP5 RF %s; Agilex %s ALM\n' \
	  $(1) $(2) \
	  "$$$$(cat $(call area_cell,ice40,$(1),$(2)))" \
	  "$$$$(cat $(call ecp5_rf_area_cell,block,$(1),$(2)))" \
	  "$$$$(cat $(call ecp5_rf_area_cell,lutram,$(1),$(2)))" \
	  "$(call agilex_tiny_area,$(1),$(2))"
endef

$(foreach w,$(TINY_WIDTHS),$(foreach c,$(TINY_CONFIGS),$(eval $(call TINY_AREA_TARGET_RULE,$(w),$(c)))))
$(foreach w,$(TINY_WIDTHS),$(eval area-$(w): area-$(w)-sys))

define NANO_AREA_TARGET_RULE
$(call nano_area_target,$(1)): $(call nano_area_cell,ice40,$(1)) \
                              $(call ecp5_rf_nano_area_cell,block,$(1)) \
                              $(call ecp5_rf_nano_area_cell,lutram,$(1))
	@printf 'nano: iCE40 %s LUT4; ECP5 block %s; ECP5 RF %s; Agilex %s ALM\n' \
	  "$$$$(cat $(call nano_area_cell,ice40,$(1)))" \
	  "$$$$(cat $(call ecp5_rf_nano_area_cell,block,$(1)))" \
	  "$$$$(cat $(call ecp5_rf_nano_area_cell,lutram,$(1)))" \
	  "$(AGILEX_AREA_NANO)"
endef

$(foreach c,$(NANO_CONFIGS),$(eval $(call NANO_AREA_TARGET_RULE,$(c))))

define AREA_PRINT
	@printf '%-24s %5s %5s %5s %5s %5s\n' profile /1 /2 /4 /8 /16
	@for t in $(TINY_CONFIGS); do printf '%-24s' $$t; \
	  for w in $(TINY_WIDTHS); do printf ' %5s' "$$(cat build/area/$(1)/tiny$$w/$$t.lut)"; done; echo; done
	@printf '%-32s %5s\n' nano "$$(cat build/area/$(1)/nano/nano.lut)"
endef

define AREA_AGILEX_PRINT
	@echo "Agilex 3 ALMs (published Quartus core characterization)"
	@printf '%-32s %7s %7s %7s %7s %7s\n' profile /1 /2 /4 /8 /16
	@printf '%-32s %7s %7s %7s %7s %7s\n' min $(AGILEX_AREA_MIN)
	@printf '%-32s %7s %7s %7s %7s %7s\n' sys $(AGILEX_AREA_SYS)
	@printf '%-32s %7s %7s %7s %7s %7s\n' full $(AGILEX_AREA_FULL)
	@printf '%-32s %7s\n' nano $(AGILEX_AREA_NANO)
	@printf '%-32s %7s\n' 'fast soft' $(AGILEX_AREA_FAST_SOFT)
	@printf '%-32s %7s\n' 'fast DSP' $(AGILEX_AREA_FAST_DSP)
	@printf '%-32s %7s\n' 'faster DSP (default)' $(AGILEX_AREA_FASTER_DSP)
	@printf '%-32s %7s\n' 'faster soft' $(AGILEX_AREA_FASTER_SOFT)
endef

area-agilex:
	$(call AREA_AGILEX_PRINT)

area-table: $(ICE40_CELLS) $(ECP5_BLOCK_CELLS) $(ECP5_LUTRAM_CELLS)
	@echo "iCE40 LUT4 (area-best mapper per row; RF in SB_RAM40_4K EBR)"
	$(call AREA_PRINT,ice40)
	@echo "ECP5 LUTs, block RF"
	$(call AREA_PRINT,ecp5-block)
	@echo "ECP5 LUTs, RF included"
	$(call AREA_PRINT,ecp5-lutram)
	$(call AREA_AGILEX_PRINT)

area: area-all
area-all: area-table area-fast

area-ecp5: $(ECP5_BLOCK_CELLS) $(ECP5_LUTRAM_CELLS)
	@echo "ECP5 LUTs, block RF"
	$(call AREA_PRINT,ecp5-block)
	@echo "ECP5 LUTs, RF included"
	$(call AREA_PRINT,ecp5-lutram)

.PHONY: clean distclean
clean:
	rm -rf __pycache__ tools/build
	@if test -d build; then \
	  find build -mindepth 1 -maxdepth 1 ! -name llvm-riscc ! -name firmware \
	    -exec rm -rf {} +; \
	fi

# The prebuilt LLVM toolchain and RISC-C runtime are SDK artifacts.  Preserve
# them for ordinary clean builds; remove them only on an explicit distclean.
distclean: clean
	rm -rf build/llvm-riscc build/firmware

# ---- Experimental RISC-C LLVM toolchain ------------------------------

# Keep this integration self-contained while the backend lives in the vendor
# checkout. Override the knobs below to use a different layout, generator, or
# build configuration without changing the project rules.
LLVM_RISCC_SOURCE ?= external/llvm-project/llvm
LLVM_RISCC_BUILD ?= build/llvm-riscc
LLVM_RISCC_GENERATOR ?= Ninja
LLVM_RISCC_BUILD_TYPE ?= Release
LLVM_RISCC_CMAKE ?= cmake
LLVM_RISCC_CMAKE_FLAGS ?=
# Keep the downstream build to the tools used by this repository.  The
# optional pieces below are deliberately unavailable: RISC-C does not use
# upstream tests, documentation, examples, benchmarks, bindings, runtimes,
# static analysis, plugins, or compressed/debug-object support.
LLVM_RISCC_MINIMAL_CMAKE_FLAGS := \
	-DLLVM_INCLUDE_TESTS=OFF \
	-DLLVM_INCLUDE_EXAMPLES=OFF \
	-DLLVM_INCLUDE_BENCHMARKS=OFF \
	-DLLVM_INCLUDE_DOCS=OFF \
	-DLLVM_INCLUDE_UTILS=OFF \
	-DLLVM_INCLUDE_RUNTIMES=OFF \
	-DLLVM_BUILD_TOOLS=OFF \
	-DLLVM_BUILD_UTILS=OFF \
	-DLLVM_BUILD_RUNTIMES=OFF \
	-DLLVM_BUILD_RUNTIME=OFF \
	-DLLVM_ENABLE_BINDINGS=OFF \
	-DLLVM_ENABLE_TELEMETRY=OFF \
	-DLLVM_ENABLE_BACKTRACES=OFF \
	-DLLVM_ENABLE_LIBEDIT=OFF \
	-DLLVM_ENABLE_LIBPFM=OFF \
	-DLLVM_ENABLE_LIBXML2=OFF \
	-DLLVM_ENABLE_ZLIB=OFF \
	-DLLVM_ENABLE_ZSTD=OFF \
	-DCLANG_BUILD_TOOLS=OFF \
	-DCLANG_INCLUDE_TESTS=OFF \
	-DCLANG_INCLUDE_DOCS=OFF \
	-DCLANG_ENABLE_STATIC_ANALYZER=OFF \
	-DCLANG_PLUGIN_SUPPORT=OFF \
	-DLLD_BUILD_TOOLS=ON
LLVM_RISCC_BUILD_TARGETS ?= clang lld llvm-ar llvm-mc llvm-objcopy \
	llvm-objdump llvm-readobj llvm-nm llvm-size \
	llc opt llvm-as llvm-dis
# Reuse the project's writable ccache selection for LLVM's host C/C++
# compilation.  Set this empty to disable it or point it at another launcher.
LLVM_RISCC_COMPILER_LAUNCHER ?= $(CCACHE)
LLVM_RISCC_COMPILER_LAUNCHER_FLAGS := $(if $(strip $(LLVM_RISCC_COMPILER_LAUNCHER)), \
	-DCMAKE_C_COMPILER_LAUNCHER=$(LLVM_RISCC_COMPILER_LAUNCHER) \
	-DCMAKE_CXX_COMPILER_LAUNCHER=$(LLVM_RISCC_COMPILER_LAUNCHER))

LLVM_RISCC_BIN := $(LLVM_RISCC_BUILD)/bin
RISCC_CLANG := $(LLVM_RISCC_BIN)/clang
RISCC_AR := $(LLVM_RISCC_BIN)/llvm-ar
RISCC_OBJCOPY := $(LLVM_RISCC_BIN)/llvm-objcopy
RISCC_MC := $(LLVM_RISCC_BIN)/llvm-mc
RISCC_LLD := $(LLVM_RISCC_BIN)/ld.lld
LLVM_RISCC_CACHE := $(LLVM_RISCC_BUILD)/CMakeCache.txt

RISCC_FIRMWARE_BUILD ?= build/firmware
RISCC_COMPILER_BUILD ?= build/compiler
RISCC_COMPILER_MAX_INSNS ?= 1000000
RISCC_TARGET_FLAGS ?= --target=riscc-none-elf -mcpu=full
RISCC_ASFLAGS ?= -ffreestanding
RISCC_CFLAGS ?= -Os -ffreestanding -fno-builtin -fno-pic -fno-pie \
	-fno-unwind-tables -fno-asynchronous-unwind-tables \
	-ffunction-sections -fdata-sections
# Keep static support libraries genuinely pay-for-what-you-use: archive
# extraction avoids unused objects and this drops unused function/data sections
# within an extracted object.
RISCC_LDFLAGS ?= -Wl,--gc-sections

RISCC_FIRMWARE_VECTORS := $(RISCC_FIRMWARE_BUILD)/vectors.o
RISCC_FIRMWARE_CRT0 := $(RISCC_FIRMWARE_BUILD)/crt0.o
RISCC_FIRMWARE_IRQ_ENTRY := $(RISCC_FIRMWARE_BUILD)/irq.o
RISCC_FIRMWARE_IRQ_DEFAULT := $(RISCC_FIRMWARE_BUILD)/irq_default.o
RISCC_FIRMWARE_IRQ_CONTROL := $(RISCC_FIRMWARE_BUILD)/irq_control.o
RISCC_FIRMWARE_IRQ_LIBRARY := $(RISCC_FIRMWARE_BUILD)/libirq.a
RISCC_BUILTINS_OBJECT := $(RISCC_FIRMWARE_BUILD)/builtins/integer.o
RISCC_BUILTINS_LIBRARY := $(RISCC_FIRMWARE_BUILD)/libbuiltins.a
RISCC_LIBC_OBJECTS := $(RISCC_FIRMWARE_BUILD)/libc/memory.o \
	$(RISCC_FIRMWARE_BUILD)/libc/stdio.o
RISCC_LIBC_LIBRARY := $(RISCC_FIRMWARE_BUILD)/libc.a
RISCC_FIRMWARE_LIBRARIES := $(RISCC_FIRMWARE_IRQ_LIBRARY) \
	$(RISCC_BUILTINS_LIBRARY) \
	$(RISCC_LIBC_LIBRARY)

RISCC_COMPILER_OBJECTS := $(RISCC_COMPILER_BUILD)/smoke.o \
	$(RISCC_COMPILER_BUILD)/helper.o
RISCC_COMPILER_ELF := $(RISCC_COMPILER_BUILD)/smoke.elf
RISCC_COMPILER_BIN := $(RISCC_COMPILER_BUILD)/smoke.bin
RISCC_COMPILER_MEMH := $(RISCC_COMPILER_BUILD)/smoke.memh
RISCC_COMPILER_UART_OBJECT := $(RISCC_COMPILER_BUILD)/smoke-uart.o
RISCC_COMPILER_UART_ELF := $(RISCC_COMPILER_BUILD)/smoke-uart.elf
RISCC_COMPILER_UART_BIN := $(RISCC_COMPILER_BUILD)/smoke-uart.bin
RISCC_COMPILER_UART_MEMH := $(RISCC_COMPILER_BUILD)/smoke-uart.memh
RISCC_COMPILER_STDIO_OBJECT := $(RISCC_COMPILER_BUILD)/stdio_smoke.o
RISCC_COMPILER_STDIO_ELF := $(RISCC_COMPILER_BUILD)/stdio-smoke.elf
RISCC_COMPILER_STDIO_BIN := $(RISCC_COMPILER_BUILD)/stdio-smoke.bin
RISCC_COMPILER_STDIO_UART_LOG := $(RISCC_COMPILER_BUILD)/stdio-smoke-uart.txt
RISCC_COMPILER_SPLIT_ELF := $(RISCC_COMPILER_BUILD)/smoke-split.elf
RISCC_COMPILER_CODE_BIN := $(RISCC_COMPILER_BUILD)/code.bin
RISCC_COMPILER_DATA_BIN := $(RISCC_COMPILER_BUILD)/data.bin
RISCC_COMPILER_ICEPI_RTLSIM := $(RISCC_COMPILER_BUILD)/icepi-rtlsim/Vicepi_zero_soc_sim
RISCC_COMPILER_ATUM_RTLSIM := $(RISCC_COMPILER_BUILD)/atum-rtlsim/Vatum_a3_nano_soc_sim
RISCC_COMPILER_IRQ_OBJECTS := $(RISCC_COMPILER_BUILD)/irq_smoke.o \
	$(RISCC_COMPILER_BUILD)/irq_smoke_main.o
RISCC_COMPILER_IRQ_ELF := $(RISCC_COMPILER_BUILD)/irq-smoke.elf
RISCC_COMPILER_IRQ_BIN := $(RISCC_COMPILER_BUILD)/irq-smoke.bin
RISCC_COMPILER_IRQ_MAP := $(RISCC_COMPILER_BUILD)/irq-smoke.map
RISCC_COMPILER_IRQ_CUSTOM_OBJECT := $(RISCC_COMPILER_BUILD)/irq_custom_vector.o
RISCC_COMPILER_IRQ_CUSTOM_ELF := $(RISCC_COMPILER_BUILD)/irq-custom-smoke.elf
RISCC_COMPILER_IRQ_CUSTOM_BIN := $(RISCC_COMPILER_BUILD)/irq-custom-smoke.bin
RISCC_COMPILER_IRQ_CUSTOM_MAP := $(RISCC_COMPILER_BUILD)/irq-custom-smoke.map
RISCC_COMPILER_FEATURE_MODULES := feature_main feature_language feature_integer \
	feature_builtins feature_memory feature_abi feature_abi_callee
RISCC_COMPILER_FEATURE_ASM_OBJECT := \
	$(RISCC_COMPILER_BUILD)/features/feature_abi_asm.o

.PHONY: llvm-riscc-configure llvm-riscc riscc-firmware \
	compiler-smoke compiler-smoke-unified compiler-smoke-iss \
	compiler-smoke-split compiler-smoke-tiny16 compiler-smoke-fast compiler-smoke-icepi \
	compiler-smoke-atum compiler-smoke-opt-o0 compiler-smoke-opt-o2 \
	compiler-smoke-opt-os compiler-smoke-opt-matrix \
	compiler-features-o0-iss compiler-features-o2-iss \
	compiler-features-os-iss compiler-features-iss \
	compiler-stdio-iss \
	compiler-irq-iss compiler-irq-tiny16 compiler-irq-fast \
	compiler-irq-custom-iss compiler-irq-custom-tiny16 compiler-irq-custom-fast \
	compiler-irq-linkage \
	check-llvm-mc-encodings test-compiler

llvm-riscc-configure:
	$(LLVM_RISCC_CMAKE) -S $(LLVM_RISCC_SOURCE) -B $(LLVM_RISCC_BUILD) \
	  -G '$(LLVM_RISCC_GENERATOR)' \
	  -DCMAKE_BUILD_TYPE='$(LLVM_RISCC_BUILD_TYPE)' \
	  -DLLVM_ENABLE_PROJECTS='clang;lld' \
	  -DLLVM_TARGETS_TO_BUILD= \
	  -DLLVM_EXPERIMENTAL_TARGETS_TO_BUILD=RISCC \
	  $(LLVM_RISCC_MINIMAL_CMAKE_FLAGS) \
	  $(LLVM_RISCC_COMPILER_LAUNCHER_FLAGS) \
	  $(LLVM_RISCC_CMAKE_FLAGS) \
	  -DLLVM_ENABLE_ASSERTIONS=ON

# Normal builds reuse an existing configured tree.  Ninja reruns CMake itself
# when LLVM CMake inputs change; invoke llvm-riscc-configure explicitly when
# changing generator or CMake cache options.
$(LLVM_RISCC_CACHE):
	$(MAKE) llvm-riscc-configure

llvm-riscc: $(LLVM_RISCC_CACHE)
	$(LLVM_RISCC_CMAKE) --build $(LLVM_RISCC_BUILD) \
	  --target $(LLVM_RISCC_BUILD_TARGETS) --parallel $(RISCC_BUILD_JOBS)

# Each tool is made available through the phony build target, but is a normal
# prerequisite of the artifacts that use it.  That avoids gratuitously
# rebuilding every firmware object while still rebuilding an artifact after its
# compiler, linker, archive, or objcopy tool actually changes.
$(RISCC_CLANG) $(RISCC_AR) $(RISCC_OBJCOPY) $(RISCC_MC) $(RISCC_LLD): | llvm-riscc

$(RISCC_FIRMWARE_VECTORS): firmware/vectors.S $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_ASFLAGS) -c $< -o $@

$(RISCC_FIRMWARE_CRT0): firmware/crt0.S $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_ASFLAGS) -c $< -o $@

$(RISCC_FIRMWARE_IRQ_ENTRY): firmware/irq.S $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_ASFLAGS) -c $< -o $@

$(RISCC_FIRMWARE_IRQ_DEFAULT): firmware/irq_default.S $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_ASFLAGS) -c $< -o $@

$(RISCC_FIRMWARE_IRQ_CONTROL): firmware/irq_control.S $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_ASFLAGS) -c $< -o $@

$(RISCC_BUILTINS_OBJECT): firmware/builtins/integer.c $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_CFLAGS) -c $< -o $@

$(RISCC_FIRMWARE_BUILD)/libc/%.o: firmware/libc/%.c firmware/include/stdio.h $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_CFLAGS) -Ifirmware/include -c $< -o $@

$(RISCC_BUILTINS_LIBRARY): $(RISCC_BUILTINS_OBJECT) $(RISCC_AR)
	@mkdir -p $(@D)
	$(RISCC_AR) rcs $@ $(RISCC_BUILTINS_OBJECT)

$(RISCC_LIBC_LIBRARY): $(RISCC_LIBC_OBJECTS) $(RISCC_AR)
	@mkdir -p $(@D)
	$(RISCC_AR) rcs $@ $(RISCC_LIBC_OBJECTS)

$(RISCC_FIRMWARE_IRQ_LIBRARY): $(RISCC_FIRMWARE_IRQ_DEFAULT) \
		$(RISCC_FIRMWARE_IRQ_CONTROL) $(RISCC_FIRMWARE_IRQ_ENTRY) $(RISCC_AR)
	@mkdir -p $(@D)
	$(RISCC_AR) rcs $@ $(RISCC_FIRMWARE_IRQ_DEFAULT) \
	  $(RISCC_FIRMWARE_IRQ_CONTROL) $(RISCC_FIRMWARE_IRQ_ENTRY)

riscc-firmware: $(RISCC_FIRMWARE_VECTORS) $(RISCC_FIRMWARE_CRT0) \
	$(RISCC_FIRMWARE_LIBRARIES)

$(RISCC_COMPILER_BUILD)/%.o: test/compiler/%.c \
		test/compiler/riscc_compiler_test.h $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_CFLAGS) \
	  -Itest/compiler -Ifirmware/include -c $< -o $@

$(RISCC_COMPILER_UART_OBJECT): test/compiler/smoke.c \
		test/compiler/riscc_compiler_test.h firmware/include/stdio.h $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_CFLAGS) \
	  -DRISCC_COMPILER_UART -Itest/compiler -Ifirmware/include -c $< -o $@

$(RISCC_COMPILER_ELF): $(RISCC_FIRMWARE_VECTORS) $(RISCC_FIRMWARE_CRT0) \
		$(RISCC_COMPILER_OBJECTS) $(RISCC_FIRMWARE_LIBRARIES) \
		firmware/unified.ld $(RISCC_CLANG) $(RISCC_LLD)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_LDFLAGS) -fuse-ld=lld -nostdlib \
	  -Wl,-T,$(abspath firmware/unified.ld) \
	  -Wl,-Map,$(@:.elf=.map) \
	  $(RISCC_FIRMWARE_VECTORS) $(RISCC_FIRMWARE_CRT0) \
	  $(RISCC_COMPILER_OBJECTS) $(RISCC_FIRMWARE_LIBRARIES) -o $@

$(RISCC_COMPILER_BIN): $(RISCC_COMPILER_ELF) $(RISCC_OBJCOPY)
	$(RISCC_OBJCOPY) -O binary $< $@

$(RISCC_COMPILER_MEMH): $(RISCC_COMPILER_BIN) tools/bin_to_memh.py
	$(PYTHON) tools/bin_to_memh.py $< -o $@

$(RISCC_COMPILER_UART_ELF): $(RISCC_FIRMWARE_VECTORS) $(RISCC_FIRMWARE_CRT0) \
		$(RISCC_COMPILER_UART_OBJECT) $(RISCC_COMPILER_BUILD)/helper.o \
		$(RISCC_FIRMWARE_LIBRARIES) firmware/unified.ld $(RISCC_CLANG) $(RISCC_LLD)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_LDFLAGS) -fuse-ld=lld -nostdlib \
	  -Wl,-T,$(abspath firmware/unified.ld) \
	  $(RISCC_FIRMWARE_VECTORS) $(RISCC_FIRMWARE_CRT0) \
	  $(RISCC_COMPILER_UART_OBJECT) $(RISCC_COMPILER_BUILD)/helper.o \
	  $(RISCC_FIRMWARE_LIBRARIES) -o $@

$(RISCC_COMPILER_UART_BIN): $(RISCC_COMPILER_UART_ELF) $(RISCC_OBJCOPY)
	$(RISCC_OBJCOPY) -O binary $< $@

$(RISCC_COMPILER_UART_MEMH): $(RISCC_COMPILER_UART_BIN) tools/bin_to_memh.py
	$(PYTHON) tools/bin_to_memh.py $< -o $@ --depth 16384

$(RISCC_COMPILER_STDIO_OBJECT): test/compiler/stdio_smoke.c \
		firmware/include/stdio.h $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_CFLAGS) \
	  -Ifirmware/include -c $< -o $@

$(RISCC_COMPILER_STDIO_ELF): $(RISCC_FIRMWARE_VECTORS) $(RISCC_FIRMWARE_CRT0) \
		$(RISCC_COMPILER_STDIO_OBJECT) $(RISCC_FIRMWARE_LIBRARIES) \
		firmware/unified.ld $(RISCC_CLANG) $(RISCC_LLD)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_LDFLAGS) -fuse-ld=lld -nostdlib \
	  -Wl,-T,$(abspath firmware/unified.ld) \
	  $(RISCC_FIRMWARE_VECTORS) $(RISCC_FIRMWARE_CRT0) \
	  $(RISCC_COMPILER_STDIO_OBJECT) $(RISCC_FIRMWARE_LIBRARIES) -o $@

$(RISCC_COMPILER_STDIO_BIN): $(RISCC_COMPILER_STDIO_ELF) $(RISCC_OBJCOPY)
	$(RISCC_OBJCOPY) -O binary $< $@

compiler-stdio-iss: $(RISCC_COMPILER_STDIO_BIN) $(RISCC_SIM)
	@mkdir -p $(RISCC_COMPILER_BUILD)
	@printf 'Q' | $(RISCC_SIM) $(RISCC_COMPILER_STDIO_BIN) --full --uart \
	  > $(RISCC_COMPILER_STDIO_UART_LOG)
	@test "$$(cat $(RISCC_COMPILER_STDIO_UART_LOG))" = 'Q'
	@echo "Compiler stdio UART PASS"

$(RISCC_COMPILER_BUILD)/irq_smoke.o: test/compiler/irq_smoke.c \
		firmware/include/riscc/interrupt.h $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_CFLAGS) \
	  -Ifirmware/include -c $< -o $@

$(RISCC_COMPILER_BUILD)/irq_smoke_main.o: test/compiler/irq_smoke_main.S $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_ASFLAGS) -c $< -o $@

$(RISCC_COMPILER_IRQ_CUSTOM_OBJECT): test/compiler/irq_custom_vector.S $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_ASFLAGS) -c $< -o $@

$(RISCC_COMPILER_IRQ_ELF): $(RISCC_FIRMWARE_VECTORS) $(RISCC_FIRMWARE_CRT0) \
		$(RISCC_COMPILER_IRQ_OBJECTS) \
		$(RISCC_FIRMWARE_LIBRARIES) firmware/unified.ld $(RISCC_CLANG) $(RISCC_LLD)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_LDFLAGS) -fuse-ld=lld -nostdlib \
	  -Wl,-T,$(abspath firmware/unified.ld) \
	  -Wl,-Map,$(RISCC_COMPILER_IRQ_MAP) \
	  $(RISCC_FIRMWARE_VECTORS) $(RISCC_FIRMWARE_CRT0) \
	  $(RISCC_COMPILER_IRQ_OBJECTS) $(RISCC_FIRMWARE_LIBRARIES) -o $@

$(RISCC_COMPILER_IRQ_BIN): $(RISCC_COMPILER_IRQ_ELF) $(RISCC_OBJCOPY)
	$(RISCC_OBJCOPY) -O binary $< $@

compiler-irq-iss: $(RISCC_COMPILER_IRQ_BIN) $(RISCC_SIM)
	$(RISCC_SIM) $< --full --max-insns $(RISCC_COMPILER_MAX_INSNS)

compiler-irq-tiny16: $(call tiny_tb,16,full) $(RISCC_COMPILER_IRQ_BIN)
	$< $(RISCC_COMPILER_IRQ_BIN) --max-cycles 10000000

compiler-irq-fast: $(call fast_tb,) $(RISCC_COMPILER_IRQ_BIN)
	$< $(RISCC_COMPILER_IRQ_BIN) --max-cycles 1000000

$(RISCC_COMPILER_IRQ_CUSTOM_ELF): $(RISCC_FIRMWARE_VECTORS) \
		$(RISCC_FIRMWARE_CRT0) $(RISCC_COMPILER_IRQ_CUSTOM_OBJECT) \
		$(RISCC_FIRMWARE_LIBRARIES) firmware/unified.ld $(RISCC_CLANG) $(RISCC_LLD)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_LDFLAGS) -fuse-ld=lld -nostdlib \
	  -Wl,-T,$(abspath firmware/unified.ld) \
	  -Wl,-Map,$(RISCC_COMPILER_IRQ_CUSTOM_MAP) \
	  $(RISCC_FIRMWARE_VECTORS) $(RISCC_FIRMWARE_CRT0) \
	  $(RISCC_COMPILER_IRQ_CUSTOM_OBJECT) $(RISCC_FIRMWARE_LIBRARIES) -o $@

$(RISCC_COMPILER_IRQ_CUSTOM_BIN): $(RISCC_COMPILER_IRQ_CUSTOM_ELF) $(RISCC_OBJCOPY)
	$(RISCC_OBJCOPY) -O binary $< $@

compiler-irq-custom-iss: $(RISCC_COMPILER_IRQ_CUSTOM_BIN) $(RISCC_SIM)
	$(RISCC_SIM) $< --full --max-insns $(RISCC_COMPILER_MAX_INSNS)

compiler-irq-custom-tiny16: $(call tiny_tb,16,full) $(RISCC_COMPILER_IRQ_CUSTOM_BIN)
	$< $(RISCC_COMPILER_IRQ_CUSTOM_BIN) --max-cycles 10000000

compiler-irq-custom-fast: $(call fast_tb,) $(RISCC_COMPILER_IRQ_CUSTOM_BIN)
	$< $(RISCC_COMPILER_IRQ_CUSTOM_BIN) --max-cycles 1000000

compiler-irq-linkage: $(RISCC_COMPILER_ELF) $(RISCC_COMPILER_IRQ_ELF) \
		$(RISCC_COMPILER_IRQ_CUSTOM_ELF) test/compiler/check_irq_linkage.py
	$(PYTHON) test/compiler/check_irq_linkage.py \
	  --normal $(RISCC_COMPILER_BUILD)/smoke.map \
	  --c-wrapper $(RISCC_COMPILER_IRQ_MAP) \
	  --custom $(RISCC_COMPILER_IRQ_CUSTOM_MAP)

compiler-smoke: compiler-smoke-icepi
compiler-smoke-unified: $(RISCC_COMPILER_MEMH)

compiler-smoke-iss: $(RISCC_COMPILER_BIN) $(RISCC_COMPILER_MEMH) $(RISCC_SIM)
	$(RISCC_SIM) $(RISCC_COMPILER_BIN) --full \
	  --max-insns $(RISCC_COMPILER_MAX_INSNS)

$(RISCC_COMPILER_SPLIT_ELF): $(RISCC_FIRMWARE_VECTORS) $(RISCC_FIRMWARE_CRT0) \
		$(RISCC_COMPILER_OBJECTS) $(RISCC_FIRMWARE_LIBRARIES) \
		firmware/split.ld $(RISCC_CLANG) $(RISCC_LLD)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_LDFLAGS) -fuse-ld=lld -nostdlib \
	  -Wl,-T,$(abspath firmware/split.ld) \
	  -Wl,-Map,$(@:.elf=.map) \
	  $(RISCC_FIRMWARE_VECTORS) $(RISCC_FIRMWARE_CRT0) \
	  $(RISCC_COMPILER_OBJECTS) $(RISCC_FIRMWARE_LIBRARIES) -o $@

$(RISCC_COMPILER_CODE_BIN): $(RISCC_COMPILER_SPLIT_ELF) $(RISCC_OBJCOPY)
	$(RISCC_OBJCOPY) -O binary --only-section=.vectors \
	  --only-section='.text*' $< $@

$(RISCC_COMPILER_DATA_BIN): $(RISCC_COMPILER_SPLIT_ELF) $(RISCC_OBJCOPY)
	$(RISCC_OBJCOPY) -O binary --only-section='.rodata*' \
	  --only-section='.data*' --only-section='.tdata*' $< $@

compiler-smoke-split: $(RISCC_COMPILER_SPLIT_ELF) \
	$(RISCC_COMPILER_CODE_BIN) $(RISCC_COMPILER_DATA_BIN) \
	test/compiler/check_tls_split_image.py
	$(PYTHON) test/compiler/check_tls_split_image.py \
	  --llvm-objcopy $(RISCC_OBJCOPY) --elf $(RISCC_COMPILER_SPLIT_ELF) \
	  --data-bin $(RISCC_COMPILER_DATA_BIN)

compiler-smoke-tiny16: $(call tiny_tb,16,full) $(RISCC_COMPILER_BIN)
	$< $(RISCC_COMPILER_BIN) --max-cycles 10000000

compiler-smoke-fast: $(call fast_tb,) $(RISCC_COMPILER_BIN)
	$< $(RISCC_COMPILER_BIN) --max-cycles 1000000


$(RISCC_COMPILER_ICEPI_RTLSIM): $(RISCC_COMPILER_UART_MEMH) $(ICEPI_SIM_RTL) \
		test/compiler/icepi_compiler_tb.cpp Makefile
	@mkdir -p $(@D)
	$(VERILATOR) -cc --exe --build $(VERILATOR_MAKEFLAGS_ARG) \
	  --top-module icepi_zero_soc_sim --prefix Vicepi_zero_soc_sim \
	  -Mdir $(@D) $(ICEPI_CPU_DEFS) -I$(abspath rtl) -I$(abspath $(ICEPI_DIR)/vendor/dvi) \
	  -GMEM_HEX='"$(abspath $(RISCC_COMPILER_UART_MEMH))"' \
	  -CFLAGS "$(TB_CXXFLAGS)" -o Vicepi_zero_soc_sim \
	  $(abspath $(ICEPI_SIM_RTL)) $(abspath test/compiler/icepi_compiler_tb.cpp)

compiler-smoke-icepi: $(RISCC_COMPILER_ICEPI_RTLSIM)
	$(RISCC_COMPILER_ICEPI_RTLSIM)

$(RISCC_COMPILER_ATUM_RTLSIM): $(RISCC_COMPILER_UART_MEMH) \
		$(ATUM_SIM_RTL) test/compiler/atum_uart_tb.cpp Makefile
	@mkdir -p $(@D)
	$(VERILATOR) -cc --exe --build $(VERILATOR_MAKEFLAGS_ARG) \
	  --top-module atum_a3_nano_soc_sim --prefix Vatum_a3_nano_soc_sim \
	  -Mdir $(@D) -I$(abspath rtl) \
	  -GMEM_HEX='"$(abspath $(RISCC_COMPILER_UART_MEMH))"' \
	  -CFLAGS "$(TB_CXXFLAGS)" -o Vatum_a3_nano_soc_sim \
	  $(abspath $(ATUM_SIM_RTL)) $(abspath test/compiler/atum_uart_tb.cpp)

compiler-smoke-atum: $(RISCC_COMPILER_ATUM_RTLSIM)
	$(RISCC_COMPILER_ATUM_RTLSIM)

# Compile and execute the same multi-file program at every optimization level
# promised by the initial backend validation profile.  Startup and support
# libraries remain separately compiled, as they would in a real sysroot.
riscc_opt_flag = $(if $(filter o0,$(1)),-O0,$(if $(filter o2,$(1)),-O2,-Os))
RISCC_CFLAGS_NO_OPT := $(filter-out -O%,$(RISCC_CFLAGS))

.PRECIOUS: $(RISCC_COMPILER_BUILD)/matrix/%/smoke.o \
	$(RISCC_COMPILER_BUILD)/matrix/%/helper.o \
	$(RISCC_COMPILER_BUILD)/matrix/%/smoke.elf

$(RISCC_COMPILER_BUILD)/matrix/%/smoke.o: test/compiler/smoke.c \
		test/compiler/riscc_compiler_test.h $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_CFLAGS_NO_OPT) \
	  $(call riscc_opt_flag,$*) -Itest/compiler -Ifirmware/include -c $< -o $@

$(RISCC_COMPILER_BUILD)/matrix/%/helper.o: test/compiler/helper.c \
		test/compiler/riscc_compiler_test.h $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_CFLAGS_NO_OPT) \
	  $(call riscc_opt_flag,$*) -Itest/compiler -Ifirmware/include -c $< -o $@

$(RISCC_COMPILER_BUILD)/matrix/%/smoke.elf: $(RISCC_FIRMWARE_VECTORS) \
		$(RISCC_FIRMWARE_CRT0) \
		$(RISCC_COMPILER_BUILD)/matrix/%/smoke.o \
		$(RISCC_COMPILER_BUILD)/matrix/%/helper.o \
		$(RISCC_FIRMWARE_LIBRARIES) firmware/unified.ld $(RISCC_CLANG) $(RISCC_LLD)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_LDFLAGS) -fuse-ld=lld -nostdlib \
	  -Wl,-T,$(abspath firmware/unified.ld) \
	  $(RISCC_FIRMWARE_VECTORS) $(RISCC_FIRMWARE_CRT0) \
	  $(RISCC_COMPILER_BUILD)/matrix/$*/smoke.o \
	  $(RISCC_COMPILER_BUILD)/matrix/$*/helper.o \
	  $(RISCC_FIRMWARE_LIBRARIES) -o $@

$(RISCC_COMPILER_BUILD)/matrix/%/smoke.bin: \
		$(RISCC_COMPILER_BUILD)/matrix/%/smoke.elf $(RISCC_OBJCOPY)
	$(RISCC_OBJCOPY) -O binary $< $@

compiler-smoke-opt-o0: $(RISCC_COMPILER_BUILD)/matrix/o0/smoke.bin $(RISCC_SIM)
	$(RISCC_SIM) $< --full --max-insns $(RISCC_COMPILER_MAX_INSNS)

compiler-smoke-opt-o2: $(RISCC_COMPILER_BUILD)/matrix/o2/smoke.bin $(RISCC_SIM)
	$(RISCC_SIM) $< --full --max-insns $(RISCC_COMPILER_MAX_INSNS)

compiler-smoke-opt-os: $(RISCC_COMPILER_BUILD)/matrix/os/smoke.bin $(RISCC_SIM)
	$(RISCC_SIM) $< --full --max-insns $(RISCC_COMPILER_MAX_INSNS)

compiler-smoke-opt-matrix: compiler-smoke-opt-o0 compiler-smoke-opt-o2 \
	compiler-smoke-opt-os

# Execute a broader, multi-file C11 and ABI feature suite at every supported
# optimization level.  The assembly helper is an independent oracle for the
# callee-saved GPR contract; all feature decisions and checks remain in C.
$(RISCC_COMPILER_FEATURE_ASM_OBJECT): test/compiler/feature_abi_asm.S \
		$(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_ASFLAGS) -c $< -o $@

define riscc_compiler_feature_rules
RISCC_COMPILER_FEATURE_OBJECTS_$(1) := $$(addprefix \
	$$(RISCC_COMPILER_BUILD)/features/$(1)/, \
	$$(addsuffix .o,$$(RISCC_COMPILER_FEATURE_MODULES)))

$$(RISCC_COMPILER_FEATURE_OBJECTS_$(1)): \
		$$(RISCC_COMPILER_BUILD)/features/$(1)/%.o: test/compiler/%.c \
		test/compiler/riscc_compiler_features.h $$(RISCC_CLANG)
	@mkdir -p $$(@D)
	$$(RISCC_CLANG) $$(RISCC_TARGET_FLAGS) $$(RISCC_CFLAGS_NO_OPT) \
	  $$(call riscc_opt_flag,$(1)) -std=c11 -Itest/compiler \
	  -Ifirmware/include -c $$< -o $$@

$$(RISCC_COMPILER_BUILD)/features/$(1)/features.elf: \
		$$(RISCC_FIRMWARE_VECTORS) $$(RISCC_FIRMWARE_CRT0) \
		$$(RISCC_COMPILER_FEATURE_OBJECTS_$(1)) \
		$$(RISCC_COMPILER_FEATURE_ASM_OBJECT) $$(RISCC_FIRMWARE_LIBRARIES) \
		firmware/unified.ld $$(RISCC_CLANG) $$(RISCC_LLD)
	@mkdir -p $$(@D)
	$$(RISCC_CLANG) $$(RISCC_TARGET_FLAGS) $$(RISCC_LDFLAGS) \
	  -fuse-ld=lld -nostdlib -Wl,-T,$$(abspath firmware/unified.ld) \
	  $$(RISCC_FIRMWARE_VECTORS) $$(RISCC_FIRMWARE_CRT0) \
	  $$(RISCC_COMPILER_FEATURE_OBJECTS_$(1)) \
	  $$(RISCC_COMPILER_FEATURE_ASM_OBJECT) $$(RISCC_FIRMWARE_LIBRARIES) -o $$@

$$(RISCC_COMPILER_BUILD)/features/$(1)/features.bin: \
		$$(RISCC_COMPILER_BUILD)/features/$(1)/features.elf $$(RISCC_OBJCOPY)
	$$(RISCC_OBJCOPY) -O binary $$< $$@

compiler-features-$(1)-iss: \
		$$(RISCC_COMPILER_BUILD)/features/$(1)/features.bin $$(RISCC_SIM)
	$$(RISCC_SIM) $$< --full --max-insns $$(RISCC_COMPILER_MAX_INSNS)
endef

$(foreach opt,o0 o2 os,$(eval $(call riscc_compiler_feature_rules,$(opt))))

compiler-features-iss: compiler-features-o0-iss compiler-features-o2-iss \
	compiler-features-os-iss

check-llvm-mc-encodings: test/compiler/check_llvm_mc_encodings.py \
		tools/riscc_asm.py $(RISCC_MC) $(RISCC_OBJCOPY)
	$(PYTHON) $< --llvm-mc $(LLVM_RISCC_BIN)/llvm-mc \
	  --llvm-objcopy $(LLVM_RISCC_BIN)/llvm-objcopy

test-compiler: compiler-smoke-iss compiler-smoke-split \
	compiler-smoke-tiny16 compiler-smoke-fast compiler-smoke-icepi compiler-smoke-atum \
	compiler-smoke-opt-matrix compiler-features-iss \
	compiler-stdio-iss compiler-irq-iss compiler-irq-tiny16 \
	compiler-irq-fast compiler-irq-custom-iss compiler-irq-custom-tiny16 \
	compiler-irq-custom-fast compiler-irq-linkage check-llvm-mc-encodings

RTL_RULES := Makefile mk/rtl.mk

.PHONY: all version check-version FORCE test test-all

all: test-all bench

FORCE:

version:
	@printf '%s\n' '$(RISCC_VERSION)'

check-version:
	@test "$$(sed -n 's/^Version: `\([^`]*\)`\.$$/\1/p' doc/RISC-C-ISA.md)" = "$(RISCC_VERSION)"

test: test-core
test-all: test-cores test-extensions test-nano test-rc32 \
	test-fast-all test-faster test-peripherals test-funnel

$(PERIPHERAL_TB): test/peripheral_tb.cpp $(PERIPHERAL_RTL)
	@mkdir -p $(@D)
	+$(VERILATOR) -cc --exe --build $(VERILATOR_MAKEFLAGS_ARG) \
	  --top-module riscc_peripherals_top --prefix Vriscc_peripherals_top \
	  -GTICK_DIV=4 -Mdir $(@D) -CFLAGS "$(TB_CXXFLAGS)" -o tb \
	  $(abspath $(PERIPHERAL_RTL)) $(abspath test/peripheral_tb.cpp)

.PHONY: test-peripherals
test-peripherals: $(PERIPHERAL_TB)
	$<

# Assembler and ISS

.PHONY: asm sim sim-all sim-fast sim-cpp
asm: $(foreach profile,$(PROFILES),build/bin/$(profile).bin) \
	$(BENCH_BIN) $(NANO_BENCH_BIN) $(FUNNEL_BIN) $(RC32_SYS_BIN) \
	$(foreach extension,$(EXTENSIONS),build/bin/full-$(extension).bin)

sim-cpp: $(RISCC_SIM)

$(RISCC_SIM): tools/riscc_sim.cpp VERSION
	@mkdir -p $(@D)
	$(CCACHE) $(CXX) $(RISCC_SIM_CXXFLAGS) $(SDL2_CFLAGS) $(STB_CFLAGS) \
	  $< -o $@ $(SDL2_LIBS) $(STB_LIBS)

# ASSEMBLE_IMAGE(source, cpu, attributes, definitions, linker_script)
define ASSEMBLE_IMAGE
	@mkdir -p $(@D)
	$(RISCC_MC) -triple=riscc-none-elf -mcpu=$(2) $(3) \
	  $(foreach d,$(4),--defsym=$(d)=1) -filetype=obj $(1) -o $@.o
	$(RISCC_LLD) -T $(abspath $(5)) -o $@.elf $@.o
	$(RISCC_OBJCOPY) -O binary $@.elf $@
endef

build/bin/%.bin: test/test_riscc.asm test/flat.ld
	$(call ASSEMBLE_IMAGE,test/test_riscc.asm,$*,,$(ASM_DEFINES_$*),test/flat.ld)

EXTENSION_FLAGS_mulh := --mattr=+mulhu
EXTENSION_FLAGS_muldiv := --mattr=+mdu
EXTENSION_ASM_DEFINES_mulh := RISCC_MULHU
EXTENSION_ASM_DEFINES_muldiv := RISCC_MDU RISCC_MULHU RISCC_DIVU

build/bin/full-%.bin: test/test_mdu.asm test/flat.ld
	$(call ASSEMBLE_IMAGE,test/test_mdu.asm,full,$(EXTENSION_FLAGS_$*), \
	  $(ASM_DEFINES_full) $(EXTENSION_ASM_DEFINES_$*),test/flat.ld)

$(FUNNEL_BIN): test/test_funnel.asm test/flat.ld
	$(call ASSEMBLE_IMAGE,test/test_funnel.asm,min,,$(ASM_DEFINES_min),test/flat.ld)

$(RC32_SYS_BIN): test/test_rc32_sys.asm test/flat.ld
	$(call ASSEMBLE_IMAGE,test/test_rc32_sys.asm,sys,--mattr=+rc32, \
	  $(ASM_DEFINES_sys),test/flat.ld)

$(BENCH_BIN): test/test_riscc_bench.asm test/flat.ld
	$(call ASSEMBLE_IMAGE,test/test_riscc_bench.asm,full,, \
	  $(ASM_DEFINES_full),test/flat.ld)

$(NANO_BENCH_BIN): test/test_riscc_bench.asm test/flat.ld
	$(call ASSEMBLE_IMAGE,test/test_riscc_bench.asm,nano,, \
	  $(ASM_DEFINES_nano),test/flat.ld)

sim: build/bin/$(PROFILE).bin $(RISCC_SIM)
	$(RISCC_SIM) $< $(SIM_FLAGS_$(PROFILE))

sim-all: $(foreach profile,$(PROFILES),build/bin/$(profile).bin) \
	$(BENCH_BIN) $(RISCC_SIM)
	@$(foreach profile,$(PROFILES),$(RISCC_SIM) build/bin/$(profile).bin \
	  $(SIM_FLAGS_$(profile)) || exit;)
	$(RISCC_SIM) $(BENCH_BIN) --full

FAST_SIM_FLAGS_soft := --fast
FAST_SIM_FLAGS_dsp := --fast-dsp
sim-fast: build/bin/full.bin $(RISCC_SIM)
	$(RISCC_SIM) $< $(FAST_SIM_FLAGS_$(MULTIPLIER))

FUZZ_SEEDS ?= 100
FUZZ_SEED_ARGS ?= --random-seed
FUZZ_CORES ?= $(foreach width,$(WIDTHS),rc16-$(width))
FUZZ_CORE_ARG = $(call join_with_commas,$(FUZZ_CORES))
RC32_FUZZ_CORES ?= $(foreach width,$(WIDTHS),rc32-$(width))
RC32_FUZZ_CORE_ARG = $(call join_with_commas,$(RC32_FUZZ_CORES))

.PHONY: fuzz fuzz-all fuzz-rc32 fuzz-fast test-rc32
fuzz: $(RISCC_SIM)
	@for profile in $(RC16_PROFILES); do \
	  RISCC_SIM=$(abspath $(RISCC_SIM)) $(PYTHON) tools/riscc_fuzz.py \
	    --campaign $(FUZZ_SEEDS) $(FUZZ_SEED_ARGS) --config $$profile \
	    --cores $(FUZZ_CORE_ARG) --outdir build/fuzz/rc16 || exit; \
	done
	RISCC_SIM=$(abspath $(RISCC_SIM)) $(PYTHON) tools/riscc_fuzz.py \
	  --family nano --campaign $(FUZZ_SEEDS) $(FUZZ_SEED_ARGS) \
	  --config nano --outdir build/fuzz/nano

fuzz-all: fuzz fuzz-rc32 fuzz-fast

# llvm-riscc is declared later, after its binary paths are configured.  Use
# the aggregate prerequisite here so this early fuzz rule still builds all
# three LLVM tools it invokes.
fuzz-rc32: $(RISCC_SIM) llvm-riscc
	@for profile in $(RC32_PROFILES); do \
	  RISCC_SIM=$(abspath $(RISCC_SIM)) RISCC_LLVM_BIN=$(abspath $(LLVM_BIN)) \
	    $(PYTHON) tools/riscc_fuzz.py --family rc32 --campaign $(FUZZ_SEEDS) \
	    $(FUZZ_SEED_ARGS) --config $$profile --cores $(RC32_FUZZ_CORE_ARG) \
	    --outdir build/fuzz/rc32 || exit; \
	done

# Keep one deterministic differential RC32 program in the normal regression
# gate.  The longer random campaign remains available through fuzz-rc32.
test-rc32: $(RISCC_SIM) llvm-riscc \
	$(foreach width,$(WIDTHS),build/test/rc32/sys/$(width).ok)
	RISCC_SIM=$(abspath $(RISCC_SIM)) RISCC_LLVM_BIN=$(abspath $(LLVM_BIN)) \
	  $(PYTHON) tools/riscc_fuzz.py --family rc32 --campaign 1 --base-seed 1 \
	  --config min --cores $(RC32_FUZZ_CORE_ARG) --outdir build/test/rc32

# RC32_SYS_TEST(width)
define RC32_SYS_TEST
build/test/rc32/sys/$(1)/tb: $(TB_SRC) rtl/riscc32_sys.v $(RISCC_RF_RTL) $(RTL_RULES)
	@mkdir -p $$(@D)
	+$$(VERILATOR) -cc --exe --build $$(VERILATOR_MAKEFLAGS_ARG) --top-module riscc32_sys \
	  -GW=$(1) -DRISCC_INFERRED_SYNC_RF --prefix Vriscc -Mdir $$(@D) \
	  -I$$(abspath rtl) -I$$(abspath rtl/test) \
	  -CFLAGS "$$(TB_CXXFLAGS) -DRISCC_TB_RC32" -o tb \
	  $$(abspath rtl/riscc32_sys.v) $$(abspath $(TB_SRC))

build/test/rc32/sys/$(1).ok: build/test/rc32/sys/$(1)/tb $$(RC32_SYS_BIN) FORCE
	@mkdir -p $$(@D)
	$$< $$(RC32_SYS_BIN) --irq-at 300 --max-cycles 100000
	@touch $$@
endef

$(foreach width,$(WIDTHS),$(eval $(call RC32_SYS_TEST,$(width))))

fuzz-fast: $(RISCC_SIM)
	RISCC_SIM=$(abspath $(RISCC_SIM)) $(PYTHON) tools/riscc_fuzz.py \
	  --family fast --campaign $(FUZZ_SEEDS) $(FUZZ_SEED_ARGS) --config full \
	  --outdir build/fuzz/fast
	RISCC_SIM=$(abspath $(RISCC_SIM)) $(PYTHON) tools/riscc_fuzz.py \
	  --family fast --campaign $(FUZZ_SEEDS) $(FUZZ_SEED_ARGS) --config full \
	  --cores fast-ice,fast-ice-dsp --outdir build/fuzz/fast-ice

# Architectural traces

.PHONY: trace trace-fast trace-nano
TRACE_CXXFLAGS = $(TB_CXXFLAGS) -DRISCC_TB_TRACE

TRACE_TB := build/trace/rc16/$(PROFILE)/$(WIDTH)/tb
FAST_TRACE_TB := build/trace/fast/$(MEMORY)/$(MULTIPLIER)/tb

$(TRACE_TB): $(TB_SRC) $(call rc16_source,$(WIDTH),$(PROFILE)) $(TRACE_RTL) $(RISCC_RF_RTL)
	@mkdir -p $(@D)
	+$(VERILATOR) -cc --exe --build $(VERILATOR_MAKEFLAGS_ARG) \
	  --top-module $(call rc16_top,$(WIDTH),$(PROFILE)) \
	  $(call rc16_verilator_width,$(WIDTH)) --prefix Vriscc -Mdir $(@D) \
	  -I$(abspath rtl) -I$(abspath rtl/test) -DRISCC_TRACE \
	  -CFLAGS "$(TRACE_CXXFLAGS)" -o tb \
	  $(abspath $(call rc16_source,$(WIDTH),$(PROFILE))) $(abspath $(TB_SRC))

trace: $(TRACE_TB) build/bin/$(PROFILE).bin
	$< build/bin/$(PROFILE).bin --trace --max-cycles 10000000

build/trace/nano/tb: $(TB_SRC) rtl/riscc_nano.v $(TRACE_RTL) $(RISCC_RF_RTL)
	@mkdir -p $(@D)
	+$(VERILATOR) -cc --exe --build $(VERILATOR_MAKEFLAGS_ARG) --top-module riscc_nano \
	  --prefix Vriscc -Mdir $(@D) -I$(abspath rtl) -I$(abspath rtl/test) -DRISCC_TRACE \
	  -CFLAGS "$(TRACE_CXXFLAGS)" -o tb \
	  $(abspath rtl/riscc_nano.v) $(abspath $(TB_SRC))

trace-nano: build/trace/nano/tb build/bin/nano.bin
	$< build/bin/nano.bin --trace --max-cycles 200000

$(FAST_TRACE_TB): $(TB_SRC) rtl/riscc16_fast.v $(TRACE_RTL)
	@mkdir -p $(@D)
	+$(VERILATOR) -cc --exe --build $(VERILATOR_MAKEFLAGS_ARG) \
	  --top-module riscc16_fast --prefix Vriscc -Mdir $(@D) \
	  -I$(abspath rtl) -I$(abspath rtl/test) -DRISCC_TRACE \
	  $(call fast_defines,$(MEMORY),$(MULTIPLIER)) \
	  -CFLAGS "$(TRACE_CXXFLAGS) -DRISCC_TB_TRACE_DRAIN=1" -o tb \
	  $(abspath rtl/riscc16_fast.v) $(abspath $(TB_SRC))

trace-fast: $(FAST_TRACE_TB) build/bin/full.bin
	$< build/bin/full.bin --trace --max-cycles 1000000

# Verilator tests

.PHONY: test-core test-cores test-extension test-extensions test-funnel \
	test-nano test-fast test-fast-all test-faster

# RC16_TEST(mode, profile, width)
define RC16_TEST
build/test/rc16/$(1)/$(2)/$(3)/tb: $(TB_SRC) \
		$(call rc16_source,$(3),$(2)) $(RISCC_RF_RTL) $(RTL_RULES)
	@mkdir -p $$(@D)
	+$$(VERILATOR) -cc --exe --build $$(VERILATOR_MAKEFLAGS_ARG) \
	  --top-module $(call rc16_top,$(3),$(2)) $(call rc16_verilator_width,$(3)) \
	  --prefix Vriscc -Mdir $$(@D) $$(RF_DEFINES_$(1)) \
	  -CFLAGS "$$(TB_CXXFLAGS)" -o tb \
	  $$(abspath $(call rc16_source,$(3),$(2))) $$(abspath $(TB_SRC))

build/test/rc16/$(1)/$(2)/$(3).ok: build/test/rc16/$(1)/$(2)/$(3)/tb \
		build/bin/$(2).bin FORCE
	@mkdir -p $$(@D)
	$$< build/bin/$(2).bin --max-cycles 10000000
	@touch $$@
endef

$(foreach mode,$(TEST_MODES),$(foreach profile,$(RC16_PROFILES),$(foreach width,$(WIDTHS), \
	$(eval $(call RC16_TEST,$(mode),$(profile),$(width))))))

test-core: build/test/rc16/$(MODE)/$(PROFILE)/$(WIDTH).ok
test-cores: $(foreach mode,$(TEST_MODES),$(foreach profile,$(RC16_PROFILES), \
	$(foreach width,$(WIDTHS),build/test/rc16/$(mode)/$(profile)/$(width).ok)))

# EXTENSION_TEST(mode, extension)
define EXTENSION_TEST
build/test/extension/$(1)/$(2)/tb: $(TB_SRC) rtl/riscc16_full_$(2).v $(RISCC_RF_RTL) $(RTL_RULES)
	@mkdir -p $$(@D)
	+$$(VERILATOR) -cc --exe --build $$(VERILATOR_MAKEFLAGS_ARG) --top-module riscc16 \
	  --prefix Vriscc -Mdir $$(@D) -I$$(abspath rtl) $$(RF_DEFINES_$(1)) \
	  -CFLAGS "$$(TB_CXXFLAGS)" -o tb \
	  $$(abspath rtl/riscc16_full_$(2).v) $$(abspath $(TB_SRC))

build/test/extension/$(1)/$(2).ok: build/test/extension/$(1)/$(2)/tb \
		build/bin/full.bin build/bin/full-$(2).bin $$(FUNNEL_BIN) FORCE
	@mkdir -p $$(@D)
	$$< build/bin/full.bin --max-cycles 10000000
	$$< build/bin/full-$(2).bin --max-cycles 10000000
	$$< $$(FUNNEL_BIN) --max-cycles 5000
	@touch $$@
endef

$(foreach mode,$(TEST_MODES),$(foreach extension,$(EXTENSIONS), \
	$(eval $(call EXTENSION_TEST,$(mode),$(extension)))))

test-extension: build/test/extension/$(MODE)/$(EXTENSION).ok
test-extensions: $(foreach mode,$(TEST_MODES),$(foreach extension,$(EXTENSIONS), \
	build/test/extension/$(mode)/$(extension).ok))

test-funnel: \
	$(foreach profile,$(RC16_PROFILES),$(foreach width,$(WIDTHS), \
	  build/test/rc16/native/$(profile)/$(width)/tb)) \
	$(foreach memory,async ice40,$(foreach multiplier,$(MULTIPLIERS), \
	  build/test/fast/$(memory)/$(multiplier)/tb)) \
	$(foreach multiplier,$(MULTIPLIERS),build/test/faster/$(multiplier)/tb) \
	$(FUNNEL_BIN) $(RISCC_SIM)
	@for profile in $(RC16_PROFILES); do \
	  for width in $(WIDTHS); do \
	    build/test/rc16/native/$$profile/$$width/tb \
	      $(FUNNEL_BIN) --max-cycles 5000 || exit; \
	  done; \
	done
	@for memory in async ice40; do for multiplier in $(MULTIPLIERS); do \
	  build/test/fast/$$memory/$$multiplier/tb \
	    $(FUNNEL_BIN) --max-cycles 5000 || exit; \
	done; done
	@for multiplier in $(MULTIPLIERS); do \
	  build/test/faster/$$multiplier/tb \
	    $(FUNNEL_BIN) --max-cycles 5000 || exit; \
	done
	@$(foreach profile,$(RC16_PROFILES),$(RISCC_SIM) $(FUNNEL_BIN) \
	  $(SIM_FLAGS_$(profile)) --max-insns 5000 || exit;)
	$(RISCC_SIM) $(FUNNEL_BIN) --faster --max-insns 5000
	@if $(RISCC_SIM) $(FUNNEL_BIN) --nano --max-insns 5000 >/dev/null 2>&1; then \
	  echo "C++ ISS accepted FSL1/FSR1 in Nano"; exit 1; \
	fi

build/test/nano/tb: $(TB_SRC) rtl/riscc_nano.v $(RISCC_RF_RTL)
	@mkdir -p $(@D)
	+$(VERILATOR) -cc --exe --build $(VERILATOR_MAKEFLAGS_ARG) --top-module riscc_nano \
	  --prefix Vriscc -Mdir $(@D) -CFLAGS "$(TB_CXXFLAGS)" -o tb \
	  $(abspath rtl/riscc_nano.v) $(abspath $(TB_SRC))

build/test/nano.ok: build/test/nano/tb build/bin/nano.bin FORCE
	$< build/bin/nano.bin --max-cycles 200000
	@touch $@

test-nano: build/test/nano.ok

# FAST_TEST(memory, multiplier)
define FAST_TEST
build/test/fast/$(1)/$(2)/tb: $(TB_SRC) rtl/riscc16_fast.v $(RTL_RULES)
	@mkdir -p $$(@D)
	+$$(VERILATOR) -cc --exe --build $$(VERILATOR_MAKEFLAGS_ARG) --top-module riscc16_fast \
	  --prefix Vriscc -Mdir $$(@D) -I$$(abspath rtl) $(call fast_defines,$(1),$(2)) \
	  -CFLAGS "$$(TB_CXXFLAGS)" -o tb \
	  $$(abspath rtl/riscc16_fast.v) $$(abspath $(TB_SRC))

build/test/fast/$(1)/$(2).ok: build/test/fast/$(1)/$(2)/tb build/bin/full.bin FORCE
	@mkdir -p $$(@D)
	$$< build/bin/full.bin --max-cycles 1000000
	@touch $$@
endef

$(foreach memory,$(FAST_MEMORIES),$(foreach multiplier,$(MULTIPLIERS), \
	$(eval $(call FAST_TEST,$(memory),$(multiplier)))))

test-fast: build/test/fast/$(MEMORY)/$(MULTIPLIER).ok
test-fast-all: $(foreach memory,$(FAST_MEMORIES),$(foreach multiplier,$(MULTIPLIERS), \
	build/test/fast/$(memory)/$(multiplier).ok))

FASTER_DEFINES_dsp :=
FASTER_DEFINES_soft := -DRISCC_FASTER_SOFT_MUL

# FASTER_TEST(multiplier)
define FASTER_TEST
build/test/faster/$(1)/tb: $(TB_SRC) rtl/riscc16_faster.v $(RTL_RULES)
	@mkdir -p $$(@D)
	+$$(VERILATOR) -cc --exe --build $$(VERILATOR_MAKEFLAGS_ARG) \
	  --top-module riscc16_faster --prefix Vriscc -Mdir $$(@D) \
	  $$(FASTER_DEFINES_$(1)) -CFLAGS "$$(TB_CXXFLAGS)" -o tb \
	  $$(abspath rtl/riscc16_faster.v) $$(abspath $(TB_SRC))

build/test/faster/$(1).ok: build/test/faster/$(1)/tb build/bin/full.bin FORCE
	@mkdir -p $$(@D)
	$$< build/bin/full.bin --max-cycles 1000000
	@touch $$@
endef

$(foreach multiplier,$(MULTIPLIERS),$(eval $(call FASTER_TEST,$(multiplier))))

test-faster: $(foreach multiplier,$(MULTIPLIERS),build/test/faster/$(multiplier).ok)

.PHONY: bench
bench: $(foreach width,$(WIDTHS),build/test/rc16/native/full/$(width)/tb) \
	build/test/nano/tb \
	$(foreach memory,async ice40,$(foreach multiplier,$(MULTIPLIERS), \
	  build/test/fast/$(memory)/$(multiplier)/tb)) \
	$(foreach multiplier,$(MULTIPLIERS),build/test/faster/$(multiplier)/tb) \
	$(BENCH_BIN) $(NANO_BENCH_BIN)
	@for width in $(WIDTHS); do \
	  tb=build/test/rc16/native/full/$$width/tb; \
	  out="$$($$tb $(BENCH_BIN) --max-cycles 800000 2>&1 | tail -1)"; \
	  printf 'rc16/%-3s %s\n' $$width "$$out"; \
	done
	@out="$$(build/test/nano/tb $(NANO_BENCH_BIN) \
	  --max-cycles 2000000 2>&1 | tail -1)"; printf '%-8s %s\n' nano "$$out"
	@for memory in async ice40; do for multiplier in $(MULTIPLIERS); do \
	  tb=build/test/fast/$$memory/$$multiplier/tb; \
	  out="$$($$tb $(BENCH_BIN) --max-cycles 800000 2>&1 | tail -1)"; \
	  printf 'fast/%s/%-4s %s\n' $$memory $$multiplier "$$out"; \
	done; done
	@for multiplier in $(MULTIPLIERS); do \
	  tb=build/test/faster/$$multiplier/tb; \
	  out="$$($$tb $(BENCH_BIN) --max-cycles 800000 2>&1 | tail -1)"; \
	  printf 'faster/%-4s %s\n' $$multiplier "$$out"; \
	done

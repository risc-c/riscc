RTL_RULES := Makefile mk/rtl.mk

.PHONY: all version check-version FORCE test test-rtl test-all

all: test-all
	+$(MAKE) --no-print-directory bench

FORCE:

version:
	@printf '%s\n' '$(RISCC_VERSION)'

check-version:
	@test "$$(sed -n 's/^Version: `\([^`]*\)`\.$$/\1/p' doc/RISC-C-ISA.md)" = "$(RISCC_VERSION)"

test: test-core
test-rtl: test-cores test-extensions test-nano test-rc32 \
	test-applications \
	test-fast-all test-faster test-peripherals test-funnel test-high-address

# Run the three gates in order because they share the LLVM, firmware, and RTL
# output trees. Each recursive make inherits the GNU Make jobserver, so every
# gate still uses the caller's full -j parallelism internally.
test-all: check-llvm-riscc
	+$(MAKE) --no-print-directory test-isa
	+$(MAKE) --no-print-directory test-compiler

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

$(ISA_IRQ_BIN): test/test_isa_irq.asm test/flat.ld
	$(call ASSEMBLE_IMAGE,test/test_isa_irq.asm,full,, \
	  $(ASM_DEFINES_full),test/flat.ld)

$(ISA_IRQ_MDU_BIN): test/test_isa_irq.asm test/flat.ld
	$(call ASSEMBLE_IMAGE,test/test_isa_irq.asm,full,$(EXTENSION_FLAGS_muldiv), \
	  $(ASM_DEFINES_full) $(EXTENSION_ASM_DEFINES_muldiv),test/flat.ld)

$(RC32_ISA_IRQ_BIN): test/test_rc32_isa_irq.asm test/flat.ld
	$(call ASSEMBLE_IMAGE,test/test_rc32_isa_irq.asm,sys,--mattr=+rc32, \
	  $(ASM_DEFINES_sys),test/flat.ld)

$(RC32_FULL_ISA_IRQ_BIN): test/test_rc32_isa_irq.asm test/flat.ld
	$(call ASSEMBLE_IMAGE,test/test_rc32_isa_irq.asm,full,--mattr=+rc32, \
	  $(ASM_DEFINES_full),test/flat.ld)

$(RC32_MDU_BIN): test/test_rc32_mdu.asm test/flat.ld
	$(call ASSEMBLE_IMAGE,test/test_rc32_mdu.asm,full,--mattr=+rc32$(comma)+mdu, \
	  $(ASM_DEFINES_full) $(EXTENSION_ASM_DEFINES_muldiv),test/flat.ld)

$(RC32_MIN_TRACE_BIN): test/test_rc32_min_trace.asm test/flat.ld
	$(call ASSEMBLE_IMAGE,test/test_rc32_min_trace.asm,min,--mattr=+rc32, \
	  $(ASM_DEFINES_min),test/flat.ld)

$(RC32_SYS_BIN): test/test_rc32_sys.asm test/flat.ld
	$(call ASSEMBLE_IMAGE,test/test_rc32_sys.asm,sys,--mattr=+rc32, \
	  $(ASM_DEFINES_sys),test/flat.ld)

$(RC32_SYS_ISS_BIN): test/test_rc32_sys.asm test/flat.ld \
		$(RISCC_MC) $(RISCC_LLD) $(RISCC_OBJCOPY)
	$(call ASSEMBLE_IMAGE,test/test_rc32_sys.asm,sys,--mattr=+rc32, \
	  $(ASM_DEFINES_sys) RISCC_ISS,test/flat.ld)

$(BENCH_BIN): test/test_riscc_bench.asm test/flat.ld
	$(call ASSEMBLE_IMAGE,test/test_riscc_bench.asm,full,, \
	  $(ASM_DEFINES_full),test/flat.ld)

$(NANO_BENCH_BIN): test/test_riscc_bench.asm test/flat.ld
	$(call ASSEMBLE_IMAGE,test/test_riscc_bench.asm,nano,, \
	  $(ASM_DEFINES_nano),test/flat.ld)

$(HIGH_ADDRESS_BIN): test/linker/rc16/high_address.asm \
		test/linker/rc16/high_address.ld
	$(call ASSEMBLE_IMAGE,test/linker/rc16/high_address.asm,full,,,test/linker/rc16/high_address.ld)

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

FUZZ_SEEDS ?= 300
FUZZ_SEED_ARGS ?= --random-seed
FUZZ_JOBS ?= $(shell nproc)
FUZZ_CORES ?= $(foreach width,$(WIDTHS),rc16-$(width))
FUZZ_CORE_ARG = $(call join_with_commas,$(FUZZ_CORES))
RC32_FUZZ_CORES ?= $(foreach width,$(WIDTHS),rc32-$(width))
RC32_FUZZ_CORE_ARG = $(call join_with_commas,$(RC32_FUZZ_CORES))

.PHONY: fuzz fuzz-all fuzz-rc32 fuzz-fast fuzz-faster test-rc32 \
	test-applications test-rc16-application test-nano-application \
	test-rc32-application
fuzz: $(RISCC_SIM)
	@for profile in $(RC16_PROFILES); do \
	  RISCC_SIM=$(abspath $(RISCC_SIM)) $(PYTHON) tools/riscc_fuzz.py \
	    --campaign $(FUZZ_SEEDS) $(FUZZ_SEED_ARGS) --jobs $(FUZZ_JOBS) \
	    --config $$profile \
	    --cores $(FUZZ_CORE_ARG) --outdir build/fuzz/rc16 || exit; \
	done
	@for extension in mulh muldiv; do \
	  RISCC_SIM=$(abspath $(RISCC_SIM)) $(PYTHON) tools/riscc_fuzz.py \
	    --campaign $(FUZZ_SEEDS) $(FUZZ_SEED_ARGS) \
	    --jobs $(FUZZ_JOBS) \
	    --config full-$$extension --cores rc16-$$extension \
	    --outdir build/fuzz/rc16 || exit; \
	done
	RISCC_SIM=$(abspath $(RISCC_SIM)) $(PYTHON) tools/riscc_fuzz.py \
	  --family nano --campaign $(FUZZ_SEEDS) $(FUZZ_SEED_ARGS) \
	  --jobs $(FUZZ_JOBS) --config nano --outdir build/fuzz/nano

fuzz-all: fuzz fuzz-rc32 fuzz-fast fuzz-faster

# llvm-riscc is declared later, after its binary paths are configured.  Use
# the aggregate prerequisite here so this early fuzz rule still builds all
# three LLVM tools it invokes.
fuzz-rc32: $(RISCC_SIM) llvm-riscc
	@for profile in $(RC32_PROFILES); do \
	  RISCC_SIM=$(abspath $(RISCC_SIM)) RISCC_LLVM_BIN=$(abspath $(LLVM_BIN)) \
	    $(PYTHON) tools/riscc_fuzz.py --family rc32 --campaign $(FUZZ_SEEDS) \
	    $(FUZZ_SEED_ARGS) --jobs $(FUZZ_JOBS) --config $$profile \
	    --cores $(RC32_FUZZ_CORE_ARG) \
	    --outdir build/fuzz/rc32 || exit; \
	done

fuzz-faster: $(RISCC_SIM)
	RISCC_SIM=$(abspath $(RISCC_SIM)) $(PYTHON) tools/riscc_fuzz.py \
	  --family faster --campaign $(FUZZ_SEEDS) $(FUZZ_SEED_ARGS) \
	  --jobs $(FUZZ_JOBS) --config full --outdir build/fuzz/faster

# Keep one deterministic differential RC32 program in the normal regression
# gate.  The longer random campaign remains available through fuzz-rc32.
test-rc32: $(RISCC_SIM) llvm-riscc \
	$(foreach width,$(WIDTHS),build/test/rc32/sys/$(width).ok) \
	$(foreach width,$(WIDTHS),build/test/rc32/full/$(width).ok)
	RISCC_SIM=$(abspath $(RISCC_SIM)) RISCC_LLVM_BIN=$(abspath $(LLVM_BIN)) \
	  $(PYTHON) tools/riscc_fuzz.py --family rc32 --campaign 1 --base-seed 1 \
	  --jobs $(FUZZ_JOBS) --cores $(RC32_FUZZ_CORE_ARG) \
	  --outdir build/test/rc32

test-applications: test-rc16-application test-nano-application \
	test-rc32-application

test-rc16-application: $(RISCC_SIM) \
		build/test/rc16/native/min/16/tb \
		build/test/rc16/native/sys/16/tb
	@for profile in min sys; do \
	  $(MAKE) --no-print-directory RISCC_XLEN=16 PROFILE=$$profile firmware || exit; \
	  build_dir=$(abspath build/test/application/rc16)/$$profile; \
	  $(MAKE) --no-print-directory -C test/application \
	    RISCC_ROOT=$(abspath .) RISCC_XLEN=16 PROFILE=$$profile \
	    BUILD=$$build_dir all || exit; \
	  image=$$build_dir/application.bin; \
	  sim_flags=""; \
	  test "$$profile" = min && sim_flags="--min"; \
	  $(RISCC_SIM) $$image $$sim_flags --require-result \
	    --max-insns 5000000 || exit; \
	  build/test/rc16/native/$$profile/16/tb $$image \
	    --max-cycles 50000000 || exit; \
	done
	@echo "RC16 riscc.mk application ISS/RTL PASS"

test-nano-application: $(RISCC_SIM) build/test/nano/tb
	+$(MAKE) --no-print-directory PROFILE=nano firmware
	+$(MAKE) --no-print-directory -C test/application \
	  RISCC_ROOT=$(abspath .) RISCC_XLEN=16 PROFILE=nano \
	  BUILD=$(abspath build/test/application/nano) all
	$(RISCC_SIM) build/test/application/nano/application.bin --nano \
	  --require-result --max-insns 10000000
	build/test/nano/tb build/test/application/nano/application.bin \
	  --max-cycles 100000000
	@echo "Nano riscc.mk application ISS/RTL PASS"

test-rc32-application: $(RISCC_SIM) \
		$(foreach profile,$(RC32_PROFILES),build/test/rc32/$(profile)/16/tb)
	@for profile in $(RC32_PROFILES); do \
	  $(MAKE) --no-print-directory RISCC_XLEN=32 PROFILE=$$profile firmware || exit; \
	  build_dir=$(abspath build/test/application/rc32)/$$profile; \
	  $(MAKE) --no-print-directory -C test/application \
	    RISCC_ROOT=$(abspath .) RISCC_XLEN=32 PROFILE=$$profile \
	    BUILD=$$build_dir all || exit; \
	  image=$$build_dir/application.bin; \
	  sim_flags="--rc32"; \
	  test "$$profile" = sys && sim_flags="--rc32-sys"; \
	  test "$$profile" = full && sim_flags="--rc32-full"; \
	  $(RISCC_SIM) $$image $$sim_flags --require-result \
	    --max-insns 5000000 || exit; \
	  build/test/rc32/$$profile/16/tb $$image \
	    --max-cycles 50000000 || exit; \
	done
	@echo "RC32 riscc.mk application ISS/RTL PASS"

# RC32_SYS_TEST(width)
define RC32_SYS_TEST
build/test/rc32/sys/$(1)/tb: $(TB_SRC) rtl/riscc32_sys.v $(RISCC_RF_RTL) $(RTL_RULES)
	@mkdir -p $$(@D)
	+$$(VERILATOR) -cc --exe --build $$(VERILATOR_MAKEFLAGS_ARG) --top-module riscc32_sys \
	  -GW=$(1) -DRISCC_INFERRED_SYNC_RF --prefix Vriscc -Mdir $$(@D) \
	  -I$$(abspath rtl) -I$$(abspath rtl/test) \
	  -CFLAGS "$$(TB_CXXFLAGS) -DRISCC_TB_RC32 \
	    -DRISCC_TB_MEM_HANDSHAKE" -o tb \
	  $$(abspath rtl/riscc32_sys.v) $$(abspath $(TB_SRC))

build/test/rc32/sys/$(1).ok: build/test/rc32/sys/$(1)/tb $$(RC32_SYS_BIN) FORCE
	@mkdir -p $$(@D)
	$$< $$(RC32_SYS_BIN) --irq-at 300 --mem-stall-seed 777 \
	  --max-cycles 100000
	@touch $$@
endef

$(foreach width,$(WIDTHS),$(eval $(call RC32_SYS_TEST,$(width))))

# RC32 Min uses the same black-box memory/trace testbench as Sys, but remains
# a distinct top so compiler-generated Min images cannot accidentally pass by
# relying on Sys-only decode or control state.
define RC32_MIN_TB
build/test/rc32/min/$(1)/tb: $(TB_SRC) rtl/riscc32_min.v $(RISCC_RF_RTL) $(RTL_RULES)
	@mkdir -p $$(@D)
	+$$(VERILATOR) -cc --exe --build $$(VERILATOR_MAKEFLAGS_ARG) \
	  --top-module riscc32_min -GW=$(1) -DRISCC_INFERRED_SYNC_RF \
	  --prefix Vriscc -Mdir $$(@D) -I$$(abspath rtl) -I$$(abspath rtl/test) \
	  -CFLAGS "$$(TB_CXXFLAGS) -DRISCC_TB_RC32 \
	    -DRISCC_TB_MEM_HANDSHAKE" -o tb \
	  $$(abspath rtl/riscc32_min.v) $$(abspath $(TB_SRC))
endef

$(foreach width,$(WIDTHS),$(eval $(call RC32_MIN_TB,$(width))))

# RC32 Full is an independent sibling with serial immediate shifts and
# iterative low-half MUL.
define RC32_FULL_TEST
build/test/rc32/full/$(1)/tb: $(TB_SRC) rtl/riscc32_full.v \
		$(RISCC_RF_RTL) $(RTL_RULES)
	@mkdir -p $$(@D)
	+$$(VERILATOR) -cc --exe --build $$(VERILATOR_MAKEFLAGS_ARG) \
	  --top-module riscc32_full -GW=$(1) -DRISCC_INFERRED_SYNC_RF \
	  --prefix Vriscc -Mdir $$(@D) -I$$(abspath rtl) -I$$(abspath rtl/test) \
	  -CFLAGS "$$(TB_CXXFLAGS) -DRISCC_TB_RC32 \
	    -DRISCC_TB_MEM_HANDSHAKE" -o tb \
	  $$(abspath rtl/riscc32_full.v) $$(abspath $(TB_SRC))

build/test/rc32/full/$(1).ok: build/test/rc32/full/$(1)/tb \
		$$(RC32_FULL_ISA_IRQ_BIN) FORCE
	@mkdir -p $$(@D)
	$$< $$(RC32_FULL_ISA_IRQ_BIN) --irq-at 300 --mem-stall-seed 777 \
	  --max-cycles 1000000
	@touch $$@
endef

$(foreach width,$(WIDTHS),$(eval $(call RC32_FULL_TEST,$(width))))

fuzz-fast: $(RISCC_SIM)
	RISCC_SIM=$(abspath $(RISCC_SIM)) $(PYTHON) tools/riscc_fuzz.py \
	  --family fast --campaign $(FUZZ_SEEDS) $(FUZZ_SEED_ARGS) --config full \
	  --jobs $(FUZZ_JOBS) \
	  --cores fast,fast-dsp,fast-ecp5,fast-ecp5-dsp \
	  --outdir build/fuzz/fast
	RISCC_SIM=$(abspath $(RISCC_SIM)) $(PYTHON) tools/riscc_fuzz.py \
	  --family fast --campaign $(FUZZ_SEEDS) $(FUZZ_SEED_ARGS) --config full \
	  --jobs $(FUZZ_JOBS) --cores fast-block,fast-block-dsp \
	  --outdir build/fuzz/fast-block
	RISCC_SIM=$(abspath $(RISCC_SIM)) $(PYTHON) tools/riscc_fuzz.py \
	  --family fast --campaign $(FUZZ_SEEDS) $(FUZZ_SEED_ARGS) --config full \
	  --jobs $(FUZZ_JOBS) --cores fast-agilex,fast-agilex-dsp \
	  --outdir build/fuzz/fast-agilex

# Architectural traces

.PHONY: trace trace-fast trace-nano trace-rc32
TRACE_CXXFLAGS = $(TB_CXXFLAGS) -DRISCC_TB_TRACE
rc16_handshake_cflags = -DRISCC_TB_MEM_HANDSHAKE

TRACE_TB := build/trace/rc16/$(PROFILE)/$(WIDTH)/tb
FAST_TRACE_TB := build/trace/fast/$(MEMORY)/$(MULTIPLIER)/tb
RC32_TRACE_TB := build/trace/rc32/$(PROFILE)/$(WIDTH)/tb
RC32_TRACE_BIN_min := $(RC32_MIN_TRACE_BIN)
RC32_TRACE_BIN_sys := $(RC32_ISA_IRQ_BIN)
RC32_TRACE_BIN_full := $(RC32_FULL_ISA_IRQ_BIN)
RC32_TRACE_IRQ_sys := --irq-at 300
RC32_TRACE_IRQ_full := --irq-at 300

$(TRACE_TB): $(TB_SRC) $(call rc16_source,$(WIDTH),$(PROFILE)) $(TRACE_RTL) $(RISCC_RF_RTL)
	@mkdir -p $(@D)
	+$(VERILATOR) -cc --exe --build $(VERILATOR_MAKEFLAGS_ARG) \
	  --top-module $(call rc16_top,$(WIDTH),$(PROFILE)) \
	  $(call rc16_verilator_width,$(WIDTH)) --prefix Vriscc -Mdir $(@D) \
	  -I$(abspath rtl) -I$(abspath rtl/test) -DRISCC_TRACE \
	  -CFLAGS "$(TRACE_CXXFLAGS) \
	    $(call rc16_handshake_cflags,$(PROFILE),$(WIDTH))" -o tb \
	  $(abspath $(call rc16_source,$(WIDTH),$(PROFILE))) $(abspath $(TB_SRC))

trace: $(TRACE_TB) build/bin/$(PROFILE).bin
	$< build/bin/$(PROFILE).bin --trace --max-cycles 10000000

build/trace/nano/tb: $(TB_SRC) rtl/riscc_nano.v $(TRACE_RTL) $(RISCC_RF_RTL)
	@mkdir -p $(@D)
	+$(VERILATOR) -cc --exe --build $(VERILATOR_MAKEFLAGS_ARG) --top-module riscc_nano \
	  --prefix Vriscc -Mdir $(@D) -I$(abspath rtl) -I$(abspath rtl/test) -DRISCC_TRACE \
	  -CFLAGS "$(TRACE_CXXFLAGS) -DRISCC_TB_MEM_OE_N" -o tb \
	  $(abspath rtl/riscc_nano.v) $(abspath $(TB_SRC))

trace-nano: build/trace/nano/tb build/bin/nano.bin
	$< build/bin/nano.bin --trace --max-cycles 200000

$(RC32_TRACE_TB): $(TB_SRC) rtl/riscc32_$(PROFILE).v $(TRACE_RTL) $(RISCC_RF_RTL)
	@mkdir -p $(@D)
	+$(VERILATOR) -cc --exe --build $(VERILATOR_MAKEFLAGS_ARG) \
	  --top-module riscc32_$(PROFILE) --prefix Vriscc -Mdir $(@D) \
	  -GW=$(WIDTH) -DRISCC_INFERRED_SYNC_RF \
	  -I$(abspath rtl) -I$(abspath rtl/test) -DRISCC_TRACE \
	  -CFLAGS "$(TRACE_CXXFLAGS) -DRISCC_TB_RC32 \
	    -DRISCC_TB_MEM_HANDSHAKE" -o tb \
	  $(abspath rtl/riscc32_$(PROFILE).v) $(abspath $(TB_SRC))

trace-rc32: $(RC32_TRACE_TB) $(RC32_TRACE_BIN_$(PROFILE))
	$< $(RC32_TRACE_BIN_$(PROFILE)) $(RC32_TRACE_IRQ_$(PROFILE)) \
	  --trace --max-cycles 1000000

$(FAST_TRACE_TB): $(TB_SRC) rtl/riscc16_fast.v $(TRACE_RTL)
	@mkdir -p $(@D)
	+$(VERILATOR) -cc --exe --build $(VERILATOR_MAKEFLAGS_ARG) \
	  --top-module riscc16_fast --prefix Vriscc -Mdir $(@D) \
	  -I$(abspath rtl) -I$(abspath rtl/test) -DRISCC_TRACE \
	  $(call fast_defines,$(MEMORY),$(MULTIPLIER)) \
	  -CFLAGS "$(TRACE_CXXFLAGS) -DRISCC_TB_TRACE_DRAIN=1 \
	    -DRISCC_TB_MEM_HANDSHAKE" -o tb \
	  $(abspath rtl/riscc16_fast.v) $(abspath $(TB_SRC))

trace-fast: $(FAST_TRACE_TB) build/bin/full.bin
	$< build/bin/full.bin --trace --max-cycles 1000000

# Verilator tests

.PHONY: test-core test-cores test-extension test-extensions \
	test-funnel test-high-address test-nano test-fast test-fast-all test-faster

# RC16_TEST(mode, profile, width)
define RC16_TEST
build/test/rc16/$(1)/$(2)/$(3)/tb: $(TB_SRC) \
		$(call rc16_source,$(3),$(2)) $(RISCC_RF_RTL) $(RTL_RULES)
	@mkdir -p $$(@D)
	+$$(VERILATOR) -cc --exe --build $$(VERILATOR_MAKEFLAGS_ARG) \
	  --top-module $(call rc16_top,$(3),$(2)) $(call rc16_verilator_width,$(3)) \
	  --prefix Vriscc -Mdir $$(@D) $$(RF_DEFINES_$(1)) \
	  -CFLAGS "$$(TB_CXXFLAGS) \
	    $(call rc16_handshake_cflags,$(2),$(3))" -o tb \
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

test-high-address: $(HIGH_ADDRESS_BIN) $(RISCC_SIM) \
		$(foreach width,$(WIDTHS),build/test/rc16/native/full/$(width)/tb) \
		test/linker/rc16/check_high_address.py
	$(PYTHON) test/linker/rc16/check_high_address.py \
	  --readobj $(LLVM_BIN)/llvm-readobj --nm $(LLVM_BIN)/llvm-nm \
	  --object $(HIGH_ADDRESS_BIN).o --elf $(HIGH_ADDRESS_BIN).elf
	$(RISCC_SIM) $(HIGH_ADDRESS_BIN) --full --max-insns 1000
	@for width in $(WIDTHS); do \
	  build/test/rc16/native/full/$$width/tb $(HIGH_ADDRESS_BIN) \
	    --max-cycles 100000 || exit; \
	done

# EXTENSION_TEST(mode, extension)
define EXTENSION_TEST
build/test/extension/$(1)/$(2)/tb: $(TB_SRC) rtl/riscc16_full_$(2).v $(RISCC_RF_RTL) $(RTL_RULES)
	@mkdir -p $$(@D)
	+$$(VERILATOR) -cc --exe --build $$(VERILATOR_MAKEFLAGS_ARG) --top-module riscc16 \
	  --prefix Vriscc -Mdir $$(@D) -I$$(abspath rtl) $$(RF_DEFINES_$(1)) \
	  -CFLAGS "$$(TB_CXXFLAGS) -DRISCC_TB_MEM_HANDSHAKE" -o tb \
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
	$(foreach memory,async ecp5-block,$(foreach multiplier,$(MULTIPLIERS), \
	  build/test/fast/$(memory)/$(multiplier)/tb)) \
	$(foreach multiplier,$(MULTIPLIERS), \
	  build/test/faster/ecp5-block/$(multiplier)/tb) \
	$(FUNNEL_BIN) $(RISCC_SIM)
	@for profile in $(RC16_PROFILES); do \
	  for width in $(WIDTHS); do \
	    build/test/rc16/native/$$profile/$$width/tb \
	      $(FUNNEL_BIN) --max-cycles 5000 || exit; \
	  done; \
	done
	@for memory in async ecp5-block; do for multiplier in $(MULTIPLIERS); do \
	  build/test/fast/$$memory/$$multiplier/tb \
	    $(FUNNEL_BIN) --max-cycles 5000 || exit; \
	done; done
	@for multiplier in $(MULTIPLIERS); do \
	  build/test/faster/ecp5-block/$$multiplier/tb \
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
	  --prefix Vriscc -Mdir $(@D) \
	  -CFLAGS "$(TB_CXXFLAGS) -DRISCC_TB_MEM_OE_N" -o tb \
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
	  -CFLAGS "$$(TB_CXXFLAGS) -DRISCC_TB_MEM_HANDSHAKE" -o tb \
	  $$(abspath rtl/riscc16_fast.v) $$(abspath $(TB_SRC))

build/test/fast/$(1)/$(2).ok: build/test/fast/$(1)/$(2)/tb build/bin/full.bin FORCE
	@mkdir -p $$(@D)
	$$< build/bin/full.bin --max-cycles 1000000
	$$< build/bin/full.bin --irq-at 300 --mem-stall-seed 777 \
	  --max-cycles 1000000
	@touch $$@
endef

$(foreach memory,$(FAST_MEMORIES),$(foreach multiplier,$(MULTIPLIERS), \
	$(eval $(call FAST_TEST,$(memory),$(multiplier)))))

test-fast: build/test/fast/$(MEMORY)/$(MULTIPLIER).ok
test-fast-all: $(foreach memory,$(FAST_MEMORIES),$(foreach multiplier,$(MULTIPLIERS), \
	build/test/fast/$(memory)/$(multiplier).ok))

FASTER_DEFINES_dsp :=
FASTER_DEFINES_soft := -DRISCC_FASTER_SOFT_MUL

# FASTER_TEST(memory, multiplier)
define FASTER_TEST
build/test/faster/$(1)/$(2)/tb: $(TB_SRC) rtl/riscc16_faster.v $(RTL_RULES)
	@mkdir -p $$(@D)
	+$$(VERILATOR) -cc --exe --build $$(VERILATOR_MAKEFLAGS_ARG) \
	  --top-module riscc16_faster --prefix Vriscc -Mdir $$(@D) \
	  $$(FASTER_MEMORY_DEFINES_$(1)) $$(FASTER_DEFINES_$(2)) \
	  -CFLAGS "$$(TB_CXXFLAGS) -DRISCC_TB_MEM_HANDSHAKE" -o tb \
	  $$(abspath rtl/riscc16_faster.v) $$(abspath $(TB_SRC))

build/test/faster/$(1)/$(2).ok: build/test/faster/$(1)/$(2)/tb build/bin/full.bin FORCE
	@mkdir -p $$(@D)
	$$< build/bin/full.bin --max-cycles 1000000
	$$< build/bin/full.bin --irq-at 300 --mem-stall-seed 777 \
	  --max-cycles 1000000
	@touch $$@
endef

$(foreach memory,$(FASTER_MEMORIES),$(foreach multiplier,$(MULTIPLIERS), \
	$(eval $(call FASTER_TEST,$(memory),$(multiplier)))))

test-faster: $(foreach memory,$(FASTER_MEMORIES),$(foreach multiplier,$(MULTIPLIERS), \
	build/test/faster/$(memory)/$(multiplier).ok))

.PHONY: bench
bench: $(foreach width,$(WIDTHS),build/test/rc16/native/full/$(width)/tb) \
	build/test/nano/tb \
	$(foreach memory,async ecp5-block,$(foreach multiplier,$(MULTIPLIERS), \
	  build/test/fast/$(memory)/$(multiplier)/tb)) \
	$(foreach multiplier,$(MULTIPLIERS), \
	  build/test/faster/ecp5-block/$(multiplier)/tb) \
	$(BENCH_BIN) $(NANO_BENCH_BIN)
	@for width in $(WIDTHS); do \
	  tb=build/test/rc16/native/full/$$width/tb; \
	  out="$$($$tb $(BENCH_BIN) --max-cycles 800000 2>&1 | tail -1)"; \
	  printf 'rc16/%-3s %s\n' $$width "$$out"; \
	done
	@out="$$(build/test/nano/tb $(NANO_BENCH_BIN) \
	  --max-cycles 2000000 2>&1 | tail -1)"; printf '%-8s %s\n' nano "$$out"
	@for memory in async ecp5-block; do for multiplier in $(MULTIPLIERS); do \
	  tb=build/test/fast/$$memory/$$multiplier/tb; \
	  out="$$($$tb $(BENCH_BIN) --max-cycles 800000 2>&1 | tail -1)"; \
	  printf 'fast/%s/%-4s %s\n' $$memory $$multiplier "$$out"; \
	done; done
	@for multiplier in $(MULTIPLIERS); do \
	  tb=build/test/faster/ecp5-block/$$multiplier/tb; \
	  out="$$($$tb $(BENCH_BIN) --max-cycles 800000 2>&1 | tail -1)"; \
	  printf 'faster/%-4s %s\n' $$multiplier "$$out"; \
	done

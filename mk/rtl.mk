RTL_RULES := Makefile mk/rtl.mk mk/serial.mk mk/wide.mk

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
	test-fast-all test-cached-all test-cached-irq-all \
	test-peripherals test-funnel test-high-address

# Run the ISA and compiler gates in order because they share LLVM, firmware, and RTL
# output trees. Each recursive make inherits the GNU Make jobserver, so every
# gate still uses the caller's full -j parallelism internally.
test-all: check-llvm-riscc
	+$(MAKE) --no-print-directory test-isa
	+$(MAKE) --no-print-directory test-compiler
	+$(MAKE) --no-print-directory test-cached-all test-cached-irq-all

$(PERIPHERAL_TB): test/peripheral_tb.cpp $(PERIPHERAL_RTL)
	@mkdir -p $(@D)
	+$(VERILATOR) -cc --exe --build $(VERILATOR_MAKEFLAGS_ARG) \
	  --top-module riscc_peripherals_top --prefix Vriscc_peripherals_top \
	  -GTICK_DIV=4 -Mdir $(@D) -CFLAGS "$(TB_CXXFLAGS)" -o tb \
	  $(abspath $(PERIPHERAL_RTL)) $(abspath test/peripheral_tb.cpp)
.PHONY: test-uart-mmio test-peripherals
test-uart-mmio:
	@set -e; \
	for div in 16 579 1736; do \
	  for pipeline in 0 1; do \
	    output=build/test/uart-mmio/div$${div}-pipeline$${pipeline}; \
	    mkdir -p "$${output}"; \
	    iverilog -g2012 -DVERILATOR -s uart_mmio_tb \
	      -P uart_mmio_tb.CLK_DIV=$${div} \
	      -P uart_mmio_tb.PIPELINE_WRITES=$${pipeline} \
	      -o "$${output}/uart_mmio_tb.vvp" \
	      boards/shared/rtl/riscc_uart_mmio.v test/uart_mmio_tb.v; \
	    vvp "$${output}/uart_mmio_tb.vvp"; \
	  done; \
	done
test-peripherals: $(PERIPHERAL_TB) test-uart-mmio
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

FAST_SIM_FLAGS_soft := --fast-soft
FAST_SIM_FLAGS_dsp := --fast
sim-fast: build/bin/full.bin $(RISCC_SIM)
	$(RISCC_SIM) $< $(FAST_SIM_FLAGS_$(MULTIPLIER))

FUZZ_SEEDS ?= 300
FUZZ_SEED_ARGS ?= --random-seed
FUZZ_JOBS ?= $(shell nproc)
FUZZ_CORES ?= $(foreach width,$(WIDTHS),rc16-$(width))
FUZZ_CORE_ARG = $(call join_with_commas,$(FUZZ_CORES))
RC32_FUZZ_CORES ?= $(foreach width,$(WIDTHS),rc32-$(width))
RC32_FUZZ_CORE_ARG = $(call join_with_commas,$(RC32_FUZZ_CORES))

.PHONY: fuzz fuzz-all fuzz-rc32 fuzz-fast fuzz-cached test-rc32 \
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

fuzz-all: fuzz fuzz-rc32 fuzz-fast fuzz-fast32 fuzz-cached fuzz-cached32

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

fuzz-fast: $(RISCC_SIM)
	RISCC_SIM=$(abspath $(RISCC_SIM)) $(PYTHON) tools/riscc_fuzz.py \
	  --family fast --campaign $(FUZZ_SEEDS) $(FUZZ_SEED_ARGS) \
	  --jobs $(FUZZ_JOBS) --config full --outdir build/fuzz/fast

.PHONY: fuzz-fast32
fuzz-fast32: $(RISCC_SIM) llvm-riscc
	RISCC_SIM=$(abspath $(RISCC_SIM)) RISCC_LLVM_BIN=$(abspath $(LLVM_BIN)) $(PYTHON) tools/riscc_fuzz.py \
	  --family rc32 --config full --cores fast32-soft,fast32-dsp,fast32-agilex-soft,fast32-agilex-dsp \
	  --campaign $(FUZZ_SEEDS) $(FUZZ_SEED_ARGS) --jobs $(FUZZ_JOBS) --outdir build/fuzz/fast32

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

# RC32_TEST(profile, width)
RC32_TEST_BIN_min := $(RC32_MIN_TRACE_BIN)
RC32_TEST_BIN_sys := $(RC32_ISA_IRQ_BIN)
RC32_TEST_BIN_full := $(RC32_FULL_ISA_IRQ_BIN)
RC32_TEST_IRQ_min :=
RC32_TEST_IRQ_sys := --irq-at 300
RC32_TEST_IRQ_full := --irq-at 300
RC32_TEST_MAX_CYCLES_min := 100000
RC32_TEST_MAX_CYCLES_sys := 100000
RC32_TEST_MAX_CYCLES_full := 1000000

define RC32_TEST
build/test/rc32/$(1)/$(2)/tb: $(TB_SRC) $(call rc32_source,$(1)) $(RISCC_RF_RTL) $(RTL_RULES)
	@mkdir -p $$(@D)
	+$$(VERILATOR) -cc --exe --build $$(VERILATOR_MAKEFLAGS_ARG) \
	  --top-module $(call rc32_top,$(1)) \
	  $(call rc32_verilator_width,$(2),$(1)) -DRISCC_INFERRED_SYNC_RF \
	  --prefix Vriscc -Mdir $$(@D) -I$$(abspath rtl) -I$$(abspath rtl/test) \
	  -CFLAGS "$$(TB_CXXFLAGS) -DRISCC_TB_RC32 \
	    -DRISCC_TB_MEM_HANDSHAKE" -o tb \
	  $$(abspath $(call rc32_source,$(1))) $$(abspath $(TB_SRC))

build/test/rc32/$(1)/$(2).ok: build/test/rc32/$(1)/$(2)/tb \
		$$(RC32_TEST_BIN_$(1)) FORCE
	@mkdir -p $$(@D)
	$$< $$(RC32_TEST_BIN_$(1)) $$(RC32_TEST_IRQ_$(1)) \
	  --mem-stall-seed 777 --max-cycles $$(RC32_TEST_MAX_CYCLES_$(1))
	@touch $$@
endef

$(foreach profile,$(RC32_PROFILES),$(foreach width,$(WIDTHS), \
	$(eval $(call RC32_TEST,$(profile),$(width)))))

# Architectural traces

.PHONY: trace trace-nano trace-rc32
TRACE_CXXFLAGS = $(TB_CXXFLAGS) -DRISCC_TB_TRACE
rc16_handshake_cflags = -DRISCC_TB_MEM_HANDSHAKE

TRACE_TB := build/trace/rc16/$(PROFILE)/$(WIDTH)/tb
RC32_TRACE_TB := build/trace/rc32/$(PROFILE)/$(WIDTH)/tb
RC32_TRACE_BIN_min := $(RC32_MIN_TRACE_BIN)
RC32_TRACE_BIN_sys := $(RC32_ISA_IRQ_BIN)
RC32_TRACE_BIN_full := $(RC32_FULL_ISA_IRQ_BIN)
RC32_TRACE_IRQ_sys := --irq-at 300
RC32_TRACE_IRQ_full := --irq-at 300

$(TRACE_TB): $(TB_SRC) $(call rc16_source,$(WIDTH),$(PROFILE)) $(TRACE_RTL) $(RISCC_RF_RTL) $(RTL_RULES)
	@mkdir -p $(@D)
	+$(VERILATOR) -cc --exe --build $(VERILATOR_MAKEFLAGS_ARG) \
	  --top-module $(call rc16_top,$(WIDTH),$(PROFILE)) \
	  $(call rc16_verilator_width,$(WIDTH),$(PROFILE)) --prefix Vriscc -Mdir $(@D) \
	  -I$(abspath rtl) -I$(abspath rtl/test) -DRISCC_TRACE \
	  -CFLAGS "$(TRACE_CXXFLAGS) -DRISCC_TB_TRACE_DRAIN=0 \
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

$(RC32_TRACE_TB): $(TB_SRC) $(call rc32_source,$(PROFILE)) $(TRACE_RTL) $(RISCC_RF_RTL) $(RTL_RULES)
	@mkdir -p $(@D)
	+$(VERILATOR) -cc --exe --build $(VERILATOR_MAKEFLAGS_ARG) \
	  --top-module $(call rc32_top,$(PROFILE)) --prefix Vriscc -Mdir $(@D) \
	  $(call rc32_verilator_width,$(WIDTH),$(PROFILE)) -DRISCC_INFERRED_SYNC_RF \
	  -I$(abspath rtl) -I$(abspath rtl/test) -DRISCC_TRACE \
	  -CFLAGS "$(TRACE_CXXFLAGS) -DRISCC_TB_RC32 \
	    -DRISCC_TB_MEM_HANDSHAKE" -o tb \
	  $(abspath $(call rc32_source,$(PROFILE))) $(abspath $(TB_SRC))

trace-rc32: $(RC32_TRACE_TB) $(RC32_TRACE_BIN_$(PROFILE))
	$< $(RC32_TRACE_BIN_$(PROFILE)) $(RC32_TRACE_IRQ_$(PROFILE)) \
	  --trace --max-cycles 1000000

# Verilator tests

.PHONY: test-core test-cores test-extension test-extensions \
	test-funnel test-high-address test-nano test-fast test-fast-all

# RC16_TEST(mode, profile, width)
define RC16_TEST
build/test/rc16/$(1)/$(2)/$(3)/tb: $(TB_SRC) \
		$(call rc16_source,$(3),$(2)) $(RISCC_RF_RTL) $(RTL_RULES)
	@mkdir -p $$(@D)
	+$$(VERILATOR) -cc --exe --build $$(VERILATOR_MAKEFLAGS_ARG) \
	  --top-module $(call rc16_top,$(3),$(2)) $(call rc16_verilator_width,$(3),$(2)) \
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
build/test/extension/$(1)/$(2)/tb: $(TB_SRC) rtl/riscc_wide.v $(RISCC_RF_RTL) $(RTL_RULES)
	@mkdir -p $$(@D)
	+$$(VERILATOR) -cc --exe --build $$(VERILATOR_MAKEFLAGS_ARG) --top-module riscc_wide \
	  $(call wide_verilator_params,16,full,$(EXTENSION_MDU_$(2))) \
	  --prefix Vriscc -Mdir $$(@D) -I$$(abspath rtl) $$(RF_DEFINES_$(1)) \
	  -CFLAGS "$$(TB_CXXFLAGS) -DRISCC_TB_MEM_HANDSHAKE" -o tb \
	  $$(abspath rtl/riscc_wide.v) $$(abspath $(TB_SRC))

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
	$(foreach multiplier,$(MULTIPLIERS), \
	  build/test/fast/ecp5-block/$(multiplier)/tb) \
	$(FUNNEL_BIN) $(RISCC_SIM)
	@for profile in $(RC16_PROFILES); do \
	  for width in $(WIDTHS); do \
	    build/test/rc16/native/$$profile/$$width/tb \
	      $(FUNNEL_BIN) --max-cycles 5000 || exit; \
	  done; \
	done
	@for multiplier in $(MULTIPLIERS); do \
	  build/test/fast/ecp5-block/$$multiplier/tb \
	    $(FUNNEL_BIN) --max-cycles 5000 || exit; \
	done
	@$(foreach profile,$(RC16_PROFILES),$(RISCC_SIM) $(FUNNEL_BIN) \
	  $(SIM_FLAGS_$(profile)) --max-insns 5000 || exit;)
	$(RISCC_SIM) $(FUNNEL_BIN) --fast --max-insns 5000
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

FAST_DEFINES_dsp :=
FAST_DEFINES_soft := -DRISCC_FAST_SOFT_MUL

# FAST_TEST(memory, multiplier, xlen)
fast_family = $(if $(filter 32,$(1)),fast32,fast)
FAST_IMAGE_16 := build/bin/full.bin
FAST_IMAGE_32 := $(RC32_FULL_ISA_IRQ_BIN)
FAST_IRQ_IMAGE_16 := $(ISA_IRQ_BIN)
FAST_IRQ_IMAGE_32 := $(RC32_FULL_ISA_IRQ_BIN)
FAST_ADDRESS_32 := build/bin/serial32-address-full.bin build/bin/wide32-load-full.bin
define FAST_TEST
build/test/$(call fast_family,$(3))/$(1)/$(2)/tb: $(TB_SRC) rtl/riscc_fast.v $(RTL_RULES)
	@mkdir -p $$(@D)
	+$$(VERILATOR) -cc --exe --build $$(VERILATOR_MAKEFLAGS_ARG) \
	  --top-module riscc_fast -GXLEN=$(3) --prefix Vriscc -Mdir $$(@D) \
	  $$(FAST_MEMORY_DEFINES_$(1)) $$(FAST_DEFINES_$(2)) \
	  -CFLAGS "$$(TB_CXXFLAGS) -DRISCC_TB_MEM_PIPELINED $(if $(filter 32,$(3)),-DRISCC_TB_RC32)" -o tb \
	  $$(abspath rtl/riscc_fast.v) $$(abspath $(TB_SRC))

build/test/$(call fast_family,$(3))/$(1)/$(2).ok: build/test/$(call fast_family,$(3))/$(1)/$(2)/tb $(FAST_IMAGE_$(3)) $(FAST_ADDRESS_$(3)) FORCE
	@mkdir -p $$(@D)
	$$< $(FAST_IMAGE_$(3)) $(if $(filter 32,$(3)),--irq-at 300) --max-cycles 1000000
	$$< $(FAST_IMAGE_$(3)) --irq-at 300 --mem-stall-seed 777 \
	  --max-cycles 1000000
	$(foreach image,$(FAST_ADDRESS_$(3)),$$< $(image) --mem-stall-seed 777 --max-cycles 1000000 &&) true
	@touch $$@
build/test/$(call fast_family,$(3))/$(1)/$(2)-irq.ok: build/test/$(call fast_family,$(3))/$(1)/$(2)/tb $(FAST_IRQ_IMAGE_$(3)) tools/test_irq_cycles.py FORCE
	$$(PYTHON) tools/test_irq_cycles.py --tb $$< --image $(FAST_IRQ_IMAGE_$(3)) \
	  --jobs $$(RISCC_BUILD_JOBS) --stall-seed 777 --max-cycles 1000000
	@touch $$@
endef

$(foreach xlen,16 32,$(foreach memory,$(FAST_MEMORIES),$(foreach multiplier,$(MULTIPLIERS), \
	$(eval $(call FAST_TEST,$(memory),$(multiplier),$(xlen))))))

test-fast: build/test/$(call fast_family,$(XLEN))/$(MEMORY)/$(MULTIPLIER).ok

# Registered SRAM throughput and dependent forwarding are architectural
# performance contracts, checked independently of whole-program cycle totals.
.PHONY: test-fast-pipeline
test-fast-pipeline:
	$(PYTHON) tools/test_fast_pipeline.py --verilator $(VERILATOR)

test-fast-all: test-fast-pipeline

test-fast-all: $(foreach xlen,16 32,$(foreach memory,$(FAST_MEMORIES),$(foreach multiplier,$(MULTIPLIERS), \
	build/test/$(call fast_family,$(xlen))/$(memory)/$(multiplier).ok)))

.PHONY: test-fast-irq test-fast-irq-all
test-fast-irq: build/test/$(call fast_family,$(XLEN))/$(MEMORY)/$(MULTIPLIER)-irq.ok
test-fast-irq-all: $(foreach xlen,16 32,$(foreach memory,$(FAST_MEMORIES),$(foreach multiplier,$(MULTIPLIERS), \
	build/test/$(call fast_family,$(xlen))/$(memory)/$(multiplier)-irq.ok)))

.PHONY: bench bench-rc16 bench-rc32
bench: bench-rc16 bench-rc32

bench-rc16: $(foreach width,$(WIDTHS),build/test/rc16/native/full/$(width)/tb) \
	build/test/nano/tb \
	$(foreach multiplier,$(MULTIPLIERS), \
	  build/test/fast/ecp5-block/$(multiplier)/tb) \
	$(BENCH_BIN) $(NANO_BENCH_BIN)
	@for width in $(WIDTHS); do \
	  tb=build/test/rc16/native/full/$$width/tb; \
	  printf 'rc16/%s ' $$width; \
	  $$tb $(BENCH_BIN) --max-cycles 800000 || exit; \
	done
	@printf 'nano '
	@build/test/nano/tb $(NANO_BENCH_BIN) --max-cycles 2000000
	@for multiplier in $(MULTIPLIERS); do \
	  tb=build/test/fast/ecp5-block/$$multiplier/tb; \
	  printf 'fast/%s ' $$multiplier; \
	  $$tb $(BENCH_BIN) --max-cycles 800000 || exit; \
	done

build/bin/bench-rc32.bin: test/test_rc32_bench.asm test/flat.ld | llvm-riscc
	$(call ASSEMBLE_IMAGE,$<,full,--mattr=+rc32,,test/flat.ld)

.PHONY: bench-fast32
bench-fast32: build/bin/bench-rc32.bin $(RISCC_SIM) \
	$(foreach multiplier,$(MULTIPLIERS),build/test/fast32/ecp5-block/$(multiplier)/tb)
	$(RISCC_SIM) $< --rc32-full --max-insns 100000
	@for multiplier in $(MULTIPLIERS); do \
	  printf 'fast32/%s ' $$multiplier; \
	  build/test/fast32/ecp5-block/$$multiplier/tb $< --max-cycles 100000 || exit; \
	done

bench-rc32: bench-fast32 $(foreach width,$(WIDTHS),build/test/rc32/full/$(width)/tb) \
	build/test/wide/32/full/0/native/tb
	@for width in $(WIDTHS); do \
	  printf 'rc32/%s ' $$width; \
	  build/test/rc32/full/$$width/tb build/bin/bench-rc32.bin --max-cycles 1000000 || exit; \
	done
	@printf 'rc32/32 '
	@build/test/wide/32/full/0/native/tb build/bin/bench-rc32.bin --max-cycles 1000000

# Cached includes its instruction and data caches. The legacy C++ fixture
# reaches its 32-bit backing port through a test-only width adapter.
cached_family = $(if $(filter 32,$(1)),cached32,cached)

# Native 32-bit backing SRAM, shared with the assembly benchmark runner.
cached_bench_tb = build/split-cache/bench/$(1)-$(2)-$(3)-cache/Vriscc_cached_bench_tb
define CACHED_BENCH
$(call cached_bench_tb,$(1),$(2),$(3)): rtl/riscc_fast.v rtl/riscc_cached.v \
		test/riscc_cached_bench_tb.v $(RTL_RULES)
	@mkdir -p $$(@D)
	+$$(VERILATOR) --binary --timing $$(VERILATOR_MAKEFLAGS_ARG) \
	  --top-module riscc_cached_bench_tb -GXLEN=$(1) -GCACHED=1 --Mdir $$(@D) \
	  $$(FAST_MEMORY_DEFINES_$(3)) $$(FAST_DEFINES_$(2)) \
	  rtl/riscc_fast.v rtl/riscc_cached.v test/riscc_cached_bench_tb.v
endef
$(foreach xlen,16 32,$(foreach multiplier,$(MULTIPLIERS),$(foreach memory,$(FAST_MEMORIES), \
	$(eval $(call CACHED_BENCH,$(xlen),$(multiplier),$(memory))))))

define CACHED_TEST
build/test/$(call cached_family,$(3))/$(1)/$(2)/tb: $(TB_SRC) rtl/riscc_fast.v rtl/riscc_cached.v rtl/test/riscc_cached_test_top.v $(RTL_RULES)
	@mkdir -p $$(@D)
	+$$(VERILATOR) -cc --exe --build $$(VERILATOR_MAKEFLAGS_ARG) \
	  --top-module riscc_cached_test_top -GXLEN=$(3) --prefix Vriscc -Mdir $$(@D) \
	  $$(FAST_MEMORY_DEFINES_$(1)) $$(FAST_DEFINES_$(2)) \
	  -CFLAGS "$$(TB_CXXFLAGS) -DRISCC_TB_MEM_PIPELINED $(if $(filter 32,$(3)),-DRISCC_TB_RC32)" -o tb \
	  $$(abspath rtl/riscc_fast.v) $$(abspath rtl/riscc_cached.v) \
	  $$(abspath rtl/test/riscc_cached_test_top.v) $$(abspath $(TB_SRC))

build/test/$(call cached_family,$(3))/$(1)/$(2).ok: build/test/$(call cached_family,$(3))/$(1)/$(2)/tb $(FAST_IMAGE_$(3)) $(FAST_ADDRESS_$(3)) FORCE
	@mkdir -p $$(@D)
	$$< $(FAST_IMAGE_$(3)) $(if $(filter 32,$(3)),--irq-at 300) --max-cycles 1000000
	$$< $(FAST_IMAGE_$(3)) --irq-at 300 --mem-stall-seed 777 \
	  --max-cycles 1000000
	$(foreach image,$(FAST_ADDRESS_$(3)),$$< $(image) --mem-stall-seed 777 --max-cycles 1000000 &&) true
	@touch $$@
build/test/$(call cached_family,$(3))/$(1)/$(2)-irq.ok: build/test/$(call cached_family,$(3))/$(1)/$(2)/tb $(FAST_IRQ_IMAGE_$(3)) tools/test_irq_cycles.py FORCE
	$$(PYTHON) tools/test_irq_cycles.py --tb $$< --image $(FAST_IRQ_IMAGE_$(3)) \
	  --jobs $$(RISCC_BUILD_JOBS) --stall-seed 777 --max-cycles 1000000
	@touch $$@
endef

$(foreach xlen,16 32,$(foreach memory,$(FAST_MEMORIES),$(foreach multiplier,$(MULTIPLIERS), \
  $(eval $(call CACHED_TEST,$(memory),$(multiplier),$(xlen))))))

.PHONY: test-cached test-cached-all test-cached-irq-all test-cached-pipeline \
	test-cached-hits test-cached-address test-cached-sram test-cache bench-cached
test-cached: build/test/$(call cached_family,$(XLEN))/$(MEMORY)/$(MULTIPLIER).ok
test-cached-all: test-cached-pipeline test-cached-hits test-cached-address test-cached-sram test-cache $(foreach xlen,16 32,$(foreach memory,$(FAST_MEMORIES),$(foreach multiplier,$(MULTIPLIERS), \
  build/test/$(call cached_family,$(xlen))/$(memory)/$(multiplier).ok)))
test-cached-irq-all: $(foreach xlen,16 32,$(foreach memory,$(FAST_MEMORIES),$(foreach multiplier,$(MULTIPLIERS), \
  build/test/$(call cached_family,$(xlen))/$(memory)/$(multiplier)-irq.ok)))
test-cached-pipeline:
	$(PYTHON) tools/test_cached_pipeline.py --verilator $(VERILATOR)
test-cached-hits:
	$(PYTHON) tools/test_cached_hits.py --verilator $(VERILATOR)
test-cached-address:
	$(PYTHON) tools/test_cached_address.py --verilator $(VERILATOR)
test-cached-sram:
	$(PYTHON) tools/test_cached_sram.py --verilator $(VERILATOR)
test-cache:
	$(PYTHON) tools/test_cache.py --verilator $(VERILATOR)
bench-cached: $(BENCH_BIN) build/bin/bench-rc32.bin
	$(PYTHON) tools/bench_cached.py --verilator $(VERILATOR)

.PHONY: fuzz-cached fuzz-cached32
fuzz-cached: $(RISCC_SIM)
	RISCC_SIM=$(abspath $(RISCC_SIM)) $(PYTHON) tools/riscc_fuzz.py \
	  --family fast --campaign $(FUZZ_SEEDS) $(FUZZ_SEED_ARGS) \
	  --jobs $(FUZZ_JOBS) --config full --cores cached-soft,cached-dsp,cached-agilex-soft,cached-agilex-dsp \
	  --outdir build/fuzz/cached

.PHONY: fuzz-cached32
fuzz-cached32: $(RISCC_SIM) llvm-riscc
	RISCC_SIM=$(abspath $(RISCC_SIM)) RISCC_LLVM_BIN=$(abspath $(LLVM_BIN)) $(PYTHON) tools/riscc_fuzz.py \
	  --family rc32 --config full --cores cached32-soft,cached32-dsp,cached32-agilex-soft,cached32-agilex-dsp \
	  --campaign $(FUZZ_SEEDS) $(FUZZ_SEED_ARGS) --jobs $(FUZZ_JOBS) --outdir build/fuzz/cached32

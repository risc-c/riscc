COMPILER_RULES := Makefile mk/compiler-tests.mk mk/firmware.mk mk/boards.mk

COMPILER_BUILD ?= build/compiler/rc16/$(PROFILE)
RC16_COMPILER_SOURCE_DIR := test/compiler/rc16
COMPILER_MAX_INSNS ?= 1000000
FLOAT_MAX_INSNS ?= 5000000
BENCHMARK_MAX_INSNS ?= 10000000
TERMINATE_MAX_INSNS ?= 256

COMPILER_SMOKE := $(COMPILER_BUILD)/smoke
COMPILER_SMOKE_OBJS := $(COMPILER_SMOKE).o $(COMPILER_BUILD)/helper.o
COMPILER_UART := $(COMPILER_BUILD)/smoke-uart
COMPILER_STDIO := $(COMPILER_BUILD)/stdio-smoke
COMPILER_ICEPI_SIM := $(COMPILER_BUILD)/icepi-rtlsim/Vicepi_zero_soc_sim
COMPILER_ATUM_SIM := $(COMPILER_BUILD)/atum-rtlsim/Vatum_a3_nano_soc_sim
COMPILER_IRQ := $(COMPILER_BUILD)/irq-smoke
COMPILER_IRQ_OBJS := $(COMPILER_IRQ).o $(COMPILER_IRQ)-main.o
COMPILER_IRQ_CUSTOM := $(COMPILER_BUILD)/irq-custom-smoke
FEATURE_MODULES := feature_main feature_language feature_integer \
	feature_builtins feature_memory feature_abi feature_abi_callee \
	feature_varargs feature_varargs_callee feature_tail
FLOAT_MODULES := float_main feature_float feature_float_callee
BENCHMARKS := int32 softfloat libm32 matrix structures
FEATURE_ASM_OBJ := $(COMPILER_BUILD)/features/feature_abi_asm.o
LIBC_TIME_TESTS_nano :=
LIBC_TIME_TESTS_min := time timer
LIBC_TIME_TESTS_sys := time timer
LIBC_TIME_TESTS_full := time timer
LIBC_TESTS := memory_string stdio bsp_stdio snprintf alloc integer math \
	clock $(LIBC_TIME_TESTS_$(PROFILE)) all
LIBC_BATCH_TESTS := $(filter-out stdio all,$(LIBC_TESTS))
LIBC_TERMINATE_TESTS := terminate_abort terminate_exit terminate__exit \
	terminate_assert
LIBC_ALL_TESTS := $(LIBC_TESTS) $(LIBC_TERMINATE_TESTS)
LIBM_TESTS := math math_extra
LIBC_TEST_HEADERS := test/compiler/libc/test.h $(LIBC_HEADERS)

.PRECIOUS: $(COMPILER_BUILD)/benchmarks/%.o \
	$(COMPILER_BUILD)/benchmarks/%.elf
# Smoke tests

.PHONY: compiler-smoke compiler-stdio

$(COMPILER_BUILD)/%.o: $(RC16_COMPILER_SOURCE_DIR)/%.c \
		$(RC16_COMPILER_SOURCE_DIR)/riscc_compiler_test.h $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_CFLAGS) \
	  -I$(RC16_COMPILER_SOURCE_DIR) -Ifirmware/include -c $< -o $@

$(COMPILER_BUILD)/%.bin: $(COMPILER_BUILD)/%.elf $(RISCC_OBJCOPY)
	$(RISCC_OBJCOPY) -O binary $< $@

$(COMPILER_UART).o: $(RC16_COMPILER_SOURCE_DIR)/smoke.c \
		$(RC16_COMPILER_SOURCE_DIR)/riscc_compiler_test.h firmware/include/stdio.h $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_CFLAGS) \
	  -DRISCC_COMPILER_UART -I$(RC16_COMPILER_SOURCE_DIR) -Ifirmware/include -c $< -o $@

$(COMPILER_SMOKE).elf: $(FW_VECTORS) $(FW_CRT0) \
		$(COMPILER_SMOKE_OBJS) $(FW_LIBS) \
		$(RISCC_LINKER_SCRIPT) $(RISCC_CLANG) $(RISCC_LLD)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_LDFLAGS) -fuse-ld=lld -nostdlib \
	  -Wl,-T,$(abspath $(RISCC_LINKER_SCRIPT)) \
	  -Wl,-Map,$(@:.elf=.map) \
	  $(FW_VECTORS) $(FW_CRT0) \
	  $(COMPILER_SMOKE_OBJS) $(FW_LIBS) -o $@

$(COMPILER_SMOKE).memh: $(COMPILER_SMOKE).bin tools/bin_to_memh.py
	$(PYTHON) tools/bin_to_memh.py $< -o $@

$(COMPILER_UART).elf: $(FW_VECTORS) $(FW_CRT0) \
		$(COMPILER_UART).o $(COMPILER_BUILD)/helper.o \
		$(FW_LIBS) $(RISCC_LINKER_SCRIPT) $(RISCC_CLANG) $(RISCC_LLD)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_LDFLAGS) -fuse-ld=lld -nostdlib \
	  -Wl,-T,$(abspath $(RISCC_LINKER_SCRIPT)) $(DEMO_LD_FLAGS) \
	  $(FW_VECTORS) $(FW_CRT0) \
	  $(COMPILER_UART).o $(COMPILER_BUILD)/helper.o \
	  $(FW_LIBS) -o $@

$(COMPILER_UART).memh: $(COMPILER_UART).bin tools/bin_to_memh.py
	$(PYTHON) tools/bin_to_memh.py $< -o $@ --depth 16384

$(COMPILER_STDIO).o: $(RC16_COMPILER_SOURCE_DIR)/stdio_smoke.c \
		firmware/include/stdio.h $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_CFLAGS) \
	  -Ifirmware/include -c $< -o $@

$(COMPILER_STDIO).elf: $(FW_VECTORS) $(FW_CRT0) \
		$(COMPILER_STDIO).o $(FW_LIBS) \
		$(RISCC_LINKER_SCRIPT) $(RISCC_CLANG) $(RISCC_LLD)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_LDFLAGS) -fuse-ld=lld -nostdlib \
	  -Wl,-T,$(abspath $(RISCC_LINKER_SCRIPT)) \
	  $(FW_VECTORS) $(FW_CRT0) \
	  $(COMPILER_STDIO).o $(FW_LIBS) -o $@

compiler-stdio: $(COMPILER_STDIO).bin $(RISCC_SIM)
	@mkdir -p $(COMPILER_BUILD)
	@printf 'Q' | $(RISCC_SIM) $(COMPILER_STDIO).bin --full --uart \
	  > $(COMPILER_STDIO)-uart.txt
	@test "$$(cat $(COMPILER_STDIO)-uart.txt)" = 'Q'
	@echo "Compiler stdio UART PASS"

# Interrupts

.PHONY: compiler-irqs

$(COMPILER_IRQ).o: $(RC16_COMPILER_SOURCE_DIR)/irq_smoke.c \
		firmware/include/riscc/interrupt.h $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_CFLAGS) \
	  -Ifirmware/include -c $< -o $@

$(COMPILER_IRQ)-main.o: $(RC16_COMPILER_SOURCE_DIR)/irq_smoke_main.S $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_ASFLAGS) -c $< -o $@

$(COMPILER_IRQ_CUSTOM).o: $(RC16_COMPILER_SOURCE_DIR)/irq_custom_vector.S $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_ASFLAGS) -c $< -o $@

$(COMPILER_IRQ).elf: $(FW_VECTORS) $(FW_CRT0) \
		$(COMPILER_IRQ_OBJS) \
		$(FW_LIBS) $(RISCC_LINKER_SCRIPT) $(RISCC_CLANG) $(RISCC_LLD)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_LDFLAGS) -fuse-ld=lld -nostdlib \
	  -Wl,-T,$(abspath $(RISCC_LINKER_SCRIPT)) \
	  -Wl,-Map,$(COMPILER_IRQ).map \
	  $(FW_VECTORS) $(FW_CRT0) \
	  $(COMPILER_IRQ_OBJS) $(FW_LIBS) -o $@

$(COMPILER_IRQ_CUSTOM).elf: $(FW_VECTORS) \
		$(FW_CRT0) $(COMPILER_IRQ_CUSTOM).o \
		$(FW_LIBS) $(RISCC_LINKER_SCRIPT) $(RISCC_CLANG) $(RISCC_LLD)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_LDFLAGS) -fuse-ld=lld -nostdlib \
	  -Wl,-T,$(abspath $(RISCC_LINKER_SCRIPT)) \
	  -Wl,-Map,$(COMPILER_IRQ_CUSTOM).map \
	  $(FW_VECTORS) $(FW_CRT0) \
	  $(COMPILER_IRQ_CUSTOM).o $(FW_LIBS) -o $@

compiler-irqs: $(COMPILER_SMOKE).elf $(COMPILER_IRQ).bin \
		$(COMPILER_IRQ_CUSTOM).bin build/test/rc16/native/full/16/tb \
		build/test/fast/async/soft/tb $(RISCC_SIM) \
		test/compiler/check_irq_linkage.py
	$(RISCC_SIM) $(COMPILER_IRQ).bin --full \
	  --max-insns $(COMPILER_MAX_INSNS)
	build/test/rc16/native/full/16/tb $(COMPILER_IRQ).bin \
	  --max-cycles 10000000
	build/test/fast/async/soft/tb $(COMPILER_IRQ).bin \
	  --max-cycles 1000000
	$(RISCC_SIM) $(COMPILER_IRQ_CUSTOM).bin --full \
	  --max-insns $(COMPILER_MAX_INSNS)
	build/test/rc16/native/full/16/tb $(COMPILER_IRQ_CUSTOM).bin \
	  --max-cycles 10000000
	build/test/fast/async/soft/tb $(COMPILER_IRQ_CUSTOM).bin \
	  --max-cycles 1000000
	$(PYTHON) test/compiler/check_irq_linkage.py \
	  --normal $(COMPILER_SMOKE).map \
	  --c-wrapper $(COMPILER_IRQ).map \
	  --custom $(COMPILER_IRQ_CUSTOM).map

# Board-level compiler tests

$(COMPILER_ICEPI_SIM): $(COMPILER_UART).memh $(ICEPI_SIM_RTL) \
		test/compiler/icepi_compiler_tb.cpp $(COMPILER_RULES)
	@mkdir -p $(@D)
	+$(VERILATOR) -cc --exe --build $(VERILATOR_MAKEFLAGS_ARG) \
	  --top-module icepi_zero_soc_sim --prefix Vicepi_zero_soc_sim \
	  -Mdir $(@D) $(ICEPI_CPU_DEFINES) -I$(abspath rtl) \
	  -GMEM_HEX='"$(abspath $(COMPILER_UART).memh)"' \
	  -CFLAGS "$(TB_CXXFLAGS)" -o Vicepi_zero_soc_sim \
	  $(abspath $(ICEPI_SIM_RTL)) $(abspath test/compiler/icepi_compiler_tb.cpp)

$(COMPILER_ATUM_SIM): $(COMPILER_UART).memh \
		$(ATUM_SIM_RTL) test/compiler/atum_uart_tb.cpp $(COMPILER_RULES)
	@mkdir -p $(@D)
	+$(VERILATOR) -cc --exe --build $(VERILATOR_MAKEFLAGS_ARG) \
	  --top-module atum_a3_nano_soc_sim --prefix Vatum_a3_nano_soc_sim \
	  -Mdir $(@D) -I$(abspath rtl) \
	  -GMEM_HEX='"$(abspath $(COMPILER_UART).memh)"' \
	  -CFLAGS "$(TB_CXXFLAGS)" -o Vatum_a3_nano_soc_sim \
	  $(abspath $(ATUM_SIM_RTL)) $(abspath test/compiler/atum_uart_tb.cpp)

compiler-smoke: $(COMPILER_SMOKE).bin $(COMPILER_SMOKE).memh $(RISCC_SIM) \
		build/test/rc16/native/full/16/tb build/test/fast/async/soft/tb \
		$(COMPILER_ICEPI_SIM) $(COMPILER_ATUM_SIM)
	$(RISCC_SIM) $(COMPILER_SMOKE).bin --full \
	  --max-insns $(COMPILER_MAX_INSNS)
	build/test/rc16/native/full/16/tb $(COMPILER_SMOKE).bin \
	  --max-cycles 10000000
	build/test/fast/async/soft/tb $(COMPILER_SMOKE).bin \
	  --max-cycles 1000000
	$(COMPILER_ICEPI_SIM)
	$(COMPILER_ATUM_SIM)

# Optimization matrix

.PHONY: compiler-smoke-matrix compiler-rc16-profile-rtl compiler-rc16-rtl

OPT_FLAGS_o0 := -O0
OPT_FLAGS_o2 := -O2
OPT_FLAGS_os := -Os
CFLAGS_NO_OPT := $(filter-out -O%,$(RISCC_CFLAGS))

.PRECIOUS: $(COMPILER_BUILD)/matrix/%/smoke.o \
	$(COMPILER_BUILD)/matrix/%/helper.o \
	$(COMPILER_BUILD)/matrix/%/smoke.elf

$(COMPILER_BUILD)/matrix/%/smoke.o: $(RC16_COMPILER_SOURCE_DIR)/smoke.c \
		$(RC16_COMPILER_SOURCE_DIR)/riscc_compiler_test.h $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(CFLAGS_NO_OPT) \
	  $(OPT_FLAGS_$*) -I$(RC16_COMPILER_SOURCE_DIR) -Ifirmware/include -c $< -o $@

$(COMPILER_BUILD)/matrix/%/helper.o: $(RC16_COMPILER_SOURCE_DIR)/helper.c \
		$(RC16_COMPILER_SOURCE_DIR)/riscc_compiler_test.h $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(CFLAGS_NO_OPT) \
	  $(OPT_FLAGS_$*) -I$(RC16_COMPILER_SOURCE_DIR) -Ifirmware/include -c $< -o $@

$(COMPILER_BUILD)/matrix/%/smoke.elf: $(FW_VECTORS) \
		$(FW_CRT0) \
		$(COMPILER_BUILD)/matrix/%/smoke.o \
		$(COMPILER_BUILD)/matrix/%/helper.o \
		$(FW_LIBS) $(RISCC_LINKER_SCRIPT) $(RISCC_CLANG) $(RISCC_LLD)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_LDFLAGS) -fuse-ld=lld -nostdlib \
	  -Wl,-T,$(abspath $(RISCC_LINKER_SCRIPT)) \
	  $(FW_VECTORS) $(FW_CRT0) \
	  $(COMPILER_BUILD)/matrix/$*/smoke.o \
	  $(COMPILER_BUILD)/matrix/$*/helper.o \
	  $(FW_LIBS) -o $@

COMPILER_SMOKE_MATRIX_RUNS := $(addprefix compiler-smoke-matrix-run-,$(OPT_LEVELS))
.PHONY: $(COMPILER_SMOKE_MATRIX_RUNS)

compiler-smoke-matrix: $(COMPILER_SMOKE_MATRIX_RUNS)

define COMPILER_SMOKE_MATRIX_RUN_RULE
compiler-smoke-matrix-run-$(1): \
		$$(COMPILER_BUILD)/matrix/$(1)/smoke.bin $$(RISCC_SIM)
	$$(RISCC_SIM) $$(COMPILER_BUILD)/matrix/$(1)/smoke.bin \
	  $$(SIM_PROFILE_FLAGS) --max-insns $$(COMPILER_MAX_INSNS)
endef

$(foreach opt,$(OPT_LEVELS), \
	$(eval $(call COMPILER_SMOKE_MATRIX_RUN_RULE,$(opt))))
# C and ABI features

.PHONY: compiler-features compiler-features-rtl

$(FEATURE_ASM_OBJ): $(RC16_COMPILER_SOURCE_DIR)/feature_abi_asm.S \
		$(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_ASFLAGS) -c $< -o $@

feature_objects = $(addprefix $(COMPILER_BUILD)/features/$(1)/, \
	$(addsuffix .o,$(FEATURE_MODULES)))

# FEATURE_RULES(optimization)
define FEATURE_RULES
$$(call feature_objects,$(1)): \
		$$(COMPILER_BUILD)/features/$(1)/%.o: $$(RC16_COMPILER_SOURCE_DIR)/%.c \
		$$(RC16_COMPILER_SOURCE_DIR)/riscc_compiler_features.h $$(RISCC_CLANG)
	@mkdir -p $$(@D)
	$$(RISCC_CLANG) $$(RISCC_TARGET_FLAGS) $$(CFLAGS_NO_OPT) \
	  $$(OPT_FLAGS_$(1)) -std=c11 -I$$(RC16_COMPILER_SOURCE_DIR) \
	  -Ifirmware/include -c $$< -o $$@

$$(COMPILER_BUILD)/features/$(1)/features.elf: \
		$$(FW_VECTORS) $$(FW_CRT0) \
		$$(call feature_objects,$(1)) \
		$$(FEATURE_ASM_OBJ) $$(FW_LIBS) \
		$$(RISCC_LINKER_SCRIPT) $$(RISCC_CLANG) $$(RISCC_LLD)
	@mkdir -p $$(@D)
	$$(RISCC_CLANG) $$(RISCC_TARGET_FLAGS) $$(RISCC_LDFLAGS) \
	  -fuse-ld=lld -nostdlib -Wl,-T,$$(abspath $$(RISCC_LINKER_SCRIPT)) \
	  $$(FW_VECTORS) $$(FW_CRT0) \
	  $$(call feature_objects,$(1)) \
	  $$(FEATURE_ASM_OBJ) $$(FW_LIBS) -o $$@

endef

$(foreach opt,$(OPT_LEVELS),$(eval $(call FEATURE_RULES,$(opt))))

FEATURE_BINS := $(foreach opt,$(OPT_LEVELS), \
	$(COMPILER_BUILD)/features/$(opt)/features.bin)

COMPILER_FEATURE_RUNS := $(addprefix compiler-features-run-,$(OPT_LEVELS))
.PHONY: $(COMPILER_FEATURE_RUNS)

compiler-features: $(COMPILER_FEATURE_RUNS)

define COMPILER_FEATURE_RUN_RULE
compiler-features-run-$(1): \
		$$(COMPILER_BUILD)/features/$(1)/features.bin $$(RISCC_SIM)
	$$(RISCC_SIM) $$(COMPILER_BUILD)/features/$(1)/features.bin \
	  $$(SIM_PROFILE_FLAGS) --max-insns $$(COMPILER_MAX_INSNS)
endef

$(foreach opt,$(OPT_LEVELS),$(eval $(call COMPILER_FEATURE_RUN_RULE,$(opt))))

# Execute the compiler-generated startup/TLS smoke and focused C/ABI programs
# on the matching full-width RC16 Min or Sys RTL.  The ordinary core, ISA, and
# fuzz matrices cover the sliced implementations; this matrix is specifically
# the compiler/profile integration gate.
RC16_COMPILER_PROFILES := min sys
RC16_COMPILER_RTL_WIDTH ?= 16
RC16_COMPILER_RTL_MAX_CYCLES ?= 30000000
RC16_COMPILER_RTL_TB = \
	build/test/rc16/native/$(PROFILE)/$(RC16_COMPILER_RTL_WIDTH)/tb
RC16_COMPILER_SMOKE_BINS = $(foreach opt,$(OPT_LEVELS), \
	$(COMPILER_BUILD)/matrix/$(opt)/smoke.bin)

RC16_COMPILER_RTL_RUNS := \
	$(addprefix compiler-rc16-profile-rtl-smoke-,$(OPT_LEVELS)) \
	$(addprefix compiler-rc16-profile-rtl-features-,$(OPT_LEVELS))
.PHONY: $(RC16_COMPILER_RTL_RUNS)

compiler-rc16-profile-rtl: $(RC16_COMPILER_RTL_RUNS)

define RC16_COMPILER_RTL_RUN_RULE
compiler-rc16-profile-rtl-smoke-$(1): \
		$$(COMPILER_BUILD)/matrix/$(1)/smoke.bin $$(RC16_COMPILER_RTL_TB)
	$$(RC16_COMPILER_RTL_TB) $$(COMPILER_BUILD)/matrix/$(1)/smoke.bin \
	  --max-cycles $$(RC16_COMPILER_RTL_MAX_CYCLES)

compiler-rc16-profile-rtl-features-$(1): \
		$$(COMPILER_BUILD)/features/$(1)/features.bin $$(RC16_COMPILER_RTL_TB)
	$$(RC16_COMPILER_RTL_TB) $$(COMPILER_BUILD)/features/$(1)/features.bin \
	  --max-cycles $$(RC16_COMPILER_RTL_MAX_CYCLES)
endef

$(foreach opt,$(OPT_LEVELS),$(eval $(call RC16_COMPILER_RTL_RUN_RULE,$(opt))))

RC16_COMPILER_PROFILE_RUNS := \
	$(addprefix compiler-rc16-rtl-profile-,$(RC16_COMPILER_PROFILES))
.PHONY: compiler-rc16-rtl $(RC16_COMPILER_PROFILE_RUNS)

compiler-rc16-rtl: $(RC16_COMPILER_PROFILE_RUNS)

define RC16_COMPILER_PROFILE_RUN_RULE
compiler-rc16-rtl-profile-$(1): llvm-riscc
	+$$(MAKE) --no-print-directory RISCC_TOOLCHAIN_READY=1 PROFILE=$(1) \
	  compiler-smoke-matrix compiler-features compiler-rc16-profile-rtl \
	  compiler-c-abi-profile
endef

$(foreach profile,$(RC16_COMPILER_PROFILES), \
	$(eval $(call RC16_COMPILER_PROFILE_RUN_RULE,$(profile))))

# Focused RC32 C/C++ and ABI integration matrix. RC16 and RC32 use peer source,
# runtime, and output directories because their objects are link-incompatible.
RC32_COMPILER_PROFILES := min sys full
RC32_COMPILER_BUILD = build/compiler/rc32/$(PROFILE)
RC32_COMPILER_TARGET_FLAGS = --target=riscc-none-elf -mcpu=$(PROFILE) -mrc32
RC32_COMPILER_CFLAGS = $(CFLAGS_NO_OPT) -Itest/compiler/rc32 -Ifirmware/include
RC32_COMPILER_MODULES := main helper builtins float tail
RC32_COMPILER_MAX_INSNS ?= 1000000
RC32_COMPILER_MAX_CYCLES ?= 30000000
RC32_COMPILER_TB = build/test/rc32/$(PROFILE)/16/tb
RC32_SIM_FLAGS_min := --rc32
RC32_SIM_FLAGS_sys := --rc32-sys
RC32_SIM_FLAGS_full := --rc32-full
RC32_COMPILER_IRQ := $(RC32_COMPILER_BUILD)/irq-smoke
RC32_COMPILER_IRQ_OBJS := $(RC32_COMPILER_IRQ).o \
	$(RC32_COMPILER_IRQ)-main.o

rc32_compiler_objects = $(addprefix $(RC32_COMPILER_BUILD)/$(1)/, \
	$(addsuffix .o,$(RC32_COMPILER_MODULES))) \
	$(RC32_COMPILER_BUILD)/$(1)/cpp.o \
	$(RC32_COMPILER_BUILD)/$(1)/memory.o

$(RC32_COMPILER_BUILD)/start.o: \
		test/compiler/rc32/start.S $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RC32_COMPILER_TARGET_FLAGS) $(RISCC_ASFLAGS) \
	  -c $< -o $@

# RC32_COMPILER_RULES(optimization)
define RC32_COMPILER_RULES
$$(addprefix $$(RC32_COMPILER_BUILD)/$(1)/, \
	$$(addsuffix .o,$$(RC32_COMPILER_MODULES))): \
		$$(RC32_COMPILER_BUILD)/$(1)/%.o: test/compiler/rc32/%.c \
		test/compiler/rc32/test.h $$(RISCC_CLANG)
	@mkdir -p $$(@D)
	$$(RISCC_CLANG) $$(RC32_COMPILER_TARGET_FLAGS) \
	  $$(RC32_COMPILER_CFLAGS) $$(OPT_FLAGS_$(1)) \
	  -std=c11 -c $$< -o $$@

$$(RC32_COMPILER_BUILD)/$(1)/cpp.o: \
		test/compiler/rc32/cpp.cpp \
		test/compiler/rc32/test.h $$(RISCC_CLANG)
	@mkdir -p $$(@D)
	$$(RISCC_CLANG) $$(RC32_COMPILER_TARGET_FLAGS) \
	  $$(RC32_COMPILER_CFLAGS) $$(OPT_FLAGS_$(1)) -std=c++17 \
	  -fno-exceptions -fno-rtti -fno-threadsafe-statics -c $$< -o $$@

$$(RC32_COMPILER_BUILD)/$(1)/memory.o: firmware/libc/memory.c \
		$$(RISCC_CLANG)
	@mkdir -p $$(@D)
	$$(RISCC_CLANG) $$(RC32_COMPILER_TARGET_FLAGS) \
	  $$(RC32_COMPILER_CFLAGS) $$(OPT_FLAGS_$(1)) -c $$< -o $$@

$$(RC32_COMPILER_BUILD)/$(1)/program.elf: \
		$$(RC32_COMPILER_BUILD)/start.o \
		$$(call rc32_compiler_objects,$(1)) \
		test/compiler/rc32/link.ld $$(BUILTINS_LIB) \
		$$(RISCC_CLANG) $$(RISCC_LLD)
	$$(RISCC_CLANG) $$(RC32_COMPILER_TARGET_FLAGS) -fuse-ld=lld -nostdlib \
	  -Wl,--gc-sections \
	  -Wl,-T,$$(abspath test/compiler/rc32/link.ld) \
	  $$(RC32_COMPILER_BUILD)/start.o \
	  $$(call rc32_compiler_objects,$(1)) $$(BUILTINS_LIB) -o $$@

$$(RC32_COMPILER_BUILD)/$(1)/program.bin: \
		$$(RC32_COMPILER_BUILD)/$(1)/program.elf $$(RISCC_OBJCOPY)
	$$(RISCC_OBJCOPY) -O binary $$< $$@

endef

$(foreach opt,$(OPT_LEVELS),$(eval $(call RC32_COMPILER_RULES,$(opt))))

RC32_COMPILER_BINS = $(foreach opt,$(OPT_LEVELS), \
	$(RC32_COMPILER_BUILD)/$(opt)/program.bin)

RC32_COMPILER_RUNS := \
	$(addprefix compiler-rc32-profile-iss-,$(OPT_LEVELS)) \
	$(addprefix compiler-rc32-profile-rtl-,$(OPT_LEVELS))
.PHONY: compiler-rc32-profile compiler-rc32 $(RC32_COMPILER_RUNS)

compiler-rc32-profile: $(RC32_COMPILER_RUNS)

define RC32_COMPILER_RUN_RULE
compiler-rc32-profile-iss-$(1): \
		$$(RC32_COMPILER_BUILD)/$(1)/program.bin $$(RISCC_SIM)
	$$(RISCC_SIM) $$(RC32_COMPILER_BUILD)/$(1)/program.bin \
	  $$(RC32_SIM_FLAGS_$$(PROFILE)) --max-insns $$(RC32_COMPILER_MAX_INSNS)

compiler-rc32-profile-rtl-$(1): \
		$$(RC32_COMPILER_BUILD)/$(1)/program.bin $$(RC32_COMPILER_TB)
	$$(RC32_COMPILER_TB) $$(RC32_COMPILER_BUILD)/$(1)/program.bin \
	  --max-cycles $$(RC32_COMPILER_MAX_CYCLES)
endef

$(foreach opt,$(OPT_LEVELS),$(eval $(call RC32_COMPILER_RUN_RULE,$(opt))))

RC32_COMPILER_PROFILE_RUNS := \
	$(addprefix compiler-rc32-run-profile-,$(RC32_COMPILER_PROFILES))
.PHONY: $(RC32_COMPILER_PROFILE_RUNS)

compiler-rc32: $(RC32_COMPILER_PROFILE_RUNS)

define RC32_COMPILER_PROFILE_RUN_RULE
compiler-rc32-run-profile-$(1): llvm-riscc
	+$$(MAKE) --no-print-directory RISCC_TOOLCHAIN_READY=1 \
	  RISCC_XLEN=32 PROFILE=$(1) \
	  compiler-rc32-profile compiler-c-abi-profile
endef

$(foreach profile,$(RC32_COMPILER_PROFILES), \
	$(eval $(call RC32_COMPILER_PROFILE_RUN_RULE,$(profile))))

# RC32 C IRQ-wrapper ABI smoke.  Sys and Full are the interrupt-capable
# profiles; run both through the ISS and the matching 16-slice RTL core.
.PHONY: compiler-rc32-irqs compiler-rc32-irq-profile \
	compiler-rc32-irq-sys compiler-rc32-irq-full

$(RC32_COMPILER_IRQ).o: test/compiler/rc32/irq_smoke.c \
		firmware/include/riscc/interrupt.h $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RC32_COMPILER_TARGET_FLAGS) $(RC32_COMPILER_CFLAGS) \
	  -Ifirmware/include -c $< -o $@

$(RC32_COMPILER_IRQ)-main.o: test/compiler/rc32/irq_smoke_main.S $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RC32_COMPILER_TARGET_FLAGS) $(RISCC_ASFLAGS) -c $< -o $@

$(RC32_COMPILER_IRQ).elf: $(FW_VECTORS) $(FW_CRT0) \
		$(RC32_COMPILER_IRQ_OBJS) $(FW_LIBS) \
		$(RISCC_LINKER_SCRIPT) $(RISCC_CLANG) $(RISCC_LLD)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RC32_COMPILER_TARGET_FLAGS) $(RISCC_LDFLAGS) \
	  -fuse-ld=lld -nostdlib -Wl,-T,$(abspath $(RISCC_LINKER_SCRIPT)) \
	  -Wl,-Map,$(RC32_COMPILER_IRQ).map \
	  $(FW_VECTORS) $(FW_CRT0) $(RC32_COMPILER_IRQ_OBJS) $(FW_LIBS) -o $@

$(RC32_COMPILER_IRQ).bin: $(RC32_COMPILER_IRQ).elf $(RISCC_OBJCOPY)
	$(RISCC_OBJCOPY) -O binary $< $@

compiler-rc32-irq-profile: $(RC32_COMPILER_IRQ).bin $(RISCC_SIM) \
		$(RC32_COMPILER_TB)
	$(RISCC_SIM) $(RC32_COMPILER_IRQ).bin $(RC32_SIM_FLAGS_$(PROFILE)) \
	  --max-insns $(COMPILER_MAX_INSNS)
	$(RC32_COMPILER_TB) $(RC32_COMPILER_IRQ).bin --max-cycles 10000000

define RC32_COMPILER_IRQ_PROFILE_RULE
compiler-rc32-irq-$(1): llvm-riscc
	+$$(MAKE) --no-print-directory RISCC_TOOLCHAIN_READY=1 \
	  RISCC_XLEN=32 PROFILE=$(1) \
	  compiler-rc32-irq-profile
endef

$(foreach profile,sys full, \
	$(eval $(call RC32_COMPILER_IRQ_PROFILE_RULE,$(profile))))

compiler-rc32-irqs: compiler-rc32-irq-sys compiler-rc32-irq-full

# Portable C language and ABI coverage shared by RC16 and RC32.  Keep this
# separate from the architecture-specific programs above: it catches codegen
# regressions that affect either data width without duplicating test sources.
C_ABI_COMPILER_SOURCE_DIR := test/compiler/c_abi
C_ABI_COMPILER_BUILD = build/compiler/c-abi/$(RISCC_ARCH)/$(PROFILE)
C_ABI_COMPILER_MODULES := c_abi_main c_abi_helper
C_ABI_COMPILER_MAX_INSNS ?= 1000000
C_ABI_COMPILER_MAX_CYCLES ?= 30000000
C_ABI_RC16_TB = build/test/rc16/native/$(PROFILE)/16/tb
C_ABI_RC32_TB = build/test/rc32/$(PROFILE)/16/tb
ifeq ($(RISCC_XLEN),32)
C_ABI_COMPILER_TB = $(C_ABI_RC32_TB)
else
C_ABI_COMPILER_TB = $(C_ABI_RC16_TB)
endif

c_abi_compiler_objects = $(addprefix $(C_ABI_COMPILER_BUILD)/$(1)/, \
	$(addsuffix .o,$(C_ABI_COMPILER_MODULES)))

# C_ABI_COMPILER_RULES(optimization)
define C_ABI_COMPILER_RULES
$$(call c_abi_compiler_objects,$(1)): \
		$$(C_ABI_COMPILER_BUILD)/$(1)/%.o: \
		$$(C_ABI_COMPILER_SOURCE_DIR)/%.c \
		$$(C_ABI_COMPILER_SOURCE_DIR)/c_abi.h $$(RISCC_CLANG)
	@mkdir -p $$(@D)
	$$(RISCC_CLANG) $$(RISCC_TARGET_FLAGS) $$(CFLAGS_NO_OPT) \
	  $$(OPT_FLAGS_$(1)) -std=c11 -I$$(C_ABI_COMPILER_SOURCE_DIR) \
	  -c $$< -o $$@

$$(C_ABI_COMPILER_BUILD)/$(1)/c_abi.elf: \
		$$(FW_VECTORS) $$(FW_CRT0) \
		$$(call c_abi_compiler_objects,$(1)) $$(FW_LIBS) \
		$$(RISCC_LINKER_SCRIPT) $$(RISCC_CLANG) $$(RISCC_LLD)
	@mkdir -p $$(@D)
	$$(RISCC_CLANG) $$(RISCC_TARGET_FLAGS) $$(RISCC_LDFLAGS) \
	  -fuse-ld=lld -nostdlib -Wl,-T,$$(abspath $$(RISCC_LINKER_SCRIPT)) \
	  $$(FW_VECTORS) $$(FW_CRT0) \
	  $$(call c_abi_compiler_objects,$(1)) $$(FW_LIBS) -o $$@

$$(C_ABI_COMPILER_BUILD)/$(1)/c_abi.bin: \
		$$(C_ABI_COMPILER_BUILD)/$(1)/c_abi.elf $$(RISCC_OBJCOPY)
	$$(RISCC_OBJCOPY) -O binary $$< $$@
endef

$(foreach opt,$(OPT_LEVELS),$(eval $(call C_ABI_COMPILER_RULES,$(opt))))

C_ABI_COMPILER_BINS = $(foreach opt,$(OPT_LEVELS), \
	$(C_ABI_COMPILER_BUILD)/$(opt)/c_abi.bin)

C_ABI_COMPILER_RUNS := \
	$(addprefix compiler-c-abi-profile-iss-,$(OPT_LEVELS)) \
	$(addprefix compiler-c-abi-profile-rtl-,$(OPT_LEVELS))
.PHONY: compiler-c-abi-profile compiler-c-abi $(C_ABI_COMPILER_RUNS)

compiler-c-abi-profile: $(C_ABI_COMPILER_RUNS)

define C_ABI_COMPILER_RUN_RULE
compiler-c-abi-profile-iss-$(1): \
		$$(C_ABI_COMPILER_BUILD)/$(1)/c_abi.bin $$(RISCC_SIM)
	$$(RISCC_SIM) $$(C_ABI_COMPILER_BUILD)/$(1)/c_abi.bin \
	  $$(SIM_PROFILE_FLAGS) --max-insns $$(C_ABI_COMPILER_MAX_INSNS)

compiler-c-abi-profile-rtl-$(1): \
		$$(C_ABI_COMPILER_BUILD)/$(1)/c_abi.bin $$(C_ABI_COMPILER_TB)
	$$(C_ABI_COMPILER_TB) $$(C_ABI_COMPILER_BUILD)/$(1)/c_abi.bin \
	  --max-cycles $$(C_ABI_COMPILER_MAX_CYCLES)
endef

$(foreach opt,$(OPT_LEVELS),$(eval $(call C_ABI_COMPILER_RUN_RULE,$(opt))))

C_ABI_COMPILER_PROFILE_RUNS := \
	$(addprefix compiler-c-abi-rc16-,min sys full) \
	$(addprefix compiler-c-abi-rc32-,$(RC32_COMPILER_PROFILES))
.PHONY: $(C_ABI_COMPILER_PROFILE_RUNS)

compiler-c-abi: $(C_ABI_COMPILER_PROFILE_RUNS)

define C_ABI_COMPILER_PROFILE_RUN_RULE
compiler-c-abi-rc$(1)-$(2): llvm-riscc
	+$$(MAKE) --no-print-directory RISCC_TOOLCHAIN_READY=1 \
	  RISCC_XLEN=$(1) PROFILE=$(2) \
	  compiler-c-abi-profile
endef

$(foreach profile,min sys full, \
	$(eval $(call C_ABI_COMPILER_PROFILE_RUN_RULE,16,$(profile))))
$(foreach profile,$(RC32_COMPILER_PROFILES), \
	$(eval $(call C_ABI_COMPILER_PROFILE_RUN_RULE,32,$(profile))))

# Portable freestanding C++ coverage. The runtime supports ordinary C++17
# code that needs no language runtime: trivial classes and aggregates,
# constant initialization, and cross-translation-unit calls. Dynamic startup
# constructors are rejected by the linker scripts and tested below.
CPP_COMPILER_SOURCE_DIR := test/compiler/cpp
CPP_COMPILER_BUILD = build/compiler/cpp/$(RISCC_ARCH)/$(PROFILE)
CPP_COMPILER_MODULES := cpp_main cpp_helper
CPP_COMPILER_MAX_INSNS ?= 1000000
CPP_COMPILER_MAX_CYCLES ?= 30000000
ifeq ($(RISCC_XLEN),32)
CPP_COMPILER_TB = build/test/rc32/$(PROFILE)/16/tb
else ifeq ($(PROFILE),nano)
CPP_COMPILER_TB = build/test/nano/tb
else
CPP_COMPILER_TB = build/test/rc16/native/$(PROFILE)/16/tb
endif

cpp_compiler_objects = $(addprefix $(CPP_COMPILER_BUILD)/$(1)/, \
	$(addsuffix .o,$(CPP_COMPILER_MODULES)))

# CPP_COMPILER_RULES(optimization)
define CPP_COMPILER_RULES
$$(call cpp_compiler_objects,$(1)): \
		$$(CPP_COMPILER_BUILD)/$(1)/%.o: \
		$$(CPP_COMPILER_SOURCE_DIR)/%.cpp \
		$$(CPP_COMPILER_SOURCE_DIR)/cpp_test.h $$(RISCC_CLANG)
	@mkdir -p $$(@D)
	$$(RISCC_CLANG) $$(RISCC_TARGET_FLAGS) \
	  $$(filter-out -O%,$$(RISCC_CXXFLAGS)) $$(OPT_FLAGS_$(1)) \
	  -I$$(CPP_COMPILER_SOURCE_DIR) -c $$< -o $$@

$$(CPP_COMPILER_BUILD)/$(1)/cpp.elf: \
		$$(FW_VECTORS) $$(FW_CRT0) \
		$$(call cpp_compiler_objects,$(1)) $$(FW_LIBS) \
		$$(RISCC_LINKER_SCRIPT) $$(RISCC_CLANG) $$(RISCC_LLD)
	@mkdir -p $$(@D)
	$$(RISCC_CLANG) $$(RISCC_TARGET_FLAGS) $$(RISCC_LDFLAGS) \
	  -fuse-ld=lld -nostdlib -Wl,-T,$$(abspath $$(RISCC_LINKER_SCRIPT)) \
	  $$(FW_VECTORS) $$(FW_CRT0) \
	  $$(call cpp_compiler_objects,$(1)) $$(FW_LIBS) -o $$@

$$(CPP_COMPILER_BUILD)/$(1)/cpp.bin: \
		$$(CPP_COMPILER_BUILD)/$(1)/cpp.elf $$(RISCC_OBJCOPY)
	$$(RISCC_OBJCOPY) -O binary $$< $$@
endef

$(foreach opt,$(OPT_LEVELS),$(eval $(call CPP_COMPILER_RULES,$(opt))))

CPP_COMPILER_RUNS := \
	$(addprefix compiler-cpp-profile-iss-,$(OPT_LEVELS)) \
	$(addprefix compiler-cpp-profile-rtl-,$(OPT_LEVELS))
.PHONY: compiler-cpp-profile compiler-cpp-constructor-policy \
	compiler-cpp $(CPP_COMPILER_RUNS)

compiler-cpp-profile: $(CPP_COMPILER_RUNS) compiler-cpp-constructor-policy

define CPP_COMPILER_RUN_RULE
compiler-cpp-profile-iss-$(1): \
		$$(CPP_COMPILER_BUILD)/$(1)/cpp.bin $$(RISCC_SIM)
	$$(RISCC_SIM) $$(CPP_COMPILER_BUILD)/$(1)/cpp.bin \
	  $$(SIM_PROFILE_FLAGS) --max-insns $$(CPP_COMPILER_MAX_INSNS)

compiler-cpp-profile-rtl-$(1): \
		$$(CPP_COMPILER_BUILD)/$(1)/cpp.bin $$(CPP_COMPILER_TB)
	$$(CPP_COMPILER_TB) $$(CPP_COMPILER_BUILD)/$(1)/cpp.bin \
	  --max-cycles $$(CPP_COMPILER_MAX_CYCLES)
endef

$(foreach opt,$(OPT_LEVELS),$(eval $(call CPP_COMPILER_RUN_RULE,$(opt))))

$(CPP_COMPILER_BUILD)/dynamic-constructor.o: \
		$(CPP_COMPILER_SOURCE_DIR)/dynamic_constructor.cpp $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_CXXFLAGS) -c $< -o $@

compiler-cpp-constructor-policy: \
		$(CPP_COMPILER_BUILD)/dynamic-constructor.o \
		$(call cpp_compiler_objects,os) $(FW_VECTORS) $(FW_CRT0) $(FW_LIBS) \
		$(RISCC_LINKER_SCRIPT) $(RISCC_CLANG) $(RISCC_LLD)
	@mkdir -p $(CPP_COMPILER_BUILD)
	@log=$(CPP_COMPILER_BUILD)/dynamic-constructor.log; \
	if $(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_LDFLAGS) \
	     -fuse-ld=lld -nostdlib -Wl,-T,$(abspath $(RISCC_LINKER_SCRIPT)) \
	     $(FW_VECTORS) $(FW_CRT0) $(call cpp_compiler_objects,os) \
	     $(CPP_COMPILER_BUILD)/dynamic-constructor.o $(FW_LIBS) \
	     -o $(CPP_COMPILER_BUILD)/dynamic-constructor.elf >$$log 2>&1; then \
	  echo 'dynamic C++ constructor unexpectedly linked'; cat $$log; exit 1; \
	fi; \
	grep -q 'does not support dynamic C++ constructors' $$log || \
	  { cat $$log; exit 1; }
	@echo "$(RISCC_ARCH) $(PROFILE) C++ constructor policy PASS"

CPP_COMPILER_PROFILE_RUNS := \
	$(addprefix compiler-cpp-rc16-,nano min sys full) \
	$(addprefix compiler-cpp-rc32-,$(RC32_COMPILER_PROFILES))
.PHONY: $(CPP_COMPILER_PROFILE_RUNS)

compiler-cpp: $(CPP_COMPILER_PROFILE_RUNS)

define CPP_COMPILER_PROFILE_RUN_RULE
compiler-cpp-rc$(1)-$(2): llvm-riscc
	+$$(MAKE) --no-print-directory RISCC_TOOLCHAIN_READY=1 \
	  RISCC_XLEN=$(1) PROFILE=$(2) \
	  compiler-cpp-profile
endef

$(foreach profile,nano min sys full, \
	$(eval $(call CPP_COMPILER_PROFILE_RUN_RULE,16,$(profile))))
$(foreach profile,$(RC32_COMPILER_PROFILES), \
	$(eval $(call CPP_COMPILER_PROFILE_RUN_RULE,32,$(profile))))

# Benchmarks

.PHONY: compiler-benchmarks

benchmark_bins = $(addprefix $(COMPILER_BUILD)/benchmarks/$(1)/, \
	$(addsuffix .bin,$(BENCHMARKS)))

# BENCHMARK_RULES(optimization)
define BENCHMARK_RULES
$$(COMPILER_BUILD)/benchmarks/$(1)/%.o: \
		test/compiler/bench/%.c test/compiler/bench/bench.h $$(RISCC_CLANG)
	@mkdir -p $$(@D)
	$$(RISCC_CLANG) $$(RISCC_TARGET_FLAGS) $$(CFLAGS_NO_OPT) \
	  $$(OPT_FLAGS_$(1)) -std=c11 -Itest/compiler/bench \
	  -Ifirmware/include -c $$< -o $$@

$$(COMPILER_BUILD)/benchmarks/$(1)/%.elf: \
		$$(FW_VECTORS) $$(FW_CRT0) \
		$$(COMPILER_BUILD)/benchmarks/$(1)/%.o \
		$$(FW_LIBS) $$(RISCC_LINKER_SCRIPT) \
		$$(RISCC_CLANG) $$(RISCC_LLD)
	$$(RISCC_CLANG) $$(RISCC_TARGET_FLAGS) $$(RISCC_LDFLAGS) \
	  -fuse-ld=lld -nostdlib -Wl,-T,$$(abspath $$(RISCC_LINKER_SCRIPT)) \
	  $$(FW_VECTORS) $$(FW_CRT0) \
	  $$(patsubst %.elf,%.o,$$@) \
	  $$(FW_LIBS) -o $$@

endef

$(foreach opt,$(BENCH_OPT_LEVELS),$(eval $(call BENCHMARK_RULES,$(opt))))

BENCHMARK_BINS := $(foreach opt,$(BENCH_OPT_LEVELS), \
	$(call benchmark_bins,$(opt)))

compiler-benchmarks: $(BENCHMARK_BINS) $(RISCC_SIM)
	@for opt in $(BENCH_OPT_LEVELS); do \
	  for benchmark in $(BENCHMARKS); do \
	    echo "RISCC benchmark $$opt: $$benchmark"; \
	    $(RISCC_SIM) \
	      "$(COMPILER_BUILD)/benchmarks/$$opt/$$benchmark.bin" \
	      $(SIM_PROFILE_FLAGS) \
	      --max-insns $(BENCHMARK_MAX_INSNS) || exit; \
	  done; \
	done

# Floating point

.PHONY: compiler-float compiler-profiles

float_objects = $(addprefix $(COMPILER_BUILD)/float/$(1)/, \
	$(addsuffix .o,$(FLOAT_MODULES)))

# FLOAT_RULES(optimization)
define FLOAT_RULES
$$(call float_objects,$(1)): \
		$$(COMPILER_BUILD)/float/$(1)/%.o: $$(RC16_COMPILER_SOURCE_DIR)/%.c \
		$$(RC16_COMPILER_SOURCE_DIR)/riscc_compiler_features.h $$(RISCC_CLANG)
	@mkdir -p $$(@D)
	$$(RISCC_CLANG) $$(RISCC_TARGET_FLAGS) $$(CFLAGS_NO_OPT) \
	  $$(OPT_FLAGS_$(1)) -std=c11 -I$$(RC16_COMPILER_SOURCE_DIR) \
	  -Ifirmware/include -c $$< -o $$@

$$(COMPILER_BUILD)/float/$(1)/float.elf: \
		$$(FW_VECTORS) $$(FW_CRT0) \
		$$(call float_objects,$(1)) \
		$$(FW_LIBS) $$(RISCC_LINKER_SCRIPT) \
		$$(RISCC_CLANG) $$(RISCC_LLD)
	@mkdir -p $$(@D)
	$$(RISCC_CLANG) $$(RISCC_TARGET_FLAGS) $$(RISCC_LDFLAGS) \
	  -fuse-ld=lld -nostdlib -Wl,-T,$$(abspath $$(RISCC_LINKER_SCRIPT)) \
	  $$(FW_VECTORS) $$(FW_CRT0) \
	  $$(call float_objects,$(1)) \
	  $$(FW_LIBS) -o $$@

endef

$(foreach opt,$(OPT_LEVELS),$(eval $(call FLOAT_RULES,$(opt))))

FLOAT_BINS := $(foreach opt,$(OPT_LEVELS), \
	$(COMPILER_BUILD)/float/$(opt)/float.bin)

COMPILER_FLOAT_RUNS := $(addprefix compiler-float-run-,$(OPT_LEVELS))
COMPILER_FEATURE_RTL_RUNS := $(addprefix compiler-features-rtl-run-,$(OPT_LEVELS))
.PHONY: $(COMPILER_FLOAT_RUNS) $(COMPILER_FEATURE_RTL_RUNS)

compiler-float: $(COMPILER_FLOAT_RUNS)
compiler-features-rtl: $(COMPILER_FEATURE_RTL_RUNS)

define COMPILER_FLOAT_RUN_RULE
compiler-float-run-$(1): \
		$$(COMPILER_BUILD)/float/$(1)/float.bin $$(RISCC_SIM)
	$$(RISCC_SIM) $$(COMPILER_BUILD)/float/$(1)/float.bin \
	  $$(SIM_PROFILE_FLAGS) --max-insns $$(FLOAT_MAX_INSNS)

compiler-features-rtl-run-$(1): \
		$$(COMPILER_BUILD)/features/$(1)/features.bin build/test/nano/tb
	build/test/nano/tb $$(COMPILER_BUILD)/features/$(1)/features.bin \
	  --max-cycles 30000000
endef

$(foreach opt,$(OPT_LEVELS),$(eval $(call COMPILER_FLOAT_RUN_RULE,$(opt))))

compiler-profiles:
	@for profile in $(PROFILES); do \
	  $(MAKE) --no-print-directory PROFILE=$$profile \
	    compiler-features compiler-float compiler-libm || exit; \
	done

# libc and libm

.PHONY: compiler-libc compiler-libm compiler-libc-size compiler-nano

libc_test_bins = $(addprefix $(COMPILER_BUILD)/libc/$(1)/, \
	$(addsuffix .bin,$(LIBC_ALL_TESTS)))
libm_test_bins = $(addprefix $(COMPILER_BUILD)/libc/$(1)/, \
	$(addsuffix .bin,$(LIBM_TESTS)))

# LIBC_TEST_RULES(optimization)
define LIBC_TEST_RULES
$$(COMPILER_BUILD)/libc/$(1)/%.o: test/compiler/libc/%.c \
		$$(LIBC_TEST_HEADERS) $$(RISCC_CLANG)
	@mkdir -p $$(@D)
	$$(RISCC_CLANG) $$(RISCC_TARGET_FLAGS) $$(CFLAGS_NO_OPT) \
	  $$(OPT_FLAGS_$(1)) -Itest/compiler/libc -Ifirmware/include \
	  -c $$< -o $$@

$$(COMPILER_BUILD)/libc/$(1)/%.elf: \
		$$(FW_VECTORS) $$(FW_CRT0) \
		$$(COMPILER_BUILD)/libc/$(1)/%.o $$(FW_LIBS) \
		$$(RISCC_LINKER_SCRIPT) $$(RISCC_CLANG) $$(RISCC_LLD)
	@mkdir -p $$(@D)
	$$(RISCC_CLANG) $$(RISCC_TARGET_FLAGS) $$(RISCC_LDFLAGS) -fuse-ld=lld -nostdlib \
	  -Wl,-T,$$(abspath $$(RISCC_LINKER_SCRIPT)) -Wl,-Map,$$(@:.elf=.map) \
	  $$(FW_VECTORS) $$(FW_CRT0) \
	  $$(COMPILER_BUILD)/libc/$(1)/$$*.o \
	  $$(FW_LIBS) -o $$@

endef

$(foreach opt,$(OPT_LEVELS),$(eval $(call LIBC_TEST_RULES,$(opt))))

LIBC_TEST_BINS := $(foreach opt,$(OPT_LEVELS),$(call libc_test_bins,$(opt)))
LIBM_TEST_BINS := $(foreach opt,$(OPT_LEVELS),$(call libm_test_bins,$(opt)))
LIBC_BATCH_RUNS := $(foreach opt,$(OPT_LEVELS), \
	$(addprefix compiler-libc-run-$(opt)-,$(LIBC_BATCH_TESTS)))
LIBC_UART_RUNS := $(foreach opt,$(OPT_LEVELS), \
	compiler-libc-run-$(opt)-all compiler-libc-run-$(opt)-stdio)
LIBC_TERMINATE_RUNS := $(foreach opt,$(OPT_LEVELS), \
	$(addprefix compiler-libc-run-$(opt)-,$(LIBC_TERMINATE_TESTS)))
LIBC_RUNS := $(LIBC_BATCH_RUNS) $(LIBC_UART_RUNS) $(LIBC_TERMINATE_RUNS)
LIBM_RUNS := $(foreach opt,$(OPT_LEVELS), \
	$(addprefix compiler-libm-run-$(opt)-,$(LIBM_TESTS)))
.PHONY: $(LIBC_RUNS) $(LIBM_RUNS)

compiler-libc: $(LIBC_RUNS)
compiler-libm: $(LIBM_RUNS)

define LIBC_BATCH_RUN_RULE
compiler-libc-run-$(1)-$(2): \
		$$(COMPILER_BUILD)/libc/$(1)/$(2).bin $$(RISCC_SIM)
	$$(RISCC_SIM) $$(COMPILER_BUILD)/libc/$(1)/$(2).bin \
	  $$(SIM_PROFILE_FLAGS) --max-insns $$(COMPILER_MAX_INSNS)
endef

$(foreach opt,$(OPT_LEVELS),$(foreach test,$(LIBC_BATCH_TESTS), \
	$(eval $(call LIBC_BATCH_RUN_RULE,$(opt),$(test)))))

define LIBC_UART_RUN_RULE
compiler-libc-run-$(1)-all: \
		$$(COMPILER_BUILD)/libc/$(1)/all.bin $$(RISCC_SIM) \
		test/compiler/libc/all.out
	$$(RISCC_SIM) $$(COMPILER_BUILD)/libc/$(1)/all.bin \
	  $$(SIM_PROFILE_FLAGS) --uart --max-insns $$(COMPILER_MAX_INSNS) \
	  > $$(COMPILER_BUILD)/libc/$(1)/all.uart
	cmp test/compiler/libc/all.out $$(COMPILER_BUILD)/libc/$(1)/all.uart

compiler-libc-run-$(1)-stdio: \
		$$(COMPILER_BUILD)/libc/$(1)/stdio.bin $$(RISCC_SIM) \
		test/compiler/libc/stdio.in test/compiler/libc/stdio.out
	$$(RISCC_SIM) $$(COMPILER_BUILD)/libc/$(1)/stdio.bin \
	  $$(SIM_PROFILE_FLAGS) --uart --max-insns $$(COMPILER_MAX_INSNS) \
	  < test/compiler/libc/stdio.in \
	  > $$(COMPILER_BUILD)/libc/$(1)/stdio.uart
	cmp test/compiler/libc/stdio.out $$(COMPILER_BUILD)/libc/$(1)/stdio.uart
endef

$(foreach opt,$(OPT_LEVELS),$(eval $(call LIBC_UART_RUN_RULE,$(opt))))

define LIBC_TERMINATE_RUN_RULE
compiler-libc-run-$(1)-$(2): \
		$$(COMPILER_BUILD)/libc/$(1)/$(2).bin $$(RISCC_SIM)
	@log=$$(COMPILER_BUILD)/libc/$(1)/$(2).terminate; \
	if ! $$(RISCC_SIM) $$(COMPILER_BUILD)/libc/$(1)/$(2).bin \
	     $$(SIM_PROFILE_FLAGS) --max-insns $$(TERMINATE_MAX_INSNS) \
	     > $$$$log 2>&1; then \
	  cat $$$$log; exit 1; \
	fi; \
	if ! grep -q 'HALT .*result=0x0000: PASS' $$$$log; then \
	  cat $$$$log; exit 1; \
	fi
endef

$(foreach opt,$(OPT_LEVELS),$(foreach test,$(LIBC_TERMINATE_TESTS), \
	$(eval $(call LIBC_TERMINATE_RUN_RULE,$(opt),$(test)))))

define LIBM_RUN_RULE
compiler-libm-run-$(1)-$(2): \
		$$(COMPILER_BUILD)/libc/$(1)/$(2).bin $$(RISCC_SIM)
	$$(RISCC_SIM) $$(COMPILER_BUILD)/libc/$(1)/$(2).bin \
	  $$(SIM_PROFILE_FLAGS) --max-insns $$(FLOAT_MAX_INSNS)
endef

$(foreach opt,$(OPT_LEVELS),$(foreach test,$(LIBM_TESTS), \
	$(eval $(call LIBM_RUN_RULE,$(opt),$(test)))))

compiler-nano: llvm-riscc
	+$(MAKE) --no-print-directory RISCC_TOOLCHAIN_READY=1 PROFILE=nano \
	  compiler-features compiler-float compiler-features-rtl compiler-libc

compiler-libc-size: $(COMPILER_BUILD)/libc/os/all.elf
	$(LLVM_BIN)/llvm-size -A $<
	@$(LLVM_BIN)/llvm-size -A $< | awk '\
	  $$1 == ".text" { text = $$2 } \
	  $$1 == ".data" { data = $$2 } \
	  $$1 == ".bss" { bss = $$2 } \
	  END { \
	    if (text > 4096 || data + bss > 32) { \
	      printf "rc16 libc size gate failed: text=%d data+bss=%d\\n", text, data + bss; \
	      exit 1; \
	    } \
	  }'

# Assembler encodings and full suite

.PHONY: check-llvm-mc-encodings check-nano-mc-encodings \
	check-rc32-mc-encodings test-isa test-compiler

check-llvm-mc-encodings: test/compiler/check_llvm_mc_encodings.py \
		tools/riscc_asm.py $(RISCC_MC) $(RISCC_OBJCOPY)
	$(PYTHON) $< --llvm-mc $(LLVM_BIN)/llvm-mc \
	  --llvm-objcopy $(LLVM_BIN)/llvm-objcopy

check-nano-mc-encodings: test/compiler/check_nano_mc_encodings.py \
		tools/riscc_asm.py $(RISCC_MC) $(RISCC_OBJCOPY)
	$(PYTHON) $< --llvm-mc $(LLVM_BIN)/llvm-mc \
	  --llvm-objcopy $(LLVM_BIN)/llvm-objcopy

check-rc32-mc-encodings: test/compiler/check_rc32_mc_encodings.py \
		$(RISCC_MC) $(RISCC_OBJCOPY)
	$(PYTHON) $< --llvm-mc $(LLVM_BIN)/llvm-mc \
	  --llvm-objcopy $(LLVM_BIN)/llvm-objcopy

# One supported-ISA gate: assembler/disassembler checks plus every directed
# ISS and RTL instruction suite.  Optional instructions enter this target only
# when their implementation and executable tests exist.
ISA_IRQ_RC16_TBS := $(foreach width,$(WIDTHS), \
	build/test/rc16/native/full/$(width)/tb)
ISA_IRQ_PIPELINE_TBS := \
	$(foreach multiplier,$(MULTIPLIERS),build/test/fast/async/$(multiplier)/tb) \
	$(foreach multiplier,$(MULTIPLIERS),build/test/faster/ecp5-block/$(multiplier)/tb)
ISA_IRQ_RC32_SYS_TBS := $(foreach width,$(WIDTHS), \
	build/test/rc32/sys/$(width)/tb)
ISA_IRQ_RC32_FULL_TBS := $(foreach width,$(WIDTHS), \
	build/test/rc32/full/$(width)/tb)
ISA_IRQ_STALL_SEEDS ?= 777
ISA_IRQ_STALL_ARGS = \
	$(foreach seed,$(ISA_IRQ_STALL_SEEDS),--stall-seed $(seed))

test-isa: check-version check-llvm-mc-encodings check-nano-mc-encodings \
	check-rc32-mc-encodings sim-all test-rtl $(RISCC_SIM) \
	$(foreach extension,$(EXTENSIONS),build/bin/full-$(extension).bin) \
	$(RC32_SYS_ISS_BIN) $(ISA_IRQ_BIN) $(ISA_IRQ_MDU_BIN) \
	$(RC32_ISA_IRQ_BIN) $(RC32_FULL_ISA_IRQ_BIN) $(RC32_MDU_BIN) \
	$(ISA_IRQ_RC16_TBS) $(ISA_IRQ_PIPELINE_TBS) \
	$(ISA_IRQ_RC32_SYS_TBS) $(ISA_IRQ_RC32_FULL_TBS) \
	tools/test_irq_cycles.py
	@$(foreach extension,$(EXTENSIONS),$(RISCC_SIM) \
	  build/bin/full-$(extension).bin --full --mdu --max-insns 5000 || exit;)
	$(RISCC_SIM) $(RC32_SYS_ISS_BIN) --rc32-sys --max-insns 5000
	$(RISCC_SIM) $(RC32_MDU_BIN) --rc32-full --mdu --max-insns 5000
	@for tb in $(ISA_IRQ_RC16_TBS) $(ISA_IRQ_PIPELINE_TBS); do \
	  $(PYTHON) tools/test_irq_cycles.py --tb $$tb --image $(ISA_IRQ_BIN) \
	    --jobs $(RISCC_BUILD_JOBS) $(ISA_IRQ_STALL_ARGS) \
	    --max-cycles 10000000 || exit; \
	done
	$(PYTHON) tools/test_irq_cycles.py \
	  --tb build/test/extension/native/muldiv/tb \
	  --image $(ISA_IRQ_MDU_BIN) --jobs $(RISCC_BUILD_JOBS) \
	  $(ISA_IRQ_STALL_ARGS) --max-cycles 10000000
	@for tb in $(ISA_IRQ_RC32_SYS_TBS); do \
	  $(PYTHON) tools/test_irq_cycles.py --tb $$tb \
	    --image $(RC32_ISA_IRQ_BIN) --jobs $(RISCC_BUILD_JOBS) \
	    $(ISA_IRQ_STALL_ARGS) \
	    --max-cycles 1000000 || exit; \
	done
	@for tb in $(ISA_IRQ_RC32_FULL_TBS); do \
	  $(PYTHON) tools/test_irq_cycles.py --tb $$tb \
	    --image $(RC32_FULL_ISA_IRQ_BIN) --jobs $(RISCC_BUILD_JOBS) \
	    $(ISA_IRQ_STALL_ARGS) \
	    --max-cycles 1000000 || exit; \
	done

TEST_COMPILER_PROFILE_RUNS := \
	test-compiler-rc16-nano test-compiler-rc16-min \
	test-compiler-rc16-sys test-compiler-rc16-full \
	test-compiler-rc32-min test-compiler-rc32-sys test-compiler-rc32-full
.PHONY: $(TEST_COMPILER_PROFILE_RUNS)

# One sub-make owns each architecture/profile output tree.  The seven profile
# jobs still run in parallel, but no two jobs rebuild the same firmware archive
# or compiler object.  LLVM and the ISS are completed once before any profile
# job starts.
test-compiler: check-llvm-mc-encodings check-nano-mc-encodings \
	check-rc32-mc-encodings $(TEST_COMPILER_PROFILE_RUNS)

test-compiler-rc16-nano: llvm-riscc $(RISCC_SIM)
	+$(MAKE) --no-print-directory RISCC_TOOLCHAIN_READY=1 PROFILE=nano \
	  compiler-features compiler-float compiler-features-rtl compiler-libc \
	  compiler-cpp-profile

test-compiler-rc16-min test-compiler-rc16-sys: llvm-riscc $(RISCC_SIM)
	+$(MAKE) --no-print-directory RISCC_TOOLCHAIN_READY=1 \
	  PROFILE=$(patsubst test-compiler-rc16-%,%,$@) \
	  compiler-smoke-matrix compiler-features compiler-rc16-profile-rtl \
	  compiler-c-abi-profile compiler-cpp-profile

test-compiler-rc16-full: llvm-riscc $(RISCC_SIM)
	+$(MAKE) --no-print-directory RISCC_TOOLCHAIN_READY=1 PROFILE=full \
	  compiler-smoke compiler-smoke-matrix compiler-features compiler-float \
	  compiler-libc compiler-libc-size compiler-stdio compiler-irqs \
	  compiler-c-abi-profile compiler-cpp-profile

test-compiler-rc32-min test-compiler-rc32-sys \
		test-compiler-rc32-full: llvm-riscc $(RISCC_SIM)
	+$(MAKE) --no-print-directory RISCC_TOOLCHAIN_READY=1 RISCC_XLEN=32 \
	  PROFILE=$(patsubst test-compiler-rc32-%,%,$@) \
	  compiler-rc32-profile compiler-c-abi-profile compiler-cpp-profile \
	  $(if $(filter test-compiler-rc32-min,$@),,compiler-rc32-irq-profile)

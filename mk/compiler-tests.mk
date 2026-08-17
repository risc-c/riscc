COMPILER_RULES := Makefile mk/compiler-tests.mk mk/firmware.mk mk/boards.mk

COMPILER_BUILD ?= build/compiler/$(PROFILE)
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

$(COMPILER_BUILD)/%.o: test/compiler/%.c \
		test/compiler/riscc_compiler_test.h $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_CFLAGS) \
	  -Itest/compiler -Ifirmware/include -c $< -o $@

$(COMPILER_BUILD)/%.bin: $(COMPILER_BUILD)/%.elf $(RISCC_OBJCOPY)
	$(RISCC_OBJCOPY) -O binary $< $@

$(COMPILER_UART).o: test/compiler/smoke.c \
		test/compiler/riscc_compiler_test.h firmware/include/stdio.h $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_CFLAGS) \
	  -DRISCC_COMPILER_UART -Itest/compiler -Ifirmware/include -c $< -o $@

$(COMPILER_SMOKE).elf: $(FW_VECTORS) $(FW_CRT0) \
		$(COMPILER_SMOKE_OBJS) $(FW_LIBS) \
		firmware/unified.ld $(RISCC_CLANG) $(RISCC_LLD)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_LDFLAGS) -fuse-ld=lld -nostdlib \
	  -Wl,-T,$(abspath firmware/unified.ld) \
	  -Wl,-Map,$(@:.elf=.map) \
	  $(FW_VECTORS) $(FW_CRT0) \
	  $(COMPILER_SMOKE_OBJS) $(FW_LIBS) -o $@

$(COMPILER_SMOKE).memh: $(COMPILER_SMOKE).bin tools/bin_to_memh.py
	$(PYTHON) tools/bin_to_memh.py $< -o $@

$(COMPILER_UART).elf: $(FW_VECTORS) $(FW_CRT0) \
		$(COMPILER_UART).o $(COMPILER_BUILD)/helper.o \
		$(FW_LIBS) firmware/unified.ld $(RISCC_CLANG) $(RISCC_LLD)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_LDFLAGS) -fuse-ld=lld -nostdlib \
	  -Wl,-T,$(abspath firmware/unified.ld) $(DEMO_LD_FLAGS) \
	  $(FW_VECTORS) $(FW_CRT0) \
	  $(COMPILER_UART).o $(COMPILER_BUILD)/helper.o \
	  $(FW_LIBS) -o $@

$(COMPILER_UART).memh: $(COMPILER_UART).bin tools/bin_to_memh.py
	$(PYTHON) tools/bin_to_memh.py $< -o $@ --depth 12288

$(COMPILER_STDIO).o: test/compiler/stdio_smoke.c \
		firmware/include/stdio.h $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_CFLAGS) \
	  -Ifirmware/include -c $< -o $@

$(COMPILER_STDIO).elf: $(FW_VECTORS) $(FW_CRT0) \
		$(COMPILER_STDIO).o $(FW_LIBS) \
		firmware/unified.ld $(RISCC_CLANG) $(RISCC_LLD)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_LDFLAGS) -fuse-ld=lld -nostdlib \
	  -Wl,-T,$(abspath firmware/unified.ld) \
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

$(COMPILER_IRQ).o: test/compiler/irq_smoke.c \
		firmware/include/riscc/interrupt.h $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_CFLAGS) \
	  -Ifirmware/include -c $< -o $@

$(COMPILER_IRQ)-main.o: test/compiler/irq_smoke_main.S $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_ASFLAGS) -c $< -o $@

$(COMPILER_IRQ_CUSTOM).o: test/compiler/irq_custom_vector.S $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_ASFLAGS) -c $< -o $@

$(COMPILER_IRQ).elf: $(FW_VECTORS) $(FW_CRT0) \
		$(COMPILER_IRQ_OBJS) \
		$(FW_LIBS) firmware/unified.ld $(RISCC_CLANG) $(RISCC_LLD)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_LDFLAGS) -fuse-ld=lld -nostdlib \
	  -Wl,-T,$(abspath firmware/unified.ld) \
	  -Wl,-Map,$(COMPILER_IRQ).map \
	  $(FW_VECTORS) $(FW_CRT0) \
	  $(COMPILER_IRQ_OBJS) $(FW_LIBS) -o $@

$(COMPILER_IRQ_CUSTOM).elf: $(FW_VECTORS) \
		$(FW_CRT0) $(COMPILER_IRQ_CUSTOM).o \
		$(FW_LIBS) firmware/unified.ld $(RISCC_CLANG) $(RISCC_LLD)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_LDFLAGS) -fuse-ld=lld -nostdlib \
	  -Wl,-T,$(abspath firmware/unified.ld) \
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

.PHONY: compiler-smoke-matrix

OPT_FLAGS_o0 := -O0
OPT_FLAGS_o2 := -O2
OPT_FLAGS_os := -Os
CFLAGS_NO_OPT := $(filter-out -O%,$(RISCC_CFLAGS))

.PRECIOUS: $(COMPILER_BUILD)/matrix/%/smoke.o \
	$(COMPILER_BUILD)/matrix/%/helper.o \
	$(COMPILER_BUILD)/matrix/%/smoke.elf

$(COMPILER_BUILD)/matrix/%/smoke.o: test/compiler/smoke.c \
		test/compiler/riscc_compiler_test.h $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(CFLAGS_NO_OPT) \
	  $(OPT_FLAGS_$*) -Itest/compiler -Ifirmware/include -c $< -o $@

$(COMPILER_BUILD)/matrix/%/helper.o: test/compiler/helper.c \
		test/compiler/riscc_compiler_test.h $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(CFLAGS_NO_OPT) \
	  $(OPT_FLAGS_$*) -Itest/compiler -Ifirmware/include -c $< -o $@

$(COMPILER_BUILD)/matrix/%/smoke.elf: $(FW_VECTORS) \
		$(FW_CRT0) \
		$(COMPILER_BUILD)/matrix/%/smoke.o \
		$(COMPILER_BUILD)/matrix/%/helper.o \
		$(FW_LIBS) firmware/unified.ld $(RISCC_CLANG) $(RISCC_LLD)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_LDFLAGS) -fuse-ld=lld -nostdlib \
	  -Wl,-T,$(abspath firmware/unified.ld) \
	  $(FW_VECTORS) $(FW_CRT0) \
	  $(COMPILER_BUILD)/matrix/$*/smoke.o \
	  $(COMPILER_BUILD)/matrix/$*/helper.o \
	  $(FW_LIBS) -o $@

compiler-smoke-matrix: $(foreach opt,$(OPT_LEVELS), \
		$(COMPILER_BUILD)/matrix/$(opt)/smoke.bin) $(RISCC_SIM)
	@for opt in $(OPT_LEVELS); do \
	  $(RISCC_SIM) $(COMPILER_BUILD)/matrix/$$opt/smoke.bin --full \
	    --max-insns $(COMPILER_MAX_INSNS) || exit; \
	done
# C and ABI features

.PHONY: compiler-features compiler-features-rtl

$(FEATURE_ASM_OBJ): test/compiler/feature_abi_asm.S \
		$(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_ASFLAGS) -c $< -o $@

feature_objects = $(addprefix $(COMPILER_BUILD)/features/$(1)/, \
	$(addsuffix .o,$(FEATURE_MODULES)))

# FEATURE_RULES(optimization)
define FEATURE_RULES
$$(call feature_objects,$(1)): \
		$$(COMPILER_BUILD)/features/$(1)/%.o: test/compiler/%.c \
		test/compiler/riscc_compiler_features.h $$(RISCC_CLANG)
	@mkdir -p $$(@D)
	$$(RISCC_CLANG) $$(RISCC_TARGET_FLAGS) $$(CFLAGS_NO_OPT) \
	  $$(OPT_FLAGS_$(1)) -std=c11 -Itest/compiler \
	  -Ifirmware/include -c $$< -o $$@

$$(COMPILER_BUILD)/features/$(1)/features.elf: \
		$$(FW_VECTORS) $$(FW_CRT0) \
		$$(call feature_objects,$(1)) \
		$$(FEATURE_ASM_OBJ) $$(FW_LIBS) \
		firmware/unified.ld $$(RISCC_CLANG) $$(RISCC_LLD)
	@mkdir -p $$(@D)
	$$(RISCC_CLANG) $$(RISCC_TARGET_FLAGS) $$(RISCC_LDFLAGS) \
	  -fuse-ld=lld -nostdlib -Wl,-T,$$(abspath firmware/unified.ld) \
	  $$(FW_VECTORS) $$(FW_CRT0) \
	  $$(call feature_objects,$(1)) \
	  $$(FEATURE_ASM_OBJ) $$(FW_LIBS) -o $$@

endef

$(foreach opt,$(OPT_LEVELS),$(eval $(call FEATURE_RULES,$(opt))))

FEATURE_BINS := $(foreach opt,$(OPT_LEVELS), \
	$(COMPILER_BUILD)/features/$(opt)/features.bin)

compiler-features: $(FEATURE_BINS) $(RISCC_SIM)
	@for image in $(FEATURE_BINS); do \
	  $(RISCC_SIM) $$image $(SIM_PROFILE_FLAGS) \
	    --max-insns $(COMPILER_MAX_INSNS) || exit; \
	done

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
		$$(FW_LIBS) firmware/unified.ld \
		$$(RISCC_CLANG) $$(RISCC_LLD)
	$$(RISCC_CLANG) $$(RISCC_TARGET_FLAGS) $$(RISCC_LDFLAGS) \
	  -fuse-ld=lld -nostdlib -Wl,-T,$$(abspath firmware/unified.ld) \
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
		$$(COMPILER_BUILD)/float/$(1)/%.o: test/compiler/%.c \
		test/compiler/riscc_compiler_features.h $$(RISCC_CLANG)
	@mkdir -p $$(@D)
	$$(RISCC_CLANG) $$(RISCC_TARGET_FLAGS) $$(CFLAGS_NO_OPT) \
	  $$(OPT_FLAGS_$(1)) -std=c11 -Itest/compiler \
	  -Ifirmware/include -c $$< -o $$@

$$(COMPILER_BUILD)/float/$(1)/float.elf: \
		$$(FW_VECTORS) $$(FW_CRT0) \
		$$(call float_objects,$(1)) \
		$$(FW_LIBS) firmware/unified.ld \
		$$(RISCC_CLANG) $$(RISCC_LLD)
	@mkdir -p $$(@D)
	$$(RISCC_CLANG) $$(RISCC_TARGET_FLAGS) $$(RISCC_LDFLAGS) \
	  -fuse-ld=lld -nostdlib -Wl,-T,$$(abspath firmware/unified.ld) \
	  $$(FW_VECTORS) $$(FW_CRT0) \
	  $$(call float_objects,$(1)) \
	  $$(FW_LIBS) -o $$@

endef

$(foreach opt,$(OPT_LEVELS),$(eval $(call FLOAT_RULES,$(opt))))

FLOAT_BINS := $(foreach opt,$(OPT_LEVELS), \
	$(COMPILER_BUILD)/float/$(opt)/float.bin)

compiler-float: $(FLOAT_BINS) $(RISCC_SIM)
	@for image in $(FLOAT_BINS); do \
	  $(RISCC_SIM) $$image $(SIM_PROFILE_FLAGS) \
	    --max-insns $(FLOAT_MAX_INSNS) || exit; \
	done

compiler-features-rtl: $(FEATURE_BINS) build/test/nano/tb
	@for image in $(FEATURE_BINS); do \
	  build/test/nano/tb $$image --max-cycles 30000000 || exit; \
	done

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
		firmware/unified.ld $$(RISCC_CLANG) $$(RISCC_LLD)
	@mkdir -p $$(@D)
	$$(RISCC_CLANG) $$(RISCC_TARGET_FLAGS) $$(RISCC_LDFLAGS) -fuse-ld=lld -nostdlib \
	  -Wl,-T,$$(abspath firmware/unified.ld) -Wl,-Map,$$(@:.elf=.map) \
	  $$(FW_VECTORS) $$(FW_CRT0) \
	  $$(COMPILER_BUILD)/libc/$(1)/$$*.o \
	  $$(FW_LIBS) -o $$@

endef

$(foreach opt,$(OPT_LEVELS),$(eval $(call LIBC_TEST_RULES,$(opt))))

LIBC_TEST_BINS := $(foreach opt,$(OPT_LEVELS),$(call libc_test_bins,$(opt)))
LIBM_TEST_BINS := $(foreach opt,$(OPT_LEVELS),$(call libm_test_bins,$(opt)))

compiler-libc: $(LIBC_TEST_BINS) $(RISCC_SIM) test/compiler/libc/stdio.in \
		test/compiler/libc/stdio.out test/compiler/libc/all.out
	@for opt in $(OPT_LEVELS); do \
	  for test in $(LIBC_BATCH_TESTS); do \
	    $(RISCC_SIM) $(COMPILER_BUILD)/libc/$$opt/$$test.bin \
	      $(SIM_PROFILE_FLAGS) \
	      --max-insns $(COMPILER_MAX_INSNS) || exit 1; \
	  done; \
	  $(RISCC_SIM) $(COMPILER_BUILD)/libc/$$opt/all.bin \
	    $(SIM_PROFILE_FLAGS) --uart \
	    --max-insns $(COMPILER_MAX_INSNS) \
	    > $(COMPILER_BUILD)/libc/$$opt/all.uart || exit 1; \
	  cmp test/compiler/libc/all.out \
	    $(COMPILER_BUILD)/libc/$$opt/all.uart || exit 1; \
	  $(RISCC_SIM) $(COMPILER_BUILD)/libc/$$opt/stdio.bin \
	    $(SIM_PROFILE_FLAGS) --uart \
	    --max-insns $(COMPILER_MAX_INSNS) < test/compiler/libc/stdio.in \
	    > $(COMPILER_BUILD)/libc/$$opt/stdio.uart || exit 1; \
	  cmp test/compiler/libc/stdio.out \
	    $(COMPILER_BUILD)/libc/$$opt/stdio.uart || exit 1; \
	  for test in $(LIBC_TERMINATE_TESTS); do \
	    log=$(COMPILER_BUILD)/libc/$$opt/$$test.terminate; \
	    if ! $(RISCC_SIM) $(COMPILER_BUILD)/libc/$$opt/$$test.bin \
	         $(SIM_PROFILE_FLAGS) \
	         --max-insns $(TERMINATE_MAX_INSNS) > $$log 2>&1; then \
	      cat $$log; exit 1; \
	    fi; \
	    if ! grep -q 'HALT .*result=0x0000: PASS' $$log; then \
	      cat $$log; exit 1; \
	    fi; \
	  done; \
	done

compiler-libm: $(LIBM_TEST_BINS) $(RISCC_SIM)
	@for opt in $(OPT_LEVELS); do for test in $(LIBM_TESTS); do \
	  $(RISCC_SIM) $(COMPILER_BUILD)/libc/$$opt/$$test.bin \
	    $(SIM_PROFILE_FLAGS) \
	    --max-insns $(FLOAT_MAX_INSNS) || exit 1; \
	done; done

compiler-nano:
	$(MAKE) --no-print-directory PROFILE=nano \
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

.PHONY: check-llvm-mc-encodings check-rc32-mc-encodings test-compiler

check-llvm-mc-encodings: test/compiler/check_llvm_mc_encodings.py \
		tools/riscc_asm.py $(RISCC_MC) $(RISCC_OBJCOPY)
	$(PYTHON) $< --llvm-mc $(LLVM_BIN)/llvm-mc \
	  --llvm-objcopy $(LLVM_BIN)/llvm-objcopy

check-rc32-mc-encodings: test/compiler/check_rc32_mc_encodings.py \
		$(RISCC_MC) $(RISCC_OBJCOPY)
	$(PYTHON) $< --llvm-mc $(LLVM_BIN)/llvm-mc \
	  --llvm-objcopy $(LLVM_BIN)/llvm-objcopy

test-compiler: compiler-smoke compiler-smoke-matrix compiler-features \
	compiler-float compiler-libc compiler-libc-size compiler-stdio compiler-irqs \
	check-llvm-mc-encodings check-rc32-mc-encodings compiler-nano

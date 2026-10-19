# Standalone, pinned CoreMark workloads; never part of the default test matrix.
COREMARK_OPT ?= -O2
# Application-only options, e.g. -flto; the runtime retains RISCC_CFLAGS.
COREMARK_EXTRA_CFLAGS ?=
COREMARK_ITERATIONS ?= 100
COREMARK_CLOCK_HZ ?= 100000000
COREMARK_MAX_CYCLES ?= 200000000
COREMARK_MAX_INSNS ?= 200000000
COREMARK_TIMEOUT ?= 300
COREMARK_CYCLE_BASE ?= 0
COREMARK_SOURCE := external/coremark
COREMARK_PORT := test/compiler/coremark
COREMARK_BUILD := build/coremark/rc32/$(patsubst -%,%,$(COREMARK_OPT))/$(COREMARK_ITERATIONS)-$(COREMARK_CLOCK_HZ)
COREMARK_MODULES := core_main core_list_join core_matrix core_state core_util core_portme
COREMARK_UPSTREAM_FILES := $(addprefix $(COREMARK_SOURCE)/,\
	$(addsuffix .c,$(filter-out core_portme,$(COREMARK_MODULES))) \
	coremark.h LICENSE.md README.md barebones_porting.md)
COREMARK_RULES := Makefile mk/coremark.mk mk/firmware.mk
COREMARK_CFLAGS := $(filter-out -O%,$(RISCC_CFLAGS)) \
	$(COREMARK_OPT)$(if $(COREMARK_EXTRA_CFLAGS), $(COREMARK_EXTRA_CFLAGS)) -std=c11 \
	-I$(COREMARK_PORT) -I$(COREMARK_SOURCE) -Ifirmware/include \
	-DITERATIONS=$(COREMARK_ITERATIONS) -DCOREMARK_CLOCK_HZ=$(COREMARK_CLOCK_HZ) \
	-DTOTAL_DATA_SIZE=2000
COREMARK_FLAGS_TEXT := $(RISCC_TARGET_FLAGS) $(COREMARK_CFLAGS)
COREMARK_IMAGES := $(foreach mode,performance validation,$(COREMARK_BUILD)/$(mode)/coremark.bin)
COREMARK_RUN_ARGS := --build-dir $(COREMARK_BUILD) \
	--compiler $(abspath $(RISCC_CLANG)) --size-tool $(abspath $(LLVM_BIN)/llvm-size) \
	--iterations $(COREMARK_ITERATIONS) --clock-hz $(COREMARK_CLOCK_HZ) \
	--optimization=$(COREMARK_OPT) --library-optimization=$(RISCC_LIB_OPT) \
	--max-cycles $(COREMARK_MAX_CYCLES) --max-insns $(COREMARK_MAX_INSNS) \
	--timeout $(COREMARK_TIMEOUT) --cycle-base $(COREMARK_CYCLE_BASE)

.PHONY: coremark coremark-build coremark-iss coremark-check coremark-fetch \
	coremark-build32 coremark-iss32 coremark-rtl32
coremark: coremark-check
	+$(MAKE) RISCC_XLEN=32 PROFILE=full RISCC_TARGET_FEATURES= \
	  RISCC_LIB_OPT=$(COREMARK_OPT) coremark-rtl32
coremark-build: coremark-fetch
	+$(MAKE) RISCC_XLEN=32 PROFILE=full RISCC_TARGET_FEATURES= \
	  RISCC_LIB_OPT=$(COREMARK_OPT) coremark-build32
coremark-iss: coremark-check
	+$(MAKE) RISCC_XLEN=32 PROFILE=full RISCC_TARGET_FEATURES= \
	  RISCC_LIB_OPT=$(COREMARK_OPT) coremark-iss32
coremark-fetch:
	$(PYTHON) tools/fetch_coremark.py

$(COREMARK_UPSTREAM_FILES): | coremark-fetch
	@test -f $@

coremark-check: coremark-fetch
	$(PYTHON) tools/test_fetch_coremark.py
	$(PYTHON) tools/test_coremark.py

ifeq ($(RISCC_XLEN):$(PROFILE),32:full)
define COREMARK_MODE
$(COREMARK_BUILD)/$(1)/%.o: $(COREMARK_SOURCE)/%.c $(COREMARK_SOURCE)/coremark.h \
		$(COREMARK_PORT)/core_portme.h $(COREMARK_RULES) $(RISCC_CLANG)
	@mkdir -p $$(@D)
	$(if $(CCACHE),$(CCACHE) )$$(RISCC_CLANG) $$(RISCC_TARGET_FLAGS) $$(COREMARK_CFLAGS) \
	  -DPERFORMANCE_RUN=$(if $(filter performance,$(1)),1,0) \
	  -DVALIDATION_RUN=$(if $(filter validation,$(1)),1,0) \
	  '-DCOMPILER_FLAGS="$$(COREMARK_FLAGS_TEXT)"' -c $$< -o $$@
$(COREMARK_BUILD)/$(1)/core_portme.o: $(COREMARK_PORT)/core_portme.c \
		$(COREMARK_SOURCE)/coremark.h $(COREMARK_PORT)/core_portme.h \
		$(COREMARK_RULES) $(RISCC_CLANG)
	@mkdir -p $$(@D)
	$(if $(CCACHE),$(CCACHE) )$$(RISCC_CLANG) $$(RISCC_TARGET_FLAGS) $$(COREMARK_CFLAGS) \
	  -DPERFORMANCE_RUN=$(if $(filter performance,$(1)),1,0) \
	  -DVALIDATION_RUN=$(if $(filter validation,$(1)),1,0) \
	  '-DCOMPILER_FLAGS="$$(COREMARK_FLAGS_TEXT)"' -c $$< -o $$@
$(COREMARK_BUILD)/$(1)/coremark.elf: $$(FW_VECTORS) $$(FW_CRT0) \
		$(addprefix $(COREMARK_BUILD)/$(1)/,$(addsuffix .o,$(COREMARK_MODULES))) \
		$$(FW_LIBS) $(COREMARK_PORT)/link.ld $$(RISCC_LLD)
	$$(RISCC_CLANG) $$(RISCC_TARGET_FLAGS) $$(RISCC_LDFLAGS) -fuse-ld=lld -nostdlib \
	  -Wl,-T,$$(abspath $(COREMARK_PORT)/link.ld) -Wl,-Map,$$(@:.elf=.map) \
	  $$(filter %.o,$$^) $$(FW_LIBS) -o $$@
$(COREMARK_BUILD)/$(1)/coremark.bin: $(COREMARK_BUILD)/$(1)/coremark.elf $(RISCC_OBJCOPY)
	$$(RISCC_OBJCOPY) -O binary $$< $$@
endef
$(foreach mode,performance validation,$(eval $(call COREMARK_MODE,$(mode))))

coremark-build32: $(COREMARK_IMAGES)
coremark-iss32: $(COREMARK_IMAGES) $(RISCC_SIM)
	$(PYTHON) tools/run_coremark.py $(COREMARK_RUN_ARGS) --iss $(RISCC_SIM) \
	  --output $(COREMARK_BUILD)/results-iss.json
coremark-rtl32: $(COREMARK_IMAGES) $(foreach cached,0 1,build/coremark/rtl/btb32/$(cached)/Vriscc_coremark_tb)
	$(PYTHON) tools/run_coremark.py $(COREMARK_RUN_ARGS) \
	  --rtl sram=build/coremark/rtl/btb32/0/Vriscc_coremark_tb \
	  --rtl cached=build/coremark/rtl/btb32/1/Vriscc_coremark_tb \
	  --output $(COREMARK_BUILD)/results-rtl.json
else
coremark-build32 coremark-iss32 coremark-rtl32:
	@echo 'Use coremark, coremark-build or coremark-iss (RC32 Full)' >&2
	@exit 2
endif

# Standard 32-entry BTB; keep the same synchronous block register file.
define COREMARK_RTL
build/coremark/rtl/btb32/$(1)/Vriscc_coremark_tb: test/riscc_coremark_tb.v \
		rtl/riscc_pipeline_shared.v rtl/riscc_cached.v $(RISCC_RF_RTL) mk/coremark.mk
	@mkdir -p $$(@D)
	+$$(VERILATOR) --binary --timing -j 8 $$(VERILATOR_MAKEFLAGS_ARG) \
	  --top-module riscc_coremark_tb -GCACHED=$(1) --Mdir $$(@D) \
	  -DRISCC_FAST_BLOCK_RF \
	  rtl/riscc_pipeline_shared.v rtl/riscc_cached.v test/riscc_coremark_tb.v
endef
$(foreach cached,0 1,$(eval $(call COREMARK_RTL,$(cached))))

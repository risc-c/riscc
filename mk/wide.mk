# Full-width core coverage across XLEN, profiles, MDU options and RF modes.
XLEN ?= 16
MDU ?= 0
WIDE_MDUS_min := 0
WIDE_MDUS_sys := 0
WIDE_MDUS_full := 0 1 2
WIDE_EXTENSION_1 := mulh
WIDE_EXTENSION_2 := muldiv
WIDE_RC32_EXTENSION_1 := build/bin/rc32-mulh.bin
WIDE_RC32_EXTENSION_2 := $(RC32_MDU_BIN)
WIDE_FEATURE_1 := +mulhu
WIDE_FEATURE_2 := +mdu
WIDE_STALL_SEED ?= 777
WIDE_MAX_CYCLES ?= 1000000
WIDE_IRQ_JOBS ?= 1

wide_base = $(if $(filter 16,$(1)),build/bin/$(2).bin,$(RC32_TEST_BIN_$(2)))
wide_extension = $(if $(filter-out 0,$(2)),$(if $(filter 16,$(1)),build/bin/full-$(WIDE_EXTENSION_$(2)).bin,$(WIDE_RC32_EXTENSION_$(2))))
wide_address = $(if $(filter 16,$(1)),build/bin/wide16-address-$(2).bin,build/bin/serial32-address-$(2).bin)
wide_load = $(if $(filter 32,$(1)),build/bin/wide32-load-$(2).bin)
wide_irq = $(if $(filter-out min,$(2)),build/bin/wide$(1)-$(2)-$(3)-irq.bin)
wide_attrs = $(if $(filter 32,$(1)),--mattr=+rc32$(if $(filter-out 0,$(2)),$(comma)$(WIDE_FEATURE_$(2))),$(EXTENSION_FLAGS_$(WIDE_EXTENSION_$(2))))
wide_tb = build/test/wide/$(1)/$(2)/$(3)/$(4)/tb
wide_ok = build/test/wide/$(1)/$(2)/$(3)/$(4).ok

build/bin/rc32-mulh.bin: test/test_rc32_mulh.asm test/flat.ld | llvm-riscc
	$(call ASSEMBLE_IMAGE,test/test_rc32_mulh.asm,full,--mattr=+rc32$(comma)+mulhu, \
	  $(ASM_DEFINES_full) RISCC_MULHU,test/flat.ld)

build/bin/wide16-address-%.bin: test/test_wide_rc16_address.asm test/flat.ld | llvm-riscc
	$(call ASSEMBLE_IMAGE,test/test_wide_rc16_address.asm,$*,,$(ASM_DEFINES_$*),test/flat.ld)

build/bin/wide32-load-%.bin: test/test_wide_rc32_load.asm test/flat.ld | llvm-riscc
	$(call ASSEMBLE_IMAGE,test/test_wide_rc32_load.asm,$*,--mattr=+rc32,$(ASM_DEFINES_$*),test/flat.ld)

# WIDE_IRQ_IMAGE(xlen, profile, mdu)
define WIDE_IRQ_IMAGE
build/bin/wide$(1)-$(2)-$(3)-irq.bin: test/test_$(if $(filter 32,$(1)),rc32_)isa_irq.asm test/flat.ld | llvm-riscc
	$$(call ASSEMBLE_IMAGE,$$<,$(2), \
	  $$(call wide_attrs,$(1),$(3)), \
	  $(ASM_DEFINES_$(2)) $(EXTENSION_ASM_DEFINES_$(WIDE_EXTENSION_$(3))),test/flat.ld)
endef
$(foreach xlen,16 32,$(foreach profile,sys full,$(foreach mdu,$(WIDE_MDUS_$(profile)), \
  $(eval $(call WIDE_IRQ_IMAGE,$(xlen),$(profile),$(mdu))))))

# WIDE_TEST(xlen, profile, mdu, rf mode)
define WIDE_TEST
$(call wide_tb,$(1),$(2),$(3),$(4)): rtl/riscc_wide.v $(RISCC_RF_RTL) $(TB_SRC) Makefile mk/wide.mk
	@mkdir -p $$(@D)
	+$$(VERILATOR) -cc --exe --build $$(VERILATOR_MAKEFLAGS_ARG) \
	  --top-module riscc_wide $(call wide_verilator_params,$(1),$(2),$(3)) \
	  --prefix Vriscc -Mdir $$(@D) -I$$(abspath rtl) $$(RF_DEFINES_$(4)) \
	  $(if $(filter native,$(4)),-DRISCC_INFERRED_SYNC_RF) \
	  -CFLAGS "$$(TB_CXXFLAGS) -DRISCC_TB_MEM_HANDSHAKE $(if $(filter 32,$(1)),-DRISCC_TB_RC32)" \
	  -o tb $$(abspath rtl/riscc_wide.v) $$(abspath $(TB_SRC))

$(call wide_ok,$(1),$(2),$(3),$(4)): $(call wide_tb,$(1),$(2),$(3),$(4)) \
		$(call wide_base,$(1),$(2)) $(call wide_extension,$(1),$(3)) \
		$(call wide_address,$(1),$(2)) $(call wide_load,$(1),$(2)) $(call wide_irq,$(1),$(2),$(3)) \
		$(if $(filter 16,$(1)),$(FUNNEL_BIN)) FORCE
	$$< $(call wide_base,$(1),$(2)) $(if $(filter 32,$(1)),$(RC32_TEST_IRQ_$(2))) \
	  --max-cycles $$(WIDE_MAX_CYCLES)
	$$< $(call wide_base,$(1),$(2)) $(if $(filter 32,$(1)),$(RC32_TEST_IRQ_$(2))) \
	  --max-cycles $$(WIDE_MAX_CYCLES) --mem-stall-seed $$(WIDE_STALL_SEED)
	$$< $(call wide_address,$(1),$(2)) --max-cycles $$(WIDE_MAX_CYCLES) \
	  --mem-stall-seed $$(WIDE_STALL_SEED)
$(if $(filter 16,$(1)),	$$< $$(FUNNEL_BIN) --max-cycles $$(WIDE_MAX_CYCLES) --mem-stall-seed $$(WIDE_STALL_SEED))
$(if $(filter 32,$(1)),	$$< $(call wide_load,$(1),$(2)) --max-cycles $$(WIDE_MAX_CYCLES)
	$$< $(call wide_load,$(1),$(2)) --max-cycles $$(WIDE_MAX_CYCLES) --mem-stall-seed $$(WIDE_STALL_SEED))
$(if $(filter-out 0,$(3)),	$$< $(call wide_extension,$(1),$(3)) --max-cycles $$(WIDE_MAX_CYCLES) --mem-stall-seed $$(WIDE_STALL_SEED))
$(if $(filter-out min,$(2)),	$$< $(call wide_irq,$(1),$(2),$(3)) --irq-at 300 --max-cycles $$(WIDE_MAX_CYCLES) --mem-stall-seed $$(WIDE_STALL_SEED))
	@touch $$@

$(if $(filter-out min,$(2)),build/test/wide/$(1)/$(2)/$(3)/$(4)-irq.ok: $(call wide_tb,$(1),$(2),$(3),$(4)) $(call wide_irq,$(1),$(2),$(3)) $(call wide_load,$(1),$(2)) tools/test_irq_cycles.py FORCE
	$$(PYTHON) tools/test_irq_cycles.py --tb $$< --image $(call wide_irq,$(1),$(2),$(3)) \
	  --jobs $$(WIDE_IRQ_JOBS) --stall-seed $$(WIDE_STALL_SEED) --max-cycles $$(WIDE_MAX_CYCLES)
$(if $(filter 32,$(1)),	$$(PYTHON) tools/test_irq_cycles.py --tb $$< --image $(call wide_load,$(1),$(2)) \
	  --jobs $$(WIDE_IRQ_JOBS) --stall-seed $$(WIDE_STALL_SEED) --max-cycles $$(WIDE_MAX_CYCLES))
	@touch $$@)
endef
$(foreach xlen,16 32,$(foreach profile,$(RC16_PROFILES),$(foreach mdu,$(WIDE_MDUS_$(profile)), \
  $(foreach mode,$(TEST_MODES),$(eval $(call WIDE_TEST,$(xlen),$(profile),$(mdu),$(mode)))))))

.PHONY: test-wide test-wide-all test-wide-irq test-wide-irq-all test-wide-rc32-mulh
test-rtl: test-wide-all
test-wide: $(call wide_ok,$(XLEN),$(PROFILE),$(MDU),$(MODE))
test-wide-all: $(foreach xlen,16 32,$(foreach profile,$(RC16_PROFILES), \
  $(foreach mdu,$(WIDE_MDUS_$(profile)),$(foreach mode,$(TEST_MODES), \
    $(call wide_ok,$(xlen),$(profile),$(mdu),$(mode))))))

test-wide-irq: build/test/wide/$(XLEN)/$(PROFILE)/$(MDU)/$(MODE)-irq.ok
test-wide-irq-all: $(foreach xlen,16 32,$(foreach profile,sys full, \
  $(foreach mdu,$(WIDE_MDUS_$(profile)),$(foreach mode,$(TEST_MODES), \
    build/test/wide/$(xlen)/$(profile)/$(mdu)/$(mode)-irq.ok))))

test-wide-rc32-mulh: $(call wide_tb,32,full,1,$(MODE)) build/bin/rc32-mulh.bin
	$< build/bin/rc32-mulh.bin --max-cycles $(WIDE_MAX_CYCLES) --mem-stall-seed $(WIDE_STALL_SEED)

.PHONY: fuzz-wide fuzz-wide32
fuzz-all: fuzz-wide fuzz-wide32
define WIDE_FUZZ
fuzz-wide$(if $(filter 32,$(1)),32): $(RISCC_SIM) llvm-riscc
	@for config in min sys full full-mulh full-muldiv; do \
	  RISCC_SIM=$$(abspath $$(RISCC_SIM)) RISCC_LLVM_BIN=$$(abspath $$(LLVM_BIN)) \
	    $$(PYTHON) tools/riscc_fuzz.py --family rc$(1) --campaign $$(FUZZ_SEEDS) \
	    $$(FUZZ_SEED_ARGS) --jobs $$(FUZZ_JOBS) --config $$$$config --cores wide$(1) \
	    --outdir build/fuzz/wide$(1) || exit; \
	done
endef
$(foreach xlen,16 32,$(eval $(call WIDE_FUZZ,$(xlen))))

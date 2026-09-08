# Serial-core coverage across register widths, slice widths, and RF modes.
XLEN ?= 16
W ?= 4
SERIAL_WIDTHS_16 := 1 2 4 8
SERIAL_WIDTHS_32 := 1 2 4 8 16
serial_bin = $(if $(filter 16,$(1)),build/bin/$(2).bin,$(RC32_TRACE_BIN_$(2)))
serial_irq = $(if $(filter 32,$(1)),$(RC32_TRACE_IRQ_$(2)))

build/bin/serial32-address-%.bin: test/test_serial_rc32_address.asm test/flat.ld | llvm-riscc
	$(call ASSEMBLE_IMAGE,test/test_serial_rc32_address.asm,$*,--mattr=+rc32, \
	  $(ASM_DEFINES_$*),test/flat.ld)

# SERIAL_TEST(xlen, profile, width, rf mode)
define SERIAL_TEST
build/test/serial/$(1)/$(2)/$(3)/$(4)/tb: rtl/riscc_serial.v $(RISCC_RF_RTL) $(TB_SRC) $(RTL_RULES)
	@mkdir -p $$(@D)
	+$$(VERILATOR) -cc --exe --build $$(VERILATOR_MAKEFLAGS_ARG) \
	  --top-module riscc_serial -GXLEN=$(1) -GW=$(3) -GPROFILE=$(SERIAL_PROFILE_$(2)) \
	  --prefix Vriscc -Mdir $$(@D) -I$$(abspath rtl) $$(RF_DEFINES_$(4)) \
	  $(if $(and $(filter 32,$(1)),$(filter native,$(4))),-DRISCC_INFERRED_SYNC_RF) \
	  -CFLAGS "$$(TB_CXXFLAGS) -DRISCC_TB_MEM_HANDSHAKE $(if $(filter 32,$(1)),-DRISCC_TB_RC32)" \
	  -o tb $$(abspath rtl/riscc_serial.v) $$(abspath $(TB_SRC))

build/test/serial/$(1)/$(2)/$(3)/$(4).ok: build/test/serial/$(1)/$(2)/$(3)/$(4)/tb \
		$(call serial_bin,$(1),$(2)) \
		$(if $(filter 16,$(1)),$(FUNNEL_BIN),build/bin/serial32-address-$(2).bin) FORCE
	$$< $(call serial_bin,$(1),$(2)) $(call serial_irq,$(1),$(2)) \
	  --max-cycles 1000000 --mem-stall-seed 777
$(if $(filter 16,$(1)),	$$< $$(FUNNEL_BIN) --max-cycles 100000 --mem-stall-seed 777)
$(if $(filter 32,$(1)),	$$< build/bin/serial32-address-$(2).bin --max-cycles 100000 --mem-stall-seed 777)
	@touch $$@
endef
$(foreach xlen,16 32,$(foreach profile,$(RC16_PROFILES),$(foreach width,$(SERIAL_WIDTHS_$(xlen)), \
  $(foreach mode,$(TEST_MODES),$(eval $(call SERIAL_TEST,$(xlen),$(profile),$(width),$(mode)))))))

.PHONY: test-serial test-serial-all fuzz-serial fuzz-serial32 bench-serial tables-serial
test-rtl: test-serial-all
test-serial: build/test/serial/$(XLEN)/$(PROFILE)/$(W)/$(MODE).ok
test-serial-all: $(foreach xlen,16 32,$(foreach profile,$(RC16_PROFILES), \
  $(foreach width,$(SERIAL_WIDTHS_$(xlen)),$(foreach mode,$(TEST_MODES), \
    build/test/serial/$(xlen)/$(profile)/$(width)/$(mode).ok))))

define SERIAL_FUZZ
fuzz-serial$(if $(filter 32,$(1)),32): $(RISCC_SIM) llvm-riscc
	@for profile in $(RC16_PROFILES); do \
	  RISCC_SIM=$$(abspath $$(RISCC_SIM)) RISCC_LLVM_BIN=$$(abspath $$(LLVM_BIN)) \
	    $$(PYTHON) tools/riscc_fuzz.py --family rc$(1) --campaign $$(FUZZ_SEEDS) \
	    $$(FUZZ_SEED_ARGS) --jobs $$(FUZZ_JOBS) --config $$$$profile \
	    --cores $(call join_with_commas,$(foreach width,$(SERIAL_WIDTHS_$(1)),serial$(1)-$(width))) \
	    --outdir build/fuzz/serial$(1) || exit; \
	done
endef
$(foreach xlen,16 32,$(eval $(call SERIAL_FUZZ,$(xlen))))

bench-serial: $(BENCH_BIN) $(foreach width,$(SERIAL_WIDTHS_16),build/test/serial/16/full/$(width)/native/tb)
	@for width in $(SERIAL_WIDTHS_16); do \
	  printf 'serial16/full/%s: ' "$$width"; \
	  build/test/serial/16/full/$$width/native/tb $(BENCH_BIN) --max-cycles 1000000 || exit; \
	done

tables-serial:
	$(PYTHON) tools/lattice_tune.py ecp5 all-serial --seeds $(TUNE_SEEDS) \
	  --seed-start 1 -j $(RISCC_BUILD_JOBS)

MEASURE_RULES := Makefile mk/measure.mk

REGRESSION_LIMITS := test/regression_limits.json
REGRESSION_CHECK := tools/check_regression_limits.py
REGRESSION_TBS := \
	$(foreach width,$(WIDTHS),build/test/rc16/native/full/$(width)/tb) \
	build/test/nano/tb \
	$(foreach pipeline,$(PIPELINES),$(foreach multiplier,$(MULTIPLIERS),build/test/$(pipeline)/ecp5-block/$(multiplier)/tb))
REGRESSION_PPA := \
	build/area/ecp5-block/rc16/sys/2.lut \
	build/area/ecp5-block/rc32/sys/2.lut \
	$(foreach width,$(WIDTHS),build/area/ecp5-block/rc32/full/$(width).lut) \
	build/area/ecp5-block/nano.lut \
	$(foreach pipeline,$(PIPELINES),$(foreach multiplier,$(MULTIPLIERS),build/area/ecp5-block/$(pipeline)/$(multiplier).resources)) \
	build/fmax/ecp5/rc16/sys/2.mhz \
	build/fmax/ecp5/rc32/sys/2.mhz \
	$(foreach width,$(WIDTHS),build/fmax/ecp5/rc32/full/$(width).mhz) \
	build/fmax/ecp5/nano.mhz \
	$(foreach pipeline,$(PIPELINES),$(foreach multiplier,$(MULTIPLIERS),build/fmax/ecp5/$(pipeline)/$(multiplier).mhz))

# Serial recipes: minimum area, with block-RF ties resolved by median Fmax
# over seeds 1–32. Columns are W=1, 2, 4, 8, 16.
# Saved measurements: build/serial-min-opt/final-ppa/ and build/core-opt4/.
AREA_OPTIONS_ecp5_serial := -abc2
EXTENSION_RECIPE_mulh := abc2-dff
EXTENSION_RECIPE_muldiv := default
extension_area_options = $(AREA_RECIPE_OPTIONS_$(EXTENSION_RECIPE_$(1)))
AREA_RECIPE_OPTIONS_default :=
AREA_RECIPE_OPTIONS_dff := -dff
AREA_RECIPE_OPTIONS_abc2 := -abc2
AREA_RECIPE_OPTIONS_abc2-dff := -abc2 -dff
AREA_RECIPE_OPTIONS_abc9 := -abc9
AREA_RECIPE_OPTIONS_noccu2 := -noccu2
AREA_RECIPE_OPTIONS_noccu2-dff := -noccu2 -dff
SERIAL_WIDTH_INDEX_1 := 1
SERIAL_WIDTH_INDEX_2 := 2
SERIAL_WIDTH_INDEX_4 := 3
SERIAL_WIDTH_INDEX_8 := 4
SERIAL_WIDTH_INDEX_16 := 5
SERIAL_RECIPES_ecp5-block_16_min := abc2 abc2 abc2-dff dff default
SERIAL_RECIPES_ecp5-block_16_sys := noccu2-dff dff noccu2-dff dff dff
SERIAL_RECIPES_ecp5-block_16_full := noccu2 abc2-dff abc2-dff default abc2
SERIAL_RECIPES_ecp5-block_32_min := noccu2-dff abc2-dff dff noccu2-dff default
SERIAL_RECIPES_ecp5-block_32_sys := noccu2 abc2-dff dff noccu2 abc2
SERIAL_RECIPES_ecp5-block_32_full := noccu2 noccu2 default noccu2 default
SERIAL_RECIPES_ecp5-lutram_16_min := abc2 abc2 abc2 dff default
SERIAL_RECIPES_ecp5-lutram_16_sys := default abc2 abc2 abc2 dff
SERIAL_RECIPES_ecp5-lutram_16_full := default abc2-dff abc2 default abc2-dff
SERIAL_RECIPES_ecp5-lutram_32_min := noccu2 dff dff noccu2 abc2
SERIAL_RECIPES_ecp5-lutram_32_sys := noccu2 abc2-dff dff noccu2 abc2
SERIAL_RECIPES_ecp5-lutram_32_full := noccu2-dff noccu2 dff noccu2 default
serial_recipe = $(word $(SERIAL_WIDTH_INDEX_$(4)),$(SERIAL_RECIPES_$(1)_$(2)_$(3)))
serial_options = $(AREA_RECIPE_OPTIONS_$(call serial_recipe,$(1),$(2),$(3),$(4)))
rc16_area_options = $(call serial_options,$(1),16,$(2),$(3))
rc32_area_options = $(call serial_options,$(1),32,$(2),$(3))
rc16_fmax_options = $(call rc16_area_options,ecp5-block,$(1),$(2))
rc32_fmax_options = $(call serial_options,ecp5-block,32,$(2),$(3))
# Fast: minimum area per RF mapping; timing uses the best median MHz/LUT4
# across seeds 1–32. Keep the timed recipe separate from minimum-area builds.
FAST_BLOCK_OPTIONS_fast_soft := -abc2
FAST_BLOCK_OPTIONS_fast_dsp := -abc2 -dff
FAST_BLOCK_OPTIONS_fast32_soft := -abc2 -dff
FAST_BLOCK_OPTIONS_fast32_dsp := -abc2
FAST_LUTRAM_OPTIONS_fast_soft :=
FAST_LUTRAM_OPTIONS_fast_dsp :=
FAST_LUTRAM_OPTIONS_fast32_soft :=
FAST_LUTRAM_OPTIONS_fast32_dsp :=
FAST_FMAX_OPTIONS_fast_soft := -abc2
FAST_FMAX_OPTIONS_fast_dsp := -abc2 -dff
FAST_FMAX_OPTIONS_fast32_soft := -dff
FAST_FMAX_OPTIONS_fast32_dsp := -abc2

# Cached: minimum area and highest MHz/LUT4 mapping at seed 1, including
# both caches. Cache data uses two EBRs in addition to the RF.
CACHED_BLOCK_OPTIONS_cached_soft := -abc2
CACHED_BLOCK_OPTIONS_cached_dsp := -abc2
CACHED_BLOCK_OPTIONS_cached32_soft :=
CACHED_BLOCK_OPTIONS_cached32_dsp := -abc2
CACHED_LUTRAM_OPTIONS_cached_soft := -abc2
CACHED_LUTRAM_OPTIONS_cached_dsp := -noccu2 -dff
CACHED_LUTRAM_OPTIONS_cached32_soft :=
CACHED_LUTRAM_OPTIONS_cached32_dsp :=
CACHED_FMAX_OPTIONS_cached_soft := -abc2 -dff
CACHED_FMAX_OPTIONS_cached_dsp := -abc2
CACHED_FMAX_OPTIONS_cached32_soft :=
CACHED_FMAX_OPTIONS_cached32_dsp := -abc2 -dff
CACHED_MEASURE_RTL := $(abspath rtl/riscc_cached.v rtl/riscc_fast.v)

# Agilex tables consume only generated Quartus results. Published snapshots
# belong in the hardware documentation, not in build logic.
AGILEX_CHARACTERIZE_DIR := build/agilex
AGILEX_RESULTS := $(AGILEX_CHARACTERIZE_DIR)/results.tsv
AGILEX_REPORT := tools/agilex_results.py
AGILEX_CHARACTERIZE := tools/agilex_core_characterize.py
# Zero lets the driver choose one independent Quartus project per two CPU
# threads, capped by available memory. Independent projects use this machine
# much better than assigning a large thread count to one tiny core; callers can
# still set an explicit cap.
AGILEX_PARALLEL_CONFIGS ?= 0
AREA_RTL := $(wildcard rtl/riscc*.v rtl/riscc*.vh)
AGILEX_RTL := $(AREA_RTL) $(RTL_TEST_DIR)/riscc_fmax_top.v $(TRACE_RTL)

$(AGILEX_RESULTS): $(AGILEX_CHARACTERIZE) $(AGILEX_RTL) $(MEASURE_RULES)
	$(PYTHON) $(AGILEX_CHARACTERIZE) \
	  --quartus "$(QUARTUS_SH)" --out $(AGILEX_CHARACTERIZE_DIR) \
	  --family all --jobs $(RISCC_BUILD_JOBS) \
	  --parallel-configs $(AGILEX_PARALLEL_CONFIGS)

characterize-agilex:
	$(PYTHON) $(AGILEX_CHARACTERIZE) \
	  --quartus "$(QUARTUS_SH)" --out $(AGILEX_CHARACTERIZE_DIR) \
	  --family $(AGILEX_FAMILY) --jobs $(RISCC_BUILD_JOBS) \
	  --parallel-configs $(AGILEX_PARALLEL_CONFIGS)

AREA_TARGETS := ecp5-block ecp5-lutram
ECP5_AREA_TARGETS := ecp5-block ecp5-lutram
AGILEX_FAMILY ?= all

SYNTH_OPTIONS_ecp5_soft :=
SYNTH_OPTIONS_ecp5_dsp :=

ECP5_LUT_AWK = '$$1 == "LUT4" { lut = $$2 } \
	$$1 == "CCU2C" { carry = $$2 } \
	$$1 == "TRELLIS_DPR16X4" { ram = $$2 } \
	END { print lut + 2 * carry + 6 * ram }'
ECP5_RESOURCE_AWK = '$$1 == "LUT4" { lut = $$2 } \
	$$1 == "CCU2C" { carry = $$2 } \
	$$1 == "MULT18X18D" { dsp = $$2 } \
	$$1 == "TRELLIS_DPR16X4" { ram = $$2 } \
	$$1 == "DP16KD" { ebr = $$2 } \
	END { print lut + 2 * carry + 6 * ram, lut + 0, 2 * carry, \
	       4 * ram, 2 * ram, dsp + 0, ebr + 0 }'

# A DPR16X4 occupies four RAM LUT sites and two RAMW sites, hence 6*r.
# ECP5_LUT_AREA(output, sources, setup, synthesis_options, top)
define ECP5_LUT_AREA
$(1): $$(AREA_RTL) $(MEASURE_RULES)
	@mkdir -p $$(@D)
	@$$(YOSYS) -p "read_verilog $(2); $(3) synth_ecp5 $(4) -top $(5) -nowidelut; stat" \
	  2>/dev/null | awk $$(ECP5_LUT_AWK) > $$@
endef

$(foreach target,$(ECP5_AREA_TARGETS), \
  $(foreach profile,$(RC16_PROFILES), \
    $(foreach width,$(WIDTHS), \
  $(eval $(call ECP5_LUT_AREA,build/area/$(target)/rc16/$(profile)/$(width).lut, \
    $(RF_DEFINES_$(target)) $(call rc16_source,$(width),$(profile)), \
    $(call rc16_yosys_width,$(width),$(profile)),$(call rc16_area_options,$(target),$(profile),$(width)), \
    $(call rc16_top,$(width),$(profile)))))))

$(foreach target,$(ECP5_AREA_TARGETS), \
  $(eval $(call ECP5_LUT_AREA,build/area/$(target)/nano.lut, \
    $(RF_DEFINES_$(target)) rtl/riscc_nano.v,,$(AREA_OPTIONS_ecp5_serial),riscc_nano)))

$(foreach target,$(ECP5_AREA_TARGETS), \
  $(foreach profile,$(RC32_PROFILES), \
    $(foreach width,$(WIDTHS), \
  $(eval $(call ECP5_LUT_AREA,build/area/$(target)/rc32/$(profile)/$(width).lut, \
    $(RF_DEFINES_$(target)) $(call rc32_source,$(profile)), \
    $(call rc32_yosys_width,$(width),$(profile)), \
    $(call rc32_area_options,$(target),$(profile),$(width)), \
    $(call rc32_top,$(profile)))))))

$(foreach target,$(ECP5_AREA_TARGETS), \
  $(foreach extension,$(EXTENSIONS), \
  $(eval $(call ECP5_LUT_AREA,build/area/$(target)/extension/$(extension).lut, \
    $(RF_DEFINES_$(target)) rtl/riscc_wide.v, \
    $(call wide_yosys_params,16,full,$(EXTENSION_MDU_$(extension))), \
    $(call extension_area_options,$(extension)),riscc_wide))))

# ECP5_RESOURCE_AREA(output, sources, synthesis_options, top, parameters)
define ECP5_RESOURCE_AREA
$(1): $$(AREA_RTL) $(MEASURE_RULES)
	@mkdir -p $$(@D)
	@$$(YOSYS) -p "read_verilog $(2); $(5) \
	  synth_ecp5 $(3) \
	  -top $(4) -nowidelut; stat" > $$@.log 2>&1
	@awk $$(ECP5_RESOURCE_AWK) $$@.log > $$@
endef

$(foreach pipeline,$(PIPELINES),$(foreach multiplier,$(MULTIPLIERS), \
  $(eval $(call ECP5_RESOURCE_AREA,build/area/ecp5-lutram/$(pipeline)/$(multiplier).resources, \
    -DRISCC_ECP5 $(FAST_DEFINES_$(multiplier)) rtl/riscc_fast.v, \
    $(SYNTH_OPTIONS_ecp5_$(multiplier)) $(FAST_LUTRAM_OPTIONS_$(pipeline)_$(multiplier)),riscc_fast, \
    $(if $(filter fast32,$(pipeline)),chparam -set XLEN 32 riscc_fast;))) \
  $(eval $(call ECP5_RESOURCE_AREA,build/area/ecp5-block/$(pipeline)/$(multiplier).resources, \
    -DRISCC_FAST_BLOCK_RF $(FAST_DEFINES_$(multiplier)) rtl/riscc_fast.v, \
    $(SYNTH_OPTIONS_ecp5_$(multiplier)) $(FAST_BLOCK_OPTIONS_$(pipeline)_$(multiplier)),riscc_fast, \
    $(if $(filter fast32,$(pipeline)),chparam -set XLEN 32 riscc_fast;)))))

$(foreach pipeline,$(CACHED_PIPELINES),$(foreach multiplier,$(MULTIPLIERS), \
  $(eval $(call ECP5_RESOURCE_AREA,build/area/ecp5-lutram/$(pipeline)/$(multiplier).resources, \
    -DRISCC_ECP5 $(FAST_DEFINES_$(multiplier)) $(CACHED_MEASURE_RTL), \
    $(SYNTH_OPTIONS_ecp5_$(multiplier)) $(CACHED_LUTRAM_OPTIONS_$(pipeline)_$(multiplier)),riscc_cached, \
    $(if $(filter cached32,$(pipeline)),chparam -set XLEN 32 riscc_cached;))) \
  $(eval $(call ECP5_RESOURCE_AREA,build/area/ecp5-block/$(pipeline)/$(multiplier).resources, \
    -DRISCC_FAST_BLOCK_RF $(FAST_DEFINES_$(multiplier)) $(CACHED_MEASURE_RTL), \
    $(SYNTH_OPTIONS_ecp5_$(multiplier)) $(CACHED_BLOCK_OPTIONS_$(pipeline)_$(multiplier)),riscc_cached, \
    $(if $(filter cached32,$(pipeline)),chparam -set XLEN 32 riscc_cached;)))))

RC16_AREA_RESULTS := $(foreach target,$(AREA_TARGETS),$(foreach profile,$(RC16_PROFILES), \
  $(foreach width,$(WIDTHS),build/area/$(target)/rc16/$(profile)/$(width).lut)))
NANO_AREA_RESULTS := $(foreach target,$(AREA_TARGETS),build/area/$(target)/nano.lut)
RC32_AREA_RESULTS := $(foreach target,$(AREA_TARGETS),$(foreach profile,$(RC32_PROFILES), \
  $(foreach width,$(WIDTHS),build/area/$(target)/rc32/$(profile)/$(width).lut)))
EXTENSION_AREA_RESULTS := $(foreach target,$(AREA_TARGETS),$(foreach extension,$(EXTENSIONS), \
  build/area/$(target)/extension/$(extension).lut))
PIPELINE_AREA_RESULTS := $(foreach target,$(ECP5_AREA_TARGETS),$(foreach pipeline,$(PIPELINES), \
  $(foreach multiplier,$(MULTIPLIERS),build/area/$(target)/$(pipeline)/$(multiplier).resources)))
CACHED_PIPELINE_AREA_RESULTS := $(foreach target,$(ECP5_AREA_TARGETS),$(foreach pipeline,$(CACHED_PIPELINES), \
  $(foreach multiplier,$(MULTIPLIERS),build/area/$(target)/$(pipeline)/$(multiplier).resources)))
LATTICE_AREA_RESULTS := $(RC16_AREA_RESULTS) $(NANO_AREA_RESULTS) \
  $(RC32_AREA_RESULTS) $(EXTENSION_AREA_RESULTS) $(PIPELINE_AREA_RESULTS) \
  $(CACHED_PIPELINE_AREA_RESULTS)

.PHONY: area area-lattice area-agilex area-all characterize-agilex

area: area-lattice

area-lattice: $(LATTICE_AREA_RESULTS)
	@for target in $(AREA_TARGETS); do \
	  case $$target in ecp5-block) title='ECP5 LUT sites (RF in block RAM)';; \
	    *) title='ECP5 LUT sites (LUTRAM RF included)';; esac; \
	  echo "$$title"; \
	  printf '%-16s %7s %7s %7s %7s %7s\n' profile /1 /2 /4 /8 /16; \
	  for profile in $(RC16_PROFILES); do \
	    printf '%-16s' $$profile; \
	    for width in $(WIDTHS); do \
	      printf ' %7s' "$$(cat build/area/$$target/rc16/$$profile/$$width.lut)"; \
	    done; echo; \
	  done; \
	  for profile in $(RC32_PROFILES); do \
	    printf '%-16s' "RC32 $$profile"; \
	    for width in $(WIDTHS); do \
	      printf ' %7s' "$$(cat build/area/$$target/rc32/$$profile/$$width.lut)"; \
	    done; echo; \
	  done; \
	  printf '%-16s %7s\n' nano "$$(cat build/area/$$target/nano.lut)"; \
	done
	@echo 'Other /16 implementations'
	@printf '%-16s %10s %10s\n' implementation 'ECP5 block' 'ECP5 LUTRAM'; \
	printf '%-16s %10s %10s\n' 'full base' \
	  "$$(cat build/area/ecp5-block/rc16/full/16.lut)" \
	  "$$(cat build/area/ecp5-lutram/rc16/full/16.lut)"; \
	for extension in $(EXTENSIONS); do printf '%-16s %10s %10s\n' "full $$extension" \
	  "$$(cat build/area/ecp5-block/extension/$$extension.lut)" \
	  "$$(cat build/area/ecp5-lutram/extension/$$extension.lut)"; done
	@printf '%-16s %22s %22s\n' implementation \
	  'ECP5 block LUT/DSP/EBR' 'ECP5 LUTRAM LUT/DSP/EBR'; \
	for pipeline in $(PIPELINES) $(CACHED_PIPELINES); do for multiplier in $(MULTIPLIERS); do \
	  set -- $$(cat build/area/ecp5-block/$$pipeline/$$multiplier.resources); \
	  blut=$$1; bdsp=$$6; bebr=$$7; \
	  set -- $$(cat build/area/ecp5-lutram/$$pipeline/$$multiplier.resources); \
	  llut=$$1; ldsp=$$6; lebr=$$7; \
	  printf '%-16s %16s/%s/%s %16s/%s/%s\n' "$$pipeline $$multiplier" \
	    $$blut $$bdsp $$bebr $$llut $$ldsp $$lebr; \
	done; done

area-agilex: $(AGILEX_RESULTS)
	$(PYTHON) $(AGILEX_REPORT) --metric area $<

area-all: area-lattice $(AGILEX_RESULTS)
	$(PYTHON) $(AGILEX_REPORT) --metric area $(AGILEX_RESULTS)

# Routed core timing

.PHONY: fmax fmax-lattice fmax-agilex fmax-all

FMAX_TOP := $(RTL_TEST_DIR)/riscc_fmax_top.v
FMAX_RTL := $(FMAX_TOP) $(AREA_RTL) $(MEASURE_RULES)

serial_fmax_defines = -DRISCC_FMAX_SERIAL -DRISCC_FMAX_SERIAL_XLEN=$(1) \
    -DRISCC_FMAX_SERIAL_W=$(3) -DRISCC_FMAX_SERIAL_PROFILE=$(SERIAL_PROFILE_$(2))
wide_fmax_defines = -DRISCC_FMAX_WIDE -DRISCC_FMAX_WIDE_XLEN=$(1) \
    -DRISCC_FMAX_WIDE_PROFILE=$(SERIAL_PROFILE_$(2)) -DRISCC_FMAX_WIDE_MDU=$(3)
rc16_fmax_defines = $(if $(filter 16,$(2)), \
    $(call wide_fmax_defines,16,$(1),0), \
    $(call serial_fmax_defines,16,$(1),$(2)))
FMAX_AWK = '/Max frequency for clock/ { \
	for (i = 1; i < NF; i++) if ($$(i + 1) == "MHz") value = $$i \
	} END { print value }'

# ECP5_FMAX(output, definitions_and_source, synthesis_options, target_mhz,
#           nextpnr_options, parameter_setup)
define ECP5_FMAX
$(1): $$(FMAX_RTL)
	@mkdir -p $$(@D)
	@$$(YOSYS) -q -p "read_verilog $(2) $$(FMAX_TOP); \
	  $(6) synth_ecp5 $(3) -nowidelut -top riscc_fmax_top \
	  -json $$(@:.mhz=.json)"
	@$$(NEXTPNR_ECP5) --25k --package CABGA256 --speed 6 \
	  --lpf-allow-unconstrained --freq $(4) --seed $$(PNR_SEED) \
	  $(5) \
	  --json $$(@:.mhz=.json) --textcfg $$(@:.mhz=.config) >$$(@:.mhz=.log) 2>&1
	@awk $$(FMAX_AWK) $$(@:.mhz=.log) > $$@
endef

$(foreach profile,$(RC16_PROFILES),$(foreach width,$(WIDTHS), \
  $(eval $(call ECP5_FMAX,build/fmax/ecp5/rc16/$(profile)/$(width).mhz, \
    -DRISCC_ECP5 -DRISCC_ECP5_BLOCK_RF \
    $(call rc16_fmax_defines,$(profile),$(width)) $(call rc16_source,$(width),$(profile)), \
    $(call rc16_fmax_options,$(profile),$(width)),40,, \
    $(call rc16_yosys_width,$(width),$(profile))))))

$(foreach profile,$(RC32_PROFILES),$(foreach width,$(WIDTHS), \
  $(eval $(call ECP5_FMAX,build/fmax/ecp5/rc32/$(profile)/$(width).mhz, \
    -DRISCC_ECP5 -DRISCC_ECP5_BLOCK_RF $(call serial_fmax_defines,32,$(profile),$(width)) \
    $(call rc32_source,$(profile)),$(call rc32_fmax_options,ecp5,$(profile),$(width)),40,, \
    $(call rc32_yosys_width,$(width),$(profile))))))

$(eval $(call ECP5_FMAX,build/fmax/ecp5/nano.mhz, \
  -DRISCC_ECP5 -DRISCC_ECP5_BLOCK_RF -DRISCC_FMAX_NANO rtl/riscc_nano.v,-abc2,40))

$(foreach extension,$(EXTENSIONS), \
  $(eval $(call ECP5_FMAX,build/fmax/ecp5/extension/$(extension).mhz, \
    -DRISCC_ECP5 -DRISCC_ECP5_BLOCK_RF \
    $(call wide_fmax_defines,16,full,$(EXTENSION_MDU_$(extension))) rtl/riscc_wide.v, \
    $(call extension_area_options,$(extension)),40,, \
    $(call wide_yosys_params,16,full,$(EXTENSION_MDU_$(extension))))))

$(foreach pipeline,$(PIPELINES),$(foreach multiplier,$(MULTIPLIERS), \
  $(eval $(call ECP5_FMAX,build/fmax/ecp5/$(pipeline)/$(multiplier).mhz, \
    -DRISCC_FMAX_$(if $(filter fast32,$(pipeline)),FAST32,FAST) -DRISCC_FAST_BLOCK_RF \
    $(FAST_DEFINES_$(multiplier)) rtl/riscc_fast.v, \
    $(SYNTH_OPTIONS_ecp5_$(multiplier)) $(FAST_FMAX_OPTIONS_$(pipeline)_$(multiplier)),40,, \
    $(if $(filter fast32,$(pipeline)),chparam -set XLEN 32 riscc_fast;)))))

$(foreach pipeline,$(CACHED_PIPELINES),$(foreach multiplier,$(MULTIPLIERS), \
  $(eval $(call ECP5_FMAX,build/fmax/ecp5/$(pipeline)/$(multiplier).mhz, \
    -DRISCC_FMAX_$(if $(filter cached32,$(pipeline)),CACHED32,CACHED) \
    -DRISCC_FAST_BLOCK_RF $(FAST_DEFINES_$(multiplier)) \
    $(CACHED_MEASURE_RTL), \
    $(SYNTH_OPTIONS_ecp5_$(multiplier)) $(CACHED_FMAX_OPTIONS_$(pipeline)_$(multiplier)),40,, \
    $(if $(filter cached32,$(pipeline)),chparam -set XLEN 32 riscc_cached;)))))

# Match the tuner's source paths and order so both flows reproduce its netlist.
$(foreach pipeline,$(CACHED_PIPELINES),$(foreach multiplier,$(MULTIPLIERS), \
  build/fmax/ecp5/$(pipeline)/$(multiplier).mhz)): FMAX_TOP := $(abspath $(FMAX_TOP))

RC16_FMAX_RESULTS := $(foreach profile,$(RC16_PROFILES), \
  $(foreach width,$(WIDTHS),build/fmax/ecp5/rc16/$(profile)/$(width).mhz))
RC32_FMAX_RESULTS := $(foreach profile,$(RC32_PROFILES), \
  $(foreach width,$(WIDTHS),build/fmax/ecp5/rc32/$(profile)/$(width).mhz))
OTHER_FMAX_RESULTS := build/fmax/ecp5/nano.mhz \
  $(foreach extension,$(EXTENSIONS),build/fmax/ecp5/extension/$(extension).mhz) \
  $(foreach pipeline,$(PIPELINES),$(foreach multiplier,$(MULTIPLIERS), \
    build/fmax/ecp5/$(pipeline)/$(multiplier).mhz)) \
  $(foreach pipeline,$(CACHED_PIPELINES),$(foreach multiplier,$(MULTIPLIERS), \
    build/fmax/ecp5/$(pipeline)/$(multiplier).mhz))
LATTICE_FMAX_RESULTS := $(RC16_FMAX_RESULTS) $(RC32_FMAX_RESULTS) $(OTHER_FMAX_RESULTS)

fmax: fmax-lattice

fmax-lattice: $(LATTICE_FMAX_RESULTS)
	@target=ecp5; \
	  echo "ECP5 LFE5U-25F speed 6, block-RAM RF; fixed seed $(PNR_SEED)"; \
	  printf '%-16s %7s %7s %7s %7s %7s\n' profile /1 /2 /4 /8 /16; \
	  for profile in $(RC16_PROFILES); do \
	    printf '%-16s' $$profile; \
	    for width in $(WIDTHS); do \
	      printf ' %7s' "$$(cat build/fmax/$$target/rc16/$$profile/$$width.mhz)"; \
	    done; echo; \
	  done; \
	  for profile in $(RC32_PROFILES); do \
	    printf '%-16s' "RC32 $$profile"; \
	    for width in $(WIDTHS); do \
	      printf ' %7s' "$$(cat build/fmax/$$target/rc32/$$profile/$$width.mhz)"; \
	    done; echo; \
	  done; \
	  printf '%-16s %7s\n' nano "$$(cat build/fmax/$$target/nano.mhz)"; \
	  for extension in $(EXTENSIONS); do printf '%-16s %7s\n' "full $$extension" \
	    "$$(cat build/fmax/$$target/extension/$$extension.mhz)"; done; \
	  for pipeline in $(PIPELINES) $(CACHED_PIPELINES); do for multiplier in $(MULTIPLIERS); do \
	    printf '%-16s %7s\n' "$$pipeline $$multiplier" \
	      "$$(cat build/fmax/$$target/$$pipeline/$$multiplier.mhz)"; \
	  done; done

fmax-agilex: $(AGILEX_RESULTS)
	$(PYTHON) $(AGILEX_REPORT) --metric fmax $<

fmax-all: fmax-lattice $(AGILEX_RESULTS)
	$(PYTHON) $(AGILEX_REPORT) --metric fmax $(AGILEX_RESULTS)

.PHONY: tables tables-lattice

tables:
	+$(MAKE) --no-print-directory tables-lattice
	+$(MAKE) --no-print-directory area-agilex
	+$(MAKE) --no-print-directory fmax-agilex

tables-lattice:
	$(PYTHON) tools/lattice_tune.py ecp5 all \
	  --seeds $(TUNE_SEEDS) -j $(RISCC_BUILD_JOBS)
	+$(MAKE) --no-print-directory bench

.PHONY: check-regressions
check-regressions: $(BENCH_BIN) $(NANO_BENCH_BIN) build/bin/bench-rc32.bin $(REGRESSION_TBS) \
		$(REGRESSION_PPA) compiler-libc-size \
		$(REGRESSION_LIMITS) $(REGRESSION_CHECK)
	$(PYTHON) $(REGRESSION_CHECK) $(REGRESSION_LIMITS)

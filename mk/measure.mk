MEASURE_RULES := Makefile mk/measure.mk

# Area defaults to one policy for serial/RC32 cores and the normal mapper for
# the separate wide implementation. Measured RC32 cases override the default.
AREA_OPTIONS_ecp5_serial := -abc2
AREA_OPTIONS_ecp5_wide :=
EXTENSION_AREA_OPTIONS_ecp5 := -abc2
RC16_AREA_OPTIONS_ecp5_1 := -noccu2 -dff
# RC32's held-request cones are unusually mapper-sensitive. These are the
# deterministic minimum-area recipes from the full built-in recipe sweep;
# they change mapping only, not the RTL or routing seed.
AREA_RECIPE_OPTIONS_abc2 := -abc2
AREA_RECIPE_OPTIONS_abc2-dff := -abc2 -dff
AREA_RECIPE_OPTIONS_noccu2 := -noccu2
AREA_RECIPE_OPTIONS_default :=
RC32_AREA_RECIPE_ecp5-lutram_min_2 := noccu2
RC32_AREA_RECIPE_ecp5-block_min_2 := noccu2
RC32_AREA_RECIPE_ecp5-lutram_min_4 := abc2-dff
RC32_AREA_RECIPE_ecp5-block_min_4 := abc2-dff
RC32_AREA_RECIPE_ecp5-lutram_sys_1 := noccu2
RC32_AREA_RECIPE_ecp5-lutram_sys_2 := abc2-dff
RC32_AREA_RECIPE_ecp5-block_sys_2 := abc2-dff
RC32_AREA_RECIPE_ecp5-lutram_sys_4 := abc2-dff
RC32_AREA_RECIPE_ecp5-block_sys_4 := abc2-dff
RC32_AREA_RECIPE_ecp5-lutram_sys_8 := abc2-dff
RC32_AREA_RECIPE_ecp5-block_sys_8 := abc2-dff
rc32_area_options = $(AREA_RECIPE_OPTIONS_$(or \
    $(RC32_AREA_RECIPE_$(1)_$(2)_$(3)),abc2))
PIPELINE_AREA_OPTIONS_ecp5_fast := -dff
rc16_area_options = $(or $(RC16_AREA_OPTIONS_$(1)_$(2)), \
	$(AREA_OPTIONS_$(1)_$(call rc16_implementation,$(2))))

RC16_FMAX_OPTIONS_ecp5_1 := -abc2
RC16_FMAX_OPTIONS_ecp5_4 := -noccu2 -dff
RC16_FMAX_OPTIONS_ecp5_8 := -abc9
RC32_FMAX_OPTIONS_ecp5 := -abc9
FAST_FMAX_OPTIONS_ecp5_soft := -abc9
FAST_FMAX_OPTIONS_ecp5_dsp := -abc2
FASTER_FMAX_OPTIONS_ecp5 := -abc9

# Agilex tables consume only generated Quartus results. Published snapshots
# belong in the hardware documentation, not in build logic.
AGILEX_CHARACTERIZE_DIR := build/agilex
AGILEX_RESULTS := $(AGILEX_CHARACTERIZE_DIR)/results.tsv
AGILEX_REPORT := tools/agilex_results.py
AGILEX_CHARACTERIZE := tools/agilex_core_characterize.py
AGILEX_PARALLEL_CONFIGS ?= 4
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

extension_source = rtl/riscc16_full_$(1).v
rc32_source = rtl/riscc32_$(1).v
rc32_top = riscc32_$(1)

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
    $(call rc16_yosys_width,$(width),$(profile)),$(call rc16_area_options,ecp5,$(width)), \
    $(call rc16_top,$(width),$(profile)))))))

$(foreach target,$(ECP5_AREA_TARGETS), \
  $(eval $(call ECP5_LUT_AREA,build/area/$(target)/nano.lut, \
    $(RF_DEFINES_$(target)) rtl/riscc_nano.v,,$(AREA_OPTIONS_ecp5_serial),riscc_nano)))

$(foreach target,$(ECP5_AREA_TARGETS), \
  $(foreach profile,$(RC32_PROFILES), \
    $(foreach width,$(WIDTHS), \
  $(eval $(call ECP5_LUT_AREA,build/area/$(target)/rc32/$(profile)/$(width).lut, \
    $(RF_DEFINES_$(target)) $(call rc32_source,$(profile)), \
    chparam -set W $(width) $(call rc32_top,$(profile));, \
    $(call rc32_area_options,$(target),$(profile),$(width)), \
    $(call rc32_top,$(profile)))))))

$(foreach target,$(ECP5_AREA_TARGETS), \
  $(foreach extension,$(EXTENSIONS), \
  $(eval $(call ECP5_LUT_AREA,build/area/$(target)/extension/$(extension).lut, \
    $(RF_DEFINES_$(target)) $(call extension_source,$(extension)), \
    ,$(EXTENSION_AREA_OPTIONS_ecp5),riscc16))))

# ECP5_RESOURCE_AREA(output, sources, synthesis_options, top)
define ECP5_RESOURCE_AREA
$(1): $$(AREA_RTL) $(MEASURE_RULES)
	@mkdir -p $$(@D)
	@$$(YOSYS) -p "read_verilog $(2); \
	  synth_ecp5 $(3) $(AREA_OPTIONS_ecp5_serial) \
	  -top $(4) -nowidelut; stat" \
	  2>/dev/null | awk $$(ECP5_RESOURCE_AWK) > $$@
endef

$(foreach multiplier,$(MULTIPLIERS), \
	$(eval $(call ECP5_RESOURCE_AREA,build/area/ecp5-lutram/fast/$(multiplier).resources, \
	  $(call fast_defines,ecp5,$(multiplier)) rtl/riscc16_fast.v, \
	  $(SYNTH_OPTIONS_ecp5_$(multiplier)) $(PIPELINE_AREA_OPTIONS_ecp5_fast), \
	  riscc16_fast)) \
  $(eval $(call ECP5_RESOURCE_AREA,build/area/ecp5-block/fast/$(multiplier).resources, \
    $(call fast_defines,ecp5-block,$(multiplier)) rtl/riscc16_fast.v, \
    $(SYNTH_OPTIONS_ecp5_$(multiplier)) $(PIPELINE_AREA_OPTIONS_ecp5_fast), \
    riscc16_fast)) \
  $(eval $(call ECP5_RESOURCE_AREA,build/area/ecp5-lutram/faster/$(multiplier).resources, \
    -DRISCC_ECP5 $(FASTER_DEFINES_$(multiplier)) rtl/riscc16_faster.v, \
    $(SYNTH_OPTIONS_ecp5_$(multiplier)),riscc16_faster)) \
  $(eval $(call ECP5_RESOURCE_AREA,build/area/ecp5-block/faster/$(multiplier).resources, \
    -DRISCC_FASTER_BLOCK_RF $(FASTER_DEFINES_$(multiplier)) rtl/riscc16_faster.v, \
    $(SYNTH_OPTIONS_ecp5_$(multiplier)),riscc16_faster)))

RC16_AREA_RESULTS := $(foreach target,$(AREA_TARGETS),$(foreach profile,$(RC16_PROFILES), \
  $(foreach width,$(WIDTHS),build/area/$(target)/rc16/$(profile)/$(width).lut)))
NANO_AREA_RESULTS := $(foreach target,$(AREA_TARGETS),build/area/$(target)/nano.lut)
RC32_AREA_RESULTS := $(foreach target,$(AREA_TARGETS),$(foreach profile,$(RC32_PROFILES), \
  $(foreach width,$(WIDTHS),build/area/$(target)/rc32/$(profile)/$(width).lut)))
EXTENSION_AREA_RESULTS := $(foreach target,$(AREA_TARGETS),$(foreach extension,$(EXTENSIONS), \
  build/area/$(target)/extension/$(extension).lut))
PIPELINE_AREA_RESULTS := $(foreach target,$(ECP5_AREA_TARGETS),$(foreach pipeline,$(PIPELINES), \
  $(foreach multiplier,$(MULTIPLIERS),build/area/$(target)/$(pipeline)/$(multiplier).resources)))
LATTICE_AREA_RESULTS := $(RC16_AREA_RESULTS) $(NANO_AREA_RESULTS) \
  $(RC32_AREA_RESULTS) $(EXTENSION_AREA_RESULTS) $(PIPELINE_AREA_RESULTS)

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
	for pipeline in $(PIPELINES); do for multiplier in $(MULTIPLIERS); do \
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

FMAX_DEFINES_serial_min := -DRISCC_FMAX_RC16 -DRISCC_FMAX_MIN
FMAX_DEFINES_serial_sys := -DRISCC_FMAX_RC16
FMAX_DEFINES_serial_full := -DRISCC_FMAX_RC16
FMAX_DEFINES_wide_min := -DRISCC_FMAX_RC16_MIN
FMAX_DEFINES_wide_sys :=
FMAX_DEFINES_wide_full :=
FMAX_WIDTH_1 := -DRISCC_FMAX_WIDTH=1
FMAX_WIDTH_2 := -DRISCC_FMAX_WIDTH=2
FMAX_WIDTH_4 := -DRISCC_FMAX_WIDTH=4
FMAX_WIDTH_8 := -DRISCC_FMAX_WIDTH=8
FMAX_WIDTH_16 :=
RC32_FMAX_DEFINES_min := -DRISCC_FMAX_RC32_MIN
RC32_FMAX_DEFINES_sys := -DRISCC_FMAX_RC32_SYS
rc16_fmax_defines = \
	$(FMAX_DEFINES_$(call rc16_implementation,$(2))_$(1)) $(FMAX_WIDTH_$(2))
FMAX_AWK = '/Max frequency for clock/ { \
	for (i = 1; i < NF; i++) if ($$(i + 1) == "MHz") value = $$i \
	} END { print value }'

# ECP5_FMAX(output, definitions_and_source, synthesis_options, target_mhz)
define ECP5_FMAX
$(1): $$(FMAX_RTL)
	@mkdir -p $$(@D)
	@$$(YOSYS) -q -p "read_verilog $(2) $$(FMAX_TOP); \
	  synth_ecp5 $(3) -nowidelut -top riscc_fmax_top \
	  -json $$(@:.mhz=.json)"
	@$$(NEXTPNR_ECP5) --25k --package CABGA256 --speed 6 \
	  --lpf-allow-unconstrained --freq $(4) --seed $$(PNR_SEED) \
	  --json $$(@:.mhz=.json) --textcfg $$(@:.mhz=.config) >$$(@:.mhz=.log) 2>&1
	@awk $$(FMAX_AWK) $$(@:.mhz=.log) > $$@
endef

$(foreach profile,$(RC16_PROFILES),$(foreach width,$(WIDTHS), \
  $(eval $(call ECP5_FMAX,build/fmax/ecp5/rc16/$(profile)/$(width).mhz, \
    -DRISCC_ECP5 -DRISCC_ECP5_BLOCK_RF \
    $(call rc16_fmax_defines,$(profile),$(width)) $(call rc16_source,$(width),$(profile)), \
    $(RC16_FMAX_OPTIONS_ecp5_$(width)),40))))

$(foreach profile,$(RC32_PROFILES),$(foreach width,$(WIDTHS), \
  $(eval $(call ECP5_FMAX,build/fmax/ecp5/rc32/$(profile)/$(width).mhz, \
    -DRISCC_ECP5 -DRISCC_ECP5_BLOCK_RF $(RC32_FMAX_DEFINES_$(profile)) \
    -DRISCC_FMAX_WIDTH=$(width) \
    $(call rc32_source,$(profile)),$(RC32_FMAX_OPTIONS_ecp5),40))))

$(eval $(call ECP5_FMAX,build/fmax/ecp5/nano.mhz, \
  -DRISCC_ECP5 -DRISCC_ECP5_BLOCK_RF -DRISCC_FMAX_NANO rtl/riscc_nano.v,,40))

$(foreach extension,$(EXTENSIONS), \
  $(eval $(call ECP5_FMAX,build/fmax/ecp5/extension/$(extension).mhz, \
    -DRISCC_ECP5 -DRISCC_ECP5_BLOCK_RF \
    $(call extension_source,$(extension)),,40)))

$(foreach multiplier,$(MULTIPLIERS), \
  $(eval $(call ECP5_FMAX,build/fmax/ecp5/fast/$(multiplier).mhz, \
    -DRISCC_FMAX_FAST $(call fast_defines,ecp5-block,$(multiplier)) \
    rtl/riscc16_fast.v, \
    $(SYNTH_OPTIONS_ecp5_$(multiplier)) $(FAST_FMAX_OPTIONS_ecp5_$(multiplier)),40)) \
  $(eval $(call ECP5_FMAX,build/fmax/ecp5/faster/$(multiplier).mhz, \
    -DRISCC_FMAX_FASTER -DRISCC_FASTER_BLOCK_RF \
    $(FASTER_DEFINES_$(multiplier)) rtl/riscc16_faster.v, \
    $(SYNTH_OPTIONS_ecp5_$(multiplier)) $(FASTER_FMAX_OPTIONS_ecp5),40)))

RC16_FMAX_RESULTS := $(foreach profile,$(RC16_PROFILES), \
  $(foreach width,$(WIDTHS),build/fmax/ecp5/rc16/$(profile)/$(width).mhz))
RC32_FMAX_RESULTS := $(foreach profile,$(RC32_PROFILES), \
  $(foreach width,$(WIDTHS),build/fmax/ecp5/rc32/$(profile)/$(width).mhz))
OTHER_FMAX_RESULTS := build/fmax/ecp5/nano.mhz \
  $(foreach extension,$(EXTENSIONS),build/fmax/ecp5/extension/$(extension).mhz) \
  $(foreach pipeline,$(PIPELINES),$(foreach multiplier,$(MULTIPLIERS), \
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
	  for pipeline in $(PIPELINES); do for multiplier in $(MULTIPLIERS); do \
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

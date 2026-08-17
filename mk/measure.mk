MEASURE_RULES := Makefile mk/measure.mk

# Area uses one policy for serial/RC32 cores and the normal mapper for the
# separate wide implementation. Profiles do not affect synthesis options.
AREA_OPTIONS_ice40_serial := -abc2
AREA_OPTIONS_ice40_wide :=
AREA_OPTIONS_ecp5_serial := -abc2
AREA_OPTIONS_ecp5_wide :=
EXTENSION_AREA_OPTIONS_ice40 :=
EXTENSION_AREA_OPTIONS_ecp5 := -abc2
RC16_AREA_OPTIONS_ecp5_1 := -noccu2 -dff
RC32_AREA_OPTIONS_ice40_4 := -abc2 -dff
RC32_AREA_OPTIONS_ice40_8 := -abc2 -dff
PIPELINE_AREA_OPTIONS_ice40_fast := -dff
PIPELINE_AREA_OPTIONS_ecp5_fast := -dff
rc16_area_options = $(or $(RC16_AREA_OPTIONS_$(1)_$(2)), \
	$(AREA_OPTIONS_$(1)_$(call rc16_implementation,$(2))))

FMAX_OPTIONS_ice40 := -abc9 -device u -dff
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
AREA_RTL := $(wildcard rtl/riscc*.v rtl/riscc*.vh)
AGILEX_RTL := $(AREA_RTL) $(RTL_TEST_DIR)/riscc_fmax_top.v $(TRACE_RTL)

$(AGILEX_RESULTS): $(AGILEX_CHARACTERIZE) $(AGILEX_RTL) $(MEASURE_RULES)
	$(PYTHON) $(AGILEX_CHARACTERIZE) \
	  --quartus "$(QUARTUS_SH)" --out $(AGILEX_CHARACTERIZE_DIR) \
	  --family all --jobs $(RISCC_BUILD_JOBS)

characterize-agilex:
	$(PYTHON) $(AGILEX_CHARACTERIZE) \
	  --quartus "$(QUARTUS_SH)" --out $(AGILEX_CHARACTERIZE_DIR) \
	  --family $(AGILEX_FAMILY) --jobs $(RISCC_BUILD_JOBS)

AREA_TARGETS := ice40 ecp5-block ecp5-lutram
ECP5_AREA_TARGETS := ecp5-block ecp5-lutram
AGILEX_FAMILY ?= all

extension_source = rtl/riscc16_full_$(1).v
rc32_source = rtl/riscc32_$(1).v
rc32_top = riscc32_$(1)

SYNTH_OPTIONS_ice40_soft :=
SYNTH_OPTIONS_ice40_dsp := -dsp
SYNTH_OPTIONS_ecp5_soft :=
SYNTH_OPTIONS_ecp5_dsp :=

ICE40_LUT_AWK = '$$1 == "SB_LUT4" { value = $$2 } \
	END { print value + 0 }'
ECP5_LUT_AWK = '$$1 == "LUT4" { lut = $$2 } \
	$$1 == "CCU2C" { carry = $$2 } \
	$$1 == "TRELLIS_DPR16X4" { ram = $$2 } \
	END { print lut + 2 * carry + 6 * ram }'
ICE40_RESOURCE_AWK = '$$1 == "SB_LUT4" { lut = $$2 } \
	$$1 == "SB_MAC16" { dsp = $$2 } \
	$$1 == "SB_RAM40_4K" { ebr = $$2 } \
	END { print lut + 0, dsp + 0, ebr + 0 }'
ECP5_RESOURCE_AWK = '$$1 == "LUT4" { lut = $$2 } \
	$$1 == "CCU2C" { carry = $$2 } \
	$$1 == "MULT18X18D" { dsp = $$2 } \
	$$1 == "TRELLIS_DPR16X4" { ram = $$2 } \
	END { print lut + 2 * carry + 6 * ram, lut + 0, 2 * carry, \
	       4 * ram, 2 * ram, dsp + 0, ram + 0 }'

# ICE40_LUT_AREA(output, sources, setup, synthesis_options, top)
define ICE40_LUT_AREA
$(1): $$(AREA_RTL) $(MEASURE_RULES)
	@mkdir -p $$(@D)
	@$$(YOSYS) -p "read_verilog $(2); $(3) synth_ice40 $(4) -top $(5); stat" \
	  2>/dev/null | awk $$(ICE40_LUT_AWK) > $$@
endef

# A DPR16X4 occupies four RAM LUT sites and two RAMW sites, hence 6*r.
# ECP5_LUT_AREA(output, sources, setup, synthesis_options, top)
define ECP5_LUT_AREA
$(1): $$(AREA_RTL) $(MEASURE_RULES)
	@mkdir -p $$(@D)
	@$$(YOSYS) -p "read_verilog $(2); $(3) synth_ecp5 $(4) -top $(5) -nowidelut; stat" \
	  2>/dev/null | awk $$(ECP5_LUT_AWK) > $$@
endef

$(foreach profile,$(RC16_PROFILES),$(foreach width,$(WIDTHS), \
  $(eval $(call ICE40_LUT_AREA,build/area/ice40/rc16/$(profile)/$(width).lut, \
    $(call rc16_source,$(width),$(profile)),$(call rc16_yosys_width,$(width),$(profile)), \
    $(call rc16_area_options,ice40,$(width)),$(call rc16_top,$(width),$(profile))))))
$(foreach target,$(ECP5_AREA_TARGETS), \
  $(foreach profile,$(RC16_PROFILES), \
    $(foreach width,$(WIDTHS), \
  $(eval $(call ECP5_LUT_AREA,build/area/$(target)/rc16/$(profile)/$(width).lut, \
    $(RF_DEFINES_$(target)) $(call rc16_source,$(width),$(profile)), \
    $(call rc16_yosys_width,$(width),$(profile)),$(call rc16_area_options,ecp5,$(width)), \
    $(call rc16_top,$(width),$(profile)))))))

$(eval $(call ICE40_LUT_AREA,build/area/ice40/nano.lut,rtl/riscc_nano.v,, \
  $(AREA_OPTIONS_ice40_serial),riscc_nano))
$(foreach target,$(ECP5_AREA_TARGETS), \
  $(eval $(call ECP5_LUT_AREA,build/area/$(target)/nano.lut, \
    $(RF_DEFINES_$(target)) rtl/riscc_nano.v,,$(AREA_OPTIONS_ecp5_serial),riscc_nano)))

$(foreach profile,$(RC32_PROFILES),$(foreach width,$(WIDTHS), \
  $(eval $(call ICE40_LUT_AREA,build/area/ice40/rc32/$(profile)/$(width).lut, \
    $(call rc32_source,$(profile)),chparam -set W $(width) $(call rc32_top,$(profile));, \
    $(or $(RC32_AREA_OPTIONS_ice40_$(width)),$(AREA_OPTIONS_ice40_serial)), \
    $(call rc32_top,$(profile))))))
$(foreach target,$(ECP5_AREA_TARGETS), \
  $(foreach profile,$(RC32_PROFILES), \
    $(foreach width,$(WIDTHS), \
  $(eval $(call ECP5_LUT_AREA,build/area/$(target)/rc32/$(profile)/$(width).lut, \
    $(RF_DEFINES_$(target)) $(call rc32_source,$(profile)), \
    chparam -set W $(width) $(call rc32_top,$(profile));, \
    $(AREA_OPTIONS_ecp5_serial),$(call rc32_top,$(profile)))))))

$(foreach extension,$(EXTENSIONS), \
  $(eval $(call ICE40_LUT_AREA,build/area/ice40/extension/$(extension).lut, \
    $(call extension_source,$(extension)),,$(EXTENSION_AREA_OPTIONS_ice40),riscc16)))
$(foreach target,$(ECP5_AREA_TARGETS), \
  $(foreach extension,$(EXTENSIONS), \
  $(eval $(call ECP5_LUT_AREA,build/area/$(target)/extension/$(extension).lut, \
    $(RF_DEFINES_$(target)) $(call extension_source,$(extension)), \
    ,$(EXTENSION_AREA_OPTIONS_ecp5),riscc16))))

# ICE40_RESOURCE_AREA(output, sources, synthesis_options, top)
define ICE40_RESOURCE_AREA
$(1): $$(AREA_RTL) $(MEASURE_RULES)
	@mkdir -p $$(@D)
	@$$(YOSYS) -p "read_verilog $(2); synth_ice40 $(3) $(AREA_OPTIONS_ice40_serial) -top $(4); stat" \
	  2>/dev/null | awk $$(ICE40_RESOURCE_AWK) > $$@
endef

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
	$(eval $(call ICE40_RESOURCE_AREA,build/area/ice40/fast/$(multiplier).resources, \
	  $(call fast_defines,ice40,$(multiplier)) rtl/riscc16_fast.v, \
	  $(SYNTH_OPTIONS_ice40_$(multiplier)) $(PIPELINE_AREA_OPTIONS_ice40_fast), \
	  riscc16_fast)) \
	$(eval $(call ECP5_RESOURCE_AREA,build/area/ecp5-lutram/fast/$(multiplier).resources, \
	  $(call fast_defines,ecp5,$(multiplier)) rtl/riscc16_fast.v, \
	  $(SYNTH_OPTIONS_ecp5_$(multiplier)) $(PIPELINE_AREA_OPTIONS_ecp5_fast), \
	  riscc16_fast)) \
  $(eval $(call ICE40_RESOURCE_AREA,build/area/ice40/faster/$(multiplier).resources, \
    -DRISCC_FASTER_ICE40 $(FASTER_DEFINES_$(multiplier)) rtl/riscc16_faster.v, \
    $(SYNTH_OPTIONS_ice40_$(multiplier)),riscc16_faster)) \
  $(eval $(call ECP5_RESOURCE_AREA,build/area/ecp5-lutram/faster/$(multiplier).resources, \
    -DRISCC_ECP5 $(FASTER_DEFINES_$(multiplier)) rtl/riscc16_faster.v, \
    $(SYNTH_OPTIONS_ecp5_$(multiplier)),riscc16_faster)))

RC16_AREA_RESULTS := $(foreach target,$(AREA_TARGETS),$(foreach profile,$(RC16_PROFILES), \
  $(foreach width,$(WIDTHS),build/area/$(target)/rc16/$(profile)/$(width).lut)))
NANO_AREA_RESULTS := $(foreach target,$(AREA_TARGETS),build/area/$(target)/nano.lut)
RC32_AREA_RESULTS := $(foreach target,$(AREA_TARGETS),$(foreach profile,$(RC32_PROFILES), \
  $(foreach width,$(WIDTHS),build/area/$(target)/rc32/$(profile)/$(width).lut)))
EXTENSION_AREA_RESULTS := $(foreach target,$(AREA_TARGETS),$(foreach extension,$(EXTENSIONS), \
  build/area/$(target)/extension/$(extension).lut))
PIPELINE_AREA_RESULTS := $(foreach target,ice40 ecp5-lutram,$(foreach pipeline,$(PIPELINES), \
  $(foreach multiplier,$(MULTIPLIERS),build/area/$(target)/$(pipeline)/$(multiplier).resources)))
LATTICE_AREA_RESULTS := $(RC16_AREA_RESULTS) $(NANO_AREA_RESULTS) \
  $(RC32_AREA_RESULTS) $(EXTENSION_AREA_RESULTS) $(PIPELINE_AREA_RESULTS)

.PHONY: area area-lattice area-agilex area-all characterize-agilex

area: area-lattice

area-lattice: $(LATTICE_AREA_RESULTS)
	@for target in $(AREA_TARGETS); do \
	  case $$target in ice40) title='iCE40 LUT4 (RF in EBR)';; \
	    ecp5-block) title='ECP5 LUT sites (RF in block RAM)';; \
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
	@printf '%-16s %7s %10s %10s\n' implementation iCE40 'ECP5 block' 'ECP5 RF'; \
	printf '%-16s %7s %10s %10s\n' 'full base' \
	  "$$(cat build/area/ice40/rc16/full/16.lut)" \
	  "$$(cat build/area/ecp5-block/rc16/full/16.lut)" \
	  "$$(cat build/area/ecp5-lutram/rc16/full/16.lut)"; \
	for extension in $(EXTENSIONS); do printf '%-16s %7s %10s %10s\n' "full $$extension" \
	  "$$(cat build/area/ice40/extension/$$extension.lut)" \
	  "$$(cat build/area/ecp5-block/extension/$$extension.lut)" \
	  "$$(cat build/area/ecp5-lutram/extension/$$extension.lut)"; done
	@printf '%-16s %18s %18s\n' implementation 'iCE40 LUT/DSP/EBR' 'ECP5 LUT/DSP/EBR'; \
	for pipeline in $(PIPELINES); do for multiplier in $(MULTIPLIERS); do \
	  set -- $$(cat build/area/ice40/$$pipeline/$$multiplier.resources); \
	  ilut=$$1; idsp=$$2; iebr=$$3; \
	  set -- $$(cat build/area/ecp5-lutram/$$pipeline/$$multiplier.resources); \
	  elut=$$1; edsp=$$6; eebr=$$7; \
	  printf '%-16s %12s/%s/%s %12s/%s/%s\n' "$$pipeline $$multiplier" \
	    $$ilut $$idsp $$iebr $$elut $$edsp $$eebr; \
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

# ICE40_FMAX(output, definitions_and_source, synthesis_options)
define ICE40_FMAX
$(1): $$(FMAX_RTL)
	@mkdir -p $$(@D)
	@$$(YOSYS) -q -p "read_verilog $(2) $$(FMAX_TOP); \
	  synth_ice40 $(3) $$(FMAX_OPTIONS_ice40) \
	  -top riscc_fmax_top -json $$(@:.mhz=.json)"
	@$$(NEXTPNR_ICE40) --up5k --package sg48 --pcf-allow-unconstrained \
	  --freq 10 --seed $$(PNR_SEED) --json $$(@:.mhz=.json) \
	  --asc $$(@:.mhz=.asc) >$$(@:.mhz=.log) 2>&1
	@awk $$(FMAX_AWK) $$(@:.mhz=.log) > $$@
endef

# ECP5_FMAX(output, definitions_and_source, synthesis_options, target_mhz)
define ECP5_FMAX
$(1): $$(FMAX_RTL)
	@mkdir -p $$(@D)
	@$$(YOSYS) -q -p "read_verilog -DRISCC_ECP5 $(2) $$(FMAX_TOP); \
	  synth_ecp5 $(3) -nowidelut -top riscc_fmax_top \
	  -json $$(@:.mhz=.json)"
	@$$(NEXTPNR_ECP5) --25k --package CABGA256 --speed 6 \
	  --lpf-allow-unconstrained --freq $(4) --seed $$(PNR_SEED) \
	  --json $$(@:.mhz=.json) --textcfg $$(@:.mhz=.config) >$$(@:.mhz=.log) 2>&1
	@awk $$(FMAX_AWK) $$(@:.mhz=.log) > $$@
endef

$(foreach profile,$(RC16_PROFILES),$(foreach width,$(WIDTHS), \
  $(eval $(call ICE40_FMAX,build/fmax/ice40/rc16/$(profile)/$(width).mhz, \
    $(call rc16_fmax_defines,$(profile),$(width)) $(call rc16_source,$(width),$(profile)),)) \
  $(eval $(call ECP5_FMAX,build/fmax/ecp5/rc16/$(profile)/$(width).mhz, \
    $(call rc16_fmax_defines,$(profile),$(width)) $(call rc16_source,$(width),$(profile)), \
    $(RC16_FMAX_OPTIONS_ecp5_$(width)),40))))

$(foreach profile,$(RC32_PROFILES),$(foreach width,$(WIDTHS), \
  $(eval $(call ICE40_FMAX,build/fmax/ice40/rc32/$(profile)/$(width).mhz, \
    $(RC32_FMAX_DEFINES_$(profile)) -DRISCC_FMAX_WIDTH=$(width) \
    $(call rc32_source,$(profile)),)) \
  $(eval $(call ECP5_FMAX,build/fmax/ecp5/rc32/$(profile)/$(width).mhz, \
    $(RC32_FMAX_DEFINES_$(profile)) -DRISCC_FMAX_WIDTH=$(width) \
    $(call rc32_source,$(profile)),$(RC32_FMAX_OPTIONS_ecp5),40))))

$(eval $(call ICE40_FMAX,build/fmax/ice40/nano.mhz, \
  -DRISCC_FMAX_NANO rtl/riscc_nano.v,))
$(eval $(call ECP5_FMAX,build/fmax/ecp5/nano.mhz, \
  -DRISCC_FMAX_NANO rtl/riscc_nano.v,,40))

$(foreach extension,$(EXTENSIONS), \
  $(eval $(call ICE40_FMAX,build/fmax/ice40/extension/$(extension).mhz, \
    $(call extension_source,$(extension)),)) \
  $(eval $(call ECP5_FMAX,build/fmax/ecp5/extension/$(extension).mhz, \
    $(call extension_source,$(extension)),,40)))

$(foreach multiplier,$(MULTIPLIERS), \
  $(eval $(call ICE40_FMAX,build/fmax/ice40/fast/$(multiplier).mhz, \
    -DRISCC_FMAX_FAST $(call fast_defines,ice40,$(multiplier)) rtl/riscc16_fast.v, \
    $(SYNTH_OPTIONS_ice40_$(multiplier)))) \
  $(eval $(call ECP5_FMAX,build/fmax/ecp5/fast/$(multiplier).mhz, \
    -DRISCC_FMAX_FAST $(MULTIPLIER_DEFINES_$(multiplier)) rtl/riscc16_fast.v, \
    $(SYNTH_OPTIONS_ecp5_$(multiplier)) $(FAST_FMAX_OPTIONS_ecp5_$(multiplier)),50)) \
  $(eval $(call ICE40_FMAX,build/fmax/ice40/faster/$(multiplier).mhz, \
    -DRISCC_FMAX_FASTER -DRISCC_FASTER_ICE40 $(FASTER_DEFINES_$(multiplier)) \
    rtl/riscc16_faster.v,$(SYNTH_OPTIONS_ice40_$(multiplier)))) \
  $(eval $(call ECP5_FMAX,build/fmax/ecp5/faster/$(multiplier).mhz, \
    -DRISCC_FMAX_FASTER $(FASTER_DEFINES_$(multiplier)) rtl/riscc16_faster.v, \
    $(SYNTH_OPTIONS_ecp5_$(multiplier)) $(FASTER_FMAX_OPTIONS_ecp5),50)))

RC16_FMAX_RESULTS := $(foreach target,ice40 ecp5,$(foreach profile,$(RC16_PROFILES), \
  $(foreach width,$(WIDTHS),build/fmax/$(target)/rc16/$(profile)/$(width).mhz)))
RC32_FMAX_RESULTS := $(foreach target,ice40 ecp5,$(foreach profile,$(RC32_PROFILES), \
  $(foreach width,$(WIDTHS),build/fmax/$(target)/rc32/$(profile)/$(width).mhz)))
OTHER_FMAX_RESULTS := $(foreach target,ice40 ecp5,build/fmax/$(target)/nano.mhz \
  $(foreach extension,$(EXTENSIONS),build/fmax/$(target)/extension/$(extension).mhz) \
  $(foreach pipeline,$(PIPELINES),$(foreach multiplier,$(MULTIPLIERS), \
    build/fmax/$(target)/$(pipeline)/$(multiplier).mhz)))
LATTICE_FMAX_RESULTS := $(RC16_FMAX_RESULTS) $(RC32_FMAX_RESULTS) $(OTHER_FMAX_RESULTS)

fmax: fmax-lattice

fmax-lattice: $(LATTICE_FMAX_RESULTS)
	@for target in ice40 ecp5; do \
	  case $$target in ice40) title='UP5K iCE40';; *) title='ECP5 LFE5U-25F speed 6';; esac; \
	  echo "$$title; fixed seed $(PNR_SEED)"; \
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
	  done; done; \
	done

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
	$(PYTHON) tools/lattice_tune.py ice40 all \
	  --seeds $(TUNE_SEEDS) -j $(RISCC_BUILD_JOBS)
	$(PYTHON) tools/lattice_tune.py ecp5 all \
	  --seeds $(TUNE_SEEDS) -j $(RISCC_BUILD_JOBS)
	+$(MAKE) --no-print-directory bench

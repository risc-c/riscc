# Shared build recipe for the Terasic demo boards.
# Arguments: variable prefix, project/directory name, public target prefix.
define AGILEX3_BOARD_RULES
.PHONY: $(3)-demo-bin $(3)-demo-iss $(3)-demo-rtlsim $(3)-demo $(3)-test-bin $(3)-test

$(1)_DIR := boards/$(2)
$(1)_BUILD := build/$(2)
$(1)_BIN := $$($(1)_BUILD)/demo.bin
$(1)_PROGRAM ?= $$(DEMO_PROGRAM)
$(1)_OBJ := $$($(1)_BUILD)/demo.o
$(1)_PROGRAM_SELECTION := $$($(1)_BUILD)/demo.program
$(1)_ELF := $$($(1)_BUILD)/demo.elf
$(1)_MEMH := $$($(1)_BUILD)/mem/demo.memh
$(1)_MIF := $$($(1)_MEMH).mif
$(1)_RTLSIM := $$($(1)_BUILD)/rtlsim/Vriscc_demo_soc_sim
$(1)_QUARTUS_BUILD := $$($(1)_BUILD)/quartus
$(1)_QUARTUS_QPF := $$($(1)_QUARTUS_BUILD)/$(2).qpf
$(1)_QUARTUS_QSF := $$($(1)_QUARTUS_BUILD)/$(2).qsf
$(1)_RESET_IP := $$($(1)_QUARTUS_BUILD)/ip/agilex3_config_reset.ip
$(1)_IPGENERATE = $$(patsubst %quartus_sh,%quartus_ipgenerate,$$(QUARTUS_SH))
$(1)_QUARTUS_MEM := $$($(1)_QUARTUS_BUILD)/mem
$(1)_FULL_BUILD_STAMP := $$($(1)_QUARTUS_BUILD)/.full-build
$(1)_SOF := $$($(1)_QUARTUS_BUILD)/output_files/$(2).sof
$(1)_SOC_RTL := \
  $$(DEMO_PERIPH_RTL) \
  boards/shared/rtl/riscc_demo_soc.v
$(1)_SIM_RTL := \
  $$(DEMO_MEMORY_SIM_RTL) \
  boards/shared/rtl/riscc_video_parallel.v \
  boards/shared/test/riscc_demo_soc_sim.v \
  $$($(1)_SOC_RTL) \
  rtl/riscc_cached.v \
  rtl/riscc_fast.v
$(1)_HW_RTL := \
  boards/shared/rtl/agilex3_demo_system.v \
  boards/shared/rtl/riscc_i2c_reg.v \
  $$($(1)_DIR)/rtl/top.v \
  $$(DEMO_SDRAM_RTL) \
  boards/shared/rtl/agilex3_sdram.v \
  boards/shared/rtl/agilex3_sdram_pll.v \
  boards/shared/rtl/agilex3_video_pll.v \
  boards/shared/rtl/agilex3_reset_release.v \
  $$($(1)_SOC_RTL) \
  boards/shared/rtl/riscc_video_parallel.v \
  $$($(1)_TRANSMITTER_RTL) \
  rtl/riscc_cached.v \
  rtl/riscc_fast.v
$(1)_PROJECT_FILES := \
  $$($(1)_DIR)/$(2).qpf \
  $$($(1)_DIR)/$(2).qsf \
  $$($(1)_DIR)/$(2).sdc \
  $$($(1)_HW_RTL) \
  boards/shared/agilex3.qsf \
  boards/shared/agilex3.sdc
$(1)_FULL_BUILD_DEPS := \
  $$($(1)_PROJECT_FILES) \
  $$($(1)_QUARTUS_QPF) \
  $$($(1)_QUARTUS_QSF) \
  $$($(1)_RESET_IP) \
  $$(RISCC_RF_RTL) \
  $$(BOARD_RULES)

$$($(1)_MEMH): $$($(1)_BIN) tools/bin_to_memh.py $$(BOARD_RULES)
	@mkdir -p $$(@D)
	$$(PYTHON) tools/bin_to_memh.py $$< -o $$@ --width 32 --depth 4096

$$($(1)_MIF): $$($(1)_BIN) tools/bin_to_memh.py $$(BOARD_RULES)
	@mkdir -p $$(@D)
	$$(PYTHON) tools/bin_to_memh.py $$< -o $$@ --width 32 --depth 4096 --format mif

$(3)-demo-bin: $$($(1)_BIN) $$($(1)_MEMH) $$($(1)_MIF)

$(3)-demo-iss: $$($(1)_BIN) $$(RISCC_SIM)
	$$(RISCC_SIM) $$< --rc32-full --board-rc32 --uart --fb-window --fb-scale 4 --mhz $$($(1)_CPU_MHZ) --max-insns 0

$$($(1)_RTLSIM): $$($(1)_MEMH) $$($(1)_SIM_RTL) boards/shared/test/riscc_demo_soc_tb.cpp $$(BOARD_RULES)
	@mkdir -p $$(@D)
	+$$(VERILATOR) -cc --exe --build $$(VERILATOR_MAKEFLAGS_ARG) \
	  --top-module riscc_demo_soc_sim --prefix Vriscc_demo_soc_sim \
	  -Mdir $$(@D) -GVIDEO_SCALE=$$($(1)_VIDEO_SCALE) -GMEM_HEX='"$$($(1)_MEMH)"' -I$$(abspath rtl) \
	  -CFLAGS "$$(TB_CXXFLAGS)" -o Vriscc_demo_soc_sim \
	  $$(abspath $$($(1)_SIM_RTL)) $$(abspath boards/shared/test/riscc_demo_soc_tb.cpp)

$(3)-demo-rtlsim: $$($(1)_RTLSIM)
	$$($(1)_RTLSIM) "RISC-C on $$($(1)_NAME)"

$$($(1)_QUARTUS_QPF): $$($(1)_DIR)/$(2).qpf
	@mkdir -p $$(@D)
	cp $$< $$@

$$($(1)_QUARTUS_QSF): $$($(1)_DIR)/$(2).qsf
	@mkdir -p $$(@D)
	cp $$< $$@

$$($(1)_QUARTUS_MEM): | $$($(1)_QUARTUS_QSF)
	ln -sfn ../mem $$@

$$($(1)_RESET_IP): $$(BOARD_RULES)
	@mkdir -p $$(@D)
	@quartus_sh=$$$$(command -v "$$(QUARTUS_SH)") || { \
	    echo "Quartus not found: $$(QUARTUS_SH). Set QUARTUS_SH=/path/to/quartus/bin/quartus_sh" >&2; exit 1; }; \
	  quartus_bin=$$$$(dirname "$$$$quartus_sh"); \
	  "$$$$quartus_bin/../sopc_builder/bin/ip-deploy" \
	    --component-name=altera_s10_user_rst_clkgate \
	    --output-name=agilex3_config_reset --output-directory="$$(abspath $$(@D))" \
	    --part=A3CZ135BB18AE7S

$$($(1)_FULL_BUILD_STAMP): $$($(1)_FULL_BUILD_DEPS) | \
		$$($(1)_MIF) $$($(1)_QUARTUS_MEM)
	cd $$($(1)_QUARTUS_BUILD) && \
	  RISCC_BUILD_JOBS=$$(RISCC_BUILD_JOBS) \
	  $$($(1)_IPGENERATE) --generate_ip_file --synthesis=verilog \
	    --ip_file=ip/agilex3_config_reset.ip $(2)
	cd $$($(1)_QUARTUS_BUILD) && \
	  RISCC_BUILD_JOBS=$$(RISCC_BUILD_JOBS) \
	  $$(QUARTUS_SH) $$(QUARTUS_FLOW_ARGS) --flow compile \
	  $(2)
	@test -f $$($(1)_SOF)
	@touch $$@

$$($(1)_SOF): $$($(1)_FULL_BUILD_STAMP) $$($(1)_MIF)
	cd $$($(1)_QUARTUS_BUILD) && \
	  RISCC_BUILD_JOBS=$$(RISCC_BUILD_JOBS) \
	  $$(QUARTUS_CDB) --update_mif $(2)
	cd $$($(1)_QUARTUS_BUILD) && \
	  RISCC_BUILD_JOBS=$$(RISCC_BUILD_JOBS) \
	  $$(QUARTUS_ASM) $(2)
	@printf '$$($(1)_NAME) SOF: %s\n' '$$@'

$(3)-demo: $$($(1)_SOF)

$$($(1)_PROGRAM_SELECTION): demo-program-selection-check
	@mkdir -p $$(@D)
	@printf '%s\n' '$$(abspath $$($(1)_PROGRAM))' > $$@.tmp
	@cmp -s $$@.tmp $$@ && rm $$@.tmp || mv $$@.tmp $$@

-include $$($(1)_OBJ:.o=.d)

$$($(1)_OBJ): $$($(1)_PROGRAM) $$($(1)_PROGRAM_SELECTION) $$(LIBC_HEADERS) $$(BOARD_RULES) $$(RISCC_CLANG)
	@mkdir -p $$(@D)
	$$(RISCC_CLANG) $$(DEMO_TARGET_FLAGS) $$(DEMO_CXXFLAGS) \
	  $$($(1)_DEFINES) -MMD -MP -c $$< -o $$@

$$($(1)_ELF): $$(DEMO_VECTORS) $$(DEMO_CRT0) \
		$$($(1)_OBJ) $$(DEMO_LIBS) $$(DEMO_LINKER_SCRIPT) \
		$$(RISCC_CLANG) $$(RISCC_LLD)
	@mkdir -p $$(@D)
	$$(RISCC_CLANG) $$(DEMO_TARGET_FLAGS) $$(RISCC_LDFLAGS) -fuse-ld=lld -nostdlib \
	  -Wl,-T,$$(abspath $$(DEMO_LINKER_SCRIPT)) $$(DEMO_LD_FLAGS) -Wl,-Map,$$(@:.elf=.map) \
	  $$(DEMO_VECTORS) $$(DEMO_CRT0) $$($(1)_OBJ) \
	  $$(DEMO_LIBS) -o $$@

$$($(1)_BIN): $$($(1)_ELF) $$(RISCC_OBJCOPY)
	$$(RISCC_OBJCOPY) -O binary $$< $$@

$(3)-test-bin:
	+$$(MAKE) $(1)_BUILD=build/$(2)_test $(1)_PROGRAM=boards/shared/test/sdram/hardware_test.cpp $(3)-demo-bin

$(3)-test:
	+$$(MAKE) $(1)_BUILD=build/$(2)_test $(1)_PROGRAM=boards/shared/test/sdram/hardware_test.cpp $(3)-demo
	cp build/$(2)_test/quartus/output_files/$(2).sof build/$(2)_test/test.sof
endef

$(eval $(call AGILEX3_BOARD_RULES,ATUM,atum_a3_nano,atum-a3))
$(eval $(call AGILEX3_BOARD_RULES,DE23,de23_lite,de23-lite))

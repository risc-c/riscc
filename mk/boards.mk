BOARD_RULES := Makefile mk/boards.mk mk/firmware.mk

.PHONY: test-board-map
test-board-map:
	$(PYTHON) tools/test_board_map.py --verilator $(VERILATOR)

.PHONY: test-sdram-cpu fuzz-sdram-cpu test-sdram-scanout
test-sdram-cpu: llvm-riscc test-sdram-write-stream
	$(PYTHON) tools/test_sdram_cpu.py --verilator $(VERILATOR)

fuzz-sdram-cpu: llvm-riscc test-sdram-write-stream
	$(PYTHON) tools/test_sdram_cpu.py --verilator $(VERILATOR) --seeds 8

test-sdram-scanout:
	@mkdir -p build/test-sdram-scanout
	iverilog -g2012 -s sdram_scanout_tb -o build/test-sdram-scanout/test.vvp \
	  boards/shared/rtl/riscc_sdram_scanout.v test/sdram_scanout_tb.v
	vvp build/test-sdram-scanout/test.vvp

.PHONY: test-video-palette
test-video-palette:
	$(PYTHON) tools/test_video_palette.py
	$(PYTHON) tools/test_video_palette_scanout.py
	$(PYTHON) tools/test_video_palette_icepi.py

.PHONY: test-icepi-tmds
test-icepi-tmds:
	$(PYTHON) tools/test_tmds_encoder.py
	$(PYTHON) tools/test_tmds_serializer.py

# Standalone external-memory controllers and their cache-facing protocol.
.PHONY: test-sdram fuzz-sdram
test-sdram:
	$(PYTHON) tools/test_sdram.py --verilator $(VERILATOR)

.PHONY: test-sdram-bench fuzz-sdram-bench
test-sdram-bench:
	$(PYTHON) tools/test_sdram_bench.py --verilator $(VERILATOR)

fuzz-sdram-bench:
	$(PYTHON) tools/test_sdram_bench.py --verilator $(VERILATOR) --seeds 8

.PHONY: test-sdram-bridge fuzz-sdram-bridge
test-sdram-bridge:
	$(PYTHON) tools/test_sdram_bridge.py --verilator $(VERILATOR)

fuzz-sdram-bridge:
	$(PYTHON) tools/test_sdram_bridge.py --verilator $(VERILATOR) --seeds 8

fuzz-sdram:
	$(PYTHON) tools/test_sdram.py --verilator $(VERILATOR) --seeds 8

DEMO_PROGRAM ?= boards/shared/sw/demo.cpp
# Hardware tests use the normal SoC with separate firmware and build outputs.
.PHONY: icepi-zero-test-bin icepi-zero-test-bit atum-a3-test-bin atum-a3-test
icepi-zero-test-bin:
	+$(MAKE) ICEPI_BUILD=build/icepi_zero_test ICEPI_IMAGE=test \
	  ICEPI_PROGRAM=boards/shared/test/sdram/hardware_test.cpp \
	  icepi-zero-demo-bin

# Replace only boot RAM so the test exercises the timing-verified demo circuit.
icepi-zero-test-bit: icepi-zero-demo-bit icepi-zero-test-bin tools/update_ecp5_bootram.py
	$(PYTHON) tools/update_ecp5_bootram.py $(ICEPI_CONFIG) build/icepi_zero_test/test.config \
	  --from-hex $(ICEPI_MEMH) --to-hex build/icepi_zero_test/test.memh
	$(ECPPACK) --compress build/icepi_zero_test/test.config build/icepi_zero_test/test.bit
	@printf 'Icepi test bitstream: %s\n' 'build/icepi_zero_test/test.bit'

atum-a3-test-bin:
	+$(MAKE) ATUM_BUILD=build/atum_a3_nano_test \
	  ATUM_PROGRAM=boards/shared/test/sdram/hardware_test.cpp \
	  atum-a3-demo-bin

atum-a3-test:
	+$(MAKE) ATUM_BUILD=build/atum_a3_nano_test \
	  ATUM_PROGRAM=boards/shared/test/sdram/hardware_test.cpp atum-a3-demo
	cp build/atum_a3_nano_test/quartus/output_files/atum_a3_nano.sof \
	  build/atum_a3_nano_test/test.sof

DEMO_RAM_LENGTH ?= 0x4000
# Board images always use RC32 Full, independent of application defaults.
DEMO_TARGET_FLAGS := --target=riscc-none-elf -mcpu=full -mrc32 -DRISCC_BOARD_DEMO
DEMO_FIRMWARE_BUILD := build/firmware/boards-rc32/full
DEMO_VECTORS := $(DEMO_FIRMWARE_BUILD)/vectors.o
DEMO_CRT0 := $(DEMO_FIRMWARE_BUILD)/crt0.o
DEMO_LIBS := $(addprefix $(DEMO_FIRMWARE_BUILD)/,libc.a libm.a libbsp.a libirq.a libbuiltins.a)
DEMO_LINKER_SCRIPT := firmware/rc32/unified.ld
.PHONY: demo-firmware
demo-firmware:
	+$(MAKE) --no-print-directory RISCC_XLEN=32 PROFILE=full \
	  RISCC_FIRMWARE_BUILD=$(DEMO_FIRMWARE_BUILD) \
	  RISCC_TARGET_FLAGS='$(DEMO_TARGET_FLAGS)' firmware

ifneq ($(RISCC_FIRMWARE_BUILD),$(DEMO_FIRMWARE_BUILD))
$(DEMO_VECTORS) $(DEMO_CRT0) $(DEMO_LIBS): | demo-firmware
endif

DEMO_LD_FLAGS := -Wl,--defsym=__riscc_ram_length=$(DEMO_RAM_LENGTH)

# Icepi Zero

.PHONY: icepi-zero-demo-bin icepi-zero-demo-iss icepi-zero-demo-iss-test \
	icepi-zero-demo-rtlsim icepi-zero-demo-json icepi-zero-demo-bit \
	icepi-zero-video-test-bit

ICEPI_DIR := boards/icepi_zero
ICEPI_BUILD := build/icepi_zero
ICEPI_IMAGE ?= demo
ICEPI_BIN := $(ICEPI_BUILD)/$(ICEPI_IMAGE).bin
ICEPI_PROGRAM ?= $(DEMO_PROGRAM)
ICEPI_OBJ := $(ICEPI_BUILD)/$(ICEPI_IMAGE).o
ICEPI_PROGRAM_SELECTION := $(ICEPI_BUILD)/$(ICEPI_IMAGE).program
ICEPI_ELF := $(ICEPI_BUILD)/$(ICEPI_IMAGE).elf
ICEPI_MEMH := $(ICEPI_BUILD)/$(ICEPI_IMAGE).memh
ICEPI_JSON := $(ICEPI_BUILD)/$(ICEPI_IMAGE).json
ICEPI_CONFIG := $(ICEPI_BUILD)/$(ICEPI_IMAGE).config
ICEPI_BIT := $(ICEPI_BUILD)/$(ICEPI_IMAGE).bit
ICEPI_VIDEO_TEST_JSON := $(ICEPI_BUILD)/video_test.json
ICEPI_VIDEO_TEST_CONFIG := $(ICEPI_BUILD)/video_test.config
ICEPI_VIDEO_TEST_BIT := $(ICEPI_BUILD)/video_test.bit
ICEPI_RTLSIM := $(ICEPI_BUILD)/rtlsim/Vicepi_zero_soc_sim
# LUTRAM keeps CPU operand reads off the slower EBR output path.
ICEPI_CPU_DEFINES := -DRISCC_ECP5
ICEPI_DEFINES := -DRISCC_ICEPI_ZERO
ICEPI_SYNTH_OPTIONS ?= -abc9
ICEPI_SPEED ?= 6
ICEPI_NEXTPNR_OPTIONS ?= --seed $(PNR_SEED) --placer heap --tmg-ripup
ICEPI_SYNTH_REPORT = '/Number of cells:/ { cells = $$4 } \
	$$1 == "LUT4" { lut = $$2 } \
	$$1 == "DP16KD" { ebr = $$2 } \
	$$1 == "MULT18X18D" { dsp = $$2 } \
	END { printf "Icepi synth: %d cells, %d LUT4, %d EBR, %d DSP\n", \
	             cells, lut, ebr, dsp }'
ICEPI_TIMING_REPORT = '/Max frequency for clock/ { \
	if (!($$6 in clocks)) order[++count] = $$6; clocks[$$6] = $$0 \
	} END { for (i = 1; i <= count; ++i) print clocks[order[i]] }'
ICEPI_DVI_RTL := \
  $(ICEPI_DIR)/rtl/icepi_fb_dvi.v \
  $(ICEPI_DIR)/rtl/icepi_tmds_ddr.v \
  $(ICEPI_DIR)/rtl/icepi_tmds_encoder.v \
  $(ICEPI_DIR)/rtl/icepi_dvi_pll.v
DEMO_PERIPH_RTL := \
  boards/shared/rtl/riscc_uart_mmio.v \
  boards/shared/rtl/riscc_timer_mmio.v \
  boards/shared/rtl/riscc_irq_ctrl.v
DEMO_SDRAM_RTL := \
  boards/shared/rtl/riscc_sdram_bridge.v \
  boards/shared/rtl/riscc_sdram.v \
  boards/shared/rtl/riscc_sdram_fabric.v \
  boards/shared/rtl/riscc_video_palette.v \
  boards/shared/rtl/riscc_sdram_scanout.v
ICEPI_SOC_RTL := \
  $(DEMO_PERIPH_RTL) \
  $(ICEPI_DIR)/rtl/icepi_zero_soc.v
ICEPI_SYNTH_RTL := \
  $(ICEPI_DIR)/rtl/top.v \
  $(DEMO_SDRAM_RTL) \
  $(ICEPI_DIR)/rtl/icepi_sdram.v \
  $(ICEPI_DIR)/rtl/icepi_sdram_pll.v \
  $(ICEPI_SOC_RTL) \
  $(ICEPI_DVI_RTL) \
  rtl/riscc_cached.v \
  rtl/riscc_fast.v
DEMO_MEMORY_SIM_RTL := \
  boards/shared/rtl/riscc_sdram_bridge.v \
  boards/shared/rtl/riscc_sdram_fabric.v \
  boards/shared/rtl/riscc_video_palette.v \
  boards/shared/rtl/riscc_sdram_scanout.v \
  boards/shared/test/riscc_demo_memory_sim.v
ICEPI_SIM_RTL := \
  $(DEMO_MEMORY_SIM_RTL) \
  $(ICEPI_DIR)/rtl/icepi_zero_soc_sim.v \
  $(ICEPI_SOC_RTL) \
  $(ICEPI_DIR)/rtl/icepi_fb_dvi.v \
  $(ICEPI_DIR)/rtl/icepi_tmds_ddr.v \
  $(ICEPI_DIR)/rtl/icepi_tmds_encoder.v \
  rtl/riscc_cached.v \
  rtl/riscc_fast.v

$(ICEPI_MEMH): $(ICEPI_BIN) tools/bin_to_memh.py $(BOARD_RULES)
	$(PYTHON) tools/bin_to_memh.py $< -o $@ --width 32 --depth 4096

icepi-zero-demo-bin: $(ICEPI_BIN) $(ICEPI_MEMH)

icepi-zero-demo-iss: $(ICEPI_BIN) $(RISCC_SIM)
	$(RISCC_SIM) $< --rc32-full --board-rc32 --uart --fb-icepi --fb-window --mhz 66.666667 --max-insns 0

icepi-zero-demo-iss-test: $(ICEPI_BIN) $(RISCC_SIM)
	@mkdir -p build/icepi_zero
	@printf '12+' | $(RISCC_SIM) $< --rc32-full --board-rc32 --fb-icepi --uart --max-insns 3000000 \
	  > build/icepi_zero/demo_uart.txt 2> build/icepi_zero/demo_iss.log || true
	@grep -q 'RISC-C on Icepi Zero' build/icepi_zero/demo_uart.txt || { \
	  cat build/icepi_zero/demo_iss.log; exit 1; \
	}
	@echo "ISS UART expect PASS"

$(ICEPI_RTLSIM): $(ICEPI_MEMH) $(ICEPI_SIM_RTL) \
		$(ICEPI_DIR)/sim/icepi_zero_soc_tb.cpp $(BOARD_RULES)
	@mkdir -p $(@D)
	+$(VERILATOR) -cc --exe --build $(VERILATOR_MAKEFLAGS_ARG) \
	  --top-module icepi_zero_soc_sim --prefix Vicepi_zero_soc_sim \
	  -Mdir $(@D) $(ICEPI_CPU_DEFINES) -GTIMER_TICK_DIV=4 -I$(abspath rtl) \
	  -CFLAGS "$(TB_CXXFLAGS)" -o Vicepi_zero_soc_sim \
	  $(abspath $(ICEPI_SIM_RTL)) $(abspath $(ICEPI_DIR)/sim/icepi_zero_soc_tb.cpp)

icepi-zero-demo-rtlsim: $(ICEPI_RTLSIM)
	$(ICEPI_RTLSIM)

$(ICEPI_JSON): $(ICEPI_MEMH) $(ICEPI_SYNTH_RTL) $(RISCC_RF_RTL) $(BOARD_RULES)
	@mkdir -p $(@D)
	@$(YOSYS) -p "read_verilog $(ICEPI_CPU_DEFINES) $(ICEPI_SYNTH_RTL); \
	  chparam -set MEM_HEX \"$(ICEPI_MEMH)\" top; \
	  hierarchy -top top; setattr -mod -set keep_hierarchy 1 A:hdlname=*riscc_sdram; \
	  synth_ecp5 $(ICEPI_SYNTH_OPTIONS) -top top; \
	  setattr -mod -unset keep_hierarchy; setattr -unset keep_hierarchy; flatten; write_json $@" \
	  >$(ICEPI_BUILD)/$(ICEPI_IMAGE)-yosys.log 2>&1 || { \
	    tail -80 $(ICEPI_BUILD)/$(ICEPI_IMAGE)-yosys.log; exit 1; \
	  }
	@awk $(ICEPI_SYNTH_REPORT) $(ICEPI_BUILD)/$(ICEPI_IMAGE)-yosys.log

$(ICEPI_CONFIG): $(ICEPI_JSON) $(ICEPI_DIR)/icepi-zero.lpf $(ICEPI_DIR)/sdram-preplace.py
	@$(NEXTPNR_ECP5) --25k --package CABGA256 --speed $(ICEPI_SPEED) \
	  $(ICEPI_NEXTPNR_OPTIONS) --pre-place $(ICEPI_DIR)/sdram-preplace.py --lpf $(ICEPI_DIR)/icepi-zero.lpf \
	  --json $< --textcfg $@.tmp >$(ICEPI_BUILD)/$(ICEPI_IMAGE)-nextpnr.log 2>&1 || \
	  { tail -80 $(ICEPI_BUILD)/$(ICEPI_IMAGE)-nextpnr.log; exit 1; }
	@mv $@.tmp $@
	@awk $(ICEPI_TIMING_REPORT) $(ICEPI_BUILD)/$(ICEPI_IMAGE)-nextpnr.log

$(ICEPI_BIT): $(ICEPI_CONFIG)
	@$(ECPPACK) --compress $< $@
	@printf 'Icepi bitstream: %s\n' '$@'

icepi-zero-demo-json: $(ICEPI_JSON)
icepi-zero-demo-bit: $(ICEPI_BIT)

$(ICEPI_VIDEO_TEST_JSON): $(ICEPI_MEMH) $(ICEPI_SYNTH_RTL) \
		$(RISCC_RF_RTL) $(BOARD_RULES)
	@mkdir -p $(@D)
	@$(YOSYS) -p "read_verilog $(ICEPI_CPU_DEFINES) \
	  -DICEPI_VIDEO_TEST $(ICEPI_SYNTH_RTL); \
	  chparam -set MEM_HEX \"$(ICEPI_MEMH)\" top; \
	  synth_ecp5 $(ICEPI_SYNTH_OPTIONS) -top top -json $@" \
	  >$(ICEPI_BUILD)/video-test-yosys.log 2>&1 || { \
	    tail -80 $(ICEPI_BUILD)/video-test-yosys.log; exit 1; \
	  }
	@echo 'Icepi video-test synthesis PASS'

$(ICEPI_VIDEO_TEST_CONFIG): $(ICEPI_VIDEO_TEST_JSON) \
		$(ICEPI_DIR)/icepi-zero.lpf $(ICEPI_DIR)/sdram-preplace.py
	@$(NEXTPNR_ECP5) --25k --package CABGA256 --speed $(ICEPI_SPEED) \
	  $(ICEPI_NEXTPNR_OPTIONS) --pre-place $(ICEPI_DIR)/sdram-preplace.py --lpf $(ICEPI_DIR)/icepi-zero.lpf \
	  --json $< --textcfg $@.tmp >$(ICEPI_BUILD)/video-test-nextpnr.log 2>&1 || \
	  { tail -80 $(ICEPI_BUILD)/video-test-nextpnr.log; exit 1; }
	@mv $@.tmp $@
	@awk $(ICEPI_TIMING_REPORT) $(ICEPI_BUILD)/video-test-nextpnr.log

$(ICEPI_VIDEO_TEST_BIT): $(ICEPI_VIDEO_TEST_CONFIG)
	@$(ECPPACK) --compress $< $@
	@printf 'Icepi video-test bitstream: %s\n' '$@'

icepi-zero-video-test-bit: $(ICEPI_VIDEO_TEST_BIT)

# Terasic Atum A3 Nano

.PHONY: atum-a3-demo-bin atum-a3-demo-iss atum-a3-demo-rtlsim atum-a3-demo

ATUM_DIR := boards/atum_a3_nano
ATUM_BUILD := build/atum_a3_nano
ATUM_BIN := $(ATUM_BUILD)/demo.bin
ATUM_PROGRAM ?= $(DEMO_PROGRAM)
ATUM_OBJ := $(ATUM_BUILD)/demo.o
ATUM_PROGRAM_SELECTION := $(ATUM_BUILD)/demo.program
ATUM_ELF := $(ATUM_BUILD)/demo.elf
ATUM_MEMH := $(ATUM_BUILD)/mem/demo.memh
ATUM_MIF := $(ATUM_MEMH).mif
ATUM_RTLSIM := $(ATUM_BUILD)/rtlsim/Vatum_a3_nano_soc_sim
ATUM_QUARTUS_BUILD := $(ATUM_BUILD)/quartus
ATUM_QUARTUS_QPF := $(ATUM_QUARTUS_BUILD)/atum_a3_nano.qpf
ATUM_QUARTUS_QSF := $(ATUM_QUARTUS_BUILD)/atum_a3_nano.qsf
ATUM_RESET_IP := $(ATUM_QUARTUS_BUILD)/ip/atum_config_reset.ip
ATUM_IPGENERATE = $(patsubst %quartus_sh,%quartus_ipgenerate,$(QUARTUS_SH))
ATUM_QUARTUS_MEM := $(ATUM_QUARTUS_BUILD)/mem
ATUM_FULL_BUILD_STAMP := $(ATUM_QUARTUS_BUILD)/.full-build
ATUM_SOF := $(ATUM_QUARTUS_BUILD)/output_files/atum_a3_nano.sof
ATUM_SOC_RTL := \
  $(DEMO_PERIPH_RTL) \
  $(ATUM_DIR)/rtl/atum_a3_nano_soc.v
ATUM_SIM_RTL := \
  $(DEMO_MEMORY_SIM_RTL) \
  $(ATUM_DIR)/rtl/atum_fb_hdmi.v \
  $(ATUM_DIR)/rtl/atum_a3_nano_soc_sim.v \
  $(ATUM_SOC_RTL) \
  rtl/riscc_cached.v \
  rtl/riscc_fast.v
ATUM_HW_RTL := \
  $(ATUM_DIR)/rtl/top.v \
  $(DEMO_SDRAM_RTL) \
  $(ATUM_DIR)/rtl/atum_sdram.v \
  $(ATUM_DIR)/rtl/atum_sdram_pll.v \
  $(ATUM_DIR)/rtl/atum_hdmi_pll.v \
  $(ATUM_DIR)/rtl/atum_reset_release.v \
  $(ATUM_SOC_RTL) \
  $(ATUM_DIR)/rtl/atum_fb_hdmi.v \
  $(ATUM_DIR)/rtl/atum_tfp410_init.v \
  rtl/riscc_cached.v \
  rtl/riscc_fast.v
ATUM_PROJECT_FILES := \
  $(ATUM_DIR)/atum_a3_nano.qpf \
  $(ATUM_DIR)/atum_a3_nano.qsf \
  $(ATUM_DIR)/atum_a3_nano.sdc \
  $(ATUM_HW_RTL)
ATUM_FULL_BUILD_DEPS := \
  $(ATUM_PROJECT_FILES) \
  $(ATUM_QUARTUS_QPF) \
  $(ATUM_QUARTUS_QSF) \
  $(ATUM_RESET_IP) \
  $(RISCC_RF_RTL) \
  $(BOARD_RULES)

$(ATUM_MEMH): $(ATUM_BIN) tools/bin_to_memh.py $(BOARD_RULES)
	@mkdir -p $(@D)
	$(PYTHON) tools/bin_to_memh.py $< -o $@ --width 32 --depth 4096

$(ATUM_MIF): $(ATUM_BIN) tools/bin_to_memh.py $(BOARD_RULES)
	@mkdir -p $(@D)
	$(PYTHON) tools/bin_to_memh.py $< -o $@ --width 32 --depth 4096 --format mif

atum-a3-demo-bin: $(ATUM_BIN) $(ATUM_MEMH) $(ATUM_MIF)

atum-a3-demo-iss: $(ATUM_BIN) $(RISCC_SIM)
	$(RISCC_SIM) $< --rc32-full --board-rc32 --uart --fb-window --fb-scale 4 --mhz 200 --max-insns 0

$(ATUM_RTLSIM): $(ATUM_MEMH) $(ATUM_SIM_RTL) $(ATUM_DIR)/sim/atum_a3_nano_soc_tb.cpp $(BOARD_RULES)
	@mkdir -p $(@D)
	+$(VERILATOR) -cc --exe --build $(VERILATOR_MAKEFLAGS_ARG) \
	  --top-module atum_a3_nano_soc_sim --prefix Vatum_a3_nano_soc_sim \
	  -Mdir $(@D) -GTIMER_TICK_DIV=4 -I$(abspath rtl) \
	  -CFLAGS "$(TB_CXXFLAGS)" -o Vatum_a3_nano_soc_sim \
	  $(abspath $(ATUM_SIM_RTL)) $(abspath $(ATUM_DIR)/sim/atum_a3_nano_soc_tb.cpp)

atum-a3-demo-rtlsim: $(ATUM_RTLSIM)
	$(ATUM_RTLSIM)

$(ATUM_QUARTUS_QPF): $(ATUM_DIR)/atum_a3_nano.qpf
	@mkdir -p $(@D)
	cp $< $@

$(ATUM_QUARTUS_QSF): $(ATUM_DIR)/atum_a3_nano.qsf
	@mkdir -p $(@D)
	cp $< $@

$(ATUM_QUARTUS_MEM): | $(ATUM_QUARTUS_QSF)
	ln -sfn ../mem $@

$(ATUM_RESET_IP): $(BOARD_RULES)
	@mkdir -p $(@D)
	@quartus_bin=$$(dirname "$$(command -v "$(QUARTUS_SH)")"); \
	  "$$quartus_bin/../sopc_builder/bin/ip-deploy" \
	    --component-name=altera_s10_user_rst_clkgate \
	    --output-name=atum_config_reset --output-directory="$(abspath $(@D))" \
	    --part=A3CZ135BB18AE7S

$(ATUM_FULL_BUILD_STAMP): $(ATUM_FULL_BUILD_DEPS) | \
		$(ATUM_MIF) $(ATUM_QUARTUS_MEM)
	cd $(ATUM_QUARTUS_BUILD) && \
	  RISCC_BUILD_JOBS=$(RISCC_BUILD_JOBS) \
	  $(ATUM_IPGENERATE) --generate_ip_file --synthesis=verilog \
	    --ip_file=ip/atum_config_reset.ip atum_a3_nano
	cd $(ATUM_QUARTUS_BUILD) && \
	  RISCC_BUILD_JOBS=$(RISCC_BUILD_JOBS) \
	  $(QUARTUS_SH) $(QUARTUS_FLOW_ARGS) --flow compile \
	  atum_a3_nano
	@test -f $(ATUM_SOF)
	@touch $@

$(ATUM_SOF): $(ATUM_FULL_BUILD_STAMP) $(ATUM_MIF)
	cd $(ATUM_QUARTUS_BUILD) && \
	  RISCC_BUILD_JOBS=$(RISCC_BUILD_JOBS) \
	  $(QUARTUS_CDB) --update_mif atum_a3_nano
	cd $(ATUM_QUARTUS_BUILD) && \
	  RISCC_BUILD_JOBS=$(RISCC_BUILD_JOBS) \
	  $(QUARTUS_ASM) atum_a3_nano
	@printf 'Atum A3 Nano SOF: %s\n' '$@'

atum-a3-demo: $(ATUM_SOF)

# Board firmware uses the same freestanding C++ subset as applications.
DEMO_CXXFLAGS := $(filter-out -O%,$(RISCC_CXXFLAGS)) -O2 -Ifirmware/include

# Rebuild when switching back to a source older than the last selected program.
.PHONY: demo-program-selection-check
demo-program-selection-check:

$(ICEPI_PROGRAM_SELECTION): demo-program-selection-check
	@mkdir -p $(@D)
	@printf '%s\n' '$(abspath $(ICEPI_PROGRAM))' > $@.tmp
	@cmp -s $@.tmp $@ && rm $@.tmp || mv $@.tmp $@

$(ATUM_PROGRAM_SELECTION): demo-program-selection-check
	@mkdir -p $(@D)
	@printf '%s\n' '$(abspath $(ATUM_PROGRAM))' > $@.tmp
	@cmp -s $@.tmp $@ && rm $@.tmp || mv $@.tmp $@

-include $(ICEPI_OBJ:.o=.d) $(ATUM_OBJ:.o=.d)

$(ICEPI_OBJ): $(ICEPI_PROGRAM) $(ICEPI_PROGRAM_SELECTION) $(LIBC_HEADERS) $(BOARD_RULES) $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(DEMO_TARGET_FLAGS) $(DEMO_CXXFLAGS) \
	  $(ICEPI_DEFINES) -MMD -MP -c $< -o $@

$(ICEPI_ELF): $(DEMO_VECTORS) $(DEMO_CRT0) \
		$(ICEPI_OBJ) $(DEMO_LIBS) $(DEMO_LINKER_SCRIPT) \
		$(RISCC_CLANG) $(RISCC_LLD)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(DEMO_TARGET_FLAGS) $(RISCC_LDFLAGS) -fuse-ld=lld -nostdlib \
	  -Wl,-T,$(abspath $(DEMO_LINKER_SCRIPT)) $(DEMO_LD_FLAGS) -Wl,-Map,$(@:.elf=.map) \
	  $(DEMO_VECTORS) $(DEMO_CRT0) $(ICEPI_OBJ) \
	  $(DEMO_LIBS) -o $@

$(ICEPI_BIN): $(ICEPI_ELF) $(RISCC_OBJCOPY)
	$(RISCC_OBJCOPY) -O binary $< $@

$(ATUM_OBJ): $(ATUM_PROGRAM) $(ATUM_PROGRAM_SELECTION) $(LIBC_HEADERS) $(BOARD_RULES) $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(DEMO_TARGET_FLAGS) $(DEMO_CXXFLAGS) \
	  -DRISCC_ATUM_A3 -MMD -MP -c $< -o $@

$(ATUM_ELF): $(DEMO_VECTORS) $(DEMO_CRT0) \
		$(ATUM_OBJ) $(DEMO_LIBS) $(DEMO_LINKER_SCRIPT) \
		$(RISCC_CLANG) $(RISCC_LLD)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(DEMO_TARGET_FLAGS) $(RISCC_LDFLAGS) -fuse-ld=lld -nostdlib \
	  -Wl,-T,$(abspath $(DEMO_LINKER_SCRIPT)) $(DEMO_LD_FLAGS) -Wl,-Map,$(@:.elf=.map) \
	  $(DEMO_VECTORS) $(DEMO_CRT0) $(ATUM_OBJ) \
	  $(DEMO_LIBS) -o $@

$(ATUM_BIN): $(ATUM_ELF) $(RISCC_OBJCOPY)
	$(RISCC_OBJCOPY) -O binary $< $@

.PHONY: test-sdram-write-stream
test-sdram-write-stream:
	@mkdir -p build/test-sdram-write-stream
	@for clocks in '5 3' '3 5' '3 3'; do \
	  set -- $$clocks; \
	  output=build/test-sdram-write-stream/$$1-$$2.vvp; \
	  iverilog -g2012 -s sdram_write_stream_tb \
	    -Psdram_write_stream_tb.CPU_HALF=$$1 \
	    -Psdram_write_stream_tb.MEMORY_HALF=$$2 -o $$output \
	    boards/shared/rtl/riscc_sdram_bridge.v boards/shared/rtl/riscc_sdram_fabric.v \
	    test/sdram_write_stream_tb.v && vvp $$output || exit $$?; \
	done

BOARD_RULES := Makefile mk/boards.mk mk/firmware.mk

DEMO_PROGRAM ?= boards/shared/sw/demo.cpp
DEMO_RAM_LENGTH ?= 0x6000
DEMO_LD_FLAGS := -Wl,--defsym=__riscc_ram_length=$(DEMO_RAM_LENGTH)

# Icepi Zero

.PHONY: icepi-zero-demo-bin icepi-zero-demo-iss icepi-zero-demo-iss-test \
	icepi-zero-demo-rtlsim icepi-zero-demo-json icepi-zero-demo-bit \
	icepi-zero-video-test-bit

ICEPI_DIR := boards/icepi_zero
ICEPI_BUILD := build/icepi_zero
ICEPI_BIN := $(ICEPI_BUILD)/demo.bin
ICEPI_PROGRAM ?= $(DEMO_PROGRAM)
ICEPI_OBJ := $(ICEPI_BUILD)/demo.o
ICEPI_ELF := $(ICEPI_BUILD)/demo.elf
ICEPI_MEMH := $(ICEPI_BUILD)/demo.memh
ICEPI_JSON := $(ICEPI_BUILD)/demo.json
ICEPI_CONFIG := $(ICEPI_BUILD)/demo.config
ICEPI_BIT := $(ICEPI_BUILD)/demo.bit
ICEPI_VIDEO_TEST_JSON := $(ICEPI_BUILD)/video_test.json
ICEPI_VIDEO_TEST_CONFIG := $(ICEPI_BUILD)/video_test.config
ICEPI_VIDEO_TEST_BIT := $(ICEPI_BUILD)/video_test.bit
ICEPI_RTLSIM := $(ICEPI_BUILD)/rtlsim/Vicepi_zero_soc_sim
ICEPI_CPU_DEFINES := -DRISCC_FAST_DSP
ICEPI_DEFINES := -DRISCC_ICEPI_ZERO
ICEPI_LD_FLAGS := -Wl,--defsym=__riscc_ram_length=0x8000
ICEPI_SYNTH_OPTIONS ?= -abc2
ICEPI_SPEED ?= 6
ICEPI_NEXTPNR_OPTIONS ?= --seed $(PNR_SEED) --placer sa --tmg-ripup
ICEPI_SYNTH_REPORT = '/Number of cells:/ { cells = $$4 } \
	$$1 == "LUT4" { lut = $$2 } \
	$$1 == "DP16KD" { ebr = $$2 } \
	$$1 == "MULT18X18D" { dsp = $$2 } \
	END { printf "Icepi synth: %d cells, %d LUT4, %d EBR, %d DSP\n", \
	             cells, lut, ebr, dsp }'
ICEPI_TIMING_REPORT = '/Max frequency for clock/ { \
	first = second; second = latest; latest = $$0 \
	} END { if (first) print first; if (second) print second; print latest }'
ICEPI_DVI_RTL := \
  $(ICEPI_DIR)/rtl/icepi_fb_dvi.v \
  $(ICEPI_DIR)/rtl/icepi_tmds_ddr.v \
  $(ICEPI_DIR)/rtl/icepi_tmds_encoder.v \
  $(ICEPI_DIR)/rtl/icepi_dvi_pll.v
DEMO_PERIPH_RTL := \
  boards/shared/rtl/riscc_framebuffer_mmio.v \
  boards/shared/rtl/riscc_uart_mmio.v \
  boards/shared/rtl/riscc_timer_mmio.v \
  boards/shared/rtl/riscc_irq_ctrl.v
ICEPI_SOC_RTL := \
  $(DEMO_PERIPH_RTL) \
  $(ICEPI_DIR)/rtl/fb_ram.v \
  $(ICEPI_DIR)/rtl/icepi_zero_soc.v
ICEPI_SYNTH_RTL := \
  $(ICEPI_DIR)/rtl/top.v \
  $(ICEPI_SOC_RTL) \
  $(ICEPI_DVI_RTL) \
  rtl/riscc16_fast.v
ICEPI_SIM_RTL := \
  $(ICEPI_DIR)/rtl/icepi_zero_soc_sim.v \
  $(ICEPI_SOC_RTL) \
  $(ICEPI_DIR)/rtl/icepi_fb_dvi.v \
  $(ICEPI_DIR)/rtl/icepi_tmds_ddr.v \
  $(ICEPI_DIR)/rtl/icepi_tmds_encoder.v \
  rtl/riscc16_fast.v

$(ICEPI_MEMH): $(ICEPI_BIN) tools/bin_to_memh.py
	$(PYTHON) tools/bin_to_memh.py $< -o $@

icepi-zero-demo-bin: $(ICEPI_BIN) $(ICEPI_MEMH)

icepi-zero-demo-iss: $(ICEPI_BIN) $(RISCC_SIM)
	$(RISCC_SIM) $< --uart --fast-dsp --fb-icepi --fb-window --mhz 50 --max-insns 0

icepi-zero-demo-iss-test: $(ICEPI_BIN) $(RISCC_SIM)
	@mkdir -p build/icepi_zero
	@printf '12+' | $(RISCC_SIM) $< --uart --full --max-insns 3000000 \
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
	@$(YOSYS) -p "read_verilog -DRISCC_ECP5 $(ICEPI_CPU_DEFINES) $(ICEPI_SYNTH_RTL); \
	  synth_ecp5 $(ICEPI_SYNTH_OPTIONS) -top top -json $@" \
	  >$(ICEPI_BUILD)/demo-yosys.log 2>&1 || { \
	    tail -80 $(ICEPI_BUILD)/demo-yosys.log; exit 1; \
	  }
	@awk $(ICEPI_SYNTH_REPORT) $(ICEPI_BUILD)/demo-yosys.log

$(ICEPI_CONFIG): $(ICEPI_JSON) $(ICEPI_DIR)/icepi-zero.lpf
	@$(NEXTPNR_ECP5) --25k --package CABGA256 --speed $(ICEPI_SPEED) \
	  $(ICEPI_NEXTPNR_OPTIONS) --lpf $(ICEPI_DIR)/icepi-zero.lpf \
	  --json $< --textcfg $@ >$(ICEPI_BUILD)/demo-nextpnr.log 2>&1 || \
	  { tail -80 $(ICEPI_BUILD)/demo-nextpnr.log; exit 1; }
	@awk $(ICEPI_TIMING_REPORT) $(ICEPI_BUILD)/demo-nextpnr.log

$(ICEPI_BIT): $(ICEPI_CONFIG)
	@$(ECPPACK) --compress $< $@
	@printf 'Icepi bitstream: %s\n' '$@'

icepi-zero-demo-json: $(ICEPI_JSON)
icepi-zero-demo-bit: $(ICEPI_BIT)

$(ICEPI_VIDEO_TEST_JSON): $(ICEPI_MEMH) $(ICEPI_SYNTH_RTL) \
		$(RISCC_RF_RTL) $(BOARD_RULES)
	@mkdir -p $(@D)
	@$(YOSYS) -p "read_verilog -DRISCC_ECP5 $(ICEPI_CPU_DEFINES) \
	  -DICEPI_VIDEO_TEST $(ICEPI_SYNTH_RTL); \
	  synth_ecp5 $(ICEPI_SYNTH_OPTIONS) -top top -json $@" \
	  >$(ICEPI_BUILD)/video-test-yosys.log 2>&1 || { \
	    tail -80 $(ICEPI_BUILD)/video-test-yosys.log; exit 1; \
	  }
	@echo 'Icepi video-test synthesis PASS'

$(ICEPI_VIDEO_TEST_CONFIG): $(ICEPI_VIDEO_TEST_JSON) \
		$(ICEPI_DIR)/icepi-zero.lpf
	@$(NEXTPNR_ECP5) --25k --package CABGA256 --speed $(ICEPI_SPEED) \
	  $(ICEPI_NEXTPNR_OPTIONS) --lpf $(ICEPI_DIR)/icepi-zero.lpf \
	  --json $< --textcfg $@ >$(ICEPI_BUILD)/video-test-nextpnr.log 2>&1 || \
	  { tail -80 $(ICEPI_BUILD)/video-test-nextpnr.log; exit 1; }
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
ATUM_ELF := $(ATUM_BUILD)/demo.elf
ATUM_MEMH := $(ATUM_BUILD)/mem/demo.memh
ATUM_MIF := $(ATUM_BUILD)/mem/demo.mif
ATUM_RTLSIM := $(ATUM_BUILD)/rtlsim/Vatum_a3_nano_soc_sim
ATUM_QUARTUS_BUILD := $(ATUM_BUILD)/quartus
ATUM_QUARTUS_QPF := $(ATUM_QUARTUS_BUILD)/atum_a3_nano.qpf
ATUM_QUARTUS_QSF := $(ATUM_QUARTUS_BUILD)/atum_a3_nano.qsf
ATUM_QUARTUS_MEM := $(ATUM_QUARTUS_BUILD)/mem
ATUM_FULL_BUILD_STAMP := $(ATUM_QUARTUS_BUILD)/.full-build
ATUM_SOF := $(ATUM_QUARTUS_BUILD)/output_files/atum_a3_nano.sof
ATUM_SOC_RTL := \
  $(DEMO_PERIPH_RTL) \
  $(ATUM_DIR)/rtl/atum_a3_nano_soc.v
ATUM_SIM_RTL := \
  $(ATUM_DIR)/rtl/atum_a3_nano_soc_sim.v \
  $(ATUM_SOC_RTL) \
  rtl/riscc16_faster.v
ATUM_HW_RTL := \
  $(ATUM_DIR)/rtl/top.v \
  $(ATUM_DIR)/rtl/atum_sys_pll.v \
  $(ATUM_DIR)/rtl/atum_reset_release.v \
  $(ATUM_SOC_RTL) \
  $(ATUM_DIR)/rtl/atum_fb_hdmi.v \
  $(ATUM_DIR)/rtl/atum_tfp410_init.v \
  rtl/riscc16_faster.v
ATUM_PROJECT_FILES := \
  $(ATUM_DIR)/atum_a3_nano.qpf \
  $(ATUM_DIR)/atum_a3_nano.qsf \
  $(ATUM_DIR)/atum_a3_nano.sdc \
  $(ATUM_HW_RTL)
ATUM_FULL_BUILD_DEPS := \
  $(ATUM_PROJECT_FILES) \
  $(ATUM_QUARTUS_QPF) \
  $(ATUM_QUARTUS_QSF) \
  $(RISCC_RF_RTL) \
  $(BOARD_RULES)

$(ATUM_MEMH): $(ATUM_BIN) tools/bin_to_memh.py $(BOARD_RULES)
	@mkdir -p $(@D)
	$(PYTHON) tools/bin_to_memh.py $< -o $@ --depth 12288

$(ATUM_MIF): $(ATUM_BIN) tools/bin_to_memh.py $(BOARD_RULES)
	@mkdir -p $(@D)
	$(PYTHON) tools/bin_to_memh.py $< -o $@ --depth 12288 --format mif

atum-a3-demo-bin: $(ATUM_BIN) $(ATUM_MEMH) $(ATUM_MIF)

atum-a3-demo-iss: $(ATUM_BIN) $(RISCC_SIM)
	$(RISCC_SIM) $< --uart --faster --fb-window --fb-scale 4 --mhz 225 --max-insns 0

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

$(ATUM_FULL_BUILD_STAMP): $(ATUM_FULL_BUILD_DEPS) | \
		$(ATUM_MIF) $(ATUM_QUARTUS_MEM)
	cd $(ATUM_QUARTUS_BUILD) && \
	  RISCC_BUILD_JOBS=$(RISCC_BUILD_JOBS) \
	  $(QUARTUS_SH) $(QUARTUS_FLOW_ARGS) --flow compile \
	  atum_a3_nano
	@test -f $(ATUM_SOF)
	@touch $@

$(ATUM_SOF): $(ATUM_FULL_BUILD_STAMP) $(ATUM_MIF)
	@quartus_mif=$$(find $(ATUM_QUARTUS_BUILD)/qdb \
	  -path '*/mifs/ram0_top_*.hdl.mif' -type f -print -quit); \
	  test -n "$$quartus_mif"; \
	  cp $(ATUM_MIF) "$$quartus_mif"
	cd $(ATUM_QUARTUS_BUILD) && \
	  RISCC_BUILD_JOBS=$(RISCC_BUILD_JOBS) \
	  $(QUARTUS_CDB) --update_mif atum_a3_nano
	cd $(ATUM_QUARTUS_BUILD) && \
	  RISCC_BUILD_JOBS=$(RISCC_BUILD_JOBS) \
	  $(QUARTUS_ASM) atum_a3_nano
	@printf 'Atum A3 Nano SOF: %s\n' '$@'

atum-a3-demo: $(ATUM_SOF)

# The board demos intentionally use only C++ language features.  There is no
# C++ standard library, exception support, RTTI, global constructors, or
# thread-safe local-static machinery in the freestanding target runtime.
DEMO_CXXFLAGS := $(filter-out -O%,$(RISCC_CFLAGS)) -O2 -std=c++11 \
	-fno-exceptions -fno-rtti -fno-threadsafe-statics -nostdinc++ \
	-Ifirmware/include

$(ICEPI_OBJ): $(ICEPI_PROGRAM) $(LIBC_HEADERS) $(BOARD_RULES) $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(DEMO_CXXFLAGS) \
	  $(ICEPI_DEFINES) -c $< -o $@

$(ICEPI_ELF): $(FW_VECTORS) $(FW_CRT0) \
		$(ICEPI_OBJ) $(FW_LIBS) firmware/unified.ld \
		$(RISCC_CLANG) $(RISCC_LLD)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_LDFLAGS) -fuse-ld=lld -nostdlib \
	  -Wl,-T,$(abspath firmware/unified.ld) $(ICEPI_LD_FLAGS) -Wl,-Map,$(@:.elf=.map) \
	  $(FW_VECTORS) $(FW_CRT0) $(ICEPI_OBJ) \
	  $(FW_LIBS) -o $@

$(ICEPI_BIN): $(ICEPI_ELF) $(RISCC_OBJCOPY)
	$(RISCC_OBJCOPY) -O binary $< $@

$(ATUM_OBJ): $(ATUM_PROGRAM) $(LIBC_HEADERS) $(BOARD_RULES) $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(DEMO_CXXFLAGS) \
	  -DRISCC_ATUM_A3 -c $< -o $@

$(ATUM_ELF): $(FW_VECTORS) $(FW_CRT0) \
		$(ATUM_OBJ) $(FW_LIBS) firmware/unified.ld \
		$(RISCC_CLANG) $(RISCC_LLD)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_LDFLAGS) -fuse-ld=lld -nostdlib \
	  -Wl,-T,$(abspath firmware/unified.ld) $(DEMO_LD_FLAGS) -Wl,-Map,$(@:.elf=.map) \
	  $(FW_VECTORS) $(FW_CRT0) $(ATUM_OBJ) \
	  $(FW_LIBS) -o $@

$(ATUM_BIN): $(ATUM_ELF) $(RISCC_OBJCOPY)
	$(RISCC_OBJCOPY) -O binary $< $@

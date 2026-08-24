FIRMWARE_RULES := Makefile mk/firmware.mk

RISCC_XLEN ?= 16
ifeq ($(filter $(RISCC_XLEN),16 32),)
$(error RISCC_XLEN must be 16 or 32)
endif
ifeq ($(RISCC_XLEN),32)
ifeq ($(PROFILE),nano)
$(error RC32 has no Nano profile)
endif
RISCC_FIRMWARE_BUILD ?= build/firmware/rc32/$(PROFILE)
RISCC_ARCH := rc32
RISCC_XLEN_FLAGS := -mrc32
RISCC_SIM_XLEN_FLAGS := $(if $(filter full,$(PROFILE)),--rc32-full,\
	$(if $(filter sys,$(PROFILE)),--rc32-sys,--rc32))
else
RISCC_ARCH := rc16
RISCC_XLEN_FLAGS :=
RISCC_SIM_XLEN_FLAGS :=
ifeq ($(PROFILE),nano)
RISCC_FIRMWARE_BUILD ?= build/firmware/nano
RISCC_STARTUP_ARCH := nano
RISCC_LINKER_SCRIPT := firmware/nano/unified.ld
else
RISCC_FIRMWARE_BUILD ?= build/firmware/rc16/$(PROFILE)
RISCC_STARTUP_ARCH := rc16
RISCC_LINKER_SCRIPT := firmware/rc16/unified.ld
endif
endif
RISCC_STARTUP_ARCH ?= $(RISCC_ARCH)
ifeq ($(RISCC_XLEN),32)
RISCC_LINKER_SCRIPT := firmware/rc32/unified.ld
endif
RISCC_TARGET_FEATURES ?=
RISCC_TARGET_FLAGS ?= --target=riscc-none-elf -mcpu=$(PROFILE) \
	$(RISCC_XLEN_FLAGS) $(addprefix -m,$(RISCC_TARGET_FEATURES))
SIM_PROFILE_FLAGS := $(SIM_FLAGS_$(PROFILE)) \
	$(RISCC_SIM_XLEN_FLAGS) \
	$(patsubst mdu,--mdu,$(filter mdu,$(RISCC_TARGET_FEATURES)))
RISCC_ASFLAGS ?= -ffreestanding
RISCC_CFLAGS ?= -Os -ffreestanding -fno-builtin -fno-pic -fno-pie \
	-fno-unwind-tables -fno-asynchronous-unwind-tables \
	-ffunction-sections -fdata-sections
RISCC_CXXFLAGS ?= $(RISCC_CFLAGS) -std=c++17 -fno-exceptions -fno-rtti \
	-fno-threadsafe-statics -fno-use-cxa-atexit -nostdinc++
# Runtime archives are size-biased; applications keep their chosen level.
LIB_CFLAGS := $(filter-out -O%,$(RISCC_CFLAGS)) -Oz
# Discard unused sections from extracted archive members.
RISCC_LDFLAGS ?= -Wl,--gc-sections

FW_VECTORS := $(RISCC_FIRMWARE_BUILD)/vectors.o
FW_CRT0 := $(RISCC_FIRMWARE_BUILD)/crt0.o
IRQ_MODULES := irq irq_control
IRQ_SOURCE_DIR := firmware/$(RISCC_ARCH)
IRQ_OBJS := $(addprefix $(RISCC_FIRMWARE_BUILD)/irq/, \
	$(addsuffix .o,$(IRQ_MODULES)))
IRQ_LIB := $(RISCC_FIRMWARE_BUILD)/libirq.a
ifeq ($(RISCC_XLEN),32)
INTEGER_C_MODULES :=
INTEGER_ASM_MODULES := integer shift constant_shift wide_shift wide_mul wide_div misc
else
INTEGER_C_MODULES := wide
INTEGER_ASM_MODULES := div mul wide_shift constant_shift
endif
INTEGER_SOURCE_DIR := firmware/$(RISCC_ARCH)
INTEGER_C_OBJS := $(addprefix $(RISCC_FIRMWARE_BUILD)/builtins/, \
	$(addsuffix .o,$(INTEGER_C_MODULES)))
INTEGER_ASM_OBJS := $(addprefix $(RISCC_FIRMWARE_BUILD)/builtins/, \
	$(addsuffix .o,$(INTEGER_ASM_MODULES)))
INTEGER_OBJS := $(INTEGER_C_OBJS) $(INTEGER_ASM_OBJS)
COMPILER_RT_BUILTINS := external/llvm-project/compiler-rt/lib/builtins
SOFT_FLOAT_MODULES := fp_mode \
	addsf3 subsf3 mulsf3 divsf3 comparesf2 \
	adddf3 subdf3 muldf3 divdf3 comparedf2 \
	extendsfdf2 truncdfsf2 \
	fixsfsi fixsfdi fixunssfsi fixunssfdi \
	fixdfsi fixdfdi fixunsdfsi fixunsdfdi \
	floatsisf floatdisf floatunsisf floatundisf \
	floatsidf floatdidf floatunsidf floatundidf
SOFT_FLOAT_ASM_MODULES := addsf3 mulsf3 divsf3
SOFT_FLOAT_OBJS := $(addprefix \
	$(RISCC_FIRMWARE_BUILD)/builtins/softfloat/, \
	$(addsuffix .o,$(SOFT_FLOAT_MODULES)))
SOFT_FLOAT_MUL24_OBJ := \
	$(RISCC_FIRMWARE_BUILD)/builtins/softfloat/mul24.o
SOFT_FLOAT_PACK_OBJ := \
	$(RISCC_FIRMWARE_BUILD)/builtins/softfloat/pack_sf.o
SOFT_FLOAT_EXTRA_OBJS_nano :=
SOFT_FLOAT_EXTRA_OBJS_min := $(SOFT_FLOAT_PACK_OBJ)
SOFT_FLOAT_EXTRA_OBJS_sys := $(SOFT_FLOAT_PACK_OBJ)
SOFT_FLOAT_EXTRA_OBJS_full := $(SOFT_FLOAT_PACK_OBJ) $(SOFT_FLOAT_MUL24_OBJ)
ifeq ($(RISCC_XLEN),32)
SOFT_FLOAT_ASM_MODULES := addsf3 mulsf3 divsf3
SOFT_FLOAT_EXTRA_OBJS_min := $(SOFT_FLOAT_PACK_OBJ)
SOFT_FLOAT_EXTRA_OBJS_sys := $(SOFT_FLOAT_PACK_OBJ)
SOFT_FLOAT_EXTRA_OBJS_full := $(SOFT_FLOAT_PACK_OBJ)
endif
SOFT_FLOAT_OBJS += $(SOFT_FLOAT_EXTRA_OBJS_$(PROFILE))
BUILTINS_LIB := $(RISCC_FIRMWARE_BUILD)/libbuiltins.a
BSP_DIR ?= firmware/bsp/demo
BSP_MODULES_nano := console clock
BSP_MODULES_min := console clock time
BSP_MODULES_sys := console clock time
BSP_MODULES_full := console clock time
BSP_MODULES ?= $(BSP_MODULES_$(PROFILE))
BSP_OBJS := $(addprefix $(RISCC_FIRMWARE_BUILD)/bsp/,$(addsuffix .o,$(BSP_MODULES)))
BSP_LIB := $(RISCC_FIRMWARE_BUILD)/libbsp.a
LIBC_MODULES := memory string ctype errno convert search rand heap \
	alloc stdio printf terminate
LIBC_OBJS := $(addprefix $(RISCC_FIRMWARE_BUILD)/libc/, \
	$(addsuffix .o,$(LIBC_MODULES))) \
	$(RISCC_FIRMWARE_BUILD)/libc/heap_limit.o
LIBC_HEADERS := $(wildcard firmware/include/*.h firmware/include/riscc/*.h)
LIBC_LIB := $(RISCC_FIRMWARE_BUILD)/libc.a
LIBM_COMMON_C_MODULES := bits compare decompose fmod next sqrt
ifeq ($(RISCC_XLEN),32)
LIBM_ARCH_C_MODULES := libm_wide
LIBM_ARCH_ASM_MODULES :=
else
LIBM_ARCH_C_MODULES :=
LIBM_ARCH_ASM_MODULES := libm_wide libm_arithmetic libm_shift
endif
LIBM_COMMON_C_OBJS := $(addprefix $(RISCC_FIRMWARE_BUILD)/libm/, \
	$(addsuffix .o,$(LIBM_COMMON_C_MODULES)))
LIBM_ARCH_C_OBJS := $(addprefix $(RISCC_FIRMWARE_BUILD)/libm/arch/, \
	$(addsuffix .o,$(LIBM_ARCH_C_MODULES)))
LIBM_ARCH_ASM_OBJS := $(addprefix $(RISCC_FIRMWARE_BUILD)/libm/arch/, \
	$(addsuffix .o,$(LIBM_ARCH_ASM_MODULES)))
LIBM_OBJS := $(LIBM_COMMON_C_OBJS) $(LIBM_ARCH_C_OBJS) \
	$(LIBM_ARCH_ASM_OBJS)
LIBM_LIB := $(RISCC_FIRMWARE_BUILD)/libm.a
IRQ_LIBRARY_nano :=
IRQ_LIBRARY_min :=
IRQ_LIBRARY_sys := $(IRQ_LIB)
IRQ_LIBRARY_full := $(IRQ_LIB)
FW_LIBS := $(LIBC_LIB) \
	$(LIBM_LIB) \
	$(BSP_LIB) \
	$(IRQ_LIBRARY_$(PROFILE)) \
	$(BUILTINS_LIB)

FIRMWARE_RC16_RUNS := $(addprefix firmware-rc16-,$(PROFILES))
FIRMWARE_RC32_RUNS := $(addprefix firmware-rc32-,$(RC32_PROFILES))
.PHONY: firmware firmware-all firmware-rc32 \
	$(FIRMWARE_RC16_RUNS) $(FIRMWARE_RC32_RUNS)

$(FW_VECTORS): firmware/vectors.S $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_ASFLAGS) -c $< -o $@

$(FW_CRT0): firmware/$(RISCC_STARTUP_ARCH)/crt0.S $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_ASFLAGS) -c $< -o $@

$(IRQ_OBJS): $(RISCC_FIRMWARE_BUILD)/irq/%.o: \
		$(IRQ_SOURCE_DIR)/%.S $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_ASFLAGS) -c $< -o $@

$(INTEGER_C_OBJS): \
		$(RISCC_FIRMWARE_BUILD)/builtins/%.o: \
		$(INTEGER_SOURCE_DIR)/%.c $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_CFLAGS) -c $< -o $@

$(INTEGER_ASM_OBJS): \
		$(RISCC_FIRMWARE_BUILD)/builtins/%.o: \
		$(INTEGER_SOURCE_DIR)/%.S $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_ASFLAGS) -c $< -o $@

SOFT_FLOAT_SOURCE_DIR := firmware/$(if $(filter nano,$(PROFILE)),nano,$(RISCC_ARCH))

$(addprefix $(RISCC_FIRMWARE_BUILD)/builtins/softfloat/, \
	$(addsuffix .o,$(SOFT_FLOAT_ASM_MODULES))): \
		$(RISCC_FIRMWARE_BUILD)/builtins/softfloat/%.o: \
		$(SOFT_FLOAT_SOURCE_DIR)/%.S \
		$(FIRMWARE_RULES) $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_ASFLAGS) -c $< -o $@

$(SOFT_FLOAT_PACK_OBJ): \
		$(SOFT_FLOAT_SOURCE_DIR)/pack_sf.S $(FIRMWARE_RULES) $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_ASFLAGS) -c $< -o $@

$(RISCC_FIRMWARE_BUILD)/builtins/softfloat/%.o: \
		$(COMPILER_RT_BUILTINS)/%.c \
		$(wildcard $(COMPILER_RT_BUILTINS)/fp_*.h) \
		$(wildcard $(COMPILER_RT_BUILTINS)/fp_*.inc) \
		$(wildcard $(COMPILER_RT_BUILTINS)/int_*.h) $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(LIB_CFLAGS) \
	  -I$(COMPILER_RT_BUILTINS) -c $< -o $@

$(SOFT_FLOAT_MUL24_OBJ): firmware/rc16/mul24.S $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_ASFLAGS) -c $< -o $@

$(RISCC_FIRMWARE_BUILD)/libc/%.o: firmware/libc/%.c \
		$(LIBC_HEADERS) $(FIRMWARE_RULES) $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(LIB_CFLAGS) -Ifirmware/include -c $< -o $@

$(LIBM_COMMON_C_OBJS): $(RISCC_FIRMWARE_BUILD)/libm/%.o: firmware/libm/%.c \
		firmware/libm/internal.h $(LIBC_HEADERS) $(FIRMWARE_RULES) $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(LIB_CFLAGS) -Ifirmware/include -c $< -o $@

$(LIBM_ARCH_C_OBJS): $(RISCC_FIRMWARE_BUILD)/libm/arch/%.o: \
		firmware/$(RISCC_ARCH)/%.c firmware/libm/internal.h \
		$(LIBC_HEADERS) $(FIRMWARE_RULES) $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(LIB_CFLAGS) \
	  -Ifirmware/include -c $< -o $@

$(LIBM_ARCH_ASM_OBJS): \
		$(RISCC_FIRMWARE_BUILD)/libm/arch/%.o: \
		firmware/$(RISCC_ARCH)/%.S $(FIRMWARE_RULES) $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_ASFLAGS) -c $< -o $@

$(RISCC_FIRMWARE_BUILD)/libc/heap_limit.o: firmware/libc/heap.S \
		$(FIRMWARE_RULES) $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_ASFLAGS) -c $< -o $@

$(RISCC_FIRMWARE_BUILD)/bsp/%.o: $(BSP_DIR)/%.c \
		$(LIBC_HEADERS) $(FIRMWARE_RULES) $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(LIB_CFLAGS) -Ifirmware/include -c $< -o $@

$(BUILTINS_LIB): $(INTEGER_OBJS) \
		$(SOFT_FLOAT_OBJS) $(RISCC_AR)
	@mkdir -p $(@D)
	$(RM) $@
	$(RISCC_AR) rcs $@ $(INTEGER_OBJS) $(SOFT_FLOAT_OBJS)

$(LIBC_LIB): $(LIBC_OBJS) $(RISCC_AR)
	@mkdir -p $(@D)
	$(RM) $@
	$(RISCC_AR) rcs $@ $(LIBC_OBJS)

$(LIBM_LIB): $(LIBM_OBJS) $(RISCC_AR)
	@mkdir -p $(@D)
	$(RM) $@
	$(RISCC_AR) rcs $@ $(LIBM_OBJS)

$(BSP_LIB): $(BSP_OBJS) $(RISCC_AR)
	@mkdir -p $(@D)
	$(RM) $@
	$(RISCC_AR) rcs $@ $(BSP_OBJS)

$(IRQ_LIB): $(IRQ_OBJS) $(RISCC_AR)
	@mkdir -p $(@D)
	$(RM) $@
	$(RISCC_AR) rcs $@ $(IRQ_OBJS)

firmware: $(FW_VECTORS) $(FW_CRT0) \
	$(FW_LIBS)

firmware-all: $(FIRMWARE_RC16_RUNS) $(FIRMWARE_RC32_RUNS)

firmware-rc32: $(FIRMWARE_RC32_RUNS)

$(FIRMWARE_RC16_RUNS): firmware-rc16-%: llvm-riscc
	+$(MAKE) --no-print-directory RISCC_TOOLCHAIN_READY=1 PROFILE=$* firmware

$(FIRMWARE_RC32_RUNS): firmware-rc32-%: llvm-riscc
	+$(MAKE) --no-print-directory RISCC_TOOLCHAIN_READY=1 \
	  RISCC_XLEN=32 PROFILE=$* firmware

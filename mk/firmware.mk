FIRMWARE_RULES := Makefile mk/firmware.mk

RISCC_FIRMWARE_BUILD ?= build/firmware/$(PROFILE)
RISCC_TARGET_FEATURES ?=
RISCC_TARGET_FLAGS ?= --target=riscc-none-elf -mcpu=$(PROFILE) \
	$(addprefix -m,$(RISCC_TARGET_FEATURES))
SIM_PROFILE_FLAGS := $(SIM_FLAGS_$(PROFILE)) \
	$(patsubst mdu,--mdu,$(filter mdu,$(RISCC_TARGET_FEATURES)))
RISCC_ASFLAGS ?= -ffreestanding
RISCC_CFLAGS ?= -Os -ffreestanding -fno-builtin -fno-pic -fno-pie \
	-fno-unwind-tables -fno-asynchronous-unwind-tables \
	-ffunction-sections -fdata-sections
# Runtime archives are size-biased; applications keep their chosen level.
LIB_CFLAGS := $(filter-out -O%,$(RISCC_CFLAGS)) -Oz
# Discard unused sections from extracted archive members.
RISCC_LDFLAGS ?= -Wl,--gc-sections

FW_VECTORS := $(RISCC_FIRMWARE_BUILD)/vectors.o
FW_CRT0 := $(RISCC_FIRMWARE_BUILD)/crt0.o
IRQ_MODULES := irq irq_default irq_control
IRQ_OBJS := $(addprefix $(RISCC_FIRMWARE_BUILD)/, \
	$(addsuffix .o,$(IRQ_MODULES)))
IRQ_LIB := $(RISCC_FIRMWARE_BUILD)/libirq.a
INTEGER_C_MODULES := integer
INTEGER_ASM_MODULES := integer_div integer_mul integer_shifts shift
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
LIBM_C_MODULES := bits compare decompose fmod next sqrt
LIBM_ASM_MODULES := wide wide_arith wide_shift
LIBM_C_OBJS := $(addprefix $(RISCC_FIRMWARE_BUILD)/libm/, \
	$(addsuffix .o,$(LIBM_C_MODULES)))
LIBM_ASM_OBJS := $(addprefix $(RISCC_FIRMWARE_BUILD)/libm/, \
	$(addsuffix .o,$(LIBM_ASM_MODULES)))
LIBM_OBJS := $(LIBM_C_OBJS) $(LIBM_ASM_OBJS)
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

.PHONY: firmware firmware-all

$(FW_VECTORS): firmware/vectors.S $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_ASFLAGS) -c $< -o $@

$(FW_CRT0): firmware/crt0.S $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_ASFLAGS) -c $< -o $@

$(IRQ_OBJS): $(RISCC_FIRMWARE_BUILD)/%.o: firmware/%.S $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_ASFLAGS) -c $< -o $@

$(INTEGER_C_OBJS): \
		$(RISCC_FIRMWARE_BUILD)/builtins/%.o: firmware/builtins/%.c $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_CFLAGS) -c $< -o $@

$(INTEGER_ASM_OBJS): \
		$(RISCC_FIRMWARE_BUILD)/builtins/%.o: firmware/builtins/%.S $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_ASFLAGS) -c $< -o $@

SOFT_FLOAT_ASM_nano := nano
SOFT_FLOAT_ASM_min := mainline
SOFT_FLOAT_ASM_sys := mainline
SOFT_FLOAT_ASM_full := mainline
SOFT_FLOAT_ASM := $(SOFT_FLOAT_ASM_$(PROFILE))

$(addprefix $(RISCC_FIRMWARE_BUILD)/builtins/softfloat/, \
	$(addsuffix .o,$(SOFT_FLOAT_ASM_MODULES))): \
		$(RISCC_FIRMWARE_BUILD)/builtins/softfloat/%.o: \
		firmware/builtins/softfloat/%_$(SOFT_FLOAT_ASM).S \
		$(FIRMWARE_RULES) $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_ASFLAGS) -c $< -o $@

$(SOFT_FLOAT_PACK_OBJ): \
		firmware/builtins/softfloat/pack_sf_mainline.S $(FIRMWARE_RULES) $(RISCC_CLANG)
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

$(SOFT_FLOAT_MUL24_OBJ): \
		firmware/builtins/softfloat/mul24.S $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_ASFLAGS) -c $< -o $@

$(RISCC_FIRMWARE_BUILD)/libc/%.o: firmware/libc/%.c \
		$(LIBC_HEADERS) $(FIRMWARE_RULES) $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(LIB_CFLAGS) -Ifirmware/include -c $< -o $@

$(LIBM_C_OBJS): $(RISCC_FIRMWARE_BUILD)/libm/%.o: firmware/libm/%.c \
		firmware/libm/internal.h $(LIBC_HEADERS) $(FIRMWARE_RULES) $(RISCC_CLANG)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(LIB_CFLAGS) -Ifirmware/include -c $< -o $@

$(LIBM_ASM_OBJS): \
		$(RISCC_FIRMWARE_BUILD)/libm/%.o: firmware/libm/%.S $(FIRMWARE_RULES) $(RISCC_CLANG)
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
	$(RISCC_AR) rcs $@ $(INTEGER_OBJS) $(SOFT_FLOAT_OBJS)

$(LIBC_LIB): $(LIBC_OBJS) $(RISCC_AR)
	@mkdir -p $(@D)
	$(RISCC_AR) rcs $@ $(LIBC_OBJS)

$(LIBM_LIB): $(LIBM_OBJS) $(RISCC_AR)
	@mkdir -p $(@D)
	$(RISCC_AR) rcs $@ $(LIBM_OBJS)

$(BSP_LIB): $(BSP_OBJS) $(RISCC_AR)
	@mkdir -p $(@D)
	$(RISCC_AR) rcs $@ $(BSP_OBJS)

$(IRQ_LIB): $(IRQ_OBJS) $(RISCC_AR)
	@mkdir -p $(@D)
	$(RISCC_AR) rcs $@ $(IRQ_OBJS)

firmware: $(FW_VECTORS) $(FW_CRT0) \
	$(FW_LIBS)

firmware-all:
	@for profile in $(PROFILES); do \
	  $(MAKE) --no-print-directory PROFILE=$$profile firmware || exit; \
	done

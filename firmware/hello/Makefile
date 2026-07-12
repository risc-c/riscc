# Complete RISC-C firmware example.  It consumes a prebuilt SDK and uses only
# its variable definitions; it does not invoke another Makefile.

MAKEFILE_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
RISCC_ROOT ?= $(abspath $(MAKEFILE_DIR)/../..)
include $(RISCC_ROOT)/firmware/riscc.mk

APP ?= hello
APP_SRC ?= $(APP).c
BUILD ?= $(RISCC_ROOT)/build/$(APP)
ASM := $(BUILD)/$(APP).s
APP_OBJ := $(BUILD)/$(APP).o
ELF := $(BUILD)/$(APP).elf

.PHONY: all clean
all: $(BUILD)/$(APP).bin $(ASM)

$(APP_OBJ): $(APP_SRC)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_CFLAGS) -c $< -o $@

$(ASM): $(APP_SRC)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_CFLAGS) -S $< -o $@

$(ELF): $(APP_OBJ) $(RISCC_LINKER_SCRIPT) $(RISCC_STARTFILES) \
	$(RISCC_LIBRARIES)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_LDFLAGS) \
	  $(RISCC_STARTFILES) $(APP_OBJ) $(RISCC_LIBRARIES) -o $@

$(BUILD)/$(APP).bin: $(ELF)
	$(RISCC_OBJCOPY) -O binary $< $@

clean:
	rm -rf $(BUILD)

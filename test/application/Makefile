RISCC_ROOT ?= ../../..
PROFILE ?= sys
RISCC_XLEN ?= 16

include $(RISCC_ROOT)/firmware/riscc.mk

RISCC_ARCH := $(if $(filter 32,$(RISCC_XLEN)),rc32,rc16)
BUILD ?= $(RISCC_ROOT)/build/test/application/$(RISCC_ARCH)/$(PROFILE)
OBJS := $(BUILD)/main.o $(BUILD)/helper.o $(BUILD)/cpp_helper.o
ELF := $(BUILD)/application.elf
BIN := $(BUILD)/application.bin

.PHONY: all

all: $(BIN)

$(BUILD)/%.o: %.c
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_CFLAGS) -O2 -c $< -o $@

$(BUILD)/%.o: %.cpp
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_CXXFLAGS) -O2 -c $< -o $@

$(ELF): $(OBJS) $(RISCC_STARTFILES) $(RISCC_LIBRARIES) \
		$(RISCC_LINKER_SCRIPT)
	@mkdir -p $(@D)
	$(RISCC_CLANG) $(RISCC_TARGET_FLAGS) $(RISCC_LDFLAGS) \
	  -Wl,-Map,$(@:.elf=.map) $(RISCC_STARTFILES) $(OBJS) \
	  $(RISCC_LIBRARIES) -o $@

$(BIN): $(ELF)
	$(RISCC_OBJCOPY) -O binary $< $@

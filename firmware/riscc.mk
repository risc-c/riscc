# RISC-C tool and runtime settings for application Makefiles.
#
# Set RISCC_ROOT before including this file.  This fragment deliberately adds
# no targets or recipes: the application Makefile owns its build graph and
# uses the visible variables below in its own commands. Set PROFILE to nano,
# min, sys, or full before including it; full is the default.

ifndef RISCC_ROOT
$(error Set RISCC_ROOT before including firmware/riscc.mk)
endif

LLVM_RISCC_BUILD ?= $(RISCC_ROOT)/build/llvm-riscc
RISCC_CLANG ?= $(LLVM_RISCC_BUILD)/bin/clang
RISCC_AR ?= $(LLVM_RISCC_BUILD)/bin/llvm-ar
RISCC_OBJCOPY ?= $(LLVM_RISCC_BUILD)/bin/llvm-objcopy
PROFILE ?= full
RISCC_LIB_OPT ?= -Oz
ifeq ($(filter $(RISCC_LIB_OPT),-O0 -O1 -O2 -O3 -Os -Oz),)
$(error RISCC_LIB_OPT must be -O0, -O1, -O2, -O3, -Os or -Oz)
endif
RISCC_RUNTIME_SUFFIX := $(if $(filter -Oz,$(RISCC_LIB_OPT)),,$(RISCC_LIB_OPT))
RISCC_XLEN ?= 16
ifeq ($(filter $(RISCC_XLEN),16 32),)
$(error RISCC_XLEN must be 16 or 32)
endif
ifeq ($(RISCC_XLEN),32)
ifeq ($(PROFILE),nano)
$(error RC32 has no Nano profile)
endif
RISCC_RUNTIME_DIR ?= $(RISCC_ROOT)/build/firmware/rc32/$(PROFILE)$(RISCC_RUNTIME_SUFFIX)
RISCC_XLEN_FLAGS := -mrc32
RISCC_LINKER_SCRIPT := $(RISCC_ROOT)/firmware/rc32/unified.ld
else
ifeq ($(PROFILE),nano)
RISCC_RUNTIME_DIR ?= $(RISCC_ROOT)/build/firmware/nano$(RISCC_RUNTIME_SUFFIX)
RISCC_LINKER_SCRIPT := $(RISCC_ROOT)/firmware/nano/unified.ld
else
RISCC_RUNTIME_DIR ?= $(RISCC_ROOT)/build/firmware/rc16/$(PROFILE)$(RISCC_RUNTIME_SUFFIX)
RISCC_LINKER_SCRIPT := $(RISCC_ROOT)/firmware/rc16/unified.ld
endif
RISCC_XLEN_FLAGS :=
endif

RISCC_TARGET_FLAGS := --target=riscc-none-elf -mcpu=$(PROFILE) \
	$(RISCC_XLEN_FLAGS)
RISCC_CFLAGS := $(if $(filter nano min,$(PROFILE)),-Oz,-Os) -fno-pic -fno-pie \
	-fno-unwind-tables -fno-asynchronous-unwind-tables \
	-ffunction-sections -fdata-sections -I$(RISCC_ROOT)/firmware/include
RISCC_CXXFLAGS := $(RISCC_CFLAGS) -std=c++17 -fno-exceptions -fno-rtti \
	-fno-threadsafe-statics -fno-use-cxa-atexit -nostdinc++
RISCC_ASFLAGS := -ffreestanding
RISCC_LDFLAGS := -fuse-ld=lld -nostdlib -Wl,--gc-sections \
	-Wl,-T,$(RISCC_LINKER_SCRIPT)

RISCC_STARTFILES := $(RISCC_RUNTIME_DIR)/vectors.o $(RISCC_RUNTIME_DIR)/crt0.o
RISCC_BSP_LIBRARY ?= $(RISCC_RUNTIME_DIR)/libbsp.a
RISCC_IRQ_LIBRARY_nano :=
RISCC_IRQ_LIBRARY_min :=
RISCC_IRQ_LIBRARY_sys := $(RISCC_RUNTIME_DIR)/libirq.a
RISCC_IRQ_LIBRARY_full := $(RISCC_RUNTIME_DIR)/libirq.a
RISCC_LIBRARIES := $(RISCC_RUNTIME_DIR)/libc.a \
	$(RISCC_RUNTIME_DIR)/libm.a $(RISCC_BSP_LIBRARY) \
	$(RISCC_IRQ_LIBRARY_$(PROFILE)) \
	$(RISCC_RUNTIME_DIR)/libbuiltins.a

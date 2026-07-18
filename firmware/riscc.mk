# RISC-C tool and runtime settings for application Makefiles.
#
# Set RISCC_ROOT before including this file.  This fragment deliberately adds
# no targets or recipes: the application Makefile owns its build graph and
# uses the visible variables below in its own commands. Set RISCC_CPU to min,
# sys, or full before including it; full is the default.

ifndef RISCC_ROOT
$(error Set RISCC_ROOT before including firmware/riscc.mk)
endif

LLVM_RISCC_BUILD ?= $(RISCC_ROOT)/build/llvm-riscc
RISCC_CLANG ?= $(LLVM_RISCC_BUILD)/bin/clang
RISCC_AR ?= $(LLVM_RISCC_BUILD)/bin/llvm-ar
RISCC_OBJCOPY ?= $(LLVM_RISCC_BUILD)/bin/llvm-objcopy
RISCC_CPU ?= full
RISCC_RUNTIME_DIR ?= $(RISCC_ROOT)/build/firmware$(if \
	$(filter full,$(RISCC_CPU)),,/$(RISCC_CPU))

RISCC_TARGET_FLAGS := --target=riscc-none-elf -mcpu=$(RISCC_CPU)
RISCC_CFLAGS := -Os -ffreestanding -fno-builtin -fno-pic -fno-pie \
	-fno-unwind-tables -fno-asynchronous-unwind-tables \
	-ffunction-sections -fdata-sections -I$(RISCC_ROOT)/firmware/include
RISCC_ASFLAGS := -ffreestanding
RISCC_LDFLAGS := -fuse-ld=lld -nostdlib -Wl,--gc-sections \
	-Wl,-T,$(RISCC_ROOT)/firmware/unified.ld

RISCC_STARTFILES := $(RISCC_RUNTIME_DIR)/vectors.o $(RISCC_RUNTIME_DIR)/crt0.o
RISCC_BSP_LIBRARY ?= $(RISCC_RUNTIME_DIR)/libbsp.a
RISCC_LIBRARIES := $(RISCC_RUNTIME_DIR)/libc.a \
	$(RISCC_RUNTIME_DIR)/libm.a $(RISCC_BSP_LIBRARY) \
	$(if $(filter-out min,$(RISCC_CPU)),$(RISCC_RUNTIME_DIR)/libirq.a) \
	$(RISCC_RUNTIME_DIR)/libbuiltins.a
RISCC_LINKER_SCRIPT := $(RISCC_ROOT)/firmware/unified.ld

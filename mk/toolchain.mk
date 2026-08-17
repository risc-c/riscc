LLVM_SOURCE ?= external/llvm-project/llvm
LLVM_BUILD ?= build/llvm-riscc
LLVM_GENERATOR ?= Ninja
LLVM_BUILD_TYPE ?= Release
CMAKE ?= cmake
LLVM_CMAKE_FLAGS ?=
# Configure only the tools and lit support used by this repository.
LLVM_CONFIG_FLAGS := \
	-DLLVM_INCLUDE_TESTS=ON \
	-DLLVM_INCLUDE_EXAMPLES=OFF \
	-DLLVM_INCLUDE_BENCHMARKS=OFF \
	-DLLVM_INCLUDE_DOCS=OFF \
	-DLLVM_INCLUDE_UTILS=ON \
	-DLLVM_INCLUDE_RUNTIMES=OFF \
	-DLLVM_BUILD_TOOLS=OFF \
	-DLLVM_BUILD_UTILS=OFF \
	-DLLVM_BUILD_RUNTIMES=OFF \
	-DLLVM_BUILD_RUNTIME=OFF \
	-DLLVM_ENABLE_BINDINGS=OFF \
	-DLLVM_ENABLE_TELEMETRY=OFF \
	-DLLVM_ENABLE_BACKTRACES=OFF \
	-DLLVM_ENABLE_LIBEDIT=OFF \
	-DLLVM_ENABLE_LIBPFM=OFF \
	-DLLVM_ENABLE_LIBXML2=OFF \
	-DLLVM_ENABLE_ZLIB=OFF \
	-DLLVM_ENABLE_ZSTD=OFF \
	-DCLANG_BUILD_TOOLS=OFF \
	-DCLANG_INCLUDE_TESTS=ON \
	-DCLANG_INCLUDE_DOCS=OFF \
	-DCLANG_ENABLE_STATIC_ANALYZER=OFF \
	-DCLANG_PLUGIN_SUPPORT=OFF \
	-DLLD_BUILD_TOOLS=ON
LLVM_TOOLS ?= clang lld llvm-ar llvm-mc llvm-objcopy \
	llvm-objdump llvm-readobj llvm-nm llvm-size \
	llc opt llvm-as llvm-dis
LLVM_LIT_TOOLS ?= FileCheck count llvm-config not split-file yaml2obj
LIT_ARGS ?= -sv
# Set LLVM_LAUNCHER empty to disable ccache for the host tools.
LLVM_LAUNCHER ?= $(CCACHE)
LLVM_LAUNCHER_FLAGS := \
	-DCMAKE_C_COMPILER_LAUNCHER=$(LLVM_LAUNCHER) \
	-DCMAKE_CXX_COMPILER_LAUNCHER=$(LLVM_LAUNCHER)

LLVM_BIN := $(LLVM_BUILD)/bin
LLVM_LIT := $(LLVM_BIN)/llvm-lit
LLVM_TESTS := \
	external/llvm-project/llvm/test/MC/RISCC \
	external/llvm-project/llvm/test/CodeGen/RISCC \
	external/llvm-project/clang/test/CodeGen/RISCC \
	external/llvm-project/clang/test/Sema/RISCC \
	external/llvm-project/clang/test/Driver/riscc-toolchain.c \
	external/llvm-project/clang/test/Preprocessor/init-riscc.c \
	external/llvm-project/clang/test/Modules/riscc-target-features.m \
	$(wildcard external/llvm-project/lld/test/ELF/riscc-*)
RISCC_CLANG := $(LLVM_BIN)/clang
RISCC_AR := $(LLVM_BIN)/llvm-ar
RISCC_OBJCOPY := $(LLVM_BIN)/llvm-objcopy
RISCC_MC := $(LLVM_BIN)/llvm-mc
RISCC_LLD := $(LLVM_BIN)/ld.lld
LLVM_CACHE := $(LLVM_BUILD)/CMakeCache.txt

.PHONY: llvm-riscc-configure llvm-riscc check-llvm-riscc

llvm-riscc-configure:
	$(CMAKE) -S $(LLVM_SOURCE) -B $(LLVM_BUILD) \
	  -G '$(LLVM_GENERATOR)' \
	  -DCMAKE_BUILD_TYPE='$(LLVM_BUILD_TYPE)' \
	  -DLLVM_ENABLE_PROJECTS='clang;lld' \
	  -DLLVM_TARGETS_TO_BUILD= \
	  -DLLVM_EXPERIMENTAL_TARGETS_TO_BUILD=RISCC \
	  $(LLVM_CONFIG_FLAGS) \
	  $(LLVM_LAUNCHER_FLAGS) \
	  $(LLVM_CMAKE_FLAGS) \
	  -DLLVM_ENABLE_ASSERTIONS=ON

# Ninja reruns CMake when LLVM inputs change.
$(LLVM_CACHE):
	$(MAKE) llvm-riscc-configure

llvm-riscc: $(LLVM_CACHE)
	$(CMAKE) --build $(LLVM_BUILD) \
	  --target $(LLVM_TOOLS) --parallel $(RISCC_BUILD_JOBS)

# Build and run the focused RISC-C lit suites.
check-llvm-riscc: llvm-riscc-configure
	$(CMAKE) --build $(LLVM_BUILD) \
	  --target $(LLVM_TOOLS) $(LLVM_LIT_TOOLS) \
	  --parallel $(RISCC_BUILD_JOBS)
	$(LLVM_LIT) $(LIT_ARGS) $(LLVM_TESTS)

# Artifacts depend on the individual tools, which are provided by llvm-riscc.
$(RISCC_CLANG) $(RISCC_AR) $(RISCC_OBJCOPY) $(RISCC_MC) $(RISCC_LLD): | llvm-riscc

$(foreach profile,$(PROFILES),build/bin/$(profile).bin) \
		$(foreach extension,$(EXTENSIONS),build/bin/full-$(extension).bin) \
		$(BENCH_BIN) $(NANO_BENCH_BIN) $(FUNNEL_BIN) $(RC32_SYS_BIN): \
		$(RISCC_MC) $(RISCC_LLD) $(RISCC_OBJCOPY)

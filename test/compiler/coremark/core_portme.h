/* RISC-C bare-metal CoreMark port; benchmark sources remain upstream. */
#ifndef RISCC_CORE_PORTME_H
#define RISCC_CORE_PORTME_H

#include <stddef.h>
#include <stdint.h>

#define HAS_FLOAT 0
#define HAS_TIME_H 0
#define USE_CLOCK 0
#define HAS_STDIO 1
#define HAS_PRINTF 0
#define SEED_METHOD SEED_VOLATILE
#define MEM_METHOD MEM_STATIC
#define MULTITHREAD 1
#define MAIN_HAS_NOARGC 1
#define MAIN_HAS_NORETURN 0
#define COMPILER_VERSION "Clang " __clang_version__
#define MEM_LOCATION "64 KiB unified SRAM; see runner for cache configuration"

#ifndef COMPILER_FLAGS
#define COMPILER_FLAGS "unspecified"
#endif
#ifndef COREMARK_CLOCK_HZ
#define COREMARK_CLOCK_HZ 100000000UL
#endif
#ifndef ITERATIONS
#define ITERATIONS 100
#endif
#if ITERATIONS <= 0 || ITERATIONS > 2147483647
#error "Use a positive iteration count; automatic calibration is not used by this port"
#endif
#if COREMARK_CLOCK_HZ <= 0 || COREMARK_CLOCK_HZ > 0xffffffffULL
#error "COREMARK_CLOCK_HZ must fit a positive 32-bit clock frequency"
#endif

typedef int16_t ee_s16;
typedef uint16_t ee_u16;
typedef int32_t ee_s32;
typedef uint32_t ee_u32;
typedef uint8_t ee_u8;
typedef double ee_f32;
typedef uintptr_t ee_ptr_int;
typedef size_t ee_size_t;
typedef uint64_t CORE_TICKS;
#define CORETIMETYPE CORE_TICKS
#define align_mem(x) (void *)(4 + (((ee_ptr_int)(x) - 1) & ~(ee_ptr_int)3))

_Static_assert(sizeof(ee_u8) == 1 && sizeof(ee_s16) == 2 &&
               sizeof(ee_u16) == 2 && sizeof(ee_s32) == 4 &&
               sizeof(ee_u32) == 4, "CoreMark requires exact-width types");
_Static_assert(sizeof(void *) == 4, "The CoreMark port targets RC32");

typedef struct CORE_PORTABLE_S {
    ee_u8 portable_id;
} core_portable;

extern ee_u32 default_num_contexts;
void portable_init(core_portable *port, int *argc, char *argv[]);
void portable_fini(core_portable *port);
int ee_printf(const char *format, ...);

#endif

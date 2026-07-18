#ifndef RISCC_COMPILER_FEATURES_H
#define RISCC_COMPILER_FEATURES_H

typedef __UINT8_TYPE__ u8;
typedef __INT8_TYPE__ s8;
typedef __UINT16_TYPE__ u16;
typedef __INT16_TYPE__ s16;
typedef __UINT32_TYPE__ u32;
typedef __INT32_TYPE__ s32;
typedef __UINT64_TYPE__ u64;
typedef __INT64_TYPE__ s64;
typedef __SIZE_TYPE__ usize;
typedef __PTRDIFF_TYPE__ sptr;

struct feature_byte
{
    s8 value;
};

struct feature_pair
{
    u16 first;
    u16 second;
};

struct feature_quad
{
    u16 word[4];
};

struct feature_large
{
    u16 word[5];
};

struct feature_vararg_pair
{
    u16 first;
    u16 second;
};

struct feature_vararg_bytes3
{
    u8 byte[3];
};

struct feature_float_pair
{
    float first;
    float second;
};

typedef u16 (*feature_binary_fn)(u16, u16);
typedef u16 (*feature_test_fn)(void);

u16 feature_test_language(void);
u16 feature_test_integer(void);
u16 feature_test_builtins(void);
u16 feature_test_memory(void);
u16 feature_test_abi(void);
u16 feature_test_varargs(void);
u16 feature_test_float(void);
u16 feature_test_tail(void);

u16 feature_abi_narrow(s8, u8, s16, u16, s8);
u16 feature_abi_stack_mix(u16, u16, u16, u32, u16);
u16 feature_abi_pair_regs(u16, struct feature_pair, u16);
u16 feature_abi_pair_stack(u16, u16, u16, struct feature_pair, u16);
u16 feature_abi_large_arg(struct feature_large, u16);
u16 feature_abi_u64_stack(u16, u64, u16);
struct feature_byte feature_abi_return_byte(s8);
struct feature_pair feature_abi_return_pair(u16);
struct feature_quad feature_abi_return_quad(u16);
struct feature_large feature_abi_return_large(u16);
u32 feature_abi_return_u32(u16);
u64 feature_abi_return_u64(u16);
u64 feature_abi_u64_roundtrip(u64);
u16 feature_abi_add(u16, u16);
u16 feature_abi_apply(feature_binary_fn, u16, u16);
u16 feature_abi_pressure(u16);
u16 feature_check_callee_saved(void);

u16 feature_varargs_sum(u16, u16, ...);
u16 feature_varargs_promote(u16, ...);
u16 feature_varargs_copy(u16, ...);
u16 feature_varargs_mix(u16, u16, u16, u16, u16, ...);

float feature_float_add(float, float);
float feature_float_stack(u16, u16, u16, float, u16);
double feature_double_arithmetic(double, double);
double feature_float_mixed(u16, float, u16);
long double feature_long_double_roundtrip(long double);
struct feature_float_pair feature_float_pair_roundtrip(
    struct feature_float_pair);
u16 feature_float_varargs(u16, ...);

extern feature_binary_fn feature_global_binary;

#endif

#ifndef RISCC_COMPILER_C_ABI_H
#define RISCC_COMPILER_C_ABI_H

typedef __UINT8_TYPE__ u8;
typedef __INT8_TYPE__ s8;
typedef __UINT16_TYPE__ u16;
typedef __INT16_TYPE__ s16;
typedef __UINT32_TYPE__ u32;
typedef __INT32_TYPE__ s32;
typedef __UINT64_TYPE__ u64;
typedef __INT64_TYPE__ s64;
typedef __SIZE_TYPE__ usize;

struct c_abi_pair
{
    u16 first;
    u16 second;
};

struct c_abi_large
{
    u16 word[5];
};

typedef u16 (*c_abi_unary_fn)(u16);

extern volatile u32 c_abi_data_word;
extern volatile u32 c_abi_bss_word;
extern const u16 c_abi_rodata_words[3];
extern __thread volatile u32 c_abi_tls_data_word;
extern _Thread_local volatile u32 c_abi_tls_bss_word;

u16 c_abi_sum_six(u16, u16, u16, u16, u16, u16);
u16 c_abi_stack_mix(u16, u16, u16, u32, u16);
struct c_abi_pair c_abi_make_pair(u16);
struct c_abi_large c_abi_make_large(u16);
u16 c_abi_call(c_abi_unary_fn, u16);
u16 c_abi_add_seven(u16);
u16 c_abi_stack_and_recursion(u16);
u16 c_abi_varargs_sum(u16, unsigned int, ...);
u16 c_abi_varargs_mix(u16, u16, u16, u16, unsigned int, ...);
u16 c_abi_tls_update(u16);
float c_abi_float_scale(float);
double c_abi_double_scale(double);

#endif

#ifndef RISCC_RC32_COMPILER_TEST_H
#define RISCC_RC32_COMPILER_TEST_H

typedef __UINT8_TYPE__ u8;
typedef __UINT16_TYPE__ u16;
typedef __UINT32_TYPE__ u32;
typedef __INT32_TYPE__ s32;
typedef __UINT64_TYPE__ u64;
typedef __INT64_TYPE__ s64;

struct rc32_pair
{
    u32 first;
    u32 second;
};

struct rc32_large
{
    u32 word[4];
};

#ifdef __cplusplus
extern "C" {
#endif

extern volatile u32 rc32_global;
extern volatile u32 rc32_bss;
extern __thread volatile u32 rc32_tls_data;
extern _Thread_local volatile u32 rc32_tls_bss;

u32 rc32_stack_sum(u32, u32, u32, u32, u32);
struct rc32_pair rc32_make_pair(u32);
struct rc32_large rc32_make_large(u32);
u32 rc32_varargs_sum(u32, u32, ...);
u32 rc32_varargs_pair(u32, u32, ...);
u32 rc32_tls_update(u32);
u32 rc32_literal_long(u32);
u32 rc32_cpp_check(u32);
u16 rc32_test_builtins(void);
u16 rc32_test_float(void);
u16 rc32_test_tail(void);

#ifdef __cplusplus
}
#endif

#endif

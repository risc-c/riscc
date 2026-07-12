#ifndef RISCC_COMPILER_TEST_H
#define RISCC_COMPILER_TEST_H

typedef unsigned char u8;
typedef signed char s8;
typedef unsigned short u16;
typedef signed short s16;
typedef unsigned long u32;
typedef signed long s32;
typedef unsigned long long u64;

struct pair16 {
    u16 first;
    u16 second;
};

typedef u16 (*unary16_fn)(u16);

extern volatile u16 compiler_bss_word;
extern volatile u16 compiler_data_word;
extern const u16 compiler_rodata_words[3];
extern __thread volatile u16 compiler_tls_data_word;
extern _Thread_local volatile u16 compiler_tls_bss_word;

struct pair16 make_pair16(u16 value);
u16 sum_six(u16 a, u16 b, u16 c, u16 d, u16 e, u16 f);
u16 stack_and_recursion(u16 value);
u16 add_seven(u16 value);
u16 call_unary16(unary16_fn fn, u16 value);
u32 mix_word32(u32 value);
u16 divide_word16(u16 value, u16 divisor);
s16 signed_divide_word16(s16 value, s16 divisor);
u32 arithmetic_word32(u32 value);
u64 arithmetic_word64(u64 value, u16 shift);
u16 compiler_tls_helper(u16 value);

#endif

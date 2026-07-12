#include "riscc_compiler_test.h"

#define RESULT_WORD (*(volatile u16 *)0xfffeu)

#ifdef RISCC_COMPILER_UART
#include <stdio.h>
#endif

static void fail(u16 code)
{
    RESULT_WORD = (u16)(0x0b00u | code);
    for (;;)
        ;
}

int main(void)
{
    struct pair16 pair;

    _Static_assert(sizeof(u8) == 1, "RISC-C byte size");
    _Static_assert(sizeof(u16) == 2, "RISC-C int size");
    _Static_assert(sizeof(u32) == 4, "RISC-C long size");
    _Static_assert(sizeof(void *) == 2, "RISC-C data pointer size");
    _Static_assert(sizeof(unary16_fn) == 2, "RISC-C code pointer size");

    if (compiler_bss_word != 0)
        fail(1);
    if (compiler_data_word != 0x1357)
        fail(2);
    if (compiler_rodata_words[0] != 0x2468 ||
        compiler_rodata_words[1] != 0xabcd ||
        compiler_rodata_words[2] != 0x55aa)
        fail(3);
    if (compiler_tls_data_word != 0x7a35)
        fail(14);
    if (compiler_tls_bss_word != 0)
        fail(15);
    if (compiler_tls_helper(0x0033) != 0x7a9b)
        fail(16);
    if (compiler_tls_data_word != 0x7a68 || compiler_tls_bss_word != 0x0033)
        fail(17);

    pair = make_pair16(0x1234);
    if (pair.first != 0x1234 || pair.second != 0xedcb)
        fail(4);

    if (sum_six(1, 2, 3, 4, 5, 6) != 21)
        fail(5);
    if (stack_and_recursion(5) != 30)
        fail(6);
    if (call_unary16(add_seven, 35) != 42)
        fail(7);
    if (mix_word32(0x12345678ul) != 0x23ba7865ul)
        fail(8);
    if (divide_word16(1000u, 37u) != 28u)
        fail(10);
    if (signed_divide_word16(-1000, 37) != -28)
        fail(11);
    if (arithmetic_word32(12345ul) != 0x3053ul)
        fail(12);
    if (arithmetic_word64(0x12345678ull, 4u) != 0x12345678dull)
        fail(13);

    compiler_bss_word = 0xa55a;
    if (compiler_bss_word != 0xa55a)
        fail(9);

#ifdef RISCC_COMPILER_UART
    puts("LLVM RISCC PASS");
#endif
    RESULT_WORD = 0x600d;
    for (;;)
        ;
}

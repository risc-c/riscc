#ifndef RISCC_LIBC_TEST_H
#define RISCC_LIBC_TEST_H

#define RESULT_WORD (*(volatile unsigned short *)0xfffeu)

static void pass(void) __attribute__((noreturn));
static void fail(unsigned int code) __attribute__((noreturn));

static void pass(void)
{
    RESULT_WORD = 0x600du;
    for (;;)
        ;
}

static void fail(unsigned int code)
{
    RESULT_WORD = 0xc000u | (code & 0x0fffu);
    for (;;)
        ;
}

#define CHECK(condition, code) \
    do \
    { \
        if (!(condition)) \
            fail(code); \
    } \
    while (0)

#endif

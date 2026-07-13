#include "riscc_compiler_features.h"

#define RESULT_WORD (*(volatile u16 *)0xfffeu)

// A failure result is 0xbMDD: M is the one-based module index below and DD is
// that module's return code.  Success uses the project-wide 0x600d sentinel.
static const feature_test_fn feature_tests[] =
{
    feature_test_language,
    feature_test_integer,
    feature_test_builtins,
    feature_test_memory,
    feature_test_abi,
    feature_test_varargs,
};

static void fail(u16 module, u16 detail)
{
    RESULT_WORD = (u16)(0xb000u | (module << 8) | detail);
    for (;;)
        ;
}

int main(void)
{
    u16 index;

    _Static_assert(sizeof(u8) == 1, "8-bit byte type");
    _Static_assert(sizeof(u16) == 2, "16-bit short and int type");
    _Static_assert(sizeof(u32) == 4, "32-bit long type");
    _Static_assert(sizeof(u64) == 8, "64-bit long long type");
    _Static_assert(sizeof(short) == 2 && sizeof(int) == 2, "16-bit C int");
    _Static_assert(sizeof(long) == 4 && sizeof(long long) == 8,
        "wide C integer types");
    _Static_assert(sizeof(usize) == 2 && sizeof(sptr) == 2,
        "pointer-sized integer types");
    _Static_assert(sizeof(void *) == 2, "16-bit data pointer");
    _Static_assert(sizeof(feature_test_fn) == 2, "16-bit code pointer");
    _Static_assert(sizeof(float) == 4, "32-bit float representation");
    _Static_assert(sizeof(double) == 8, "64-bit double representation");
    _Static_assert(sizeof(long double) == 8, "64-bit long double representation");
    _Static_assert(_Alignof(float) == 2, "float ABI alignment");
    _Static_assert(_Alignof(double) == 2, "double ABI alignment");
    _Static_assert(_Alignof(long long) == 2, "wide integer ABI alignment");
    _Static_assert(_Alignof(long double) == 2, "long double ABI alignment");

    for (index = 0;
        index != (u16)(sizeof(feature_tests) / sizeof(feature_tests[0]));
        ++index)
    {
        u16 detail = feature_tests[index]();
        if (detail != 0)
            fail((u16)(index + 1), detail);
    }

    RESULT_WORD = 0x600d;
    for (;;)
        ;
}

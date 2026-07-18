#include "riscc_compiler_features.h"

#define RESULT_WORD (*(volatile u16 *)0xfffeu)

int main(void)
{
    u16 detail = feature_test_float();

    RESULT_WORD = detail == 0 ? 0x600du : (u16)(0xbf00u | detail);
    for (;;)
        ;
}

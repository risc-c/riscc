#include <stdint.h>

uint32_t application_helper(uint32_t left, uint32_t right)
{
    uint32_t mixed = (left ^ right) + UINT32_C(0x10203040);
    return mixed / 3 + mixed % 3;
}

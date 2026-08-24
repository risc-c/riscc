#include "cpp_test.h"

namespace
{
constexpr cpp_pair constant_pair = {0x0102u, 0x0304u};

[[noreturn]] void fail(unsigned short code)
{
    *reinterpret_cast<volatile unsigned short *>(0xfffeu) =
        static_cast<unsigned short>(0xc000u | code);
    for (;;)
        asm volatile("" ::: "memory");
}
}

extern "C" int main()
{
    static_assert(sizeof(cpp_word) == sizeof(void *));
    static_assert(__is_trivially_copyable(cpp_pair));
    static_assert(constant_pair.first + constant_pair.second == 0x0406u);

    if (cpp_constant_seed != 0x1234u)
        fail(1);

    cpp_pair pair = cpp_make_pair(0x1357u);
    if (pair.first != 0x1368u || pair.second != 0x46fdu)
        fail(2);

    if (cpp_cross_tu_sum(pair, 0x00f0u) != 0x5a95u)
        fail(3);

    cpp_pair transformed = cpp_transform_pair(pair);
    if (transformed.first != 0x4700u || transformed.second != 0x1c67u)
        fail(4);

    cpp_accumulator accumulator(0x0100u);
    accumulator.add(cpp_cross_tu_sum(pair, 0x00f0u));
    accumulator.add(transformed.first);
    if (accumulator.value() != 0xa295u)
        fail(5);

    *reinterpret_cast<volatile unsigned short *>(0xfffeu) = 0x600du;
    return 0;
}

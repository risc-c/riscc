#include "cpp_test.h"

const cpp_word cpp_constant_seed = 0x1234u;

cpp_pair cpp_make_pair(cpp_word input)
{
    return {input + 0x11u, input ^ 0x55aau};
}

cpp_pair cpp_transform_pair(cpp_pair input)
{
    cpp_pair result = {input.second + 3u, input.first ^ 0x0f0fu};
    return result;
}

cpp_word cpp_cross_tu_sum(const cpp_pair &input, cpp_word bias)
{
    return (input.first + input.second) ^ bias;
}

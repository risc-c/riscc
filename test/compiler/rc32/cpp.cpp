#include "test.h"

namespace
{
class accumulator
{
public:
    explicit accumulator(u32 initial) : value(initial) {}
    void add(u32 amount) { value += amount; }
    u32 get() const { return value; }

private:
    u32 value;
};

struct words
{
    u32 first;
    u32 second;
};
}

extern "C" u32 rc32_cpp_check(u32 input)
{
    accumulator sum(input);
    words value = {input ^ 0x11111111u, input + 0x01020304u};
    sum.add(value.first);
    sum.add(value.second);
    return sum.get();
}

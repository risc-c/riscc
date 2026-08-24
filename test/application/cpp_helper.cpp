#include <stdint.h>

namespace
{
struct operands
{
    uint32_t left;
    uint32_t right;
};

class mixer
{
public:
    explicit mixer(operands value) : value_(value) {}

    uint32_t result() const
    {
        return (value_.left ^ UINT32_C(0x55aa55aa)) +
               (value_.right ^ UINT32_C(0xaa55aa55));
    }

private:
    operands value_;
};
}

extern "C" uint32_t application_cpp_helper(uint32_t left, uint32_t right)
{
    return mixer({left, right}).result();
}

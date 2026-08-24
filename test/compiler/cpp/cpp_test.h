#ifndef RISCC_CPP_TEST_H
#define RISCC_CPP_TEST_H

using cpp_word = __UINTPTR_TYPE__;

struct cpp_pair
{
    cpp_word first;
    cpp_word second;
};

class cpp_accumulator
{
public:
    constexpr explicit cpp_accumulator(cpp_word initial) : value_(initial) {}
    constexpr void add(cpp_word amount) { value_ += amount; }
    constexpr cpp_word value() const { return value_; }

private:
    cpp_word value_;
};

extern const cpp_word cpp_constant_seed;

cpp_pair cpp_make_pair(cpp_word input);
cpp_pair cpp_transform_pair(cpp_pair input);
cpp_word cpp_cross_tu_sum(const cpp_pair &input, cpp_word bias);

#endif

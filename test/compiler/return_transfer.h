#ifndef RISCC_COMPILER_RETURN_TRANSFER_H
#define RISCC_COMPILER_RETURN_TRANSFER_H

typedef __UINTPTR_TYPE__ return_word;

struct return_three_words {
    return_word first, second, third;
};

static __attribute__((noinline)) void
return_fill(volatile return_word *frame, return_word last, return_word value)
{
    frame[0] = value + 1;
    frame[last] = value + 2;
    __asm__ volatile("" ::: "r4", "r5");
}

/* An opaque call forces preservation of the incoming return address. Passing
 * the array prevents shrinking the frame to its two accessed elements. */
static void (*volatile return_fill_target)(volatile return_word *, return_word,
                                          return_word) = return_fill;

static __attribute__((noinline)) struct return_three_words
return_small_frame(return_word value)
{
    volatile return_word frame[4];
    return_fill_target(frame, 3, value);
    struct return_three_words result = {frame[0], frame[3], value + 3};
    return result;
}

static __attribute__((noinline)) struct return_three_words
return_large_frame(return_word value)
{
    volatile return_word frame[256];
    return_fill_target(frame, 255, value);
    struct return_three_words result = {frame[0], frame[255], value + 3};
    return result;
}

static unsigned test_return_transfers(void)
{
    for (return_word value = 0; value < 4; ++value) {
        struct return_three_words small = return_small_frame(value);
        if (small.first != value + 1 || small.second != value + 2 ||
            small.third != value + 3)
            return 1;
        struct return_three_words large = return_large_frame(value + 100);
        if (large.first != value + 101 || large.second != value + 102 ||
            large.third != value + 103)
            return 2;
    }
    return 0;
}

#endif

#include "bench.h"

#include <math.h>

typedef union
{
    float value;
    uint32_t bits;
} float_bits;

static volatile float inputs[4] = {1.25f, 2.5f, 0.75f, 3.125f};

BENCH_NOINLINE static uint16_t softfloat_libm(void)
{
    float x = inputs[0];
    float y = inputs[1];
    float z = inputs[2];
    float total = inputs[3];
    uint16_t iteration;
    float_bits result;

    for (iteration = 0; iteration != 8; ++iteration)
    {
        int32_t signed_part;
        uint32_t unsigned_part;
        float converted;

        x = sqrtf(x * x + y + 0.25f);
        y = fmodf(y + x * 0.375f + z, 4.0f) + 0.5f;
        z = sqrtf(z * z + 0.5f) * 0.5f + 0.125f;
        signed_part = (int32_t)(total - x);
        unsigned_part = (uint32_t)(y + z);
        converted = (float)signed_part + (float)unsigned_part;
        if (x > z && y != 0.0f)
            total += (x * y + z - converted * 0.03125f) /
                (float)(iteration + 2);
        else
            total -= 0.125f;
    }

    result.value = total + x + y + z;
    return bench_fold32(result.bits);
}

int main(void)
{
    bench_finish(softfloat_libm(), UINT16_C(0x721e));
}

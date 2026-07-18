#include "bench.h"
#include <math.h>

enum { N = 3, ELEMENTS = N * N };

static volatile float multiply_left[ELEMENTS] =
{
     3.0f, -2.0f,  5.0f,
    -1.0f,  4.0f,  2.0f,
     6.0f,  0.0f, -2.0f,
};

static volatile float multiply_right[ELEMENTS] =
{
     2.0f,  1.0f, -3.0f,
     5.0f, -2.0f,  0.0f,
    -1.0f,  3.0f,  2.0f,
};

static volatile float lu_input[ELEMENTS] =
{
    4.0f, 3.0f, 2.0f,
    6.0f, 3.0f, 0.0f,
    2.0f, 1.0f, 8.0f,
};

static volatile float cholesky_input[ELEMENTS] =
{
    25.0f, 15.0f, -5.0f,
    15.0f, 18.0f,  0.0f,
    -5.0f,  0.0f, 11.0f,
};

static volatile float qr_input[ELEMENTS] =
{
    12.0f, -51.0f,   4.0f,
     6.0f, 167.0f, -68.0f,
    -4.0f,  24.0f, -41.0f,
};

static volatile float product[ELEMENTS];
static volatile float lu_lower[ELEMENTS];
static volatile float lu_upper[ELEMENTS];
static volatile float cholesky_lower[ELEMENTS];
static volatile float qr_q[ELEMENTS];
static volatile float qr_r[ELEMENTS];

BENCH_NOINLINE static void matrix_multiply(void)
{
    uint16_t row;
    uint16_t column;
    uint16_t k;

    for (row = 0; row != N; ++row)
        for (column = 0; column != N; ++column)
        {
            float sum = 0.0f;
            for (k = 0; k != N; ++k)
                sum += multiply_left[row * N + k] *
                    multiply_right[k * N + column];
            product[row * N + column] = sum;
        }
}

BENCH_NOINLINE static void lu_decompose(void)
{
    uint16_t row;
    uint16_t column;
    uint16_t k;

    for (row = 0; row != N; ++row)
        for (column = 0; column != N; ++column)
        {
            lu_lower[row * N + column] = 0.0f;
            lu_upper[row * N + column] = 0.0f;
        }

    for (row = 0; row != N; ++row)
    {
        for (column = row; column != N; ++column)
        {
            float sum = 0.0f;
            for (k = 0; k != row; ++k)
                sum += lu_lower[row * N + k] *
                    lu_upper[k * N + column];
            lu_upper[row * N + column] =
                lu_input[row * N + column] - sum;
        }

        lu_lower[row * N + row] = 1.0f;
        for (column = row + 1; column != N; ++column)
        {
            float sum = 0.0f;
            for (k = 0; k != row; ++k)
                sum += lu_lower[column * N + k] *
                    lu_upper[k * N + row];
            lu_lower[column * N + row] =
                (lu_input[column * N + row] - sum) /
                lu_upper[row * N + row];
        }
    }
}

BENCH_NOINLINE static void cholesky_decompose(void)
{
    uint16_t row;
    uint16_t column;
    uint16_t k;

    for (row = 0; row != N; ++row)
        for (column = 0; column != N; ++column)
            cholesky_lower[row * N + column] = 0.0f;

    for (row = 0; row != N; ++row)
        for (column = 0; column <= row; ++column)
        {
            float sum = 0.0f;
            for (k = 0; k != column; ++k)
                sum += cholesky_lower[row * N + k] *
                    cholesky_lower[column * N + k];

            if (row == column)
                cholesky_lower[row * N + column] =
                    sqrtf(cholesky_input[row * N + row] - sum);
            else
                cholesky_lower[row * N + column] =
                    (cholesky_input[row * N + column] - sum) /
                    cholesky_lower[column * N + column];
        }
}

BENCH_NOINLINE static void qr_decompose(void)
{
    float work[ELEMENTS];
    uint16_t row;
    uint16_t column;
    uint16_t next;

    for (row = 0; row != N; ++row)
        for (column = 0; column != N; ++column)
        {
            work[row * N + column] = qr_input[row * N + column];
            qr_q[row * N + column] = 0.0f;
            qr_r[row * N + column] = 0.0f;
        }

    for (column = 0; column != N; ++column)
    {
        float norm = 0.0f;
        for (row = 0; row != N; ++row)
            norm += work[row * N + column] *
                work[row * N + column];
        norm = sqrtf(norm);
        qr_r[column * N + column] = norm;

        for (row = 0; row != N; ++row)
            qr_q[row * N + column] =
                work[row * N + column] / norm;

        for (next = column + 1; next != N; ++next)
        {
            float dot = 0.0f;
            for (row = 0; row != N; ++row)
                dot += qr_q[row * N + column] *
                    work[row * N + next];
            qr_r[column * N + next] = dot;
            for (row = 0; row != N; ++row)
                work[row * N + next] -=
                    qr_q[row * N + column] * dot;
        }
    }
}

static uint32_t hash_matrix(uint32_t hash, volatile float *matrix)
{
    uint16_t i;
    for (i = 0; i != ELEMENTS; ++i)
    {
        union
        {
            float value;
            uint32_t bits;
        } shape;

        shape.value = matrix[i];
        hash = (hash << 5) | (hash >> 27);
        hash ^= shape.bits + i;
    }
    return hash;
}

BENCH_NOINLINE static uint16_t run_matrix_benchmark(void)
{
    uint32_t hash = UINT32_C(0x13579bdf);

    matrix_multiply();
    lu_decompose();
    cholesky_decompose();
    qr_decompose();

    hash = hash_matrix(hash, product);
    hash = hash_matrix(hash, lu_lower);
    hash = hash_matrix(hash, lu_upper);
    hash = hash_matrix(hash, cholesky_lower);
    hash = hash_matrix(hash, qr_q);
    hash = hash_matrix(hash, qr_r);
    return bench_fold32(hash);
}

int main(void)
{
    bench_finish(run_matrix_benchmark(), UINT16_C(0x9a4f));
}

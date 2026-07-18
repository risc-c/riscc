#ifndef RISCC_MATH_H
#define RISCC_MATH_H

#define HUGE_VAL (__builtin_huge_val())
#define HUGE_VALF (__builtin_huge_valf())
#define HUGE_VALL ((long double)__builtin_huge_val())
#define INFINITY (__builtin_inff())
#define NAN (__builtin_nanf(""))

#define FP_NAN 0
#define FP_INFINITE 1
#define FP_ZERO 2
#define FP_SUBNORMAL 3
#define FP_NORMAL 4

#define MATH_ERRNO 1
#define MATH_ERREXCEPT 2
#define math_errhandling 0

#define FP_ILOGB0 (-32767 - 1)
#define FP_ILOGBNAN 32767

typedef float float_t;
typedef double double_t;

#define fpclassify(value) \
    __builtin_fpclassify(FP_NAN, FP_INFINITE, FP_NORMAL, FP_SUBNORMAL, \
        FP_ZERO, (value))
#define isfinite(value) __builtin_isfinite(value)
#define isinf(value) __builtin_isinf(value)
#define isnan(value) __builtin_isnan(value)
#define isnormal(value) __builtin_isnormal(value)
#define signbit(value) __builtin_signbit(value)

#define isgreater(left, right) __builtin_isgreater((left), (right))
#define isgreaterequal(left, right) __builtin_isgreaterequal((left), (right))
#define isless(left, right) __builtin_isless((left), (right))
#define islessequal(left, right) __builtin_islessequal((left), (right))
#define islessgreater(left, right) __builtin_islessgreater((left), (right))
#define isunordered(left, right) __builtin_isunordered((left), (right))

float fabsf(float value);
double fabs(double value);
long double fabsl(long double value);

float copysignf(float magnitude, float sign);
double copysign(double magnitude, double sign);
long double copysignl(long double magnitude, long double sign);

float truncf(float value);
double trunc(double value);
long double truncl(long double value);

float floorf(float value);
double floor(double value);
long double floorl(long double value);

float ceilf(float value);
double ceil(double value);
long double ceill(long double value);

float roundf(float value);
double round(double value);
long double roundl(long double value);

long lroundf(float value);
long lround(double value);
long lroundl(long double value);

long long llroundf(float value);
long long llround(double value);
long long llroundl(long double value);

float sqrtf(float value);
double sqrt(double value);
long double sqrtl(long double value);

float fmodf(float numerator, float denominator);
double fmod(double numerator, double denominator);
long double fmodl(long double numerator, long double denominator);

float fminf(float left, float right);
double fmin(double left, double right);
long double fminl(long double left, long double right);

float fmaxf(float left, float right);
double fmax(double left, double right);
long double fmaxl(long double left, long double right);

float fdimf(float left, float right);
double fdim(double left, double right);
long double fdiml(long double left, long double right);

float modff(float value, float *integral);
double modf(double value, double *integral);
long double modfl(long double value, long double *integral);

float frexpf(float value, int *exponent);
double frexp(double value, int *exponent);
long double frexpl(long double value, int *exponent);

float ldexpf(float value, int exponent);
double ldexp(double value, int exponent);
long double ldexpl(long double value, int exponent);

float scalbnf(float value, int exponent);
double scalbn(double value, int exponent);
long double scalbnl(long double value, int exponent);

float scalblnf(float value, long exponent);
double scalbln(double value, long exponent);
long double scalblnl(long double value, long exponent);

int ilogbf(float value);
int ilogb(double value);
int ilogbl(long double value);

float logbf(float value);
double logb(double value);
long double logbl(long double value);

float nextafterf(float from, float toward);
double nextafter(double from, double toward);
long double nextafterl(long double from, long double toward);

float nexttowardf(float from, long double toward);
double nexttoward(double from, long double toward);
long double nexttowardl(long double from, long double toward);

float nanf(const char *tag);
double nan(const char *tag);
long double nanl(const char *tag);

#endif

#ifndef RISCC_STDINT_H
#define RISCC_STDINT_H

typedef signed char int8_t;
typedef unsigned char uint8_t;
typedef int int16_t;
typedef unsigned int uint16_t;
typedef long int32_t;
typedef unsigned long uint32_t;
typedef long long int64_t;
typedef unsigned long long uint64_t;

typedef int16_t intptr_t;
typedef uint16_t uintptr_t;
typedef int64_t intmax_t;
typedef uint64_t uintmax_t;

#define INT8_MIN (-128)
#define INT8_MAX 127
#define UINT8_MAX 255u
#define INT16_MIN (-32767 - 1)
#define INT16_MAX 32767
#define UINT16_MAX 65535u
#define INT32_MIN (-2147483647L - 1L)
#define INT32_MAX 2147483647L
#define UINT32_MAX 4294967295UL
#define INT64_MIN (-9223372036854775807LL - 1LL)
#define INT64_MAX 9223372036854775807LL
#define UINT64_MAX 18446744073709551615ULL

#define INT8_C(value) value
#define UINT8_C(value) value##U
#define INT16_C(value) value
#define UINT16_C(value) value##U
#define INT32_C(value) value##L
#define UINT32_C(value) value##UL
#define INT64_C(value) value##LL
#define UINT64_C(value) value##ULL

#define INTPTR_MIN INT16_MIN
#define INTPTR_MAX INT16_MAX
#define UINTPTR_MAX UINT16_MAX
#define SIZE_MAX UINT16_MAX

#endif

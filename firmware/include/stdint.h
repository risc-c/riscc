#ifndef RISCC_STDINT_H
#define RISCC_STDINT_H

/* Follow the target data layout: RC16 has 16-bit int/pointers while RC32 has
 * 32-bit int/pointers.  The compiler-provided exact-width types cover both. */
typedef __INT8_TYPE__ int8_t;
typedef __UINT8_TYPE__ uint8_t;
typedef __INT16_TYPE__ int16_t;
typedef __UINT16_TYPE__ uint16_t;
typedef __INT32_TYPE__ int32_t;
typedef __UINT32_TYPE__ uint32_t;
typedef __INT64_TYPE__ int64_t;
typedef __UINT64_TYPE__ uint64_t;

typedef __INTPTR_TYPE__ intptr_t;
typedef __UINTPTR_TYPE__ uintptr_t;
typedef __INTMAX_TYPE__ intmax_t;
typedef __UINTMAX_TYPE__ uintmax_t;

#define INT8_MIN (-__INT8_MAX__ - 1)
#define INT8_MAX __INT8_MAX__
#define UINT8_MAX __UINT8_MAX__
#define INT16_MIN (-__INT16_MAX__ - 1)
#define INT16_MAX __INT16_MAX__
#define UINT16_MAX __UINT16_MAX__
#define INT32_MIN (-__INT32_MAX__ - 1)
#define INT32_MAX __INT32_MAX__
#define UINT32_MAX __UINT32_MAX__
#define INT64_MIN (-__INT64_MAX__ - 1)
#define INT64_MAX __INT64_MAX__
#define UINT64_MAX __UINT64_MAX__

#define INT8_C(value) __INT8_C(value)
#define UINT8_C(value) __UINT8_C(value)
#define INT16_C(value) __INT16_C(value)
#define UINT16_C(value) __UINT16_C(value)
#define INT32_C(value) __INT32_C(value)
#define UINT32_C(value) __UINT32_C(value)
#define INT64_C(value) __INT64_C(value)
#define UINT64_C(value) __UINT64_C(value)

#define INTPTR_MIN (-__INTPTR_MAX__ - 1)
#define INTPTR_MAX __INTPTR_MAX__
#define UINTPTR_MAX __UINTPTR_MAX__
#define SIZE_MAX __SIZE_MAX__

#endif

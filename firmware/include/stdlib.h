#ifndef RISCC_STDLIB_H
#define RISCC_STDLIB_H

#include <stddef.h>

#define EXIT_SUCCESS 0
#define EXIT_FAILURE 1
#define RAND_MAX 32767

typedef struct
{
    int quot;
    int rem;
} div_t;

typedef struct
{
    long quot;
    long rem;
} ldiv_t;

void abort(void) __attribute__((noreturn));
int abs(int value);
long labs(long value);
div_t div(int numer, int denom);
ldiv_t ldiv(long numer, long denom);
void exit(int status) __attribute__((noreturn));
void _Exit(int status) __attribute__((noreturn));
long atol(const char *nptr);
int atoi(const char *nptr);
long strtol(const char *restrict nptr, char **restrict endptr, int base);
unsigned long strtoul(const char *restrict nptr, char **restrict endptr,
                     int base);
int rand(void);
void srand(unsigned int seed);
void *bsearch(const void *key, const void *base, size_t nmemb, size_t size,
              int (*compar)(const void *, const void *));
void qsort(void *base, size_t nmemb, size_t size,
           int (*compar)(const void *, const void *));
void *malloc(size_t size);
void free(void *ptr);
void *calloc(size_t nmemb, size_t size);
void *realloc(void *ptr, size_t size);

#endif

#ifndef RISCC_STDIO_H
#define RISCC_STDIO_H

#include <stdarg.h>
#include <stddef.h>

#ifdef __cplusplus
#define RISCC_RESTRICT __restrict
extern "C"
{
#else
#define RISCC_RESTRICT restrict
#endif

typedef struct riscc_FILE FILE;

#define EOF (-1)

extern FILE *const stdin;
extern FILE *const stdout;
extern FILE *const stderr;

int getchar(void);
int putchar(int character);
int puts(const char *string);
int fgetc(FILE *stream);
int fputc(int character, FILE *stream);
char *fgets(char *RISCC_RESTRICT string, int count,
            FILE *RISCC_RESTRICT stream);
int fputs(const char *RISCC_RESTRICT string, FILE *RISCC_RESTRICT stream);

int printf(const char *RISCC_RESTRICT format, ...);
int fprintf(FILE *RISCC_RESTRICT stream, const char *RISCC_RESTRICT format,
            ...);
int sprintf(char *RISCC_RESTRICT string, const char *RISCC_RESTRICT format,
            ...);
int snprintf(char *RISCC_RESTRICT string, size_t count,
             const char *RISCC_RESTRICT format, ...);
int vprintf(const char *RISCC_RESTRICT format, va_list arguments);
int vfprintf(FILE *RISCC_RESTRICT stream, const char *RISCC_RESTRICT format,
             va_list arguments);
int vsprintf(char *RISCC_RESTRICT string,
             const char *RISCC_RESTRICT format,
             va_list arguments);
int vsnprintf(char *RISCC_RESTRICT string, size_t count,
              const char *RISCC_RESTRICT format, va_list arguments);

#ifdef __cplusplus
}
#endif

#undef RISCC_RESTRICT

#endif

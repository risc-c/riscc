#ifndef RISCC_STDIO_H
#define RISCC_STDIO_H

/*
 * Minimal freestanding stdio subset.  The current runtime implements these
 * functions on the RISC-C top-page UART; it does not provide FILE, EOF,
 * formatted I/O, or any other hosted stdio interface.
 */

#ifdef __cplusplus
extern "C" {
#endif

int getchar(void);
int putchar(int character);
int puts(const char *string);

#ifdef __cplusplus
}
#endif

#endif

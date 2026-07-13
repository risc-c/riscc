#include <stdlib.h>

static void halt(void) __attribute__((noreturn));

static void halt(void)
{
    for (;;)
        ;
}

void abort(void)
{
    halt();
}

void exit(int status)
{
    (void)status;
    halt();
}

void _Exit(int status)
{
    (void)status;
    halt();
}

/* Generic unbuffered streams backed by the selected RISC-C BSP console. */

#include <stdio.h>

struct riscc_FILE
{
    int (*put)(int character);
    int (*get)(void);
};

static struct riscc_FILE input_stream = {0, getchar};
static struct riscc_FILE output_stream = {putchar, 0};

FILE *const stdin = &input_stream;
FILE *const stdout = &output_stream;
FILE *const stderr = &output_stream;

int fputc(int character, FILE *stream)
{
    return stream->put(character);
}

int fgetc(FILE *stream)
{
    return stream->get();
}

int fputs(const char *string, FILE *stream)
{
    while (*string)
        fputc((unsigned char)*string++, stream);
    return 0;
}

char *fgets(char *string, int count, FILE *stream)
{
    int index = 0;

    if (count <= 0)
        return (char *)0;
    if (count == 1)
    {
        string[0] = '\0';
        return string;
    }
    while (index + 1 < count)
    {
        int character = fgetc(stream);
        string[index++] = (char)character;
        if (character == '\n')
            break;
    }
    string[index] = '\0';
    return string;
}

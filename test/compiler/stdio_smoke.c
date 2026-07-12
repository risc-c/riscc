#include <stdio.h>

#define RESULT_WORD (*(volatile unsigned short *)0xfffeu)

static void finish(unsigned short result)
{
  RESULT_WORD = result;
  for (;;)
    ;
}

int main(void)
{
  int value = getchar();

  if (value != 'Q')
    finish(0x0b21u);
  if (putchar(value) != 'Q')
    finish(0x0b22u);
  if (puts("") != 0)
    finish(0x0b23u);
  return 0;
}

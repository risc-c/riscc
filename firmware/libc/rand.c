#include <stdlib.h>

static unsigned int rand_state = 1;

int rand(void)
{
    rand_state = rand_state * 25173u + 13849u;
    return (int)(rand_state & RAND_MAX);
}

void srand(unsigned int seed)
{
    rand_state = seed;
}

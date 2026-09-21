#include "bench.h"

enum { NODES = 1024, ROUNDS = 16 };

struct node
{
    uint32_t next;
    uint32_t visits;
};

// Indices keep the 8 KiB layout identical on RC16 and RC32.
static volatile struct node nodes[NODES] __attribute__((aligned(32)));

BENCH_NOINLINE static uint32_t walk_nodes(void)
{
    uint32_t index = 0;
    for (unsigned left = NODES * ROUNDS; left != 0; left -= 4)
    {
        index = nodes[index].next;
        nodes[index].visits += 1;
        index = nodes[index].next;
        nodes[index].visits += 1;
        index = nodes[index].next;
        nodes[index].visits += 1;
        index = nodes[index].next;
        nodes[index].visits += 1;
    }
    return index;
}

int main(void)
{
    for (unsigned i = 0; i != NODES; ++i)
    {
        // This permutation forms one cycle through all 1024 nodes.
        nodes[i].next = (65u * (uint32_t)i + 17u) & (NODES - 1u);
        nodes[i].visits = 0;
    }
    if (walk_nodes() != 0)
        bench_finish(UINT16_C(0x0b03), 0);
    for (unsigned i = 0; i != NODES; ++i)
        if (nodes[i].visits != ROUNDS ||
            nodes[i].next != ((65u * (uint32_t)i + 17u) & (NODES - 1u)))
            bench_finish(UINT16_C(0x0b04), 0);
    bench_finish(0, 0);
}

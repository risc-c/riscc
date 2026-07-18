#include "bench.h"

#define NODE_COUNT 12
#define GRAPH_NODES 8
#define NO_EDGE UINT16_C(0xffff)

struct list_node
{
    uint16_t value;
    struct list_node *next;
};

struct tree_node
{
    uint16_t key;
    struct tree_node *left;
    struct tree_node *right;
};

static struct list_node list_nodes[NODE_COUNT];
static struct tree_node tree_nodes[NODE_COUNT];

static const uint16_t graph[GRAPH_NODES][GRAPH_NODES] =
{
    {0, 4, 2, NO_EDGE, NO_EDGE, NO_EDGE, NO_EDGE, NO_EDGE},
    {4, 0, 1, 5, NO_EDGE, NO_EDGE, NO_EDGE, NO_EDGE},
    {2, 1, 0, 8, 10, NO_EDGE, NO_EDGE, NO_EDGE},
    {NO_EDGE, 5, 8, 0, 2, 6, NO_EDGE, NO_EDGE},
    {NO_EDGE, NO_EDGE, 10, 2, 0, 3, 7, NO_EDGE},
    {NO_EDGE, NO_EDGE, NO_EDGE, 6, 3, 0, 1, 4},
    {NO_EDGE, NO_EDGE, NO_EDGE, NO_EDGE, 7, 1, 0, 2},
    {NO_EDGE, NO_EDGE, NO_EDGE, NO_EDGE, NO_EDGE, 4, 2, 0},
};

BENCH_NOINLINE static void initialize_nodes(void)
{
    static const uint16_t order[NODE_COUNT] =
        {0, 7, 3, 10, 1, 8, 5, 11, 2, 9, 4, 6};
    uint16_t index;

    for (index = 0; index != NODE_COUNT; ++index)
    {
        uint16_t node = order[index];
        list_nodes[node].value = (uint16_t)(node * 13 + 5);
        list_nodes[node].next = index + 1 == NODE_COUNT ?
            (struct list_node *)0 : &list_nodes[order[index + 1]];

        tree_nodes[index].key = (uint16_t)(index * 11 + 3);
        tree_nodes[index].left = (struct tree_node *)0;
        tree_nodes[index].right = (struct tree_node *)0;
    }

    tree_nodes[5].left = &tree_nodes[2];
    tree_nodes[5].right = &tree_nodes[9];
    tree_nodes[2].left = &tree_nodes[0];
    tree_nodes[2].right = &tree_nodes[4];
    tree_nodes[0].right = &tree_nodes[1];
    tree_nodes[4].left = &tree_nodes[3];
    tree_nodes[9].left = &tree_nodes[7];
    tree_nodes[9].right = &tree_nodes[11];
    tree_nodes[7].left = &tree_nodes[6];
    tree_nodes[7].right = &tree_nodes[8];
    tree_nodes[11].left = &tree_nodes[10];
}

BENCH_NOINLINE static uint16_t walk_list(void)
{
    struct list_node *node = &list_nodes[0];
    uint16_t sum = 0;
    uint16_t alternating = 0;
    uint16_t mixed = 1;
    uint16_t count = 0;

    while (node)
    {
        sum = (uint16_t)(sum + node->value);
        alternating = (uint16_t)(alternating ^
            (uint16_t)(node->value << (count & 3)));
        mixed = (uint16_t)(mixed + (node->value ^ count));
        ++count;
        node = node->next;
    }
    return (uint16_t)(sum ^ alternating ^ mixed ^ count);
}

BENCH_NOINLINE static uint16_t walk_tree(void)
{
    struct tree_node *stack[NODE_COUNT];
    struct tree_node *node = &tree_nodes[5];
    uint16_t depth = 0;
    uint16_t sum = 0;
    uint16_t ordered = 0;
    uint16_t count = 0;

    while (node || depth)
    {
        while (node)
        {
            stack[depth++] = node;
            node = node->left;
        }
        node = stack[--depth];
        sum = (uint16_t)(sum + node->key);
        ordered = (uint16_t)((ordered << 1) ^ node->key ^ count);
        ++count;
        node = node->right;
    }
    return (uint16_t)(sum ^ ordered ^ count);
}

BENCH_NOINLINE static uint16_t shortest_paths(void)
{
    uint16_t distance[GRAPH_NODES];
    uint16_t visited = 0;
    uint16_t step;
    uint16_t node;
    uint16_t checksum = 0;

    for (node = 0; node != GRAPH_NODES; ++node)
        distance[node] = NO_EDGE;
    distance[0] = 0;

    for (step = 0; step != GRAPH_NODES; ++step)
    {
        uint16_t best = NO_EDGE;
        uint16_t current = 0;

        for (node = 0; node != GRAPH_NODES; ++node)
            if (!(visited & (uint16_t)(1u << node)) &&
                distance[node] < best)
            {
                best = distance[node];
                current = node;
            }

        visited = (uint16_t)(visited | (uint16_t)(1u << current));
        for (node = 0; node != GRAPH_NODES; ++node)
            if (graph[current][node] != NO_EDGE &&
                (uint16_t)(best + graph[current][node]) < distance[node])
                distance[node] =
                    (uint16_t)(best + graph[current][node]);
    }

    for (node = 0; node != GRAPH_NODES; ++node)
        checksum = (uint16_t)((checksum << 2) ^ distance[node] ^ node);
    return checksum;
}

int main(void)
{
    uint16_t result;

    initialize_nodes();
    result = (uint16_t)(walk_list() ^ walk_tree() ^ shortest_paths());
    bench_finish(result, UINT16_C(0x087b));
}

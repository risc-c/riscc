#ifndef RISCC_COMPILER_POINTER_ROTATION_H
#define RISCC_COMPILER_POINTER_ROTATION_H

struct rotation_node {
    struct rotation_node *next;
    u16 value;
};

static struct rotation_node rotation_nodes[10];

static __attribute__((noinline)) struct rotation_node *
rotate_reverse(struct rotation_node *head)
{
    struct rotation_node *previous = 0;
    while (head) {
        struct rotation_node *next = head->next;
        head->next = previous;
        previous = head;
        head = next;
    }
    return previous;
}

/* Keep the two updates in one loop body, but leave an exit after either
 * half.  This is deliberately written out instead of relying on an
 * unroller so the two pointer-update paths remain visible to codegen tests. */
static __attribute__((noinline)) struct rotation_node *
rotate_reverse_unrolled(struct rotation_node *head)
{
    struct rotation_node *previous = 0;
    while (head) {
        struct rotation_node *next = head->next;
        head->next = previous;
        previous = head;
        head = next;
        if (!head)
            break;

        next = head->next;
        head->next = previous;
        previous = head;
        head = next;
    }
    return previous;
}

static unsigned test_pointer_rotation_unrolled(void);

static unsigned test_pointer_rotation(void)
{
    /* Include empty, single-node, odd and even lengths. Check each address
     * before dereferencing it, and reverse again to verify the exit value. */
    for (u16 count = 0; count <= 10; ++count) {
        for (u16 i = 0; i < count; ++i) {
            rotation_nodes[i].next = i + 1 < count ? &rotation_nodes[i + 1] : 0;
            rotation_nodes[i].value = i;
        }
        struct rotation_node *head = count ? rotation_nodes : 0;
        struct rotation_node *reversed = rotate_reverse(head);
        struct rotation_node *p = reversed;
        for (u16 i = count; i != 0; --i) {
            if (p != &rotation_nodes[i - 1] || p->value != i - 1)
                return 1;
            p = p->next;
        }
        if (p)
            return 2;
        p = rotate_reverse(reversed);
        for (u16 i = 0; i < count; ++i) {
            if (p != &rotation_nodes[i] || p->value != i)
                return 3;
            p = p->next;
        }
        if (p)
            return 4;
    }
    return test_pointer_rotation_unrolled();
}

static unsigned test_pointer_rotation_unrolled(void)
{
    /* Exercise zero, singleton, odd and even lengths through both exits of
     * the two-way body.  Check values and addresses in both directions. */
    for (u16 count = 0; count <= 10; ++count) {
        for (u16 i = 0; i < count; ++i) {
            rotation_nodes[i].next = i + 1 < count ? &rotation_nodes[i + 1] : 0;
            rotation_nodes[i].value = i;
        }
        struct rotation_node *head = count ? rotation_nodes : 0;
        struct rotation_node *reversed = rotate_reverse_unrolled(head);
        struct rotation_node *p = reversed;
        for (u16 i = count; i != 0; --i) {
            if (p != &rotation_nodes[i - 1] || p->value != i - 1)
                return 5;
            p = p->next;
        }
        if (p)
            return 6;
        p = rotate_reverse_unrolled(reversed);
        for (u16 i = 0; i < count; ++i) {
            if (p != &rotation_nodes[i] || p->value != i)
                return 7;
            p = p->next;
        }
        if (p)
            return 8;
    }
    return 0;
}

#endif

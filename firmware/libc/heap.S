        .section .text.__riscc_heap_limit,"ax",@progbits
        .p2align 1
        .weak __riscc_heap_limit
        .type __riscc_heap_limit,@function
__riscc_heap_limit:
        MOV r1, r7
#ifdef __RISCC_NANO__
        JMP r6
#else
        RET     S7
#endif
        .size __riscc_heap_limit, .-__riscc_heap_limit

        .section .text.__riscc_heap_limit,"ax",@progbits
        .p2align 1
        .weak __riscc_heap_limit
        .type __riscc_heap_limit,@function
__riscc_heap_limit:
        MOV r1, r7
#ifdef __RISCC_NANO__
        JAL r0, r6
#else
        RETS
#endif
        .size __riscc_heap_limit, .-__riscc_heap_limit

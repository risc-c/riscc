#include "riscc_compiler_features.h"

#define OFFSETOF(type, member) __builtin_offsetof(type, member)

void *memcpy(void *, const void *, usize);
void *memmove(void *, const void *, usize);
void *memset(void *, int, usize);

struct memory_layout
{
    u8 head;
    u16 word;
    u8 tail;
};

struct memory_bits
{
    unsigned first : 3;
    unsigned second : 5;
    unsigned third : 8;
};

union memory_union
{
    u16 word;
    u8 byte[2];
};

static volatile u16 memory_data_word = 0x1357u;
static volatile u16 memory_bss_word;
static const u8 memory_rodata[] = {3, 1, 4, 1, 5, 9};
static volatile u16 *memory_data_pointer = &memory_data_word;
static __thread volatile u16 memory_tls_data = 0x2468u;
static _Thread_local volatile u8 memory_tls_bss;

u16 feature_test_memory(void)
{
    struct memory_layout first = {.tail = 0x56, .head = 0x12, .word = 0x3456};
    struct memory_layout second;
    volatile struct memory_bits bits = {5, 17, 0xa5};
    volatile union memory_union endian;
    u8 bytes[8];
    u16 words[4];
    const char *text = "RISC-C";
    volatile u16 *tls_data_pointer = &memory_tls_data;
    volatile u8 *tls_bss_pointer = &memory_tls_bss;
    u16 i;

    _Static_assert(sizeof(struct memory_layout) == 6, "struct tail padding");
    _Static_assert(_Alignof(struct memory_layout) == 2, "struct alignment");
    _Static_assert(OFFSETOF(struct memory_layout, head) == 0, "byte member");
    _Static_assert(OFFSETOF(struct memory_layout, word) == 2, "word member");
    _Static_assert(OFFSETOF(struct memory_layout, tail) == 4, "tail member");
    _Static_assert(sizeof(struct memory_bits) == 2, "16-bit bit-fields");
    _Static_assert(sizeof(union memory_union) == 2, "union size");

    if (memory_data_word != 0x1357u || memory_bss_word != 0 ||
        *memory_data_pointer != 0x1357u)
        return 1;
    if (memory_rodata[0] != 3 || memory_rodata[5] != 9)
        return 2;

    memory_bss_word = 0xa55au;
    *memory_data_pointer = 0x7531u;
    if (memory_bss_word != 0xa55au || memory_data_word != 0x7531u)
        return 3;

    if (memory_tls_data != 0x2468u || memory_tls_bss != 0)
        return 4;
    *tls_data_pointer = (u16)(*tls_data_pointer + 0x1111u);
    *tls_bss_pointer = 0x5au;
    if (memory_tls_data != 0x3579u || memory_tls_bss != 0x5au)
        return 5;

    second = first;
    if (second.head != 0x12 || second.word != 0x3456 || second.tail != 0x56)
        return 6;
    if (bits.first != 5 || bits.second != 17 || bits.third != 0xa5)
        return 7;
    bits.second = 3;
    if (bits.first != 5 || bits.second != 3 || bits.third != 0xa5)
        return 8;

    endian.word = 0x1234u;
    if (endian.byte[0] != 0x34u || endian.byte[1] != 0x12u)
        return 9;
    endian.byte[0] = 0x78u;
    if (endian.word != 0x1278u)
        return 10;

    for (i = 0; i != 4; ++i)
        words[i] = (u16)(i * i + 1);
    if (words[0] != 1 || words[1] != 2 || words[2] != 5 || words[3] != 10 ||
        &words[3] - &words[0] != 3)
        return 11;

    if (memset(bytes, 0xa5, sizeof(bytes)) != bytes)
        return 12;
    for (i = 0; i != sizeof(bytes); ++i)
        if (bytes[i] != 0xa5u)
        return 13;
    if (memcpy(bytes, memory_rodata, sizeof(memory_rodata)) != bytes ||
        bytes[0] != 3 || bytes[5] != 9)
        return 14;
    if (memcpy(bytes, memory_rodata, 0) != bytes)
        return 15;
    if (memmove(bytes + 1, bytes, 0) != bytes + 1 ||
        memset(bytes, 0, 0) != bytes)
        return 16;

    for (i = 0; i != sizeof(bytes); ++i)
        bytes[i] = (u8)i;
    if (memmove(bytes + 2, bytes, 6) != bytes + 2 ||
        bytes[0] != 0 || bytes[1] != 1 || bytes[2] != 0 || bytes[3] != 1 ||
        bytes[4] != 2 || bytes[5] != 3 || bytes[6] != 4 || bytes[7] != 5)
        return 17;
    if (memmove(bytes, bytes + 2, 6) != bytes ||
        bytes[0] != 0 || bytes[1] != 1 || bytes[2] != 2 || bytes[3] != 3 ||
        bytes[4] != 4 || bytes[5] != 5 || bytes[6] != 4 || bytes[7] != 5)
        return 18;

    if (text[0] != 'R' || text[4] != '-' || text[5] != 'C' || text[6] != '\0')
        return 19;

    return 0;
}

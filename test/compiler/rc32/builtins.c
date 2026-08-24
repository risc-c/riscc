#include "test.h"

u32 __mulsi3(u32, u32);
s32 __ashlsi3(s32, int);
u32 __lshrsi3(u32, int);
s32 __ashrsi3(s32, int);
u32 __udivsi3(u32, u32);
u32 __umodsi3(u32, u32);
u32 __udivmodsi4(u32, u32, u32 *);
s32 __divsi3(s32, s32);
s32 __modsi3(s32, s32);
s32 __divmodsi4(s32, s32, s32 *);

s64 __muldi3(s64, s64);
s64 __ashldi3(s64, int);
u64 __lshrdi3(u64, int);
s64 __ashrdi3(s64, int);
u64 __udivdi3(u64, u64);
u64 __umoddi3(u64, u64);
u64 __udivmoddi4(u64, u64, u64 *);
s64 __divdi3(s64, s64);
s64 __moddi3(s64, s64);
s64 __divmoddi4(s64, s64, s64 *);
s64 __negdi2(s64);
int __ucmpdi2(u64, u64);
int __cmpdi2(s64, s64);
int __clzsi2(u32);
int __ctzsi2(u32);
int __clzdi2(s64);
int __ctzdi2(s64);

static volatile u32 value32 = 0x12345678u;
static volatile s32 signed32 = -100000;
static volatile u64 value64 = 0x123456789abcdef0ull;
static volatile s64 signed64 = -100000ll;
static volatile u32 shift32 = 0x80010001u;
static volatile u64 shift64 = 0x8001000200040001ull;

u16 rc32_test_builtins(void)
{
    u32 remainder32;
    s32 signed_remainder32;
    u64 remainder64;
    s64 signed_remainder64;
    u32 u32_value = value32;
    s32 s32_value = signed32;
    u64 u64_value = value64;
    s64 s64_value = signed64;
    u32 u32_shift = shift32;
    u64 u64_shift = shift64;

    if (__mulsi3(u32_value, 37) != 0xa1907f58u ||
        __mulsi3(0xffffffffu, 0xffffffffu) != 1 ||
        __mulsi3(0x00010001u, 0x00010001u) != 0x00020001u ||
        __mulsi3(0x89abcdefu, 0x76543210u) != 0xe5618cf0u ||
        __mulsi3(0xffff0001u, 0x0001ffffu) != 0x0002ffffu)
        return 1;

    if ((u32)__ashlsi3((s32)u32_shift, 0) != 0x80010001u ||
        (u32)__ashlsi3((s32)u32_shift, 1) != 0x00020002u ||
        (u32)__ashlsi3((s32)u32_shift, 16) != 0x00010000u ||
        (u32)__ashlsi3((s32)u32_shift, 31) != 0x80000000u ||
        __lshrsi3(u32_shift, 1) != 0x40008000u ||
        __lshrsi3(u32_shift, 16) != 0x00008001u ||
        __lshrsi3(u32_shift, 31) != 1 ||
        (u32)__ashrsi3((s32)u32_shift, 1) != 0xc0008000u ||
        (u32)__ashrsi3((s32)u32_shift, 16) != 0xffff8001u ||
        (u32)__ashrsi3((s32)u32_shift, 31) != 0xffffffffu)
        return 2;

    if (__udivsi3(u32_value, 12345) != 0x60a4u ||
        __umodsi3(u32_value, 12345) != 0x11f4u ||
        __udivsi3(0xffffffffu, 0x80000001u) != 1 ||
        __umodsi3(0xffffffffu, 0x80000001u) != 0x7ffffffeu ||
        __udivsi3(0x80000000u, 0xffffffffu) != 0 ||
        __umodsi3(0x80000000u, 0xffffffffu) != 0x80000000u ||
        __udivsi3(0xffffffffu, 1) != 0xffffffffu ||
        __umodsi3(0xffffffffu, 1) != 0 ||
        __udivsi3(u32_value, 0) != 0 ||
        __umodsi3(u32_value, 0) != u32_value ||
        __udivmodsi4(u32_value, 12345, &remainder32) != 0x60a4u ||
        remainder32 != 0x11f4u ||
        __udivmodsi4(u32_value, 12345, (u32 *)0) != 0x60a4u)
        return 3;

    if (__divsi3(s32_value, 300) != -333 ||
        __modsi3(s32_value, 300) != -100 ||
        __divmodsi4(s32_value, 300, &signed_remainder32) != -333 ||
        signed_remainder32 != -100 ||
        __divsi3(100000, -300) != -333 ||
        __modsi3(100000, -300) != 100 ||
        __divsi3(-100000, -300) != 333 ||
        __modsi3(-100000, -300) != -100 ||
        __divsi3(-5, 300) != 0 || __modsi3(-5, 300) != -5 ||
        __divsi3(s32_value, 0) != 0 ||
        __modsi3(s32_value, 0) != s32_value ||
        __divmodsi4(s32_value, 300, (s32 *)0) != -333)
        return 4;

    if ((u64)__muldi3((s64)u64_value, 3) != 0x369d0369d0369cd0ull ||
        (u64)__ashldi3((s64)u64_shift, 0) != 0x8001000200040001ull ||
        (u64)__ashldi3((s64)u64_shift, 1) != 0x0002000400080002ull ||
        (u64)__ashldi3((s64)u64_shift, 16) != 0x0002000400010000ull ||
        (u64)__ashldi3((s64)u64_shift, 63) != 0x8000000000000000ull ||
        __lshrdi3(u64_shift, 1) != 0x4000800100020000ull ||
        __lshrdi3(u64_shift, 16) != 0x0000800100020004ull ||
        __lshrdi3(u64_shift, 63) != 1 ||
        (u64)__ashrdi3((s64)u64_shift, 1) != 0xc000800100020000ull ||
        (u64)__ashrdi3((s64)u64_shift, 16) != 0xffff800100020004ull ||
        (u64)__ashrdi3((s64)u64_shift, 63) != 0xffffffffffffffffull)
        return 5;

    if (__udivdi3(u64_value, 65537) != 0x0000123444445678ull ||
        __umoddi3(u64_value, 65537) != 0x8878ull ||
        __udivdi3(0xffffffffffffffffull, 0x8000000000000001ull) != 1 ||
        __umoddi3(0xffffffffffffffffull, 0x8000000000000001ull) !=
            0x7ffffffffffffffeull ||
        __udivdi3(0x8000000000000000ull, 0xffffffffffffffffull) != 0 ||
        __umoddi3(0x8000000000000000ull, 0xffffffffffffffffull) !=
            0x8000000000000000ull ||
        __udivdi3(0xffffffffffffffffull, 1) != 0xffffffffffffffffull ||
        __umoddi3(0xffffffffffffffffull, 1) != 0 ||
        __udivdi3(u64_value, 0) != 0 ||
        __umoddi3(u64_value, 0) != u64_value ||
        __udivmoddi4(u64_value, 65537, &remainder64) !=
            0x0000123444445678ull ||
        remainder64 != 0x8878ull ||
        __udivmoddi4(u64_value, 65537, (u64 *)0) !=
            0x0000123444445678ull)
        return 6;

    if (__divdi3(s64_value, 300) != -333ll ||
        __moddi3(s64_value, 300) != -100ll ||
        __divmoddi4(s64_value, 300, &signed_remainder64) != -333ll ||
        signed_remainder64 != -100ll ||
        __divdi3(100000ll, -300) != -333ll ||
        __moddi3(100000ll, -300) != 100ll ||
        __divdi3(-100000ll, -300) != 333ll ||
        __moddi3(-100000ll, -300) != -100ll ||
        __negdi2(s64_value) != 100000ll)
        return 7;

    if (__ucmpdi2(1, 2) != 0 || __ucmpdi2(2, 2) != 1 ||
        __ucmpdi2(3, 2) != 2 || __cmpdi2(-2, 1) != 0 ||
        __cmpdi2(-2, -2) != 1 || __cmpdi2(1, -2) != 2 ||
        __clzsi2(0) != 32 || __clzsi2(1) != 31 ||
        __clzsi2(0x80000000u) != 0 || __ctzsi2(0) != 32 ||
        __ctzsi2(0x80000000u) != 31 || __clzdi2(1) != 63 ||
        __clzdi2((s64)0x8000000000000000ull) != 0 ||
        __ctzdi2(0) != 64 || __ctzdi2((s64)0x8000000000000000ull) != 63)
        return 8;

    return 0;
}

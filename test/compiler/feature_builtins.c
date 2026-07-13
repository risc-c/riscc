#include "riscc_compiler_features.h"

u16 __udivhi3(u16, u16);
u16 __umodhi3(u16, u16);
u16 __udivmodhi4(u16, u16, u16 *);
s16 __divhi3(s16, s16);
s16 __modhi3(s16, s16);
s16 __divmodhi4(s16, s16, s16 *);

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
s32 __negsi2(s32);

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

static volatile u16 builtin_u16 = 1000;
static volatile s16 builtin_s16 = -1000;
static volatile u32 builtin_u32 = 0x12345678ul;
static volatile s32 builtin_s32 = -100000l;
static volatile u64 builtin_u64 = 0x123456789abcdef0ull;
static volatile s64 builtin_s64 = -100000ll;

u16 feature_test_builtins(void)
{
    u16 remainder16;
    s16 signed_remainder16;
    u32 remainder32;
    s32 signed_remainder32;
    u64 remainder64;
    s64 signed_remainder64;
    u16 value16 = builtin_u16;
    s16 signed16 = builtin_s16;
    u32 value32 = builtin_u32;
    s32 signed32 = builtin_s32;
    u64 value64 = builtin_u64;
    s64 signed64 = builtin_s64;

    if (__udivhi3(value16, 37) != 27 || __umodhi3(value16, 37) != 1 ||
        __udivmodhi4(value16, 37, &remainder16) != 27 || remainder16 != 1)
        return 1;
    if (__divhi3(signed16, 37) != -27 || __modhi3(signed16, 37) != -1 ||
        __divmodhi4(signed16, 37, &signed_remainder16) != -27 ||
        signed_remainder16 != -1)
        return 2;

    if (__mulsi3(value32, 37) != 0xa1907f58ul ||
        (u32)__ashlsi3((s32)value32, 4) != 0x23456780ul ||
        __lshrsi3(value32, 4) != 0x01234567ul ||
        (u32)__ashrsi3((s32)0x87654321ul, 4) != 0xf8765432ul)
        return 3;
    if (__udivsi3(value32, 12345) != 0x60a4ul ||
        __umodsi3(value32, 12345) != 0x11f4ul ||
        __udivmodsi4(value32, 12345, &remainder32) != 0x60a4ul ||
        remainder32 != 0x11f4ul)
        return 4;
    if (__divsi3(signed32, 300) != -333l ||
        __modsi3(signed32, 300) != -100l ||
        __divmodsi4(signed32, 300, &signed_remainder32) != -333l ||
        signed_remainder32 != -100l || __negsi2(signed32) != 100000l)
        return 5;

    if ((u64)__muldi3((s64)value64, 3) != 0x369d0369d0369cd0ull ||
        (u64)__ashldi3((s64)0x0000000100000001ull, 4) !=
            0x0000001000000010ull ||
        __lshrdi3(0x8000000000000001ull, 4) != 0x0800000000000000ull ||
        __ashrdi3(-0x100000000ll, 4) != -0x10000000ll)
        return 6;
    if (__udivdi3(value64, 65537) != 0x0000123444445678ull ||
        __umoddi3(value64, 65537) != 0x8878ull ||
        __udivmoddi4(value64, 65537, &remainder64) !=
            0x0000123444445678ull ||
        remainder64 != 0x8878ull)
        return 7;
    if (__divdi3(signed64, 300) != -333ll ||
        __moddi3(signed64, 300) != -100ll ||
        __divmoddi4(signed64, 300, &signed_remainder64) != -333ll ||
        signed_remainder64 != -100ll || __negdi2(signed64) != 100000ll)
        return 8;

    if (__ucmpdi2(1, 2) != 0 || __ucmpdi2(2, 2) != 1 ||
        __ucmpdi2(3, 2) != 2 || __cmpdi2(-2, 1) != 0 ||
        __cmpdi2(-2, -2) != 1 || __cmpdi2(1, -2) != 2)
        return 9;

    return 0;
}

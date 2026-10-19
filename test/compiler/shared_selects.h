#ifndef RISCC_COMPILER_SHARED_SELECTS_H
#define RISCC_COMPILER_SHARED_SELECTS_H

/* Use C int types here deliberately: they are the native-width integer types
 * for each compiler target, unlike the explicitly wider u32 test type on
 * RC16.  Volatile arm loads keep the distinct values live at runtime. */
typedef unsigned int shared_select_uint;
typedef signed int shared_select_sint;

static volatile shared_select_uint shared_select_unsigned_arms[] = {
    3u, 5u, 7u, 11u, 13u, 17u,
    19u, 23u, 29u, 31u, 37u, 41u,
};
static volatile shared_select_sint shared_select_signed_arms[] = {
    43, 47, 53, 59, 61, 67,
    71, 73, 79, 83, 89, 97,
};
static volatile shared_select_uint shared_select_memory;

static volatile shared_select_uint shared_select_unsigned_zero = 0u;
static volatile shared_select_uint shared_select_unsigned_one = 1u;
static volatile shared_select_uint shared_select_unsigned_max =
    (shared_select_uint)-1;
static volatile shared_select_sint shared_select_signed_min =
    -((shared_select_sint)(((shared_select_uint)-1) >> 1)) - 1;
static volatile shared_select_sint shared_select_signed_neg = -1;
static volatile shared_select_sint shared_select_signed_zero = 0;
static volatile shared_select_sint shared_select_signed_one = 1;
static volatile shared_select_sint shared_select_signed_max =
    (shared_select_sint)(((shared_select_uint)-1) >> 1);

/* Three equal unsigned selects have identical comparison operands and live
 * out as separate values in the final sum. */
static __attribute__((noinline)) shared_select_uint
shared_select_unsigned_equal(shared_select_uint value)
{
    shared_select_uint t0 = shared_select_unsigned_arms[0];
    shared_select_uint f0 = shared_select_unsigned_arms[1];
    shared_select_uint t1 = shared_select_unsigned_arms[2];
    shared_select_uint f1 = shared_select_unsigned_arms[3];
    shared_select_uint t2 = shared_select_unsigned_arms[4];
    shared_select_uint f2 = shared_select_unsigned_arms[5];
    shared_select_uint a = value == 0u ? t0 : f0;
    shared_select_uint b = value == 0u ? t1 : f1;
    shared_select_uint c = value == 0u ? t2 : f2;
    return a + b + c;
}

static __attribute__((noinline)) shared_select_uint
shared_select_unsigned_relational(shared_select_uint value)
{
    shared_select_uint t0 = shared_select_unsigned_arms[6];
    shared_select_uint f0 = shared_select_unsigned_arms[7];
    shared_select_uint t1 = shared_select_unsigned_arms[8];
    shared_select_uint f1 = shared_select_unsigned_arms[9];
    shared_select_uint t2 = shared_select_unsigned_arms[10];
    shared_select_uint f2 = shared_select_unsigned_arms[11];
    shared_select_uint a = value < 1u ? t0 : f0;
    shared_select_uint b = value < 1u ? t1 : f1;
    shared_select_uint c = value < 1u ? t2 : f2;
    return a + b + c;
}

static __attribute__((noinline)) shared_select_sint
shared_select_signed_equal(shared_select_sint value)
{
    shared_select_sint t0 = shared_select_signed_arms[0];
    shared_select_sint f0 = shared_select_signed_arms[1];
    shared_select_sint t1 = shared_select_signed_arms[2];
    shared_select_sint f1 = shared_select_signed_arms[3];
    shared_select_sint t2 = shared_select_signed_arms[4];
    shared_select_sint f2 = shared_select_signed_arms[5];
    shared_select_sint a = value == 0 ? t0 : f0;
    shared_select_sint b = value == 0 ? t1 : f1;
    shared_select_sint c = value == 0 ? t2 : f2;
    return a + b + c;
}

static __attribute__((noinline)) shared_select_sint
shared_select_signed_relational(shared_select_sint value)
{
    shared_select_sint t0 = shared_select_signed_arms[6];
    shared_select_sint f0 = shared_select_signed_arms[7];
    shared_select_sint t1 = shared_select_signed_arms[8];
    shared_select_sint f1 = shared_select_signed_arms[9];
    shared_select_sint t2 = shared_select_signed_arms[10];
    shared_select_sint f2 = shared_select_signed_arms[11];
    shared_select_sint a = value < 0 ? t0 : f0;
    shared_select_sint b = value < 0 ? t1 : f1;
    shared_select_sint c = value < 0 ? t2 : f2;
    return a + b + c;
}

/* The second comparison depends on the first selected result, so these two
 * selects must remain separate even though their arms are otherwise pure. */
static __attribute__((noinline)) shared_select_uint
shared_select_dependent(shared_select_uint value)
{
    shared_select_uint first_true = shared_select_unsigned_arms[0];
    shared_select_uint first_false = shared_select_unsigned_arms[2];
    shared_select_uint second_true = shared_select_unsigned_arms[4];
    shared_select_uint second_false = shared_select_unsigned_arms[6];
    shared_select_uint first = value == 0u ? first_true : first_false;
    shared_select_uint second = first == first_true ? second_true : second_false;
    return first + second;
}

/* A volatile store separates the first selected value from the remaining
 * selects.  The value is read back into the liveout sum to check both arms. */
static __attribute__((noinline)) shared_select_uint
shared_select_memory_intervening(shared_select_uint value)
{
    shared_select_uint t0 = shared_select_unsigned_arms[0];
    shared_select_uint f0 = shared_select_unsigned_arms[2];
    shared_select_uint t1 = shared_select_unsigned_arms[4];
    shared_select_uint f1 = shared_select_unsigned_arms[6];
    shared_select_uint t2 = shared_select_unsigned_arms[8];
    shared_select_uint f2 = shared_select_unsigned_arms[10];
    shared_select_uint first = value < 1u ? t0 : f0;
    shared_select_memory = first;
    shared_select_uint second = value < 1u ? t1 : f1;
    shared_select_uint third = value < 1u ? t2 : f2;
    return first + second + third + shared_select_memory;
}

static unsigned test_shared_selects(void)
{
    if (sizeof(shared_select_uint) != sizeof(shared_select_sint) ||
        (sizeof(shared_select_uint) != sizeof(u16) &&
         sizeof(shared_select_uint) != sizeof(u32)))
        return 1;

    /* Check equal and relational unsigned selects at zero, one, and max. */
    if (shared_select_unsigned_equal(shared_select_unsigned_zero) != 23u ||
        shared_select_unsigned_equal(shared_select_unsigned_one) != 33u ||
        shared_select_unsigned_equal(shared_select_unsigned_max) != 33u)
        return 2;
    if (shared_select_unsigned_relational(shared_select_unsigned_zero) !=
            85u ||
        shared_select_unsigned_relational(shared_select_unsigned_one) !=
            95u ||
        shared_select_unsigned_relational(shared_select_unsigned_max) !=
            95u)
        return 3;

    /* Signed tests cover min, -1, zero, one, and max on both arms. */
    if (shared_select_signed_equal(shared_select_signed_zero) != 157 ||
        shared_select_signed_equal(shared_select_signed_neg) != 173 ||
        shared_select_signed_equal(shared_select_signed_min) != 173 ||
        shared_select_signed_equal(shared_select_signed_max) != 173)
        return 4;
    if (shared_select_signed_relational(shared_select_signed_min) != 239 ||
        shared_select_signed_relational(shared_select_signed_neg) != 239 ||
        shared_select_signed_relational(shared_select_signed_zero) != 253 ||
        shared_select_signed_relational(shared_select_signed_one) != 253 ||
        shared_select_signed_relational(shared_select_signed_max) != 253)
        return 5;

    if (shared_select_dependent(shared_select_unsigned_zero) != 16u ||
        shared_select_dependent(shared_select_unsigned_one) != 26u ||
        shared_select_dependent(shared_select_unsigned_max) != 26u)
        return 6;
    if (shared_select_memory_intervening(shared_select_unsigned_zero) !=
            48u ||
        shared_select_memory_intervening(shared_select_unsigned_one) != 70u ||
        shared_select_memory_intervening(shared_select_unsigned_max) != 70u)
        return 7;
    return 0;
}

#endif

/*
 * Dhrystone 2.1, Reinhold P. Weicker, May 25, 1988.
 * Adapted from https://www.netlib.org/benchmark/dhry-c
 * C11 declarations; original types, records, and procedure boundaries.
 */
#ifndef RISCC_DHRYSTONE_H
#define RISCC_DHRYSTONE_H

#include "bench.h"
#include <string.h>

enum { DHRYSTONE_RUNS = 1000 };

typedef enum { Ident_1, Ident_2, Ident_3, Ident_4, Ident_5 } Enumeration;
typedef int One_Thirty;
typedef int One_Fifty;
typedef char Capital_Letter;
typedef int Boolean;
typedef char Str_30[31];
typedef int Arr_1_Dim[50];
typedef int Arr_2_Dim[50][50];

typedef struct record
{
    struct record *Ptr_Comp;
    Enumeration Discr;
    union
    {
        struct
        {
            Enumeration Enum_Comp;
            int Int_Comp;
            char Str_Comp[31];
        } var_1;
        struct
        {
            Enumeration E_Comp_2;
            char Str_2_Comp[31];
        } var_2;
        struct
        {
            char Ch_1_Comp;
            char Ch_2_Comp;
        } var_3;
    } variant;
} Rec_Type, *Rec_Pointer;

extern int Int_Glob;
extern char Ch_1_Glob;

/* Dhrystone's measurement rules prohibit inlining its procedures. */
BENCH_NOINLINE void Proc_1(Rec_Pointer Ptr_Val_Par);
BENCH_NOINLINE void Proc_2(One_Fifty *Int_Par_Ref);
BENCH_NOINLINE void Proc_3(Rec_Pointer *Ptr_Ref_Par);
BENCH_NOINLINE void Proc_4(void);
BENCH_NOINLINE void Proc_5(void);
BENCH_NOINLINE void Proc_6(Enumeration Enum_Val_Par, Enumeration *Enum_Ref_Par);
BENCH_NOINLINE void Proc_7(One_Fifty Int_1_Par_Val, One_Fifty Int_2_Par_Val,
                         One_Fifty *Int_Par_Ref);
BENCH_NOINLINE void Proc_8(Arr_1_Dim Arr_1_Par_Ref, Arr_2_Dim Arr_2_Par_Ref,
                         int Int_1_Par_Val, int Int_2_Par_Val);
BENCH_NOINLINE Enumeration Func_1(Capital_Letter Ch_1_Par_Val,
                                 Capital_Letter Ch_2_Par_Val);
BENCH_NOINLINE Boolean Func_2(Str_30 Str_1_Par_Ref, Str_30 Str_2_Par_Ref);
BENCH_NOINLINE Boolean Func_3(Enumeration Enum_Par_Val);

#endif

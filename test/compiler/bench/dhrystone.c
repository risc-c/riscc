/*
 * Dhrystone 2.1, Reinhold P. Weicker, May 25, 1988.
 * Adapted from dhry_1.c: https://www.netlib.org/benchmark/dhry-c
 * Fixed run count, static records, and checked results replace interactive
 * input and allocation. Simulation markers time only the benchmark loop.
 */
#include "dhrystone.h"

Rec_Pointer Ptr_Glob, Next_Ptr_Glob;
int Int_Glob;
Boolean Bool_Glob;
char Ch_1_Glob, Ch_2_Glob;
int Arr_1_Glob[50];
int Arr_2_Glob[50][50];

int main(void)
{
    One_Fifty Int_1_Loc, Int_2_Loc, Int_3_Loc;
    char Ch_Index;
    Enumeration Enum_Loc;
    Str_30 Str_1_Loc, Str_2_Loc;
    int Run_Index;
    static Rec_Type Records[2];

    Next_Ptr_Glob = &Records[0];
    Ptr_Glob = &Records[1];
    Ptr_Glob->Ptr_Comp = Next_Ptr_Glob;
    Ptr_Glob->Discr = Ident_1;
    Ptr_Glob->variant.var_1.Enum_Comp = Ident_3;
    Ptr_Glob->variant.var_1.Int_Comp = 40;
    strcpy(Ptr_Glob->variant.var_1.Str_Comp, "DHRYSTONE PROGRAM, SOME STRING");
    strcpy(Str_1_Loc, "DHRYSTONE PROGRAM, 1'ST STRING");
    Arr_2_Glob[8][7] = 10;

    bench_mark(DHRYSTONE_RUNS);
    for (Run_Index = 1; Run_Index <= DHRYSTONE_RUNS; ++Run_Index)
    {
        Proc_5();
        Proc_4();
        Int_1_Loc = 2;
        Int_2_Loc = 3;
        strcpy(Str_2_Loc, "DHRYSTONE PROGRAM, 2'ND STRING");
        Enum_Loc = Ident_2;
        Bool_Glob = !Func_2(Str_1_Loc, Str_2_Loc);
        while (Int_1_Loc < Int_2_Loc)
        {
            Int_3_Loc = 5 * Int_1_Loc - Int_2_Loc;
            Proc_7(Int_1_Loc, Int_2_Loc, &Int_3_Loc);
            Int_1_Loc += 1;
        }
        Proc_8(Arr_1_Glob, Arr_2_Glob, Int_1_Loc, Int_3_Loc);
        Proc_1(Ptr_Glob);
        for (Ch_Index = 'A'; Ch_Index <= Ch_2_Glob; ++Ch_Index)
        {
            if (Enum_Loc == Func_1(Ch_Index, 'C'))
            {
                Proc_6(Ident_1, &Enum_Loc);
                strcpy(Str_2_Loc, "DHRYSTONE PROGRAM, 3'RD STRING");
                Int_2_Loc = Run_Index;
                Int_Glob = Run_Index;
            }
        }
        Int_2_Loc = Int_2_Loc * Int_1_Loc;
        Int_1_Loc = Int_2_Loc / Int_3_Loc;
        Int_2_Loc = 7 * (Int_2_Loc - Int_3_Loc) - Int_1_Loc;
        Proc_2(&Int_1_Loc);
    }
    bench_mark(0);

    /* Check the reference final state, including both records and strings. */
    if (Int_Glob != 5 || Bool_Glob != 1 || Ch_1_Glob != 'A' || Ch_2_Glob != 'B')
        bench_finish(0xd001u, 0);
    if (Arr_1_Glob[8] != 7 || Arr_2_Glob[8][7] != DHRYSTONE_RUNS + 10 ||
        Arr_1_Glob[9] != 7 || Arr_1_Glob[38] != 8 ||
        Arr_2_Glob[8][8] != 8 || Arr_2_Glob[8][9] != 8 || Arr_2_Glob[28][8] != 7)
        bench_finish(0xd002u, 0);
    if (Ptr_Glob->Ptr_Comp != Next_Ptr_Glob ||
        Ptr_Glob->Discr != Ident_1 ||
        Ptr_Glob->variant.var_1.Enum_Comp != Ident_3 ||
        Ptr_Glob->variant.var_1.Int_Comp != 17 ||
        strcmp(Ptr_Glob->variant.var_1.Str_Comp, "DHRYSTONE PROGRAM, SOME STRING"))
        bench_finish(0xd003u, 0);
    if (Next_Ptr_Glob->Ptr_Comp != Next_Ptr_Glob ||
        Next_Ptr_Glob->Discr != Ident_1 ||
        Next_Ptr_Glob->variant.var_1.Enum_Comp != Ident_2 ||
        Next_Ptr_Glob->variant.var_1.Int_Comp != 18 ||
        strcmp(Next_Ptr_Glob->variant.var_1.Str_Comp, "DHRYSTONE PROGRAM, SOME STRING"))
        bench_finish(0xd004u, 0);
    if (Int_1_Loc != 5 || Int_2_Loc != 13 || Int_3_Loc != 7 || Enum_Loc != Ident_2 ||
        strcmp(Str_1_Loc, "DHRYSTONE PROGRAM, 1'ST STRING") ||
        strcmp(Str_2_Loc, "DHRYSTONE PROGRAM, 2'ND STRING"))
        bench_finish(0xd005u, 0);
    bench_finish(0, 0);
}

void Proc_1(Rec_Pointer Ptr_Val_Par)
{
    Rec_Pointer Next_Record = Ptr_Val_Par->Ptr_Comp;

    *Ptr_Val_Par->Ptr_Comp = *Ptr_Glob;
    Ptr_Val_Par->variant.var_1.Int_Comp = 5;
    Next_Record->variant.var_1.Int_Comp = Ptr_Val_Par->variant.var_1.Int_Comp;
    Next_Record->Ptr_Comp = Ptr_Val_Par->Ptr_Comp;
    Proc_3(&Next_Record->Ptr_Comp);
    if (Next_Record->Discr == Ident_1)
    {
        Next_Record->variant.var_1.Int_Comp = 6;
        Proc_6(Ptr_Val_Par->variant.var_1.Enum_Comp,
               &Next_Record->variant.var_1.Enum_Comp);
        Next_Record->Ptr_Comp = Ptr_Glob->Ptr_Comp;
        Proc_7(Next_Record->variant.var_1.Int_Comp, 10,
               &Next_Record->variant.var_1.Int_Comp);
    }
    else
        *Ptr_Val_Par = *Ptr_Val_Par->Ptr_Comp;
}

void Proc_2(One_Fifty *Int_Par_Ref)
{
    One_Fifty Int_Loc;
    Enumeration Enum_Loc;

    Int_Loc = *Int_Par_Ref + 10;
    do
    {
        if (Ch_1_Glob == 'A')
        {
            Int_Loc -= 1;
            *Int_Par_Ref = Int_Loc - Int_Glob;
            Enum_Loc = Ident_1;
        }
    } while (Enum_Loc != Ident_1);
}

void Proc_3(Rec_Pointer *Ptr_Ref_Par)
{
    if (Ptr_Glob != 0)
        *Ptr_Ref_Par = Ptr_Glob->Ptr_Comp;
    Proc_7(10, Int_Glob, &Ptr_Glob->variant.var_1.Int_Comp);
}

void Proc_4(void)
{
    Boolean Bool_Loc;

    Bool_Loc = Ch_1_Glob == 'A';
    Bool_Glob = Bool_Loc | Bool_Glob;
    Ch_2_Glob = 'B';
}

void Proc_5(void)
{
    Ch_1_Glob = 'A';
    Bool_Glob = 0;
}

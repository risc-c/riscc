// RISC-C non-nesting C interrupt wrapper.
//
// Hardware enters with S0 = EPC and IE = 0.  An interrupted leaf may be
// using r7 for a non-stack value, so entry never uses the interrupted r7 as a
// stack pointer.  The thread prefix below S2 supplies the interrupted context;
// the C runtime has one optional global handler stack:
//
//   S2 - 22 .. S2 - 16  interrupted S3 .. S6
//   S2 - 14              interrupted r7
//   S2 - 12 .. S2 - 4    interrupted r0 .. r4
//   S2 - 2               interrupted S7
//
// r5, r6, and the handler stack pointer are ordinary C callee-saved state.
// S0 holds EPC, S1 is the deliberate interrupt scratch register, and S2 keeps
// the current thread/context anchor.  S3..S7 are software-managed registers
// and are restored unconditionally after the C handler.

        .section .riscc.irq_context,"aw",@nobits
        .p2align 1
        .zero   22
        .global __riscc_irq_context_end
__riscc_irq_context_end:

        .section .bss.riscc_irq_handler,"aw",@nobits
        .p2align 1
        .global __riscc_irq_handler_ptr
__riscc_irq_handler_ptr:
        .zero   2

        .section .bss.riscc_irq_stack,"aw",@nobits
        .p2align 1
        .global __riscc_irq_stack_bottom
__riscc_irq_stack_bottom:
        .zero   64
        .global __riscc_irq_stack_top
__riscc_irq_stack_top:

        .section .text.riscc_irq_set_handler,"ax",@progbits
        .p2align 1
        .global riscc_irq_set_handler
        .type riscc_irq_set_handler,@function
riscc_irq_set_handler:
        LDI16   r0, __riscc_irq_handler_ptr
        STW     r1, [r0+0]
        RETS
        .size riscc_irq_set_handler, . - riscc_irq_set_handler

        .section .text.__riscc_irq_entry,"ax",@progbits
        .p2align 1
        .global __riscc_irq_vector
        .global __riscc_irq_entry
        .type __riscc_irq_vector,@function
        .type __riscc_irq_entry,@function
__riscc_irq_vector:
__riscc_irq_entry:
        MTS     S1, r0

        MFS     r0, S2
        STW     r1, [r0-10]
        STW     r2, [r0-8]
        STW     r3, [r0-6]
        STW     r4, [r0-4]
        MFS     r1, S7
        STW     r1, [r0-2]
        STW     r7, [r0-14]
        MFS     r1, S1
        STW     r1, [r0-12]
        MFS     r1, S3
        STW     r1, [r0-22]
        MFS     r1, S4
        STW     r1, [r0-20]
        MFS     r1, S5
        STW     r1, [r0-18]
        MFS     r1, S6
        STW     r1, [r0-16]

        LDI16   r0, __riscc_irq_handler_ptr
        LDW     r0, [r0+0]
        BNEZ    .Lhandler_set
        JAL16   S0, __default_irq
.Lhandler_set:
        LDI16   r7, __riscc_irq_stack_top
        JAL     S7, r0

        MFS     r0, S2
        LDW     r1, [r0-14]
        MTS     S1, r1
        LDW     r1, [r0-22]
        MTS     S3, r1
        LDW     r1, [r0-20]
        MTS     S4, r1
        LDW     r1, [r0-18]
        MTS     S5, r1
        LDW     r1, [r0-16]
        MTS     S6, r1
        LDW     r1, [r0-2]
        MTS     S7, r1
        LDW     r4, [r0-4]
        LDW     r3, [r0-6]
        LDW     r2, [r0-8]
        LDW     r1, [r0-10]
        LDW     r0, [r0-12]
        MFS     r7, S1
        RETI    S0
        .size __riscc_irq_vector, . - __riscc_irq_vector
        .size __riscc_irq_entry, . - __riscc_irq_entry

        .section .text.__default_irq,"ax",@progbits
        .p2align 1
        .weak __default_irq
        .type __default_irq,@function
__default_irq:
.Lirq_halt:
        JMP8    .Lirq_halt
        .size __default_irq, . - __default_irq

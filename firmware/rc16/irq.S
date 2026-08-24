// RC16 non-nesting C interrupt wrapper.
//
// Hardware enters with S0 = EPC and IE = 0.  An interrupted leaf may be
// using r7 for a non-stack value, so entry never uses the interrupted r7 as a
// stack pointer.  The thread prefix below S2 supplies the interrupted context;
// the C runtime has one optional global handler stack:
//
//   S2 - 18 .. S2 - 16  interrupted S3 .. S4
//   S2 - 14              interrupted r7
//   S2 - 12 .. S2 - 6    interrupted r0 .. r3
//   S2 - 4               interrupted S7
//
// r4..r6, S5..S6, and the handler stack pointer are C callee-saved state.
// The wrapper does not use them, so an ABI-conforming C handler preserves
// them without interrupt-context slots.
// S0 holds EPC, S1 is the deliberate interrupt scratch register, and S2 keeps
// the current thread/context anchor.  S3 and S4 are caller-saved; S7 holds
// the public call link and is restored after the C handler.

        .section .riscc.irq_context,"aw",@nobits
        .p2align 1
        .zero   18
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
        ST     r1, [r0+0]
        RET     S7
        .size riscc_irq_set_handler, . - riscc_irq_set_handler

        .section .text.__riscc_irq_entry,"ax",@progbits
        .p2align 1
        .global __riscc_irq_vector
        .global __riscc_irq_entry
        .type __riscc_irq_vector,@function
        .type __riscc_irq_entry,@function
__riscc_irq_vector:
__riscc_irq_entry:
#if defined(__RISCC_SYS__) || defined(__RISCC_FULL__)
        MTS     S1, r0
#endif

        MFS     r0, S2
        ST     r1, [r0-10]
        ST     r2, [r0-8]
        ST     r3, [r0-6]
        MFS     r1, S7
        ST     r1, [r0-4]
        ST     r7, [r0-14]
        MFS     r1, S1
        ST     r1, [r0-12]
        MFS     r1, S3
        ST     r1, [r0-18]
        MFS     r1, S4
        ST     r1, [r0-16]

        LDI16   r0, __riscc_irq_handler_ptr
        LD     r0, [r0+0]
        BNEZ    .Lhandler_set
        LDI16   r0, __default_irq
        JMP     r0
.Lhandler_set:
        LDI16   r7, __riscc_irq_stack_top
        JALR    S7, r0

        MFS     r0, S2
        LD     r1, [r0-14]
        MTS     S1, r1
        LD     r1, [r0-18]
        MTS     S3, r1
        LD     r1, [r0-16]
        MTS     S4, r1
        LD     r1, [r0-4]
        MTS     S7, r1
        LD     r3, [r0-6]
        LD     r2, [r0-8]
        LD     r1, [r0-10]
        LD     r0, [r0-12]
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

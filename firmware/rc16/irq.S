// RC16 non-nesting C interrupt wrapper.
//
// Hardware enters with S0 = EPC and IE = 0.  An interrupted leaf may be
// using r7 for a non-stack value, so entry never uses the interrupted r7 as a
// stack pointer.  The prefix below the active context/TLS anchor supplies the
// interrupted context; the C runtime has one optional global handler stack:
//
//   anchor - 20                 interrupted S2
//   anchor - 18 .. anchor - 16  interrupted S3 .. S4
//   anchor - 14                   interrupted r7
//   anchor - 12 .. anchor - 6     interrupted r0 .. r3
//   anchor - 4                    interrupted S7
//
// r4..r6, S5..S6, and the handler stack pointer are C callee-saved state.
// The wrapper does not use them, so an ABI-conforming C handler preserves
// them without interrupt-context slots.
// S0 holds EPC and S1 is the deliberate interrupt scratch register. S2..S4
// are caller-saved; S5..S6 are callee-saved. S7 holds the public call link and
// is restored after the C handler.

        .section .riscc.irq_context,"aw",@nobits
        .p2align 1
        .zero   20
        .global __riscc_irq_context_end
__riscc_irq_context_end:

        .section .data.riscc_irq_state,"aw",@progbits
        .p2align 1
        .global __riscc_irq_state
__riscc_irq_state:
        .global __riscc_irq_handler_ptr
__riscc_irq_handler_ptr:
        .short  __default_irq
        .short  __riscc_irq_stack_top

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
        LDI16   r0, __riscc_irq_state
        ST      r1, [r0+0]
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

        LDI16   r0, __riscc_current_context
        LD      r0, [r0+0]
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
        MFS     r1, S2
        ST     r1, [r0-20]
        MTS     S1, r0

        LDI16   r0, __riscc_irq_state
        LD      r7, [r0+2]
        LD      r0, [r0+0]
        JALR    S7, r0

        MFS     r0, S1
        LD      r7, [r0-14]
        LD     r1, [r0-18]
        MTS     S3, r1
        LD     r1, [r0-16]
        MTS     S4, r1
        LD     r1, [r0-20]
        MTS     S2, r1
        LD     r1, [r0-4]
        MTS     S7, r1
        LD     r3, [r0-6]
        LD     r2, [r0-8]
        LD     r1, [r0-10]
        LD     r0, [r0-12]
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

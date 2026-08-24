// RC32 non-nesting C interrupt wrapper. The active context/TLS anchor points
// just above the 36-byte interrupted-context prefix allocated before TLS.
// r4..r6 and S5..S6 are C callee-saved and unused by this wrapper, so an
// ABI-conforming C handler preserves them without interrupt-context slots.

        .section .riscc.irq_context,"aw",@nobits
        .p2align 2
        .zero   36
        .global __riscc_irq_context_end
__riscc_irq_context_end:

        .section .data.riscc_irq_state,"aw",@progbits
        .p2align 2
        .global __riscc_irq_state
__riscc_irq_state:
        .global __riscc_irq_handler_ptr
__riscc_irq_handler_ptr:
        .long   __default_irq
        .long   __riscc_irq_stack_top

        .section .bss.riscc_irq_stack,"aw",@nobits
        .p2align 2
        .global __riscc_irq_stack_bottom
__riscc_irq_stack_bottom:
        .zero   128
        .global __riscc_irq_stack_top
__riscc_irq_stack_top:

        .section .text.riscc_irq_set_handler,"ax",@progbits
        .p2align 1
        .global riscc_irq_set_handler
        .type riscc_irq_set_handler,@function
riscc_irq_set_handler:
        LDPC    r0, .Lirq_state
        ST      r1, [r0 + 0]
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
        MTS     S1, r0
        LDPC    r0, .Lcurrent_context
        LD      r0, [r0 + 0]
        ST      r1, [r0 - 16]
        ST      r2, [r0 - 12]
        ST      r3, [r0 - 8]
        MFS     r1, S7
        ST      r1, [r0 - 4]
        ST      r7, [r0 - 24]
        MFS     r1, S1
        ST      r1, [r0 - 20]
        MFS     r1, S3
        ST      r1, [r0 - 32]
        MFS     r1, S4
        ST      r1, [r0 - 28]
        MFS     r1, S2
        ST      r1, [r0 - 36]
        MTS     S1, r0

        LDPC    r0, .Lirq_state
        LD      r7, [r0 + 4]
        LD      r0, [r0 + 0]
        JALR    S7, r0

        MFS     r0, S1
        LD      r7, [r0 - 24]
        LD      r1, [r0 - 32]
        MTS     S3, r1
        LD      r1, [r0 - 28]
        MTS     S4, r1
        LD      r1, [r0 - 36]
        MTS     S2, r1
        LD      r1, [r0 - 4]
        MTS     S7, r1
        LD      r3, [r0 - 8]
        LD      r2, [r0 - 12]
        LD      r1, [r0 - 16]
        LD      r0, [r0 - 20]
        RETI    S0
        .size __riscc_irq_vector, . - __riscc_irq_vector
        .size __riscc_irq_entry, . - __riscc_irq_entry

        // One address literal serves every use within the compact LDPC reach.
        .p2align 2
.Lirq_state:
        .long   __riscc_irq_state
.Lcurrent_context:
        .long   __riscc_current_context

        .section .text.__default_irq,"ax",@progbits
        .p2align 1
        .weak __default_irq
        .type __default_irq,@function
__default_irq:
.Lirq_halt:
        JMP8    .Lirq_halt
        .size __default_irq, . - __default_irq

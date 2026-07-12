// IRQ control instructions are independent of the optional C IRQ wrapper.
// A custom assembly __riscc_irq_vector can use these helpers without pulling
// in the wrapper, its C handler, or its S2-relative context prefix.

        .section .text.riscc_irq_enable,"ax",@progbits
        .p2align 1
        .global riscc_irq_enable
        .type riscc_irq_enable,@function
riscc_irq_enable:
        STI
        RETS
        .size riscc_irq_enable, . - riscc_irq_enable

        .section .text.riscc_irq_disable,"ax",@progbits
        .p2align 1
        .global riscc_irq_disable
        .type riscc_irq_disable,@function
riscc_irq_disable:
        CLI
        RETS
        .size riscc_irq_disable, . - riscc_irq_disable

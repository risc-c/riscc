.section .vectors,"ax",@progbits
.global _start
_start:
    LDPC r7, .Lstack
    LDPC r0, .Lmain
    JALR s7, r0
    HALT
.p2align 2
.Lstack: .long 0x3ff0
.Lmain: .long call_target(main)

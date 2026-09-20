ENTRY(_start)
MEMORY { RAM (rwx) : ORIGIN = 0, LENGTH = 0x4000 }
SECTIONS {
    .text : { *(.vectors) *(.text*) *(.rodata*) } > RAM
    .data : { *(.data*) } > RAM
    .bss (NOLOAD) : { *(.bss*) } > RAM
    ASSERT(. < 0x3800, "SDRAM CPU test exceeds SRAM stack limit")
}

/* Plain-C benchmark image using the normal RC32 startup and runtime. Output
 * sections inherit larger input alignments (e.g. constant tables aligned 16). */
ENTRY(_start)
MEMORY { RAM (rwx) : ORIGIN = 0, LENGTH = 0x10000 }
SECTIONS
{
    .vectors : { KEEP(*(.vectors)) } > RAM
    ASSERT(SIZEOF(.vectors) == 2 || SIZEOF(.vectors) == 8,
           "RISC-C vector table must contain reset or reset plus IRQ")
    .text : ALIGN(4) { *(.text .text.*) } > RAM
    .rodata : ALIGN(4) { *(.rodata .rodata.*) } > RAM
    .data : ALIGN(4) { *(.data .data.*) } > RAM
    .tdata : ALIGN(4) {
        __tls_start = .;
        *(.tdata .tdata.*)
    } > RAM
    .tbss (NOLOAD) : ALIGN(4) {
        __zero_start = .;
        *(.tbss .tbss.*)
    } > RAM
    .bss (NOLOAD) : ALIGN(4) {
        *(.bss .bss.* COMMON)
        . = ALIGN(4);
        __zero_end = .;
    } > RAM
    __image_end = .;
    __heap_start = .;
    __stack_top = 0xfff0;
    __heap_end = __stack_top;
    ASSERT(__image_end <= __stack_top - 4096,
           "CoreMark data leaves less than 4 KiB of stack")
    /DISCARD/ : { *(.comment .note.GNU-stack) }
}

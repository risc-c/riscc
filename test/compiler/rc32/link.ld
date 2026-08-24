ENTRY(_start)

MEMORY
{
  RAM (rwx) : ORIGIN = 0, LENGTH = 0x10000
}

SECTIONS
{
  .vectors ORIGIN(RAM) :
  {
    KEEP(*(.vectors))
  } > RAM
  ASSERT(SIZEOF(.vectors) == 2 || SIZEOF(.vectors) == 8,
         "RISC-C vector table must contain reset or reset plus IRQ")

  .text ALIGN(4) :
  {
    *(.text .text.*)
  } > RAM

  .rodata ALIGN(4) :
  {
    *(.rodata .rodata.*)
  } > RAM

  .data ALIGN(4) :
  {
    *(.data .data.*)
    . = ALIGN(4);
  } > RAM

  .tdata ALIGN(4) :
  {
    __tls_start = .;
    *(.tdata .tdata.*)
    . = ALIGN(4);
  } > RAM

  .tbss ALIGN(4) (NOLOAD) :
  {
    __zero_start = .;
    *(.tbss .tbss.*)
    . = ALIGN(4);
  } > RAM

  .bss ALIGN(4) (NOLOAD) :
  {
    *(.bss .bss.* COMMON)
    . = ALIGN(4);
    __zero_end = .;
  } > RAM

  __image_end = .;
  __stack_top = 0xfff0;
  ASSERT(__image_end <= __stack_top,
         "RC32 compiler test image exceeds RAM")

  /DISCARD/ :
  {
    *(.comment)
    *(.note.GNU-stack)
  }
}

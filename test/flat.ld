ENTRY(start)

MEMORY
{
  RAM (rwx) : ORIGIN = 0x0000, LENGTH = 0x10000
}

SECTIONS
{
  .vectors ORIGIN(RAM) :
  {
    KEEP(*(.vectors))
  } > RAM

  .text ALIGN(2) :
  {
    *(.text .text.*)
  } > RAM

  .rodata ALIGN(2) :
  {
    *(.rodata .rodata.*)
  } > RAM

  .data ALIGN(2) :
  {
    *(.data .data.*)
  } > RAM

  __image_end = .;
  ASSERT(__image_end <= ORIGIN(RAM) + LENGTH(RAM),
         "RISC-C test image exceeds the 16-bit address space")
}

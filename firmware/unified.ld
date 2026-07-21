ENTRY(_start)

MEMORY
{
  RAM (rwx) : ORIGIN = 0x0000,
              LENGTH = DEFINED(__riscc_ram_length) ? __riscc_ram_length : 0x8000
}

SECTIONS
{
  .vectors ORIGIN(RAM) :
  {
    KEEP(*(.vectors))
  } > RAM

  ASSERT(SIZEOF(.vectors) == 8,
         "RISC-C requires two four-byte vector slots")

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
    __data_start = .;
    *(.data .data.*)
    . = ALIGN(2);
    __data_end = .;
  } > RAM

  /* Present only when libirq's C wrapper is extracted.  S2 points immediately
   * above this per-thread interrupt prefix. */
  .riscc.irq_context ALIGN(2) (NOLOAD) :
  {
    KEEP(*(.riscc.irq_context))
  } > RAM

  .tdata ALIGN(2) :
  {
    __tls_start = .;
    *(.tdata .tdata.*)
    . = ALIGN(2);
    __tdata_end = .;
  } > RAM

  .tbss ALIGN(2) (NOLOAD) :
  {
    __zero_start = .;
    __tbss_start = .;
    *(.tbss .tbss.*)
    . = ALIGN(2);
    __tbss_end = .;
    __tls_end = .;
  } > RAM

  .bss __tls_end (NOLOAD) :
  {
    __bss_start = .;
    *(.bss .bss.* COMMON)
    . = ALIGN(2);
    __bss_end = .;
    __zero_end = .;
  } > RAM

  __image_end = .;
  __heap_start = __image_end;
  __stack_top = ORIGIN(RAM) + LENGTH(RAM);
  __heap_end = __stack_top;

  ASSERT(__image_end <= __stack_top,
         "RISC-C unified image exceeds the 32 KiB RAM")

  /DISCARD/ :
  {
    *(.comment)
    *(.note.GNU-stack)
  }
}

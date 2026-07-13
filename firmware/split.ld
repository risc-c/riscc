ENTRY(_start)

/*
 * Data VMAs carry an ELF-only 0x10000 tag.  RISC-C data relocations emit the
 * low 16 bits; the tag keeps equal logical code/data addresses distinct in
 * the linked ELF file and in its load segments.
 */
MEMORY
{
  CODE (rx)  : ORIGIN = 0x00000, LENGTH = 0x10000
  DATA (rw)  : ORIGIN = 0x10000, LENGTH = 0x08000
}

SECTIONS
{
  .vectors ORIGIN(CODE) :
  {
    KEEP(*(.vectors))
  } > CODE

  ASSERT(SIZEOF(.vectors) == 8,
         "RISC-C requires two four-byte vector slots")

  .text ALIGN(2) :
  {
    *(.text .text.*)
  } > CODE

  __code_end = .;
  ASSERT(__code_end <= ORIGIN(CODE) + LENGTH(CODE),
         "RISC-C program image exceeds the 15-bit word address space")

  .rodata ORIGIN(DATA) :
  {
    *(.rodata .rodata.*)
  } > DATA

  .data ALIGN(2) :
  {
    __data_start = .;
    *(.data .data.*)
    . = ALIGN(2);
    __data_end = .;
  } > DATA

  /* Present only when libirq's C wrapper is extracted.  S2 points immediately
   * above this per-thread interrupt prefix. */
  .riscc.irq_context ALIGN(2) (NOLOAD) :
  {
    KEEP(*(.riscc.irq_context))
  } > DATA

  .tdata ALIGN(2) :
  {
    __tls_start = .;
    *(.tdata .tdata.*)
    . = ALIGN(2);
    __tdata_end = .;
  } > DATA

  .tbss ALIGN(2) (NOLOAD) :
  {
    __zero_start = .;
    __tbss_start = .;
    *(.tbss .tbss.*)
    . = ALIGN(2);
    __tbss_end = .;
    __tls_end = .;
  } > DATA

  .bss __tls_end (NOLOAD) :
  {
    __bss_start = .;
    *(.bss .bss.* COMMON)
    . = ALIGN(2);
    __bss_end = .;
    __zero_end = .;
  } > DATA

  __data_space_tag = ORIGIN(DATA);
  __data_image_end = __tdata_end;
  __heap_start = __bss_end;
  __stack_top = ORIGIN(DATA) + LENGTH(DATA);
  __heap_end = __stack_top;

  ASSERT(__bss_end <= __stack_top,
         "RISC-C data image and BSS exceed the 32 KiB data RAM")

  /DISCARD/ :
  {
    *(.comment)
    *(.note.GNU-stack)
  }
}

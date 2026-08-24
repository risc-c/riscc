/* RC32 unified ROM/RAM image. */
ENTRY(_start)

MEMORY
{
  RAM (rwx) : ORIGIN = 0,
              LENGTH = DEFINED(__riscc_ram_length) ? __riscc_ram_length : 0x10000
}

SECTIONS
{
  .vectors ORIGIN(RAM) :
  {
    KEEP(*(.vectors))
  } > RAM

  ASSERT(SIZEOF(.vectors) == 2 || SIZEOF(.vectors) == 8,
         "RISC-C vector table must contain reset or reset plus IRQ")

  .vectors.tramp ALIGN(4) :
  {
    KEEP(*(.vectors.tramp))
  } > RAM

  .text ALIGN(4) :
  {
    *(.text .text.*)
  } > RAM

  .rodata ALIGN(4) :
  {
    *(.rodata .rodata.*)
  } > RAM

  .init_array ALIGN(4) :
  {
    KEEP(*(.init_array .init_array.*))
  } > RAM

  ASSERT(SIZEOF(.init_array) == 0,
         "RISC-C runtime does not support dynamic C++ constructors")

  .unsupported_cxx_startup ALIGN(4) :
  {
    KEEP(*(.preinit_array .preinit_array.*))
    KEEP(*(.fini_array .fini_array.*))
    KEEP(*(.ctors .ctors.*))
    KEEP(*(.dtors .dtors.*))
  } > RAM

  ASSERT(SIZEOF(.unsupported_cxx_startup) == 0,
         "RISC-C runtime does not support C++ startup or finalizer arrays")

  .data ALIGN(4) :
  {
    __data_start = .;
    *(.data .data.*)
    . = ALIGN(4);
    __data_end = .;
  } > RAM

  .riscc.irq_context ALIGN(4) (NOLOAD) :
  {
    KEEP(*(.riscc.irq_context))
  } > RAM

  .tdata ALIGN(4) :
  {
    __tls_start = .;
    *(.tdata .tdata.*)
    . = ALIGN(4);
    __tdata_end = .;
  } > RAM

  .tbss ALIGN(4) (NOLOAD) :
  {
    __zero_start = .;
    __tbss_start = .;
    *(.tbss .tbss.*)
    . = ALIGN(4);
    __tbss_end = .;
    __tls_end = .;
  } > RAM

  .bss __tls_end (NOLOAD) :
  {
    __bss_start = .;
    *(.bss .bss.* COMMON)
    . = ALIGN(4);
    __bss_end = .;
    __zero_end = .;
  } > RAM

  __image_end = .;
  __heap_start = __image_end;
  __ram_end = ORIGIN(RAM) + LENGTH(RAM);
  __io_start = DEFINED(__riscc_io_start) ? __riscc_io_start : 0xfff0;
  __usable_end = __ram_end < __io_start ? __ram_end : __io_start;
  __stack_top = __usable_end & ~3;
  __heap_end = __stack_top;

  ASSERT(__image_end <= __stack_top,
         "RC32 unified image exceeds RAM")

  /DISCARD/ :
  {
    *(.comment)
    *(.note.GNU-stack)
  }
}

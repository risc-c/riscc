/* Nano unified ROM/RAM image. Nano has no S registers, IRQ entry, or TLS. */
ENTRY(_start)

MEMORY
{
  RAM (rwx) : ORIGIN = 0x0000,
              LENGTH = DEFINED(__riscc_ram_length) ? __riscc_ram_length : 0x10000
}

SECTIONS
{
  .vectors ORIGIN(RAM) :
  {
    KEEP(*(.vectors))
  } > RAM

  ASSERT(SIZEOF(.vectors) == 2,
         "RISC-C Nano requires one compact reset vector")

  .vectors.tramp ALIGN(2) :
  {
    KEEP(*(.vectors.tramp))
  } > RAM

  .text ALIGN(2) :
  {
    *(.text .text.*)
  } > RAM

  .rodata ALIGN(2) :
  {
    *(.rodata .rodata.*)
  } > RAM

  .init_array ALIGN(2) :
  {
    KEEP(*(.init_array .init_array.*))
  } > RAM

  ASSERT(SIZEOF(.init_array) == 0,
         "RISC-C runtime does not support dynamic C++ constructors")

  .unsupported_cxx_startup ALIGN(2) :
  {
    KEEP(*(.preinit_array .preinit_array.*))
    KEEP(*(.fini_array .fini_array.*))
    KEEP(*(.ctors .ctors.*))
    KEEP(*(.dtors .dtors.*))
  } > RAM

  ASSERT(SIZEOF(.unsupported_cxx_startup) == 0,
         "RISC-C runtime does not support C++ startup or finalizer arrays")

  .data ALIGN(2) :
  {
    __data_start = .;
    *(.data .data.*)
    . = ALIGN(2);
    __data_end = .;
  } > RAM

  .tdata ALIGN(2) :
  {
    *(.tdata .tdata.*)
  } > RAM

  .tbss ALIGN(2) (NOLOAD) :
  {
    *(.tbss .tbss.*)
  } > RAM

  ASSERT(SIZEOF(.tdata) == 0 && SIZEOF(.tbss) == 0,
         "RISC-C Nano does not support thread-local storage")

  .bss ALIGN(2) (NOLOAD) :
  {
    __zero_start = .;
    __bss_start = .;
    *(.bss .bss.* COMMON)
    . = ALIGN(2);
    __bss_end = .;
    __zero_end = .;
  } > RAM

  __image_end = .;
  __heap_start = __image_end;
  __ram_end = ORIGIN(RAM) + LENGTH(RAM);
  __io_start = DEFINED(__riscc_io_start) ? __riscc_io_start : 0xfff0;
  __usable_end = __ram_end < __io_start ? __ram_end : __io_start;
  __stack_top = __usable_end == 0x10000 ? 0xfffe : __usable_end;
  __heap_end = __stack_top;

  ASSERT(__image_end <= __stack_top,
         "RISC-C Nano unified image exceeds RAM")

  /DISCARD/ :
  {
    *(.comment)
    *(.note.GNU-stack)
  }
}

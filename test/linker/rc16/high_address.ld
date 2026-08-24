ENTRY(start)

SECTIONS
{
  .vectors 0x0000 :
  {
    KEEP(*(.vectors))
  }

  .text.low 0x0010 :
  {
    *(.text.low)
  }

  .text.boundary.low 0x7ffc :
  {
    *(.text.boundary.low)
  }

  .text.boundary.high 0x8000 :
  {
    *(.text.boundary.high)
  }

  .rodata.top 0xffd0 :
  {
    *(.rodata.top)
  }

  .text.top 0xffd8 :
  {
    *(.text.top)
  }

  ASSERT(SIZEOF(.text.boundary.low) == 4,
         "boundary-low sequence must end at 0x8000")
  ASSERT(ADDR(.text.top) + SIZEOF(.text.top) <= 0xfff0,
         "upper-address test overlaps the I/O page")
}

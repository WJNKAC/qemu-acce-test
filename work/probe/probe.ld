ENTRY(_start)
SECTIONS {
  . = 0x40080000;
  .text : { *(.text) *(.rodata*) *(.data) *(.bss) *(COMMON) }
  /DISCARD/ : { *(.ARM.attributes) *(.comment) *(.note*) *(.eh_frame*) }
}

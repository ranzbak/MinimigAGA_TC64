/* L1 bench image: one flat 1 MB memory starting at 0.
 *   0x0000  reset vector          (.text.reset)
 *   0x0020  default trap entry    (.text.trap, mtvec reset value)
 *   ....    crt0                  (.text.crt0)
 *   0x0100  code run from the "ROM" region, latency ROMWS (.text.rom)
 *   0x2000  program .text (first: .text.entry, then .text), rodata, data, bss
 *   0x4000  .at4000 (fixed data, used by lanes.S)
 *   stack top = 0x00100000
 * The linker refuses overlapping sections, so a program whose .text grows
 * into a fixed section fails to link instead of running wrong. */
OUTPUT_ARCH("riscv")
ENTRY(_reset)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 1M
}

SECTIONS
{
    .reset 0x0000 : { KEEP(*(.text.reset)) } > RAM
    .trap  0x0020 : { KEEP(*(.text.trap)) } > RAM
    .crt0         : { KEEP(*(.text.crt0)) } > RAM
    .rom   0x0100 : { *(.text.rom) *(.text.rom.*) } > RAM
    .text  0x2000 : { *(.text.entry) *(.text) *(.text.*) } > RAM
    .rodata       : { . = ALIGN(4); *(.rodata) *(.rodata.*) *(.srodata) *(.srodata.*) } > RAM
    .data         : { . = ALIGN(4); *(.data) *(.data.*) *(.sdata) *(.sdata.*) . = ALIGN(4); } > RAM
    .bss (NOLOAD) : {
        . = ALIGN(4);
        __bss_start = .;
        *(.bss) *(.bss.*) *(.sbss) *(.sbss.*) *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > RAM
    .at4000 0x4000 : { KEEP(*(.at4000)) . = ALIGN(4); } > RAM

    __stack_top = ORIGIN(RAM) + LENGTH(RAM);
}

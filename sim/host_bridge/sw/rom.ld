/* L2 host-bridge test ROM: everything in the 8 KB boot BRAM 0x0-0x1FFF.
 *   0x0000  reset vector          (.text.reset)
 *   0x0020  trap entry            (.text.trap, mtvec reset value)
 *   ....    crt0, text, rodata, data, bss
 *   0x1800  .scratch: 256 bytes the tests store into (t_lanes); NOLOAD
 *   stack: 0x2000 down to the end of .scratch
 * The linker refuses overlapping sections, so a program that grows into
 * .scratch fails to link instead of running wrong.  Every loadable section
 * ends 4-aligned: romgen reads the binary in whole 32-bit words. */
OUTPUT_ARCH("riscv")
ENTRY(_reset)

MEMORY
{
    BRAM (rwx) : ORIGIN = 0x00000000, LENGTH = 8K
}

SECTIONS
{
    .reset 0x0000 : { KEEP(*(.text.reset)) . = ALIGN(4); } > BRAM
    .trap  0x0020 : { KEEP(*(.text.trap)) . = ALIGN(4); } > BRAM
    .text         : { KEEP(*(.text.crt0)) *(.text) *(.text.*) . = ALIGN(4); } > BRAM
    .rodata       : { . = ALIGN(4); *(.rodata) *(.rodata.*) *(.srodata) *(.srodata.*) . = ALIGN(4); } > BRAM
    .data         : { . = ALIGN(4); *(.data) *(.data.*) *(.sdata) *(.sdata.*) . = ALIGN(4); } > BRAM
    .bss (NOLOAD) : {
        . = ALIGN(4);
        __bss_start = .;
        *(.bss) *(.bss.*) *(.sbss) *(.sbss.*) *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > BRAM
    .scratch 0x1800 (NOLOAD) : { . = . + 0x100; } > BRAM

    __stack_top = ORIGIN(BRAM) + LENGTH(BRAM);
}

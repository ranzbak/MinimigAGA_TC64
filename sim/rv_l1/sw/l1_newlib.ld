/* L1 bench image for newlib-nano programs (sim/rv_l1/prog): as l1.ld, but
 * program text at 0x2000 only, stack top 0xF0000, heap in between.
 *   0x0000 reset, 0x0020 trap, crt0 (sw/crt0_l1.S), 0x2000 .text/.rodata/.data/.bss
 *   _end .. __heap_limit   heap (_sbrk in sw/syscalls.c)
 *   __heap_limit .. 0xF0000 stack (grows down)
 */
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
    .text  0x2000 : { *(.text.entry) *(.text) *(.text.*) } > RAM
    .rodata       : { . = ALIGN(4); *(.rodata) *(.rodata.*) *(.srodata) *(.srodata.*) } > RAM
    .init_array   : { . = ALIGN(4); KEEP(*(.init_array*)) KEEP(*(.ctors*)) } > RAM
    .fini_array   : { . = ALIGN(4); KEEP(*(.fini_array*)) KEEP(*(.dtors*)) } > RAM
    .data         : { . = ALIGN(4); *(.data) *(.data.*) *(.sdata) *(.sdata.*) . = ALIGN(4); } > RAM
    .bss (NOLOAD) : {
        . = ALIGN(4);
        __bss_start = .;
        *(.bss) *(.bss.*) *(.sbss) *(.sbss.*) *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > RAM
    _end = .;
    end = .;

    __stack_top  = 0xF0000;
    __heap_limit = 0xE0000;   /* 64 KB of stack below __stack_top */
}

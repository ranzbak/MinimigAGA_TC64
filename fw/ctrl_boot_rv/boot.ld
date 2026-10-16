/* Boot ROM: everything inside the 8 KB boot BRAM (0x0-0x1FFF).  The BRAM is
   initialised RAM, so .data stays in place (no copy).  Stack top is 0x2000;
   the ASSERT keeps at least 1 KB of stack. */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
	ram (rwx) : ORIGIN = 0x00000000, LENGTH = 0x2000
}

SECTIONS
{
	.text : {
		KEEP(*(.text.start))
		*(.text .text.*)
		*(.rodata .rodata.* .srodata .srodata.*)
		. = ALIGN(4);
	} > ram

	.data : {
		*(.data .data.*)
		*(.sdata .sdata.*)
		. = ALIGN(4);
	} > ram
	__global_pointer$ = ADDR(.data) + 0x800;

	.bss (NOLOAD) : {
		__bss_start = .;
		*(.sbss .sbss.* .bss .bss.* COMMON)
		. = ALIGN(4);
		_end = .;
	} > ram

	/DISCARD/ : { *(.comment) *(.eh_frame) *(.note*) }

	ASSERT(boot_trap == 0x20, "boot ROM: boot_trap must sit at 0x20")
	ASSERT(_end <= 0x1C00, "boot ROM: text+data+bss leave less than 1 KB of stack")
}

/* OSD firmware for the RISC-V host CPU (VexRiscv RV32IMC).
 *
 * The boot ROM (fw/ctrl_boot) loads RV32OSDA.BIN, the flat binary of this
 * image (objcopy -O binary), to 0x2000 and jumps there; so _start (crt0.S,
 * section .text.start) must be the first byte.  The image is loaded into
 * RAM as a whole: .data stays where it is linked (no copy), .bss is cleared
 * by crt0.  The stack starts at 0x2000 and grows down into the 8 KB boot
 * BRAM.  The image must end below 0x70000 (AUDIO_BUFFER).
 *
 *   0x00002000  .text      _start first, then all code
 *               .rodata
 *               .init_array  constructors, run by crt0 in priority order
 *               .data, .sdata
 *               .sbss, .bss  (NOLOAD, cleared by crt0)
 *   _end        < 0x70000
 *
 * Symbols for crt0.S: __stack_top, __global_pointer$, __bss_start,
 * __bss_end, __init_array_start, __init_array_end. */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    ram (rwx) : ORIGIN = 0x00002000, LENGTH = 0x00070000 - 0x00002000
}

SECTIONS
{
    .text : {
        KEEP(*(.text.start))
        *(.text .text.*)
    } > ram

    .rodata : {
        . = ALIGN(4);
        *(.rodata .rodata.* .srodata .srodata.*)
        . = ALIGN(4);
    } > ram

    .init_array : {
        __init_array_start = .;
        KEEP(*(SORT_BY_INIT_PRIORITY(.init_array.*)))
        KEEP(*(.init_array))
        __init_array_end = .;
    } > ram

    .data : {
        . = ALIGN(4);
        *(.data .data.*)
        . = ALIGN(4);
        __sdata_start = .;
        *(.sdata .sdata.*)
        . = ALIGN(4);
    } > ram

    /* gp-relative accesses reach __sdata_start .. __sdata_start + 4 KB */
    __global_pointer$ = __sdata_start + 0x800;

    .bss (NOLOAD) : {
        . = ALIGN(4);
        __bss_start = .;
        *(.sbss .sbss.* .bss .bss.* COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > ram

    _end = .;
    __stack_top = 0x2000;

    /DISCARD/ : { *(.comment) *(.eh_frame) *(.eh_frame_hdr) *(.note*) }

    ASSERT(_start == 0x2000, "firmware.ld: _start must be the first byte at 0x2000")
    ASSERT(_end < 0x70000, "firmware.ld: the image reaches AUDIO_BUFFER (0x70000)")
}

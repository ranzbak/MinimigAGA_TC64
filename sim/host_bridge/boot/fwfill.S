/* fw_fill: 1280 bytes of .rodata for the L2 boot firmware (fwtest.c).  It
 * makes the image span three 1 KB FAT clusters, and it is part of the IMG
 * word sum, so a cluster loaded from the wrong place changes the sum.
 * Word n = (n << 16) | (n ^ 0x5A5A): no two words alike, no byte order
 * symmetric. */
    .section .rodata.fw_fill, "a"
    .globl  fw_fill
    .balign 4
fw_fill:
    .set    n, 0
    .rept   320
    .word   (n << 16) | (n ^ 0x5A5A)
    .set    n, n + 1
    .endr
    .size   fw_fill, . - fw_fill

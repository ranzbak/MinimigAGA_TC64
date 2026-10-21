/* L1 stand-in for the boot ROM, for programs linked as firmware
 * (fw/ctrl/arch/firmware.ld, _start at 0x2000).  The Makefile pads this to
 * 0x2000 bytes and puts the firmware image after it, so the bench image looks
 * like the real machine after the boot ROM has loaded the firmware:
 *   0x0000  reset vector
 *   0x0020  trap entry until the firmware's crt0 installs its own mtvec:
 *           DONE = 0x8000 | mcause[31] << 8 | mcause[7:0]
 *   ....    zero x1-x31, jump to 0x2000 (the firmware's _start)
 * Zeroing the registers stands in for the boot ROM having run: the simulated
 * register file starts as X, and a prologue that saves an unused register
 * would put X on the bus (the bus checker flags X write data). */
#include "l1.h"

    .section .text, "ax"
    .globl _reset
_reset:
    j       boot

    .org    0x20
_trap_boot:
    csrr    t0, mcause
    andi    t1, t0, 0xff
    srli    t0, t0, 31
    slli    t0, t0, 8
    or      t0, t0, t1
    li      t1, 0x8000
    or      t0, t0, t1
    sw      t0, L1_DONE_OFS(zero)
1:  j       1b

boot:
    .irp r, 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30
    li      x\r, 0
    .endr
    li      x31, 0x2000
    jr      x31

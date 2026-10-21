/* L2 boot-ROM stand-in for fw/dhrystone_rv (test "dhry"): the firmware image
 * is preloaded into the SDRAM model (+SDRAM_HEX, fw/dhrystone_rv l2_*.hex,
 * byte 0x2000 = _start); the ROM clears x1-x31 and jumps there, as the real
 * boot ROM (fw/ctrl_boot_rv/crt0.S clears them at reset) does after loading
 * RV32OSDA.BIN.  The simulated register file starts as X; a firmware
 * prologue that saves an unused register would put X on the bus.
 *   0x0000  reset vector: jump to the register clear
 *   0x0020  trap entry until crt0 installs its own: DONE = 0x8000 | mcause
 *   crt0    zero x1-x31, lui t0,2 ; jr t0 */
#include "hb.h"

    .section .text.reset, "ax"
    .globl _reset
_reset:
    j       _clear

    .section .text.trap, "ax"
    .globl _trap
_trap:
    csrr    t0, mcause
    andi    t1, t0, 0xff
    srli    t0, t0, 31
    slli    t0, t0, 8
    or      t0, t0, t1
    li      t1, 0x8000
    or      t0, t0, t1
    sw      t0, HB_DONE_OFS(zero)
1:  j       1b

    .section .text.crt0, "ax"
_clear:
    .irp r, 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    li      x\r, 0
    .endr
    lui     t0, 2                   /* 0x2000 */
    jr      t0

/* L2 boot-ROM stand-in for fw/dhrystone_rv (test "dhry"): the firmware image
 * is preloaded into the SDRAM model (+SDRAM_HEX, fw/dhrystone_rv l2_*.hex,
 * byte 0x2000 = _start); the ROM only jumps there, as the real boot ROM does
 * after loading RV32OSDA.BIN.  No register clear: run.sh starts the simulated
 * register file at 0 (its VexOsd.v copy), like the FPGA's.
 *   0x0000  reset vector: lui t0,2 ; jr t0
 *   0x0020  trap entry until crt0 installs its own: DONE = 0x8000 | mcause */
#include "hb.h"

    .section .text.reset, "ax"
    .globl _reset
_reset:
    lui     t0, 2                   /* 0x2000 */
    jr      t0

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

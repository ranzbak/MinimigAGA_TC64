/* L2 boot-ROM start-up for tests linked with the firmware start-up
 * (fw/ctrl/arch/crt0.S, _start) instead of sw/crt0_rom.S:
 *   0x0000  reset vector: jump to the register clear
 *   0x0020  trap entry until crt0 installs trap_entry (mtvec reset value):
 *           DONE = 0x8000 | mcause[31] << 8 | mcause[7:0], as crt0_rom.S
 *   crt0    zero x1-x31 (the simulated register file starts as X; the
 *           firmware's crt0 does not do this, the boot ROM runs before it
 *           on the real machine), then jump to _start.
 * Such a test's main() reports PASS/FAIL and writes DONE itself: the
 * firmware crt0 spins when main returns. */
#include "hb.h"

    .section .text.reset, "ax"
    .globl _reset
_reset:
    j       _fwboot

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
_fwboot:
    .irp r, 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    li      x\r, 0
    .endr
    j       _start

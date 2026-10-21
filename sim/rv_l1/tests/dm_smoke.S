/* dm_smoke: the program the debug smoke test (tests/dm_smoke.v, run.sh
 * dm_smoke, DEBUG=2) halts, inspects and resumes over JTAG.
 *
 *   a2 (x12) = boot count: DM_BOOTS + 1 at every start (memory survives a
 *              core reset, so it is 2 after a dmcontrol.ndmreset)
 *   a0 (x10) = loop counter, from 0, +1 per iteration, stored to DM_CNT
 *              after each increment (the bench compares the register it
 *              reads over the DM with this word)
 *   a1 (x11) = stop value, 0 at start; the debugger writes it with an
 *              abstract command.  The loop ends when a0 == a1: main
 *              returns 0, crt0 writes DONE 0 (=== PASS).
 *
 * Without a debugger the run never ends (TIMEOUT): a1 = 0 is reached only
 * after 2^32 iterations.
 * DM_CNT / DM_BOOTS are fixed (.at4000) so the bench knows them:
 *   DM_CNT = 0x4000, DM_BOOTS = 0x4004 (tests/dm_smoke.v). */
#include "l1.h"

    .section .text.entry, "ax"
    .globl main
main:
    li      t0, 0x4000          /* DM_CNT; DM_BOOTS = 4(t0) */
    lw      a2, 4(t0)
    addi    a2, a2, 1
    sw      a2, 4(t0)
    li      a1, 0
    li      a0, 0
1:  addi    a0, a0, 1
    sw      a0, 0(t0)
    bne     a0, a1, 1b
    li      a0, 0
    ret

    .section .at4000, "aw"
    .globl dm_cnt, dm_boots
dm_cnt:   .word 0
dm_boots: .word 0

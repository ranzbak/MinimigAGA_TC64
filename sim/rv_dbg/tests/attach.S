/* attach: the program the OpenOCD attach runs (run.sh attach1/attach2)
 * halt and resume.  Counts forever: a0 (x10) from 0, +1 per iteration,
 * stored to 0x4000 (attach_cnt).  It never writes DONE, so the run ends by
 * the debugger's disconnect (+exit_on_disconnect) or the harness timeout.
 * run.sh checks that the PC OpenOCD reads after "halt" lies in
 * [attach_loop, attach_loop_end) (symbols from build/attach.elf). */
#include "l1.h"

    .section .text.entry, "ax"
    .globl main, attach_loop, attach_loop_end
main:
    li      t0, 0x4000
    li      a0, 0
attach_loop:
    addi    a0, a0, 1
    sw      a0, 0(t0)
    j       attach_loop
attach_loop_end:

    .section .at4000, "aw"
    .globl attach_cnt
attach_cnt: .word 0

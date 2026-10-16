/* L1 bench start-up: reset vector at 0x0, default trap at 0x20 (mtvec reset
 * value), stack at the top of the 1 MB model, .bss cleared, main() called,
 * its return value written to DONE (0 = PASS). */
#include "l1.h"

    .section .text.reset, "ax"
    .globl _reset
_reset:
    j       _crt0

/* Unexpected trap: DONE = 0x8000 | mcause[31] << 8 | mcause[7:0]. */
    .section .text.trap, "ax"
    .globl _trap_default
_trap_default:
    csrr    t0, mcause
    andi    t1, t0, 0xff
    srli    t0, t0, 31
    slli    t0, t0, 8
    or      t0, t0, t1
    li      t1, 0x8000
    or      t0, t0, t1
    sw      t0, L1_DONE_OFS(zero)
1:  j       1b

    .section .text.crt0, "ax"
_crt0:
    /* zero x1-x31: the simulated register file starts as X, and a
       prologue that saves an unused callee-saved register would put X on
       the bus (the bus checker flags X write data) */
    .irp r, 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31
    li      x\r, 0
    .endr
    la      sp, __stack_top
    la      t0, __bss_start
    la      t1, __bss_end
1:  bgeu    t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:  call    main
    sw      a0, L1_DONE_OFS(zero)
3:  j       3b

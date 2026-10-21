/* irq: the cfide-like INTERRUPT register -> irq_ext -> rv_hostcpu register
 * -> externalInterrupt (mip.MEIP) -> trap entry.
 *   1. enable = 0: an IRQ_AT event must not pend (no trap)
 *   2. enable = 1: an IRQ_AT event traps once with mcause = 0x8000000B; the
 *      handler's access to INTERRUPT clears the pending line, so it does
 *      not re-enter
 * Exit code: 0 = pass, 1 = trap while disabled, 2 = no trap, 3 = trap count
 * not 1, 4 = wrong mcause. */
#include "l1.h"

    .section .text.entry, "ax"
    .globl main
main:
    la      t0, handler
    csrw    mtvec, t0
    li      t0, 0x800               /* mie.MEIE */
    csrs    mie, t0
    csrsi   mstatus, 8              /* mstatus.MIE */

    /* 1: disabled */
    sh      zero, L1_INTR_OFS(zero)
    li      t0, 20
    sh      t0, L1_IRQAT_OFS(zero)
    li      t1, 300
1:  addi    t1, t1, -1
    bnez    t1, 1b
    lw      t2, count
    li      a0, 1
    bnez    t2, out

    /* 2: enabled */
    li      t0, 1
    sh      t0, L1_INTR_OFS(zero)
    li      t0, 50
    sh      t0, L1_IRQAT_OFS(zero)
    li      t1, 20000
2:  lw      t2, count
    bnez    t2, 3f
    addi    t1, t1, -1
    bnez    t1, 2b
    li      a0, 2
    j       out
3:  li      t1, 300                 /* time for a (wrong) second entry */
4:  addi    t1, t1, -1
    bnez    t1, 4b
    lw      t2, count
    li      t3, 1
    li      a0, 3
    bne     t2, t3, out
    lw      t2, cause
    li      t3, 0x8000000B
    li      a0, 4
    bne     t2, t3, out
    li      a0, 0
out:
    csrci   mstatus, 8
    ret

    .balign 4
handler:
    addi    sp, sp, -8
    sw      t0, 0(sp)
    sw      t1, 4(sp)
    lhu     t0, L1_INTR_OFS(zero)   /* any access clears the pending line */
    csrr    t0, mcause
    la      t1, cause
    sw      t0, 0(t1)
    la      t1, count
    lw      t0, 0(t1)
    addi    t0, t0, 1
    sw      t0, 0(t1)
    lw      t0, 0(sp)
    lw      t1, 4(sp)
    addi    sp, sp, 8
    mret

    .section .bss
    .balign 4
count:  .space 4
cause:  .space 4

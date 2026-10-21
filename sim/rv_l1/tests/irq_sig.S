/* irq_sig: the firmware trap entry (fw/ctrl_rv/arch/trap.S) keeps every
 * register of the interrupted code.
 *
 * x1 and x3..x31 hold distinct patterns PAT(n); sp is the stack.  Each loop
 * iteration checks them in two halves: first x1, x3..x30 with x31 as the
 * scratch register, then x31 holds PAT(31) and x1, x3..x29, x31 are checked
 * with x30 as the scratch; then x30 holds PAT(30) again and x31 is the scratch
 * of the event count.  So every register, x31 (t6) included, holds its
 * pattern while traps arrive for part of the loop, and a trap between a
 * check's load of PAT(n) into the scratch and its compare fails the check
 * too if it changes the scratch.
 * 50 interrupt events arrive at pseudo-random distances: main arms the first
 * one, the C handler (tests/irq_sig_h.c, installed with SetIntHandler) counts,
 * clears the line with GetInterrupts(), arms the next one with IRQ_AT 20..275
 * cycles ahead and calls sig_trash, which overwrites every caller-saved
 * register (t0-t6, a0-a7) as any C handler may.  After the 50th event the
 * loop runs AFTER more iterations: the count must stay 50.
 * Linked with --no-relax so that no C code addresses through gp, which holds
 * a pattern here like the others.
 * Exit code: 0 = pass, 0x100 + n = register xn changed (0x101..0x11f), 2 = fewer than 50
 * events within ITER_MAX iterations, 3 = more than 50 events. */
#include "l1.h"

#define PAT(r)   (0xA5000000 | ((r) << 16) | (((r) ^ 0xff) << 8) | (r))
#define NEV      50          /* = SIG_NEV in irq_sig_h.c */
#define ITER_MAX 200000
#define AFTER    64

    /* CHK r, s: register x<r> still holds PAT(r) (x<s> is the scratch),
       else exit 0x100 + r */
    .macro CHK r, s
    li      x\s, PAT(\r)
    beq     x\r, x\s, 1f
    li      x31, 0x100 + \r
    j       fail
1:
    .endm

    .section .text.entry, "ax"
    .globl main
main:
    la      a0, sig_handler
    call    SetIntHandler
    call    EnableInterrupts
    addi    sp, sp, -16
    li      t0, ITER_MAX
    sw      t0, 0(sp)               /* iterations left until count = NEV */
    li      t0, AFTER
    sw      t0, 4(sp)               /* iterations after count = NEV */
    li      t0, 100
    sw      t0, L1_IRQAT_OFS(zero)  /* first event; the handler arms the rest */

    .irp r, 1,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30
    li      x\r, PAT(\r)
    .endr

loop:
    .irp r, 1,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30
    CHK     \r, 31
    .endr
    li      x31, PAT(31)            /* second half: x31 holds a pattern */
    .irp r, 1,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,31
    CHK     \r, 30
    .endr
    li      x30, PAT(30)            /* x31 is the scratch again */
    lw      x31, sig_count
    addi    x31, x31, -NEV
    beqz    x31, 5f
    bgtz    x31, 3f
    lw      x31, 0(sp)
    addi    x31, x31, -1
    sw      x31, 0(sp)
    bnez    x31, loop
    li      x31, 2
    j       fail
3:  li      x31, 3
    j       fail
5:  lw      x31, 4(sp)
    addi    x31, x31, -1
    sw      x31, 4(sp)
    bnez    x31, loop
    li      x31, 0
fail:
    sw      x31, L1_DONE_OFS(zero)
6:  j       6b

/* sig_trash: overwrite every caller-saved register but ra (C ABI: a callee
 * may), so a trap entry that does not restore one of them is caught. */
    .text
    .globl sig_trash
sig_trash:
    .irp r, 5,6,7,10,11,12,13,14,15,16,17,28,29,30,31
    li      x\r, 0xDEAD0000 + \r
    .endr
    ret

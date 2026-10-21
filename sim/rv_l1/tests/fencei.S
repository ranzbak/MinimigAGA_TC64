/* fencei: self-modifying code needs fence.i (plan 3.4).
 * Copy "li a0, 1; nop; nop; ret" to 0x6000 through dBus stores, call it
 * (the I$ line is filled), overwrite it with "li a0, 2; ...", fence.i, call
 * again -> 2.  Built with -DNO_FENCEI (fencei_nofencei) the stale I$ line
 * still returns 1: that variant must end with "=== FAIL 1" (teeth).
 * 0x6000 is I$ line index 0; nothing that runs between the two calls may
 * sit on index 0 (0x2000 does), hence the jump over the first 64 bytes.
 * Exit code: 0 = pass, 1 = stale line, 0x10 + a0 = first call wrong,
 * 0x30 = second call returned something else. */
#include "l1.h"

#define DST 0x6000

    .section .text.entry, "ax"
    .globl main
main:
    j       1f
    .balign 64
1:  addi    sp, sp, -16
    sw      ra, 12(sp)

    la      a0, tmpl1
    call    copy16
    li      t0, DST
    jalr    ra, 0(t0)
    li      t1, 1
    bne     a0, t1, bad1

    la      a0, tmpl2
    call    copy16
#ifndef NO_FENCEI
    fence.i
#endif
    li      t0, DST
    jalr    ra, 0(t0)
    li      t1, 2
    beq     a0, t1, pass
    li      t1, 1
    beq     a0, t1, out             /* stale line: exit code 1 */
    li      a0, 0x30
    j       out
bad1:
    addi    a0, a0, 0x10
    j       out
pass:
    li      a0, 0
out:
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret

/* copy the 16-byte routine at a0 to DST */
copy16:
    li      t0, DST
    addi    t2, a0, 16
1:  lw      t1, 0(a0)
    sw      t1, 0(t0)
    addi    a0, a0, 4
    addi    t0, t0, 4
    bne     a0, t2, 1b
    ret

    .section .rodata
    .balign 4
    .option push
    .option norvc
tmpl1:
    addi    a0, zero, 1
    addi    zero, zero, 0
    addi    zero, zero, 0
    jalr    zero, 0(ra)
tmpl2:
    addi    a0, zero, 2
    addi    zero, zero, 0
    addi    zero, zero, 0
    jalr    zero, 0(ra)
    .option pop

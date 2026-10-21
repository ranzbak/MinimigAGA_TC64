/* CHECK reg, val: count the check in s0 and branch to "fail" on mismatch.
 * Exit code of a test = number of the first failing check (s0). */
#ifndef CHECK_H
#define CHECK_H
    .macro CHECK reg, val
    addi    s0, s0, 1
    li      t6, \val
    bne     \reg, t6, fail
    .endm
    /* bench checkpoint: TIME <n> */
    .macro STAMP n
    li      t6, \n
    sw      t6, HB_TIME_OFS(zero)
    .endm
#endif

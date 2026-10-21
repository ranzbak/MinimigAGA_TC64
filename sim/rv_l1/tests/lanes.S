/* lanes: the lane rule end to end.
 * Memory is big endian (byte A+0 in bits 31:24 of the word); the core is
 * little endian; rv_hostcpu swaps the four bytes for addr[23]=0 and passes
 * the hw window (addr[23]=1) through unswapped.
 *   - loads of every width/alignment from 0x4000 (bytes 11 22 33 44 55 66 77 88)
 *   - stores of every width/alignment to 0x5000..0x5023, reloaded here and
 *     dumped by the bench as BE words (run.sh compares with lanes.mem)
 *   - hw window: 16-bit SCRATCH register, unswapped; unmapped register = 0
 * Exit code: 0 = pass, else the number of the failing check. */
#include "l1.h"

    .macro CHECK reg, val
    addi    s0, s0, 1
    li      t6, \val
    bne     \reg, t6, fail
    .endm

    .section .text.entry, "ax"
    .globl main
main:
    li      s0, 0
    li      s1, 0x4000

    /* loads, BE memory -> LE core */
    lbu     t0, 0(s1);  CHECK t0, 0x11          /* 1 */
    lbu     t0, 1(s1);  CHECK t0, 0x22
    lbu     t0, 2(s1);  CHECK t0, 0x33
    lbu     t0, 3(s1);  CHECK t0, 0x44
    lbu     t0, 4(s1);  CHECK t0, 0x55          /* 5 */
    lbu     t0, 5(s1);  CHECK t0, 0x66
    lbu     t0, 6(s1);  CHECK t0, 0x77
    lbu     t0, 7(s1);  CHECK t0, 0x88
    lhu     t0, 0(s1);  CHECK t0, 0x2211
    lhu     t0, 2(s1);  CHECK t0, 0x4433        /* 10 */
    lhu     t0, 4(s1);  CHECK t0, 0x6655
    lhu     t0, 6(s1);  CHECK t0, 0x8877
    lw      t0, 0(s1);  CHECK t0, 0x44332211
    lw      t0, 4(s1);  CHECK t0, 0x88776655
    lb      t0, 7(s1);  CHECK t0, 0xFFFFFF88    /* 15 */
    lh      t0, 6(s1);  CHECK t0, 0xFFFF8877

    /* stores, every width and legal alignment (partial words over a
       pre-written background, so a wrong mask or lane shows) */
    li      s2, 0x5000
    li      t1, -1
    li      t0, 0x12345678; sw t0, 0(s2)
    sw      t1, 4(s2);   li t0, 0xAB;   sb t0, 5(s2)
    sw      t1, 8(s2);   li t0, 0x01;   sb t0, 8(s2)
    sw      t1, 12(s2);  li t0, 0x02;   sb t0, 14(s2)
    sw      t1, 16(s2);  li t0, 0x03;   sb t0, 19(s2)
    sw      zero, 20(s2); li t0, 0xBEEF; sh t0, 20(s2)
    sw      zero, 24(s2); li t0, 0xCAFE; sh t0, 26(s2)
    sw      zero, 28(s2); li t0, 0x5A;   sb t0, 28(s2); li t0, 0xA5; sb t0, 31(s2)
    li      t0, 0x8899AABB; sw t0, 32(s2)

    lw      t0, 0(s2);  CHECK t0, 0x12345678    /* 17 */
    lw      t0, 4(s2);  CHECK t0, 0xFFFFABFF
    lw      t0, 8(s2);  CHECK t0, 0xFFFFFF01
    lw      t0, 12(s2); CHECK t0, 0xFF02FFFF    /* 20 */
    lw      t0, 16(s2); CHECK t0, 0x03FFFFFF
    lw      t0, 20(s2); CHECK t0, 0x0000BEEF
    lw      t0, 24(s2); CHECK t0, 0xCAFE0000
    lw      t0, 28(s2); CHECK t0, 0xA500005A
    lw      t0, 32(s2); CHECK t0, 0x8899AABB    /* 25 */
    lbu     t0, 5(s2);  CHECK t0, 0xAB
    lbu     t0, 31(s2); CHECK t0, 0xA5
    lbu     t0, 30(s2); CHECK t0, 0x00
    lhu     t0, 20(s2); CHECK t0, 0xBEEF
    lhu     t0, 26(s2); CHECK t0, 0xCAFE        /* 30 */
    lh      t0, 26(s2); CHECK t0, 0xFFFFCAFE

    /* hw window: 16-bit, value in bits 15:0, no swap */
    li      t0, 0x1234
    sh      t0, L1_SCRATCH_OFS(zero)
    lhu     t0, L1_SCRATCH_OFS(zero); CHECK t0, 0x1234      /* 32 */
    lw      t0, L1_SCRATCH_OFS(zero); CHECK t0, 0x00001234
    li      t0, 0x56
    sb      t0, L1_SCRATCH_OFS(zero)                        /* low byte only */
    lhu     t0, L1_SCRATCH_OFS(zero); CHECK t0, 0x1256
    li      t0, 0xABCD9876
    sw      t0, L1_SCRATCH_OFS(zero)
    lhu     t0, L1_SCRATCH_OFS(zero); CHECK t0, 0x9876      /* 35 */
    lhu     t0, -208(zero);           CHECK t0, 0           /* 0xFFFFFF30 unmapped */

    li      a0, 0
    ret
fail:
    mv      a0, s0
    ret

    .section .at4000, "aw"
    .byte   0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88

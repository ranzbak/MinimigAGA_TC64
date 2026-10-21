/* t_lanes: byte lanes end to end through the real bridge, hostcache and an
 * SDRAM model with sdram_ctrl's lanes (sel[0] -> q[31:24] -> upper byte of
 * the lower halfword), and through the boot BRAM.
 *   1-16   loads of every width/alignment from SDRAM 0x4000 (preloaded by
 *          the bench from sw/t_lanes.sdram.hex: bytes 11 22 .. 88)
 *   17-32  the same loads from .rodata in the boot BRAM (romgen image)
 *   33-     stores of every width/alignment to SDRAM 0x3000.. and to the
 *          boot BRAM 0x1800.., read back through the CPU (the SDRAM reads
 *          miss hostcache: a write invalidates the line)
 * The bench then checks the SDRAM model's halfwords at 0x3000..0x301F
 * (tb_host_bridge.v, TEST=t_lanes).  Exit code: 0 or the failing check. */
#include "hb.h"
#include "check.h"

    /* loads from \b: bytes 11 22 33 44 55 66 77 88 (BE memory, LE core) */
    .macro LOADS b
    lbu     t0, 0(\b);  CHECK t0, 0x11
    lbu     t0, 1(\b);  CHECK t0, 0x22
    lbu     t0, 2(\b);  CHECK t0, 0x33
    lbu     t0, 3(\b);  CHECK t0, 0x44
    lbu     t0, 4(\b);  CHECK t0, 0x55
    lbu     t0, 5(\b);  CHECK t0, 0x66
    lbu     t0, 6(\b);  CHECK t0, 0x77
    lbu     t0, 7(\b);  CHECK t0, 0x88
    lhu     t0, 0(\b);  CHECK t0, 0x2211
    lhu     t0, 2(\b);  CHECK t0, 0x4433
    lhu     t0, 4(\b);  CHECK t0, 0x6655
    lhu     t0, 6(\b);  CHECK t0, 0x8877
    lw      t0, 0(\b);  CHECK t0, 0x44332211
    lw      t0, 4(\b);  CHECK t0, 0x88776655
    lb      t0, 7(\b);  CHECK t0, 0xFFFFFF88
    lh      t0, 6(\b);  CHECK t0, 0xFFFF8877
    .endm

    /* stores to \b..\b+0x1F; partial stores over a known background, so a
       wrong mask or lane shows */
    .macro STORES b
    li      t1, -1
    li      t0, 0x12345678; sw t0, 0(\b)
    li      t0, 0xAB;       sb t0, 3(\b)
    sw      t1, 4(\b);   li t0, 0x01;   sb t0, 4(\b)
    sw      t1, 8(\b);   li t0, 0x02;   sb t0, 9(\b)
    sw      t1, 12(\b);  li t0, 0x03;   sb t0, 14(\b)
    sw      zero, 16(\b); li t0, 0xBEEF; sh t0, 16(\b)
    sw      zero, 20(\b); li t0, 0xCAFE; sh t0, 22(\b)
    li      t0, 0x8899AABB; sw t0, 24(\b)
    li      t0, 0x11; sb t0, 28(\b)
    li      t0, 0x22; sb t0, 29(\b)
    li      t0, 0x33; sb t0, 30(\b)
    li      t0, 0x44; sb t0, 31(\b)
    .endm

    .macro READBACK b
    lw      t0, 0(\b);  CHECK t0, 0xAB345678
    lw      t0, 4(\b);  CHECK t0, 0xFFFFFF01
    lw      t0, 8(\b);  CHECK t0, 0xFFFF02FF
    lw      t0, 12(\b); CHECK t0, 0xFF03FFFF
    lw      t0, 16(\b); CHECK t0, 0x0000BEEF
    lw      t0, 20(\b); CHECK t0, 0xCAFE0000
    lw      t0, 24(\b); CHECK t0, 0x8899AABB
    lw      t0, 28(\b); CHECK t0, 0x44332211
    lbu     t0, 3(\b);  CHECK t0, 0xAB
    lbu     t0, 0(\b);  CHECK t0, 0x78
    lhu     t0, 2(\b);  CHECK t0, 0xAB34
    lhu     t0, 16(\b); CHECK t0, 0xBEEF
    lhu     t0, 22(\b); CHECK t0, 0xCAFE
    lh      t0, 22(\b); CHECK t0, 0xFFFFCAFE
    lbu     t0, 9(\b);  CHECK t0, 0x02
    lb      t0, 31(\b); CHECK t0, 0x44
    .endm

    .text
    .globl main
main:
    li      s0, 0
    li      s1, 0x4000
    LOADS   s1                          /* 1-16  SDRAM read lanes */
    la      s1, pattern
    LOADS   s1                          /* 17-32 boot BRAM read lanes */
    li      s2, 0x3000
    STORES  s2
    READBACK s2                         /* 33-48 SDRAM */
    li      s2, 0x1800
    STORES  s2
    READBACK s2                         /* 49-64 boot BRAM */
    li      a0, 0
    ret
fail:
    mv      a0, s0
    ret

    .section .rodata
    .balign 4
pattern:
    .byte   0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88

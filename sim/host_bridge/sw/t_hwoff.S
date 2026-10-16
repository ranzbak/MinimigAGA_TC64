/* t_hwoff: cfide register offsets through the bridge (addr[23] = 1: 16-bit
 * registers in bits 15:0, no lane swap).  STAMP n = bench checkpoint n
 * (tb_host_bridge.v, TEST=t_hwoff), which checks cfide's output pins.
 *   PLATFORM 0xFFFFFFC0  read = platformdata (0x0003 here); write bit 0 ->
 *                        scandoubler pin (STAMP 1, 2)
 *   AUDIO    0xFFFFFFB0  write bit 0 -> audio_ena, bit 1 -> audio_clear
 *                        (STAMP 3-5); read = {audio_amiga, audio_buf} = 1
 *   TIMER    0xFFFFFFD0  two reads: it advances by one (the bench's tick_in
 *                        counts every clk_28: one step per 1024 clk_114)
 *   SPI      CS 0x02 -> sd_cs = 0xFC (STAMP 6); DATA write 0x5A -> the
 *                        bench's slave captures 0x5A (STAMP 7); DATA read ->
 *                        the slave's first scripted MISO byte 0xA5; CS 0x03
 *                        -> sd_cs = 0xFF (STAMP 8)
 * Exit code: 0 or the failing check. */
#include "hb.h"
#include "check.h"

    .text
    .globl main
main:
    li      s0, 0
    /* PLATFORM read, halfword and byte */
    lhu     t0, HB_PLATFORM_OFS(zero);  CHECK t0, HB_PLATFORM_VAL      /* 1 */
    lbu     t0, HB_PLATFORM_OFS(zero);  CHECK t0, HB_PLATFORM_VAL      /* 2 */
    lw      t0, HB_PLATFORM_OFS(zero);  CHECK t0, HB_PLATFORM_VAL      /* 3 */
    /* PLATFORM write -> scandoubler */
    sh      zero, HB_PLATFORM_OFS(zero)
    STAMP   1
    li      t0, 1
    sh      t0, HB_PLATFORM_OFS(zero)
    STAMP   2
    /* AUDIO write -> audio_ena / audio_clear, read -> {audio_amiga, audio_buf} */
    li      t0, 1
    sh      t0, HB_AUDIO_OFS(zero)
    STAMP   3
    li      t0, 2
    sh      t0, HB_AUDIO_OFS(zero)
    STAMP   4
    sh      zero, HB_AUDIO_OFS(zero)
    STAMP   5
    lhu     t0, HB_AUDIO_OFS(zero);     CHECK t0, 1                    /* 4 */
    /* TIMER: poll until it changes (at most 0x4000 reads), step = 1 */
    lhu     t1, HB_TIMER_OFS(zero)
    li      t3, 0x4000
1:  lhu     t2, HB_TIMER_OFS(zero)
    bne     t2, t1, 2f
    addi    t3, t3, -1
    bnez    t3, 1b
2:  sub     t0, t2, t1;                 CHECK t0, 1                    /* 5 */
    /* SPI */
    li      t0, HB_CS1_ON
    sb      t0, HB_SPI_CS_OFS(zero)
    STAMP   6
    li      t0, 0x5A
    sb      t0, HB_SPI_DATA_OFS(zero)
    lbu     t0, HB_SPI_DATA_OFS(zero)   /* waits for the transfer to end */
    STAMP   7
    CHECK   t0, 0xA5                                                   /* 6 */
    li      t0, HB_CS1_OFF
    sb      t0, HB_SPI_CS_OFS(zero)
    STAMP   8
    li      a0, 0
    ret
fail:
    mv      a0, s0
    ret

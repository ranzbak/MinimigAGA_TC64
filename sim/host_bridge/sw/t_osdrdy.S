/* t_osdrdy: cfide's HOST_REQ register (0xFFFFFFB4, bit 0 OSD_RDY), the OSD
 * reply-ready handshake.  OSD_RDY = 1 when cfide's count of the SPI bytes it
 * started with the OSD selected (sd_cs[5]) equals userio_osd's osd_rx_seq,
 * which the bench drives here (TEST=t_osdrdy: STAMP 10..13 set it to 0..3).
 * cfide resyncs its count to osd_rx_seq once the OSD has been deselected for
 * 64 clk_114 cycles.  SPI at the reset speed; every DATA write is followed by
 * a DATA read, which waits for the byte to end.
 *   1      after reset: OSD_RDY 1 (both counts 0)
 *   2      a byte with sd_cs[1] selected (not the OSD) is not counted
 *   3-8    a byte with the OSD selected: 0 until the bench steps osd_rx_seq
 *          (STAMP 11, check 8); meanwhile 0xFFFFFFB0 (half and byte), B8 and
 *          BC still read audio_q (the bench's audio_buf = 1: 0x0001)
 *   9-11   two bytes outstanding read 0, also with one of them taken (STAMP
 *          12), 1 with both (STAMP 13)
 *   12-14  a byte userio_osd never takes (osd_rx_seq stays 3): 0, still 0
 *          right after the deselect, 1 again after the resync (STAMP 20 / 21:
 *          the bench checks that it took at least 64 cycles)
 *   15-17  counting goes on from the resynced value: one byte, 0; STAMP 10
 *          (osd_rx_seq 3 -> 0), 1; HOST_REQ read as a byte and as a word
 * Exit code: 0 or the failing check. */
#include "hb.h"
#include "check.h"

    .text
    .globl main
main:
    li      s0, 0
    lhu     t0, HB_HOST_REQ_OFS(zero);  CHECK t0, 1                    /* 1 */
    /* a byte to sd_cs[1]: the OSD is not selected, not counted */
    li      t0, HB_CS1_ON
    sb      t0, HB_SPI_CS_OFS(zero)
    li      t0, 0x5A
    sb      t0, HB_SPI_DATA_OFS(zero)
    lbu     t0, HB_SPI_DATA_OFS(zero)
    li      t0, HB_CS1_OFF
    sb      t0, HB_SPI_CS_OFS(zero)
    lhu     t0, HB_HOST_REQ_OFS(zero);  CHECK t0, 1                    /* 2 */
    /* one OSD byte */
    li      t0, HB_OSD_ON
    sb      t0, HB_SPI_CS_OFS(zero)
    li      t0, 0x88
    sb      t0, HB_SPI_DATA_OFS(zero)
    lbu     t0, HB_SPI_DATA_OFS(zero)
    lhu     t0, HB_HOST_REQ_OFS(zero);  CHECK t0, 0                    /* 3 */
    lhu     t0, HB_AUDIO_OFS(zero);     CHECK t0, 1                    /* 4 */
    lbu     t0, HB_AUDIO_OFS(zero);     CHECK t0, 1                    /* 5 */
    lhu     t0, HB_AUDIO8_OFS(zero);    CHECK t0, 1                    /* 6 */
    lhu     t0, HB_AUDIOC_OFS(zero);    CHECK t0, 1                    /* 7 */
    STAMP   11
    lhu     t0, HB_HOST_REQ_OFS(zero);  CHECK t0, 1                    /* 8 */
    /* two bytes outstanding */
    sb      zero, HB_SPI_DATA_OFS(zero)
    lbu     t0, HB_SPI_DATA_OFS(zero)
    sb      zero, HB_SPI_DATA_OFS(zero)
    lbu     t0, HB_SPI_DATA_OFS(zero)
    lhu     t0, HB_HOST_REQ_OFS(zero);  CHECK t0, 0                    /* 9 */
    STAMP   12
    lhu     t0, HB_HOST_REQ_OFS(zero);  CHECK t0, 0                    /* 10 */
    STAMP   13
    lhu     t0, HB_HOST_REQ_OFS(zero);  CHECK t0, 1                    /* 11 */
    /* a byte that is never taken: the resync heals it */
    sb      zero, HB_SPI_DATA_OFS(zero)
    lbu     t0, HB_SPI_DATA_OFS(zero)
    lhu     t0, HB_HOST_REQ_OFS(zero);  CHECK t0, 0                    /* 12 */
    STAMP   20
    li      t0, HB_OSD_OFF
    sb      t0, HB_SPI_CS_OFS(zero)
    lhu     t0, HB_HOST_REQ_OFS(zero);  CHECK t0, 0                    /* 13 */
    li      t1, 64                      /* at most 64 reads (several hundred cycles) */
1:  lhu     t0, HB_HOST_REQ_OFS(zero)
    bnez    t0, 2f
    addi    t1, t1, -1
    bnez    t1, 1b
2:  CHECK   t0, 1                                                      /* 14 */
    STAMP   21
    /* counting goes on from the resynced value (3) */
    li      t0, HB_OSD_ON
    sb      t0, HB_SPI_CS_OFS(zero)
    sb      zero, HB_SPI_DATA_OFS(zero)
    lbu     t0, HB_SPI_DATA_OFS(zero)
    lbu     t0, HB_HOST_REQ_OFS(zero);  CHECK t0, 0                    /* 15 */
    STAMP   10
    lbu     t0, HB_HOST_REQ_OFS(zero);  CHECK t0, 1                    /* 16 */
    lw      t0, HB_HOST_REQ_OFS(zero);  CHECK t0, 1                    /* 17 */
    li      t0, HB_OSD_OFF
    sb      t0, HB_SPI_CS_OFS(zero)
    STAMP   99
    li      a0, 0
    ret
fail:
    mv      a0, s0
    ret

/* t_spibusy: SPI DATA writes while the previous byte is still shifting.
 * SPI_slow() (SPEED = 0xEF: about 7700 clk_114 cycles per byte), select
 * sd_cs[1], then 8 straight-line "sb" to SPI DATA.  cfide only accepts a
 * DATA write (and only acks it) while SD_busy is low, so writes 2-8 wait on
 * the bus.  The bench (TEST=t_spibusy) checks at STAMP 2: the slave got the
 * 8 bytes in order, at least 7 writes found SD_busy high; and in every run:
 * no DATA write completed that cfide did not accept.  The final DATA read
 * returns the slave's 8th scripted MISO byte (0xA5 + 7 * 0x11 = 0x1C).
 * Exit code: 0 or the failing check. */
#include "hb.h"
#include "check.h"

    .text
    .globl main
main:
    li      s0, 0
    li      t0, HB_SPI_SLOW
    sb      t0, HB_SPI_SPEED_OFS(zero)
    li      t0, HB_CS1_ON
    sb      t0, HB_SPI_CS_OFS(zero)
    STAMP   1
    li      t0, 0x01
    li      t1, 0x80
    li      t2, 0x55
    li      t3, 0xAA
    li      t4, 0xFF
    li      t5, 0x00
    li      a1, 0x3C
    li      a2, 0xC3
    sb      t0, HB_SPI_DATA_OFS(zero)
    sb      t1, HB_SPI_DATA_OFS(zero)
    sb      t2, HB_SPI_DATA_OFS(zero)
    sb      t3, HB_SPI_DATA_OFS(zero)
    sb      t4, HB_SPI_DATA_OFS(zero)
    sb      t5, HB_SPI_DATA_OFS(zero)
    sb      a1, HB_SPI_DATA_OFS(zero)
    sb      a2, HB_SPI_DATA_OFS(zero)
    lbu     t0, HB_SPI_DATA_OFS(zero)   /* waits for the last byte */
    STAMP   2
    CHECK   t0, 0x1C                                                   /* 1 */
    li      t0, HB_CS1_OFF
    sb      t0, HB_SPI_CS_OFS(zero)
    STAMP   3
    li      a0, 0
    ret
fail:
    mv      a0, s0
    ret

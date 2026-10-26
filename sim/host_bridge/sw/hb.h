/* L2 host-bridge bench: cfide register map and the bench's snooped addresses.
 * Usable from C and from .S.  Every register is reached with an x0-relative
 * 12-bit offset (the *_OFS values, sign-extended to 0xFFFFFFxx), e.g.
 * "sh t0, HB_PLATFORM_OFS(zero)".  cfide registers are 16 bits wide, value in
 * bits 15:0 of the bus word, no lane swap (addr[23] = 1).
 *
 *   TIME  0xFFFFFF00  W: bench checkpoint <value> (test-specific pin checks)
 *   DONE  0xFFFFFF04  W: end of run, 0 = PASS, else FAIL <code>
 * cfide acks both as unmapped registers; the bench snoops the bridge's bus.
 */
#ifndef HB_H
#define HB_H

#define HB_TIME_OFS      (-256)   /* 0xFFFFFF00 bench checkpoint (W)          */
#define HB_DONE_OFS      (-252)   /* 0xFFFFFF04 bench verdict (W)             */
#define HB_AUDIO_OFS     (-80)    /* 0xFFFFFFB0 W: bit0 audio_ena, bit1 audio_clear; R: {audio_amiga, audio_buf} */
#define HB_HOST_REQ_OFS  (-76)    /* 0xFFFFFFB4 R: bit0 OSD_RDY (OSD reply-ready handshake) */
#define HB_AUDIO8_OFS    (-72)    /* 0xFFFFFFB8 R: audio_q (the AUDIO window, addr(3:2) = 10) */
#define HB_AUDIOC_OFS    (-68)    /* 0xFFFFFFBC R: audio_q (addr(3:2) = 11) */
#define HB_PLATFORM_OFS  (-64)    /* 0xFFFFFFC0 W: bit0 scandoubler; R: platformdata */
#define HB_TIMER_OFS     (-48)    /* 0xFFFFFFD0 R: timecnt[23:8]              */
#define HB_SPI_DATA_OFS  (-32)    /* 0xFFFFFFE0 W: shift a byte out; R: last byte in */
#define HB_SPI_CS_OFS    (-28)    /* 0xFFFFFFE4 W: bit0 = 0 selects, bits 7:1 pick the lines */
#define HB_SPI_SPEED_OFS (-24)    /* 0xFFFFFFE8 W: SPI clock divider          */
#define HB_UART_OFS      (-16)    /* 0xFFFFFFF0 W: character out (8-bit)      */
/* interrupt controller (rtl/host/cfide.vhd, 0x3x window) */
#define HB_IRQ_PENDING_OFS (-208) /* 0xFFFFFF30 R: PENDING & MASK, clears the EDGE bits returned */
#define HB_IRQ_MASK_OFS    (-204) /* 0xFFFFFF34 R/W                           */
#define HB_IRQ_RAW_OFS     (-200) /* 0xFFFFFF38 R: synchronised source levels */
#define HB_IRQ_MODE_OFS    (-196) /* 0xFFFFFF3C R/W: 1 = LEVEL, 0 = EDGE      */

/* SD card peripheral (rtl/host/sdcard_spi.v) through cfide's ext_* port,
   0xFFFFFF00..2C (the windows 0-2).  0x00 (TXW) and 0x04 (TXB) are also the
   bench's TIME and DONE: those writes push bytes into its TX FIFO, which no
   test minds. */
#define HB_SDC_RXLVL_OFS   (-248) /* 0xFFFFFF08 R: RXLVL                       */
#define HB_SDC_TXLVL_OFS   (-244) /* 0xFFFFFF0C R: TXLVL                       */
#define HB_SDC_CMD_OFS     (-240) /* 0xFFFFFF10 W: CMD, R: STATUS              */
#define HB_SDC_IRQ_OFS     (-228) /* 0xFFFFFF1C W: IRQACK, R: IRQPEND          */
#define HB_SDC_CFG_OFS     (-224) /* 0xFFFFFF20 R/W: 7:0 divider, 8 CS        */
#define HB_SDC_TIMEOUT_OFS (-220) /* 0xFFFFFF24 R/W                            */
#define HB_SDC_IRQEN_OFS   (-216) /* 0xFFFFFF28 R/W                            */
#define HB_SDC_VERSION_OFS (-212) /* 0xFFFFFF2C W: WMARK, R: VERSION           */
#define HB_SDC_VERSION     0x5D02
/* cfide's interrupt controller source of the SD peripheral: irq_src(4) */
#define HB_SDC_IRQ_BIT     0x10

/* platformdata with the bench's cfide generics (havespirtc = false) and
   menu_button = 1: X"000" & "0" & '0' & '1' & '1' */
#define HB_PLATFORM_VAL  0x0003
/* SPI CS values: sd_cs[0] and sd_cs[1] low (selected) / high */
#define HB_CS1_ON        0x02
#define HB_CS1_OFF       0x03
/* SPI CS values: the OSD (sd_cs[5]) selected / deselected, as fw EnableOsd() / DisableOsd() */
#define HB_OSD_ON        0x20
#define HB_OSD_OFF       0x21
#define HB_SPI_SLOW      0xEF

#endif

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

/* platformdata with the bench's cfide generics (havespirtc = false) and
   menu_button = 1: X"000" & "0" & '0' & '1' & '1' */
#define HB_PLATFORM_VAL  0x0003
/* SPI CS values: sd_cs[0] and sd_cs[1] low (selected) / high */
#define HB_CS1_ON        0x02
#define HB_CS1_OFF       0x03
#define HB_SPI_SLOW      0xEF

#endif

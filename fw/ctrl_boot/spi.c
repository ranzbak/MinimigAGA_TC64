/* The SD card through the SD card peripheral (rtl/host/sdcard_spi.v: its
   header comment is the contract; register names from fw/ctrl/sdc.h).  The
   boot ROM polls STATUS (nothing else runs at boot; the peripheral's irq
   stays off) and runs one op at a time.  Every op ends by itself: XFER
   after LEN bytes (TX is filled first, RX never fills: 512 + 2 < 1024), the
   wait ops by TIMEOUT, any op at once when the card is gone; so every poll
   loop is bounded by the hardware.  Only reads: init, then CMD17 per
   sector, the block's CRC16 checked by the peripheral (XFER bit 7).

   UART (README "UART lines"): the init steps with their R1, the card type,
   every failed command try and every failed read try. */
#include "spi.h"
#include "uart.h"
#include "small_printf.h"
#include "../ctrl/sdc.h"

/* wait-op bounds, TIMEOUT units of 144.4 us (as fw/ctrl/sdproto.c):
   R1 2.3 ms, read token 250 ms */
#define T_NCR    16
#define T_TOKEN  1732
/* SCK from a read's 3rd try on, for the rest of the boot: 4.1 MHz */
#define DIV_SLOW 13
/* STATUS of a wait op that found no byte */
#define ST_NONE  (SDC_ST_TIMEOUT | SDC_ST_GONE | SDC_ST_REFUSED)

static unsigned char sdhc;		/* block addressing */
static unsigned char div;		/* SCK divider of the reads */

/* one op to its end: STATUS */
static unsigned run(unsigned cmd, unsigned len)
{
	unsigned st;

	SDC_W(SDC_LEN, len);
	SDC_W(SDC_CMD, cmd);
	while ((st = SDC_R(SDC_STATUS)) & SDC_ST_BUSY)
		;
	return st;
}

/* clock FF until a byte that is not FF (MATCH is FF): STATUS, LAST = it */
static unsigned wait_ne(unsigned tmo)
{
	SDC_W(SDC_TIMEOUT, tmo);
	return run(SDC_OP_WAIT_NE, 0);
}

/* CRC7 (x^7 + x^3 + 1) as the command's last byte, (crc << 1) | 1 */
static unsigned crc7(const unsigned char *p, int n)
{
	unsigned c = 0, b;
	int i;

	while (n--) {
		b = *p++;
		for (i = 0; i < 8; i++) {
			c = ((c << 1) ^ ((((c >> 6) ^ (b >> 7)) & 1) ? 0x09 : 0)) & 0x7F;
			b <<= 1;
		}
	}
	return (c << 1) | 1;
}

/* FF, the command, its CRC7; R1, or -1 when 4 tries gave none (no byte in
   T_NCR, card gone) or only R1s with the CRC bit (08).  Each failed try:
   "SD CMD<n>: R1 <r1>, try <t>" (R1 FF: no answer). */
static int cmd(unsigned idx, unsigned long arg)
{
	unsigned char f[7];
	int t, i, r;

	f[0] = 0xFF;
	f[1] = 0x40 | idx;
	f[2] = arg >> 24;
	f[3] = arg >> 16;
	f[4] = arg >> 8;
	f[5] = arg;
	f[6] = crc7(f + 1, 5);
	for (t = 1; t <= 4; t++) {
		for (i = 0; i < 7; i++)
			SDC_W(SDC_TXB, f[i]);
		run(SDC_OP_XFER | SDC_X_TX, 7);
		run(SDC_OP_TX_FLUSH, 0);	/* TX keeps sent bytes: free them */
		r = 0xFF;
		if (!(wait_ne(T_NCR) & ST_NONE)) {
			r = SDC_R(SDC_LAST);
			if ((r & 0x88) != 0x08)
				return r;
		}
		printf("SD CMD%d: R1 %02x, try %d\n", idx, r, t);
	}
	return -1;
}

/* the 4 bytes after an R1 (R7 / OCR) */
static void rx4(unsigned char *p)
{
	int i;

	run(SDC_OP_XFER | SDC_X_RX, 4);
	for (i = 0; i < 4; i++)
		p[i] = SDC_R(SDC_RXB);
}

/* "SD init: <step> <r1>" (FF: no R1) */
static int step(const char *s, int r)
{
	printf("SD init: %s %02x\n", s, r & 0xFF);
	return r;
}

int spi_init(void)
{
	unsigned char r[4];
	unsigned long hcs;
	unsigned v = SDC_R(SDC_VER);
	int n, r1;

	printf("SD init: VERSION %04x, card %d\n", v, (SDC_R(SDC_STATUS) >> 3) & 1);
	if (v != SDC_VERSION)
		return 0;		/* no peripheral (reads 0) or another one */
	run(SDC_OP_ABORT, 0);		/* a re-run of the ROM: the firmware's op */
	SDC_W(SDC_IRQEN, 0);
	run(SDC_OP_RX_FLUSH, 0);
	run(SDC_OP_TX_FLUSH, 0);
	SDC_W(SDC_MATCH, 0xFF);
	SDC_W(SDC_CFG, SDC_DIV_INIT);	/* 400 kHz, CS off */
	run(SDC_OP_XFER, 10);		/* 80 clocks with CS high */
	SDC_W(SDC_CFG, SDC_CFG_CS | SDC_DIV_INIT);
	if (step("CMD0", cmd(0, 0)) != 0x01)
		return 0;
	r1 = step("CMD8", cmd(8, 0x1AA));
	if (r1 == 0x01) {
		rx4(r);
		if (r[2] != 0x01 || r[3] != 0xAA) {
			step("CMD8 echo", r[3]);
			return 0;
		}
		hcs = 1ul << 30;
	} else if (r1 > 0 && r1 < 0x80 && (r1 & 0x04))
		hcs = 0;		/* illegal command: SD v1 */
	else
		return 0;
	n = 5000;			/* >= 0.36 ms per poll at 400 kHz: >= 1.8 s */
	do {
		r1 = cmd(55, 0);
		if (r1 == 0x00 || r1 == 0x01)
			r1 = cmd(41, hcs);
	} while (r1 == 0x01 && --n);
	if (step("ACMD41", r1))
		return 0;
	sdhc = 0;
	if (hcs) {
		if (step("CMD58", cmd(58, 0)))
			return 0;
		rx4(r);
		sdhc = r[0] & 0x40;
	}
	if (step("CMD59", cmd(59, 1)))	/* CRC on */
		return 0;
	if (!sdhc && step("CMD16", cmd(16, 512)))
		return 0;
	puts(sdhc ? "SD card: SDHC\n" : "SD card: SD\n");
	div = SDC_DIV_MIN;
	SDC_W(SDC_CFG, SDC_CFG_CS | SDC_DIV_MIN);
	return 1;
}

/* CMD17, the data token, 512 bytes + CRC16 checked by the peripheral; 4
   tries, from the 3rd on at DIV_SLOW.  Each failed try: "SD read <lba>:
   <what> <value>, try <t>" (R1 <r1>; token <byte> (FF: none in T_TOKEN);
   CRC <STATUS 7:0>). */
int sd_read_sector(unsigned long lba, unsigned char *buf)
{
	const char *what;
	unsigned st, w;
	int t, i, r;

	for (t = 1; t <= 4; t++) {
		what = "R1";
		r = cmd(17, sdhc ? lba : lba << 9);
		if (!r) {
			what = "token";
			st = wait_ne(T_TOKEN);
			r = (st & ST_NONE) ? 0xFF : SDC_R(SDC_LAST);
			if (r == 0xFE) {
				what = "CRC";
				r = run(SDC_OP_XFER | SDC_X_RX | SDC_X_RXCRC, 512);
				if (r & SDC_ST_CRC_OK) {
					for (i = 0; i < 512; i += 2) {
						w = SDC_R(SDC_RXW);	/* first byte in 15:8 */
						buf[i] = w >> 8;
						buf[i + 1] = w;
					}
					return 1;
				}
				run(SDC_OP_RX_FLUSH, 0);	/* poisoned: drop it */
			}
		}
		printf("SD read %u: %s %02x, try %d\n", (unsigned)lba, what, r & 0xFF, t);
		if (t == 2 && div != DIV_SLOW) {
			div = DIV_SLOW;
			SDC_W(SDC_CFG, SDC_CFG_CS | DIV_SLOW);
			printf("SD: SCK div %d\n", DIV_SLOW);
		}
	}
	return 0;
}

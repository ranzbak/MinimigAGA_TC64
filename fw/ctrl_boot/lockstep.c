/* Bitstream / firmware lock-step check (lockstep.h, design 5.5): the boot
   ROM is part of the bitstream, so the peripheral's VERSION register names
   the card path this bitstream has; RV32OSDB.BIN names the one it was built
   for in its trailer.  Different (or no trailer): stop, never run it, and
   say so on the UART, with BootDiag's colour (ErrorCode 0x0ff: cyan) and on
   the OSD. */
#include "lockstep.h"
#include "small_printf.h"
#include "../ctrl/sdc.h"

#ifdef HOSTTEST
/* test/lockstep_test.c: what goes to cfide's SPI (the OSD) */
void hosttest_osd(int what, unsigned char b);	/* 0 select, 1 deselect, 2 a byte, 3 the SPI speed */
#define OSD_ON()     hosttest_osd(0, 0)
#define OSD_OFF()    hosttest_osd(1, 0)
#define OSD_TX(b)    hosttest_osd(2, (b))
#define OSD_FAST()   hosttest_osd(3, 1)
#else
#include "spi.h"
#define OSD_ON()     EnableOsd()
#define OSD_OFF()    DisableOsd()
#define OSD_TX(b)    (HW_SPI(HW_SPI_DATA) = (b))
#define OSD_FAST()   (HW_SPI(HW_SPI_SPEED) = 1)	/* fw/ctrl's SPI_fast(): the OSD takes it */
#endif

/* "FIRMWARE MISMATCH": the glyphs of fw/ctrl/charrom.h (columns 0-6 of
   each, LSB the top pixel; column 7 is 0 in all of them), the message as
   offsets into the table */
static const unsigned char glyph[] = {
	0x00, 0x7f, 0x7f, 0x09, 0x09, 0x01, 0x01,	/*  0 F */
	0x00, 0x00, 0x41, 0x7f, 0x7f, 0x41, 0x00,	/*  7 I */
	0x00, 0x7f, 0x7f, 0x09, 0x19, 0x7f, 0x66,	/* 14 R */
	0x7f, 0x7f, 0x06, 0x0c, 0x06, 0x7f, 0x7f,	/* 21 M */
	0x7f, 0x7f, 0x30, 0x18, 0x30, 0x7f, 0x7f,	/* 28 W */
	0x00, 0x7e, 0x7f, 0x09, 0x09, 0x7f, 0x7e,	/* 35 A */
	0x00, 0x7f, 0x7f, 0x49, 0x49, 0x41, 0x41,	/* 42 E */
	0x00, 0x26, 0x6f, 0x4d, 0x59, 0x7b, 0x32,	/* 49 S */
	0x00, 0x01, 0x01, 0x7f, 0x7f, 0x01, 0x01,	/* 56 T */
	0x00, 0x1c, 0x3e, 0x63, 0x41, 0x41, 0x41,	/* 63 C */
	0x00, 0x7f, 0x7f, 0x08, 0x08, 0x7f, 0x7f,	/* 70 H */
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,	/* 77 space */
};
static const unsigned char msg[LOCKSTEP_OSD_CHARS] = {
	0, 7, 14, 21, 28, 35, 14, 42, 77, 21, 7, 49, 21, 35, 56, 63, 70
};

/* The whole OSD buffer (8 lines of 256 bytes, userio_osd.v: line 0 from the
   write command's 4th data byte on, the address counting on through the
   lines) in one frame: blank, the message from LOCKSTEP_OSD_AT; then the
   OSD on.  Stale menu lines from before a soft restart go too. */
static void osd_mismatch(void)
{
	int i;
	unsigned k;

	OSD_FAST();
	OSD_ON();
	OSD_TX(0x0c);			/* write the OSD buffer: 4 bytes, the 4th line 0 ... */
	for (i = -4; i < 2048; i++) {	/* ... then the 2048 buffer bytes */
		k = (unsigned)(i - LOCKSTEP_OSD_AT);	/* before the message: wraps high */
		OSD_TX(k < 8 * LOCKSTEP_OSD_CHARS && (k & 7) != 7 ? glyph[msg[k >> 3] + (k & 7)] : 0);
	}
	OSD_OFF();
	osd_cmd(0x28, 0x01);		/* OSD control: enable */
}

void fw_start(const unsigned char *img, unsigned size)
{
	unsigned need = SDC_R(SDC_VER);
	unsigned have = ~0u;	/* no trailer: matches no 16-bit VERSION */

	if (size >= FW_TRAILER_LEN) {
		const unsigned char *t = img + size - FW_TRAILER_LEN;
		if (t[0] == 'S' && t[1] == 'D' && t[2] == 'C' && t[3] == 'V' && !t[4] && !t[5])
			have = t[6] << 8 | t[7];
	}
	if (have == need) {
		printf("Firmware SDC %04x, bitstream SDC %04x\n", have, need);
		_boot();
	}
	printf("Firmware does not match this bitstream (need SDC %04x)\n", need);
	ErrorCode(0x0ff);
	osd_mismatch();
	boot_halt();
}

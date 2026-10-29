/* Bitstream / firmware lock-step check (lockstep.h, design 5.5): the boot
   ROM is part of the bitstream, so the peripheral's VERSION register names
   the card path this bitstream has and the OSD's VERSION reply its text
   layer; RV32OSDB.BIN names the card path it was built for and the layer
   it needs in its trailer.  Different (or no trailer): stop, never run it,
   and say so on the UART, on the OSD text layer and with BootDiag's colour
   (ErrorCode 0x0ff: cyan). */
#include "lockstep.h"
#include "small_printf.h"
#include "../ctrl/sdc.h"

#ifdef HOSTTEST
/* test/lockstep_test.c: what goes to cfide's SPI (the OSD) */
void hosttest_osd(int what, unsigned char b);	/* 0 select, 1 deselect, 2 a byte */
unsigned char hosttest_osd_rx(void);		/* a byte 0xff out, the reply in */
#define OSD_ON()     hosttest_osd(0, 0)
#define OSD_OFF()    hosttest_osd(1, 0)
#define OSD_TX(b)    hosttest_osd(2, (b))
#define OSD_RX()     hosttest_osd_rx()
#else
#include "spi.h"
#define OSD_ON()     EnableOsd()
#define OSD_OFF()    DisableOsd()
#define OSD_TX(b)    (HW_SPI(HW_SPI_DATA) = (b))
/* at the ROM's slow SPI (SPI_slow, ~8 us a bit) userio_osd has the next
   reply byte in place long before the byte starts: no OSD_RDY wait */
#define OSD_RX()     (HW_SPI(HW_SPI_DATA) = 0xff, HW_SPI(HW_SPI_DATA))
#endif

/* the core's text layer version: OSD_CMD_VERSION (0x88) reply byte 11 when
   byte 10 is the magic, else 0 (no layer: an older core answers MINION_VER,
   a day <= 31, there) */
static unsigned osd2_version(void)
{
	unsigned char b10 = 0, b11 = 0;
	int i;

	OSD_ON();
	OSD_TX(0x88);
	for (i = 0; i < 12; i++) {
		b10 = b11;
		b11 = OSD_RX();
	}
	OSD_OFF();
	return b10 == LOCKSTEP_OSD2_MAGIC ? b11 : 0;
}

/* the OSD frames of the message, each {length, bytes}, 0 ends:
   the palette (0x4C from entry 0, {mode << 6, r, g, b}): entry 0 (the
   cells' background) red, entry 1 white, both opaque;
   the message into cells 0..16 (0x2C, char/attr pairs from cell 0; attr
   0x01: foreground 1, background 0);
   the window (0x5C): enabled, scale 2, at (x0, y0), 17 x 1 cells; its 5th
   byte commits palette and window at the layer's next frame.
   Cells outside the 17 x 1 window (a soft restart's menu) stay hidden. */
#define M(c) (c), 0x01
static const unsigned char osd_msg[] = {
	10, 0x4c, 0, 0x00, 0xe0, 0x3c, 0x3c, 0x00, 0xf0, 0xf0, 0xf0,
	4 + 2 * LOCKSTEP_OSD_CHARS, 0x2c, 0, 0, 0,
	M('F'), M('I'), M('R'), M('M'), M('W'), M('A'), M('R'), M('E'), M(' '),
	M('M'), M('I'), M('S'), M('M'), M('A'), M('T'), M('C'), M('H'),
	6, 0x5c, 0x03, LOCKSTEP_OSD_X0, LOCKSTEP_OSD_Y0, LOCKSTEP_OSD_CHARS, 1,
	0
};

static void osd_mismatch(void)
{
	const unsigned char *p = osd_msg;
	unsigned n;

	while ((n = *p++)) {
		OSD_ON();
		while (n--)
			OSD_TX(*p++);
		OSD_OFF();
	}
}

void fw_start(const unsigned char *img, unsigned size)
{
	unsigned need = SDC_R(SDC_VER);
	unsigned have = ~0u;	/* no trailer: matches no 16-bit VERSION */
	unsigned osd_need = 0, osd_have = osd2_version();

	if (size >= FW_TRAILER_LEN) {
		const unsigned char *t = img + size - FW_TRAILER_LEN;
		if (t[0] == 'S' && t[1] == 'D' && t[2] == 'C' && t[3] == 'V') {
			osd_need = t[4] << 8 | t[5];
			have = t[6] << 8 | t[7];
		}
	}
	if (have == need && osd_have >= osd_need) {
		printf("Firmware SDC %04x, bitstream SDC %04x\n", have, need);
		_boot();
	}
	printf("Firmware does not match this bitstream (need SDC %04x, OSD layer <= %d)\n", need, osd_have);
	osd_mismatch();		/* before ErrorCode: that stays the last hardware access (no chipset
				   reset touches the text layer) */
	ErrorCode(0x0ff);
	boot_halt();
}

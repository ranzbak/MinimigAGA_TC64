/* Bitstream / firmware lock-step check (lockstep.h, design 5.5): the boot
   ROM is part of the bitstream, so the peripheral's VERSION register names
   the card path this bitstream has; RV32OSDA.BIN names the one it was built
   for in its trailer.  Different (or no trailer): stop, never run it. */
#include "lockstep.h"
#include "small_printf.h"
#include "../ctrl/sdc.h"

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
	boot_halt();
}

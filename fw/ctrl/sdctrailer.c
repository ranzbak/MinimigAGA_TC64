/* The lock-step trailer of RV32OSDB.BIN (fw/ctrl_boot README "Lock-step
 * check", design 5.5; findings/osd-redesign/plan.md 3.12): the Makefile
 * compiles this file on its own, takes the 8 bytes of .sdctrailer out with
 * objcopy and appends them to the image after objcopy -O binary (so _start
 * stays byte 0).  Not linked into the firmware.  SDC_VERSION comes from
 * sdc.h, as the driver's and the boot ROM's: one source; OSD2_REQUIRED
 * (bytes 4-5, the OSD text layer version the firmware needs) from osd2.h.
 * A boot ROM from before OSD2_REQUIRED wants bytes 4-5 = 0, so it refuses
 * this file. */
#include "sdc.h"
#include "osd2.h"

__attribute__((section(".sdctrailer"), used))
const unsigned char sdc_trailer[8] = {
	'S', 'D', 'C', 'V', (OSD2_REQUIRED >> 8) & 0xFF, OSD2_REQUIRED & 0xFF,
	(SDC_VERSION >> 8) & 0xFF, SDC_VERSION & 0xFF
};

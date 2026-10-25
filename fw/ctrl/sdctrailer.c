/* The lock-step trailer of RV32OSDA.BIN (fw/ctrl_boot README "Lock-step
 * check", design 5.5): the Makefile compiles this file on its own, takes the
 * 8 bytes of .sdctrailer out with objcopy and appends them to the image
 * after objcopy -O binary (so _start stays byte 0).  Not linked into the
 * firmware.  SDC_VERSION comes from sdc.h, as the driver's and the boot
 * ROM's: one source. */
#include "sdc.h"

__attribute__((section(".sdctrailer"), used))
const unsigned char sdc_trailer[8] = {
	'S', 'D', 'C', 'V', 0, 0, (SDC_VERSION >> 8) & 0xFF, SDC_VERSION & 0xFF
};

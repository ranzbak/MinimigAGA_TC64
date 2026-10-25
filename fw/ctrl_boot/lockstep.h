#ifndef LOCKSTEP_H
#define LOCKSTEP_H

/* Bitstream / firmware lock-step (design 5.5, README "Lock-step check").
   RV32OSDA.BIN ends with an 8-byte trailer, appended by fw/ctrl/Makefile
   after objcopy: 'S','D','C','V', 0, 0, SDC_VERSION >> 8, SDC_VERSION & 0xFF
   (SDC_VERSION from fw/ctrl/sdc.h).  The boot ROM boots the file only when
   that trailer, the last 8 bytes of the file (its length from the FAT
   directory entry), names the peripheral's VERSION register. */
#define FW_TRAILER_LEN 8

/* img = the loaded file, size = its length.  Match: one UART line with both
   versions, then _boot().  Mismatch (another version, no 'SDCV' magic, bytes
   4-5 not 0, size < 8): "Firmware does not match this bitstream (need SDC
   %04x)", ErrorCode(0x0ff), boot_halt().  Never returns. */
void fw_start(const unsigned char *img, unsigned size);

/* boot.c */
void _boot(void);
void ErrorCode(int code);
void boot_halt(void) __attribute__((noreturn));	/* interrupts off, park */

#endif

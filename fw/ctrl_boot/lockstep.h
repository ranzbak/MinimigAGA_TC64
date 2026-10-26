#ifndef LOCKSTEP_H
#define LOCKSTEP_H

/* Bitstream / firmware lock-step (design 5.5, README "Lock-step check").
   RV32OSDB.BIN ends with an 8-byte trailer, appended by fw/ctrl/Makefile
   after objcopy: 'S','D','C','V', 0, 0, SDC_VERSION >> 8, SDC_VERSION & 0xFF
   (SDC_VERSION from fw/ctrl/sdc.h).  The boot ROM boots the file only when
   that trailer, the last 8 bytes of the file (its length from the FAT
   directory entry), names the peripheral's VERSION register. */
#define FW_TRAILER_LEN 8

/* The OSD's part of a mismatch (design 5.5): the whole OSD buffer written
   blank with "FIRMWARE MISMATCH" (LOCKSTEP_OSD_CHARS characters of
   fw/ctrl/charrom.h, 8 columns each) from byte LOCKSTEP_OSD_AT (line 3,
   centred), then the OSD enabled; cfide's SPI at fw/ctrl's SPI_fast speed */
#define LOCKSTEP_OSD_CHARS 17
#define LOCKSTEP_OSD_AT (3 * 256 + (256 - 8 * LOCKSTEP_OSD_CHARS) / 2)

/* img = the loaded file, size = its length.  Match: one UART line with both
   versions, then _boot().  Mismatch (another version, no 'SDCV' magic, bytes
   4-5 not 0, size < 8): "Firmware does not match this bitstream (need SDC
   %04x)", the OSD message, ErrorCode(0x0ff) (BootDiag cyan; the last
   hardware access), boot_halt().  Never returns. */
void fw_start(const unsigned char *img, unsigned size);

/* boot.c */
void _boot(void);
void ErrorCode(int code);
void osd_cmd(unsigned char cmd, unsigned char v);	/* EnableOsd, cmd, v, DisableOsd */
void boot_halt(void) __attribute__((noreturn));	/* interrupts off, park */

#endif

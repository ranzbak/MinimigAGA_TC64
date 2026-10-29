#ifndef LOCKSTEP_H
#define LOCKSTEP_H

/* Bitstream / firmware lock-step (design 5.5, README "Lock-step check";
   findings/osd-redesign/plan.md 3.12).  RV32OSDB.BIN ends with an 8-byte
   trailer, appended by fw/ctrl/Makefile after objcopy:
     'S','D','C','V', OSD2_REQUIRED >> 8, OSD2_REQUIRED & 0xFF,
     SDC_VERSION >> 8, SDC_VERSION & 0xFF
   (fw/ctrl/sdctrailer.c: SDC_VERSION from fw/ctrl/sdc.h, OSD2_REQUIRED
   from fw/ctrl/osd2.h).  OSD2_REQUIRED is the OSD text layer version the
   firmware needs (OSD reply byte 11 of OSD_CMD_VERSION, behind the magic
   0xB5 in byte 10), 0 = none: the bytes a firmware from before the text
   layer has there.  The boot ROM boots the file only when that trailer,
   the last 8 bytes of the file (its length from the FAT directory entry),
   names the peripheral's VERSION register and the core's text layer is at
   least OSD2_REQUIRED.  (A boot ROM from before OSD2_REQUIRED wants bytes
   4-5 = 0: it refuses every firmware that needs the layer.) */
#define FW_TRAILER_LEN 8

/* the OSD text layer's VERSION reply (userio_osd.v): byte 10 the magic,
   byte 11 the layer version */
#define LOCKSTEP_OSD2_MAGIC 0xB5

/* The OSD's part of a mismatch: "FIRMWARE MISMATCH" in the text layer's
   cell RAM (cells 0..16 of row 0, white on red), a 17 x 1 window at scale
   2, centred on the 720p raster (x0 = (1280 - 17 * 16) / 2 / 8, y0 =
   (720 - 32) / 2 / 8).  No font upload: the layer's font RAM comes up with
   osd_font.mem.  cfide's SPI stays at the ROM's slow speed. */
#define LOCKSTEP_OSD_CHARS 17
#define LOCKSTEP_OSD_X0 63
#define LOCKSTEP_OSD_Y0 43

/* img = the loaded file, size = its length.  Match: one UART line with both
   SDC versions, then _boot().  Mismatch (another SDC version, no 'SDCV'
   magic, size < 8; or a text layer older than OSD2_REQUIRED, none counting
   as 0): "Firmware does not match this bitstream (need SDC %04x, OSD
   layer <= %d)" (the bitstream's SDC version and text layer), the OSD
   message,
   ErrorCode(0x0ff) (BootDiag cyan; the last hardware access), boot_halt().
   Never returns. */
void fw_start(const unsigned char *img, unsigned size);

/* boot.c */
void _boot(void);
void ErrorCode(int code);
void osd_cmd(unsigned char cmd, unsigned char v);	/* EnableOsd, cmd, v, DisableOsd */
void boot_halt(void) __attribute__((noreturn));	/* interrupts off, park */

#endif

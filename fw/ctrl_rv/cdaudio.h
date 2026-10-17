#ifndef CDAUDIO_H
#define CDAUDIO_H

/*
 * CD audio player (findings/cdrom/plan.md 13.2, 13.7): plays a range of
 * disc sectors into the 64 KB audio ring (two 32 KB halves, 44.1 kHz
 * 16-bit LE stereo, red book as it is).  Pure C: the hardware and the SD
 * card are behind the cda_port_* functions, implemented by cdrom.c on the
 * board and by the tests (test/cdaudio_test.c, test/emu/cdaudio_emu.c).
 *
 * Refill by polling (13.1): cda_poll() is called from the main loop and
 * between the blocks of every SD transfer loop; when the half being played
 * has changed it fills the other one.  The position comes from TIMER
 * (256 frames a unit), not from the read-ahead.
 *
 * vbcc832 (12.6): every state field is 32 bits.
 */

#include <stdint.h>
#include "cue.h"

/* Audio status = the READ SUB-CHANNEL codes (13.6) */
#define CDA_PLAYING   0x11
#define CDA_PAUSED    0x12
#define CDA_COMPLETED 0x13
#define CDA_ERROR     0x14
#define CDA_IDLE      0x15

/* AUDIO register (hardware.h): write bit 0 ENA, bit 1 CLEAR; read bit 0 =
   the half being played, bit 1 = the Amiga owns the stream. */
#define CDA_ENA        1
#define CDA_CLEAR      2
#define CDA_REG_HALF   1
#define CDA_REG_AMIGA  2

#define CDA_HALF_BYTES  0x8000	/* AUDIO_BUFFER_SIZE */
#define CDA_HALF_FRAMES 8192
#define CDA_HALF_UNITS  32	/* TIMER units (256 frames) in one half */

/* ---- the port ---- */

/* 512-byte block `block` (byte offset block * 512) of disc file `file`
   into dst; 1 = read, 0 = SD error. */
int32_t  cda_port_read(int32_t file, uint32_t block, uint8_t *dst);
uint32_t cda_port_audio(void);		/* read the AUDIO register */
void     cda_port_control(uint32_t v);	/* write the AUDIO register: CDA_ENA, CDA_CLEAR or 0 */
uint32_t cda_port_timer(void);		/* TIMER (16 bits) */
uint8_t *cda_port_ring(void);		/* the ring: half h at h * CDA_HALF_BYTES */
void     cda_port_claim(void);		/* the player takes the ring: the drive sounds stop */

/* ---- the player ---- */

void     cda_init(void);			/* idle, volume 255/255 */
/* Play sectors start .. end - 1 of disc d (end > start, end <= lead-out).
   Silent gaps and data sectors play as silence; any play in progress
   stops first. */
void     cda_play(const struct cd_disc *d, uint32_t start, uint32_t end);
void     cda_pause(void);			/* playing -> paused, position kept */
void     cda_resume(void);			/* paused -> playing from the position */
void     cda_stop(void);			/* -> idle */
void     cda_volume(uint32_t left, uint32_t right);	/* 0..255 per channel */
void     cda_poll(void);
int32_t  cda_status(void);		/* CDA_PLAYING .. CDA_IDLE */
uint32_t cda_position(void);		/* LBA of the sector playing (paused at, last played) */
int32_t  cda_busy(void);		/* playing or paused: the ring is the player's */
uint32_t cda_underruns(void);		/* late refills since power on */

#endif

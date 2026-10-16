#ifndef CUE_H
#define CUE_H

/*
 * CD disc model and CUE sheet parser (findings/cdrom/plan.md 13.4).
 *
 * Pure C, no hardware or SD access: the caller feeds the CUE text in any
 * chunks and opens each FILE through a callback (cdrom.c on the board, a
 * table in the tests).  Builds for the 832 (vbcc832) and the host
 * (fw/ctrl_832/test/cue_test.c, test/emu/cue_emu.c).
 *
 * vbcc832 rule (12.6): a field that is set and then returned with the same
 * constant ("p->error = E; return E;") must be 32 bits wide -- vbcc832
 * stores it with a 32-bit store whatever its type.  The parser's result
 * fields are int32_t for that reason; the disc model's narrow fields are
 * never set that way, and test/emu/cue_emu.c checks every one of them.
 */

#include <stdint.h>

#define CD_MAX_TRACKS 99
#define CD_MAX_FILES  99
#define CUE_LINE_MAX  300	/* FILE "<255 characters>" BINARY fits */

/* track types */
#define CD_DATA2048 1	/* 2048 bytes of file per sector (ISO, MODE1/2048) */
#define CD_DATA2352 2	/* raw MODE1/2352: user data at byte 16 */
#define CD_AUDIO    3	/* 2352 bytes = 588 stereo frames of 16-bit LE PCM */

#define CD_FRAMES_PER_SECTOR 588

struct cd_track {		/* one per TRACK, up to 99; track[i].number == i + 1 */
	uint8_t  number;
	uint8_t  type;		/* CD_DATA2048, CD_DATA2352, CD_AUDIO */
	uint8_t  file;		/* index into file[] */
	uint32_t file_offset;	/* bytes into the file where INDEX 01 starts */
	uint32_t lba;		/* disc address of INDEX 01 */
	uint32_t sectors;	/* to the next track's INDEX 01 in the same file / end of file */
	uint32_t pregap_lba;	/* first sector of its gap (INDEX 00 or PREGAP), == lba if none */
	uint8_t  pregap_silent;	/* gap not in the file (PREGAP) */
};

struct cd_file {
	char     shortname[12];	/* 8.3 name as FileOpen wants it (11 characters, no dot) + NUL */
	uint8_t  wave;		/* FILE ... WAVE */
	uint32_t data_offset;	/* WAVE: first byte of the data chunk; BINARY: 0 */
	uint32_t data_bytes;	/* WAVE: data chunk size; BINARY: file size */
};

struct cd_disc {
	int32_t  tracks;
	int32_t  files;
	uint32_t leadout;	/* LBA of the lead-out = disc size in sectors */
	struct cd_track track[CD_MAX_TRACKS];
	struct cd_file  file[CD_MAX_FILES];
};

/* Errors: the parser's result and cue_message()'s text */
#define CUE_OK          0
#define CUE_E_SYNTAX    1	/* "syntax" */
#define CUE_E_UNKNOWN   2	/* "unknown cmd": a command we do not know is refused */
#define CUE_E_LINE      3	/* "line too long" */
#define CUE_E_FILETYPE  4	/* "file type": FILE type other than BINARY / WAVE */
#define CUE_E_MODE      5	/* "track mode": MODE2, CDG, CDI, MODE1/2336 */
#define CUE_E_TOOMANY   6	/* "too many": more than 99 tracks or files */
#define CUE_E_ORDER     7	/* "track order": TRACK numbers not 1, 2, 3 ... */
#define CUE_E_INDEX     8	/* "bad INDEX": INDEX 02+, 00 after 01, twice, missing 01, going back */
#define CUE_E_GAP       9	/* "PREGAP+INDEX0": both on one track */
#define CUE_E_SESSION  10	/* "2nd session": REM SESSION 02 or later */
#define CUE_E_NOFILE   11	/* "file missing" */
#define CUE_E_WAV      12	/* "WAV format": not PCM 44.1 kHz 16-bit stereo, or no data chunk */
#define CUE_E_MIXED    13	/* "sector sizes": 2048 and 2352 in one FILE, or data in a WAVE */
#define CUE_E_END      14	/* "past file end": INDEX 01 beyond the end of its FILE */
#define CUE_E_EMPTY    15	/* "no tracks" */
#define CUE_E_READ     16	/* "read error": the glue could not read the CUE */

/* Open the FILE named name (as written in the CUE, quotes removed) for f:
   f->wave is set before the call; fill f->shortname, f->data_offset and
   f->data_bytes.  Return CUE_OK, CUE_E_NOFILE or CUE_E_WAV. */
typedef int32_t (*cue_open_fn)(void *ctx, const char *name, struct cd_file *f);

struct cue_parser {
	struct cd_disc *disc;
	cue_open_fn     open;
	void           *ctx;
	int32_t  error;		/* CUE_OK or the first error */
	int32_t  error_line;	/* its line (1 = first), 0 = not tied to a line */
	int32_t  line;		/* number of the line being collected */
	int32_t  len;		/* characters in buf */
	int32_t  overflow;	/* the line is longer than CUE_LINE_MAX */
	int32_t  cur_file;	/* last FILE, -1 = none yet */
	int32_t  idx0[CD_MAX_TRACKS];	/* INDEX 00 in sectors of its file, -1 = none */
	int32_t  idx1[CD_MAX_TRACKS];	/* INDEX 01, -1 = none yet */
	int32_t  pregap[CD_MAX_TRACKS];	/* PREGAP sectors */
	int32_t  postgap[CD_MAX_TRACKS];	/* POSTGAP sectors */
	int32_t  tline[CD_MAX_TRACKS];	/* line of each TRACK */
	char     buf[CUE_LINE_MAX + 1];
};

/* Start parsing into d (cleared).  open is called once per FILE line. */
void cue_begin(struct cue_parser *p, struct cd_disc *d, cue_open_fn open, void *ctx);

/* The next len bytes of the CUE text, cut anywhere.  CRLF or LF.
   Returns p->error (parsing stops at the first error). */
int32_t cue_feed(struct cue_parser *p, const char *text, uint32_t len);

/* End of the text: the last line, the checks and the LBA layout (13.4).
   Returns CUE_OK or the first error; on CUE_OK d is a complete disc. */
int32_t cue_end(struct cue_parser *p);

/* "line N: <cause>" (or "<cause>"), at most 23 characters: buf[24]. */
void cue_message(const struct cue_parser *p, char *buf);

/* An ISO: one DATA2048 track over the whole file (bytes / 2048 sectors). */
void cue_single(struct cd_disc *d, const char *shortname, uint32_t bytes);

/* Where disc sector lba lives. */
struct cue_loc {
	int32_t  track;		/* index into track[] */
	int32_t  index;		/* 0 = in the gap before INDEX 01, 1 = from INDEX 01 on */
	int32_t  silent;	/* no file bytes: PREGAP or POSTGAP */
	int32_t  file;		/* index into file[] when !silent */
	uint32_t offset;	/* when !silent: byte offset in the file of the sector's first byte */
	uint32_t run;		/* sectors from lba on with the same track, index, silent and contiguous bytes */
};

/* 1 and *loc filled, or 0 when lba is at or past the lead-out. */
int32_t cue_locate(const struct cd_disc *d, uint32_t lba, struct cue_loc *loc);

/* Bytes of file per sector of a track type: 2048 or 2352. */
uint32_t cue_sector_size(int32_t type);

#endif

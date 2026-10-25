/*
 * CD-ROM board glue -- see cdrom.h and findings/cdrom/plan.md 7.1, 7.4, 9, 13.5.
 *
 * The ATAPI unit of atapi.c on one IDE slot of the two-port Gayle.  The
 * disc is a model (cue.h): an ISO is one DATA2048 track, a CUE sheet is
 * parsed at insert and each of its FILEs looked up in the CUE's directory.  The
 * Gayle port runs in packet mode (gayle_port.v): each data phase is set up
 * with WriteXfer (length in words), the task file (interrupt reason, byte
 * count) and a status write for the direction; the port raises DRQ and the
 * interrupt, and its xfer_done flag says when the host is through.
 *
 *   packet  reason 1 (CoD), 6 words out, no interrupt
 *   data in reason 2 (IO), byte count = block, pio in; the interrupt comes
 *           with the DRQ once the block is in the FIFO.  Blocks of at most
 *           the host's byte count limit and 8 KB (the FIFO); sectors go
 *           from the SD card straight into the FIFO (to_gayle card runs,
 *           CD_Step).
 *   data out reason 0, byte count = block, pio out + interrupt
 *   status  reason 3 (IO|CoD), END + interrupt, ERR and the error register
 *           (sense key << 4, ABRT for ILLEGAL REQUEST / ABORTED COMMAND)
 *
 * While the firmware waits for the host it polls the port's flags: an
 * Amiga reset (rst_seen) or a command written over this one (packet mode
 * gone) ends the command without a status; a host that does nothing for
 * CD_TIMEOUT TIMER counts gets the command aborted.
 *
 * READ(10)/(12) and READ CD run as main-loop states (CD_Step, below:
 * findings/sdcard-engine Task 11b); the packet phase, the CPU-buffer
 * replies, MODE SELECT's data and the CD-DA / raw 2352 / gap runs of a
 * read stay synchronous (cd_wait spins on the host, CD_AudioPoll inside).
 */

#include <stdio.h>
#include <string.h>

#include "hardware.h"
#include "fat.h"
#include "hdd.h"
#include "mmc.h"
#include "sdproto.h"
#include "config.h"
#include "errors.h"
#include "rafile.h"
#include "atapi.h"
#include "cue.h"
#include "cdaudio.h"
#include "diskstat.h"
#include "cdrom.h"
#ifndef HOSTTEST
#include "drivesounds.h"
#endif

/* fat.c's directory state: lookups in the disc's directory put it back, so
   the OSD file browser does not move (or lose its ".." position). */
extern unsigned long iCurrentDirectory, iPreviousDirectory;

cdromTYPE cdrom;

static hdfTYPE cd_audio;		/* the disc file being played (13.5: the second open file) */
static int cd_audio_file = -1;		/* its index in cd_disc.file[], -1 = none */
static uint32_t cd_underruns;		/* cda_underruns() at the last report */
static struct cd_disc cd_disc;		/* the disc in the drive */
static struct cue_parser cd_cue;	/* 2.5 KB: static, the stack is ~3 KB (0x1400..0x2000) */
static RAFile cd_cuefile;		/* the CUE text */
static RAFile cd_lookup;		/* each FILE of the CUE: its size, a WAV's header */
static unsigned long cd_dir;		/* the directory of the disc's files */
static int cd_data_file = -1;		/* the disc file open in cdrom.hdf, -1 = none */
static unsigned char cd_block[512];	/* one FAT sector: the raw-sector paths */
static char cd_msg[24];			/* why the last insert was refused */
static unsigned short cd_id[256];	/* IDENTIFY PACKET DEVICE words */
static unsigned char cd_cdb[12];

#define CD_TIMEOUT 10000	/* TIMER counts (GetTimer) the host may take for one phase */
#define CD_FIFO_512 16		/* 512-byte units in one data-in block: the 8 KB FIFO */

/* cd_wait() and the data phases */
#define CD_DONE     1
#define CD_GONE     0	/* reset, or a new command: no status for this one */
#define CD_FAILED  -1	/* timeout or SD error: the unit's sense says which */
#define CD_WAITING  2	/* cd_look: the host is not through yet */

/* ---- the slot's config entry (5.3: the disc in the drive at power on) ---- */

static void cd_config(const char *name, const char *long_name, unsigned long dir)
{
	hardfileTYPE *hf;
	if (!cdrom.active)
		return;
	hf = SlotConfig(cdrom.slot);
	memset(hf->name, 0, sizeof(hf->name));
	memset(hf->long_name, 0, sizeof(hf->long_name));
	hf->present = name ? CD_PRESENT(name) : 0;
	if (name) {
		memcpy(hf->name, name, sizeof(hf->name));	/* 8 characters: the extension is in present */
		if (long_name)
			strncpy(hf->long_name, long_name, sizeof(hf->long_name));
		config.hdfdir[cdrom.slot] = dir;
	}
}

/* ---- drive state ---- */

int CD_Open(int slot)
{
	hardfileTYPE *hf;
	char name[12];
	char long_name[sizeof(hf->long_name) + 1];

	CD_Cancel();	/* a READ in progress ends before the drive changes */
	cda_stop();
	cda_init();
	cd_audio.type = HDF_DISABLED;
	cd_audio_file = -1;
	cdrom.hdf.type = HDF_DISABLED;
	cd_data_file = -1;
	cdrom.slot = slot;
	cdrom.active = slot >= 0 && slot < HDD_SLOTS;
	atapi_init(&cdrom.unit);
	if (!cdrom.active)
		return CD_OK;
	hf = SlotConfig(slot);
	/* config names are fixed-width, not always terminated; present says
	   whether the 8 characters name an ISO or a CUE */
	memcpy(name, hf->name, 8);
	memcpy(name + 8, hf->present == CD_PRESENT_CUE ? "CUE" : "ISO", 3);
	name[11] = 0;
	hf->present = 0;
	if (!hf->name[0])
		return CD_OK;	/* CD slot, no disc */
	memcpy(long_name, hf->long_name, sizeof(hf->long_name));
	long_name[sizeof(hf->long_name)] = 0;
	return CD_Insert(name, long_name[0] ? long_name : 0, config.hdfdir[slot]);
}

/* ---- the disc's files ---- */

/* RAOpen in the disc's directory, leaving fat.c's directory state alone.
   A failed lookup is the insert's refusal, not a filesystem error for the
   OSD's error page. */
static int cd_raopen(RAFile *f, const char *name)
{
	unsigned long cur = iCurrentDirectory, prev = iPreviousDirectory;
	int ok;
	ChangeDirectory(cd_dir);
	ok = RAOpen(f, name);
	iCurrentDirectory = cur;
	iPreviousDirectory = prev;
	if (!ok)
		ClearError(ERROR_FILESYSTEM);
	return ok;
}

/* name as an 8.3 directory name ("game.bin" -> "GAME    BIN"), 0 when it
   is not one (a long name).  An 8.3 name written in lower case has no long
   name entry on a FAT card (Linux, Windows), so FileOpen's long-name match
   cannot find it. */
static int cd_name83(const char *name, char *out)
{
	int i = 0, n = 0, dot = 0;
	memset(out, ' ', 11);
	out[11] = 0;
	while (name[i]) {
		char c = name[i];
		if (c == '.') {
			if (dot || i == 0)
				return 0;
			dot = 1;
			n = 8;
		} else {
			if (c >= 'a' && c <= 'z')
				c = (char)(c - 32);
			if (!((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '~' ||
			      c == '!' || c == '#' || c == '$' || c == '%' || c == '&' || c == '(' || c == ')'))
				return 0;
			if (n == (dot ? 11 : 8))
				return 0;
			out[n++] = c;
		}
		i++;
	}
	return i > 0;
}

/* cue_wav's reader: the WAV opened in cd_lookup. */
static int32_t cd_lookup_read(void *ctx, uint32_t offset, uint8_t *dst, uint32_t len)
{
	(void)ctx;
	if (!RASeek(&cd_lookup, offset, SEEK_SET))
		return 0;
	return RARead(&cd_lookup, dst, len) ? 1 : 0;
}

/* The parser's FILE callback: find the file by its 8.3 or long name,
   keep the 8.3 name, read a WAV's header. */
static int32_t cd_cue_open(void *ctx, const char *name, struct cd_file *f)
{
	(void)ctx;
	char n83[12];
	int ok = 0;
	if (cd_name83(name, n83))
		ok = cd_raopen(&cd_lookup, n83);
	if (!ok)
		ok = cd_raopen(&cd_lookup, name);	/* FileOpen: long-name match */
	if (!ok)
		return CUE_E_NOFILE;
	memcpy(f->shortname, cd_lookup.file.name, 11);
	f->shortname[11] = 0;
	if (!f->wave) {
		f->data_offset = 0;
		f->data_bytes = cd_lookup.size;
		return CUE_OK;
	}
	return cue_wav(cd_lookup_read, 0, cd_lookup.size, f);
}

/* Parse the CUE opened in cd_cuefile into cd_disc. */
static int32_t cd_parse_cue(void)
{
	unsigned long left = cd_cuefile.size;
	cue_begin(&cd_cue, &cd_disc, cd_cue_open, 0);
	while (left && cd_cue.error == CUE_OK) {
		unsigned long n = left < sizeof(cd_block) ? left : sizeof(cd_block);
		if (!RARead(&cd_cuefile, cd_block, n)) {
			cd_cue.error = CUE_E_READ;
			cd_cue.error_line = 0;
			return CUE_E_READ;
		}
		cue_feed(&cd_cue, (const char *)cd_block, n);
		left -= n;
	}
	return cue_end(&cd_cue);
}

/* Disc file f in h -- cdrom.hdf for reads, cd_audio for the player (13.5:
   two open files) -- opened in the disc's directory with a fresh cluster
   index when h holds another file; *open says which file h holds. */
static int cd_hdf_open(hdfTYPE *h, int *open, int f)
{
	unsigned long cur, prev;
	int ok;
	if (*open == f && h->type == HDF_FILE)
		return 1;
	h->type = HDF_DISABLED;
	*open = -1;
	cur = iCurrentDirectory;
	prev = iPreviousDirectory;
	ChangeDirectory(cd_dir);
	ok = FileOpen(&h->file, cd_disc.file[f].shortname);
	iCurrentDirectory = cur;
	iPreviousDirectory = prev;
	if (!ok) {
		ClearError(ERROR_FILESYSTEM);
		return 0;
	}
	h->type = HDF_FILE;
	h->offset = 0;
	if (!BuildHardfileIndex(h))	/* a FAT read failed or a short chain: wrong clusters in the index */
		return 0;
	*open = f;
	return 1;
}

static int cd_data_open(int f)
{
	return cd_hdf_open(&cdrom.hdf, &cd_data_file, f);
}

const char *CD_Message(void)
{
	return cd_msg;
}

int CD_Insert(const char *name, const char *long_name, unsigned long dir)
{
	char shortname[12];
	char base[9];		/* the drive's name without a long name: 8 characters */
	char longname[ATAPI_NAME_LEN + 1];

	if (!cdrom.active)
		return CD_NOFILE;
	/* copies first: name may be the config entry CD_Eject clears */
	memcpy(shortname, name, 11);
	shortname[11] = 0;
	memcpy(base, name, 8);
	base[8] = 0;
	if (long_name) {
		strncpy(longname, long_name, ATAPI_NAME_LEN);
		longname[ATAPI_NAME_LEN] = 0;
	}
	if (CD_Eject() != CD_OK)
		return CD_LOCKED;

	cd_msg[0] = 0;
	if (!ValidateDirectory(dir))
		return CD_NOFILE;
	cd_dir = dir;
	if (memcmp(shortname + 8, "CUE", 3) == 0) {
		if (!cd_raopen(&cd_cuefile, shortname))
			return CD_NOFILE;
		if (cd_parse_cue() != CUE_OK) {
			cue_message(&cd_cue, cd_msg);
			if (DebugMode)
				printf("CD: %s refused: %s\r\n", shortname, cd_msg);
			return CD_BADCUE;
		}
	} else {
		if (!cd_raopen(&cd_lookup, shortname))
			return CD_NOFILE;
		cue_single(&cd_disc, shortname, cd_lookup.size);
	}
	if (!cd_data_open(cd_disc.track[0].file))
		return CD_NOFILE;

	atapi_insert(&cdrom.unit, &cd_disc, long_name ? longname : base);
	cd_config(shortname, long_name ? longname : 0, dir);
	if (DebugMode)
		printf("CD: insert %s (%s), %d tracks, %d sectors\r\n", shortname, cdrom.unit.name,
		       (int)cd_disc.tracks, (int)cd_disc.leadout);
	return CD_OK;
}

/* The disc is out (OSD or Amiga eject, or a new disc): the music stops,
   the files close, the name is forgotten. */
static void cd_drop_file(void)
{
	cda_stop();
	cd_audio.type = HDF_DISABLED;
	cd_audio_file = -1;
	cdrom.hdf.type = HDF_DISABLED;	/* FAT files need no close */
	cd_data_file = -1;
	cd_config(0, 0, 0);
}

int CD_Eject(void)
{
	if (CD_Locked())	/* an Amiga reset since the last command clears the lock */
		return CD_LOCKED;
	CD_Cancel();	/* a READ in progress ends before its file goes */
	if (atapi_eject(&cdrom.unit) != ATAPI_OK)
		return CD_LOCKED;
	cd_drop_file();
	return CD_OK;
}

void CD_Reset(void)
{
	if (DebugMode)
		printf("CD: Amiga reset\r\n");
	cda_stop();	/* 13.7: a reset stops the music */
	atapi_reset(&cdrom.unit);
}

void CD_Flags(int port, unsigned char flags)
{
	if ((flags & IDEF_RST_SEEN) && cdrom.active && (cdrom.slot >> 1) == port)
		CD_Reset();
}

int CD_Locked(void)
{
	if (!cdrom.active)
		return 0;
	if (cdrom.unit.locked && !hdd_busy()) {
		/* the Amiga may have been reset since its last command: the
		   lock does not survive that (R-D).  Not while an IDE command is
		   in progress (findings/sdcard-engine Tasks 11a, 11b: the main
		   loop and the OSD run during it): during an HDD command the flags
		   read's command word would re-latch the Gayle's firmware port to
		   the CD's; during a CD command it would take the rst_seen the
		   command's own look must see; the lock is kept until the next
		   look */
		CD_Flags(cdrom.slot >> 1, ReadIDEFlags(cdrom.slot >> 1));
	}
	return atapi_locked(&cdrom.unit);
}

/* ---- CD audio (13.5, 13.7): the player's port and its requests ---- */

/* The player reads through the second open file. */
int32_t cda_port_read(int32_t file, uint32_t block, uint8_t *dst)
{
	if (!cd_hdf_open(&cd_audio, &cd_audio_file, file))
		return 0;
	if (!HardFileSeek(&cd_audio, block))
		return 0;
	return FileRead(&cd_audio.file, dst) ? 1 : 0;
}

#ifndef HOSTTEST
uint32_t cda_port_audio(void)
{
	return AUDIO;
}

void cda_port_control(uint32_t v)
{
	AUDIO = (unsigned char)v;
}

uint32_t cda_port_timer(void)
{
	return TIMER;
}

uint8_t *cda_port_ring(void)
{
	return (uint8_t *)AUDIO_BUFFER;
}

void cda_port_claim(void)
{
	drivesounds_yield();	/* 13.1: CD audio wins the buffer */
}
#endif

/* Set while a CD command is in progress (CD_HandleCommand, and a READ's
   states up to their end): cd_wait / CD_Step read the port's flags
   themselves and must see an rst_seen there (the command ends). */
static int cd_in_command;

/* The refill: SD card reads into RAM and the audio registers, no FPGA
   command word, so the Gayle's firmware port stays where the caller's
   transfer latched it. */
void CD_AudioRefill(void)
{
	uint32_t n;
	cda_poll();
	n = cda_underruns();
	if (n != cd_underruns) {
		cd_underruns = n;
		if (DebugMode)
			printf("CDA: underrun %d\r\n", (int)n);
	}
}

/* An Amiga reset with no port-2 command after it (a floppy game, no
   atapi.device) would leave the music playing: outside a CD command the
   poll reads the CD port's flags, and CD_Flags stops the player on rst_seen
   (13.7).  Reading the flags consumes nothing else, but its command word
   re-latches the Gayle's firmware port to the CD's: inside a port-1 transfer
   the next block went to the CD port's FIFO and "drained" was hidden behind
   the busy CD port, a deadlock on the board (CD audio + READ MULTIPLE of
   more than one block, 2026-10-20).  So: main loop only; transfer loops
   call CD_AudioRefill. */
void CD_AudioPoll(void)
{
	if (!cd_in_command && cdrom.active && cda_busy()) {
		int port = cdrom.slot >> 1;
		CD_Flags(port, ReadIDEFlags(port));
	}
	CD_AudioRefill();
}

int CD_PlayingTrack(void)
{
	struct cue_loc l;
	if (!cda_busy() || !cdrom.unit.media || !cue_locate(&cd_disc, cda_position(), &l))
		return 0;
	return cd_disc.track[l.track].number;
}

static void cd_audio_request(const struct atapi_result *r)
{
	switch (r->audio) {
	case ATAPI_AUDIO_PLAY:
		cda_play(&cd_disc, r->lba, r->lba + r->count);
		break;
	case ATAPI_AUDIO_PAUSE:
		cda_pause();
		break;
	case ATAPI_AUDIO_RESUME:
		cda_resume();
		break;
	case ATAPI_AUDIO_STOP:
		cda_stop();
		break;
	}
}

/* ---- the Gayle side ---- */

static unsigned char cd_error(void)
{
	unsigned char key = cdrom.unit.sense_key;
	return (unsigned char)((key << 4) | ((key == 0x05 || key == 0x0B) ? 0x04 : 0x00));
}

/* ATA-level abort: the command is not for this device. */
static void cd_abort(unsigned char *tfr)
{
	WriteTaskFile(0x04, tfr[2], tfr[3], tfr[4], tfr[5], tfr[6]);
	WriteStatus(IDE_STATUS_END | IDE_STATUS_IRQ | IDE_STATUS_ERR);
}

/* The status phase of a packet command. */
static void cd_complete(unsigned char *tfr, unsigned char error)
{
	WriteTaskFile(error, 0x03, tfr[3], tfr[4], tfr[5], tfr[6]);
	WriteStatus(IDE_STATUS_END | IDE_STATUS_IRQ | (error ? IDE_STATUS_ERR : 0));
}

/* One look at the port's flags: is the host through with the data phase
   (CD_DONE), gone (CD_GONE: a reset, or a new command written: packet mode
   off), past timeout (CD_FAILED, 0B/00/00), or not yet (CD_WAITING)? */
static int cd_look(int port, unsigned long timeout)
{
	unsigned char flags = ReadIDEFlags(port);
	CD_Flags(port, flags);
	if (flags & IDEF_RST_SEEN)
		return CD_GONE;
	if (!(flags & IDEF_PKT))
		return CD_GONE;	/* the host wrote a new command */
	if (flags & IDEF_XFER_DONE)
		return CD_DONE;
	if (CheckTimer(timeout)) {
		if (DebugMode)
			printf("CD: host timeout\r\n");
		WriteXfer(0, 1);	/* drop the transfer: no DRQ, no stall */
		atapi_set_sense(&cdrom.unit, 0x0B, 0x00, 0x00);
		return CD_FAILED;
	}
	return CD_WAITING;
}

/* Until the host is through with the data phase (the synchronous phases). */
static int cd_wait(int port)
{
	unsigned long timeout = GetTimer(CD_TIMEOUT);
	int r;
	do {
		CD_AudioPoll();	/* no SD transfer in flight here (13.5) */
		r = cd_look(port, timeout);
	} while (r == CD_WAITING);
	return r;
}

/* Set up one data phase: length, interrupt reason, byte count, direction. */
static void cd_phase(unsigned char *tfr, unsigned int bytes, unsigned char reason, unsigned int status)
{
	WriteXfer((bytes + 1) >> 1, 1);
	WriteTaskFile(0, reason, tfr[3], bytes & 0xff, bytes >> 8, tfr[6]);
	WriteStatus(status);
}

/* Data in from a buffer, in blocks of at most the limit. */
static int cd_send_buffer(int port, unsigned char *tfr, const unsigned char *buf, unsigned int len, unsigned int limit)
{
	int r;
	while (len) {
		unsigned int n = len < limit ? len : limit;
		cd_phase(tfr, n, 0x02, IDE_STATUS_RDY);
		WriteIDEData(buf, n);
		if ((r = cd_wait(port)) != CD_DONE)
			return r;
		buf += n;
		len -= n;
	}
	return CD_DONE;
}

/* MEDIUM ERROR 03/11/00 for a read that failed on the SD card. */
static int cd_read_error(unsigned long block)
{
	if (DebugMode)
		printf("CD: SD read error at %d\r\n", (int)block);
	WriteXfer(0, 1);	/* drop the transfer: no DRQ, no stall */
	atapi_set_sense(&cdrom.unit, 0x03, 0x11, 0x00);
	return CD_FAILED;
}

/* len bytes at byte offset off of the data file into dst, through cd_block. */
static int cd_file_read(unsigned long off, unsigned char *dst, unsigned long len)
{
	unsigned long done = 0;
	while (done < len) {
		unsigned long in = (off + done) & 511, n = 512 - in;
		if (n > len - done)
			n = len - done;
		if (!HardFileSeek(&cdrom.hdf, (off + done) >> 9) || !FileRead(&cdrom.hdf.file, cd_block))
			return 0;
		memcpy(dst + done, cd_block + in, n);
		done += n;
	}
	return 1;
}

/* Data in of count sectors from a DATA2352 file at byte offset off: the
   2048 user bytes of each (from byte 16), one sector per DRQ block (split
   by the limit). */
static int cd_send_raw(int port, unsigned char *tfr, unsigned long off, unsigned long count, unsigned int limit)
{
	int r;
	while (count) {
		if (!cd_file_read(off + 16, atapi_buf, ATAPI_SECTOR_SIZE))
			return cd_read_error(off >> 9);
		if ((r = cd_send_buffer(port, tfr, atapi_buf, ATAPI_SECTOR_SIZE, limit)) != CD_DONE)
			return r;
		off += 2352;
		count--;
	}
	return CD_DONE;
}

/* Data in of count sectors of zeros: a data track's PREGAP / POSTGAP. */
static int cd_send_zero(int port, unsigned char *tfr, unsigned long count, unsigned int limit)
{
	int r;
	memset(atapi_buf, 0, ATAPI_SECTOR_SIZE);
	while (count) {
		if ((r = cd_send_buffer(port, tfr, atapi_buf, ATAPI_SECTOR_SIZE, limit)) != CD_DONE)
			return r;
		count--;
	}
	return CD_DONE;
}

/* Data in of count audio sectors as CD-DA (READ CD): 2352 bytes each from
   the file, silence for a silent gap and past the end of a WAV's data. */
static int cd_send_cdda(int port, unsigned char *tfr, const struct cue_loc *l, unsigned long count, unsigned int limit)
{
	unsigned long off = l->offset;
	int r;
	while (count) {
		unsigned long have = 0;
		if (!l->silent) {
			const struct cd_file *f = &cd_disc.file[l->file];
			unsigned long end = f->data_offset + f->data_bytes;
			have = off < end ? end - off : 0;
			if (have > 2352)
				have = 2352;
			if (have && (!cd_data_open(l->file) || !cd_file_read(off, atapi_buf, have)))
				return cd_read_error(off >> 9);
		}
		memset(atapi_buf + have, 0, 2352 - have);
		if ((r = cd_send_buffer(port, tfr, atapi_buf, 2352, limit)) != CD_DONE)
			return r;
		off += 2352;
		count--;
	}
	return CD_DONE;
}

/* ---- READ(10)/(12) and READ CD as main-loop states (findings/sdcard-engine
 * Task 11b) ----
 * lba .. lba + count - 1, split where the track, its file or its sector size
 * changes (cue_locate); audio sectors only come with READ CD (atapi.c
 * refuses them for READ(10)/(12)): CD-DA.  CD_Step() advances the read a
 * step at a time from the main loop (hdd.c hdd_poll: the dispatcher of the
 * one IDE command in progress, ruling T11-R4), never a wait in the CPU for
 * a DATA2048 run (an ISO, a CUE's MODE1/2048 track):
 *   per data-in block (at most the host's limit and 8 KB, the FIFO; blocks
 *   of 512 bytes for a limit below that, as before) the port's flags looked
 *   at first (the Amiga may have left in the gap since the last look: a
 *   reset, a new command: nothing more for this command), the phase
 *   (cd_phase: length, interrupt reason 2, byte count, RDY), then the
 *   block's sectors SD card -> Gayle's FIFO in to_gayle card runs
 *   (hdd_op_go: one RX_TO_GAYLE per 512 bytes after its CRC; at most 16
 *   sectors, inside one cluster: hdd_file_run; the file position by
 *   hdd_seek_begin / hdd_seek_step, whose FAT reads are async too); once
 *   the block is in, one flags look per pass until the host has read it
 *   (XFER_DONE: "drain, then refill") or CD_TIMEOUT.
 * The other runs (CD-DA, raw 2352, a data track's gap) are sent inside one
 * step, synchronously as before (FileRead, cd_wait).
 * Ends: the status in the step that saw the last block taken (as before:
 * no gap for an abandon between the two); a card error (a run's, a FAT
 * read's) or a chain that ends inside the file: the transfer dropped,
 * MEDIUM ERROR 03/11/00 (+ ERROR_SDCARD for a card error), unless the
 * Amiga left meanwhile (the flags looked at first: no status for a command
 * it left); a Gayle error on a run (the Amiga abandoned the command: the
 * bridge's cmd_since), a reset or packet mode gone: no status; the host
 * past CD_TIMEOUT: 0B/00/00.  No IDE command on cs 0x10 while a Gayle op
 * runs: every port access is made with the card op over (and
 * sd_gayle_busy() 0). */
enum { C_IDLE, C_LOCATE, C_SEEK, C_PHASE, C_RUNGO, C_RUN, C_WAIT };

static struct {
	unsigned char st;
	unsigned char port;
	unsigned char tfr[8];		/* the command's task file (cd_phase, cd_complete) */
	unsigned limit;			/* the host's byte count limit */
	unsigned per;			/* 512-byte sectors of a data-in block */
	unsigned long lba, count;	/* the next CD sector of the read, CD sectors left */
	unsigned long run;		/* CD sectors of the DATA2048 run in progress */
	unsigned long block, left;	/* its next 512-byte sector of the file, sectors left */
	unsigned bleft, n;		/* the data-in block's sectors not yet sent; the card op's */
	unsigned long timeout;		/* the host's bound for the block (GetTimer) */
	unsigned long lba0, count0;	/* the trace: the read */
	unsigned short t0;
	sd_op op;
} cc;

int CD_Busy(void)
{
	return cc.st != C_IDLE;
}

/* the read is over (r: CD_DONE / CD_FAILED / CD_GONE): the status (none
   for CD_GONE), the trace line */
static int cd_end(int r)
{
	unsigned char err = r == CD_FAILED ? cd_error() : 0;
	unsigned st = r == CD_GONE ? 0 : IDE_STATUS_END | IDE_STATUS_IRQ | (err ? IDE_STATUS_ERR : 0);
	if (r != CD_GONE)
		cd_complete(cc.tfr, err);
	ata_trace(0xA0, cc.lba0, (unsigned)cc.count0, r == CD_GONE ? "abandoned" : r == CD_FAILED ? "error" : "ok", st,
	          (dbg_flags & DBG_ATA) ? (unsigned short)(TIMER - cc.t0) : 0);	/* the TIMER only for the trace */
	cc.st = C_IDLE;
	cd_in_command = 0;
	return 0;
}

/* Has the Amiga left the command since the last look (cd_look's rules: a
   reset, packet mode gone)?  Before what follows a gap: a data-in block's
   phase, a status after a card error */
static int cd_left(void)
{
	unsigned char flags = ReadIDEFlags(cc.port);
	CD_Flags(cc.port, flags);
	return (flags & IDEF_RST_SEEN) || !(flags & IDEF_PKT);
}

/* a card error (a run's, a FAT read's) or the chain's end inside the file */
static int cd_card_failed(void)
{
	if (cd_left())
		return cd_end(CD_GONE);
	return cd_end(cd_read_error(cc.block));
}

static void cd_read_start(int port, const unsigned char *tfr, unsigned long lba, unsigned long count, unsigned int limit)
{
	cc.port = (unsigned char)port;
	memcpy(cc.tfr, tfr, 8);
	cc.limit = limit;
	cc.per = limit >> 9;
	if (cc.per > CD_FIFO_512)
		cc.per = CD_FIFO_512;
	if (!cc.per)
		cc.per = 1;	/* a limit below 512 bytes: blocks of 512 anyway */
	cc.lba = cc.lba0 = lba;
	cc.count = cc.count0 = count;
	if (dbg_flags & DBG_ATA)
		cc.t0 = TIMER;
	cc.st = C_LOCATE;
}

int CD_Step(void)
{
	struct cue_loc l;
	unsigned long n, card;
	unsigned k;
	int r;

	ide_port = cc.port;	/* the HDD SPI commands' port (WriteXfer, WriteStatus, ...) */
	switch (cc.st) {
	case C_LOCATE:	/* the next run of the read */
		if (sd_gayle_busy())
			return 0;
		if (cd_left())
			return cd_end(CD_GONE);
		if (!cue_locate(&cd_disc, cc.lba, &l))
			return cd_end(cd_read_error(cc.lba));
		n = l.run < cc.count ? l.run : cc.count;
		if (cd_disc.track[l.track].type == CD_AUDIO)
			r = cd_send_cdda(cc.port, cc.tfr, &l, n, cc.limit);
		else if (l.silent)
			r = cd_send_zero(cc.port, cc.tfr, n, cc.limit);
		else if (!cd_data_open(l.file))
			r = cd_read_error(cc.lba);
		else if (cd_disc.track[l.track].type == CD_DATA2048) {
			cc.run = n;
			cc.block = l.offset >> 9;
			cc.left = n * 4;
			cc.bleft = 0;
			hdd_seek_begin(&cdrom.hdf, cc.block);
			cc.st = C_SEEK;
			return 1;
		} else
			r = cd_send_raw(cc.port, cc.tfr, l.offset, n, cc.limit);
		if (r != CD_DONE)
			return cd_end(r);
		cc.lba += n;
		cc.count -= n;
		if (!cc.count)
			return cd_end(CD_DONE);
		return 1;

	case C_SEEK:	/* the file position to cc.block */
		r = hdd_seek_step(&cc.op);
		if (!r)
			return 0;
		if (r < 0) {
			if (r == -1)	/* a FAT read failed (-2: the chain ends inside the file) */
				MMC_OpResult(&cc.op, "SD card read");
			return cd_card_failed();
		}
		cc.st = cc.bleft ? C_RUNGO : C_PHASE;
		return 1;

	case C_PHASE:	/* the next data-in block */
		if (sd_gayle_busy())
			return 0;
		if (cd_left())
			return cd_end(CD_GONE);
		cc.bleft = cc.left < cc.per ? (unsigned)cc.left : cc.per;
		cd_phase(cc.tfr, cc.bleft << 9, 0x02, IDE_STATUS_RDY);
		cc.st = C_RUNGO;
		return 1;

	case C_RUNGO:	/* a card run into the FIFO: the block's rest, inside the cluster */
		k = cc.bleft;
		card = hdd_file_run(&cdrom.hdf, &k);
		if (hdd_op_go(&cc.op, SD_READ, card, k, 0, cc.port))	/* buf 0: into Gayle's FIFO of the port */
			return 0;
		cc.n = k;
		cc.st = C_RUN;
		return 0;

	case C_RUN:
		if (cc.op.state)
			return 0;
		if (cc.op.err == SD_E_GAYLE)
			return cd_end(CD_GONE);	/* the Amiga abandoned the command */
		if (cc.op.err) {
			MMC_OpResult(&cc.op, "SD card read");
			return cd_card_failed();
		}
		cc.block += cc.n;
		cc.left -= cc.n;
		cc.bleft -= cc.n;
		if (cc.bleft) {
			hdd_seek_begin(&cdrom.hdf, cc.block);
			cc.st = C_SEEK;
			return 1;
		}
		cc.timeout = GetTimer(CD_TIMEOUT);
		cc.st = C_WAIT;
		return 1;

	case C_WAIT:	/* the host reads the block: one look a pass */
		if (sd_gayle_busy())
			return 0;
		r = cd_look(cc.port, cc.timeout);
		if (r == CD_WAITING)
			return 0;
		if (r != CD_DONE)
			return cd_end(r);
		if (cc.left) {
			hdd_seek_begin(&cdrom.hdf, cc.block);
			cc.st = C_SEEK;
			return 1;
		}
		cc.lba += cc.run;
		cc.count -= cc.run;
		if (!cc.count)
			return cd_end(CD_DONE);
		cc.st = C_LOCATE;
		return 1;
	}
	return 0;
}

void CD_Cancel(void)
{
	if (cc.st == C_IDLE)
		return;
	if (cc.op.state)
		sd_drain();	/* the card op over (a read needs no close) */
	ide_port = cc.port;
	if (cd_left()) {
		cd_end(CD_GONE);
		return;
	}
	WriteXfer(0, 1);	/* drop the transfer: no DRQ, no stall */
	atapi_set_sense(&cdrom.unit, 0x0B, 0x00, 0x00);
	cd_end(CD_FAILED);
}

/* Data out (MODE SELECT), in blocks of at most the limit: what fits goes to
   atapi_buf for atapi_mode_select (page 0E: the volume), the rest is
   dropped. */
static int cd_receive(int port, unsigned char *tfr, unsigned int len, unsigned int limit)
{
	unsigned int got = 0, kept = 0;
	int r;
	if (limit > CD_FIFO_512 * 512)
		limit = CD_FIFO_512 * 512;
	while (got < len) {
		unsigned int n = len - got < limit ? len - got : limit;
		cd_phase(tfr, n, 0x00, IDE_STATUS_REQ | IDE_STATUS_IRQ);
		if ((r = cd_wait(port)) != CD_DONE)
			return r;
		if (kept == got && got + n <= ATAPI_BUF_SIZE) {
			ReadIDEData(atapi_buf + got, n);
			kept += n;
		} else {
			ReadIDEData(0, n);
		}
		got += n;
	}
	atapi_mode_select(&cdrom.unit, cd_cdb, atapi_buf, kept);
	cda_volume(cdrom.unit.volume[0], cdrom.unit.volume[1]);
	return CD_DONE;
}

static void cd_log_cdb(int port, const struct atapi_result *r)
{
	int i;
	printf("CD%d CDB", port + 1);
	for (i = 0; i < 12; i++)
		printf(" %02X", cd_cdb[i]);
	switch (r->kind) {
	case ATAPI_RESPONSE: printf(" > %u bytes", (unsigned)r->length); break;
	case ATAPI_READ:     printf(" > read %lu+%lu", (unsigned long)r->lba, (unsigned long)r->count); break;
	case ATAPI_READ_CD:  printf(" > read cd %d+%d", (int)r->lba, (int)r->count); break;
	case ATAPI_RECEIVE:  printf(" < %u bytes", (unsigned)r->length); break;
	case ATAPI_CHECK:    printf(" CHECK %02X/%02X/%02X", r->sense_key, r->asc, r->ascq); break;
	case ATAPI_PLAY:     printf(" > audio %d", (int)r->audio); break;
	default:             printf(" GOOD"); break;
	}
	printf("\r\n");
}

/* PACKET (0xA0) */
static void cd_packet(int port, unsigned char *tfr)
{
	struct atapi_result r;
	unsigned int limit = tfr[4] | (tfr[5] << 8);
	int done;

	if (tfr[1] & 0x01) {	/* DMA: not here */
		cd_abort(tfr);
		return;
	}
	if (limit == 0 || limit == 0xFFFF)
		limit = 0xFFFE;
	limit &= ~1u;

	/* the command packet: the byte count registers keep the host's limit */
	WriteXfer(6, 1);
	WriteTaskFile(0, 0x01, tfr[3], tfr[4], tfr[5], tfr[6]);
	WriteStatus(IDE_STATUS_REQ);
	done = cd_wait(port);
	if (done == CD_GONE)
		return;
	if (done == CD_FAILED) {
		cd_complete(tfr, cd_error());
		return;
	}
	ReadIDEData(cd_cdb, 12);

	atapi_audio_status(&cdrom.unit, cda_status(), cda_position());
	atapi_packet(&cdrom.unit, cd_cdb, (uint16_t)limit, &r);
	if (DebugMode)
		cd_log_cdb(port, &r);
	if (r.ejected)
		cd_drop_file();
	else if (r.audio)
		cd_audio_request(&r);

	switch (r.kind) {
	case ATAPI_RESPONSE:
		done = cd_send_buffer(port, tfr, atapi_buf, r.length, limit);
		break;
	case ATAPI_READ:
	case ATAPI_READ_CD:
		cd_read_start(port, tfr, r.lba, r.count, limit);
		return;	/* goes on in CD_Step: the status at its end */
	case ATAPI_RECEIVE:
		done = cd_receive(port, tfr, r.length, limit);
		break;
	default:
		done = CD_DONE;
		break;
	}
	if (done == CD_GONE)
		return;
	cd_complete(tfr, (done == CD_FAILED || r.kind == ATAPI_CHECK) ? cd_error() : 0);
}

/* IDENTIFY PACKET DEVICE (0xA1): an ATA PIO-in command, as IDENTIFY DEVICE. */
static void cd_identify(unsigned char *tfr)
{
	int i;
	atapi_identify(cd_id, &cdrom.unit);
	for (i = 0; i < 256; i++) {	/* each word low byte first, as ATA_IdentifyDevice */
		atapi_buf[2 * i] = (unsigned char)cd_id[i];
		atapi_buf[2 * i + 1] = (unsigned char)(cd_id[i] >> 8);
	}
	WriteTaskFile(0, tfr[2], tfr[3], tfr[4], tfr[5], tfr[6]);
	WriteStatus(IDE_STATUS_RDY);
	WriteIDEData(atapi_buf, 512);
	WriteStatus(IDE_STATUS_END | IDE_STATUS_IRQ);
}

void CD_HandleCommand(int port, unsigned char *tfr)
{
	cd_in_command = 1;
	if (DebugMode)
		printf("CD%d ATA %02X fe %02X sc %02X bc %02X%02X dh %02X\r\n",
		       port + 1, tfr[7], tfr[1], tfr[2], tfr[5], tfr[4], tfr[6]);

	switch (tfr[7]) {
	case 0xA0:	/* PACKET */
		cd_packet(port, tfr);
		break;
	case 0xA1:	/* IDENTIFY PACKET DEVICE */
		cd_identify(tfr);
		break;
	case 0xEC:	/* IDENTIFY DEVICE: abort with the signature (how a host learns to send A1) */
		WriteTaskFile(0x04, 0x01, 0x01, 0x14, 0xEB, tfr[6]);
		WriteStatus(IDE_STATUS_END | IDE_STATUS_IRQ | IDE_STATUS_ERR);
		break;
	case 0x90:	/* EXECUTE DEVICE DIAGNOSTIC: passed, signature */
		WriteTaskFile(0x01, 0x01, 0x01, 0x14, 0xEB, tfr[6]);
		WriteStatus(IDE_STATUS_END | IDE_STATUS_IRQ | IDE_STATUS_SIG);
		break;
	case 0x08:	/* DEVICE RESET: signature, no interrupt */
		WriteTaskFile(0x01, 0x01, 0x01, 0x14, 0xEB, tfr[6]);
		WriteStatus(IDE_STATUS_END | IDE_STATUS_SIG);
		break;
	case 0xEF:	/* SET FEATURES: transfer mode accepted, the rest aborted */
		if (tfr[1] == 0x03)
			WriteStatus(IDE_STATUS_END | IDE_STATUS_IRQ);
		else
			cd_abort(tfr);
		break;
	default:	/* NOP and every other ATA command */
		cd_abort(tfr);
		break;
	}
	if (cc.st == C_IDLE)
		cd_in_command = 0;	/* else the READ's states clear it at their end */
}

/*
 * ATAPI CD-ROM command layer -- see atapi.h and findings/cdrom/plan.md 7.2.
 *
 * No hardware access, no malloc, small stack: every response is built in
 * the static atapi_buf, byte by byte, big-endian as SCSI wants.
 */

#include <string.h>
#include "atapi.h"

uint8_t atapi_buf[ATAPI_BUF_SIZE];

/* Every response here fits in this many bytes (MODE SENSE(10) 3F: 52). */
#define RESP_MAX 64

#define LEADOUT_TRACK  0xAA
#define ADR_CTRL_DATA  0x14	/* ADR 1 (position), control 4 (data track) */
#define ADR_CTRL_AUDIO 0x10	/* ADR 1, control 0 (2-channel audio, no pre-emphasis) */

static const char empty_name[] = "CD-ROM (empty)";

static void put16(uint8_t *p, uint32_t v)
{
	p[0] = (uint8_t)(v >> 8);
	p[1] = (uint8_t)v;
}

static void put32(uint8_t *p, uint32_t v)
{
	p[0] = (uint8_t)(v >> 24);
	p[1] = (uint8_t)(v >> 16);
	p[2] = (uint8_t)(v >> 8);
	p[3] = (uint8_t)v;
}

static uint32_t get16(const uint8_t *p)
{
	return ((uint32_t)p[0] << 8) | p[1];
}

static uint32_t get32(const uint8_t *p)
{
	return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

/* Address field: LBA, or MSF (0, M, S, F) with the 150-frame pregap. */
static void put_addr(uint8_t *p, uint32_t lba, int msf)
{
	if (msf) {
		uint32_t f = lba + 150;
		p[0] = 0;
		p[1] = (uint8_t)(f / (75 * 60));
		p[2] = (uint8_t)((f / 75) % 60);
		p[3] = (uint8_t)(f % 75);
	} else {
		put32(p, lba);
	}
}

static uint8_t adr_ctrl(const struct cd_track *t)
{
	return t->type == CD_AUDIO ? ADR_CTRL_AUDIO : ADR_CTRL_DATA;
}

/* Does [lba, lba + count) touch an audio track (audio = 1) or a data track
   (audio = 0), gaps included?  The
   range is inside the disc. */
static int touches(const struct cd_disc *d, uint32_t lba, uint32_t count, int audio)
{
	struct cue_loc l;
	while (count) {
		uint32_t n;
		if (!cue_locate(d, lba, &l))
			return 0;
		if ((d->track[l.track].type == CD_AUDIO) == audio)
			return 1;
		n = l.run < count ? l.run : count;
		lba += n;
		count -= n;
	}
	return 0;
}

static const char *disc_name(const struct atapi_unit *u)
{
	if (!u->media)
		return empty_name;
	return u->name[0] ? u->name : "CD-ROM";
}

/* Space-padded copy of len bytes. */
static void pad_copy(uint8_t *dst, const char *src, unsigned len)
{
	unsigned i;
	for (i = 0; i < len && src[i]; i++)
		dst[i] = (uint8_t)src[i];
	for (; i < len; i++)
		dst[i] = ' ';
}

/* ATA string: two characters per word, the first in bits 15:8. */
static void ata_string(uint16_t *w, const char *s, unsigned bytes)
{
	uint8_t tmp[ATAPI_NAME_LEN];
	unsigned i;
	pad_copy(tmp, s, bytes);
	for (i = 0; i < bytes; i += 2)
		w[i / 2] = (uint16_t)((tmp[i] << 8) | tmp[i + 1]);
}

static void set_sense(struct atapi_unit *u, uint8_t key, uint8_t asc, uint8_t ascq)
{
	u->sense_key = key;
	u->asc = asc;
	u->ascq = ascq;
}

static int good(struct atapi_unit *u, struct atapi_result *r)
{
	set_sense(u, 0, 0, 0);
	r->kind = ATAPI_DONE;
	return ATAPI_DONE;
}

static int check(struct atapi_unit *u, struct atapi_result *r, uint8_t key, uint8_t asc, uint8_t ascq)
{
	set_sense(u, key, asc, ascq);
	r->sense_key = key;
	r->asc = asc;
	r->ascq = ascq;
	r->kind = ATAPI_CHECK;
	return ATAPI_CHECK;
}

#define ILLEGAL_FIELD(u, r) check(u, r, 0x05, 0x24, 0x00)

/* Data in of full bytes, cut to the allocation length; nothing left = no data phase. */
static int respond(struct atapi_unit *u, struct atapi_result *r, uint32_t full, uint32_t alloc)
{
	if (alloc < full)
		full = alloc;
	if (!full)
		return good(u, r);
	set_sense(u, 0, 0, 0);
	r->length = (uint16_t)full;
	r->kind = ATAPI_RESPONSE;
	return ATAPI_RESPONSE;
}

/* ---- drive state ---- */

void atapi_init(struct atapi_unit *u)
{
	memset(u, 0, sizeof(*u));
	u->audio_status = ATAPI_AUDIO_NONE;
	u->volume[0] = 0xFF;
	u->volume[1] = 0xFF;
}

void atapi_audio_status(struct atapi_unit *u, int32_t status, uint32_t lba)
{
	if (status == ATAPI_AUDIO_COMPLETED || status == ATAPI_AUDIO_ERROR) {
		if (u->audio_seen == status)
			status = ATAPI_AUDIO_NONE;	/* reported once already */
	} else {
		u->audio_seen = 0;
	}
	u->audio_status = status;
	u->audio_lba = lba;
}

void atapi_reset(struct atapi_unit *u)
{
	u->locked = 0;
	u->ua_asc = 0x29;
	set_sense(u, 0, 0, 0);
}

int atapi_insert(struct atapi_unit *u, const struct cd_disc *disc, const char *name)
{
	unsigned i;
	if (u->media && u->locked)
		return ATAPI_LOCKED;
	for (i = 0; i < ATAPI_NAME_LEN && name && name[i]; i++) {
		uint8_t c = (uint8_t)name[i];
		u->name[i] = (c < 0x20 || c > 0x7E) ? '_' : (char)c;
	}
	u->name[i] = 0;
	u->disc = disc;
	u->sectors = disc->leadout;
	u->media = 1;
	u->ua_asc = 0x28;
	u->event = ATAPI_EVENT_NEW_MEDIA;
	return ATAPI_OK;
}

int atapi_eject(struct atapi_unit *u)
{
	if (u->locked)
		return ATAPI_LOCKED;
	if (u->media) {
		u->media = 0;
		u->sectors = 0;
		u->disc = 0;
		u->name[0] = 0;
		u->event = ATAPI_EVENT_REMOVED;
	}
	return ATAPI_OK;
}

int atapi_locked(const struct atapi_unit *u)
{
	return u->locked;
}

void atapi_set_sense(struct atapi_unit *u, uint8_t key, uint8_t asc, uint8_t ascq)
{
	set_sense(u, key, asc, ascq);
}

void atapi_identify(uint16_t *id, const struct atapi_unit *u)
{
	int i;
	memset(id, 0, 256 * sizeof(uint16_t));
	id[0] = 0x8580;		/* ATAPI, CD-ROM, removable, 12-byte packets */
	ata_string(id + 10, "MINIMIGCD0", 20);
	ata_string(id + 23, "1.00", 8);
	ata_string(id + 27, disc_name(u), ATAPI_NAME_LEN);
	id[49] = 0x0200;	/* LBA */
	id[53] = 0x0007;
	id[80] = 0x007E;
	id[82] = 0x4014;	/* NOP, PACKET, removable media */
	id[83] = 0x7000;
	for (i = 84; i <= 87; i++)
		id[i] = 0x4000;
}

/* ---- commands ---- */

static int inquiry(struct atapi_unit *u, const uint8_t *cdb, struct atapi_result *r)
{
	uint8_t *b = atapi_buf;
	if (cdb[1] & 0x01)	/* EVPD: no vital product data pages */
		return ILLEGAL_FIELD(u, r);
	b[0] = 0x05;		/* CD-ROM */
	b[1] = 0x80;		/* removable */
	b[2] = 0x00;
	b[3] = 0x21;
	b[4] = 36 - 5;
	pad_copy(b + 8, "MINIMIG", 8);
	pad_copy(b + 16, disc_name(u), 16);
	pad_copy(b + 32, "1.00", 4);
	return respond(u, r, 36, cdb[4]);
}

static int request_sense(struct atapi_unit *u, const uint8_t *cdb, struct atapi_result *r)
{
	uint8_t *b = atapi_buf;
	uint8_t key = u->sense_key, asc = u->asc, ascq = u->ascq;
	if (!key) {
		if (u->ua_asc) {	/* a pending UNIT ATTENTION is reported and cleared */
			key = 0x06;
			asc = u->ua_asc;
			ascq = 0;
			u->ua_asc = 0;
		} else if (!u->media) {
			key = 0x02;
			asc = 0x3A;
			ascq = 0;
		}
	}
	b[0] = 0x70;
	b[2] = key;
	b[7] = 18 - 8;
	b[12] = asc;
	b[13] = ascq;
	return respond(u, r, 18, cdb[4]);
}

static uint8_t *mode_page(uint8_t *p, uint8_t code, const struct atapi_unit *u)
{
	switch (code) {
	case 0x01:		/* read error recovery */
		p[0] = 0x01;
		p[1] = 0x06;
		p[3] = 3;	/* read retry count */
		return p + 8;
	case 0x0E:		/* CD audio control */
		p[0] = 0x0E;
		p[1] = 0x0E;
		p[2] = 0x04;	/* IMMED */
		p[8] = 0x01;	/* port 0: channel 0 */
		p[9] = u->volume[0];
		p[10] = 0x02;	/* port 1: channel 1 */
		p[11] = u->volume[1];
		return p + 16;
	case 0x2A:		/* capabilities: CD-ROM read, audio play (13.6) */
		p[0] = 0x2A;
		p[1] = 0x12;
		p[4] = 0x01;	/* audio play */
		p[6] = (uint8_t)(0x29 | (u->locked ? 0x02 : 0));	/* tray, eject, lock (+ state) */
		put16(p + 8, 706);	/* max read speed, KB/s (4x) */
		put16(p + 10, 256);	/* volume levels */
		put16(p + 12, 64);	/* buffer, KB */
		put16(p + 14, 706);	/* current read speed */
		return p + 20;
	}
	return p;
}

static int mode_sense(struct atapi_unit *u, const uint8_t *cdb, struct atapi_result *r)
{
	uint8_t *b = atapi_buf;
	int six = cdb[0] == 0x1A;
	uint8_t page = cdb[2] & 0x3F;	/* bits 7:6 page control: current values for all */
	uint8_t *p = b + (six ? 4 : 8);
	uint8_t *start = p;
	uint32_t total;

	if (page == 0x3F) {
		p = mode_page(p, 0x01, u);
		p = mode_page(p, 0x0E, u);
		p = mode_page(p, 0x2A, u);
	} else {
		p = mode_page(p, page, u);
	}
	if (p == start)
		return ILLEGAL_FIELD(u, r);
	total = (uint32_t)(p - b);
	if (six) {
		b[0] = (uint8_t)(total - 1);
		return respond(u, r, total, cdb[4]);
	}
	put16(b, total - 2);
	return respond(u, r, total, get16(cdb + 7));
}

static void toc_entry(uint8_t *p, uint8_t ctrl, uint8_t track, uint32_t lba, int msf)
{
	p[1] = ctrl;
	p[2] = track;
	put_addr(p + 4, lba, msf);
}

static int read_toc(struct atapi_unit *u, const uint8_t *cdb, struct atapi_result *r)
{
	const struct cd_disc *d = u->disc;
	uint8_t *b = atapi_buf;
	uint8_t *p = b + 4;
	int msf = cdb[1] & 0x02;
	uint8_t format = cdb[2] & 0x0F;
	uint8_t track = cdb[6];
	int32_t i, first;

	memset(b, 0, 4 + 8 * (CD_MAX_TRACKS + 1));	/* 99 tracks + lead-out: 804 bytes */
	if (!format)
		format = cdb[9] >> 6;	/* SFF-8020 drivers put the format here */
	b[2] = 1;	/* first track / session */
	b[3] = 1;	/* last session */
	if (format == 0) {
		b[3] = (uint8_t)d->tracks;	/* last track */
		if (track == LEADOUT_TRACK)
			first = d->tracks;	/* the lead-out only */
		else if (track <= 1)
			first = 0;
		else if (track <= d->tracks)
			first = track - 1;
		else
			return ILLEGAL_FIELD(u, r);
		for (i = first; i < d->tracks; i++) {
			toc_entry(p, adr_ctrl(&d->track[i]), d->track[i].number, d->track[i].lba, msf);
			p += 8;
		}
		toc_entry(p, adr_ctrl(&d->track[d->tracks - 1]), LEADOUT_TRACK, d->leadout, msf);
		p += 8;
	} else if (format == 1) {
		toc_entry(p, adr_ctrl(&d->track[0]), 1, d->track[0].lba, msf);	/* first track of the last session */
		p += 8;
	} else {
		return ILLEGAL_FIELD(u, r);
	}
	put16(b, (uint32_t)(p - b) - 2);
	return respond(u, r, (uint32_t)(p - b), get16(cdb + 7));
}

/* Relative address in a track: LBA (negative in the gap before INDEX 01),
   or MSF counting away from INDEX 01 without the 150-frame offset. */
static void put_rel(uint8_t *p, int32_t rel, int msf)
{
	if (msf) {
		uint32_t a = (uint32_t)(rel < 0 ? -rel : rel);
		p[0] = 0;
		p[1] = (uint8_t)(a / (75 * 60));
		p[2] = (uint8_t)((a / 75) % 60);
		p[3] = (uint8_t)(a % 75);
	} else {
		put32(p, (uint32_t)rel);
	}
}

static int read_subchannel(struct atapi_unit *u, const uint8_t *cdb, struct atapi_result *r)
{
	const struct cd_disc *d = u->disc;
	uint8_t *b = atapi_buf;
	uint32_t n = 0;
	int32_t status = u->audio_status;
	b[1] = (uint8_t)status;	/* audio status: the player's */
	if (cdb[2] & 0x40) {	/* SubQ */
		uint8_t format = cdb[3];
		b[4] = format;
		if (format == 1) {	/* current position: where the player is */
			const struct cd_track *t;
			struct cue_loc l;
			uint32_t lba = u->audio_lba < u->sectors ? u->audio_lba : 0;
			int msf = cdb[1] & 0x02;
			cue_locate(d, lba, &l);
			t = &d->track[l.track];
			b[5] = adr_ctrl(t);
			b[6] = t->number;
			b[7] = (uint8_t)l.index;
			put_addr(b + 8, lba, msf);
			put_rel(b + 12, (int32_t)lba - (int32_t)t->lba, msf);
			n = 12;
		} else if (format == 2 || format == 3) {	/* MCN / ISRC: not valid */
			if (format == 3)
				b[6] = cdb[6];
			n = 20;
		} else {
			return ILLEGAL_FIELD(u, r);
		}
	}
	if (status == ATAPI_AUDIO_COMPLETED || status == ATAPI_AUDIO_ERROR)
		u->audio_seen = status;	/* then NONE (atapi_audio_status) */
	put16(b + 2, n);
	return respond(u, r, 4 + n, get16(cdb + 7));
}

static int get_configuration(struct atapi_unit *u, const uint8_t *cdb, struct atapi_result *r)
{
	uint8_t *b = atapi_buf;
	uint8_t *p = b + 8;
	uint32_t start = get16(cdb + 2);
	int only = (cdb[1] & 0x03) == 0x02;	/* RT 2: the starting feature alone */
	put16(b + 6, 0x0008);	/* current profile: CD-ROM */
	if (start == 0) {	/* the profile list */
		p[2] = 0x03;	/* persistent, current */
		p[3] = 4;
		put16(p + 4, 0x0008);
		p[6] = 0x01;	/* current */
		p += 8;
	}
	if (only ? start == 0x0103 : start <= 0x0103) {	/* CD audio external play */
		put16(p, 0x0103);
		p[2] = u->media ? 0x01 : 0x00;	/* current with a disc in */
		p[3] = 4;
		p[4] = 0x03;	/* separate channel mute, separate volume */
		put16(p + 6, 256);	/* volume levels */
		p += 8;
	}
	put32(b, (uint32_t)(p - b) - 4);
	return respond(u, r, (uint32_t)(p - b), get16(cdb + 7));
}

static int event_status(struct atapi_unit *u, const uint8_t *cdb, struct atapi_result *r)
{
	uint8_t *b = atapi_buf;
	uint32_t alloc = get16(cdb + 7);
	if (!(cdb[1] & 0x01))	/* asynchronous notification not supported */
		return ILLEGAL_FIELD(u, r);
	b[3] = 0x10;		/* supported classes: media */
	if (!(cdb[4] & 0x10)) {	/* no supported class requested */
		b[1] = 2;
		b[2] = 0x80;	/* NEA */
		return respond(u, r, 4, alloc);
	}
	b[1] = 6;
	b[2] = 0x04;		/* media class */
	b[4] = u->event;
	b[5] = u->media ? 0x02 : 0x00;
	if (alloc > 4)		/* one-shot: gone once the host has seen it */
		u->event = ATAPI_EVENT_NONE;
	return respond(u, r, 8, alloc);
}

static int disc_information(struct atapi_unit *u, const uint8_t *cdb, struct atapi_result *r)
{
	uint8_t *b = atapi_buf;
	if (cdb[1] & 0x07)
		return ILLEGAL_FIELD(u, r);
	b[1] = 32;
	b[2] = 0x0E;		/* complete disc, complete session */
	b[3] = 1;		/* first track */
	b[4] = 1;		/* sessions */
	b[5] = 1;		/* first track in last session */
	b[6] = (uint8_t)u->disc->tracks;	/* last track in last session */
	b[7] = 0x20;		/* unrestricted use */
	memset(b + 16, 0xFF, 8);	/* lead-in / last lead-out start: complete disc */
	return respond(u, r, 34, get16(cdb + 7));
}

static int track_information(struct atapi_unit *u, const uint8_t *cdb, struct atapi_result *r)
{
	const struct cd_disc *d = u->disc;
	const struct cd_track *t;
	uint8_t *b = atapi_buf;
	uint32_t n = get32(cdb + 2), end;
	uint8_t type = cdb[1] & 0x03;
	struct cue_loc l;
	int32_t i;
	if (type == 0 && cue_locate(d, n, &l))
		i = l.track;				/* the track holding LBA n */
	else if (type == 1 && n >= 1 && n <= (uint32_t)d->tracks)
		i = (int32_t)n - 1;			/* track n */
	else if (type == 2 && n == 1)
		i = 0;					/* session 1: its first track */
	else
		return ILLEGAL_FIELD(u, r);
	t = &d->track[i];
	end = i + 1 < d->tracks ? d->track[i + 1].lba : d->leadout;
	put16(b, 28 - 2);
	b[2] = t->number;	/* track */
	b[3] = 1;		/* session */
	b[5] = t->type == CD_AUDIO ? 0x00 : 0x04;	/* track mode: the control nibble */
	b[6] = t->type == CD_AUDIO ? 0x0F : 0x01;	/* data mode: unknown (audio) / mode 1 */
	put32(b + 8, t->lba);	/* track start */
	put32(b + 24, end - t->lba);	/* track size */
	return respond(u, r, 28, get16(cdb + 7));
}

static int read_sectors(struct atapi_unit *u, const uint8_t *cdb, struct atapi_result *r)
{
	uint32_t lba = get32(cdb + 2);
	uint32_t count = cdb[0] == 0x28 ? get16(cdb + 7) : get32(cdb + 6);
	if (!count)
		return good(u, r);
	if (lba >= u->sectors || count > u->sectors - lba)
		return check(u, r, 0x05, 0x21, 0x00);
	if (touches(u->disc, lba, count, 1))	/* audio sectors are not READ(10) data */
		return check(u, r, 0x05, 0x64, 0x00);
	set_sense(u, 0, 0, 0);
	r->lba = lba;
	r->count = count;
	r->kind = ATAPI_READ;
	return ATAPI_READ;
}

static int start_stop(struct atapi_unit *u, const uint8_t *cdb, struct atapi_result *r)
{
	if ((cdb[4] & 0x03) == 0x02) {	/* LoEj, not Start: eject */
		if (atapi_eject(u) != ATAPI_OK)
			return check(u, r, 0x05, 0x53, 0x02);
		r->ejected = 1;
	}
	if (!(cdb[4] & 0x01))	/* stop or eject: playback ends */
		r->audio = ATAPI_AUDIO_STOP;
	return good(u, r);
}

/* ---- audio (13.6) ---- */

/* A play request for sectors start .. end - 1 (end > start). */
static int play(struct atapi_unit *u, struct atapi_result *r, uint32_t start, uint32_t end)
{
	const struct cd_disc *d = u->disc;
	struct cue_loc l;
	if (start >= u->sectors || end > u->sectors)
		return check(u, r, 0x05, 0x21, 0x00);
	cue_locate(d, start, &l);
	if (d->track[l.track].type != CD_AUDIO)	/* starts in a data track */
		return check(u, r, 0x05, 0x64, 0x00);
	set_sense(u, 0, 0, 0);
	u->audio_seen = 0;
	r->audio = ATAPI_AUDIO_PLAY;
	r->lba = start;
	r->count = end - start;
	r->kind = ATAPI_PLAY;
	return ATAPI_PLAY;
}

/* PLAY AUDIO(10) 45 / (12) A5: LBA + length; length 0 does nothing. */
static int play_lba(struct atapi_unit *u, const uint8_t *cdb, struct atapi_result *r)
{
	uint32_t lba = get32(cdb + 2);
	uint32_t len = cdb[0] == 0x45 ? get16(cdb + 7) : get32(cdb + 6);
	if (!len)
		return good(u, r);
	if (lba >= u->sectors || len > u->sectors - lba)
		return check(u, r, 0x05, 0x21, 0x00);
	return play(u, r, lba, lba + len);
}

/* MSF -> LBA; addresses in the first 2 seconds (the lead-in pregap) are LBA 0. */
static uint32_t msf_lba(const uint8_t *p)
{
	uint32_t f = ((uint32_t)p[0] * 60 + p[1]) * 75 + p[2];
	return f < 150 ? 0 : f - 150;
}

/* PLAY AUDIO MSF 47: start MSF (3-5) .. end MSF (6-8). */
static int play_msf(struct atapi_unit *u, const uint8_t *cdb, struct atapi_result *r)
{
	uint32_t start = msf_lba(cdb + 3), end = msf_lba(cdb + 6);
	if (start == end)
		return good(u, r);
	if (start > end)
		return ILLEGAL_FIELD(u, r);
	return play(u, r, start, end);
}

/* PLAY AUDIO TRACK/INDEX 48: from track cdb[4] index cdb[5] through track
   cdb[7] index cdb[8].  Index 0 = the gap before INDEX 01; 1 and up = the
   track (there are no higher indexes); an end track past the last plays
   to the end of the disc. */
static int play_track(struct atapi_unit *u, const uint8_t *cdb, struct atapi_result *r)
{
	const struct cd_disc *d = u->disc;
	int32_t st = cdb[4], et = cdb[7];
	uint32_t start, end;
	if (st < 1 || st > d->tracks || et < st)
		return ILLEGAL_FIELD(u, r);
	if (et > d->tracks)
		et = d->tracks;
	start = cdb[5] ? d->track[st - 1].lba : d->track[st - 1].pregap_lba;
	if (!cdb[8])
		end = d->track[et - 1].lba;
	else
		end = et < d->tracks ? d->track[et].pregap_lba : d->leadout;
	if (end <= start)
		return ILLEGAL_FIELD(u, r);
	return play(u, r, start, end);
}

/* READ CD (BE): user data of data sectors (2048 bytes), CD-DA of audio
   sectors (2352); no sync, headers, EDC/ECC, C2 or subchannel (13.6).
   Expected sector type (byte 1 bits 4:2): 0 any, 1 CD-DA, 2 Mode 1; the
   Mode 2 types match no track here. */
static int read_cd(struct atapi_unit *u, const uint8_t *cdb, struct atapi_result *r)
{
	uint32_t lba = get32(cdb + 2);
	uint32_t count = ((uint32_t)cdb[6] << 16) | ((uint32_t)cdb[7] << 8) | cdb[8];
	uint8_t type = (cdb[1] >> 2) & 0x07;
	if (cdb[9] != 0x10 || (cdb[10] & 0x07) || type > 5)
		return ILLEGAL_FIELD(u, r);
	if (!count)
		return good(u, r);
	if (lba >= u->sectors || count > u->sectors - lba)
		return check(u, r, 0x05, 0x21, 0x00);
	if (type > 2 || (type == 1 && touches(u->disc, lba, count, 0)) || (type == 2 && touches(u->disc, lba, count, 1)))
		return check(u, r, 0x05, 0x64, 0x00);
	set_sense(u, 0, 0, 0);
	r->lba = lba;
	r->count = count;
	r->kind = ATAPI_READ_CD;
	return ATAPI_READ_CD;
}

/* PAUSE/RESUME 4B, STOP PLAY/SCAN 4E: a request for the player. */
static int audio_request(struct atapi_unit *u, struct atapi_result *r, int32_t what)
{
	set_sense(u, 0, 0, 0);
	r->audio = what;
	r->kind = ATAPI_PLAY;
	return ATAPI_PLAY;
}

int atapi_packet(struct atapi_unit *u, const uint8_t *cdb, uint16_t limit, struct atapi_result *r)
{
	uint8_t op = cdb[0];

	memset(r, 0, sizeof(*r));
	memset(atapi_buf, 0, RESP_MAX);

	switch (op) {	/* exempt from UNIT ATTENTION and the no-disc rule */
	case 0x03:
		return request_sense(u, cdb, r);
	case 0x12:
		return inquiry(u, cdb, r);
	case 0x46:
		return get_configuration(u, cdb, r);
	case 0x4A:
		return event_status(u, cdb, r);
	}

	if (u->ua_asc) {
		uint8_t asc = u->ua_asc;
		u->ua_asc = 0;
		return check(u, r, 0x06, asc, 0x00);
	}
	if (!u->media)
		return check(u, r, 0x02, 0x3A, 0x00);

	switch (op) {
	case 0x00:	/* TEST UNIT READY */
	case 0x2B:	/* SEEK(10) */
	case 0x35:	/* SYNCHRONIZE CACHE */
	case 0xBC:	/* PLAY CD: not in 13.6 */
		return good(u, r);
	case 0x45:	/* PLAY AUDIO(10) */
	case 0xA5:	/* PLAY AUDIO(12) */
		return play_lba(u, cdb, r);
	case 0x47:
		return play_msf(u, cdb, r);
	case 0x48:
		return play_track(u, cdb, r);
	case 0x4B:	/* PAUSE / RESUME: byte 8 bit 0 */
		return audio_request(u, r, (cdb[8] & 0x01) ? ATAPI_AUDIO_RESUME : ATAPI_AUDIO_PAUSE);
	case 0x4E:	/* STOP PLAY / SCAN */
		return audio_request(u, r, ATAPI_AUDIO_STOP);
	case 0x1A:
	case 0x5A:
		return mode_sense(u, cdb, r);
	case 0x1B:
		return start_stop(u, cdb, r);
	case 0x1E:	/* PREVENT / ALLOW MEDIUM REMOVAL */
		u->locked = cdb[4] & 0x01;
		return good(u, r);
	case 0x25:	/* READ CAPACITY */
		put32(atapi_buf, u->sectors - 1);
		put32(atapi_buf + 4, ATAPI_SECTOR_SIZE);
		return respond(u, r, 8, 8);
	case 0x28:
	case 0xA8:
		return read_sectors(u, cdb, r);
	case 0x42:
		return read_subchannel(u, cdb, r);
	case 0x43:
		return read_toc(u, cdb, r);
	case 0x51:
		return disc_information(u, cdb, r);
	case 0x52:
		return track_information(u, cdb, r);
	case 0x15:	/* MODE SELECT(6) */
	case 0x55:	/* MODE SELECT(10): the data go to atapi_mode_select */
		r->length = (uint16_t)(op == 0x15 ? cdb[4] : get16(cdb + 7));
		if (!r->length)
			return good(u, r);
		set_sense(u, 0, 0, 0);
		r->kind = ATAPI_RECEIVE;
		return ATAPI_RECEIVE;
	case 0xBE:
		return read_cd(u, cdb, r);
	}
	/* READ CD MSF (B9) and the vendor variants (D8 D9) land here */
	return check(u, r, 0x05, 0x20, 0x00);
}

void atapi_mode_select(struct atapi_unit *u, const uint8_t *cdb, const uint8_t *data, uint32_t len)
{
	int six = cdb[0] == 0x15;
	uint32_t p = six ? 4 : 8;	/* the parameter header */
	if (len < p)
		return;
	p += six ? data[3] : get16(data + 6);	/* block descriptors */
	while (p + 2 <= len) {
		uint8_t code = data[p] & 0x3F;
		uint32_t plen = data[p + 1];
		if (code == 0x0E && plen >= 10 && p + 12 <= len) {	/* CD audio control */
			u->volume[0] = data[p + 9];	/* port 0 = left; the mapping is fixed */
			u->volume[1] = data[p + 11];	/* port 1 = right */
		}
		p += 2 + plen;
	}
}

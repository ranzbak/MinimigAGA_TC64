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

#define LEADOUT_TRACK 0xAA
#define ADR_CTRL_DATA 0x14	/* ADR 1 (position), control 4 (data track) */

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
}

void atapi_reset(struct atapi_unit *u)
{
	u->locked = 0;
	u->ua_asc = 0x29;
	set_sense(u, 0, 0, 0);
}

int atapi_insert(struct atapi_unit *u, uint32_t sectors, const char *name)
{
	unsigned i;
	if (u->media && u->locked)
		return ATAPI_LOCKED;
	for (i = 0; i < ATAPI_NAME_LEN && name && name[i]; i++) {
		uint8_t c = (uint8_t)name[i];
		u->name[i] = (c < 0x20 || c > 0x7E) ? '_' : (char)c;
	}
	u->name[i] = 0;
	u->sectors = sectors;
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
		p[8] = 0x01;	/* port 0: channel 0, full volume */
		p[9] = 0xFF;
		p[10] = 0x02;	/* port 1: channel 1, full volume */
		p[11] = 0xFF;
		return p + 16;
	case 0x2A:		/* capabilities: CD-ROM read, no audio play until phase 3 */
		p[0] = 0x2A;
		p[1] = 0x12;
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

static void toc_entry(uint8_t *p, uint8_t track, uint32_t lba, int msf)
{
	p[1] = ADR_CTRL_DATA;
	p[2] = track;
	put_addr(p + 4, lba, msf);
}

static int read_toc(struct atapi_unit *u, const uint8_t *cdb, struct atapi_result *r)
{
	uint8_t *b = atapi_buf;
	uint8_t *p = b + 4;
	int msf = cdb[1] & 0x02;
	uint8_t format = cdb[2] & 0x0F;
	uint8_t track = cdb[6];

	if (!format)
		format = cdb[9] >> 6;	/* SFF-8020 drivers put the format here */
	b[2] = 1;	/* first track / session */
	b[3] = 1;	/* last track / session */
	if (format == 0) {
		if (track <= 1) {
			toc_entry(p, 1, 0, msf);
			p += 8;
		} else if (track != LEADOUT_TRACK) {
			return ILLEGAL_FIELD(u, r);
		}
		toc_entry(p, LEADOUT_TRACK, u->sectors, msf);
		p += 8;
	} else if (format == 1) {
		toc_entry(p, 1, 0, msf);	/* first track of the last session */
		p += 8;
	} else {
		return ILLEGAL_FIELD(u, r);
	}
	put16(b, (uint32_t)(p - b) - 2);
	return respond(u, r, (uint32_t)(p - b), get16(cdb + 7));
}

static int read_subchannel(struct atapi_unit *u, const uint8_t *cdb, struct atapi_result *r)
{
	uint8_t *b = atapi_buf;
	uint32_t n = 0;
	b[1] = 0x15;		/* audio status: none */
	if (cdb[2] & 0x40) {	/* SubQ */
		uint8_t format = cdb[3];
		b[4] = format;
		if (format == 1) {	/* current position: start of track 1 */
			b[5] = ADR_CTRL_DATA;
			b[6] = 1;
			b[7] = 1;
			put_addr(b + 8, 0, cdb[1] & 0x02);
			n = 12;	/* relative address 0 in either format */
		} else if (format == 2 || format == 3) {	/* MCN / ISRC: not valid */
			if (format == 3)
				b[6] = cdb[6];
			n = 20;
		} else {
			return ILLEGAL_FIELD(u, r);
		}
	}
	put16(b + 2, n);
	return respond(u, r, 4 + n, get16(cdb + 7));
}

static int get_configuration(struct atapi_unit *u, const uint8_t *cdb, struct atapi_result *r)
{
	uint8_t *b = atapi_buf;
	uint32_t total = 8;
	put16(b + 6, 0x0008);	/* current profile: CD-ROM */
	if (get16(cdb + 2) == 0) {	/* starting feature 0: the profile list */
		b[10] = 0x03;	/* persistent, current */
		b[11] = 4;
		put16(b + 12, 0x0008);
		b[14] = 0x01;	/* current */
		total = 16;
	}
	put32(b, total - 4);
	return respond(u, r, total, get16(cdb + 7));
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
	b[6] = 1;		/* last track in last session */
	b[7] = 0x20;		/* unrestricted use */
	memset(b + 16, 0xFF, 8);	/* lead-in / last lead-out start: complete disc */
	return respond(u, r, 34, get16(cdb + 7));
}

static int track_information(struct atapi_unit *u, const uint8_t *cdb, struct atapi_result *r)
{
	uint8_t *b = atapi_buf;
	uint32_t n = get32(cdb + 2);
	uint8_t type = cdb[1] & 0x03;
	if (!((type == 0 && n < u->sectors) || (type != 0 && n == 1)))
		return ILLEGAL_FIELD(u, r);
	put16(b, 28 - 2);
	b[2] = 1;		/* track */
	b[3] = 1;		/* session */
	b[5] = 0x04;		/* track mode: data */
	b[6] = 0x01;		/* data mode 1 */
	put32(b + 24, u->sectors);	/* track size; start (8..11) is 0 */
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
	return good(u, r);
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
	case 0x45:	/* PLAY AUDIO(10)    -- phase 3 */
	case 0x47:	/* PLAY AUDIO MSF    -- phase 3 */
	case 0x4B:	/* PAUSE / RESUME    -- phase 3 */
	case 0x4E:	/* STOP PLAY / SCAN  -- phase 3 */
	case 0xBC:	/* PLAY CD           -- phase 3 */
		return good(u, r);
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
	case 0x55:	/* MODE SELECT(10): take the data, ignore it */
		r->length = (uint16_t)get16(cdb + 7);
		if (!r->length)
			return good(u, r);
		set_sense(u, 0, 0, 0);
		r->kind = ATAPI_RECEIVE;
		return ATAPI_RECEIVE;
	}
	/* READ CD (BE B9 D8 D9) lands here until phase 3 */
	return check(u, r, 0x05, 0x20, 0x00);
}

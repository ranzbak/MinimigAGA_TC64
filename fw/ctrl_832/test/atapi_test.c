/*
 * Host test for the ATAPI CD-ROM layer (fw/ctrl_832/atapi.c).
 *
 * Plan: findings/cdrom/plan.md, sections 7.1, 7.2, 9 and task 0.1.
 * Build and run: make -C fw/ctrl_832/test
 *
 * atapi.c decides what a packet command answers; the board glue (cdrom.c)
 * moves the bytes.  Here the glue is played by run(): RESPONSE bytes are
 * checked in atapi_buf, READ results are fetched through a sector-read
 * callback backed by a real ISO (default ~/work/amiga/AmigaOS3.9.iso,
 * override with the first argument).  Without the ISO the ISO-backed cases
 * are skipped, not failed.
 *
 * Exit status: 0 when every case passed (skips allowed), 1 otherwise.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>

#include "atapi.h"

/* AmigaOS3.9.iso: 502,855,680 bytes = 245,535 sectors of 2048 bytes. */
#define OS39_SECTORS 245535u
#define OS39_NAME    "AmigaOS3.9.iso"

static int case_fails, total_fails, cases_run, cases_passed, cases_skipped;
static const char *case_name;

#define EXPECT(cond, ...) do { \
	if (!(cond)) { \
		case_fails++; \
		printf("  FAIL %s (line %d): ", case_name, __LINE__); \
		printf(__VA_ARGS__); \
		printf("\n"); \
	} \
} while (0)

static void begin(const char *name)
{
	case_name = name;
	case_fails = 0;
}

static void end(void)
{
	cases_run++;
	if (case_fails) {
		total_fails += case_fails;
		printf("FAIL  %s\n", case_name);
	} else {
		cases_passed++;
		printf("ok    %s\n", case_name);
	}
}

static void skip(const char *name, const char *why)
{
	cases_skipped++;
	printf("SKIP  %s: %s\n", name, why);
}

/* ---- the ISO behind the sector-read callback ---- */

static int iso_fd = -1;
static uint32_t iso_sectors;
static uint8_t sector[4 * ATAPI_SECTOR_SIZE];

/* What cdrom.c does with an ATAPI_READ result: fetch count sectors from lba. */
static int iso_read(uint32_t lba, uint32_t count, uint8_t *dst)
{
	off_t pos = (off_t)lba * ATAPI_SECTOR_SIZE;
	size_t len = (size_t)count * ATAPI_SECTOR_SIZE;
	if (iso_fd < 0)
		return -1;
	return pread(iso_fd, dst, len, pos) == (ssize_t)len ? 0 : -1;
}

/* ---- helpers ---- */

static struct atapi_unit U;
static struct atapi_result R;

/* An ISO of this many sectors as the disc model cdrom.c builds (cue_single).
   One model at a time: a later call changes the disc U points to. */
static struct cd_disc D;

static const struct cd_disc *iso(uint32_t sectors)
{
	cue_single(&D, "TESTDISCISO", sectors * ATAPI_SECTOR_SIZE);
	return &D;
}

/* A second disc, for swaps: the refused one must not touch the disc in. */
static struct cd_disc D2;

static const struct cd_disc *iso_other(uint32_t sectors)
{
	cue_single(&D2, "OTHERDSCISO", sectors * ATAPI_SECTOR_SIZE);
	return &D2;
}

/* The reference disc (findings/cdrom/plan.md 13.9) through the CUE parser:
   track 1 data LBA 0, track 2 audio 2358 (silent PREGAP from 2208), track
   3 audio 20283 (INDEX 00 at 20133), lead-out 41658. */
static int32_t pinball_open(void *ctx, const char *name, struct cd_file *f)
{
	static const uint32_t bytes[3] = { 4521984, 41806800, 50626800 };
	int i = name[0] - '1';
	(void)ctx;
	if (i < 0 || i > 2)
		return CUE_E_NOFILE;
	memcpy(f->shortname, "PINBALL1ISO", 12);
	f->shortname[6] = name[0];
	f->data_offset = f->wave ? 44 : 0;
	f->data_bytes = bytes[i];
	return CUE_OK;
}

static const struct cd_disc *pinball(void)
{
	static const char cue[] =
		"FILE \"1.iso\" BINARY\n TRACK 01 MODE1/2048\n INDEX 01 00:00:00\n"
		"FILE \"2.wav\" WAVE\n TRACK 02 AUDIO\n PREGAP 00:02:00\n INDEX 01 00:00:00\n"
		"FILE \"3.wav\" WAVE\n TRACK 03 AUDIO\n INDEX 00 00:00:00\n INDEX 01 00:02:00\n";
	static struct cue_parser p;
	cue_begin(&p, &D, pinball_open, 0);
	cue_feed(&p, cue, sizeof(cue) - 1);
	if (cue_end(&p) != CUE_OK)
		printf("  note: the reference CUE did not parse (error %d line %d)\n", p.error, p.error_line);
	return &D;
}

static int run(const uint8_t *cdb)
{
	int k;
	memset(&R, 0xA5, sizeof(R));
	k = atapi_packet(&U, cdb, 0xFFFE, &R);
	if (k != R.kind)
		printf("  note: atapi_packet returned %d, result kind %d\n", k, R.kind);
	return R.kind;
}

static void cdb0(uint8_t *c, uint8_t op)
{
	memset(c, 0, 12);
	c[0] = op;
}

static uint32_t be32(const uint8_t *p)
{
	return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

static uint16_t be16(const uint8_t *p)
{
	return (uint16_t)((p[0] << 8) | p[1]);
}

static void put_be32(uint8_t *p, uint32_t v)
{
	p[0] = (uint8_t)(v >> 24);
	p[1] = (uint8_t)(v >> 16);
	p[2] = (uint8_t)(v >> 8);
	p[3] = (uint8_t)v;
}

/* Sense as REQUEST SENSE reports it. */
static void expect_sense(int line, uint8_t key, uint8_t asc, uint8_t ascq)
{
	uint8_t c[12];
	cdb0(c, 0x03);
	c[4] = 18;
	if (run(c) != ATAPI_RESPONSE || R.length != 18) {
		case_fails++;
		printf("  FAIL %s (line %d): REQUEST SENSE kind %d length %d\n", case_name, line, R.kind, R.length);
		return;
	}
	if (atapi_buf[0] != 0x70 || (atapi_buf[2] & 0x0F) != key || atapi_buf[7] != 10 ||
	    atapi_buf[12] != asc || atapi_buf[13] != ascq) {
		case_fails++;
		printf("  FAIL %s (line %d): sense %02X/%02X/%02X (resp %02X, add.len %d), want %02X/%02X/%02X\n",
		       case_name, line, atapi_buf[2] & 0x0F, atapi_buf[12], atapi_buf[13], atapi_buf[0], atapi_buf[7],
		       key, asc, ascq);
	}
}

/* Command must end in CHECK CONDITION with this sense, and REQUEST SENSE must report it. */
static void expect_check(int line, const uint8_t *c, uint8_t key, uint8_t asc, uint8_t ascq)
{
	int k = run(c);
	if (k != ATAPI_CHECK || R.sense_key != key || R.asc != asc || R.ascq != ascq) {
		case_fails++;
		printf("  FAIL %s (line %d): CDB %02X kind %d sense %02X/%02X/%02X, want CHECK %02X/%02X/%02X\n",
		       case_name, line, c[0], k, R.sense_key, R.asc, R.ascq, key, asc, ascq);
		return;
	}
	expect_sense(line, key, asc, ascq);
}

static void expect_good(int line, const uint8_t *c)
{
	int k = run(c);
	if (k != ATAPI_DONE) {
		case_fails++;
		printf("  FAIL %s (line %d): CDB %02X kind %d (sense %02X/%02X/%02X), want DONE\n",
		       case_name, line, c[0], k, R.sense_key, R.asc, R.ascq);
	}
}

static void expect_response(int line, const uint8_t *c, unsigned len)
{
	int k = run(c);
	if (k != ATAPI_RESPONSE || R.length != len) {
		case_fails++;
		printf("  FAIL %s (line %d): CDB %02X kind %d length %u (sense %02X/%02X/%02X), want RESPONSE of %u\n",
		       case_name, line, c[0], k, (unsigned)R.length, R.sense_key, R.asc, R.ascq, len);
	}
}

static void expect_bytes(int line, const uint8_t *want, unsigned off, unsigned len)
{
	unsigned i;
	for (i = 0; i < len; i++) {
		if (atapi_buf[off + i] != want[i]) {
			case_fails++;
			printf("  FAIL %s (line %d): byte %u = %02X, want %02X\n",
			       case_name, line, off + i, atapi_buf[off + i], want[i]);
			return;
		}
	}
}

/* Fresh unit with a disc in and its insert UNIT ATTENTION consumed. */
static void ready_disc(const struct cd_disc *d, const char *name)
{
	uint8_t c[12];
	atapi_init(&U);
	atapi_insert(&U, d, name);
	cdb0(c, 0x00);
	run(c);	/* 06/28/00 */
	run(c);	/* GOOD */
}

/* Fresh unit with an ISO of this many sectors in (the OS 3.9 image). */
static void ready_unit(uint32_t sectors, const char *name)
{
	ready_disc(iso(sectors), name);
}

static void tur(uint8_t *c) { cdb0(c, 0x00); }

static void inquiry(uint8_t *c, uint8_t alloc)
{
	cdb0(c, 0x12);
	c[4] = alloc;
}

static void read10(uint8_t *c, uint32_t lba, uint16_t count)
{
	cdb0(c, 0x28);
	put_be32(c + 2, lba);
	c[7] = (uint8_t)(count >> 8);
	c[8] = (uint8_t)count;
}

static void read12(uint8_t *c, uint32_t lba, uint32_t count)
{
	cdb0(c, 0xA8);
	put_be32(c + 2, lba);
	put_be32(c + 6, count);
}

static void toc(uint8_t *c, int msf, uint8_t format, uint8_t track, uint16_t alloc)
{
	cdb0(c, 0x43);
	c[1] = msf ? 0x02 : 0x00;
	c[2] = format;
	c[6] = track;
	c[7] = (uint8_t)(alloc >> 8);
	c[8] = (uint8_t)alloc;
}

static void mode_sense10(uint8_t *c, uint8_t page, uint16_t alloc)
{
	cdb0(c, 0x5A);
	c[2] = page;
	c[7] = (uint8_t)(alloc >> 8);
	c[8] = (uint8_t)alloc;
}

static void mode_sense6(uint8_t *c, uint8_t page, uint8_t alloc)
{
	cdb0(c, 0x1A);
	c[2] = page;
	c[4] = alloc;
}

static void gesn(uint8_t *c, uint8_t polled, uint8_t classes, uint16_t alloc)
{
	cdb0(c, 0x4A);
	c[1] = polled;
	c[4] = classes;
	c[7] = (uint8_t)(alloc >> 8);
	c[8] = (uint8_t)alloc;
}

static void prevent(uint8_t *c, int lock)
{
	cdb0(c, 0x1E);
	c[4] = lock ? 1 : 0;
}

static void start_stop(uint8_t *c, int loej, int start)
{
	cdb0(c, 0x1B);
	c[4] = (uint8_t)((loej ? 2 : 0) | (start ? 1 : 0));
}

/* ---- cases ---- */

static void t_inquiry_name(void)
{
	static const uint8_t head[] = { 0x05, 0x80, 0x00, 0x21, 0x1F };
	uint8_t c[12];
	begin("INQUIRY: ISO name in the product field");
	ready_unit(OS39_SECTORS, OS39_NAME);
	inquiry(c, 36);
	expect_response(__LINE__, c, 36);
	expect_bytes(__LINE__, head, 0, 5);
	expect_bytes(__LINE__, (const uint8_t *)"MINIMIG ", 8, 8);
	expect_bytes(__LINE__, (const uint8_t *)"AmigaOS3.9.iso  ", 16, 16);
	expect_bytes(__LINE__, (const uint8_t *)"1.00", 32, 4);

	/* longer names: first 16 characters */
	atapi_init(&U);
	atapi_insert(&U, iso(275806), "ClassicInstallCD-53.71.iso");
	expect_response(__LINE__, c, 36);
	expect_bytes(__LINE__, (const uint8_t *)"ClassicInstallCD", 16, 16);

	/* characters outside printable ASCII never reach the host */
	atapi_init(&U);
	atapi_insert(&U, iso(100), "a\tb\x80\x7f");
	expect_response(__LINE__, c, 36);
	{
		int i, ok = 1;
		for (i = 16; i < 32; i++)
			if (atapi_buf[i] < 0x20 || atapi_buf[i] > 0x7E)
				ok = 0;
		EXPECT(ok, "product field has non-printable bytes");
		EXPECT(atapi_buf[16] == 'a', "product[0] = %02X", atapi_buf[16]);
	}
	end();
}

static void t_inquiry_empty(void)
{
	uint8_t c[12];
	begin("INQUIRY: empty drive reports \"CD-ROM (empty)\", exempt from no-disc");
	atapi_init(&U);
	inquiry(c, 36);
	expect_response(__LINE__, c, 36);
	EXPECT(atapi_buf[0] == 0x05 && atapi_buf[1] == 0x80, "type %02X rmb %02X", atapi_buf[0], atapi_buf[1]);
	expect_bytes(__LINE__, (const uint8_t *)"CD-ROM (empty)  ", 16, 16);

	/* after an eject too */
	atapi_insert(&U, iso(OS39_SECTORS), OS39_NAME);
	EXPECT(atapi_eject(&U) == ATAPI_OK, "eject refused");
	expect_response(__LINE__, c, 36);
	expect_bytes(__LINE__, (const uint8_t *)"CD-ROM (empty)  ", 16, 16);
	end();
}

static void t_alloc_truncation(void)
{
	uint8_t c[12];
	begin("allocation length truncates every response");
	ready_unit(OS39_SECTORS, OS39_NAME);
	inquiry(c, 5);
	expect_response(__LINE__, c, 5);
	EXPECT(atapi_buf[4] == 0x1F, "additional length %02X (must describe the full 36 bytes)", atapi_buf[4]);
	inquiry(c, 255);
	expect_response(__LINE__, c, 36);
	inquiry(c, 0);
	expect_good(__LINE__, c);	/* nothing to transfer: no data phase */

	toc(c, 0, 0, 0, 12);
	expect_response(__LINE__, c, 12);
	EXPECT(be16(atapi_buf) == 18, "TOC data length %u (must stay the full length)", be16(atapi_buf));

	mode_sense10(c, 0x3F, 8);
	expect_response(__LINE__, c, 8);
	EXPECT(be16(atapi_buf) == 50, "mode data length %u", be16(atapi_buf));

	cdb0(c, 0x03);
	c[4] = 8;
	expect_response(__LINE__, c, 8);

	gesn(c, 1, 0x10, 4);
	expect_response(__LINE__, c, 4);
	end();
}

static uint16_t ata_chars(const char *s)
{
	return (uint16_t)(((uint8_t)s[0] << 8) | (uint8_t)s[1]);
}

/* ATA strings: two characters per word, the first in bits 15:8. */
static void expect_ata_string(int line, const uint16_t *id, int word, const char *s, int len)
{
	int i;
	char pad[64];
	memset(pad, ' ', sizeof(pad));
	memcpy(pad, s, strlen(s));
	for (i = 0; i < len / 2; i++) {
		if (id[word + i] != ata_chars(pad + 2 * i)) {
			case_fails++;
			printf("  FAIL %s (line %d): word %d = %04X, want %04X (\"%.2s\")\n",
			       case_name, line, word + i, id[word + i], ata_chars(pad + 2 * i), pad + 2 * i);
			return;
		}
	}
}

static void t_identify_packet(void)
{
	static uint16_t id[256];
	int i, nonzero = 0;
	begin("IDENTIFY PACKET DEVICE: words 0/49/82 and the model string");
	atapi_init(&U);
	atapi_insert(&U, iso(OS39_SECTORS), OS39_NAME);
	memset(id, 0xEE, sizeof(id));
	atapi_identify(id, &U);
	EXPECT(id[0] == 0x8580, "word 0 = %04X", id[0]);
	EXPECT(id[49] == 0x0200, "word 49 = %04X", id[49]);
	EXPECT(id[82] == 0x4014, "word 82 = %04X", id[82]);
	EXPECT(id[53] == 0x0007, "word 53 = %04X", id[53]);
	EXPECT(id[80] == 0x007E, "word 80 = %04X", id[80]);
	EXPECT(id[83] == 0x7000, "word 83 = %04X", id[83]);
	for (i = 84; i <= 87; i++)
		EXPECT(id[i] == 0x4000, "word %d = %04X", i, id[i]);
	for (i = 62; i <= 64; i++)
		EXPECT(id[i] == 0, "word %d = %04X (no DMA)", i, id[i]);
	expect_ata_string(__LINE__, id, 10, "MINIMIGCD0", 20);
	expect_ata_string(__LINE__, id, 23, "1.00", 8);
	expect_ata_string(__LINE__, id, 27, OS39_NAME, 40);
	EXPECT(id[27] == (('A' << 8) | 'm'), "word 27 = %04X, byte order", id[27]);
	for (i = 88; i < 256; i++)
		if (id[i])
			nonzero++;
	EXPECT(nonzero == 0, "%d words above 87 are not zero", nonzero);

	atapi_init(&U);
	atapi_identify(id, &U);
	expect_ata_string(__LINE__, id, 27, "CD-ROM (empty)", 40);

	/* 40-character limit */
	atapi_insert(&U, iso(100), "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz.iso");
	atapi_identify(id, &U);
	expect_ata_string(__LINE__, id, 27, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmn", 40);
	EXPECT(id[47] == 0, "word 47 = %04X (model overran)", id[47]);
	end();
}

static void t_toc_format0(void)
{
	/* 245,535 = 0x0003BF1F; lead-out MSF = (245,535 + 150) frames = 54:35:60 */
	static const uint8_t lba[20] = {
		0x00, 0x12, 0x01, 0x01,
		0x00, 0x14, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x00, 0x14, 0xAA, 0x00, 0x00, 0x03, 0xBF, 0x1F
	};
	static const uint8_t msf[20] = {
		0x00, 0x12, 0x01, 0x01,
		0x00, 0x14, 0x01, 0x00, 0x00, 0x00, 0x02, 0x00,
		0x00, 0x14, 0xAA, 0x00, 0x00, 54, 35, 60
	};
	static const uint8_t leadout_only[12] = {
		0x00, 0x0A, 0x01, 0x01,
		0x00, 0x14, 0xAA, 0x00, 0x00, 0x03, 0xBF, 0x1F
	};
	uint8_t c[12];
	begin("READ TOC format 0, LBA and MSF, 245,535 sectors");
	ready_unit(OS39_SECTORS, OS39_NAME);
	toc(c, 0, 0, 0, 0xFFFF);
	expect_response(__LINE__, c, 20);
	expect_bytes(__LINE__, lba, 0, 20);
	toc(c, 0, 0, 1, 0xFFFF);
	expect_response(__LINE__, c, 20);
	expect_bytes(__LINE__, lba, 0, 20);
	toc(c, 1, 0, 0, 0xFFFF);
	expect_response(__LINE__, c, 20);
	expect_bytes(__LINE__, msf, 0, 20);
	toc(c, 0, 0, 0xAA, 0xFFFF);
	expect_response(__LINE__, c, 12);
	expect_bytes(__LINE__, leadout_only, 0, 12);
	toc(c, 0, 0, 2, 0xFFFF);
	expect_check(__LINE__, c, 0x05, 0x24, 0x00);
	end();
}

static void t_toc_format1(void)
{
	static const uint8_t lba[12] = {
		0x00, 0x0A, 0x01, 0x01, 0x00, 0x14, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00
	};
	static const uint8_t msf[12] = {
		0x00, 0x0A, 0x01, 0x01, 0x00, 0x14, 0x01, 0x00, 0x00, 0x00, 0x02, 0x00
	};
	uint8_t c[12];
	begin("READ TOC format 1 (session info), unsupported formats");
	ready_unit(OS39_SECTORS, OS39_NAME);
	toc(c, 0, 1, 0, 0xFFFF);
	expect_response(__LINE__, c, 12);
	expect_bytes(__LINE__, lba, 0, 12);
	toc(c, 1, 1, 0, 0xFFFF);
	expect_response(__LINE__, c, 12);
	expect_bytes(__LINE__, msf, 0, 12);
	/* SFF-8020 drivers put the format in byte 9 bits 7:6 */
	toc(c, 0, 0, 0, 0xFFFF);
	c[9] = 0x40;
	expect_response(__LINE__, c, 12);
	expect_bytes(__LINE__, lba, 0, 12);
	toc(c, 0, 2, 0, 0xFFFF);
	expect_check(__LINE__, c, 0x05, 0x24, 0x00);
	end();
}

static void t_read_capacity(void)
{
	static const uint8_t want[8] = { 0x00, 0x03, 0xBF, 0x1E, 0x00, 0x00, 0x08, 0x00 };
	uint8_t c[12];
	begin("READ CAPACITY: last LBA 245,534, 2048-byte blocks");
	ready_unit(OS39_SECTORS, OS39_NAME);
	cdb0(c, 0x25);
	expect_response(__LINE__, c, 8);
	expect_bytes(__LINE__, want, 0, 8);
	end();
}

static void t_mode_sense(void)
{
	uint8_t c[12];
	begin("MODE SENSE(6/10): page lengths, 3F, unknown page");
	ready_unit(OS39_SECTORS, OS39_NAME);

	mode_sense10(c, 0x01, 0xFFFF);
	expect_response(__LINE__, c, 16);
	EXPECT(be16(atapi_buf) == 14, "mode data length %u", be16(atapi_buf));
	EXPECT(be16(atapi_buf + 6) == 0, "block descriptor length %u", be16(atapi_buf + 6));
	EXPECT(atapi_buf[8] == 0x01 && atapi_buf[9] == 0x06, "page 01 header %02X %02X", atapi_buf[8], atapi_buf[9]);

	mode_sense10(c, 0x0E, 0xFFFF);
	expect_response(__LINE__, c, 24);
	EXPECT(be16(atapi_buf) == 22, "mode data length %u", be16(atapi_buf));
	EXPECT(atapi_buf[8] == 0x0E && atapi_buf[9] == 0x0E, "page 0E header %02X %02X", atapi_buf[8], atapi_buf[9]);
	EXPECT(atapi_buf[8 + 9] == 0xFF && atapi_buf[8 + 11] == 0xFF, "volumes %02X %02X",
	       atapi_buf[8 + 9], atapi_buf[8 + 11]);

	mode_sense10(c, 0x2A, 0xFFFF);
	expect_response(__LINE__, c, 28);
	EXPECT(be16(atapi_buf) == 26, "mode data length %u", be16(atapi_buf));
	EXPECT(atapi_buf[8] == 0x2A && atapi_buf[9] == 0x12, "page 2A header %02X %02X", atapi_buf[8], atapi_buf[9]);
	EXPECT((atapi_buf[8 + 4] & 0x01) == 0, "audio play claimed before phase 3");
	EXPECT((atapi_buf[8 + 6] & 0x02) == 0, "lock state set while unlocked");

	mode_sense10(c, 0x3F, 0xFFFF);
	expect_response(__LINE__, c, 52);
	EXPECT(be16(atapi_buf) == 50, "mode data length %u", be16(atapi_buf));
	EXPECT(atapi_buf[8] == 0x01 && atapi_buf[16] == 0x0E && atapi_buf[32] == 0x2A,
	       "page order %02X %02X %02X", atapi_buf[8], atapi_buf[16], atapi_buf[32]);

	/* page control bits (7:6) do not change the page code */
	mode_sense10(c, 0x80 | 0x2A, 0xFFFF);
	expect_response(__LINE__, c, 28);

	mode_sense6(c, 0x2A, 0xFF);
	expect_response(__LINE__, c, 24);
	EXPECT(atapi_buf[0] == 23 && atapi_buf[3] == 0, "6-byte header %02X .. %02X", atapi_buf[0], atapi_buf[3]);
	EXPECT(atapi_buf[4] == 0x2A && atapi_buf[5] == 0x12, "page 2A at 4: %02X %02X", atapi_buf[4], atapi_buf[5]);

	mode_sense6(c, 0x3F, 0xFF);
	expect_response(__LINE__, c, 48);
	EXPECT(atapi_buf[0] == 47, "mode data length %u", atapi_buf[0]);

	mode_sense6(c, 0x3F, 10);
	expect_response(__LINE__, c, 10);

	mode_sense10(c, 0x05, 0xFFFF);
	expect_check(__LINE__, c, 0x05, 0x24, 0x00);

	/* the lock state shows in page 2A */
	prevent(c, 1);
	expect_good(__LINE__, c);
	mode_sense10(c, 0x2A, 0xFFFF);
	expect_response(__LINE__, c, 28);
	EXPECT((atapi_buf[8 + 6] & 0x02) != 0, "lock state clear while locked");
	end();
}

static void t_no_disc(void)
{
	uint8_t c[12];
	begin("no disc: 02/3A/00 except INQUIRY, REQUEST SENSE, GET CONFIGURATION, GESN");
	atapi_init(&U);
	tur(c);
	expect_check(__LINE__, c, 0x02, 0x3A, 0x00);
	read10(c, 16, 1);
	expect_check(__LINE__, c, 0x02, 0x3A, 0x00);
	cdb0(c, 0x25);
	expect_check(__LINE__, c, 0x02, 0x3A, 0x00);
	toc(c, 0, 0, 0, 0xFFFF);
	expect_check(__LINE__, c, 0x02, 0x3A, 0x00);
	mode_sense10(c, 0x3F, 0xFFFF);
	expect_check(__LINE__, c, 0x02, 0x3A, 0x00);
	start_stop(c, 1, 0);
	expect_check(__LINE__, c, 0x02, 0x3A, 0x00);

	inquiry(c, 36);
	expect_response(__LINE__, c, 36);
	cdb0(c, 0x46);
	c[8] = 0xFF;
	expect_response(__LINE__, c, 16);
	EXPECT(be16(atapi_buf + 6) == 0x0008, "current profile %04X", be16(atapi_buf + 6));
	gesn(c, 1, 0x10, 8);
	expect_response(__LINE__, c, 8);
	EXPECT(atapi_buf[5] == 0x00, "media status %02X with no disc", atapi_buf[5]);
	/* REQUEST SENSE itself is exempt and reports the last error */
	tur(c);
	run(c);
	expect_sense(__LINE__, 0x02, 0x3A, 0x00);
	end();
}

static void t_ua_insert(void)
{
	uint8_t c[12];
	begin("insert: one-shot UNIT ATTENTION 06/28/00, exempt commands keep it pending");
	atapi_init(&U);
	atapi_insert(&U, iso(OS39_SECTORS), OS39_NAME);
	inquiry(c, 36);
	expect_response(__LINE__, c, 36);
	gesn(c, 1, 0x10, 8);
	expect_response(__LINE__, c, 8);
	tur(c);
	expect_check(__LINE__, c, 0x06, 0x28, 0x00);
	expect_good(__LINE__, c);
	expect_good(__LINE__, c);
	expect_sense(__LINE__, 0x00, 0x00, 0x00);

	/* REQUEST SENSE as the first command reports the pending UA and clears it */
	atapi_init(&U);
	atapi_insert(&U, iso(OS39_SECTORS), OS39_NAME);
	expect_sense(__LINE__, 0x06, 0x28, 0x00);
	tur(c);
	expect_good(__LINE__, c);

	/* any non-exempt command takes the UA, not only TEST UNIT READY */
	atapi_init(&U);
	atapi_insert(&U, iso(OS39_SECTORS), OS39_NAME);
	read10(c, 16, 1);
	expect_check(__LINE__, c, 0x06, 0x28, 0x00);
	EXPECT(run(c) == ATAPI_READ, "READ after the UA: kind %d", R.kind);
	end();
}

static void t_ua_reset(void)
{
	uint8_t c[12];
	begin("reset: one-shot UNIT ATTENTION 06/29/00, then the no-disc rule");
	ready_unit(OS39_SECTORS, OS39_NAME);
	atapi_reset(&U);
	tur(c);
	expect_check(__LINE__, c, 0x06, 0x29, 0x00);
	expect_good(__LINE__, c);
	EXPECT(U.media, "reset removed the disc");

	atapi_init(&U);
	atapi_reset(&U);
	tur(c);
	expect_check(__LINE__, c, 0x06, 0x29, 0x00);
	expect_check(__LINE__, c, 0x02, 0x3A, 0x00);
	end();
}

static void t_gesn(void)
{
	uint8_t c[12];
	static const uint8_t new_media[8] = { 0x00, 0x06, 0x04, 0x10, 0x02, 0x02, 0x00, 0x00 };
	static const uint8_t no_change[8] = { 0x00, 0x06, 0x04, 0x10, 0x00, 0x02, 0x00, 0x00 };
	static const uint8_t removed[8]   = { 0x00, 0x06, 0x04, 0x10, 0x03, 0x00, 0x00, 0x00 };
	static const uint8_t empty[8]     = { 0x00, 0x06, 0x04, 0x10, 0x00, 0x00, 0x00, 0x00 };
	static const uint8_t no_class[4]  = { 0x00, 0x02, 0x80, 0x10 };
	begin("GET EVENT STATUS NOTIFICATION: new media / removed, one-shot");
	atapi_init(&U);
	atapi_insert(&U, iso(OS39_SECTORS), OS39_NAME);
	gesn(c, 1, 0x10, 8);
	expect_response(__LINE__, c, 8);
	expect_bytes(__LINE__, new_media, 0, 8);
	expect_response(__LINE__, c, 8);
	expect_bytes(__LINE__, no_change, 0, 8);
	EXPECT(atapi_eject(&U) == ATAPI_OK, "eject refused");
	expect_response(__LINE__, c, 8);
	expect_bytes(__LINE__, removed, 0, 8);
	expect_response(__LINE__, c, 8);
	expect_bytes(__LINE__, empty, 0, 8);
	gesn(c, 1, 0x02, 8);
	expect_response(__LINE__, c, 4);
	expect_bytes(__LINE__, no_class, 0, 4);
	gesn(c, 0, 0x10, 8);
	expect_check(__LINE__, c, 0x05, 0x24, 0x00);
	end();
}

static void t_lock_eject(void)
{
	uint8_t c[12];
	begin("PREVENT: START STOP eject 05/53/02 and OSD eject refused; ALLOW: both work");
	ready_unit(OS39_SECTORS, OS39_NAME);
	prevent(c, 1);
	expect_good(__LINE__, c);
	EXPECT(atapi_locked(&U), "not locked after PREVENT");
	start_stop(c, 1, 0);
	expect_check(__LINE__, c, 0x05, 0x53, 0x02);
	EXPECT(U.media, "disc gone after a refused eject");
	EXPECT(atapi_eject(&U) == ATAPI_LOCKED, "OSD eject not refused while locked");
	EXPECT(U.media, "disc gone after a refused OSD eject");
	EXPECT(atapi_insert(&U, iso_other(275806), "ClassicInstallCD-53.71.iso") == ATAPI_LOCKED,
	       "swap not refused while locked");
	inquiry(c, 36);
	expect_response(__LINE__, c, 36);
	expect_bytes(__LINE__, (const uint8_t *)"AmigaOS3.9.iso  ", 16, 16);
	tur(c);
	expect_good(__LINE__, c);

	prevent(c, 0);
	expect_good(__LINE__, c);
	EXPECT(!atapi_locked(&U), "locked after ALLOW");
	start_stop(c, 1, 0);
	expect_good(__LINE__, c);
	EXPECT(R.ejected == 1, "START STOP eject did not tell the glue to close the file");
	EXPECT(!U.media, "disc still in after START STOP eject");
	tur(c);
	expect_check(__LINE__, c, 0x02, 0x3A, 0x00);

	/* OSD eject after ALLOW */
	ready_unit(OS39_SECTORS, OS39_NAME);
	prevent(c, 1);
	expect_good(__LINE__, c);
	prevent(c, 0);
	expect_good(__LINE__, c);
	EXPECT(atapi_eject(&U) == ATAPI_OK, "OSD eject refused after ALLOW");
	EXPECT(!U.media, "disc still in after the OSD eject");

	/* start / stop without LoEj, and load: GOOD, disc stays */
	ready_unit(OS39_SECTORS, OS39_NAME);
	start_stop(c, 0, 1);
	expect_good(__LINE__, c);
	EXPECT(R.ejected == 0, "ejected flag on START");
	start_stop(c, 0, 0);
	expect_good(__LINE__, c);
	start_stop(c, 1, 1);
	expect_good(__LINE__, c);
	EXPECT(U.media, "disc gone after start/stop/load");

	/* swap while unlocked: new disc in, UNIT ATTENTION again */
	EXPECT(atapi_insert(&U, iso_other(275806), "ClassicInstallCD-53.71.iso") == ATAPI_OK, "swap refused");
	tur(c);
	expect_check(__LINE__, c, 0x06, 0x28, 0x00);
	cdb0(c, 0x25);
	expect_response(__LINE__, c, 8);
	EXPECT(be32(atapi_buf) == 275805, "last LBA %u after swap", be32(atapi_buf));
	end();
}

static void t_reset_unlocks(void)
{
	uint8_t c[12];
	begin("reset clears the lock");
	ready_unit(OS39_SECTORS, OS39_NAME);
	prevent(c, 1);
	expect_good(__LINE__, c);
	atapi_reset(&U);
	EXPECT(!atapi_locked(&U), "still locked after reset");
	EXPECT(atapi_eject(&U) == ATAPI_OK, "OSD eject refused after reset");
	end();
}

static void t_invalid(void)
{
	static const uint8_t ops[] = { 0xFF, 0x15, 0xBE, 0xB9, 0xD8, 0xD9, 0x04 };
	uint8_t c[12];
	unsigned i;
	begin("invalid opcodes and READ CD: 05/20/00");
	ready_unit(OS39_SECTORS, OS39_NAME);
	for (i = 0; i < sizeof(ops); i++) {
		cdb0(c, ops[i]);
		expect_check(__LINE__, c, 0x05, 0x20, 0x00);
	}
	end();
}

static void t_read(void)
{
	uint8_t c[12];
	begin("READ(10)/READ(12): count 0, range, beyond the end 05/21/00");
	ready_unit(OS39_SECTORS, OS39_NAME);
	read10(c, 16, 0);
	expect_good(__LINE__, c);
	read12(c, 16, 0);
	expect_good(__LINE__, c);
	read10(c, 16, 1);
	EXPECT(run(c) == ATAPI_READ && R.lba == 16 && R.count == 1, "kind %d lba %u count %u",
	       R.kind, R.lba, R.count);
	read10(c, 0x12345, 0x1234);
	EXPECT(run(c) == ATAPI_READ && R.lba == 0x12345 && R.count == 0x1234, "kind %d lba %X count %X",
	       R.kind, R.lba, R.count);
	read12(c, 1000, 70000);
	EXPECT(run(c) == ATAPI_READ && R.lba == 1000 && R.count == 70000, "kind %d lba %u count %u",
	       R.kind, R.lba, R.count);
	read10(c, OS39_SECTORS - 1, 1);
	EXPECT(run(c) == ATAPI_READ && R.lba == OS39_SECTORS - 1, "last sector: kind %d", R.kind);
	read10(c, OS39_SECTORS, 1);
	expect_check(__LINE__, c, 0x05, 0x21, 0x00);
	read10(c, OS39_SECTORS - 1, 2);
	expect_check(__LINE__, c, 0x05, 0x21, 0x00);
	read10(c, 0xFFFFFFFFu, 1);
	expect_check(__LINE__, c, 0x05, 0x21, 0x00);
	read12(c, 10, 0xFFFFFFF8u);
	expect_check(__LINE__, c, 0x05, 0x21, 0x00);
	end();
}

static void t_misc(void)
{
	uint8_t c[12];
	static const uint8_t nodata[] = { 0x2B, 0x35, 0x45, 0x47, 0x4B, 0x4E, 0xBC };
	unsigned i;
	begin("SEEK, SYNC CACHE, audio no-ops, MODE SELECT, sub-channel, disc/track info");
	ready_unit(OS39_SECTORS, OS39_NAME);
	for (i = 0; i < sizeof(nodata); i++) {
		cdb0(c, nodata[i]);
		expect_good(__LINE__, c);
	}
	cdb0(c, 0x55);
	c[8] = 24;
	EXPECT(run(c) == ATAPI_RECEIVE && R.length == 24, "MODE SELECT: kind %d length %u", R.kind, R.length);
	cdb0(c, 0x55);
	expect_good(__LINE__, c);

	cdb0(c, 0x42);
	c[8] = 0xFF;
	expect_response(__LINE__, c, 4);
	EXPECT(atapi_buf[1] == 0x15, "audio status %02X", atapi_buf[1]);
	c[2] = 0x40;
	c[3] = 0x01;
	expect_response(__LINE__, c, 16);
	EXPECT(atapi_buf[1] == 0x15 && be16(atapi_buf + 2) == 12 && atapi_buf[4] == 0x01,
	       "sub-channel %02X %u %02X", atapi_buf[1], be16(atapi_buf + 2), atapi_buf[4]);

	cdb0(c, 0x51);
	c[8] = 0xFF;
	expect_response(__LINE__, c, 34);
	EXPECT(be16(atapi_buf) == 32 && atapi_buf[3] == 1 && atapi_buf[6] == 1, "disc info %u %u %u",
	       be16(atapi_buf), atapi_buf[3], atapi_buf[6]);

	cdb0(c, 0x52);
	c[1] = 0x01;
	c[5] = 0x01;
	c[8] = 0xFF;
	expect_response(__LINE__, c, 28);
	EXPECT(be16(atapi_buf) == 26 && atapi_buf[2] == 1 && be32(atapi_buf + 8) == 0 &&
	       be32(atapi_buf + 24) == OS39_SECTORS, "track info len %u track %u start %u size %u",
	       be16(atapi_buf), atapi_buf[2], be32(atapi_buf + 8), be32(atapi_buf + 24));
	c[5] = 0x02;
	expect_check(__LINE__, c, 0x05, 0x24, 0x00);
	end();
}

static void t_toc_tracks(void)
{
	/* LBA: 2358 = 0x936, 20283 = 0x4F3B, 41658 = 0xA2BA */
	static const uint8_t lba[36] = {
		0x00, 0x22, 0x01, 0x03,
		0x00, 0x14, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x00, 0x10, 0x02, 0x00, 0x00, 0x00, 0x09, 0x36,
		0x00, 0x10, 0x03, 0x00, 0x00, 0x00, 0x4F, 0x3B,
		0x00, 0x10, 0xAA, 0x00, 0x00, 0x00, 0xA2, 0xBA
	};
	/* MSF = LBA + 150 frames: 00:33:33, 04:32:33, 09:17:33 */
	static const uint8_t msf[36] = {
		0x00, 0x22, 0x01, 0x03,
		0x00, 0x14, 0x01, 0x00, 0x00, 0, 2, 0,
		0x00, 0x10, 0x02, 0x00, 0x00, 0, 33, 33,
		0x00, 0x10, 0x03, 0x00, 0x00, 4, 32, 33,
		0x00, 0x10, 0xAA, 0x00, 0x00, 9, 17, 33
	};
	static const uint8_t from3[20] = {
		0x00, 0x12, 0x01, 0x03,
		0x00, 0x10, 0x03, 0x00, 0x00, 0x00, 0x4F, 0x3B,
		0x00, 0x10, 0xAA, 0x00, 0x00, 0x00, 0xA2, 0xBA
	};
	static const uint8_t session[12] = {
		0x00, 0x0A, 0x01, 0x01, 0x00, 0x14, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00
	};
	uint8_t c[12];
	begin("READ TOC of the reference disc: 3 tracks, audio control 0x10, starting track, lead-out");
	ready_disc(pinball(), "Pinball Fantasies");
	toc(c, 0, 0, 0, 0xFFFF);
	expect_response(__LINE__, c, 36);
	expect_bytes(__LINE__, lba, 0, 36);
	toc(c, 1, 0, 1, 0xFFFF);
	expect_response(__LINE__, c, 36);
	expect_bytes(__LINE__, msf, 0, 36);
	toc(c, 0, 0, 3, 0xFFFF);
	expect_response(__LINE__, c, 20);
	expect_bytes(__LINE__, from3, 0, 20);
	toc(c, 0, 0, 0xAA, 0xFFFF);
	expect_response(__LINE__, c, 12);
	expect_bytes(__LINE__, from3 + 12, 4, 8);
	toc(c, 0, 0, 4, 0xFFFF);
	expect_check(__LINE__, c, 0x05, 0x24, 0x00);
	toc(c, 0, 1, 0, 0xFFFF);
	expect_response(__LINE__, c, 12);
	expect_bytes(__LINE__, session, 0, 12);
	toc(c, 0, 0, 0, 12);	/* allocation length cuts, the length field stays (12.2) */
	expect_response(__LINE__, c, 12);
	EXPECT(be16(atapi_buf) == 34, "TOC length %u", be16(atapi_buf));
	end();
}

static void t_tracks_info(void)
{
	static const uint8_t cap[8] = { 0x00, 0x00, 0xA2, 0xB9, 0x00, 0x00, 0x08, 0x00 };
	uint8_t c[12];
	begin("reference disc: READ CAPACITY to the lead-out, DISC / TRACK INFORMATION per track");
	ready_disc(pinball(), "Pinball Fantasies");
	cdb0(c, 0x25);
	expect_response(__LINE__, c, 8);
	expect_bytes(__LINE__, cap, 0, 8);
	cdb0(c, 0x51);
	c[8] = 0xFF;
	expect_response(__LINE__, c, 34);
	EXPECT(atapi_buf[3] == 1 && atapi_buf[5] == 1 && atapi_buf[6] == 3, "disc info first %u last %u",
	       atapi_buf[5], atapi_buf[6]);
	cdb0(c, 0x52);
	c[1] = 0x01;
	c[5] = 0x02;
	c[8] = 0xFF;
	expect_response(__LINE__, c, 28);
	EXPECT(atapi_buf[2] == 2 && atapi_buf[5] == 0x00 && be32(atapi_buf + 8) == 2358 && be32(atapi_buf + 24) == 17925,
	       "track 2: number %u mode %02X start %u size %u", atapi_buf[2], atapi_buf[5], be32(atapi_buf + 8),
	       be32(atapi_buf + 24));
	cdb0(c, 0x52);
	put_be32(c + 2, 30000);	/* type 0: the track holding LBA 30000 */
	c[8] = 0xFF;
	expect_response(__LINE__, c, 28);
	EXPECT(atapi_buf[2] == 3 && be32(atapi_buf + 8) == 20283 && be32(atapi_buf + 24) == 21375,
	       "LBA 30000: track %u start %u size %u", atapi_buf[2], be32(atapi_buf + 8), be32(atapi_buf + 24));
	cdb0(c, 0x52);
	c[1] = 0x01;
	c[5] = 0x04;
	c[8] = 0xFF;
	expect_check(__LINE__, c, 0x05, 0x24, 0x00);
	end();
}

static void t_read_audio(void)
{
	uint8_t c[12];
	begin("READ(10)/(12) of audio sectors (or their gap): 05/64/00; data up to the boundary reads");
	ready_disc(pinball(), "Pinball Fantasies");
	read10(c, 2200, 8);	/* the last 8 data sectors */
	EXPECT(run(c) == ATAPI_READ && R.lba == 2200 && R.count == 8, "kind %d lba %u count %u", R.kind, R.lba, R.count);
	read10(c, 2200, 9);	/* one into track 2's PREGAP */
	expect_check(__LINE__, c, 0x05, 0x64, 0x00);
	read10(c, 2208, 1);
	expect_check(__LINE__, c, 0x05, 0x64, 0x00);
	read10(c, 2358, 1);
	expect_check(__LINE__, c, 0x05, 0x64, 0x00);
	read12(c, 30000, 2);
	expect_check(__LINE__, c, 0x05, 0x64, 0x00);
	read10(c, 41657, 2);	/* past the lead-out: the range check comes first */
	expect_check(__LINE__, c, 0x05, 0x21, 0x00);
	end();
}

static void t_iso_read(const char *path)
{
	uint8_t c[12];
	uint32_t pvd_blocks;
	struct stat st;
	const char *name = "ISO-backed READ: PVD \"CD001\" at sector 16, last sector";

	if (iso_fd < 0) {
		skip(name, "ISO not found");
		return;
	}
	begin(name);
	if (fstat(iso_fd, &st) != 0 || st.st_size % ATAPI_SECTOR_SIZE != 0) {
		EXPECT(0, "%s is not a whole number of 2048-byte sectors", path);
		end();
		return;
	}
	iso_sectors = (uint32_t)(st.st_size / ATAPI_SECTOR_SIZE);
	ready_unit(iso_sectors, OS39_NAME);

	cdb0(c, 0x25);
	expect_response(__LINE__, c, 8);
	EXPECT(be32(atapi_buf) + 1 == iso_sectors, "READ CAPACITY %u + 1 != %u sectors", be32(atapi_buf), iso_sectors);

	read10(c, 16, 1);
	if (run(c) == ATAPI_READ) {
		EXPECT(iso_read(R.lba, R.count, sector) == 0, "callback read failed");
		EXPECT(sector[0] == 0x01 && memcmp(sector + 1, "CD001", 5) == 0,
		       "sector 16 is not a primary volume descriptor");
		pvd_blocks = sector[80] | (sector[81] << 8) | (sector[82] << 16) | ((uint32_t)sector[83] << 24);
		EXPECT(pvd_blocks == be32(sector + 84), "PVD volume space size LE/BE disagree");
		EXPECT(pvd_blocks <= iso_sectors, "PVD says %u blocks, file has %u", pvd_blocks, iso_sectors);
	} else {
		EXPECT(0, "READ(10) 16,1: kind %d", R.kind);
	}

	read12(c, 16, 2);
	if (run(c) == ATAPI_READ && R.count == 2) {
		EXPECT(iso_read(R.lba, R.count, sector) == 0, "callback read failed");
		EXPECT(memcmp(sector + ATAPI_SECTOR_SIZE + 1, "CD001", 5) == 0,
		       "sector 17 is not a volume descriptor");
	} else {
		EXPECT(0, "READ(12) 16,2: kind %d count %u", R.kind, R.count);
	}

	read10(c, iso_sectors - 1, 1);
	if (run(c) == ATAPI_READ)
		EXPECT(iso_read(R.lba, R.count, sector) == 0, "last sector unreadable through the callback");
	else
		EXPECT(0, "READ(10) last sector: kind %d", R.kind);

	read10(c, iso_sectors, 1);
	expect_check(__LINE__, c, 0x05, 0x21, 0x00);
	end();
}

int main(int argc, char **argv)
{
	char path[1024];
	const char *home = getenv("HOME");

	if (argc > 1)
		snprintf(path, sizeof(path), "%s", argv[1]);
	else
		snprintf(path, sizeof(path), "%s/work/amiga/AmigaOS3.9.iso", home ? home : ".");
	iso_fd = open(path, O_RDONLY);
	if (iso_fd < 0)
		printf("note: %s not readable, ISO-backed cases are skipped\n", path);

	t_inquiry_name();
	t_inquiry_empty();
	t_alloc_truncation();
	t_identify_packet();
	t_toc_format0();
	t_toc_format1();
	t_read_capacity();
	t_mode_sense();
	t_no_disc();
	t_ua_insert();
	t_ua_reset();
	t_gesn();
	t_lock_eject();
	t_reset_unlocks();
	t_invalid();
	t_read();
	t_misc();
	t_toc_tracks();
	t_tracks_info();
	t_read_audio();
	t_iso_read(path);

	if (iso_fd >= 0)
		close(iso_fd);
	printf("\n%d cases: %d passed, %d failed, %d skipped (%d failed checks)\n",
	       cases_run + cases_skipped, cases_passed, cases_run - cases_passed, cases_skipped, total_fails);
	return (cases_run == cases_passed) ? 0 : 1;
}

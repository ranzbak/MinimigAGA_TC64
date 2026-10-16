/*
 * atapi_emu: the ATAPI command layer compiled by vbcc832 and run in 832e,
 * the EightThirtyTwo emulator (make -C fw/ctrl_832/test emu).
 *
 * The host tests (atapi_test, cdrom_test) build atapi.c with gcc, so they
 * cannot see what the 832 compiler does with it.  On the board (2026-10-15,
 * stage_cdscaler2, IDEfix97) every packet command ended as GOOD without data:
 * vbcc832 compiled each "r->kind = X; return X;" with the uint8_t kind as a
 * 32-bit store, which on the big-endian 832 writes 0 into kind.  These cases
 * check the result kind, the lengths and the response bytes of one command of
 * each kind.  The last line is "PASS" or "FAIL n".
 */
#include <stdio.h>
#include <string.h>
#include "atapi.h"

static int fails;

static void expect(const char *what, unsigned int got, unsigned int want)
{
	if (got != want) {
		printf("FAIL %s: got %u, want %u\n", what, got, want);
		fails++;
	} else
		printf("ok   %s = %u\n", what, got);
}

static struct atapi_unit unit;
static struct atapi_result res;
static uint8_t cdb[12];
static struct cd_disc iso, pinball;

/* The reference disc (13.9) as cue.c lays it out (cue_emu checks that). */
static void make_pinball(void)
{
	struct cd_track *t = pinball.track;
	pinball.tracks = 3;
	pinball.files = 3;
	pinball.leadout = 41658;
	t[0].number = 1; t[0].type = CD_DATA2048; t[0].file = 0; t[0].file_offset = 0;
	t[0].lba = 0; t[0].sectors = 2208; t[0].pregap_lba = 0; t[0].pregap_silent = 0;
	t[1].number = 2; t[1].type = CD_AUDIO; t[1].file = 1; t[1].file_offset = 44;
	t[1].lba = 2358; t[1].sectors = 17775; t[1].pregap_lba = 2208; t[1].pregap_silent = 1;
	t[2].number = 3; t[2].type = CD_AUDIO; t[2].file = 2; t[2].file_offset = 44 + 150 * 2352;
	t[2].lba = 20283; t[2].sectors = 21375; t[2].pregap_lba = 20133; t[2].pregap_silent = 0;
	pinball.file[1].wave = 1;
	pinball.file[1].data_offset = 44;
	pinball.file[1].data_bytes = 41806800;
	pinball.file[2].wave = 1;
	pinball.file[2].data_offset = 44;
	pinball.file[2].data_bytes = 50626800;
}

static unsigned int be32(const uint8_t *p)
{
	return ((unsigned int)p[0] << 24) | ((unsigned int)p[1] << 16) | ((unsigned int)p[2] << 8) | p[3];
}

static int packet(uint8_t op, uint8_t b2, uint8_t b4, uint8_t b8)
{
	int k;
	memset(cdb, 0, sizeof(cdb));
	cdb[0] = op;
	cdb[2] = b2;
	cdb[4] = b4;
	cdb[8] = b8;
	k = atapi_packet(&unit, cdb, 0xFFFE, &res);
	printf("     CDB %x: kind %u sense %x/%x/%x length %u\n", op,
	       (unsigned)res.kind, res.sense_key, res.asc, res.ascq, res.length);
	return k;
}

int main(int argc, char **argv)
{
	int k;

	atapi_init(&unit);

	/* INQUIRY, allocation length 36: what IDEfix97's FindDevice sends */
	k = packet(0x12, 0, 36, 0);
	expect("INQUIRY return", k, ATAPI_RESPONSE);
	expect("INQUIRY kind", res.kind, ATAPI_RESPONSE);
	expect("INQUIRY length", res.length, 36);
	expect("INQUIRY byte 0 (CD-ROM)", atapi_buf[0], 0x05);
	expect("INQUIRY byte 1 (removable)", atapi_buf[1], 0x80);
	expect("INQUIRY ejected", res.ejected, 0);

	/* no disc: TEST UNIT READY is CHECK 02/3A/00 */
	k = packet(0x00, 0, 0, 0);
	expect("TUR no disc return", k, ATAPI_CHECK);
	expect("TUR no disc kind", res.kind, ATAPI_CHECK);
	expect("TUR no disc sense key", res.sense_key, 0x02);
	expect("TUR no disc asc", res.asc, 0x3A);
	expect("TUR no disc ascq", res.ascq, 0x00);

	/* a disc of 2208 sectors (the Pinball Fantasies data track) */
	cue_single(&iso, "PINBALL ISO", 2208 * 2048);
	expect("insert", atapi_insert(&unit, &iso, "Pinball Fantasies"), ATAPI_OK);
	expect("insert sectors", unit.sectors, 2208);
	k = packet(0x00, 0, 0, 0);	/* the insert's UNIT ATTENTION */
	expect("TUR after insert kind", res.kind, ATAPI_CHECK);
	expect("TUR after insert sense key", res.sense_key, 0x06);
	k = packet(0x00, 0, 0, 0);
	expect("TUR ready return", k, ATAPI_DONE);
	expect("TUR ready kind", res.kind, ATAPI_DONE);

	/* READ CAPACITY: last LBA 2207, 2048-byte blocks */
	k = packet(0x25, 0, 0, 0);
	expect("READ CAPACITY kind", res.kind, ATAPI_RESPONSE);
	expect("READ CAPACITY length", res.length, 8);
	expect("READ CAPACITY last LBA", (atapi_buf[2] << 8) | atapi_buf[3], 2207);
	expect("READ CAPACITY block", (atapi_buf[6] << 8) | atapi_buf[7], 2048);

	/* READ(10) LBA 16, 2 sectors */
	memset(cdb, 0, sizeof(cdb));
	cdb[0] = 0x28;
	cdb[5] = 16;
	cdb[8] = 2;
	k = atapi_packet(&unit, cdb, 0xFFFE, &res);
	expect("READ(10) return", k, ATAPI_READ);
	expect("READ(10) kind", res.kind, ATAPI_READ);
	expect("READ(10) lba", res.lba, 16);
	expect("READ(10) count", res.count, 2);

	/* REQUEST SENSE: 18 bytes */
	k = packet(0x03, 0, 18, 0);
	expect("REQUEST SENSE kind", res.kind, ATAPI_RESPONSE);
	expect("REQUEST SENSE length", res.length, 18);

	/* START STOP UNIT LoEj: the disc goes out */
	k = packet(0x1B, 0, 0x02, 0);
	expect("eject kind", res.kind, ATAPI_DONE);
	expect("eject ejected", res.ejected, 1);

	/* the reference disc: TOC of 3 tracks, audio sectors are not READ data */
	make_pinball();
	expect("insert pinball", atapi_insert(&unit, &pinball, "Pinball Fantasies"), ATAPI_OK);
	expect("pinball sectors", unit.sectors, 41658);
	packet(0x00, 0, 0, 0);	/* UNIT ATTENTION */
	memset(cdb, 0, sizeof(cdb));
	cdb[0] = 0x43;
	cdb[7] = 0xFF;
	cdb[8] = 0xFF;
	k = atapi_packet(&unit, cdb, 0xFFFE, &res);
	expect("TOC kind", res.kind, ATAPI_RESPONSE);
	expect("TOC length", res.length, 36);
	expect("TOC data length", (atapi_buf[0] << 8) | atapi_buf[1], 34);
	expect("TOC last track", atapi_buf[3], 3);
	expect("TOC track 1 control", atapi_buf[5], 0x14);
	expect("TOC track 2 control", atapi_buf[13], 0x10);
	expect("TOC track 2 number", atapi_buf[14], 2);
	expect("TOC track 2 LBA", be32(atapi_buf + 16), 2358);
	expect("TOC track 3 LBA", be32(atapi_buf + 24), 20283);
	expect("TOC lead-out number", atapi_buf[30], 0xAA);
	expect("TOC lead-out LBA", be32(atapi_buf + 32), 41658);
	memset(cdb, 0, sizeof(cdb));
	cdb[0] = 0x28;
	cdb[4] = 0x09;	/* LBA 2358 = 0x936 */
	cdb[5] = 0x36;
	cdb[8] = 1;
	k = atapi_packet(&unit, cdb, 0xFFFE, &res);
	expect("READ audio return", k, ATAPI_CHECK);
	expect("READ audio kind", res.kind, ATAPI_CHECK);
	expect("READ audio sense key", res.sense_key, 0x05);
	expect("READ audio asc", res.asc, 0x64);
	cdb[4] = 0x08;	/* LBA 2200 = 0x898, 8 sectors: the end of the data track */
	cdb[5] = 0x98;
	cdb[8] = 8;
	k = atapi_packet(&unit, cdb, 0xFFFE, &res);
	expect("READ data kind", res.kind, ATAPI_READ);
	expect("READ data lba", res.lba, 2200);
	expect("READ data count", res.count, 8);

	/* PLAY AUDIO(10) 2358 + 100: a play request (int32 kind and audio) */
	memset(cdb, 0, sizeof(cdb));
	cdb[0] = 0x45;
	cdb[4] = 0x09;
	cdb[5] = 0x36;
	cdb[8] = 100;
	k = atapi_packet(&unit, cdb, 0xFFFE, &res);
	expect("PLAY return", k, ATAPI_PLAY);
	expect("PLAY kind", res.kind, ATAPI_PLAY);
	expect("PLAY audio", res.audio, ATAPI_AUDIO_PLAY);
	expect("PLAY lba", res.lba, 2358);
	expect("PLAY count", res.count, 100);
	expect("PLAY seen", unit.audio_seen, 0);
	/* PAUSE */
	memset(cdb, 0, sizeof(cdb));
	cdb[0] = 0x4B;
	k = atapi_packet(&unit, cdb, 0xFFFE, &res);
	expect("PAUSE kind", res.kind, ATAPI_PLAY);
	expect("PAUSE audio", res.audio, ATAPI_AUDIO_PAUSE);
	/* START STOP UNIT stop: DONE with a stop request */
	k = packet(0x1B, 0, 0x00, 0);
	expect("STOP UNIT kind", res.kind, ATAPI_DONE);
	expect("STOP UNIT audio", res.audio, ATAPI_AUDIO_STOP);
	expect("STOP UNIT ejected", res.ejected, 0);
	/* SUB-CHANNEL: completed once, then none */
	atapi_audio_status(&unit, ATAPI_AUDIO_COMPLETED, 2457);
	expect("status after set", unit.audio_status, ATAPI_AUDIO_COMPLETED);
	expect("lba after set", unit.audio_lba, 2457);
	memset(cdb, 0, sizeof(cdb));
	cdb[0] = 0x42;
	cdb[2] = 0x40;
	cdb[3] = 0x01;
	cdb[8] = 16;
	k = atapi_packet(&unit, cdb, 0xFFFE, &res);
	expect("SUB-CHANNEL length", res.length, 16);
	expect("SUB-CHANNEL status", atapi_buf[1], 0x13);
	expect("SUB-CHANNEL track", atapi_buf[6], 2);
	expect("SUB-CHANNEL relative", be32(atapi_buf + 12), 99);
	expect("seen after report", unit.audio_seen, ATAPI_AUDIO_COMPLETED);
	atapi_audio_status(&unit, ATAPI_AUDIO_COMPLETED, 2457);
	expect("status reported once", unit.audio_status, ATAPI_AUDIO_NONE);

	/* READ CD of 2 audio sectors, user data / CD-DA */
	memset(cdb, 0, sizeof(cdb));
	cdb[0] = 0xBE;
	cdb[4] = 0x09;
	cdb[5] = 0x36;
	cdb[8] = 2;
	cdb[9] = 0x10;
	k = atapi_packet(&unit, cdb, 0xFFFE, &res);
	expect("READ CD return", k, ATAPI_READ_CD);
	expect("READ CD kind", res.kind, ATAPI_READ_CD);
	expect("READ CD lba", res.lba, 2358);
	expect("READ CD count", res.count, 2);
	cdb[9] = 0xF8;
	k = atapi_packet(&unit, cdb, 0xFFFE, &res);
	expect("READ CD 0xF8 kind", res.kind, ATAPI_CHECK);
	expect("READ CD 0xF8 asc", res.asc, 0x24);

	/* MODE SELECT(10) page 0E, then MODE SENSE 0E */
	{
		static const uint8_t sel[24] = {
			0, 0, 0, 0, 0, 0, 0, 0,
			0x0E, 0x0E, 0x04, 0, 0, 0, 0, 0, 0x01, 0x80, 0x02, 0x40, 0, 0, 0, 0
		};
		memset(cdb, 0, sizeof(cdb));
		cdb[0] = 0x55;
		cdb[8] = 24;
		k = atapi_packet(&unit, cdb, 0xFFFE, &res);
		expect("MODE SELECT kind", res.kind, ATAPI_RECEIVE);
		expect("MODE SELECT length", res.length, 24);
		atapi_mode_select(&unit, cdb, sel, 24);
		expect("volume left", unit.volume[0], 0x80);
		expect("volume right", unit.volume[1], 0x40);
		expect("audio_seen after the volume", unit.audio_seen, ATAPI_AUDIO_COMPLETED);
		memset(cdb, 0, sizeof(cdb));
		cdb[0] = 0x5A;
		cdb[2] = 0x0E;
		cdb[8] = 0xFF;
		k = atapi_packet(&unit, cdb, 0xFFFE, &res);
		expect("MODE SENSE 0E length", res.length, 24);
		expect("MODE SENSE 0E left", atapi_buf[17], 0x80);
		expect("MODE SENSE 0E right", atapi_buf[19], 0x40);
	}

	if (fails)
		printf("FAIL %d\n", fails);
	else
		printf("PASS\n");
	return fails;
}

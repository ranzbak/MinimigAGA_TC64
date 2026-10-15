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
	expect("insert", atapi_insert(&unit, 2208, "Pinball Fantasies"), ATAPI_OK);
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

	if (fails)
		printf("FAIL %d\n", fails);
	else
		printf("PASS\n");
	return fails;
}

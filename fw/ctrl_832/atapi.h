#ifndef ATAPI_H
#define ATAPI_H

/*
 * ATAPI CD-ROM command layer (findings/cdrom/plan.md, sections 7.1, 7.2, 9).
 *
 * Pure C, no hardware access: builds into the 832 firmware and, with
 * -DHOSTTEST, into the host test fw/ctrl_832/test/atapi_test.c.  The board
 * glue (cdrom.c) owns the file, the Gayle registers and the data phases; this
 * layer decides what each command answers and keeps the drive state (disc,
 * lock, sense, UNIT ATTENTION, media event).
 *
 * Byte order: SCSI responses in atapi_buf are big-endian byte streams, built
 * byte by byte (no struct overlays, no host-endian stores).  They go to the
 * Gayle FIFO in buffer order, the same order as file data (hdd.c sends
 * sector_buffer that way).  IDENTIFY PACKET data are 256 word VALUES with ATA
 * strings packed first character in bits 15:8, the same convention as
 * IdentifyDevice() in hdd.c; the glue sends each word low byte first like
 * ATA_IdentifyDevice().
 */

#include <stdint.h>

#define ATAPI_SECTOR_SIZE 2048
#define ATAPI_BUF_SIZE    2048
#define ATAPI_NAME_LEN    40	/* IDENTIFY model field */

/* atapi_packet() result kinds */
#define ATAPI_DONE     0	/* GOOD, no data phase */
#define ATAPI_RESPONSE 1	/* data in: length bytes of atapi_buf */
#define ATAPI_READ     2	/* data in: count sectors from lba */
#define ATAPI_RECEIVE  3	/* data out: accept length bytes, then GOOD */
#define ATAPI_CHECK    4	/* CHECK CONDITION, sense in the result and the unit */

/* atapi_eject() / atapi_insert() status */
#define ATAPI_OK       0
#define ATAPI_LOCKED   1	/* the Amiga sent PREVENT MEDIUM REMOVAL (D5) */

/* GET EVENT STATUS NOTIFICATION media events */
#define ATAPI_EVENT_NONE      0
#define ATAPI_EVENT_NEW_MEDIA 2
#define ATAPI_EVENT_REMOVED   3

struct atapi_unit
{
	uint8_t  media;		/* a disc is in */
	uint8_t  locked;	/* PREVENT MEDIUM REMOVAL in force */
	uint8_t  ua_asc;	/* pending UNIT ATTENTION: 0x28 medium changed, 0x29 reset; 0 none */
	uint8_t  event;		/* pending media event, ATAPI_EVENT_* */
	uint8_t  sense_key;	/* sense of the last command, for REQUEST SENSE */
	uint8_t  asc;
	uint8_t  ascq;
	uint32_t sectors;	/* disc size in 2048-byte sectors */
	char     name[ATAPI_NAME_LEN + 1];	/* ISO long name, printable ASCII */
};

struct atapi_result
{
	uint8_t  kind;		/* ATAPI_DONE .. ATAPI_CHECK, also the return value */
	uint8_t  ejected;	/* START STOP UNIT ejected the disc: close the file */
	uint8_t  sense_key;	/* ATAPI_CHECK: error register = sense_key << 4 */
	uint8_t  asc;
	uint8_t  ascq;
	uint16_t length;	/* RESPONSE: bytes in atapi_buf (allocation length applied); RECEIVE: bytes */
	uint32_t lba;		/* READ */
	uint32_t count;		/* READ: sectors, never 0 */
};

/* Response buffer shared by all units (one command at a time). */
extern uint8_t atapi_buf[ATAPI_BUF_SIZE];

/* Power on: no disc, no lock, nothing pending. */
void atapi_init(struct atapi_unit *u);

/* Amiga reset (Gayle rst_seen): lock cleared, UNIT ATTENTION 06/29/00 armed; the disc stays in. */
void atapi_reset(struct atapi_unit *u);

/* Put a disc in (OSD insert or swap).  Refused with ATAPI_LOCKED when a disc
   is in and locked; otherwise any disc in is replaced, UNIT ATTENTION
   06/28/00 and a NEW_MEDIA event are armed.  name: the ISO long name. */
int atapi_insert(struct atapi_unit *u, uint32_t sectors, const char *name);

/* Take the disc out (OSD eject).  ATAPI_LOCKED while locked, nothing changes;
   otherwise ATAPI_OK and, if a disc was in, a REMOVED event is armed.
   The caller closes the file only on ATAPI_OK. */
int atapi_eject(struct atapi_unit *u);

int atapi_locked(const struct atapi_unit *u);

/* The glue's own errors (an SD read error, a host that gave up): the sense
   REQUEST SENSE reports for the command that failed. */
void atapi_set_sense(struct atapi_unit *u, uint8_t key, uint8_t asc, uint8_t ascq);

/* IDENTIFY PACKET DEVICE (0xA1): 256 words. */
void atapi_identify(uint16_t *id, const struct atapi_unit *u);

/* Execute one 12-byte packet.  limit = the host's byte-count limit (cylinder
   registers); it does not change the result, the glue splits data phases
   into DRQ blocks with it.  Returns r->kind. */
int atapi_packet(struct atapi_unit *u, const uint8_t *cdb, uint16_t limit, struct atapi_result *r);

#endif

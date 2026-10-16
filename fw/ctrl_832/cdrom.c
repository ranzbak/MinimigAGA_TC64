/*
 * CD-ROM board glue -- see cdrom.h and findings/cdrom/plan.md 7.1, 7.4, 9.
 *
 * The ATAPI unit of atapi.c on one IDE slot of the two-port Gayle.  The
 * Gayle port runs in packet mode (gayle_port.v): each data phase is set up
 * with WriteXfer (length in words), the task file (interrupt reason, byte
 * count) and a status write for the direction; the port raises DRQ and the
 * interrupt, and its xfer_done flag says when the host is through.
 *
 *   packet  reason 1 (CoD), 6 words out, no interrupt
 *   data in reason 2 (IO), byte count = block, pio in; the interrupt comes
 *           with the DRQ once the block is in the FIFO.  Blocks of at most
 *           the host's byte count limit and 8 KB (the FIFO); sectors go
 *           from the SD card straight into the FIFO (FileReadEx, direct).
 *   data out reason 0, byte count = block, pio out + interrupt
 *   status  reason 3 (IO|CoD), END + interrupt, ERR and the error register
 *           (sense key << 4, ABRT for ILLEGAL REQUEST / ABORTED COMMAND)
 *
 * While the firmware waits for the host it polls the port's flags: an
 * Amiga reset (rst_seen) or a command written over this one (packet mode
 * gone) ends the command without a status; a host that does nothing for
 * CD_TIMEOUT ms gets the command aborted, so the OSD never hangs on it.
 */

#include <stdio.h>
#include <string.h>

#include "hardware.h"
#include "fat.h"
#include "hdd.h"
#include "config.h"
#include "atapi.h"
#include "cdrom.h"

cdromTYPE cdrom;

static struct cd_disc cd_disc;		/* the disc in the drive (an ISO: one track) */
static char cd_filename[12];
static unsigned short cd_id[256];	/* IDENTIFY PACKET DEVICE words */
static unsigned char cd_cdb[12];

#define CD_TIMEOUT 10000	/* ms the host may take for one phase */
#define CD_FIFO_512 16		/* 512-byte units in one data-in block: the 8 KB FIFO */

/* cd_wait() and the data phases */
#define CD_DONE     1
#define CD_GONE     0	/* reset, or a new command: no status for this one */
#define CD_FAILED  -1	/* timeout or SD error: the unit's sense says which */

/* ---- the slot's config entry (5.3: the disc in the drive at power on) ---- */

static void cd_config(const char *name, const char *long_name, unsigned long dir)
{
	hardfileTYPE *hf;
	if (!cdrom.active)
		return;
	hf = SlotConfig(cdrom.slot);
	memset(hf->name, 0, sizeof(hf->name));
	memset(hf->long_name, 0, sizeof(hf->long_name));
	hf->present = name ? 1 : 0;
	if (name) {
		memcpy(hf->name, name, sizeof(hf->name));
		if (long_name)
			strncpy(hf->long_name, long_name, sizeof(hf->long_name));
		config.hdfdir[cdrom.slot] = dir;
	}
}

/* ---- drive state ---- */

int CD_Open(int slot)
{
	hardfileTYPE *hf;
	char name[9];
	char long_name[sizeof(hf->long_name) + 1];

	cdrom.hdf.type = HDF_DISABLED;
	cdrom.slot = slot;
	cdrom.active = slot >= 0 && slot < HDD_SLOTS;
	atapi_init(&cdrom.unit);
	if (!cdrom.active)
		return CD_OK;
	hf = SlotConfig(slot);
	hf->present = 0;
	if (!hf->name[0])
		return CD_OK;	/* CD slot, no disc */
	/* config names are fixed-width, not always terminated */
	memcpy(name, hf->name, 8);
	name[8] = 0;
	memcpy(long_name, hf->long_name, sizeof(hf->long_name));
	long_name[sizeof(hf->long_name)] = 0;
	return CD_Insert(name, long_name[0] ? long_name : 0, config.hdfdir[slot]);
}

int CD_Insert(const char *name, const char *long_name, unsigned long dir)
{
	char shortname[9];
	char longname[ATAPI_NAME_LEN + 1];

	if (!cdrom.active)
		return CD_NOFILE;
	/* copies first: name may be the config entry CD_Eject clears */
	memcpy(shortname, name, 8);
	shortname[8] = 0;
	if (long_name) {
		strncpy(longname, long_name, ATAPI_NAME_LEN);
		longname[ATAPI_NAME_LEN] = 0;
	}
	if (CD_Eject() != CD_OK)
		return CD_LOCKED;

	memcpy(cd_filename, shortname, 8);
	strcpy(&cd_filename[8], "ISO");
	if (!ValidateDirectory(dir))
		return CD_NOFILE;
	ChangeDirectory(dir);
	if (!FileOpen(&cdrom.hdf.file, cd_filename))
		return CD_NOFILE;

	cdrom.hdf.type = HDF_FILE;
	cdrom.hdf.offset = 0;
	BuildHardfileIndex(&cdrom.hdf);

	cue_single(&cd_disc, cd_filename, cdrom.hdf.file.size);
	atapi_insert(&cdrom.unit, &cd_disc, long_name ? longname : shortname);
	cd_config(shortname, long_name ? longname : 0, dir);
	if (DebugMode)
		printf("CD: insert %s (%s), %lu sectors\r\n", cd_filename, cdrom.unit.name, (unsigned long)cdrom.unit.sectors);
	return CD_OK;
}

/* The disc is out (OSD or Amiga eject): close the file, forget the name. */
static void cd_drop_file(void)
{
	cdrom.hdf.type = HDF_DISABLED;	/* FAT files need no close */
	cd_config(0, 0, 0);
}

int CD_Eject(void)
{
	CD_Locked();	/* an Amiga reset since the last command clears the lock */
	if (atapi_eject(&cdrom.unit) != ATAPI_OK)
		return CD_LOCKED;
	cd_drop_file();
	return CD_OK;
}

void CD_Reset(void)
{
	if (DebugMode)
		printf("CD: Amiga reset\r\n");
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
	if (cdrom.unit.locked) {
		/* the Amiga may have been reset since its last command: the
		   lock does not survive that (R-D) */
		CD_Flags(cdrom.slot >> 1, ReadIDEFlags(cdrom.slot >> 1));
	}
	return atapi_locked(&cdrom.unit);
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

/* Until the host is through with the data phase. */
static int cd_wait(int port)
{
	unsigned long timeout = GetTimer(CD_TIMEOUT);
	unsigned char flags;
	for (;;) {
		flags = ReadIDEFlags(port);
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
	}
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

/* Data in from the ISO: SD card -> FIFO, 512-byte FAT sectors, four per CD
   sector, blocks of at most the limit and 8 KB. */
static int cd_send_sectors(int port, unsigned char *tfr, unsigned long lba, unsigned long count, unsigned int limit)
{
	unsigned long left = count * 4;
	unsigned int per = limit >> 9;
	int r;
	if (per > CD_FIFO_512)
		per = CD_FIFO_512;
	if (!per)
		per = 1;	/* a limit below 512 bytes: blocks of 512 anyway */
	HardFileSeek(&cdrom.hdf, lba * 4);
	while (left) {
		unsigned int n = left < per ? (unsigned int)left : per;
		cd_phase(tfr, n << 9, 0x02, IDE_STATUS_RDY);
		if (!FileReadEx(&cdrom.hdf.file, 0, n)) {
			if (DebugMode)
				printf("CD: SD read error at %lu\r\n", lba * 4 + count * 4 - left);
			WriteXfer(0, 1);
			atapi_set_sense(&cdrom.unit, 0x03, 0x11, 0x00);
			return CD_FAILED;
		}
		if ((r = cd_wait(port)) != CD_DONE)
			return r;
		left -= n;
	}
	return CD_DONE;
}

/* Data out (MODE SELECT): taken and dropped, in blocks of at most the limit. */
static int cd_receive(int port, unsigned char *tfr, unsigned int len, unsigned int limit)
{
	int r;
	if (limit > CD_FIFO_512 * 512)
		limit = CD_FIFO_512 * 512;
	while (len) {
		unsigned int n = len < limit ? len : limit;
		cd_phase(tfr, n, 0x00, IDE_STATUS_REQ | IDE_STATUS_IRQ);
		if ((r = cd_wait(port)) != CD_DONE)
			return r;
		ReadIDEData(0, n);
		len -= n;
	}
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
	case ATAPI_RECEIVE:  printf(" < %u bytes", (unsigned)r->length); break;
	case ATAPI_CHECK:    printf(" CHECK %02X/%02X/%02X", r->sense_key, r->asc, r->ascq); break;
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

	atapi_packet(&cdrom.unit, cd_cdb, (uint16_t)limit, &r);
	if (DebugMode)
		cd_log_cdb(port, &r);
	if (r.ejected)
		cd_drop_file();

	switch (r.kind) {
	case ATAPI_RESPONSE:
		done = cd_send_buffer(port, tfr, atapi_buf, r.length, limit);
		break;
	case ATAPI_READ:
		done = cd_send_sectors(port, tfr, r.lba, r.count, limit);
		break;
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
}

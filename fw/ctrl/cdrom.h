#ifndef CDROM_H
#define CDROM_H

/*
 * CD-ROM board glue (findings/cdrom/plan.md 7.4, 13.5): the disc behind the
 * ATAPI unit of atapi.c -- an ISO, or a CUE sheet with its BIN / ISO / WAV
 * files -- and the Gayle side of the commands.
 */

#include <string.h>
#include "fat.h"
#include "hdd.h"
#include "atapi.h"

/* CD_Insert / CD_Eject status, shown by the OSD */
#define CD_OK      ATAPI_OK
#define CD_LOCKED  ATAPI_LOCKED	/* the Amiga locked the drive (D5) */
#define CD_NOFILE  2		/* bad directory or file not found */
#define CD_BADCUE  3		/* the CUE sheet was refused: CD_Message() says why */

/* hardfileTYPE.present of the CD slot: which disc the 8-character config
   name is (the config has no room for the extension, phase3-plan.md spec
   issue 1).  0 = no disc. */
#define CD_PRESENT_ISO 1
#define CD_PRESENT_CUE 2
#define CD_PRESENT(name83) (memcmp((name83) + 8, "CUE", 3) == 0 ? CD_PRESENT_CUE : CD_PRESENT_ISO)

typedef struct
{
	hdfTYPE           hdf;	/* the disc file being read (a CUE's data track's file): file + cluster index */
	struct atapi_unit unit;
	int               slot;	/* IDE slot (port << 1 | slave), valid while active */
	unsigned char     active;	/* a CD drive is configured (BSS zero: none) */
} cdromTYPE;

extern cdromTYPE cdrom;

/* The CD drive's IDE slot, -1 when there is none. */
#define CD_SLOT() (cdrom.active ? cdrom.slot : -1)

/* Make slot the CD drive and insert the ISO configured for it, if any.
   slot -1: no CD drive.  Returns CD_OK or CD_NOFILE. */
int CD_Open(int slot);

/* OSD insert or swap.  name: the 8.3 name as in fileTYPE.name (11
   characters, no dot): "xxxxxxxxISO" or "xxxxxxxxCUE"; long_name: the long
   name without extension (IDENTIFY / INQUIRY, D7), may be NULL.  Refused
   with CD_LOCKED while the Amiga holds the lock; CD_NOFILE when the ISO /
   CUE is not there; CD_BADCUE when the CUE or one of its files is refused
   (CD_Message()).  The drive is empty after any refusal but CD_LOCKED. */
int CD_Insert(const char *name, const char *long_name, unsigned long dir);

/* Why the last CD_Insert was refused, at most 23 characters ("" if it was not). */
const char *CD_Message(void);

/* OSD eject.  CD_LOCKED while the Amiga holds the lock, nothing changes. */
int CD_Eject(void);

/* Amiga reset seen (Gayle rst_seen): lock cleared, UNIT ATTENTION 06/29/00. */
void CD_Reset(void);

/* The Amiga holds the lock (PREVENT MEDIUM REMOVAL); looks for a reset first
   (not while an IDE command is in progress, hdd_busy(): an HDD command's
   port latch, a CD command's own flags look). */
int CD_Locked(void);

/* The flags of a task file register read of port: an rst_seen on the CD's
   port resets the unit (CD_Reset). */
void CD_Flags(int port, unsigned char flags);

/* A command for the CD unit; tfr = the 8 task file registers.  The
   command runs to its end here, except READ(10)/(12) and READ CD: their
   data phases go on in CD_Step (CD_Busy() 1 until the status). */
void CD_HandleCommand(int port, unsigned char *tfr);

/* The CD drive's READ as main-loop states (findings/sdcard-engine Task
   11b): CD_Step() takes one step (1: the next one at once, 0: wait for the
   next pass), from hdd.c hdd_poll(), the dispatcher of the one IDE command
   in progress (hdd_busy() covers CD_Busy(): the pickup waits, ruling
   T11-R4).  DATA2048 sectors go from the card into Gayle's FIFO in to_gayle
   card runs (sdproto.h), at most 16 sectors and inside one cluster
   (hdd_file_run), each data-in block only after the host read the last one
   (XFER_DONE: "drain, then refill").  Rule: no IDE command on cs 0x10
   (EnableFpga: WriteXfer, WriteTaskFile, WriteStatus, ReadIDEFlags, the
   data commands) while a Gayle op may run (sd_gayle_busy()): the bridge
   owns hdd_port, hdd_data_out and hdd_addr then (rtl/minimig/
   sdcard_gayle.v).  The main loop's own cs 0x10 users (HandleFpga, the
   floppy) are gated the same way (main.c PollDisks). */
int CD_Busy(void);
int CD_Step(void);
/* 1 while a data-in block is part-delivered (some of its sectors in
   Gayle's FIFO, not all): the Amiga may be reading it, held by nrdy, so
   the main loop does nothing but the disk steps until it is complete
   (hdd_in_block, main.c PollDisks; findings/sdcard-engine Task 11b fix
   round 1) */
int CD_InBlock(void);
/* End a READ in progress for the callers that change the drive (OSD eject
   and insert, CD_Open, ColdBoot): its card op finished, the transfer
   dropped, CHECK CONDITION 0B/00/00 (ABORTED COMMAND), unless the Amiga
   left it (no status then) */
void CD_Cancel(void);

/* CD audio poll of the main loop (13.1, 13.7): the refill, and while the
   music plays outside a CD command, the CD port's flags (an Amiga reset
   stops the player).  That flags read is a CMD_IDE_REGS_RD of the CD's
   port, whose command word re-latches the Gayle's firmware port
   (paula_floppy.v hdd_port_r): never call this inside an IDE or floppy
   transfer, use CD_AudioRefill there.  The main loop calls it only while no
   IDE command (HDD or CD) is in progress (main.c PollDisks, hdd_busy();
   findings/sdcard-engine Tasks 11a, 11b), CD_AudioRefill during one. */
void CD_AudioPoll(void);

/* CD audio refill only (13.5): no IDE register access, so it is safe
   between the blocks of every transfer loop (hdd.c, fdd.c), never inside an
   SD multi-block read or write.  Prints "CDA: underrun n" in DebugMode. */
void CD_AudioRefill(void);

/* The track the player is in (playing or paused), 0 when it is not: the
   OSD's play mark (13.8 step 3c). */
int CD_PlayingTrack(void);

#endif

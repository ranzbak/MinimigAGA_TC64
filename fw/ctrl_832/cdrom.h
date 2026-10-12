#ifndef CDROM_H
#define CDROM_H

/*
 * CD-ROM board glue (findings/cdrom/plan.md 7.4): the ISO file behind the
 * ATAPI unit of atapi.c, and the Gayle side of the commands.
 *
 * Phase 0: compiled and linked, not called from anywhere.
 * CD_HandleCommand is a stub until task 1.4 (it needs the two-port Gayle
 * with packet mode of phase 1).
 */

#include "fat.h"
#include "hdd.h"
#include "atapi.h"

/* CD_Insert / CD_Eject status, shown by the OSD */
#define CD_OK      ATAPI_OK
#define CD_LOCKED  ATAPI_LOCKED	/* the Amiga locked the drive (D5) */
#define CD_NOFILE  2		/* bad directory or file not found */

typedef struct
{
	hdfTYPE           hdf;	/* the ISO: file + cluster index; sector n = HardFileSeek(&hdf, 4*n) */
	struct atapi_unit unit;
	int               slot;	/* IDE slot (port << 1 | slave), valid while active */
	unsigned char     active;	/* a CD drive is configured (BSS zero: none) */
} cdromTYPE;

extern cdromTYPE cdrom;	/* not "cd": main.c has a struct cdimage cd (bincue) */

/* The CD drive's IDE slot, -1 when there is none. */
#define CD_SLOT() (cdrom.active ? cdrom.slot : -1)

/* Make slot the CD drive and insert the ISO configured for it, if any.
   slot -1: no CD drive.  Returns CD_OK or CD_NOFILE. */
int CD_Open(int slot);

/* OSD insert or swap.  name: 8-character short name without extension, as
   in hardfileTYPE; long_name: the ISO's long name (IDENTIFY / INQUIRY, D7),
   may be NULL.  Refused with CD_LOCKED while the Amiga holds the lock. */
int CD_Insert(const char *name, const char *long_name, unsigned long dir);

/* OSD eject.  CD_LOCKED while the Amiga holds the lock, nothing changes. */
int CD_Eject(void);

/* Amiga reset seen (Gayle rst_seen): lock cleared, UNIT ATTENTION 06/29/00. */
void CD_Reset(void);

/* The Amiga holds the lock (PREVENT MEDIUM REMOVAL); looks for a reset first. */
int CD_Locked(void);

/* The flags of a task file register read of port: an rst_seen on the CD's
   port resets the unit (CD_Reset). */
void CD_Flags(int port, unsigned char flags);

/* A command for the CD unit; tfr = the 8 task file registers. */
void CD_HandleCommand(int port, unsigned char *tfr);

#endif

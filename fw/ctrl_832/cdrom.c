/*
 * CD-ROM board glue -- see cdrom.h and findings/cdrom/plan.md 7.4.
 *
 * Phase 0 skeleton: linked into the image, called by nothing.
 */

#include <string.h>

#include "hardware.h"
#include "fat.h"
#include "hdd.h"
#include "config.h"
#include "atapi.h"
#include "cdrom.h"

cdromTYPE cdrom;

static char cd_filename[12];

int CD_Open(int slot)
{
	hardfileTYPE *hf;

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
	if (CD_Insert(hf->name, hf->long_name[0] ? hf->long_name : 0, config.hdfdir[slot]) != CD_OK)
		return CD_NOFILE;
	hf->present = 1;
	return CD_OK;
}

int CD_Insert(const char *name, const char *long_name, unsigned long dir)
{
	char shortname[9];
	char longname[ATAPI_NAME_LEN + 1];

	if (CD_Eject() != CD_OK)
		return CD_LOCKED;

	memcpy(cd_filename, name, 8);
	strcpy(&cd_filename[8], "ISO");
	if (!ValidateDirectory(dir))
		return CD_NOFILE;
	ChangeDirectory(dir);
	if (!FileOpen(&cdrom.hdf.file, cd_filename))
		return CD_NOFILE;

	cdrom.hdf.type = HDF_FILE;
	cdrom.hdf.offset = 0;
	BuildHardfileIndex(&cdrom.hdf);

	/* config names are fixed-width, not always terminated */
	memcpy(shortname, name, 8);
	shortname[8] = 0;
	if (long_name) {
		strncpy(longname, long_name, ATAPI_NAME_LEN);
		longname[ATAPI_NAME_LEN] = 0;
	}
	atapi_insert(&cdrom.unit, cdrom.hdf.file.size / ATAPI_SECTOR_SIZE, long_name ? longname : shortname);
	return CD_OK;
}

int CD_Eject(void)
{
	if (atapi_eject(&cdrom.unit) != ATAPI_OK)
		return CD_LOCKED;
	cdrom.hdf.type = HDF_DISABLED;	/* FAT files need no close */
	return CD_OK;
}

void CD_Reset(void)
{
	atapi_reset(&cdrom.unit);
}

void CD_HandleCommand(int port, unsigned char *tfr)
{
	/* Task 1.4: 0xA0 / 0xA1 / 0xEC / 0x90 / 0x08 / 0xEF over the two-port
	   Gayle.  Until then every command aborts, as for an absent unit. */
	WriteTaskFile(0x04, tfr[2], tfr[3], tfr[4], tfr[5], tfr[6]);
	WriteStatus(IDE_STATUS_END | IDE_STATUS_IRQ | IDE_STATUS_ERR);
}

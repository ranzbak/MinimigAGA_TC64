/*
 * openhf_test: hdd.c's OpenHardfile() on a CD-ROM slot (review finding,
 * phase 3, 2026-10-16).  The function is cut out of ../hdd.c by the
 * Makefile (openhf.inc) and built here with stubs: hdd.c as a whole does
 * not build with gcc.
 *
 * ApplyConfiguration and the Harddisks page call OpenHardfile on every
 * slot before ApplyCDROM; the CD slot's present byte is the ISO / CUE
 * marker CD_Open reads (phase3-plan.md, spec issue 1).  OpenHardfile used
 * to zero it, so a CUE in the config came back as NAME.ISO after a boot.
 */
#include <stdio.h>
#include <string.h>
#include "errors.h"
#include "hardware.h"
#include "fat.h"
#include "hdd.h"
#include "config.h"
#include "cdrom.h"

/* the globals and calls OpenHardfile uses */
configTYPE config;
hdfTYPE hdf[HDD_SLOTS];
struct PartitionEntry partitions[4];
int ErrorMask;
struct Error Errors[ERROR_MAX + 1];
static char filename[12];
static hardfileTYPE slots[HDD_SLOTS];
static int file_opens;

hardfileTYPE *SlotConfig(int slot) { return &slots[slot]; }
int ValidateDirectory(unsigned long dir) { return 1; }
void ChangeDirectory(unsigned long dir) { }
unsigned char FileOpen(fileTYPE *file, const char *name) { file_opens++; return 0; }
void GetHardfileGeometry(hdfTYPE *pHDF) { }
unsigned long GetTimer(unsigned long offset) { return 0; }
void BuildHardfileIndex(hdfTYPE *pHDF) { }

#include "openhf.inc"

static int fails;

static void check(const char *what, int got, int want)
{
	if (got != want) {
		printf("FAIL %s: got %d, want %d\n", what, got, want);
		fails++;
	} else
		printf("ok   %s = %d\n", what, got);
}

int main(void)
{
	int slot;
	for (slot = 0; slot < HDD_SLOTS; slot++) {
		/* a CD slot as the config holds it: the CUE marker and its 8-character name */
		memset(slots, 0, sizeof(slots));
		slots[slot].enabled = HDF_CDROM;
		slots[slot].present = CD_PRESENT_CUE;
		memcpy(slots[slot].name, "PINBAL~1", 8);
		file_opens = 0;
		check("OpenHardfile on a CD slot returns 0", OpenHardfile(slot), 0);
		check("the CD slot's present byte (CUE marker) is kept", slots[slot].present, CD_PRESENT_CUE);
		check("no hardfile opened for a CD slot", file_opens, 0);
		check("hdf[] type stays disabled", hdf[slot].type, HDF_DISABLED);
	}
	/* a disabled slot still reads not present */
	memset(slots, 0, sizeof(slots));
	slots[0].present = 1;
	check("a disabled slot: present cleared", (OpenHardfile(0), slots[0].present), 0);
	printf(fails ? "FAIL %d\n" : "PASS\n", fails);
	return fails ? 1 : 0;
}

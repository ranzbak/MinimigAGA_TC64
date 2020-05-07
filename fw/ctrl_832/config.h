#include "fat.h"

typedef struct
{
    char name[8];
    char long_name[16];
} kickstartTYPE;

typedef struct
{
    unsigned char lores;
    unsigned char hires;
} filterTYPE;

typedef struct
{
    unsigned char speed;
    unsigned char drives;
} floppyTYPE;

typedef struct
{
    unsigned char enabled;	// 0: Disabled, 1: Hard file, 2: MMC (entire card), 3-6: Partition 1-4 of MMC card
    unsigned char present;
    char name[8];
    char long_name[16];
} hardfileTYPE;

typedef struct
{
    char          id[8];
    unsigned long version;
    kickstartTYPE kickstart;
    filterTYPE    filter;
    unsigned char memory;
    unsigned char chipset;
    floppyTYPE    floppy;
    unsigned char disable_ar3;
    unsigned char enable_ide;
    unsigned char scanlines;
	unsigned char misc; // Contains extra settings, such as scandoubler, (turbo kickstart? turbo slowram?)
    hardfileTYPE  hardfile[2];
    unsigned char cpu;
	unsigned char fastram;	// Contains fast mem (bit 0 & 1) and turbo chipram (bit 7) settings.
	unsigned char kick13patch;
	unsigned char autofire;
} configTYPE;

extern fileTYPE file;	// Temporary file available for use by other modules, to avoid repeated memory usage.
						// Shouldn't be considered persistent.

extern configTYPE config; 
extern char DebugMode;

char UploadKickstart(char *name);
char UploadActionReplay();
void SetConfigurationFilename(int config);	// Set configuration filename by slot number
unsigned char LoadConfiguration(char *filename);	// Can supply NULL to use filename previously set by slot number
unsigned char SaveConfiguration(char *filename);	// Can supply NULL to use filename previously set by slot number
unsigned char ConfigurationExists(char *filename);
void ApplyConfiguration(char reloadkickstart);


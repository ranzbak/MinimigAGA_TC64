#include "fat.h"

#define CONFIG_VERSION 4
#define CONFIG_VERSION_EXTROM 2
#define CONFIG_VERSION_ROMPATH 3
#define CONFIG_VERSION_DRIVESOUNDS 3

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
  unsigned char volume;
} audioTYPE;

typedef struct
{
  unsigned char hpos;
  unsigned char vpos;
} videoPosTYPE;

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
	unsigned char misc; // Contains extra settings, such as scandoubler
  hardfileTYPE  hardfile[2];
  unsigned char cpu;
	unsigned char fastram;	// Contains fast mem (bit 0 & 1) and turbo chipram (bit 7) settings.
	unsigned char kick13patch;
	unsigned char autofire;
  kickstartTYPE extrom;		// Added in V2 config
	unsigned char drivesounds;	// Added in V3 config
	unsigned char pad1;
	unsigned char pad2;
	unsigned char pad3;
	unsigned long kickdir;	// Directory of kick file.
	unsigned long extromdir;	// Directory of ext rom file.
	unsigned long hdfdir[4]; // Directory for HDF files.  Space for expansion to four devices.
  hardfileTYPE  secondaryhardfile[2]; // hardfile entries for potential secondary IDE devices.
  audioTYPE     audio;
  videoPosTYPE  videopos;
  // ADV7511 clock delay (register 0xBA bits 7:5) + 1, so 1..8 = -1.2 .. +1.6 ns
  // in 0.4 ns steps.  0 = the firmware default.  This byte was the struct's
  // tail padding, so sizeof(configTYPE) stays 212 and config files remain
  // interchangeable with older firmware (theirs hold 0 here).
  unsigned char hdmi_clkdelay;
} configTYPE;

extern fileTYPE file;	// Temporary file available for use by other modules, to avoid repeated memory usage.
						// Shouldn't be considered persistent.

extern configTYPE config; 
extern char DebugMode;

int UploadKickstart(unsigned long dir,char *name);
char UploadActionReplay();
void SetConfigurationFilename(int config);	// Set configuration filename by slot number
unsigned char LoadConfiguration(char *filename);	// Can supply NULL to use filename previously set by slot number
unsigned char SaveConfiguration(char *filename);	// Can supply NULL to use filename previously set by slot number
unsigned char ConfigurationExists(char *filename);
int ApplyConfiguration(char reloadkickstart,char applydrives);


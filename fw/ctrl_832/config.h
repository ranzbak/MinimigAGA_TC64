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
  unsigned char hpos;	// signed HD pixels, positive right (-128..120, steps of 8)
  unsigned char vpos;	// signed Amiga lines (64 us), positive down (-VPOS_MAX..VPOS_MAX, steps of VPOS_STEP)
} videoPosTYPE;

// Video Pos VPOS range and menu step.  Firmware before VPOS worked (it did
// nothing in the HDMI core) stepped this byte by 8, unsigned; such a value
// within the range now moves the picture that many lines in the direction
// pressed (8 down, 248 = -8 up), anything further out loads as 0.
#define VPOS_MAX  64
#define VPOS_STEP 2

// HDMI Scaling (rtl/openaars/adv7511, findings/scaler/plan.md): the Video
// page's "Scaling", bits 5:4 of config.scanlines.  Sharp and Area scale the
// 15 kHz picture by exactly 2.5x (PAL 288 -> 720 lines) / 3x (NTSC 240 ->
// 720) in linear light; Line rate is the picture of before (~2.4x / 2.9x,
// one input line per 2 or 3 HD lines).  Sharp is 0: fresh configs (memset 0)
// and config files from older firmware -- which never wrote these bits,
// kept them through their menu and sent only bits 1:0 -- get it.  The
// struct stays 212 bytes, CONFIG_VERSION 4.  3 loads as Sharp.
#define SCALING_SHIFT 4
#define SCALING_MASK  (3 << SCALING_SHIFT)
#define SCALING_SHARP 0
#define SCALING_AREA  1
#define SCALING_LINE  2
#define CONFIG_SCALING(scanlines) (((scanlines) & SCALING_MASK) >> SCALING_SHIFT)

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
  // bits 1:0 the Video page's Scanlines (0 off, 1 dim, 2 black); bits 3:2
  // its old "(laced)" item, which no core here ever got (ConfigVideo sends
  // bits 1:0 only) and which left the menu for Scaling -- the bits stay as
  // they were; bits 5:4 the HDMI Scaling (SCALING_* below)
  unsigned char scanlines;
	unsigned char misc; // Contains extra settings, such as scandoubler
  hardfileTYPE  hardfile[2];
  unsigned char cpu;
	unsigned char fastram;	// Contains fast mem (bit 0 & 1) and turbo chipram (bit 7) settings.
	unsigned char kick13patch;
	unsigned char autofire;
  kickstartTYPE extrom;		// Added in V2 config
	unsigned char drivesounds;	// Added in V3 config
	// HDMI horizontal beam spot (rtl/openaars/adv7511/crt_beamh.v): the
	// Video page's "Beam width" (0 off, 1 sharp, 2 medium, 3 soft).  This
	// was pad1, which nothing ever wrote: older config files hold 0 here
	// (off), the struct stays 212 bytes and older firmware ignores it.
	unsigned char crt_beam;
	// HDMI CRT emulation (rtl/openaars/adv7511/crt_post.v): the Video page's
	// "CRT Mask" (0 off, 1 grille, 2 grille strong, 3 shadow) and "Bloom"
	// (0 off, 1 low, 2 high).  These were pad2 and pad3, which nothing ever
	// wrote: config files from older firmware hold 0 here (both off), the
	// struct stays 212 bytes (config.c checks it) and older firmware simply
	// ignores the two bytes.
	unsigned char crt_mask;
	unsigned char crt_bloom;
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


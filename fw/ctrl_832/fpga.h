#ifndef FPGA_H
#define FPGA_H

#include "rafile.h"

void ShiftFpga(unsigned char data);
unsigned char ConfigureFpga(void);
void SendFileV2(RAFile* file, unsigned char* key, int keysize, int address, int size);
void SendFileEncrypted(RAFile *file,unsigned char *key,int keysize);
char BootPrint(const char *text);
char PrepareBootUpload(unsigned char base, unsigned char size);
void BootExit(void);
void ClearMemory(unsigned long base, unsigned long size);
unsigned char GetFPGAStatus(void);
void fpga_init();

extern int checksum_pre;

// What the core answered when asked what it is (OSD_CMD_VERSION bytes 4 and
// 5, guarded by the 0xA4 magic).  Zero on any core that predates the query,
// which is exactly what the old menu behaviour assumes -- so every test here
// must be written so that 0 means "as before".
extern unsigned char core_caps;

#define CORE_CAPS_AP040      0x01   // an AP68040 is fitted
#define CORE_CAPS_AP040_SEL  0x02   // ... and it can be selected (dual build)
#define CORE_CAPS_FPU        0x04
#define CORE_CAPS_MMU        0x08
#define CORE_CAPS_KEYQ       0x10   // the OSD has a key-event queue (OSD_CMD_KEYQ)

// True when the core has a 68040 that cannot be switched away from: the CPU
// menu line is then a statement of fact, not a choice.
#define CORE_CPU_FIXED_040() \
	(((core_caps) & CORE_CAPS_AP040) && !((core_caps) & CORE_CAPS_AP040_SEL))

#endif


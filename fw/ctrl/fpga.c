/*
Copyright 2005, 2006, 2007 Dennis van Weeren
Copyright 2008, 2009 Jakub Bednarski

This file is part of Minimig

Minimig is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 3 of the License, or
(at your option) any later version.

Minimig is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
*/

// 2009-10-10   - any length (any multiple of 8 bytes) fpga core file support
// 2009-12-10   - changed command header id
// 2010-04-14   - changed command header id

//#include "AT91SAM7S256.h"
#include <stdio.h>
#include <string.h>
#include "version.h"
#include "errors.h"
#include "hardware.h"
#include "fat.h"
#include "fdd.h"
#include "rafile.h"
#include "boot.h"

#include "fpga.h"
#include "osd.h"
#include "osd2.h"
#include "config.h"

#define CMD_HDRID 0xAACA

extern fileTYPE file;
extern char s[40];

int checksum_pre;


int CheckSum(char *adr,int size);

char BootPrint(const char *text);


char kick1xfoundstr[] = "Kickstart v1.x found\n";
const char applymemdetectionpatchstr[] = "Applying Kickstart 1.x memory detection patch\n";

const char *kickfoundstr, *applypatchstr;

void PatchKick1xMemoryDetection(unsigned char *buf) {

  if (!strncmp((const char *)buf + 0x18, "exec 33.192 (8 Oct 1986)", 24)) {
    kick1xfoundstr[13] = '2';
    kickfoundstr = kick1xfoundstr;
    goto applypatch;
  }
  if (!strncmp((const char *)buf + 0x18, "exec 34.2 (28 Oct 1987)", 23)) {
    kick1xfoundstr[13] = '3';
    kickfoundstr = kick1xfoundstr;
    goto applypatch;
  }

  goto out;

applypatch:
  if ((buf[0x154] == 0x66) && (buf[0x155] == 0x78)) {
    applypatchstr = applymemdetectionpatchstr;
    buf[0x154] = 0x60;
  }

out:
  return;
}


// SendFileV2 (for minimig_v2): 1, or 0 with ERROR_ROM set when a read of
// the file failed (findings/sdcard-engine Task 10 fix round 1: the Amiga
// must not run a part-loaded ROM; the error page reboots on ERROR_ROM)
int SendFileV2(RAFile* file, unsigned char* key, int keysize, int address, int size)
{
	int i,j;
	unsigned int keyidx=0;

	checksum_pre=0;


	printf("File size: %dkB\r", size>>1);
	printf("[");
	if (keysize) {
		// read header
		if (!RARead(file, sector_buffer, 0xb)) {
			SetError(ERROR_ROM, "ROM read error", address, -1);
			printf("]\r");
			return 0;
		}
	}

	for (i=0; i<size; i++) {
		unsigned char *adr = (unsigned char *)(((address + i*512) & 0x7fffff) ^ HOSTMAP_ADDR);
		if (!(i&31)) printf("*");
		if (!RARead(file, adr, 512)) {
			SetError(ERROR_ROM, "ROM read error", address, i);
			printf("]\r");
			return 0;
		}
		if (keysize) {
			// decrypt ROM
			for (j=0; j<512; j++) {
				adr[j] ^= key[keyidx++];
				if(keyidx >= (unsigned int)keysize) keyidx -= keysize;
			}
		}
		checksum_pre+=CheckSum((char *)adr,512);

		// patch kickstart 1.x to force memory detection every time the AMIGA is reset
		if (config.kick13patch && (i == 0 || i == 512)) {
			kickfoundstr = NULL;
			applypatchstr = NULL;
			PatchKick1xMemoryDetection(adr);
		}

	}
	printf("]\r");

	if (kickfoundstr) {
		printf("%s", kickfoundstr);
	}
	if (applypatchstr) {
		printf("%s", applypatchstr);
	}
	return 1;
}


// print message on the boot screen
// (Temporarily disabled.)
/* Falls off the end of a non-void function (no caller uses the value):
 * found by -Wextra, left as is (README, "Found by -Wextra", fpga.c BootPrint). */
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wreturn-type"
char BootPrint(const char *text)
{
	(void)text;
//	BootPrintEx(text);
//	return(1);
}
#pragma GCC diagnostic pop

void ClearMemory(unsigned long base, unsigned long size)
{
    unsigned char c1, c2 __attribute__((unused)), c3, c4;

    while (1)
    {
        EnableFpga();
        c1 = SPI(0x10); // track read command
        c2 = SPI(0x01); // disk present
        SPI(0);
        SPI(0);
        c3 = SPI(0);
        c4 = SPI(0);
        if (c1 & CMD_RDTRK)
        {
            if (c3 == 0x80 && c4 == 0x06)// command packet size 12 bytes
            {
                SPI(CMD_HDRID >> 8); // command header
                SPI(CMD_HDRID & 0xFF);
                SPI(0x00); // cmd: 0x0004 = clear memory
                SPI(0x04);
                // memory base
                SPI((unsigned char)(base >> 24));
                SPI((unsigned char)(base >> 16));
                SPI((unsigned char)(base >> 8));
                SPI((unsigned char)base);
                // memory size
                SPI((unsigned char)(size >> 24));
                SPI((unsigned char)(size >> 16));
                SPI((unsigned char)(size >> 8));
                SPI((unsigned char)size);
            }
            DisableFpga();
            return;
        }
        DisableFpga();
    }
}

unsigned char GetFPGAStatus(void)
{
    unsigned char status;

    EnableFpga();
    status = SPI(0);
    SPI(0);
    SPI(0);
    SPI(0);
    SPI(0);
    SPI(0);
    DisableFpga();

    return status;
}


// What the core told us about itself, 0 if it is too old to be asked.  See
// CORE_CAPS_* in fpga.h and userio_osd.v's rtl_ver.
unsigned char core_caps = 0;
unsigned char core_version[4];
const char fw_version[] = MM_FIRMWARE_VERSION;

void fpga_init() {
	unsigned long time __attribute__((unused)) = GetTimer(0);
	char ver_beta,ver_major,ver_minor,ver_minion;
	char ver_magic,ver_caps;
	unsigned char osd2_ver[4];
	int i;
	char rtl_ver[45];

	EnableOsd();
	SPI(OSD_CMD_VERSION);
	ver_beta   = SPI_reply();
	ver_major  = SPI_reply();
	ver_minor  = SPI_reply();
	ver_minion = SPI_reply();
	// Two more bytes, which an older core does not have: it answers
	// MINION_VER to both, so the magic byte is what says the second one means
	// anything.  Without this check a 68000 core would look like whatever its
	// minion version happens to spell.
	ver_magic  = SPI_reply();
	ver_caps   = SPI_reply();
	// Bytes 10-13: the OSD text layer (osd2.h; 0xB5, version, 64, 32).  An
	// older core answers MINION_VER (a day, <= 31) there, never 0xB5.  Bytes
	// 6-9 (the input diagnostic) are read only to get there; reading byte 9
	// clears its sticky half, which at boot holds nothing anyone has seen.
	for (i = 6; i < 10; i++)
		SPI_reply();
	for (i = 0; i < 4; i++)
		osd2_ver[i] = SPI_reply();
	DisableOsd();
	core_caps = (ver_magic == (char)0xA4) ? ver_caps : 0;
	core_version[0] = (unsigned char)ver_beta;
	core_version[1] = (unsigned char)ver_major;
	core_version[2] = (unsigned char)ver_minor;
	core_version[3] = (unsigned char)ver_minion;
	SPIN; SPIN; SPIN; SPIN;
	if (osd2_detect(ver_magic == (char)0xA4, osd2_ver))
		osd2_init(OSD2_ATTR(OSD2_C_WHITE, OSD2_C_BLACK));   // the window off, the cell RAM to be cleared

	OsdDoReset(SPI_RST_USR | SPI_RST_CPU | SPI_CPU_HLT,SPI_RST_CPU | SPI_CPU_HLT);

	WaitTimer(50);
	BootInit();
	WaitTimer(100);

	BootHome();

	sprintf(rtl_ver, "Minimig AGA%s version 20%d-%d-%d for Turbo Chameleon 64", ver_beta ? " BETA" : "",
		ver_major, ver_minor, ver_minion);
	BootPrintEx(rtl_ver);
	sprintf(rtl_ver, "Firmware version: %s",MM_FIRMWARE_VERSION);
	BootPrintEx(rtl_ver);
	if (core_caps & CORE_CAPS_AP040) {
		sprintf(rtl_ver, "CPU: MC68040%s%s",
			(core_caps & CORE_CAPS_FPU) ? " + FPU" : "",
			(core_caps & CORE_CAPS_MMU) ? " + MMU" : "");
		BootPrintEx(rtl_ver);
	}
	// the text layer's reply bytes, whatever the core (an old one: MINION_VER)
	sprintf(rtl_ver, "OSD2: %02X %02X %02X %02X", osd2_ver[0], osd2_ver[1], osd2_ver[2], osd2_ver[3]);
	BootPrintEx(rtl_ver);
	BootPrintEx(" ");
	BootPrintEx("Minimig AGA by Rok Krajnc.  Original Minimig by Dennis van Weeren");
	BootPrintEx("Updates by Jakub Bednarski, Tobias Gubener, Sascha Boing, A.M. Robinson & others");
	BootPrintEx(" ");
	BootPrintEx("Ported to Turbo Chameleon 64 by Alastair M. Robinson");
	BootPrintEx("Ported to Open AARS by Paul Honig");
	BootPrintEx(" ");
	WaitTimer(1000);
    
    //eject all disk
    df[0].status = 0;
    df[1].status = 0;
    df[2].status = 0;
    df[3].status = 0;
}


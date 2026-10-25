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

// 2008-10-04   - porting to ARM
// 2008-10-06   - support for 4 floppy drives
// 2008-10-30   - hdd write support
// 2009-05-01   - subdirectory support
// 2009-06-26   - SDHC and FAT32 support
// 2009-08-10   - hardfile selection
// 2009-09-11   - minor changes to hardware initialization routine
// 2009-10-10   - any length fpga core file support
// 2009-11-14   - adapted floppy gap size
//              - changes to OSD labels
// 2009-12-24   - updated version number
// 2010-01-09   - changes to floppy handling
// 2010-07-28   - improved menu button handling
//              - improved FPGA configuration routines
//              - added support for OSD vsync
// 2010-08-15   - support for joystick emulation
// 2010-08-18   - clean-up

// FIXME - detect number of partitions on the SD card, and allow that many to be selected as hard files.

//#include "AT91SAM7S256.h"
//#include "stdio.h"
//#include "string.h"
#include "errors.h"
#include "boot.h"
#include "hardware.h"
#include "mmc.h"
#include "fat.h"
#include "osd.h"
#include "fpga.h"
#include "fdd.h"
#include "hdd.h"
#include "swap.h"
#include "menu.h"
#include "config.h"
#include "c64keys.h"
#include "akiko.h"
#include "irq.h"
#include "sdc.h"
#include "sdproto.h"
#include "drivesounds.h"
#include "cdrom.h"
#include "audio.h"
#include "rtc.h"
#include "version.h"

#include <stdio.h>
#include "adv7511.h"
#include "stackcheck.h"
#include "diskstat.h"

static unsigned long adv_timer = 0;
static unsigned char adv_first = 1;   // service the ADV7511 once at start-up
static unsigned char adv_int_was = 0; // INT level at the last check (edge detect)
unsigned long adv_services = 0;       // OSD HDMI page: how often the part was serviced
unsigned char adv_int_now = 0;        // OSD HDMI page: INT level at the last check

const char version[] = MM_VERSTRING;

extern adfTYPE df[4];

char s[40];

extern int _bss_start__;
int CheckSum(char *adr,int size)	/* checksum_pre: the 68k's big-endian words, byte-wise, wrapping */
{
	char *end=adr+size;
	unsigned int sum=0;
	while(adr<end)
	{
		sum+=rd_be32(adr);
		adr+=4;
	}
	return(sum);
}

#if 0
void FatalError(unsigned long error)
{
    unsigned long i;

    sprintf(s,"Fatal error: %lu\n", error);
	BootPrintEx(s);

    while (1)
    {
        for (i = 0; i < error; i++)
        {
            DISKLED_ON;
            WaitTimer(250);
            DISKLED_OFF;
            WaitTimer(250);
        }
        WaitTimer(1000);
    }
}
#endif


void HandleFpga(void)
{
    unsigned char  c1, c2,c3,c4;

    EnableFpga();
    c1 = SPI(0); // cmd request and drive number
    c2 = SPI(0); // track number
    SPI(0);
    SPI(0);
    c3 = SPI(0);
    c4 = SPI(0);
    DisableFpga();

    HandleFDD(c1, c2, c3 ,c4);
    HandleHDD(c1, c2);

    UpdateDriveStatus();
}


// One pass of the disk work, in the main loop and the error page's loop:
// the SD card op and the HDD data path (findings/sdcard-engine Task 11a:
// both advance here, a step per pass, never a wait), the CD audio refill,
// the FPGA's requests (floppy, the IDE command pickup; fpga 0: not those).
// During an HDD command the refill only: CD_AudioPoll reads the CD port's
// flags, whose command word re-latches the Gayle's firmware port (cdrom.h).
// No FPGA command while a Gayle op runs: the bridge owns hdd_port,
// hdd_data_out and hdd_addr then (rtl/minimig/sdcard_gayle.v).
void PollDisks(int fpga)
{
	sd_poll();
	hdd_poll();
	if (hdd_busy())
		CD_AudioRefill();
	else
		CD_AudioPoll();	// CD audio refill (findings/cdrom/plan.md 13.1)
	if (fpga && !sd_gayle_busy())
		HandleFpga();
}


// The interrupt sources on cfide's controller (arch/irq.h; the dispatcher
// calls one handler per pending bit): vertical blank -> the C64 keyboard
// scan, the Amiga's Akiko request -> akiko_inthandler.  Both are pulses,
// EDGE (the reset mode).  The SD peripheral's bit is sdc_init()'s.  This
// replaces the legacy INTERRUPT register, whose one handler ran both on
// every event (vblank, Akiko and each I2C transfer event).
void IrqSetupSources(void)
{
	IrqSetHandler(IRQ_VBLANK, c64keys_inthandler);
	IrqSetHandler(IRQ_AKIKO, akiko_inthandler);
	IrqEnable(IRQ_VBLANK);
	IrqEnable(IRQ_AKIKO);
}


int ColdBoot()
{
	int result=0;
	hdd_cancel();	/* an HDD command in progress ends (ERR) before the card starts over */
	/* Reset the chipset briefly to cancel AGA display modes, then Put the CPU in reset while we initialise */
	OsdDoReset(SPI_RST_USR | SPI_RST_CPU | SPI_CPU_HLT,SPI_RST_CPU | SPI_CPU_HLT);

	// The keyboard scan and Akiko requests wait for the end of the boot (as
	// with the legacy DisableInterrupts() here); the SD peripheral's
	// interrupt is needed during it.
	IrqDisable(IRQ_VBLANK);
	IrqDisable(IRQ_AKIKO);
	sdc_init();

	ClearError(ERROR_ALL);

    if (MMC_Init())
	{
	    if (FindDrive())
		{
			int key;
			int override=0;
		    ChangeDirectory(DIRECTORY_ROOT);

			config.kickstart.name[0]=0;
			SetConfigurationFilename(0); // Use default config
		    LoadConfiguration(0);	// Use slot-based config filename
			ApplyConfiguration(0,0);  // Setup screenmodes, etc before loading KickStart.

			fpga_init();	// Display splashscreen

			// Which function key is being HELD, not which one changed:
			// OsdGetCtrl now answers with queued events, and the press
			// that happened before the splash screen is not one.
			key = OsdGetKeyLevel();
			sprintf(s,"Got key: %X\n",key);
			BootPrint(s);
			if ((key == KEY_F1) || (key == KEY_F3))
			{
				override=1;
				config.chipset |= CONFIG_NTSC; // force NTSC mode if F1 or F3 pressed
			}

			if ((key == KEY_F2) || (key == KEY_F4))
			{
				override=1;
				config.chipset &= ~CONFIG_NTSC; // force PAL mode if F2 or F4 pressed
			}

			// FIXME - new interface for scandoubler?
			if ((key == KEY_F3) || (key == KEY_F4))
			{
				override=1;
				config.misc &= ~(1<<(PLATFORM_SCANDOUBLER));	// High byte of platform register
			}

			if ((key == KEY_F1) || (key == KEY_F2))
			{
				override=1;
				config.misc |= 1<<(PLATFORM_SCANDOUBLER);  // High byte of platform register
			}

			if(override)
			{
				BootPrintEx("Overriding screenmode.");
				ApplyConfiguration(0,0);
			}

			drivesounds_init("DRIVESNDBIN");
			ClearError(ERROR_FILESYSTEM); /* Don't report a missing drivesnd.bin */			

			BootPrintEx("Loading kickstart ROM...");
			result=ApplyConfiguration(1,1);

			// Only let the CPU go if there is actually a ROM for it to run.
			// Releasing it onto RAM that holds no valid Kickstart is what
			// produced the white/grey screen that came back on every reset:
			// the 68040 restarts, finds the same rubbish, and fails the same
			// way.  Held in reset instead, the machine stays quiet and the OSD
			// stays usable, so another Kickstart can be chosen -- which
			// re-runs ApplyConfiguration and releases the CPU properly.
			if(result)
				OsdDoReset(SPI_RST_USR | SPI_RST_CPU,0);
			else if(!ErrorMask)
				SetError(ERROR_ROM,"Kickstart ROM failed to load",0,0);

			audio_clear();
			if(drivesounds_loaded())
				drivesounds_enable(config.drivesounds);

		}
	}

	// One exit, always.  Whatever went wrong above -- no card, no filesystem,
	// no ROM -- the interrupt sources have to be enabled again to match the
	// IrqDisable()s on the way in.  Leaving them off was what turned "the
	// boot failed" into "the machine is wedged": the host CPU kept running
	// but without its timers, so nothing that depends on them (drive sounds,
	// the RTC, the HDMI re-init poll) worked again.
	IrqSetupSources();

	return(result);
}

// Sim-only STACKHW line for the L2 bench (make B=build_sr
// EXTRA_CFLAGS=-DRV_STACK_REPORT; the shipped image has no such code): once,
// at the 5th call.  Called from both main loops -- the bench card has no
// kickstart, so the firmware sits in the error loop below the main one.
// Counted, not timed: the bench's TIMER does not run at wall-clock speed.
#ifdef RV_STACK_REPORT
static void stackhw_poll(void)
{
	static unsigned int passes;
	if(passes < 6 && ++passes == 5)
	{
		printf("STACKHW ");
		printf("%X", StackHighWater());
		printf("\n");
	}
}
#else
#define stackhw_poll() ((void)0)
#endif

int main(void)
{
	int rtc;
	StackFill();
	debugmsg[0]=0;
	debugmsg2[0]=0;

    DISKLED_ON;

	if(PLATFORM & (1<<PLATFORM_SPIRTC))
	{
		printf("Platform has SPI RTC support\n");
#if 0
		SPI_slow();
		EnableRTC();
		SPI(0x10);	/* Write starting at register 0 */
		SPI(0);	/* Clear cr 1 */
		SPI(0); /* Clear cr 2 */
		DisableRTC();
#endif
		rtc=1;
	}
	else
	{
		printf("Platform lacks SPI RTC support\n");
		rtc=0;
	}

	if(!ColdBoot())
		BootPrintEx("ROM loading failed");

    adv_timer = GetTimer(250);
	unsigned char debug_was = 0;
	// disk statistics (diskstat.h): the first report period starts here
	diskstat_period_start();
	unsigned long diskstat_timer = GetTimer(DISKSTAT_PERIOD);
    while(1)
    {
		diskstat_loop_pass();
		stackhw_poll();
		if(DebugMode && !debug_was)
		{
			// (the existing "%X" format: a new format string needs a case in
			// test/gold/formats.txt and fmt_cases.h)
			printf("Stack high water ");
			printf("%X", StackHighWater());
			printf(", OSD RDY timeouts 0x");	// SPI_reply() waits that ran out (hardware.c)
			printf("%X", (unsigned int)osd_rdy_timeouts);
			printf("\n");
		}
		debug_was = DebugMode;
		// A disk report every DISKSTAT_PERIOD TIMER counts (5.804 s) when
		// dbg_flags has DBG_DISKSTAT (diskstat.h; off by default, set it over
		// the GDB tunnel).  It is about 300 UART bytes, and the CPU waits for
		// each: cfide has no TX FIFO, a write to UART_TX is not acked while
		// the previous byte shifts out (txbusy; 247 clk_28 per bit at 115200
		// baud, 10 bits = about 87 us per byte).  So one report stalls this
		// loop about 26 ms (0.45% of the period); the stall falls in the next
		// period (diskstat_report reads TIMER before printing).  Off, the
		// period starts over without the report.
		if(CheckTimer(diskstat_timer))
		{
			diskstat_timer = GetTimer(DISKSTAT_PERIOD);
			if (dbg_flags & DBG_DISKSTAT)
			{
				diskstat_report();
				sd_report();	// the SD errors per retry-table row (sdproto.h)
			}
			else
				diskstat_period_start();
		}
		drivesounds_fill();
		//if(c64keyboard_checkreset())
		//	OsdDoReset(SPI_RST_USR | SPI_RST_CPU,0);

		PollDisks(1);	// the card, the HDD data path, the CD refill, HandleFpga

		if(rtc)
			HandleRTC();

        HandleUI();
		// The HDMI transmitter forgets its configuration when the monitor goes
		// away: Hot Plug Detect low RESETS registers 0x00-0x93, 0x94-0x97,
		// 0xAF-0xCC and the whole packet memory (Programming Guide, Table 97).
		// So the picture cannot come back by itself -- something has to write
		// the configuration again once HPD is high, which until now was a
		// person pressing LSHIFT + keypad '.'.  adv7511_poll() does it.
		//
		// The first attempt at this (23:01) wedged the I2C bus and took the
		// manual re-init down with it: a read command needs its STOP to ride
		// on the command itself, and every wait here is now bounded.
		// INTERRUPT-DRIVEN, not polled (Paul, 2026-09-27): the part raises INT
		// on a hot-plug or monitor-sense change (the enables 0x94[7:6] survive
		// the HPD reset), the FPGA shows the pin in the I2C status register,
		// and only then does the firmware talk I2C to it -- read the status,
		// re-initialise on HPD high, clear the flags (which drops INT).  At
		// most every 250 ms while INT stays up; once at start-up.
		// On a RISING edge of INT only (2026-09-27): serviced on the level, a
		// pin that stays high -- the wrong polarity, or a flag that will not
		// clear -- had the firmware servicing the part every 250 ms, and the Amiga
		// crashed a few seconds after Workbench (no SD icon, disk block
		// errors: the firmware also serves the disks).  Edge-triggered, a stuck pin
		// costs one service.
		if (CheckTimer(adv_timer))
		{
			unsigned char lvl = adv7511_int_active() ? 1 : 0;
			adv_timer = GetTimer(250);
			adv_int_now = lvl;
			if (adv_first || (lvl && !adv_int_was))
			{
				adv_first = 0;
				adv_services++;
				adv7511_poll();
			}
			adv_int_was = lvl;
		}
		if(ErrorMask)
		{
			ShowError();
			while(ErrorMask)
			{
				// the disks and the music go on behind an error page
				// (the FPGA's requests only when the error is not fatal)
				PollDisks(!ErrorFatal);
		        HandleUI();
				stackhw_poll();
            }
		}
    }
}


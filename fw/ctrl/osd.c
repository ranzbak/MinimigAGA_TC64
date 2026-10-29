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

The OSD's control side: the core's configuration registers (Config*), the
resets, the keys (the core's key queue, the auto-repeat, Amiga raw key to
ASCII) and where the keyboard goes.  The picture is the 720p text layer's
(osd2.c); the bitmap OSD renderer that was here (OsdWrite, the title stripe,
the logo, stars and fireworks, the scroller) went with the bitmap OSD in
OSD redesign Phase 6 (last commit with it: osd-int bc677a44).

29-12-2006 - created
30-12-2006 - improved and simplified
-- JB --
2008-10-04 - ARM version
2008-10-26 - added cpu and floppy configuration functions
2008-12-31 - added enable HDD command
2009-02-03 - full keyboard support
2009-08-23 - adapted ConfigIDE() - support for 2 hardfiles
*/

#include "osd.h"
#include "fpga.h"
#include "hardware.h"
#include "stdio.h"

#include "audio.h"
#include "config.h"   // CONFIG_SCALING (ConfigVideo), videopos (ConfigVideoPos)
#include "osd2.h"     // osd2_caps (ConfigVideoPos)

#include "string.h"

// conversion table of Amiga keyboard scan codes to ASCII codes
const char keycode_table[128] =
{
      0,'1','2','3','4','5','6','7','8','9','0',  0,  0,  0,  0,  0,
    'Q','W','E','R','T','Y','U','I','O','P',  0,  0,  0,  0,  0,  0,
    'A','S','D','F','G','H','J','K','L',  0,  0,  0,  0,  0,  0,  0,
      0,'Z','X','C','V','B','N','M',  0,  0,  0,  0,  0,  0,  0,  0,
      0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
      0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
      0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
      0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0
};

// the keyboard (and joystick 2) back to the Amiga: OSD control (0x28)
// {K = 0}.  Bit 0 was the bitmap OSD's enable; it is gone (Phase 6), the
// firmware sends 0 there.
void OsdHide(void)
{
    EnableOsd();
    SPI(OSD_CMD_OSD);
    SPI(0x00);
    DisableOsd();
}


void OsdReset()
{
    EnableOsd();
    //SPI(OSDCMDRST | (boot & 0x01));
    SPI(OSD_CMD_RST);
    //SPI(0x2 | (boot & 0x01));
    SPI(0x1);
    DisableOsd();
    EnableOsd();
    SPI(OSD_CMD_RST);
    SPI(0x0);
    DisableOsd();
}


// The second data byte is the HDMI CRT emulation's {scaling, beam, bloom,
// mask} (rtl/minimig/userio_osd.v); a core without it ignores the byte, an
// older core the beam or scaling bits.  The core's scaling code: 0 line
// rate, 1 sharp, 2 area (0 = the picture of before, for older firmware);
// config.scanlines bits 5:4 hold SCALING_* (config.h), Sharp = 0.  Bits 5:2
// of the first byte were the Hires and Lores Filter (removed 2026-10-26,
// findings/osd-redesign/plan.md 3.13): always 0, so an older core keeps
// its filters off too.
void ConfigVideo(unsigned char scanlines, unsigned char crt_mask, unsigned char crt_bloom, unsigned char crt_beam)
{
    EnableOsd();
    SPI(OSD_CMD_VID);
    SPI(scanlines & 0x03);
    {
        unsigned char sc = CONFIG_SCALING(scanlines);
        unsigned char hw = (sc == SCALING_LINE) ? 0 : (sc == SCALING_AREA) ? 2 : 1;
        SPI((hw << 6) | ((crt_beam & 0x03) << 4) | ((crt_bloom & 0x03) << 2) | (crt_mask & 0x03));
    }
    DisableOsd();
}

// Both Video Pos pairs: the RTG screen's first (only on a core whose text
// layer says it has the register, osd2.h OSD2_V_STATUS), then the PAL/NTSC
// picture's.  An older core decodes every address of 0xFFFFFF5x as the PAL
// register, so the PAL pair is written last either way.
void ConfigVideoPos(void)
{
	EnableOsd();
	if (osd2_caps >= OSD2_V_STATUS)
		VIDEOSCALE_SET_RTG = (config.videopos_rtg.hpos + ((unsigned short)config.videopos_rtg.vpos << 8));
	VIDEOSCALE_SET_POS = (config.videopos.hpos + ((unsigned short)config.videopos.vpos << 8));
	DisableOsd();
}

void ConfigAudio(unsigned char volume)
{
  EnableOsd();
  audio_volume(volume);
  DisableOsd();
}

void ConfigMemory(unsigned char memory)
{
    EnableOsd();
    SPI(OSD_CMD_MEM);
    SPI(memory);
    DisableOsd();
}

void ConfigCPU(unsigned char cpu)
{
    EnableOsd();
    //SPI(OSDCMDCFGCPU | (cpu & 0x03));					//CPU
    SPI(OSD_CMD_CPU);
    SPI(cpu & 0x1f);    // [1:0] CPU, [3:2] Turbo, [4] Chip slots Fast (userio_osd.v)
    DisableOsd();
}

void ConfigChipset(unsigned char chipset)
{
    EnableOsd();
    //SPI(OSDCMDCFGCHP | (chipset & 0x0F));
    SPI(OSD_CMD_CHIP);
    SPI(chipset & 0x1f);
    DisableOsd();
}

void ConfigFloppy(unsigned char drives, unsigned char speed)
{
    EnableOsd();
    //SPI(OSDCMDCFGFLP | ((drives & 0x03) << 2) | (speed & 0x03));
    SPI(OSD_CMD_FLP);
    SPI(((drives & 0x03) << 2) | (speed & 0x03));
    DisableOsd();
}

// One IDE port's configuration, applied by the core at the next reset:
// {slave ATAPI, master ATAPI, slave present, master present, port on}.
// Port 1 (0) is OSD_CMD_HDD, port 2 (1) OSD_CMD_HDD1.
void ConfigIDE(unsigned char port, unsigned char on, unsigned char master, unsigned char slave, unsigned char atapi)
{
    EnableOsd();
    //SPI(OSDCMDCFGIDE | (slave ? 4 : 0) | (master ? 2 : 0) | (gayle ? 1 : 0));
    SPI(port ? OSD_CMD_HDD1 : OSD_CMD_HDD);
    SPI(((atapi & 3) << 3) | (slave ? 4 : 0) | (master ? 2 : 0) | (on ? 1 : 0));
    DisableOsd();
}


void ConfigAutofire(unsigned char autofire)
{
    EnableOsd();
    //SPI(OSDCMDAUTOFIRE | (autofire & 0x03));
    SPI(OSD_CMD_JOY);
    // Three bits, not two: userio_osd.v takes wrdat[2:0] as {cd32pad,
    // autofire_config}.  Masking with 0x03 dropped the CD32 pad bit on the way
    // out, so that menu item wrote config, redrew itself, and changed nothing
    // in the core.
    SPI(autofire & 0x07);
    DisableOsd();
}


unsigned char osd_keyq_lost = 0;

// Events the core has handed over but HandleUI has not been given yet.  It
// acts on one event per call, so they go out one at a time.  Fifteen is what
// the core's queue holds, so one drain can never overrun this.
static unsigned char kq_buf[15];
static unsigned char kq_head = 0;
static unsigned char kq_tail = 0;

// The key the core is holding right now.  A level, not an event.
unsigned char OsdGetKeyLevel(void)
{
    unsigned char c;
    EnableOsd();
    c = SPI(OSD_CMD_READ);
    DisableOsd();
    return c;
}

// The next key EVENT, or 0 if none is waiting.
//
// OSD_CMD_READ answers a level, so this used to be "the level changed since
// the last poll" -- and a key that went down and up between two polls was
// never seen at all.  A missed key-UP is the expensive one: HandleUI keeps
// ctrl/lalt/lshift in statics, and a modifier stuck down makes F12 toggle
// debug mode instead of opening the OSD, permanently, while every other key
// still works because those reach the Amiga by another path.  The core now
// queues every change; `level' is only the fallback for a core that has no
// queue, where the old behaviour is all there is.
static unsigned char OsdNextEvent(unsigned char level)
{
    static unsigned char prev = 0;
    unsigned char i, n, st;

    if (!(core_caps & CORE_CAPS_KEYQ))
    {
        unsigned char c = (level != prev) ? level : 0;
        prev = level;
        return c;
    }

    if (kq_head == kq_tail)
    {
        kq_head = 0;
        kq_tail = 0;
        EnableOsd();
        SPI(OSD_CMD_KEYQ);
        st = SPI_reply();           // {overflow, 0, 0, 0, count[3:0]}
        n = st & 0x0f;
        for (i = 0; i < n; i++)
            kq_buf[i] = SPI_reply();
        DisableOsd();
        kq_tail = n;
        if (st & 0x80)
            osd_keyq_lost = 1;      // events were dropped, see HandleUI
    }

    return (kq_head != kq_tail) ? kq_buf[kq_head++] : 0;
}

// get key status
unsigned char OsdGetCtrl(void)
{
    static unsigned long delay=0;
    static unsigned long repeat=0;
    static unsigned char repeat2=0;
    unsigned char c1,c;

    // send command and get current ctrl status
    c1 = OsdGetKeyLevel();

    c = OsdNextEvent(c1);

    // add front menu button
    if (!CheckButton())
        delay = GetTimer(BUTTONDELAY);
    else if (CheckTimer(delay))
    {
        c1 = KEY_MENU;
        c  = KEY_MENU;
        delay = GetTimer(-1);
    }

    // generate repeat "key-pressed" events.  This asks whether a key is HELD,
    // which is what the level is for, so it keeps reading c1.  It only fills
    // in when there is no real event to deliver: with a queue there can be one
    // waiting, and overwriting it here would drop it.
    if (c1 & KEY_UPSTROKE)
    {
        repeat = GetTimer(REPEATDELAY);
    }
    else if (CheckTimer(repeat))
    {
        repeat = GetTimer(REPEATRATE);
        if (!c && (c1 == KEY_UP || c1 == KEY_DOWN))
           c = c1;
        repeat2++;
        if (repeat2 == 2)
        {
            repeat2 = 0;
            if (!c && (c1 == KEY_PGUP || c1 == KEY_PGDN || GetASCIIKey(c1)))
                c = c1;
        }
    }

    return(c);
}


unsigned char GetASCIIKey(unsigned char keycode)
{
    if (keycode & KEY_UPSTROKE)
       return 0;

    return keycode_table[keycode & 0x7F];
}


void OsdDoReset(int enter,int leave)
{
    EnableOsd();
    SPI(OSD_CMD_RST);
    SPI(enter);
    DisableOsd();
    EnableOsd();
    SPI(OSD_CMD_RST);
    SPI(leave);
    DisableOsd();
}



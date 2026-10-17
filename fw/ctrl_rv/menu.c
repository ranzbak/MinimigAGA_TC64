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

// 2009-11-14   - OSD labels changed
// 2009-12-15   - added display of directory name extensions
// 2010-01-09   - support for variable number of tracks

// #include "AT91SAM7S256.h"
// #include "stdbool.h"
#include "stdio.h"
#include "string.h"
#include "errors.h"
#include "mmc.h"
#include "fat.h"
#include "osd.h"
#include "fpga.h"
#include "fdd.h"
#include "hdd.h"
#include "hardware.h"
#include "firmware.h"
#include "config.h"
#include "menu.h"
#include "hexdump.h"
#include "drivesounds.h"
#include "adv7511.h"
#include "i2c.h"
#include "cdrom.h"

#define OSDCOLOR_TOPLEVEL 0x01
#define OSDCOLOR_SUBMENU 0x03
#define OSDCOLOR_WARNING 0x10

// other constants
#define DIRSIZE 8 // number of items in directory display window

signed char errorpage;
unsigned char menustate = MENU_NONE1;
unsigned char parentstate;
unsigned char parentsub;
unsigned char menusub = 0;
unsigned int menumask = 0; // Used to determine which rows are selectable...
unsigned long menu_timer;

extern unsigned char drives;
extern adfTYPE df[4];

extern configTYPE config;
extern fileTYPE file;
extern char s[40];

extern unsigned char fat32;

extern DIRENTRY DirEntry[MAXDIRENTRIES];
extern unsigned char sort_table[MAXDIRENTRIES];
extern unsigned char nDirEntries;
extern unsigned char iSelectedEntry;
extern unsigned long iCurrentDirectory;
extern char DirEntryLFN[MAXDIRENTRIES][261];
char DirEntryInfo[MAXDIRENTRIES][5]; // disk number info of dir entries
char DiskInfo[5];                    // disk number info of selected entry

extern const char version[];

const char *config_filter_msg[] = {"none", "HORIZONTAL", "VERTICAL", "H+V"};
const char *config_memory_chip_msg[] = {"0.5 MB", "1.0 MB", "1.5 MB", "2.0 MB"};
const char *config_memory_slow_msg[] = {"none  ", "0.5 MB", "1.0 MB", "1.5 MB"};
const char *config_on_off_msg[] = {"off", "on "};
const char *config_scanlines_msg[] = {"off", "dim", "black"};
const char *config_scaling_msg[] = {"sharp", "area", "line rate", "sharp"};   // SCALING_*
const char *config_crt_mask_msg[] = {"off", "grille", "grille+", "shadow"};
const char *config_crt_bloom_msg[] = {"off", "low", "high"};
const char *config_crt_beam_msg[] = {"off", "sharp", "medium", "soft"};
const char *config_memory_fast_msg[] = {"none  ", "2.0 MB", "4.0 MB", "Maximum"};
const char *config_cpu_msg[] = {"68000 ", "68010", "-", "020 alpha"};
const char *config_hdf_msg[] = {"Disabled", "Hardfile (disk img)", "MMC/SD card", "MMC/SD partition 1", "MMC/SD partition 2", "MMC/SD partition 3", "MMC/SD partition 4", "CD-ROM (ISO)"};
const char *config_chipset_msg[] = {"OCS-A500", "OCS-A1000", "ECS", "---", "---", "---", "AGA", "---"};
const char *config_turbo_msg[] = {"none", "CHIPRAM", "KICK", "BOTH"};
// Chip slots, config.cpu bit 4 (CONFIG_CPU_FASTCHIP): how the CPU's chipset
// cycles fit the chip bus when Turbo CHIPRAM is off.  Standard is the 7 MHz
// machine as it always was; Fast ends each cycle with its chip slot, so the
// CPU can take the authentic AGA rate of one chip cycle in two CCKs.  DMA
// keeps every slot it had in both.  Old configs have the bit clear: Standard.
const char *config_chipslots_msg[] = {"Standard", "Fast"};
const char *config_cd32pad_msg[] = {"OFF", "ON"};
const char *config_volume_msg[] = {" ", " 1", " 2", " 3", " 4", " 5", " 6", " 7", " 8", " 9", "10", "11", "12", "13", "14", "15", "16", "17", "18", "19", "20", "21", "22", "23", "24", "25", "26", "27", "28", "29", "30", "31"};
const char *config_hdmi_clkdelay_msg[] = {"-1.2", "-0.8", "-0.4", " 0.0", "+0.4", "+0.8", "+1.2", "+1.6"};

char *config_autofire_msg[] = {"        AUTOFIRE OFF", "        AUTOFIRE FAST", "        AUTOFIRE MEDIUM", "        AUTOFIRE SLOW"};

enum HelpText_Message
{
    HELPTEXT_NONE,
    HELPTEXT_MAIN,
    HELPTEXT_HARDFILE,
    HELPTEXT_CHIPSET,
    HELPTEXT_MEMORY,
    HELPTEXT_VIDEO,
    HELPTEXT_HDMI,
    HELPTEXT_CDROM
};
const char *helptexts[] = {
    0,
    "                                Welcome to Minimig!  Use the cursor keys to navigate the menus.  Use space bar or enter to select an item.  Press Esc or F12 to exit the menus.  Mouse emulation on the numeric keypad can be toggled with the numlock key, while pressing Ctrl-Alt-0 (numeric keypad) toggles autofire mode.",
    "                                Minimig can emulate an A600 IDE harddisk interface.  The emulation can make use of Minimig-style hardfiles (complete disk images) or UAE-style hardfiles (filesystem images with no partition table).  It is also possible to use either the entire SD card or an individual partition as an emulated harddisk.",
    "                                Minimig's processor core can emulate a 68000 or 68020 processor.  Access to both Chip RAM and Kickstart ROM can be sped up with the Turbo function.  Chip slots Fast lets the CPU use every chip bus slot an AGA machine gives it (one in two colour clocks) without touching DMA timing; Turbo CHIPRAM bypasses the chip bus altogether.  The emulated chipset can be either A500 or A1000 OCS, ECS or AGA.",
#ifdef ACTIONREPLAY_BROKEN
    "                                Minimig can make use of up to 2 megabytes of Chip RAM, up to 1.5 megabytes of Slow RAM (A500 Trapdoor RAM), and up to 28 megabytes of true Fast RAM.",
#else
    "                                Minimig can make use of up to 2 megabytes of Chip RAM, up to 1.5 megabytes of Slow RAM (A500 Trapdoor RAM), and up to 28 megabytes of true Fast RAM.  To use the HRTMon feature you will need an appropriate ROM file on the SD card.  To activate the monitor hold Ctrl and press the Pause key.",
#endif
    "                                Minimig's video features include a blur filter, to simulate the poorer picture quality on older monitors, and also scanline generation to simulate the appearance of a screen with low vertical resolution.  On HDMI, CRT Mask adds a phosphor mask (grille: red, green and blue stripes; shadow: magenta and green) and Bloom lets bright pixels fill their scanline gaps; bloom needs scanlines or a vertical filter.  Beam width gives each pixel the soft spot of a CRT's beam, so dithered patterns blend as on a monitor; with it on, Bloom also widens the spot of bright pixels.  Video Pos moves the HDMI picture: Hpos in HD pixels (+ right), Vpos in Amiga lines (+ down).  Scaling (HDMI): Sharp and Area scale the picture exactly 2.5 times (PAL) or 3 times (NTSC) vertically, every line the same height; Sharp keeps edges crisp, Area is the most even.  Line rate is the older, slightly smaller picture.  Sharp and Area need the 15 kHz picture: the core turns the scandoubler off for them.",
    "                                The clock delay sets where the HDMI transmitter samples each pixel.  Too early or too late shows as sparkling colours, light yellows first.  Step through the values, note where the picture is clean, and settle in the middle of that range.  Save the configuration to keep it.",
    "                                CD-ROM drive.  Insert an ISO image or a CUE sheet (BIN, or ISO + WAV tracks) from the SD card.  On IDE port 2 the Amiga needs AtapiMagic (3.1.4/3.2) or IDEfix97 (3.1).  The Amiga cannot boot from it.",
    0};

void SanityCheck();

void ColdBoot();
void (*confirmfunc)();

extern unsigned char DEBUG;

// (config_autofire used to live here: a second, private copy of the autofire
// rate that only the Ctrl-Alt-KP0 shortcut wrote.  config.autofire is the one
// that is saved and shown, so the shortcut uses that now.)

// file selection menu variables
char *fs_pFileExt = NULL;
unsigned char fs_Options;
unsigned char fs_MenuSelect;
unsigned char fs_MenuCancel;

static char debuglines[8 * 32 + 1];
static char debugptr = 0;

void _showdebugmessages()
{
    int i;
    for (i = 0; i < 8; ++i)
    {
        int j = (debugptr + i) & 7;
        debuglines[j * 32 + 31] = 0;
        OsdWrite(i, &debuglines[j * 32], i == 7, 0);
    }
}

void SelectFile(char *pFileExt, unsigned char Options, unsigned char MenuSelect, unsigned char MenuCancel)
{
    // this function displays file selection menu

    if (!fs_pFileExt || strcmp(pFileExt, fs_pFileExt) != 0) // check desired file extension(s)
    {                                           // if different from the current one go to the root directory and init entry buffer
        ChangeDirectory(DIRECTORY_ROOT);
        ScanDirectory(SCAN_INIT, pFileExt, Options);
    }

    fs_pFileExt = pFileExt;
    fs_Options = Options;
    fs_MenuSelect = MenuSelect;
    fs_MenuCancel = MenuCancel;

    menustate = MENU_FILE_SELECT1;
}

void VolumeBar(unsigned char vol, char *bar)
{
    for (int i = 0; i < 32; i++)
    {
        if (i < config.audio.volume)
        {
            bar[i >> 1] = '#';
        }
        else
        {
            bar[i >> 1] = ' ';
        }
    }
    bar[16] = '\0';
}

#define STD_EXIT "            exit"
#define STD_BACK "            back"
#define HELPTEXT_DELAY 2500
#define FRAME_DELAY 50

void ShowSplash()
{
    OsdSetTitle("Welcome", 0);
    OsdWrite(0, "", 0, 0);
    OsdDrawLogo(1, 0, 0);
    OsdDrawLogo(2, 1, 0);
    OsdDrawLogo(3, 2, 0);
    OsdDrawLogo(4, 3, 0);
    OsdDrawLogo(5, 4, 0);
    OsdWrite(6, "", 0, 0);
    OsdWrite(7, "", 0, 0);
    OsdShow(0);
    OsdColor(OSDCOLOR_TOPLEVEL);
}

void HideSplash()
{
    OsdHide();
}

/******************************************************************/
/* IDE slots on the Harddisks pages (findings/cdrom/plan.md 5)      */
/******************************************************************/

// The four IDE slots as edited on the Harddisks pages (slot = port << 1 |
// slave), applied on leaving them.  A disc change in the live CD drive is
// applied at once (no reset) and copied here.
static hardfileTYPE t_hardfile[HDD_SLOTS];
static unsigned long t_hdfdir[HDD_SLOTS];
static int hdf_select_slot;	// the slot whose file selector is open

// A message in place of a CD line, for 4 s: "locked by the Amiga" (D5),
// or why an insert was refused (13.1: the cause, at most 23 characters).
#define CD_MSG_DELAY 4000
static unsigned long cd_msg_timer;
static char cd_msg_on;
static const char *cd_msg_text;
static int cd_shown_track;	// the track in the main page's play mark, 0 = none

static void cd_show_msg(const char *text)
{
    cd_msg_text = text;
    cd_msg_on = 1;
    cd_msg_timer = GetTimer(CD_MSG_DELAY);
}

static void cd_locked_msg(void)
{
    cd_show_msg("locked by the Amiga");
}

// The OSD's answer to CD_Insert: nothing when the disc went in.
static void cd_insert_msg(int r)
{
    if (r == CD_LOCKED)
        cd_locked_msg();
    else if (r == CD_BADCUE)
        cd_show_msg(CD_Message());
    else if (r == CD_NOFILE)
        cd_show_msg("file not found");
}

// The message is over: redraw.
static int cd_msg_expired(void)
{
    if (cd_msg_on && CheckTimer(cd_msg_timer))
    {
        cd_msg_on = 0;
        return 1;
    }
    return 0;
}

static const char *hdf_type_name(unsigned char enabled)
{
    if (enabled == (HDF_FILE | HDF_SYNTHRDB))
        return "Hardfile (filesys)";
    if ((enabled & HDF_TYPEMASK) > HDF_CDROM)
        return "---";
    return config_hdf_msg[enabled & HDF_TYPEMASK];
}

// The type cycle: Disabled, Hardfile (disk img), Hardfile (filesys), MMC/SD
// card, its partitions, CD-ROM (ISO), Disabled.  CD-ROM only on a core with
// two IDE ports, and not while another slot is the CD drive (one drive, D3).
static void hdf_next_type(int slot)
{
    hardfileTYPE *t = &t_hardfile[slot];
    unsigned char e = t->enabled;
    int i, cd_elsewhere = 0;
    for (i = 0; i < HDD_SLOTS; i++)
        if (i != slot && t_hardfile[i].enabled == HDF_CDROM)
            cd_elsewhere = 1;
    if (e == HDF_FILE)
        e = HDF_FILE | HDF_SYNTHRDB;
    else if (e == (HDF_FILE | HDF_SYNTHRDB))
        e = HDF_CARD;
    else if (e == HDF_CDROM)
        e = HDF_DISABLED;
    else
    {
        e += 1;
        if (e >= HDF_CARDPART0 + partitioncount)
            e = (!cd_elsewhere && (core_caps & CORE_CAPS_IDE2)) ? HDF_CDROM : HDF_DISABLED;
    }
    if (e == HDF_CDROM)
    {   // a CD slot starts empty: an HDF name is not a disc
        memset(t->name, 0, sizeof(t->name));
        memset(t->long_name, 0, sizeof(t->long_name));
        t->present = 0;
    }
    t->enabled = e;
}

// The CD slot is the live drive: same slot, same type as in use.
static int cd_live(int slot)
{
    return slot == CD_SLOT() && SlotConfig(slot)->enabled == HDF_CDROM && t_hardfile[slot].enabled == HDF_CDROM;
}

// A slot's two lines: its type at row, its file at row + 1 (menusub ==
// row on both pages).  Returns their menumask bits.
static unsigned char hdf_slot_lines(int slot, int row, const char *label, char ide_on)
{
    hardfileTYPE *t = &t_hardfile[slot];
    unsigned char mask = 0;
    char enable;

    strcpy(s, label);
    strcat(s, hdf_type_name(t->enabled));
    OsdWrite(row, s, ide_on ? (menusub == row) : 0, ide_on == 0);
    if (ide_on)
        mask |= 1 << row;

    if (t->enabled == HDF_CDROM && cd_msg_on && cd_live(slot))
    {
        strcpy(s, "       ");
        strcat(s, cd_msg_text);
    }
    else if (t->enabled == HDF_CDROM && !t->name[0])
        strcpy(s, "              * no disc *");
    else if (t->present)
    {
        strcpy(s, "                                ");
        if (t->long_name[0])
            strncpy(&s[14], t->long_name, sizeof(t->long_name));
        else
            strncpy(&s[14], t->name, sizeof(t->name));
    }
    else
        strcpy(s, "       ** file not found **");

    enable = ide_on && ((t->enabled & HDF_TYPEMASK) == HDF_FILE || t->enabled == HDF_CDROM);
    if (enable)
        mask |= 1 << (row + 1);
    OsdWrite(row + 1, s, enable ? (menusub == row + 1) : 0, enable == 0);
    return mask;
}

static unsigned char hdf_page(int slot)
{
    return slot < 2 ? MENU_SETTINGS_HARDFILE1 : MENU_SETTINGS_HARDFILE3;
}

static void hdf_select(int slot)
{
    hdf_select_slot = slot;
    SelectFile(t_hardfile[slot].enabled == HDF_CDROM ? "ISOCUE" : "HDF", SCAN_DIR | SCAN_LFN, MENU_HARDFILE_SELECTED, hdf_page(slot));
}

// The help text for a Harddisks page: the CD's when the cursor is on a CD slot.
static const char *hdf_help(int slot)
{
    return (slot >= 0 && t_hardfile[slot].enabled == HDF_CDROM) ? helptexts[HELPTEXT_CDROM] : helptexts[HELPTEXT_HARDFILE];
}

// Does leaving the Harddisks pages need a reset?  A changed slot type or
// hardfile does (the Amiga must probe the bus again); a new disc in a CD
// slot does not -- it is a media change, applied at once in the live
// drive, and only remembered for a CD slot that is not live yet.
static int hdf_needs_reset(char ide_on)
{
    int slot;
    if (ide_on != config.enable_ide)
        return 1;
    for (slot = 0; slot < HDD_SLOTS; slot++)
    {
        hardfileTYPE *c = SlotConfig(slot);
        if (t_hardfile[slot].enabled != c->enabled)
            return 1;
        if (c->enabled != HDF_CDROM && memcmp(c, &t_hardfile[slot], sizeof(*c)) != 0)
            return 1;
    }
    return 0;
}

void HandleUI(void)
{
    unsigned char i, c, up, down, select, menu, right, left, plus, minus;
    unsigned long len;
    static char t_enable_ide; // temporary copy of former enable_ide flag.
    // Memory menu: config.memory as it was when the menu was entered, so that
    // leaving it after a change can offer the reset the change needs (the
    // memory map and autoconfig only change at the next reset).
    static unsigned char t_memory;
    static char t_memory_valid = 0;
    static unsigned char t_memory_next, t_memory_nextsub; // where the user was going
    static unsigned char ctrl = false;
    static unsigned char lalt = false;
    static unsigned char lshift = false;
    char enable;
    static long helptext_timer;
    static const char *helptext;
    static char helpstate = 0;
    char volume_bar[17];

    // get user control codes
    c = OsdGetCtrl();

    // The core's key queue overflowed, so an event was dropped.  The flag is
    // cleared and otherwise ignored.
    //
    // This used to clear ctrl/lalt/lshift on the theory that a dropped key-up
    // could leave a modifier stuck.  That cost far more than it bought: it
    // wipes modifiers the user is still HOLDING, and InfoMessage is slow
    // enough (OsdWaitVBL plus eight OSD line writes over SPI) that events pile
    // up behind it.  The visible result was that LSHIFT + keypad +/- changed
    // the volume exactly once and then did nothing until shift was released
    // and pressed again.
    //
    // A stuck modifier is what the QUEUE itself fixes, by delivering key-ups
    // reliably; blanking state on overflow was a second line of defence for a
    // rare case, breaking a common one.  If a stuck modifier is ever seen
    // again, the answer is a deeper queue so overflow cannot happen, not
    // throwing away state we were told correctly.
    if (osd_keyq_lost)
        osd_keyq_lost = 0;

    // decode and set events
    menu = false;
    select = false;
    up = false;
    down = false;
    left = false;
    right = false;
    plus = false;
    minus = false;

    switch (c)
    {
    case KEY_CTRL:
        ctrl = true;
        break;
    case KEY_CTRL | KEY_UPSTROKE:
        ctrl = false;
        break;
    case KEY_LALT:
        lalt = true;
        break;
    case KEY_LALT | KEY_UPSTROKE:
        lalt = false;
        break;
    case KEY_LSHIFT:
        lshift = true;
        break;
    case KEY_LSHIFT | KEY_UPSTROKE:
        lshift = false;
        break;
    case KEY_KPPLUS:
        if (ctrl && lalt)
        {
            config.chipset |= CONFIG_TURBO;
            ConfigChipset(config.chipset);
            if (menustate == MENU_SETTINGS_CHIPSET2)
                menustate = MENU_SETTINGS_CHIPSET1;
            else if (menustate == MENU_NONE2 || menustate == MENU_INFO)
                InfoMessage("             TURBO");
        }
        else if (lshift) // volume up
        {
            if (config.audio.volume != 31)
            {
                config.audio.volume++;
                ConfigAudio(config.audio.volume);
            }
            if (menustate == MENU_NONE2 || menustate == MENU_INFO)
            {
                strcpy(s, "vol: ");
                strcat(s, config_volume_msg[config.audio.volume]);
                strcat(s, " ");
                VolumeBar(config.audio.volume, volume_bar);
                strcat(s, volume_bar);
                InfoMessage(s);
            }
        }
        else
            plus = true;
        break;
    case KEY_KPMINUS:
        if (ctrl && lalt)
        {
            config.chipset &= ~CONFIG_TURBO;
            ConfigChipset(config.chipset);
            if (menustate == MENU_SETTINGS_CHIPSET2)
                menustate = MENU_SETTINGS_CHIPSET1;
            else if (menustate == MENU_NONE2 || menustate == MENU_INFO)
                InfoMessage("             NORMAL");
        }
        else if (lshift) // Volume down
        {
            if (config.audio.volume != 0)
            {
                config.audio.volume--;
                ConfigAudio(config.audio.volume);
            }
            if (menustate == MENU_NONE2 || menustate == MENU_INFO)
            {
                strcpy(s, "vol: ");
                strcat(s, config_volume_msg[config.audio.volume]);
                strcat(s, " ");
                VolumeBar(config.audio.volume, volume_bar);
                strcat(s, volume_bar);
                InfoMessage(s);
            }
        }
        else
            minus = true;
        break;
    case KEY_KPDOT:
        if (lshift) // Refresh ADV7511 configuration
        {
            // Works from ANY menu state.  It used to be allowed only with no
            // menu open (or a notification showing), which made it useless in
            // precisely the situation where it is wanted -- looking at the
            // HDMI status page and needing to kick the transmitter.  LSHIFT +
            // keypad '.' is not a chord any menu uses for navigation.
            //
            // The notification is only raised when there is no menu in the
            // way; drawing one over a menu would corrupt what the menu had
            // already written, and it also used to re-arm its own dismiss
            // timer on every press.
            if (menustate == MENU_NONE2 || menustate == MENU_INFO)
                InfoMessage("Refreshing ADV7511 config");
            // free the bus first: a slave stuck mid-byte would swallow the
            // whole init sequence (the display that stayed dark overnight)
            i2c_bus_recover();
            adv7511_init();
        }
        break;
    case KEY_KP0:
        if (ctrl && lalt)
        {
            if (menustate == MENU_NONE2 || menustate == MENU_INFO)
            {
                // config.autofire, not the private config_autofire this used
                // to keep: that second copy meant the shortcut and the menu
                // disagreed about the current rate, the shortcut's setting was
                // never saved, and -- because it sent a two-bit value -- using
                // it switched the CD32 pad off in the core as a side effect.
                // Bits 1:0 are the rate; bit 2 is the CD32 pad and is preserved.
                config.autofire = (config.autofire & 0x04)
                                | ((config.autofire + 1) & 0x03);
                ConfigAutofire(config.autofire);
                if (menustate == MENU_NONE2 || menustate == MENU_INFO)
                    InfoMessage(config_autofire_msg[config.autofire & 0x03]);
            }
        }
        break;
    case KEY_MENU:
        if (ctrl && lalt)
        {
            OsdSetTitle("Debug", 0);
            DebugMode = DebugMode ^ 1;
            if (DebugMode)
                SanityCheck();
            menustate = MENU_NONE1;
        }
        else
            menu = true;
        break;
    case KEY_ESC:
        if (menustate != MENU_NONE2)
            menu = true;
        break;
    case KEY_ENTER:
    case KEY_SPACE:
        select = true;
        break;
    case KEY_UP:
        up = true;
        break;
    case KEY_DOWN:
        down = true;
        break;
    case KEY_LEFT:
        left = true;
        break;
    case KEY_RIGHT:
        right = true;
        break;
    }

    if (menu || select || up || down || left || right)
    {
        if (helpstate)
            OsdWrite(7, STD_EXIT, (menumask - ((1 << (menusub + 1)) - 1)) <= 0, 0); // Redraw the Exit line...
        helpstate = 0;
        helptext_timer = GetTimer(HELPTEXT_DELAY);
    }

    if (helptext)
    {
        if (helpstate < 9)
        {
            if (CheckTimer(helptext_timer))
            {
                helptext_timer = GetTimer(FRAME_DELAY);
                OsdWriteOffset(7, STD_EXIT, 0, 0, helpstate);
                ++helpstate;
            }
        }
        else if (helpstate == 9)
        {
            ScrollReset();
            ++helpstate;
        }
        else
            ScrollText(7, helptext, 0, 0, 0);
    }

    // Standardised menu up/down.
    // The screen should set menumask, bit 0 to make the top line selectable, bit 1 for the 2nd line, etc.
    // (Lines in this context don't have to correspond to rows on the OSD.)
    // Also set parentstate to the appropriate menustate.
    if (menumask)
    {
        if (down && (menumask >= (1 << (menusub + 1)))) // Any active entries left?
        {
            do
                menusub++;
            while ((menumask & (1 << menusub)) == 0);
            menustate = parentstate;
        }

        // ...mmmm.
        // ......X.

        if (up && (menusub > 0) && (menumask & (0xff >> (8 - menusub))))
        {
            do
                --menusub;
            while ((menumask & (1 << menusub)) == 0);
            menustate = parentstate;
        }
    }

    switch (menustate)
    {
        /******************************************************************/
        /* no menu selected                                               */
        /******************************************************************/
    case MENU_NONE1:
        helptext = helptexts[HELPTEXT_NONE];
        menumask = 0;
        t_memory_valid = 0;     // the OSD closed: the next Memory menu visit starts afresh
        if (DebugMode)
        {
            helptext = helptexts[HELPTEXT_NONE];
            OsdShow(0);
        }
        else
            OsdHide();
        menustate = MENU_NONE2;
        break;

    case MENU_NONE2:
        if (DebugMode)
            _showdebugmessages();
        if (menu)
        {
            menustate = MENU_MAIN1;
            menusub = 0;
            OsdClear();
            OsdShow(DISABLE_KEYBOARD);
        }
        break;

        /******************************************************************/
        /* main menu                                                      */
        /******************************************************************/
    case MENU_MAIN1:
        OsdColor(OSDCOLOR_TOPLEVEL);
        menumask = 0xb0; // b10110000 Floppy turbo, Harddisk options & Exit; the CD-ROM line below.
        OsdSetTitle("Minimig", OSD_ARROW_RIGHT);
        helptext = helptexts[menusub == 6 ? HELPTEXT_CDROM : HELPTEXT_MAIN];

        // floppy drive info
        // We display a line for each drive that's active
        // in the config file, but grey out any that the FPGA doesn't think are active.
        // We also print a help text in place of the last drive if it's inactive.
        for (i = 0; i < 4; i++)
        {
            if (i == config.floppy.drives + 1)
                OsdWrite(i, " KP +/- to add/remove drives", 0, 1);
            else
            {
                strcpy(s, " dfx: ");
                s[3] = i + '0';
                if (i <= drives)
                {
                    menumask |= (1 << i); // Make enabled drives selectable

                    if (df[i].status & DSK_INSERTED) // floppy disk is inserted
                    {
                        strncpy(&s[6], df[i].name, sizeof(df[0].name));
                        if (!(df[i].status & DSK_WRITABLE))
                            strcpy(&s[6 + sizeof(df[i].name) - 1], " \x17"); // padlock icon for write-protected disks
                        else
                            strcpy(&s[6 + sizeof(df[i].name) - 1], "  "); // clear padlock icon for write-enabled disks
                    }
                    else // no floppy disk
                    {
                        strcat(s, "* no disk *");
                    }
                }
                else if (i <= config.floppy.drives)
                {
                    strcat(s, "* active after reset *");
                }
                else
                    strcpy(s, "");
                OsdWrite(i, s, menusub == i, (i > drives) || (i > config.floppy.drives));
            }
        }
        OsdWrite(4, " Floppy disk settings \x16", menusub == 4, 0);
        OsdWrite(5, " Hard disk settings \x16", menusub == 5, 0);
        // The CD-ROM drive (5.2): insert, eject, or why not.
        if (CD_SLOT() < 0)
            OsdWrite(6, " CD-ROM: not configured", 0, 1);
        else
        {
            menumask |= 0x40;
            cd_shown_track = CD_PlayingTrack();
            if (cd_msg_on)
                sprintf(s, " CD-ROM: %s", cd_msg_text);
            else if (!cdrom.unit.media)
                strcpy(s, " CD-ROM: * no disc *");
            else
            {   // the name, the play mark (note + track) at columns 27-29, the
                // lock mark at column 31.  strncat: lib832's printf has no
                // precision (it printed "21s" here).
                char locked = CD_Locked();
                strcpy(s, " CD-ROM: ");
                strncat(s, cdrom.unit.name, cd_shown_track ? 17 : 21);
                if (cd_shown_track || locked)
                {
                    len = strlen(s);
                    while (len < 31)
                        s[len++] = ' ';
                    s[31] = locked ? 0x17 : ' ';
                    s[32] = 0;
                }
                if (cd_shown_track)
                {
                    s[27] = 0x19; // note (charrom.h)
                    s[28] = (char)('0' + cd_shown_track / 10);
                    s[29] = (char)('0' + cd_shown_track % 10);
                }
            }
            OsdWrite(6, s, menusub == 6, 0);
        }
        OsdWrite(7, STD_EXIT, menusub == 7, 0);

        menustate = MENU_MAIN2;
        parentstate = MENU_MAIN1;
        break;

    case MENU_MAIN2:
        if (cd_msg_expired() || (CD_SLOT() >= 0 && CD_PlayingTrack() != cd_shown_track))
            menustate = MENU_MAIN1; // a message ended, or the play mark changed
        if (menu)
            menustate = MENU_NONE1;
        else if (plus && (config.floppy.drives < 3))
        {
            config.floppy.drives++;
            ConfigFloppy(config.floppy.drives, config.floppy.speed);
            menustate = MENU_MAIN1;
        }
        else if (minus && (config.floppy.drives > 0))
        {
            config.floppy.drives--;
            ConfigFloppy(config.floppy.drives, config.floppy.speed);
            menustate = MENU_MAIN1;
        }
        else if (select)
        {
            if (menusub < 4)
            {
                if (df[menusub].status & DSK_INSERTED) // eject selected floppy
                {
                    df[menusub].status = 0;
                    menustate = MENU_MAIN1;
                    drivesounds_queueevent(DRIVESOUND_EJECT);
                }
                else
                {
                    df[menusub].status = 0;
                    SelectFile("ADF", SCAN_DIR | SCAN_LFN, MENU_FILE_SELECTED, MENU_MAIN1);
                }
            }
            else if (menusub == 4) // Floppy disk options.
            {
                menustate = MENU_FLOPPY1;
                parentsub = 4;
                menusub = 0;
            }
            else if (menusub == 5) // Go to harddrives page.
            {
                for (i = 0; i < HDD_SLOTS; i++)
                {
                    t_hardfile[i] = *SlotConfig(i);
                    t_hdfdir[i] = config.hdfdir[i];
                }
                t_enable_ide = config.enable_ide;
                menustate = MENU_SETTINGS_HARDFILE1;
                menusub = 0;
            }
            else if (menusub == 6) // CD-ROM: insert or eject
            {
                if (!cdrom.unit.media)
                    SelectFile("ISOCUE", SCAN_DIR | SCAN_LFN, MENU_CDROM_SELECTED, MENU_MAIN1);
                else
                {
                    if (CD_Eject() == CD_LOCKED) // refused while the Amiga holds the lock (D5)
                        cd_locked_msg();
                    menustate = MENU_MAIN1;
                }
            }
            else if (menusub == 7)
                menustate = MENU_NONE1;
        }
        else if (c == KEY_BACK) // eject all floppies
        {
            for (i = 0; i <= drives; i++)
                df[i].status = 0;

            menustate = MENU_MAIN1;
        }
        else if (right)
        {
            menustate = MENU_MAIN2_1;
            menusub = 0;
        }
        break;

    case MENU_FLOPPY1: // Floppy drive options
        OsdColor(OSDCOLOR_TOPLEVEL);
        helptext = helptexts[HELPTEXT_MAIN];
        menumask = 0x0f;
        OsdSetTitle("Floppy", 0);
        OsdWrite(0, "", 0, 0);
        sprintf(s, " Floppy drives : %d", config.floppy.drives + 1);
        OsdWrite(1, s, menusub == 0, 0);
        sprintf(s, " Floppy disk turbo : %s", config.floppy.speed ? "on" : "off");
        OsdWrite(2, s, menusub == 1, 0);
        sprintf(s, " Floppy disk sounds : %s", config.drivesounds & DRIVESOUNDS_FLOPPY ? "on" : "off");
        OsdWrite(3, s, menusub == 2, !drivesounds_loaded());
        if (!drivesounds_loaded())
            menumask &= 0xb;
        OsdWrite(4, "", 0, 0);
        OsdWrite(5, "", 0, 0);
        OsdWrite(6, "", 0, 0);
        OsdWrite(7, STD_EXIT, menusub == 3, 0);

        parentstate = menustate;
        menustate = MENU_FLOPPY2;
        break;

    case MENU_FLOPPY2:
        if (menu)
            menustate = MENU_NONE1;
        else if (select)
        {
            switch (menusub)
            {
            case 0: /* Number of drives */
                config.floppy.drives = (config.floppy.drives + 1) & 3;
                ConfigFloppy(config.floppy.drives, config.floppy.speed);
                menustate = MENU_FLOPPY1;
                break;
            case 1:
                config.floppy.speed ^= 1;
                ConfigFloppy(config.floppy.drives, config.floppy.speed);
                menustate = MENU_FLOPPY1;
                break;
            case 2:
                config.drivesounds ^= DRIVESOUNDS_FLOPPY;
                if (config.drivesounds & DRIVESOUNDS_FLOPPY)
                    drivesounds_enable(DRIVESOUNDS_FLOPPY);
                else
                    drivesounds_disable(DRIVESOUNDS_FLOPPY);
                menustate = MENU_FLOPPY1;
                break;
            case 3:
                menustate = MENU_MAIN1;
                menusub = parentsub;
                break;
            }
        }
        break;

    case MENU_FILE_SELECTED: // file successfully selected

        InsertFloppy(&df[menusub]);
        menustate = MENU_MAIN1;
        menusub++;
        if (menusub > drives)
            menusub = 7;

        break;

    case MENU_CDROM_SELECTED: // an ISO or CUE for the CD-ROM drive, from the main page
        cd_insert_msg(CD_Insert(file.name, file.long_name[0] ? file.long_name : 0, CurrentDirectory()));
        menustate = MENU_MAIN1;
        menusub = 6;
        break;

        /******************************************************************/
        /* second part of the main menu                                   */
        /******************************************************************/
    case MENU_MAIN2_1:
        OsdColor(OSDCOLOR_TOPLEVEL);
        helptext = helptexts[HELPTEXT_MAIN];
        menumask = 0x7f;
        OsdSetTitle("Settings", OSD_ARROW_LEFT | OSD_ARROW_RIGHT);
        OsdWrite(0, "    load configuration", menusub == 0, 0);
        OsdWrite(1, "    save configuration", menusub == 1, 0);
        OsdWrite(2, "", 0, 0);
        OsdWrite(3, "    chipset settings \x16", menusub == 2, 0);
        OsdWrite(4, "     memory settings \x16", menusub == 3, 0);
        OsdWrite(5, "      video settings \x16", menusub == 4, 0);
        OsdWrite(6, "      audio settings \x16", menusub == 5, 0);
        OsdWrite(7, STD_EXIT, menusub == 6, 0);

        parentstate = menustate;
        menustate = MENU_MAIN2_2;
        break;

    case MENU_MAIN2_2:
        if (menu)
            menustate = MENU_NONE1;
        else if (select)
        {
            if (menusub == 0)
            {
                menusub = 0;
                menustate = MENU_LOADCONFIG_1;
            }
            else if (menusub == 1)
            {
                menusub = 0;
                menustate = MENU_SAVECONFIG_1;
            }
            else if (menusub == 2)
            {
                menustate = MENU_SETTINGS_CHIPSET1;
                menusub = 0;
            }
            else if (menusub == 3)
            {
                menustate = MENU_SETTINGS_MEMORY1;
                menusub = 0;
            }
            else if (menusub == 4)
            {
                menustate = MENU_SETTINGS_VIDEO1;
                menusub = 0;
            }
            else if (menusub == 5)
            {
                menustate = MENU_SETTINGS_AUDIO1;
                menusub = 0;
            }
        }
        else if (left)
        {
            menustate = MENU_MAIN1;
            menusub = 0;
        }
        else if (right)
        {
            menustate = MENU_MISC1;
            menusub = 0;
        }
        break;

    case MENU_MISC1:
        OsdColor(OSDCOLOR_TOPLEVEL);
        helptext = helptexts[HELPTEXT_MAIN];
        menumask = 0x3f; // Reset, about and exit.
        OsdSetTitle("Misc", OSD_ARROW_LEFT);
        OsdWrite(0, "    Reset", menusub == 0, 0);
        OsdWrite(1, "    Reboot", menusub == 1, 0);
        OsdWrite(2, "", 0, 0);
        if (PLATFORM & (1 << PLATFORM_RECONFIG))
            OsdWrite(3, "    Return to Chameleon", menusub == 2, 0);
        else
        {
            OsdWrite(3, "", 0, 0);
            menumask &= ~0x04; // Remove the Reconfigure option from the menu
        }
        //        OsdWrite(3, "    (Not yet implemented)", 0,1);
        OsdWrite(4, "    About", menusub == 3, 0);
        OsdWrite(5, "    Supporters", menusub == 4, 0);
        OsdWrite(6, "", 0, 0);
        OsdWrite(7, STD_EXIT, menusub == 5, 0);

        parentstate = menustate;
        menustate = MENU_MISC2;
        break;

    case MENU_MISC2:

        if (menu)
            menusub = 0, menustate = MENU_NONE1;
        if (left)
            menusub = 0, menustate = MENU_MAIN2_1;
        else if (select)
        {
            parentsub = menusub;
            if (menusub == 0) // Reset
            {
                menusub = 0;
                strcpy(s, "         Reset Minimig?");
                confirmfunc = OsdReset;
                menustate = MENU_CONFIRM1;
            }
            if (menusub == 1) // Reboot
            {
                menusub = 0;
                strcpy(s, "         Reboot Minimig?");
                confirmfunc = ColdBoot;
                menustate = MENU_CONFIRM1;
            }
            if (menusub == 2) // Reconfig
            {
                menusub = 0;
                strcpy(s, "     Return to Chameleon?");
                confirmfunc = Reconfigure;
                menustate = MENU_CONFIRM1;
            }
            if (menusub == 3) // About
            {
                menusub = 0;
                menustate = MENU_ABOUT1;
            }
            if (menusub == 4) // About
            {
                menusub = 0;
                menustate = MENU_SUPPORTERS1;
            }
            if (menusub == 5) // Exit
            {
                menustate = MENU_NONE1;
            }
        }
        break;

    case MENU_ABOUT1:
        OsdColor(OSDCOLOR_SUBMENU);
        helptext = helptexts[HELPTEXT_NONE];
        menumask = 0x01; // Just Exit
        OsdSetTitle("About", 0);
        OsdDrawLogo(0, 0, 1);
        OsdDrawLogo(1, 1, 1);
        OsdDrawLogo(2, 2, 1);
        OsdDrawLogo(3, 3, 1);
        OsdDrawLogo(4, 4, 1);
        OsdDrawLogo(6, 6, 1);
        //        OsdWrite(1, "", 0,0);
        //        OsdWriteDoubleSize(2,"   Minimig",0);
        //        OsdWriteDoubleSize(3,"   Minimig",1);
        //        OsdWrite(4, "", 0,0);
        OsdWrite(5, "", 0, 0);
        OsdWrite(6, "", 0, 0);
        OsdWrite(7, STD_BACK, menusub == 0, 0);

        StarsInit();
        ScrollReset();

        parentstate = menustate;
        menustate = MENU_ABOUT2;
        break;

    case MENU_ABOUT2:
        StarsUpdate();
        OsdDrawLogo(0, 0, 1);
        OsdDrawLogo(1, 1, 1);
        OsdDrawLogo(2, 2, 1);
        OsdDrawLogo(3, 3, 1);
        OsdDrawLogo(4, 4, 1);
        OsdDrawLogo(6, 6, 1);
        ScrollText(5, "                                 Minimig AGA by Rok Krajnc, ported to Turbo Chameleon 64 by Alastair M. Robinson.  Original Minimig by Dennis van Weeren with chipset improvements by Jakub Bednarski and Sascha Boing.  TG68K softcore by Tobias Gubener.  Menu / disk code by Dennis van Weeren, Jakub Bednarski, Alastair M. Robinson and Christian Vogelgsang.  Minimig logo based on a design by Loriano Pagni.  Minimig is distributed under the terms of the GNU General Public License version 3.", 0, 0, 0);
        if (select || menu)
        {
            menusub = parentsub;
            menustate = MENU_MISC1;
        }
        break;

    case MENU_SUPPORTERS1:
        OsdColor(OSDCOLOR_SUBMENU);
        helptext = helptexts[HELPTEXT_NONE];
        menumask = 0x01; // Just Exit
        OsdSetTitle("Thanks to", 0);
        OsdDrawLogo(0, 0, 1);
        OsdDrawLogo(1, 1, 1);
        OsdDrawLogo(2, 2, 1);
        OsdDrawLogo(3, 3, 1);
        OsdDrawLogo(4, 4, 1);
        OsdDrawLogo(6, 6, 1);
        //        OsdWrite(1, "", 0,0);
        //        OsdWriteDoubleSize(2,"   Minimig",0);
        //        OsdWriteDoubleSize(3,"   Minimig",1);
        //        OsdWrite(4, "", 0,0);
        OsdWrite(5, "", 0, 0);
        OsdWrite(6, "", 0, 0);
        OsdWrite(7, STD_BACK, menusub == 0, 0);

        FireworksInit();
        ScrollReset();

        parentstate = menustate;
        menustate = MENU_SUPPORTERS2;
        break;

    case MENU_SUPPORTERS2:
        FireworksUpdate();
        OsdDrawLogo(0, 8, 1);
        OsdDrawLogo(1, 8, 1);
        OsdDrawLogo(2, 8, 1);
        OsdDrawLogo(3, 8, 1);
        OsdDrawLogo(4, 8, 1);
        OsdDrawLogo(6, 8, 1);
        ScrollText(5, "                                 I'm very grateful to these people for their support, which will give me the means and motivation to continue working on this core and others.  If you would like to contribute then one-off donations at paypal.me/robinsonb5 are very welcome, or if you wish you can contribute regularly at patreon.com/coresforchameleon - if you donate 20UKP or more, or join the second tier at Patreon your name will be included on this screen, or the equivalent screen of future projects.", 0, 0, 0);
        if (select || menu)
        {
            menusub = parentsub;
            menustate = MENU_MISC1;
        }
        break;

    case MENU_LOADCONFIG_1:
        OsdColor(OSDCOLOR_SUBMENU);
        helptext = helptexts[HELPTEXT_NONE];
        if (parentstate != menustate) // First run?
        {
            menumask = 0x20;
            SetConfigurationFilename(0);
            if (ConfigurationExists(0))
                menumask |= 0x01;
            SetConfigurationFilename(1);
            if (ConfigurationExists(0))
                menumask |= 0x02;
            SetConfigurationFilename(2);
            if (ConfigurationExists(0))
                menumask |= 0x04;
            SetConfigurationFilename(3);
            if (ConfigurationExists(0))
                menumask |= 0x08;
            SetConfigurationFilename(4);
            if (ConfigurationExists(0))
                menumask |= 0x10;
            if (!(menumask & 0x1f))
                menusub = 5;
        }
        parentstate = menustate;
        OsdSetTitle("Load", 0);

        OsdWrite(0, "", 0, 0);
        OsdWrite(1, "          Default", menusub == 0, (menumask & 1) == 0);
        OsdWrite(2, "          1", menusub == 1, (menumask & 2) == 0);
        OsdWrite(3, "          2", menusub == 2, (menumask & 4) == 0);
        OsdWrite(4, "          3", menusub == 3, (menumask & 8) == 0);
        OsdWrite(5, "          4", menusub == 4, (menumask & 0x10) == 0);
        OsdWrite(6, "", 0, 0);
        OsdWrite(7, STD_EXIT, menusub == 5, 0);

        menustate = MENU_LOADCONFIG_2;
        break;

    case MENU_LOADCONFIG_2:

        //        if (down)
        //        {
        //            if (menusub < 3)
        //            if (menusub < 5)
        //                menusub++;
        //            menustate = MENU_LOADCONFIG_1;
        //        }
        //        else if (select)
        if (select)
        {
            if (menusub < 5)
            {
                OsdWrite(7, "      Loading config...", menusub == 5, 0);
                SetConfigurationFilename(menusub);
                LoadConfiguration(NULL);
                ApplyConfiguration(1, 1);
                OsdHide();
                OsdDoReset(SPI_RST_USR | SPI_RST_CPU, 0);
                //				OsdReset(RESET_NORMAL);
                menustate = MENU_NONE1;
            }
            else
            {
                menustate = MENU_MAIN2_1;
                menusub = 0;
            }
        }
        if (menu) // exit menu
        {
            menustate = MENU_MAIN2_1;
            menusub = 0;
        }
        break;

        /******************************************************************/
        /* file selection menu                                            */
        /******************************************************************/
    case MENU_FILE_SELECT1:
        OsdColor(OSDCOLOR_SUBMENU);
        helptext = helptexts[HELPTEXT_NONE];
        OsdSetTitle("Select", 0);
        PrintDirectory();
        menustate = MENU_FILE_SELECT2;
        break;

    case MENU_FILE_SELECT2:
        menumask = 0;

        ScrollLongName(); // scrolls file name if longer than display line

        if (c == KEY_HOME)
        {
            ScanDirectory(SCAN_INIT, fs_pFileExt, fs_Options);
            menustate = MENU_FILE_SELECT1;
        }

        if (c == KEY_BACK)
        {
            if (iCurrentDirectory) // if not root directory
            {
                ScanDirectory(SCAN_INIT, fs_pFileExt, fs_Options);
                ChangeDirectory(DirEntry[sort_table[iSelectedEntry]].StartCluster +
                                (fat32 ? (DirEntry[sort_table[iSelectedEntry]].HighCluster & 0x0FFF) << 16 : 0));
                if (ScanDirectory(SCAN_INIT_FIRST, fs_pFileExt, fs_Options))
                    ScanDirectory(SCAN_INIT_NEXT, fs_pFileExt, fs_Options);

                menustate = MENU_FILE_SELECT1;
            }
        }

        if (c == KEY_PGUP)
        {
            ScanDirectory(SCAN_PREV_PAGE, fs_pFileExt, fs_Options);
            menustate = MENU_FILE_SELECT1;
        }

        if (c == KEY_PGDN)
        {
            ScanDirectory(SCAN_NEXT_PAGE, fs_pFileExt, fs_Options);
            menustate = MENU_FILE_SELECT1;
        }

        if (down) // scroll down one entry
        {
            ScanDirectory(SCAN_NEXT, fs_pFileExt, fs_Options);
            menustate = MENU_FILE_SELECT1;
        }

        if (up) // scroll up one entry
        {
            ScanDirectory(SCAN_PREV, fs_pFileExt, fs_Options);
            menustate = MENU_FILE_SELECT1;
        }

        if ((i = GetASCIIKey(c)))
        { // find an entry beginning with given character
            if (nDirEntries)
            {
                if (DirEntry[sort_table[iSelectedEntry]].Attributes & ATTR_DIRECTORY)
                { // it's a directory
                    if (i < DirEntry[sort_table[iSelectedEntry]].Name[0])
                    {
                        if (!ScanDirectory(i, fs_pFileExt, fs_Options | FIND_FILE))
                            ScanDirectory(i, fs_pFileExt, fs_Options | FIND_DIR);
                    }
                    else if (i > DirEntry[sort_table[iSelectedEntry]].Name[0])
                    {
                        if (!ScanDirectory(i, fs_pFileExt, fs_Options | FIND_DIR))
                            ScanDirectory(i, fs_pFileExt, fs_Options | FIND_FILE);
                    }
                    else
                    {
                        if (!ScanDirectory(i, fs_pFileExt, fs_Options)) // find nexr
                            if (!ScanDirectory(i, fs_pFileExt, fs_Options | FIND_FILE))
                                ScanDirectory(i, fs_pFileExt, fs_Options | FIND_DIR);
                    }
                }
                else
                { // it's a file
                    if (i < DirEntry[sort_table[iSelectedEntry]].Name[0])
                    {
                        if (!ScanDirectory(i, fs_pFileExt, fs_Options | FIND_DIR))
                            ScanDirectory(i, fs_pFileExt, fs_Options | FIND_FILE);
                    }
                    else if (i > DirEntry[sort_table[iSelectedEntry]].Name[0])
                    {
                        if (!ScanDirectory(i, fs_pFileExt, fs_Options | FIND_FILE))
                            ScanDirectory(i, fs_pFileExt, fs_Options | FIND_DIR);
                    }
                    else
                    {
                        if (!ScanDirectory(i, fs_pFileExt, fs_Options)) // find next
                            if (!ScanDirectory(i, fs_pFileExt, fs_Options | FIND_DIR))
                                ScanDirectory(i, fs_pFileExt, fs_Options | FIND_FILE);
                    }
                }
            }
            menustate = MENU_FILE_SELECT1;
        }

        if (select)
        {
            if (DirEntry[sort_table[iSelectedEntry]].Attributes & ATTR_DIRECTORY)
            {
                ChangeDirectory(DirEntry[sort_table[iSelectedEntry]].StartCluster +
                                (fat32 ? (DirEntry[sort_table[iSelectedEntry]].HighCluster & 0x0FFF) << 16 : 0));
                {
                    if (strncmp((char *)DirEntry[sort_table[iSelectedEntry]].Name, "..", 2) == 0)
                    { // parent dir selected
                        if (ScanDirectory(SCAN_INIT_FIRST, fs_pFileExt, fs_Options))
                            ScanDirectory(SCAN_INIT_NEXT, fs_pFileExt, fs_Options);
                        else
                            ScanDirectory(SCAN_INIT, fs_pFileExt, fs_Options);
                    }
                    else
                        ScanDirectory(SCAN_INIT, fs_pFileExt, fs_Options);

                    menustate = MENU_FILE_SELECT1;
                }
            }
            else
            {
                if (nDirEntries)
                {
                    file.long_name[0] = 0;
                    len = strlen(DirEntryLFN[sort_table[iSelectedEntry]]);
                    if (len > 4)
                        if (DirEntryLFN[sort_table[iSelectedEntry]][len - 4] == '.')
                            len -= 4; // remove extension

                    if (len > sizeof(file.long_name))
                        len = sizeof(file.long_name);

                    strncpy(file.name, (const char *)DirEntry[sort_table[iSelectedEntry]].Name, sizeof(file.name));
                    memset(file.long_name, 0, sizeof(file.long_name));
                    strncpy(file.long_name, DirEntryLFN[sort_table[iSelectedEntry]], len);
                    strncpy(DiskInfo, DirEntryInfo[iSelectedEntry], sizeof(DiskInfo));

                    file.size = DirEntry[sort_table[iSelectedEntry]].FileSize;
                    file.attributes = DirEntry[sort_table[iSelectedEntry]].Attributes;
                    file.start_cluster = DirEntry[sort_table[iSelectedEntry]].StartCluster +
                                         (fat32 ? (DirEntry[sort_table[iSelectedEntry]].HighCluster & 0x0FFF) << 16 : 0);
                    file.cluster = file.start_cluster;
                    file.sector = 0;

                    menustate = fs_MenuSelect;
                }
                else
                    menustate = MENU_MAIN1; // Return to main menu if user selects the "No files!" line
            }
        }

        if (menu)
        {
            menustate = fs_MenuCancel;
        }

        break;

        /******************************************************************/
        /* reset menu                                                     */
        /******************************************************************/
    case MENU_CONFIRM1:
        OsdColor(OSDCOLOR_WARNING);
        helptext = helptexts[HELPTEXT_NONE];
        OsdSetTitle("Reset", 0);
        menumask = 0x03; // Yes / No
        parentstate = menustate;

        OsdWrite(0, "", 0, 0);
        OsdWrite(1, s, 0, 0);
        OsdWrite(2, "", 0, 0);
        OsdWrite(3, "               yes", menusub == 0, 0);
        OsdWrite(4, "               no", menusub == 1, 0);
        OsdWrite(5, "", 0, 0);
        OsdWrite(6, "", 0, 0);
        OsdWrite(7, "", 0, 0);

        menustate = MENU_CONFIRM2;
        break;

    case MENU_CONFIRM2:

        if (select && menusub == 0)
        {
            menustate = MENU_NONE1;
            OsdHide();
            confirmfunc();
        }

        if (menu || (select && (menusub == 1))) // exit menu
        {
            menustate = MENU_MISC1;
            menusub = parentsub;
        }
        break;

        /******************************************************************/
        /* reconfigure confirmation                                       */
        /******************************************************************/
#if 0
    case MENU_RECONF1 :
        OsdColor(OSDCOLOR_WARNING);
		helptext=helptexts[HELPTEXT_NONE];
		OsdSetTitle("Exit",0);
		menumask=0x03;	// Yes / No
		parentstate=menustate;

        OsdWrite(0, "", 0,0);
        OsdWrite(1, "     Return to Chameleon?", 0,0);
        OsdWrite(2, "", 0,0);
        OsdWrite(3, "               yes", menusub == 0,0);
        OsdWrite(4, "               no", menusub == 1,0);
        OsdWrite(5, "", 0,0);
        OsdWrite(6, "", 0,0);
        OsdWrite(7, "", 0,0);

        menustate = MENU_RECONF2;
        break;

    case MENU_RECONF2 :

        if (select && menusub == 0)
        {
            Reconfigure();
        }

        if (menu || (select && (menusub == 1))) // exit menu
        {
            menustate = MENU_MISC1;
            menusub = 1;
        }
        break;
#endif
        /******************************************************************/
        /* settings menu                                                  */
        /******************************************************************/

    case MENU_SAVECONFIG_1:
        OsdColor(OSDCOLOR_SUBMENU);
        helptext = helptexts[HELPTEXT_NONE];
        menumask = 0x3f;
        parentstate = menustate;
        OsdSetTitle("Save", 0);

        OsdWrite(0, "", 0, 0);
        SetConfigurationFilename(0);
        sprintf(s, "    Default %s", ConfigurationExists(0) ? "(overwrite)" : "");
        OsdWrite(1, s, menusub == 0, 0);
        SetConfigurationFilename(1);
        sprintf(s, "          1 %s", ConfigurationExists(0) ? "(overwrite)" : "");
        OsdWrite(2, s, menusub == 1, 0);
        SetConfigurationFilename(2);
        sprintf(s, "          2 %s", ConfigurationExists(0) ? "(overwrite)" : "");
        OsdWrite(3, s, menusub == 2, 0);
        SetConfigurationFilename(3);
        sprintf(s, "          3 %s", ConfigurationExists(0) ? "(overwrite)" : "");
        OsdWrite(4, s, menusub == 3, 0);
        SetConfigurationFilename(4);
        sprintf(s, "          4 %s", ConfigurationExists(0) ? "(overwrite)" : "");
        OsdWrite(5, s, menusub == 4, 0);
        OsdWrite(6, "", 0, 0);
        OsdWrite(7, STD_EXIT, menusub == 5, 0);

        menustate = MENU_SAVECONFIG_2;
        break;

    case MENU_SAVECONFIG_2:

        if (menu)
        {
            menustate = MENU_MAIN2_1;
            menusub = 5;
        }

        else if (up)
        {
            if (menusub > 0)
                menusub--;
            menustate = MENU_SAVECONFIG_1;
        }
        else if (down)
        {
            //            if (menusub < 3)
            if (menusub < 5)
                menusub++;
            menustate = MENU_SAVECONFIG_1;
        }
        else if (select)
        {
            if (menusub < 5)
            {
                SetConfigurationFilename(menusub);
                SaveConfiguration(NULL);
                menustate = MENU_NONE1;
            }
            else
            {
                menustate = MENU_MAIN2_1;
                menusub = 1;
            }
        }
        if (menu) // exit menu
        {
            menustate = MENU_MAIN2_1;
            menusub = 1;
        }
        break;

        /******************************************************************/
        /* chipset settings menu                                          */
        /******************************************************************/
    case MENU_SETTINGS_CHIPSET1:
        OsdColor(OSDCOLOR_SUBMENU);
        helptext = helptexts[HELPTEXT_CHIPSET];
        parentstate = menustate;
        // With a 68040 that cannot be switched away from, the CPU line still
        // says what the machine is -- but it is not a choice, so it is not
        // selectable and the cursor never lands on it.  On every other core
        // core_caps is 0 and this is the menu exactly as it was.
        menumask = CORE_CPU_FIXED_040() ? 0x7e : 0x7f;
        if (CORE_CPU_FIXED_040() && menusub == 0)
            menusub = 1;
        OsdSetTitle("Chipset", OSD_ARROW_LEFT | OSD_ARROW_RIGHT);

#if 0
        OsdWrite(0, "", 0,0);
        strcpy(s, "         CPU : ");
//        strcat(s, config.chipset & CONFIG_TURBO ? "turbo" : "normal");
        strcat(s, config_cpu_msg[config.cpu & 0x03]);
        OsdWrite(1, s, menusub == 0,0);
        strcpy(s, "       Video : ");
        strcat(s, config.chipset & CONFIG_NTSC ? "NTSC" : "PAL");
        OsdWrite(2, s, menusub == 1,0);
        strcpy(s, "     Chipset : ");
        strcat(s, config_chipset_msg[config.chipset >> 2 & 3]);
        OsdWrite(3, s, menusub == 2,0);
        OsdWrite(4, "", 0,0);
        OsdWrite(5, "", 0,0);
        OsdWrite(6, "", 0,0);
#endif
        // The die temperature, on the first line, where Paul asked for it.  The
        // XADC transfer function is T = raw * 503.975 / 4096 - 273.15; whole
        // degrees is as much as this line can usefully say.  Only a core that
        // decodes the register says so in its capabilities -- on any other one
        // that address reads the platform register, which would print a
        // confident and entirely fictional number.
        if (core_caps & CORE_CAPS_TEMP) {
            unsigned short raw = FPGA_TEMP_RAW;
            int t = (int)((((unsigned long)(raw & 0x0fff)) * 504) >> 12) - 273;
            // The raw word is shown alongside until this is trusted.  It reads
            // -273 when raw is 0, and a failed address decode lands in the same
            // place -- cfide answers an unrecognised address with platformdata,
            // which is also a small number -- so the two cannot be told apart
            // from the temperature alone.  0000 means nothing is arriving;
            // anything else means the decode works and the XADC is the suspect.
            // HDMI status rides along on the same line while the HPD question
            // is open: is the part answering at all when the display is off?
            // ff = no answer, otherwise bit 6 (0x40) is Hot Plug Detect.
            sprintf(s, "  %dC %04X HDMI %08lX", t, raw, adv_status_hist);
            OsdWrite(0, s, 0, 0);
        } else {
            OsdWrite(0, "", 0, 0);
        }
        strcpy(s, "         CPU : ");
        if (CORE_CPU_FIXED_040()) {
            strcat(s, "68040");
            if (core_caps & CORE_CAPS_FPU) strcat(s, "/FPU");
            if (core_caps & CORE_CAPS_MMU) strcat(s, "/MMU");
            OsdWrite(1, s, 0, 1);       // shown, greyed, not selectable
        } else {
            strcat(s, config_cpu_msg[config.cpu & 0x03]);
            OsdWrite(1, s, menusub == 0, 0);
        }
        strcpy(s, "       Turbo : ");
        strcat(s, config_turbo_msg[(config.cpu >> 2) & 0x03]);
        OsdWrite(2, s, menusub == 1, 0);
        strcpy(s, "       Video : ");
        strcat(s, config.chipset & CONFIG_NTSC ? "NTSC" : "PAL");
        OsdWrite(3, s, menusub == 2, 0);
        strcpy(s, "     Chipset : ");
        strcat(s, config_chipset_msg[(config.chipset >> 2) & 7]);
        OsdWrite(4, s, menusub == 3, 0);
        strcpy(s, "     CD32Pad : ");
        strcat(s, config_cd32pad_msg[(config.autofire >> 2) & 1]);
        OsdWrite(5, s, menusub == 4, 0);
        strcpy(s, "  Chip slots : ");
        strcat(s, config_chipslots_msg[(config.cpu & CONFIG_CPU_FASTCHIP) ? 1 : 0]);
        OsdWrite(6, s, menusub == 5, 0);

        OsdWrite(7, STD_BACK, menusub == 6, 0);

        menustate = MENU_SETTINGS_CHIPSET2;
        break;

    case MENU_SETTINGS_CHIPSET2:

        if (down && menusub < 6)
        {
            menusub++;
            menustate = MENU_SETTINGS_CHIPSET1;
        }

        if (up && menusub > 0)
        {
            menusub--;
            menustate = MENU_SETTINGS_CHIPSET1;
        }

        if (select)
        {
            if (menusub == 0 && !CORE_CPU_FIXED_040())
            {
                int cpu = (config.cpu + 1) & 3;
                menustate = MENU_SETTINGS_CHIPSET1;

                if (cpu == 2)
                    ++cpu;
                config.cpu &= ~3;
                config.cpu |= cpu;
                ConfigCPU(config.cpu);
            }
            else if (menusub == 1)
            {
                int _config_turbo = (config.cpu >> 2) & 0x3;
                menustate = MENU_SETTINGS_CHIPSET1;
                _config_turbo += 1;
                config.cpu = (config.cpu & ~0x0c) | ((_config_turbo & 0x3) << 2);  // keeps Chip slots
                ConfigCPU(config.cpu);
            }
            else if (menusub == 2)
            {
                config.chipset ^= CONFIG_NTSC;
                menustate = MENU_SETTINGS_CHIPSET1;
                ConfigChipset(config.chipset);
            }
            else if (menusub == 3)
            {
                switch (config.chipset & 0x1c)
                {
                case 0:
                    config.chipset = (config.chipset & 3) | CONFIG_A1000;
                    break;
                case CONFIG_A1000:
                    config.chipset = (config.chipset & 3) | CONFIG_ECS;
                    break;
                case CONFIG_ECS:
                    config.chipset = (config.chipset & 3) | CONFIG_AGA | CONFIG_ECS;
                    break;
                case (CONFIG_AGA | CONFIG_ECS):
                    config.chipset = (config.chipset & 3) | 0;
                    break;
                }

                menustate = MENU_SETTINGS_CHIPSET1;
                ConfigChipset(config.chipset);
            }
            else if (menusub == 4)
            {
                /* CD32 pad */
                config.autofire = (config.autofire + 4) & 0x7;
                menustate = MENU_SETTINGS_CHIPSET1;
                ConfigAutofire(config.autofire);
            }
            else if (menusub == 5)
            {
                config.cpu ^= CONFIG_CPU_FASTCHIP;
                menustate = MENU_SETTINGS_CHIPSET1;
                ConfigCPU(config.cpu);
            }
            else if (menusub == 6)
            {
                menustate = MENU_MAIN2_1;
                menusub = 2;
            }
        }

        if (menu)
        {
            menustate = MENU_MAIN2_1;
            menusub = 2;
        }
        else if (right)
        {
            menustate = MENU_SETTINGS_MEMORY1;
            menusub = 0;
        }
        else if (left)
        {
            menustate = MENU_SETTINGS_HDMI1;
            menusub = 0;
        }
        break;

        /******************************************************************/
        /* memory settings menu                                           */
        /******************************************************************/
    case MENU_SETTINGS_MEMORY1:
        if (!t_memory_valid) {       // entering the menu, not redrawing it
            t_memory = config.memory;
            t_memory_valid = 1;
        }
        OsdColor(OSDCOLOR_SUBMENU);
        helptext = helptexts[HELPTEXT_MEMORY];
        menumask = 0x7f;
        parentstate = menustate;

        OsdSetTitle("Memory", OSD_ARROW_LEFT | OSD_ARROW_RIGHT);

        strcpy(s, "      CHIP  : ");
        strcat(s, config_memory_chip_msg[config.memory & 0x03]);
        OsdWrite(0, s, menusub == 0, 0);
        strcpy(s, "      SLOW  : ");
        strcat(s, config_memory_slow_msg[config.memory >> 2 & 0x03]);
        OsdWrite(1, s, menusub == 1, 0);
        strcpy(s, "      FAST  : ");
        strcat(s, config_memory_fast_msg[config.memory >> 4 & 0x03]);
        OsdWrite(2, s, menusub == 2, 0);

        OsdWrite(3, "", 0, 0);

        strcpy(s, "        ROM  : ");
        if (config.kickstart.long_name[0])
            strncat(s, config.kickstart.long_name, sizeof(config.kickstart.long_name));
        else
            strncat(s, config.kickstart.name, sizeof(config.kickstart.name));
        OsdWrite(4, s, menusub == 3, 0);

        strcpy(s, "      HRTmon: ");
        strcat(s, (config.memory & 0x40) ? "enabled " : "disabled");
        OsdWrite(5, s, menusub == 4, 0);

        // Which fast-RAM boards autoconfig offers.  "DDR3 only" drops the
        // Zorro-II board and Zorro-III boards 1 and 2 from the chain so every
        // fast-RAM allocation lands on the DDR3 board -- the only way to
        // benchmark that memory rather than whichever board the OS happened
        // to allocate from.  Takes effect at the next reset, like the rest of
        // the memory map.
        strcpy(s, "      Boards: ");
        strcat(s, (config.memory & 0x80) ? "DDR3 only" : "all      ");
        OsdWrite(6, s, menusub == 5, 0);

        OsdWrite(7, STD_BACK, menusub == 6, 0);

        menustate = MENU_SETTINGS_MEMORY2;
        break;

    case MENU_SETTINGS_MEMORY2:
        if (select)
        {
            if (menusub == 0) /* Chip RAM */
            {
                config.memory = ((config.memory + 1) & 0x03) | (config.memory & ~0x03);
                menustate = MENU_SETTINGS_MEMORY1;
                ConfigMemory(config.memory);
            }
            else if (menusub == 1) /* Slow RAM */
            {
                config.memory = ((config.memory + 4) & 0x0C) | (config.memory & ~0x0C);
                menustate = MENU_SETTINGS_MEMORY1;
                ConfigMemory(config.memory);
            }
            else if (menusub == 2) /* Fast RAM */
            {
                config.memory = ((config.memory + 0x10) & 0x30) | (config.memory & ~0x30);
                menustate = MENU_SETTINGS_MEMORY1;
                ConfigMemory(config.memory);
            }
            else if (menusub == 3) /* Kickstart ROM */
            {
                SelectFile("ROM", SCAN_DIR | SCAN_LFN, MENU_ROMFILE_SELECTED, MENU_SETTINGS_MEMORY1);
            }
            else if (menusub == 4) /* HRTMon */
            {
                config.memory ^= 0x40;
                ConfigMemory(config.memory);
                // if (!(config.disable_ar3 & 0x01)||(config.memory & 0x20))
                //   config.disable_ar3 |= 0x01;
                // else
                //   config.disable_ar3 &= 0xFE;
                menustate = MENU_SETTINGS_MEMORY1;
            }
            else if (menusub == 5) /* fast-RAM boards: all / DDR3 only */
            {
                config.memory ^= 0x80;
                ConfigMemory(config.memory);
                menustate = MENU_SETTINGS_MEMORY1;
            }
            else if (menusub == 6)
            {
                menustate = MENU_MAIN2_1;
                menusub = 3;
            }
        }

        if (menu)
        {
            menustate = MENU_MAIN2_1;
            menusub = 3;
        }
        else if (right)
        {
            menustate = MENU_SETTINGS_AUDIO1;
            menusub = 0;
        }
        else if (left)
        {
            menustate = MENU_SETTINGS_CHIPSET1;
            menusub = 0;
        }

        // Leaving the menu (Exit, the menu key, or left/right to the next
        // page): if the memory settings changed, ask for the reset they need
        // first, then go where the user was going.  Choosing a Kickstart
        // (SelectFile) is not leaving: it comes back here, and has its own
        // "Reload Kickstart?" prompt.
        if (menustate != MENU_SETTINGS_MEMORY1 && menustate != MENU_SETTINGS_MEMORY2
                && !(select && menusub == 3)) {
            t_memory_valid = 0;
            if (config.memory != t_memory) {
                t_memory_next = menustate;
                t_memory_nextsub = menusub;
                menustate = MENU_MEMORY_CHANGED1;
                menusub = 0;
            }
        }
        break;

    // memory configuration has changed: offer the reset it needs, the same way
    // the hardfile menu does (autoconfig and the memory map change at reset)
    case MENU_MEMORY_CHANGED1:
        helptext = helptexts[HELPTEXT_NONE];
        OsdColor(OSDCOLOR_WARNING);
        menumask = 0x03;
        parentstate = menustate;
        OsdSetTitle("Confirm", 0);

        OsdWrite(0, "", 0, 0);
        OsdWrite(1, "  Memory configuration changed,", 0, 0);
        OsdWrite(2, "      this requires a reset.", 0, 0);
        OsdWrite(3, "", 0, 0);
        OsdWrite(4, "       Reset Minimig?", 0, 0);
        OsdWrite(5, "", 0, 0);
        OsdWrite(6, "             yes", menusub == 0, 0);
        OsdWrite(7, "             no", menusub == 1, 0);

        menustate = MENU_MEMORY_CHANGED2;
        break;

    case MENU_MEMORY_CHANGED2:
        if (select && menusub == 0) // yes
        {
            OsdReset();
            menustate = MENU_NONE1;
        }
        else if ((select && menusub == 1) || menu) // no: carry on where the user was going
        {
            menustate = t_memory_next;
            menusub = t_memory_nextsub;
        }
        break;

        /******************************************************************/
        /* drive settings menu                                            */
        /******************************************************************/

        /******************************************************************/
        /* hardfile settings menu                                         */
        /******************************************************************/

    case MENU_SETTINGS_HARDFILE1:
        OsdColor(OSDCOLOR_SUBMENU);
        helptext = hdf_help((menusub >= 1 && menusub <= 4) ? (menusub - 1) >> 1 : -1);
        // page 2 (IDE port 2) only on a core that has it
        OsdSetTitle("Harddisks", (core_caps & CORE_CAPS_IDE2) ? OSD_ARROW_RIGHT : 0);

        parentstate = menustate;
        menumask = 0x81; // b10000001 - On/off & exit enabled by default...
        if (core_caps & CORE_CAPS_IDE2)
            menumask |= 0x40; // the IDE port 2 line (12.6: the title arrow alone was not found)
        strcpy(s, "    IDE : ");
        strcat(s, t_enable_ide ? "on " : "off");
        OsdWrite(0, s, menusub == 0, 0);

        menumask |= hdf_slot_lines(0, 1, " Master : ", t_enable_ide);
        menumask |= hdf_slot_lines(1, 3, "  Slave : ", t_enable_ide);

        if (t_enable_ide)
            menumask |= 0x20; // sounds
        strcpy(s, " Sounds : ");
        strcat(s, config.drivesounds & DRIVESOUNDS_HDD ? "on " : "off");
        OsdWrite(5, s, menusub == 5, t_enable_ide == 0);
        if (core_caps & CORE_CAPS_IDE2)
            OsdWrite(6, " IDE port 2 \x16", menusub == 6, 0);
        else
            OsdWrite(6, "", 0, 0);
        OsdWrite(7, STD_BACK, menusub == 7, 0);

        menustate = MENU_SETTINGS_HARDFILE2;

        break;

    case MENU_SETTINGS_HARDFILE2:
        if (cd_msg_expired())
            menustate = MENU_SETTINGS_HARDFILE1;
        if (select)
        {
            if (menusub == 0)
            {
                t_enable_ide = (t_enable_ide == 0);
                menustate = MENU_SETTINGS_HARDFILE1;
            }
            else if (menusub == 1 || menusub == 3) // master / slave type
            {
                hdf_next_type((menusub - 1) >> 1);
                menustate = MENU_SETTINGS_HARDFILE1;
            }
            else if (menusub == 2 || menusub == 4) // master / slave file
            {
                hdf_select((menusub - 1) >> 1);
            }
            else if (menusub == 5)
            {
                config.drivesounds ^= DRIVESOUNDS_HDD;
                if (config.drivesounds & DRIVESOUNDS_HDD)
                    drivesounds_enable(DRIVESOUNDS_HDD);
                else
                    drivesounds_disable(DRIVESOUNDS_HDD);
                menustate = MENU_SETTINGS_HARDFILE1;
            }
            else if (menusub == 6) // IDE port 2 (the line is only there on a two-port core)
            {
                menustate = MENU_SETTINGS_HARDFILE3;
                menusub = 0;
            }
            else if (menusub == 7) // return to previous menu
            {
                menustate = MENU_HARDFILE_EXIT;
            }
        }
        else if (right && (core_caps & CORE_CAPS_IDE2))
        {
            menustate = MENU_SETTINGS_HARDFILE3;
            menusub = 0;
        }

        if (menu) // return to previous menu
        {
            menustate = MENU_HARDFILE_EXIT;
        }
        break;

        /******************************************************************/
        /* IDE port 2: no on/off line, it is on when a slot is set (D4)   */
        /******************************************************************/
    case MENU_SETTINGS_HARDFILE3:
        OsdColor(OSDCOLOR_SUBMENU);
        helptext = hdf_help(menusub <= 3 ? 2 + (menusub >> 1) : -1);
        OsdSetTitle("IDE port 2", OSD_ARROW_LEFT);

        parentstate = menustate;
        menumask = 0x10; // back
        menumask |= hdf_slot_lines(2, 0, " Master : ", t_enable_ide);
        menumask |= hdf_slot_lines(3, 2, "  Slave : ", t_enable_ide);
        OsdWrite(4, " Port 2 needs AtapiMagic or", 0, 0);
        OsdWrite(5, " IDEfix97 on the Amiga.", 0, 0);
        OsdWrite(6, " Not bootable.", 0, 0);
        OsdWrite(7, STD_BACK, menusub == 4, 0);

        menustate = MENU_SETTINGS_HARDFILE4;
        break;

    case MENU_SETTINGS_HARDFILE4:
        if (cd_msg_expired())
            menustate = MENU_SETTINGS_HARDFILE3;
        if (select)
        {
            if (menusub == 0 || menusub == 2) // master / slave type
            {
                hdf_next_type(2 + (menusub >> 1));
                menustate = MENU_SETTINGS_HARDFILE3;
            }
            else if (menusub == 1 || menusub == 3) // master / slave file
                hdf_select(2 + (menusub >> 1));
            else if (menusub == 4)
                menustate = MENU_HARDFILE_EXIT;
        }
        else if (left)
        {
            menustate = MENU_SETTINGS_HARDFILE1;
            menusub = 0;
        }
        if (menu)
            menustate = MENU_HARDFILE_EXIT;
        break;

        /******************************************************************/
        /* hardfile selected menu                                         */
        /******************************************************************/
    case MENU_HARDFILE_SELECTED:
    {
        int slot = hdf_select_slot;
        hardfileTYPE *t = &t_hardfile[slot];
        menustate = hdf_page(slot);
        if (t->enabled == HDF_CDROM)
        {
            if (cd_live(slot))
            {   // a disc change in the live drive: now, no reset (refused while locked, D5)
                cd_insert_msg(CD_Insert(file.name, file.long_name[0] ? file.long_name : 0, CurrentDirectory()));
                *t = *SlotConfig(slot);
                t_hdfdir[slot] = config.hdfdir[slot];
            }
            else
            {   // the disc for a CD slot that is not live yet
                memcpy((void *)t->name, (void *)file.name, sizeof(t->name));
                memcpy((void *)t->long_name, (void *)file.long_name, sizeof(t->long_name));
                t->present = CD_PRESENT(file.name); // ISO or CUE: the config's name has no extension
                t_hdfdir[slot] = CurrentDirectory();
            }
            break;
        }
        // Read RDB from selected drive and determine type...
        memcpy((void *)t->name, (void *)file.name, sizeof(t->name));
        memcpy((void *)t->long_name, (void *)file.long_name, sizeof(t->long_name));
        t_hdfdir[slot] = CurrentDirectory();
        switch (GetHDFFileType(file.name))
        {
        case HDF_FILETYPE_RDB:
            t->enabled = HDF_FILE;
            t->present = 1;
            break;
        case HDF_FILETYPE_DOS:
            t->enabled = HDF_FILE | HDF_SYNTHRDB;
            t->present = 1;
            break;
        case HDF_FILETYPE_UNKNOWN:
            t->present = 1;
            if (t->enabled == HDF_FILE) // Warn if we can't detect the type
                menustate = MENU_SYNTHRDB1;
            else
                menustate = MENU_SYNTHRDB2_1;
            menusub = 0;
            break;
        case HDF_FILETYPE_NOTFOUND:
        default:
            t->present = 0;
            break;
        }
        break;
    }

        // check if hardfile configuration has changed
    case MENU_HARDFILE_EXIT:
        if (hdf_needs_reset(t_enable_ide))
        {
            menustate = MENU_HARDFILE_CHANGED1;
            menusub = 1;
        }
        else
        {
            // only discs of CD slots differ: remember them, no reset
            for (i = 0; i < HDD_SLOTS; i++)
                if (t_hardfile[i].enabled == HDF_CDROM && !cd_live(i))
                {
                    *SlotConfig(i) = t_hardfile[i];
                    config.hdfdir[i] = t_hdfdir[i];
                }
            menustate = MENU_MAIN1;
            menusub = 5;
        }

        break;

    // hardfile configuration has changed, ask user if he wants to use the new settings
    case MENU_HARDFILE_CHANGED1:
        helptext = helptexts[HELPTEXT_NONE];
        OsdColor(OSDCOLOR_WARNING);
        menumask = 0x03;
        parentstate = menustate;
        OsdSetTitle("Confirm", 0);

        OsdWrite(0, "", 0, 0);
        OsdWrite(1, "    Changing configuration", 0, 0);
        OsdWrite(2, "      requires reset.", 0, 0);
        OsdWrite(3, "", 0, 0);
        OsdWrite(4, "       Reset Minimig?", 0, 0);
        OsdWrite(5, "", 0, 0);
        OsdWrite(6, "             yes", menusub == 0, 0);
        OsdWrite(7, "             no", menusub == 1, 0);

        menustate = MENU_HARDFILE_CHANGED2;
        break;

    case MENU_HARDFILE_CHANGED2:
        if (select)
        {
            if (menusub == 0) // yes
            {
                unsigned char upd[HDD_SLOTS];
                for (i = 0; i < HDD_SLOTS; i++)
                {
                    hardfileTYPE *c = SlotConfig(i);
                    upd[i] = (config.enable_ide != t_enable_ide && t_hardfile[i].enabled)
                          || c->enabled != t_hardfile[i].enabled
                          || strncmp(c->name, t_hardfile[i].name, sizeof(c->name)) != 0;
                    *c = t_hardfile[i];                  // apply new configuration
                    config.hdfdir[i] = t_hdfdir[i];
                }
                config.enable_ide = t_enable_ide;        // Apply new IDE on/off

                // FIXME - waiting for user-confirmation increases the window of opportunity for file corruption!

                for (i = 0; i < HDD_SLOTS; i++)
                    if (upd[i] && (i < 2 || (core_caps & CORE_CAPS_IDE2)))
                        OpenHardfile(i);
                ApplyCDROM();       // the CD drive's slot and disc
                ConfigIDEPorts();
                OsdReset();

                menustate = MENU_NONE1;
            }
            else if (menusub == 1) // no
            {
                menustate = MENU_MAIN1;
                menusub = 5;
            }
        }

        if (menu)
        {
            menustate = MENU_MAIN1;
            menusub = 5;
        }
        break;

    case MENU_SYNTHRDB1:
        helptext = helptexts[HELPTEXT_NONE];
        menumask = 0x01;
        parentstate = menustate;
        OsdSetTitle("Warning", 0);
        OsdWrite(0, "", 0, 0);
        OsdWrite(1, " No partition table found -", 0, 0);
        OsdWrite(2, " Hardfile image may need", 0, 0);
        OsdWrite(3, " to be prepped with HDToolbox,", 0, 0);
        OsdWrite(4, " then formatted.", 0, 0);
        OsdWrite(5, "", 0, 0);
        OsdWrite(6, "", 0, 0);
        OsdWrite(7, "             OK", menusub == 0, 0);

        menustate = MENU_SYNTHRDB2;
        break;

    case MENU_SYNTHRDB2_1:
        helptext = helptexts[HELPTEXT_NONE];
        menumask = 0x01;
        parentstate = menustate;
        OsdSetTitle("Warning", 0);
        OsdWrite(0, "", 0, 0);
        OsdWrite(1, " No filesystem recognised.", 0, 0);
        OsdWrite(2, " Hardfile may need formatting", 0, 0);
        OsdWrite(3, " (or may simply be an", 0, 0);
        OsdWrite(4, " unrecognised filesystem)", 0, 0);
        OsdWrite(5, "", 0, 0);
        OsdWrite(6, "", 0, 0);
        OsdWrite(7, "             OK", menusub == 0, 0);

        menustate = MENU_SYNTHRDB2;
        break;

    case MENU_SYNTHRDB2:
        if (select || menu)
        {
            if (menusub == 0) // OK
                menustate = hdf_page(hdf_select_slot);
        }
        break;

        /******************************************************************/
        /* video settings menu                                            */
        /******************************************************************/
    case MENU_SETTINGS_VIDEO1:
        OsdColor(OSDCOLOR_SUBMENU);
        menumask = 0xff;
        parentstate = menustate;
        helptext = helptexts[HELPTEXT_VIDEO];
        // config files from older firmware hold 0 here; anything else: off
        if (config.crt_mask > 3) config.crt_mask = 0;
        if (config.crt_bloom > 2) config.crt_bloom = 0;
        if (config.crt_beam > 3) config.crt_beam = 0;

        OsdSetTitle("Video", OSD_ARROW_LEFT | OSD_ARROW_RIGHT);
        strcpy(s, "   Lores Filter : ");
        strcat(s, config_filter_msg[config.filter.lores & 0x03]);
        OsdWrite(0, s, menusub == 0, 0);
        strcpy(s, "   Hires Filter : ");
        strcat(s, config_filter_msg[config.filter.hires & 0x03]);
        OsdWrite(1, s, menusub == 1, 0);
        strcpy(s, "   Scanlines    : ");
        strcat(s, config_scanlines_msg[config.scanlines & 3]);
        OsdWrite(2, s, menusub == 2, 0);
        strcpy(s, "   Scaling      : ");
        strcat(s, config_scaling_msg[CONFIG_SCALING(config.scanlines)]);
        OsdWrite(3, s, menusub == 3, 0);
        strcpy(s, "   CRT Mask     : ");
        strcat(s, config_crt_mask_msg[config.crt_mask & 3]);
        OsdWrite(4, s, menusub == 4, 0);
        strcpy(s, "   Bloom        : ");
        strcat(s, config_crt_bloom_msg[config.crt_bloom]);
        OsdWrite(5, s, menusub == 5, 0);
        strcpy(s, "   Beam width   : ");
        strcat(s, config_crt_beam_msg[config.crt_beam & 3]);
        OsdWrite(6, s, menusub == 6, 0);
        OsdWrite(7, STD_BACK, menusub == 7, 0);

        menustate = MENU_SETTINGS_VIDEO2;
        break;

    case MENU_SETTINGS_VIDEO2:
        if (select)
        {
            if (menusub == 0)
            {
                config.filter.lores++;
                config.filter.lores &= 0x03;
                menustate = MENU_SETTINGS_VIDEO1;
                ConfigVideo(config.filter.hires, config.filter.lores, config.scanlines, config.crt_mask, config.crt_bloom, config.crt_beam);
            }
            else if (menusub == 1)
            {
                config.filter.hires++;
                config.filter.hires &= 0x03;
                menustate = MENU_SETTINGS_VIDEO1;
                ConfigVideo(config.filter.hires, config.filter.lores, config.scanlines, config.crt_mask, config.crt_bloom, config.crt_beam);
                //                ConfigFilter(config.filter.lores, config.filter.hires);
            }
            else if (menusub == 2)
            {
                short tmp = config.scanlines + 1;
                if ((tmp & 3) == 3)
                    tmp = 0;
                config.scanlines = (config.scanlines & 0xfc) | (tmp & 3);
                menustate = MENU_SETTINGS_VIDEO1;
                ConfigVideo(config.filter.hires, config.filter.lores, config.scanlines, config.crt_mask, config.crt_bloom, config.crt_beam);
                //                ConfigScanlines(config.scanlines);
            }
            else if (menusub == 3)
            {
                // Scaling: line rate -> sharp -> area -> line rate
                unsigned char sc = CONFIG_SCALING(config.scanlines);
                sc = (sc == SCALING_LINE) ? SCALING_SHARP : (sc == SCALING_SHARP) ? SCALING_AREA : SCALING_LINE;
                config.scanlines = (config.scanlines & ~SCALING_MASK) | (sc << SCALING_SHIFT);
                menustate = MENU_SETTINGS_VIDEO1;
                ConfigVideo(config.filter.hires, config.filter.lores, config.scanlines, config.crt_mask, config.crt_bloom, config.crt_beam);
            }

            else if (menusub == 4)
            {
                config.crt_mask = (config.crt_mask + 1) & 3;
                menustate = MENU_SETTINGS_VIDEO1;
                ConfigVideo(config.filter.hires, config.filter.lores, config.scanlines, config.crt_mask, config.crt_bloom, config.crt_beam);
            }
            else if (menusub == 5)
            {
                config.crt_bloom = (config.crt_bloom >= 2) ? 0 : config.crt_bloom + 1;
                menustate = MENU_SETTINGS_VIDEO1;
                ConfigVideo(config.filter.hires, config.filter.lores, config.scanlines, config.crt_mask, config.crt_bloom, config.crt_beam);
            }
            else if (menusub == 6)
            {
                config.crt_beam = (config.crt_beam + 1) & 3;
                menustate = MENU_SETTINGS_VIDEO1;
                ConfigVideo(config.filter.hires, config.filter.lores, config.scanlines, config.crt_mask, config.crt_bloom, config.crt_beam);
            }
            else if (menusub == 7)
            {
                menustate = MENU_MAIN2_1;
                menusub = 4;
            }
        }

        if (menu)
        {
            menustate = MENU_MAIN2_1;
            menusub = 4;
        }
        else if (right)
        {
            // menustate = MENU_SETTINGS_CHIPSET1;
            menustate = MENU_SETTINGS_VIDEO3;
            menusub = 0;
        }
        else if (left)
        {
            menustate = MENU_SETTINGS_AUDIO1;
            menusub = 0;
        }
        break;

        /******************************************************************/
        /* video output settings menu                                     */
        /******************************************************************/
    case MENU_SETTINGS_VIDEO3:
        OsdColor(OSDCOLOR_SUBMENU);
        menumask = 0x1f;
        parentstate = menustate;
        helptext = helptexts[HELPTEXT_VIDEO];

        OsdSetTitle("Video Pos", OSD_ARROW_LEFT | OSD_ARROW_RIGHT);
        /* Both signed: Hpos in HD pixels (negative moves the picture left),
           Vpos in Amiga lines of 64 us (negative moves it up; one line is
           2.4 HD lines at 50 Hz, 2.9 at 60 Hz) */
        sprintf(s, " Hpos : %4d | Vpos : %4d", (int)(signed char)config.videopos.hpos,
                (int)(signed char)config.videopos.vpos);
        OsdWrite(0, s, 0, 0);
        OsdWrite(1, " --- ", 0, 0);
        OsdWrite(2, "   HPOS +", menusub == 0, 0);
        OsdWrite(3, "   HPOS -", menusub == 1, 0);
        OsdWrite(4, " --- ", 0, 0);
        OsdWrite(5, "   VPOS +", menusub == 2, 0);
        OsdWrite(6, "   VPOS -", menusub == 3, 0);
        OsdWrite(7, STD_BACK, menusub == 4, 0);

        menustate = MENU_SETTINGS_VIDEO4;
        break;

    case MENU_SETTINGS_VIDEO4:
        if (select)
        {
            if (menusub == 0)
            {
                if ((signed char)config.videopos.hpos < 0x78)
                    config.videopos.hpos = (config.videopos.hpos + 0x08);
                menustate = MENU_SETTINGS_VIDEO3;
                ConfigVideoPos(config.videopos.hpos, config.videopos.vpos);
            }
            else if (menusub == 1)
            {
                if ((signed char)config.videopos.hpos > -0x80)
                    config.videopos.hpos = (config.videopos.hpos - 0x08);
                menustate = MENU_SETTINGS_VIDEO3;
                ConfigVideoPos(config.videopos.hpos, config.videopos.vpos);
            }
            /* Vpos: -VPOS_MAX..VPOS_MAX in steps of 2 lines, stopping at the ends */
            else if (menusub == 2)
            {
                if ((signed char)config.videopos.vpos < VPOS_MAX)
                    config.videopos.vpos = (config.videopos.vpos + VPOS_STEP);
                menustate = MENU_SETTINGS_VIDEO3;
                ConfigVideoPos(config.videopos.hpos, config.videopos.vpos);
            }
            else if (menusub == 3)
            {
                if ((signed char)config.videopos.vpos > -VPOS_MAX)
                    config.videopos.vpos = (config.videopos.vpos - VPOS_STEP);
                menustate = MENU_SETTINGS_VIDEO3;
                ConfigVideoPos(config.videopos.hpos, config.videopos.vpos);
            }

            else if (menusub == 4)
            {
                menustate = MENU_MAIN2_1;
                menusub = 4;
            }
        }

        if (menu)
        {
            menustate = MENU_MAIN2_1;
            menusub = 4;
        }
        else if (right)
        {
            menustate = MENU_SETTINGS_HDMI1;
            menusub = 0;
        }
        else if (left)
        {
            menustate = MENU_SETTINGS_VIDEO1;
            menusub = 0;
        }
        break;

        /******************************************************************/
        /* HDMI settings menu: the ADV7511's video clock delay, i.e. where */
        /* in the pixel the transmitter samples the FPGA's DDR data.       */
        /* Colour sparkles (light yellows first) mean too close to an edge;*/
        /* the best value is the middle of the range that looks clean.     */
        /******************************************************************/
    case MENU_SETTINGS_HDMI1:
        OsdColor(OSDCOLOR_SUBMENU);
        menumask = 0x07;
        parentstate = menustate;
        helptext = helptexts[HELPTEXT_HDMI];

        OsdSetTitle("HDMI", OSD_ARROW_LEFT | OSD_ARROW_RIGHT);
        OsdWrite(0, "", 0, 0);
        OsdWrite(1, "   Clock delay +", menusub == 0, 0);
        OsdWrite(2, "   Clock delay -", menusub == 1, 0);
        OsdWrite(3, "", 0, 0);
        {
            char *p;
            int i;
            strcpy(s, "   ");
            strcat(s, config_hdmi_clkdelay_msg[adv_clkdelay]);
            strcat(s, " ns  [");
            p = s + strlen(s);
            for (i = 0; i < 8; i++)
                *p++ = (i <= adv_clkdelay) ? '#' : '.';
            *p++ = ']';
            *p = 0;
        }
        OsdWrite(4, s, 0, 0);
        // What the chip really holds: ff = no answer on the bus
        {
            static const char hex[] = "0123456789abcdef";
            unsigned char rb = adv7511_read_clkdelay();
            unsigned char wr = adv_clkdelay << 5;
            strcpy(s, "   Chip 0xBA: xx  set: xx");
            s[14] = hex[rb >> 4];
            s[15] = hex[rb & 15];
            s[23] = hex[wr >> 4];
            s[24] = hex[wr & 15];
        }
        OsdWrite(5, s, 0, 0);
        {
            extern unsigned long adv_services;
            extern unsigned char adv_int_now;
            sprintf(s, "   INT %d  serviced %lu", adv_int_now, adv_services);
        }
        OsdWrite(6, s, 0, 0);
        OsdWrite(7, STD_BACK, menusub == 2, 0);

        menustate = MENU_SETTINGS_HDMI2;
        break;

    case MENU_SETTINGS_HDMI2:
        if (select)
        {
            if (menusub == 0 || menusub == 1)
            {
                if (menusub == 0 && adv_clkdelay < 7)
                    adv7511_set_clkdelay(adv_clkdelay + 1);
                else if (menusub == 1 && adv_clkdelay > 0)
                    adv7511_set_clkdelay(adv_clkdelay - 1);
                config.hdmi_clkdelay = adv_clkdelay + 1;  // saved with the config
                menustate = MENU_SETTINGS_HDMI1;
            }
            else if (menusub == 2)
            {
                menustate = MENU_MAIN2_1;
                menusub = 4;
            }
        }

        if (menu)
        {
            menustate = MENU_MAIN2_1;
            menusub = 4;
        }
        else if (right)
        {
            menustate = MENU_SETTINGS_CHIPSET1;
            menusub = 0;
        }
        else if (left)
        {
            menustate = MENU_SETTINGS_VIDEO3;
            menusub = 0;
        }
        break;

        /******************************************************************/
        /* video settings menu                                            */
        /******************************************************************/
    case MENU_SETTINGS_AUDIO1:
        // Sanity
        if (config.audio.volume > 31)
        {
            config.audio.volume = 15;
        }
        // setup menu
        helptext = helptexts[HELPTEXT_NONE];
        parentstate = menustate;
        // Enable/Disable selectable items
        menumask = 0x07;
        // if(config.audio.volume < 32) menumask |= 0x01;
        // if(config.audio.volume > 0) menumask |= 0x02;
        //  Items
        OsdSetTitle("Audio", OSD_ARROW_LEFT | OSD_ARROW_RIGHT);
        OsdWrite(0, "", 0, 0);
        OsdWrite(1, "Volume +", menusub == 0, 0);
        OsdWrite(2, "Volume -", menusub == 1, 0);
        OsdWrite(3, "", 0, 0);
        OsdWrite(4, "", 0, 0);
        strcpy(s, "   Volume : ");
        strcat(s, config_volume_msg[config.audio.volume]);
        strcat(s, " ");
        VolumeBar(config.audio.volume, volume_bar);
        strcat(s, volume_bar);
        OsdWrite(5, s, 0, 0);
        OsdWrite(6, "", 0, 0);
        OsdWrite(7, STD_BACK, menusub == 2, 0);

        menustate = MENU_SETTINGS_AUDIO2;

        break;

    case MENU_SETTINGS_AUDIO2:
        if (select)
        {
            // Volume up
            if (menusub == 0)
            {
                if (config.audio.volume != 31)
                    config.audio.volume++;
                ConfigAudio(config.audio.volume);
                menustate = MENU_SETTINGS_AUDIO1;
            }
            // Volume down
            if (menusub == 1)
            {
                if (config.audio.volume != 0)
                    config.audio.volume--;
                ConfigAudio(config.audio.volume);
                menustate = MENU_SETTINGS_AUDIO1;
            }
            if (menusub == 2)
            {
                menustate = MENU_MAIN2_1;
                menusub = 4;
            }
        }

        if (menu)
        {
            menustate = MENU_MAIN2_1;
            menusub = 4;
        }
        else if (right)
        {
            menustate = MENU_SETTINGS_VIDEO1;
            menusub = 0;
        }
        else if (left)
        {
            menustate = MENU_SETTINGS_MEMORY1;
            menusub = 0;
        }

        break;

        /******************************************************************/
        /* rom file selected menu                                         */
        /******************************************************************/
    case MENU_ROMFILE_SELECTED:

        menusub = 1;
        menustate = MENU_ROMFILE_SELECTED1;
        // no break intended

    case MENU_ROMFILE_SELECTED1:
        helptext = helptexts[HELPTEXT_NONE];
        OsdColor(OSDCOLOR_WARNING);
        menumask = 0x03;
        parentstate = menustate;
        OsdSetTitle("Confirm", 0);
        OsdWrite(0, "", 0, 0);
        OsdWrite(1, "       Reload Kickstart?", 0, 0);
        OsdWrite(2, "", 0, 0);
        OsdWrite(3, "              yes", menusub == 0, 0);
        OsdWrite(4, "              no", menusub == 1, 0);
        OsdWrite(5, "", 0, 0);
        OsdWrite(6, "", 0, 0);
        OsdWrite(7, "", 0, 0);

        menustate = MENU_ROMFILE_SELECTED2;
        break;

    case MENU_ROMFILE_SELECTED2:

        if (select)
        {
            if (menusub == 0)
            {
                memcpy((void *)config.kickstart.name, (void *)file.name, sizeof(config.kickstart.name));
                memcpy((void *)config.kickstart.long_name, (void *)file.long_name, sizeof(config.kickstart.long_name));
                config.kickdir = CurrentDirectory();

                OsdWrite(7, "           Loading...", 0, 0);

                OsdDoReset(0, SPI_RST_CPU | SPI_CPU_HLT);

                ApplyConfiguration(1, 0);
                //				UploadKickstart(config.kickstart.name);
                OsdHide();
                OsdDoReset(SPI_RST_USR | SPI_RST_CPU, 0);

                menustate = MENU_NONE1;
            }
            else if (menusub == 1)
            {
                menustate = MENU_SETTINGS_MEMORY1;
                menusub = 4;
            }
        }

        if (menu)
        {
            menustate = MENU_SETTINGS_MEMORY1;
            menusub = 4;
        }
        break;

        /******************************************************************/
        /* error message menu                                             */
        /******************************************************************/
    case MENU_ERROR:
        menumask = 0x01;
        parentstate = MENU_ERROR;

        OsdSetTitle("Error", OSD_ARROW_LEFT | OSD_ARROW_RIGHT);
        OsdWrite(0, ErrorFatal ? "      *** FATAL ERROR ***" : "         *** ERROR ***", 1, 0);
        OsdWrite(1, "", 0, !(ErrorMask & (1 << errorpage)));
        snprintf(s, 32, " %s", ErrorMessages[errorpage]);
        OsdWrite(2, s, 0, !(ErrorMask & (1 << errorpage)));
        snprintf(s, 32, " %s", Errors[errorpage].string);
        OsdWrite(3, s, 0, !(ErrorMask & (1 << errorpage)));
        snprintf(s, 32, " %X", Errors[errorpage].a);
        OsdWrite(4, s, 0, !(ErrorMask & (1 << errorpage)));
        snprintf(s, 32, " %X", Errors[errorpage].b);
        OsdWrite(5, s, 0, !(ErrorMask & (1 << errorpage)));
        OsdWrite(6, "", 0, 0);
        OsdWrite(7, ErrorFatal ? "           Reboot" : "             OK", 1, 0);

        menustate = MENU_ERROR2;
        break;

    case MENU_ERROR2:
        menustate = MENU_ERROR;
        if (left)
        {
            --errorpage;
            if (errorpage < 0)
                errorpage = ERROR_MAX;
        }
        if (right)
        {
            ++errorpage;
            if (errorpage > ERROR_MAX)
                errorpage = 0;
        }
        if (select)
        {
            OsdHide();
            // A ROM error means there is no usable Kickstart in RAM and the
            // CPU is being held, so dismissing it has to retry the boot --
            // otherwise the only way out is the board reset button.  A fatal
            // error retries for the same reason.
            if (ErrorFatal || (ErrorMask & (1 << ERROR_ROM)))
                ColdBoot();     // does its own ClearError(ERROR_ALL)
            else
                // Nothing else clears it.  main()'s error loop spins on
                // `while(ErrorMask)', so a flag left set there keeps the 832
                // out of its main loop for good: drive sounds, the RTC and the
                // HDMI re-init poll never run again, and the error is latched
                // until the board is reset.
                ClearError(ERROR_ALL);
            menustate = MENU_NONE1;
        }
        break;

        /******************************************************************/
        /* popup info menu                                                */
        /******************************************************************/
    case MENU_INFO:

        if (menu)
            menustate = MENU_MAIN1;
        else if (CheckTimer(menu_timer))
            menustate = MENU_NONE1;

        break;

        /******************************************************************/
        /* we should never come here                                      */
        /******************************************************************/
    default:

        break;
    }
}

void ScrollLongName(void)
{
    // this function is called periodically when file selection window is displayed
    // it checks if predefined period of time has elapsed and scrolls the name if necessary

    char k = sort_table[iSelectedEntry];
    static int len;
    int max_len;

    if (DirEntryLFN[k][0]) // && CheckTimer(scroll_timer)) // scroll if long name and timer delay elapsed
    {
        // FIXME - yuk, we don't want to do this every frame!
        len = strlen(DirEntryLFN[k]); // get name length

        if (len > 4)
            if (DirEntryLFN[k][len - 4] == '.')
                len -= 4; // remove extension

        max_len = 30; // number of file name characters to display (one more required for scrolling)
        if (DirEntry[k].Attributes & ATTR_DIRECTORY)
            max_len = 25; // number of directory name characters to display

        ScrollText(iSelectedEntry, DirEntryLFN[k], len, max_len, 1);
    }
}

char *GetDiskInfo(char *lfn, long len)
{
    // extracts disk number substring form file name
    // if file name contains "X of Y" substring where X and Y are one or two digit number
    // then the number substrings are extracted and put into the temporary buffer for further processing
    // comparision is case sensitive

    short i, k;
    static char info[] = "XX/XX";     // temporary buffer
    static char template[4] = " of "; // template substring to search for
    char *ptr1, *ptr2, c;
    unsigned char cmp;

    if (len > 20) // scan only names which can't be fully displayed
    {
        for (i = (unsigned short)len - 1 - sizeof(template); i > 0; i--) // scan through the file name starting from its end
        {
            ptr1 = &lfn[i]; // current start position
            ptr2 = template;
            cmp = 0;
            for (k = 0; k < sizeof(template); k++) // scan through template
            {
                cmp |= *ptr1++ ^ *ptr2++; // compare substrings' characters one by one
                if (cmp)
                    break; // stop further comparing if difference already found
            }

            if (!cmp) // match found
            {
                k = i - 1; // no need to check if k is valid since i is greater than zero

                c = lfn[k];               // get the first character to the left of the matched template substring
                if (c >= '0' && c <= '9') // check if a digit
                {
                    info[1] = c;   // copy to buffer
                    info[0] = ' '; // clear previous character
                    k--;           // go to the preceding character
                    if (k >= 0)    // check if index is valid
                    {
                        c = lfn[k];
                        if (c >= '0' && c <= '9') // check if a digit
                            info[0] = c;          // copy to buffer
                    }

                    k = i + sizeof(template); // get first character to the right of the mached template substring
                    c = lfn[k];               // no need to check if index is valid
                    if (c >= '0' && c <= '9') // check if a digit
                    {
                        info[3] = c;   // copy to buffer
                        info[4] = ' '; // clear next char
                        k++;           // go to the followwing character
                        if (k < len)   // check if index is valid
                        {
                            c = lfn[k];
                            if (c >= '0' && c <= '9') // check if a digit
                                info[4] = c;          // copy to buffer
                        }
                        return info;
                    }
                }
            }
        }
    }
    return NULL;
}

// print directory contents
void PrintDirectory(void)
{
    unsigned char i;
    unsigned char k;
    unsigned long len;
    char *lfn;
    char *info;
    char *p;
    unsigned char j;

    s[32] = 0; // set temporary string length to OSD line length

    ScrollReset();

    for (i = 0; i < 8; i++)
    {
        memset(s, ' ', 32); // clear line buffer
        if (i < nDirEntries)
        {
            k = sort_table[i];      // ordered index in storage buffer
            lfn = DirEntryLFN[k];   // long file name pointer
            DirEntryInfo[i][0] = 0; // clear disk number info buffer

            if (lfn[0]) // item has long name
            {
                len = strlen(lfn); // get name length
                info = NULL;       // no disk info

                if (!(DirEntry[k].Attributes & ATTR_DIRECTORY)) // if a file
                {
                    if (len > 4)
                        if (lfn[len - 4] == '.')
                            len -= 4; // remove extension

                    info = GetDiskInfo(lfn, len); // extract disk number info

                    if (info != NULL)
                        memcpy(DirEntryInfo[i], info, 5); // copy disk number info if present
                }

                if (len > 30)
                    len = 30; // trim display length if longer than 30 characters

                if (i != iSelectedEntry && info != NULL)
                {                                     // display disk number info for not selected items
                    strncpy(s + 1, lfn, 30 - 6);      // trimmed name
                    strncpy(s + 1 + 30 - 5, info, 5); // disk number
                }
                else
                    strncpy(s + 1, lfn, len); // display only name
            }
            else // no LFN
            {
                strncpy(s + 1, (const char *)DirEntry[k].Name, 8); // if no LFN then display base name (8 chars)
                if (DirEntry[k].Attributes & ATTR_DIRECTORY && DirEntry[k].Extension[0] != ' ')
                {
                    p = (char *)&DirEntry[k].Name[7];
                    j = 8;
                    do
                    {
                        if (*p-- != ' ')
                            break;
                    } while (--j);

                    s[1 + j++] = '.';
                    strncpy(s + 1 + j, (const char *)DirEntry[k].Extension, 3); // if no LFN then display base name (8 chars)
                }
            }

            if (DirEntry[k].Attributes & ATTR_DIRECTORY) // mark directory with suffix
                strcpy(&s[22], " <DIR>");
        }
        else
        {
            if (i == 0 && nDirEntries == 0) // selected directory is empty
                strcpy(s, "          No files!");
        }

        OsdWrite(i, s, i == iSelectedEntry, 0); // display formatted line text
    }
}

void _strncpy(char *pStr1, const char *pStr2, size_t nCount)
{
    // customized strncpy() function to fill remaing destination string part with spaces

    while (*pStr2 && nCount)
    {
        *pStr1++ = *pStr2++; // copy strings
        nCount--;
    }

    while (nCount--)
        *pStr1++ = ' '; // fill remaining space with spaces
}

// insert floppy image pointed to to by global <file> into <drive>
void InsertFloppy(adfTYPE *drive)
{
    unsigned char i, j;
    unsigned long tracks;

    // calculate number of tracks in the ADF image file
    tracks = file.size / (512 * 11);
    if (tracks > MAX_TRACKS)
    {
        SetError(ERROR_FDD, "ADF has too many tracks!", tracks, 0);
        printf("UNSUPPORTED ADF SIZE!!! Too many tracks: %lu\r", tracks);
        tracks = MAX_TRACKS;
    }
    drive->tracks = (unsigned char)tracks;

    // fill index cache
    for (i = 0; i < tracks; i++) // for every track get its start position within image file
    {
        drive->cache[i] = file.cluster; // start of the track within image file
        for (j = 0; j < 11; j++)
            FileNextSector(&file); // advance by track length (11 sectors)
    }

    // copy image file name into drive struct
    if (file.long_name[0])                                          // file has long name
        _strncpy(drive->name, file.long_name, sizeof(drive->name)); // copy long name
    else
    {
        strncpy(drive->name, file.name, 8);                    // copy base name
        memset(&drive->name[8], ' ', sizeof(drive->name) - 8); // fill the rest of the name with spaces
    }

    if (DiskInfo[0]) // if selected file has valid disk number info then copy it to its name in drive struct
    {
        drive->name[16] = ' ';                                 // precede disk number info with space character
        strncpy(&drive->name[17], DiskInfo, sizeof(DiskInfo)); // copy disk number info
    }

    // initialize the rest of drive struct
    drive->status = DSK_INSERTED;
    if (!(file.attributes & ATTR_READONLY)) // read-only attribute
        drive->status |= DSK_WRITABLE;

    drive->cluster_offset = drive->cache[0];
    drive->sector_offset = 0;
    drive->track = 0;
    drive->track_prev = -1;

    // some debug info
    if (file.long_name[0])
        printf("Inserting floppy: \"%s\"\r", file.long_name);
    else
        printf("Inserting floppy: \"%.11s\"\r", file.name);

    printf("file attributes: 0x%02X\r", file.attributes);
    printf("file size: %lu (%lu KB)\r", file.size, file.size >> 10);
    printf("drive tracks: %u\r", drive->tracks);
    printf("drive status: 0x%02X\r", drive->status);
    drivesounds_queueevent(DRIVESOUND_INSERT);
}

/*  Error Message */
void ErrorMessage(char *message, unsigned char code)
{
    menustate = MENU_ERROR;
    OsdShow(DISABLE_KEYBOARD); // do not disable KEYBOARD
    OsdColor(OSDCOLOR_WARNING);
}

void ShowError(void)
{
    int t = ErrorMask >> 1;
    errorpage = 0;
    while (t)
    {
        t >>= 1;
        ++errorpage;
    }
    menustate = MENU_ERROR;
    OsdShow(DISABLE_KEYBOARD);
    OsdColor(OSDCOLOR_WARNING);
}

void InfoMessage(char *message)
{
    OsdWaitVBL();
    if (menustate != MENU_INFO)
    {
        //        OsdClear();
        OsdSetTitle("Message", 0);
        OsdShow(0); // do not disable keyboard
        OsdShow(OSDCOLOR_TOPLEVEL);
    }
    OsdWrite(0, "", 0, 0);
    OsdWrite(1, message, 0, 0);
    OsdWrite(2, "", 0, 0);
    OsdWrite(3, "", 0, 0);
    OsdWrite(4, "", 0, 0);
    OsdWrite(5, "", 0, 0);
    OsdWrite(6, "", 0, 0);
    OsdWrite(7, "", 0, 0);
    menu_timer = GetTimer(1000);
    menustate = MENU_INFO;
}

static int shiftcheck(int in)
{
    return (in >> 1);
}

static int mulcheck(int in)
{
    return (in * 0x88888888);
}

static int addcheck(int in)
{
    return (in + 0xa5a5a5a5);
}

void SanityCheck()
{
    snprintf(s, 32, "%X", shiftcheck(0xabcdef01));
    DebugMessage(s);
    snprintf(s, 32, "%X", shiftcheck(0x23456789));
    DebugMessage(s);
    snprintf(s, 32, "%X", mulcheck(0xabcdef01));
    DebugMessage(s);
    snprintf(s, 32, "%X", mulcheck(0x23456789));
    DebugMessage(s);
    snprintf(s, 32, "%X", addcheck(0xabcdef01));
    DebugMessage(s);
    snprintf(s, 32, "%X", addcheck(0x23456789));
    DebugMessage(s);
    snprintf(s, 32, "%X", checksum_pre);
    DebugMessage(s);
}

void DebugMessage(char *message)
{
    strncpy(&debuglines[debugptr * 32], message, 31);
    debuglines[debugptr * 32 + 31] = 0;
    debugptr = (debugptr + 1) & 7;
}

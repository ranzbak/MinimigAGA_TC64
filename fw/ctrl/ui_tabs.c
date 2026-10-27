/* ui_tabs: the new OSD menu's tabs and items (ui.h; plan 5's tab map).
 * Main and System work here; Storage, Video and Acceleration show their
 * values and hand over to the classic menu to change them (Phase 4 brings
 * them here: an item's kind UI_INFO -> UI_CYCLE and a set function). */
#include <string.h>

#include "hardware.h"
#include "fat.h"
#include "fdd.h"
#include "osd.h"
#include "fpga.h"
#include "config.h"
#include "cdrom.h"
#include "drivesounds.h"
#include "menu.h"
#include "menu_model.h"
#include "ui.h"

extern unsigned char drives;
extern adfTYPE df[4];
int ColdBoot(void);

int ui_cd_shown_track;      /* the track in the CD line's play mark, 0 = none */

static char tbuf[40];       /* value texts of this file */

static const char *const v_off_on[] = { "off", "on" };
static const char *const v_slots[] = { "Default", "1", "2", "3", "4" };

/* ---- Main: floppies ---- */

static unsigned char floppy_avail(unsigned char i)
{
	return i <= drives;
}

static const char *floppy_text(unsigned char i)
{
	size_t n;
	if (i > drives)
		return i <= config.floppy.drives ? "* active after reset *" : "not fitted (keypad + adds one)";
	if (!(df[i].status & DSK_INSERTED))
		return "* no disk *";
	/* the name without its padding, the padlock after it */
	n = sizeof(df[i].name);
	memcpy(tbuf, df[i].name, n);
	while (n && tbuf[n - 1] == ' ')
		n--;
	if (!(df[i].status & DSK_WRITABLE)) {
		tbuf[n++] = ' ';
		tbuf[n++] = 0x17;                        /* the padlock (font8x16.h) */
	}
	tbuf[n] = 0;
	return tbuf;
}

static void floppy_act(unsigned char i)
{
	if (df[i].status & DSK_INSERTED) {
		df[i].status = 0;
		drivesounds_queueevent(DRIVESOUND_EJECT);
		return;
	}
	df[i].status = 0;
	ui_fs_open(UI_FS_FLOPPY, i);
}

/* ---- Main: the CD-ROM drive ---- */

static unsigned char cd_avail(unsigned char arg)
{
	(void)arg;
	return CD_SLOT() >= 0;
}

static const char *cd_text(unsigned char arg)
{
	size_t n;
	(void)arg;
	ui_cd_shown_track = 0;
	if (CD_SLOT() < 0)
		return "not configured (Storage)";
	if (cd_msg_on)
		return cd_msg_text;
	if (!cdrom.unit.media)
		return "* no disc *";
	/* the name (25 at most), the play mark (note + track), the lock mark */
	ui_cd_shown_track = CD_PlayingTrack();
	n = strlen(cdrom.unit.name);
	if (n > 25)
		n = 25;
	memcpy(tbuf, cdrom.unit.name, n);
	if (ui_cd_shown_track) {
		tbuf[n++] = ' ';
		tbuf[n++] = 0x19;                         /* a note (font8x16.h) */
		tbuf[n++] = (char)('0' + ui_cd_shown_track / 10 % 10);
		tbuf[n++] = (char)('0' + ui_cd_shown_track % 10);
	}
	if (CD_Locked()) {
		tbuf[n++] = ' ';
		tbuf[n++] = 0x17;
	}
	tbuf[n] = 0;
	return tbuf;
}

static void cd_act(unsigned char arg)
{
	(void)arg;
	if (!cdrom.unit.media)
		ui_fs_open(UI_FS_CD, 0);
	else if (CD_Eject() == CD_LOCKED)   /* refused while the Amiga holds the lock (D5) */
		cd_locked_msg();
}

/* ---- Main: configuration files ---- */

static unsigned char load_slot, save_slot;

static unsigned char load_avail(unsigned char arg)
{
	(void)arg;
	return ui_cfg_mask != 0;
}

static unsigned char load_get(unsigned char arg)
{
	(void)arg;
	if (ui_cfg_mask && !(ui_cfg_mask & (1 << load_slot)))
		while (!(ui_cfg_mask & (1 << load_slot)))
			load_slot = (unsigned char)((load_slot + 1) % MM_CONFIG_SLOTS);
	return load_slot;
}

/* v is one step from the slot shown: go on in that direction to a slot
   that has a file */
static void load_set(unsigned char arg, unsigned char v)
{
	unsigned char fwd = v == (load_slot + 1) % MM_CONFIG_SLOTS;
	(void)arg;
	if (!ui_cfg_mask)
		return;
	while (!(ui_cfg_mask & (1 << v)))
		v = (unsigned char)(fwd ? (v + 1) % MM_CONFIG_SLOTS : (v + MM_CONFIG_SLOTS - 1) % MM_CONFIG_SLOTS);
	load_slot = v;
}

static const char *load_text(unsigned char arg)
{
	(void)arg;
	return ui_cfg_mask ? v_slots[load_get(0)] : "none saved";
}

static void load_done(unsigned char b)
{
	if (b)
		return;
	ui_toast("Loading configuration...");
	osd2_flush();
	mm_load_config(load_slot);
	ui_close();
}

static void load_act(unsigned char arg)
{
	static const char *const b[] = { "Load", "Cancel" };
	static char l1[32];
	(void)arg;
	strcpy(l1, "Load configuration ");
	strcat(l1, v_slots[load_get(0)]);
	strcat(l1, "?");
	ui_dialog("Load", l1, "The Amiga restarts with it.", b, 2, 0, load_done);
}

static unsigned char save_get(unsigned char arg)
{
	(void)arg;
	return save_slot;
}

static void save_set(unsigned char arg, unsigned char v)
{
	(void)arg;
	save_slot = v % MM_CONFIG_SLOTS;
}

static const char *save_text(unsigned char arg)
{
	(void)arg;
	strcpy(tbuf, v_slots[save_slot]);
	if (ui_cfg_mask & (1 << save_slot))
		strcat(tbuf, " (exists)");
	return tbuf;
}

static void save_now(void)
{
	mm_save_config(save_slot);
	ui_cfg_mask = mm_config_scan();
	ui_toast("Configuration saved");
}

static void save_done(unsigned char b)
{
	if (!b)
		save_now();
}

static void save_act(unsigned char arg)
{
	static const char *const b[] = { "Overwrite", "Cancel" };
	static char l1[32];
	(void)arg;
	if (!(ui_cfg_mask & (1 << save_slot))) {
		save_now();
		return;
	}
	strcpy(l1, "Configuration ");
	strcat(l1, v_slots[save_slot]);
	strcat(l1, " exists.");
	ui_dialog("Save", l1, "Overwrite it?", b, 2, 0, save_done);
}

/* ---- Main: reset, reboot, Chameleon, classic pages ---- */

static const char *const yes_no[] = { "Yes", "No" };
static unsigned char confirm_what;

static void confirm_done(unsigned char b)
{
	if (b)
		return;
	ui_close();
	if (confirm_what == 0)
		OsdReset();
	else if (confirm_what == 1)
		ColdBoot();
	else
		Reconfigure();
}

static void confirm_act(unsigned char what)
{
	static const char *const title[] = { "Reset", "Reboot", "Chameleon" };
	static const char *const l1[] = { "Reset the Amiga?", "Reboot the Amiga?", "Return to the Chameleon menu?" };
	static const char *const l2[] = { "", "The Kickstart is loaded again.", "" };
	confirm_what = what;
	ui_dialog(title[what], l1[what], l2[what], yes_no, 2, 0, confirm_done);
}

static unsigned char reconfig_avail(unsigned char arg)
{
	(void)arg;
	return (PLATFORM & (1 << PLATFORM_RECONFIG)) != 0;
}

/* the classic menu's pages the items hand over to: {page, cursor} */
static const unsigned char classic_pages[][2] = {
	{ MENU_MAIN1, 0 },               /* 0 Main */
	{ MENU_MAIN1, 5 },               /* 1 Storage: "Hard disk settings" on its main page */
	{ MENU_SETTINGS_VIDEO1, 0 },     /* 2 Video (Video Pos and HDMI to its right) */
	{ MENU_SETTINGS_CHIPSET1, 0 },   /* 3 Acceleration: CPU, Turbo, Chip slots */
	{ MENU_ABOUT1, 0 },              /* 4 */
	{ MENU_SUPPORTERS1, 0 },         /* 5 */
};

static void classic_act(unsigned char i)
{
	ui_classic(classic_pages[i][0], classic_pages[i][1]);
}

#define SEP { .kind = UI_SEP }

static const struct ui_item main_items[] = {
	{ "DF0", "Floppy drive 0. Enter inserts a disk image (ADF) or ejects it. Backspace ejects all; keypad + and - add or remove drives.",
	  .text = floppy_text, .act = floppy_act, .avail = floppy_avail, .kind = UI_ACTION, .arg = 0 },
	{ "DF1", "Floppy drive 1. Enter inserts or ejects. Keypad + and - add or remove drives (after a reset).",
	  .text = floppy_text, .act = floppy_act, .avail = floppy_avail, .kind = UI_ACTION, .arg = 1 },
	{ "DF2", "Floppy drive 2. Enter inserts or ejects. Keypad + and - add or remove drives (after a reset).",
	  .text = floppy_text, .act = floppy_act, .avail = floppy_avail, .kind = UI_ACTION, .arg = 2 },
	{ "DF3", "Floppy drive 3. Enter inserts or ejects. Keypad + and - add or remove drives (after a reset).",
	  .text = floppy_text, .act = floppy_act, .avail = floppy_avail, .kind = UI_ACTION, .arg = 3 },
	{ "CD", "The CD-ROM drive. Enter inserts an ISO or CUE image, or ejects the disc (not while the Amiga locks it). Set up in Storage.",
	  .text = cd_text, .act = cd_act, .avail = cd_avail, .kind = UI_ACTION },
	SEP,
	{ "Load configuration", "Left/Right choose a saved configuration, Enter loads it. The Amiga restarts with it.",
	  .get = load_get, .set = load_set, .text = load_text, .act = load_act, .avail = load_avail,
	  .kind = UI_CYCLE, .nvalues = MM_CONFIG_SLOTS, .flags = UI_ENTERACT },
	{ "Save configuration", "Left/Right choose the slot, Enter saves the settings there (asks before overwriting). Default is loaded at power-on.",
	  .get = save_get, .set = save_set, .text = save_text, .act = save_act,
	  .kind = UI_CYCLE, .nvalues = MM_CONFIG_SLOTS, .flags = UI_ENTERACT },
	SEP,
	{ "Reset", "Resets the Amiga. Disks stay inserted.", .act = confirm_act, .kind = UI_ACTION, .arg = 0, .flags = UI_SUB },
	{ "Reboot", "Restarts the whole machine and loads the Kickstart again.", .act = confirm_act, .kind = UI_ACTION, .arg = 1, .flags = UI_SUB },
	{ "Return to Chameleon", "Leaves this core for the Chameleon menu.", .act = confirm_act, .avail = reconfig_avail,
	  .kind = UI_ACTION, .arg = 2, .flags = UI_HIDE | UI_SUB },
	SEP,
	{ "About", "Who made this (the classic page).", .act = classic_act, .kind = UI_ACTION, .arg = 4, .flags = UI_SUB },
	{ "Supporters", "Thanks (the classic page).", .act = classic_act, .kind = UI_ACTION, .arg = 5, .flags = UI_SUB },
	{ "Classic menu", "The previous OSD menu, with every setting. Esc there comes back here.",
	  .act = classic_act, .kind = UI_ACTION, .arg = 0, .flags = UI_SUB },
};

/* ---- System ---- */

static const char *const v_chipset[] = { "OCS-A500", "OCS-A1000", "ECS", "AGA" };
static const char *const v_video[] = { "PAL", "NTSC" };
static const char *const v_chip[] = { "0.5 MB", "1.0 MB", "1.5 MB", "2.0 MB" };
static const char *const v_slow[] = { "none", "0.5 MB", "1.0 MB", "1.5 MB" };
static const char *const v_fast[] = { "none", "2.0 MB", "4.0 MB", "maximum" };
static const char *const v_boards[] = { "all", "DDR3 only" };
static const char *const v_hrtmon[] = { "disabled", "enabled" };
static const char *const v_autofire[] = { "off", "fast", "medium", "slow" };

static void kick_act(unsigned char arg)
{
	(void)arg;
	ui_fs_open(UI_FS_KICK, 0);
}

static const struct ui_item system_items[] = {
	{ "Chipset", "OCS (A500 or A1000), ECS or AGA. Takes full effect after a reset: leaving System offers one.",
	  .values = v_chipset, .get = mm_get_chipset, .set = mm_set_chipset, .kind = UI_CYCLE, .nvalues = 4 },
	{ "Video standard", "PAL (50 Hz) or NTSC (60 Hz).",
	  .values = v_video, .get = mm_get_field, .set = mm_set_field, .kind = UI_CYCLE, .arg = MMF_NTSC, .nvalues = 2 },
	SEP,
	{ "Chip RAM", "Chip memory (graphics, sound, the custom chips). Memory changes need a reset: leaving System offers one.",
	  .values = v_chip, .get = mm_get_field, .set = mm_set_field, .kind = UI_CYCLE, .arg = MMF_CHIP, .nvalues = 4 },
	{ "Slow RAM", "Memory at 0xC00000 (A500 trapdoor style). Needs a reset.",
	  .values = v_slow, .get = mm_get_field, .set = mm_set_field, .kind = UI_CYCLE, .arg = MMF_SLOW, .nvalues = 4 },
	{ "Fast RAM", "Fast memory for the CPU. Needs a reset.",
	  .values = v_fast, .get = mm_get_field, .set = mm_set_field, .kind = UI_CYCLE, .arg = MMF_FAST, .nvalues = 4 },
	{ "Fast-RAM boards", "Which fast-RAM boards autoconfig offers. DDR3 only puts every fast-RAM allocation on the DDR3 board. Needs a reset.",
	  .values = v_boards, .get = mm_get_field, .set = mm_set_field, .kind = UI_CYCLE, .arg = MMF_BOARDS, .nvalues = 2 },
	{ "HRTmon", "The HRTmon debugger/monitor. Needs a reset.",
	  .values = v_hrtmon, .get = mm_get_field, .set = mm_set_field, .kind = UI_CYCLE, .arg = MMF_HRTMON, .nvalues = 2 },
	{ "Kickstart ROM", "Enter chooses a Kickstart ROM image on the card. Loading it restarts the Amiga.",
	  .text = mm_text_kickstart, .act = kick_act, .kind = UI_ACTION, .flags = UI_SUB },
	SEP,
	{ "CD32 pad", "Joystick port 2 as a CD32 game pad.",
	  .values = v_off_on, .get = mm_get_field, .set = mm_set_field, .kind = UI_CYCLE, .arg = MMF_CD32PAD, .nvalues = 2 },
	{ "Autofire", "Autofire rate of the fire button (also Ctrl-Alt-keypad 0 with the menu closed).",
	  .values = v_autofire, .get = mm_get_field, .set = mm_set_field, .kind = UI_CYCLE, .arg = MMF_AUTOFIRE, .nvalues = 4 },
	{ "Volume", "The audio volume, 0-31 (also LShift and keypad + or -).",
	  .get = mm_get_volume, .set = mm_set_volume, .kind = UI_CYCLE, .nvalues = 32, .flags = UI_CLAMP | UI_BAR },
};

/* ---- Storage, Video, Acceleration: shown here, changed in the classic menu ---- */

static const char *const v_scanlines[] = { "off", "dim", "black", "off" };
static const char *const v_scaling[] = { "sharp", "area", "line rate", "sharp" };
static const char *const v_mask[] = { "off", "grille", "grille+", "shadow" };
static const char *const v_bloom[] = { "off", "low", "high" };
static const char *const v_beam[] = { "off", "sharp", "medium", "soft" };
static const char *const v_turbo[] = { "none", "CHIPRAM", "KICK", "BOTH" };
static const char *const v_chipslots[] = { "Standard", "Fast" };

static unsigned char sounds_avail(unsigned char arg)
{
	(void)arg;
	return drivesounds_loaded() != 0;
}

static unsigned char ide2_avail(unsigned char arg)
{
	(void)arg;
	return (core_caps & CORE_CAPS_IDE2) != 0;
}

#define INFO_V(l, h, vals, g, a, n) { l, h, .values = vals, .get = g, .kind = UI_INFO, .arg = a, .nvalues = n }
#define INFO_T(l, h, t, a) { l, h, .text = t, .kind = UI_INFO, .arg = a }

static const struct ui_item storage_items[] = {
	INFO_T("Floppy drives", "How many floppy drives the Amiga has (keypad + and - on Main).", mm_text_drives, 0),
	INFO_V("Floppy turbo", "Faster floppy reads than a real drive.", v_off_on, mm_get_field, MMF_FLOPPYTURBO, 2),
	{ "Floppy sounds", "Drive noises for the floppies (needs the drive sounds file on the card).",
	  .values = v_off_on, .get = mm_get_sound, .avail = sounds_avail, .kind = UI_INFO, .arg = DRIVESOUNDS_FLOPPY, .nvalues = 2 },
	SEP,
	INFO_V("IDE", "The Gayle IDE controller (hard disks, CD-ROM). Changes need a reset.", v_off_on, mm_get_field, MMF_IDE, 2),
	INFO_T("Port 1 master", "What the first IDE drive is: a hardfile, the SD card or a partition of it, or the CD-ROM.", mm_text_hdf_type, 0),
	INFO_T("  file", "The image file of the drive above.", mm_text_hdf_file, 0),
	INFO_T("Port 1 slave", "What the second IDE drive is.", mm_text_hdf_type, 1),
	INFO_T("  file", "The image file of the drive above.", mm_text_hdf_file, 1),
	{ "Port 2 master", "IDE port 2 (needs AtapiMagic or IDEfix97 on the Amiga; not bootable).",
	  .text = mm_text_hdf_type, .avail = ide2_avail, .kind = UI_INFO, .arg = 2, .flags = UI_HIDE },
	{ "  file", "The image file of the drive above.", .text = mm_text_hdf_file, .avail = ide2_avail, .kind = UI_INFO, .arg = 2, .flags = UI_HIDE },
	{ "Port 2 slave", "IDE port 2, second drive.", .text = mm_text_hdf_type, .avail = ide2_avail, .kind = UI_INFO, .arg = 3, .flags = UI_HIDE },
	{ "  file", "The image file of the drive above.", .text = mm_text_hdf_file, .avail = ide2_avail, .kind = UI_INFO, .arg = 3, .flags = UI_HIDE },
	{ "Hard disk sounds", "Drive noises for the hard disks.",
	  .values = v_off_on, .get = mm_get_sound, .avail = sounds_avail, .kind = UI_INFO, .arg = DRIVESOUNDS_HDD, .nvalues = 2 },
	SEP,
	{ "Open classic menu", "Changes the drives in the classic menu (its main page: Floppy and Hard disk settings).",
	  .act = classic_act, .kind = UI_ACTION, .arg = 1, .flags = UI_SUB },
};

static const struct ui_item video_items[] = {
	INFO_V("Scanlines", "Dark lines between the picture's lines, as on a CRT.", v_scanlines, mm_get_field, MMF_SCANLINES, 4),
	INFO_V("Scaling", "How the picture is scaled to 720p: sharp, area (smooth), or line rate.", v_scaling, mm_get_scaling, 0, 4),
	INFO_V("CRT mask", "The phosphor mask of a CRT.", v_mask, mm_get_field, MMF_MASK, 4),
	INFO_V("Bloom", "Bright parts glow into their neighbours.", v_bloom, mm_get_bloom, 0, 3),
	INFO_V("Beam width", "The width of the CRT beam spot.", v_beam, mm_get_field, MMF_BEAM, 4),
	SEP,
	INFO_T("Horizontal pos", "Moves the picture left or right (HD pixels).", mm_text_pos, 0),
	INFO_T("Vertical pos", "Moves the picture up or down (Amiga lines).", mm_text_pos, 1),
	INFO_T("HDMI clock delay", "Where the HDMI transmitter samples the pixel data. Sparkles mean too close to an edge.", mm_text_clkdelay, 0),
	SEP,
	{ "Open classic menu", "Changes these in the classic menu (Video; Right: Video Pos, HDMI).",
	  .act = classic_act, .kind = UI_ACTION, .arg = 2, .flags = UI_SUB },
};

static const struct ui_item accel_items[] = {
	INFO_T("CPU", "The CPU the Amiga has.", mm_text_cpu, 0),
	INFO_V("Turbo", "Chip RAM and/or Kickstart ROM at fast-RAM speed for the CPU.", v_turbo, mm_get_field, MMF_TURBO, 4),
	INFO_V("Chip slots", "Standard: the 7 MHz machine. Fast: a chip cycle ends with its slot (the AGA rate).", v_chipslots, mm_get_field, MMF_CHIPSLOTS, 2),
	SEP,
	{ "Open classic menu", "Changes these in the classic menu (its Chipset page).",
	  .act = classic_act, .kind = UI_ACTION, .arg = 3, .flags = UI_SUB },
};

#define N(a) (sizeof(a) / sizeof((a)[0]))

/* the icons' colours: osd_icons.h (house, floppy, chip, monitor, bolt) */
const struct ui_tab ui_tabs[UI_TABS] = {
	{ "Main", "Floppies, the CD-ROM, configurations, reset.", main_items, N(main_items), OSD2_C_YELLOW },
	{ "Storage", "Floppy and hard disk drives (shown here; changed in the classic menu for now).", storage_items, N(storage_items), OSD2_C_WHITE },
	{ "System", "Chipset, memory, Kickstart, joystick, volume.", system_items, N(system_items), OSD2_C_GREEN },
	{ "Video", "The HDMI picture (shown here; changed in the classic menu for now).", video_items, N(video_items), OSD2_C_WHITE },
	{ "Acceleration", "CPU and chip-bus speed (shown here; changed in the classic menu for now).", accel_items, N(accel_items), OSD2_C_RED },
};

/* ui_tabs: the new OSD menu's tabs and items (ui.h; plan 5's tab map).
 * Every setting of the classic menu is here (OSD redesign Phase 4); Main's
 * About and Supporters are pages of their own (ui_about.c, ui_supporters.c). */
#include <string.h>

#include "hardware.h"
#include "fat.h"
#include "fdd.h"
#include "osd.h"
#include "fpga.h"
#include "config.h"
#include "cdrom.h"
#include "drivesounds.h"
#include "hdd.h"
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

/* ---- Main: reset, reboot, Chameleon ---- */

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
	{ "About", "Who made Minimig AGA: the credits, over a starfield.",
	  .act = ui_page_open, .kind = UI_ACTION, .arg = UI_PAGE_ABOUT, .flags = UI_SUB },
	{ "Supporters", "The supporters of this core, and how to support it, over a plasma.",
	  .act = ui_page_open, .kind = UI_ACTION, .arg = UI_PAGE_SUPPORTERS, .flags = UI_SUB },
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

/* ---- Storage: the floppies (applied at once), the IDE slots (an edit
   copy, mm_hdf: leaving the tab after a change offers the reset that
   applies it, ui.c leave_check) ---- */

static const char *const v_drives[] = { "1", "2", "3", "4" };

static unsigned char sounds_avail(unsigned char arg)
{
	(void)arg;
	return drivesounds_loaded() != 0;
}

/* the IDE slots' items: greyed while IDE is off (the classic page) */
static unsigned char ide_avail(unsigned char arg)
{
	(void)arg;
	return mm_ide_on != 0;
}

/* a slot's file: a hardfile or a CD slot, IDE on */
static unsigned char hdf_file_avail(unsigned char slot)
{
	unsigned char e = mm_hdf[slot].enabled;
	return mm_ide_on && ((e & HDF_TYPEMASK) == HDF_FILE || e == HDF_CDROM);
}

/* the type: Right the classic cycle, Left the cycle backwards (the type
   whose next is the current one) */
static void hdf_type_step(unsigned char slot, int dir)
{
	unsigned char cur = mm_hdf[slot].enabled, e = cur, k;
	if (dir > 0) {
		mm_hdf_next_type(slot);
		return;
	}
	for (k = 0; k < 16; k++) {
		unsigned char nx = mm_hdf_type_after(slot, e);
		if (nx == cur)
			break;
		e = nx;
	}
	if (e != cur)
		mm_hdf_set_type(slot, e);
}

static void hdf_file_act(unsigned char slot)
{
	ui_fs_open(mm_hdf[slot].enabled == HDF_CDROM ? UI_FS_HDCD : UI_FS_HDF, slot);
}

#define HDF_TYPE(l, h, s, f) { l, h, .text = mm_text_hdf_type, .avail = ide_avail, .step = hdf_type_step, \
                               .kind = UI_CYCLE, .arg = s, .flags = f }
#define HDF_FILE_(h, s, f) { "  file", h, .text = mm_text_hdf_file, .act = hdf_file_act, .avail = hdf_file_avail, \
                             .kind = UI_ACTION, .arg = s, .flags = (f) | UI_SUB }

static const struct ui_item storage_items[] = {
	{ "Floppy drives", "How many floppy drives the Amiga has (also keypad + and - on Main). More drives need a reset.",
	  .values = v_drives, .get = mm_get_field, .set = mm_set_field, .kind = UI_CYCLE, .arg = MMF_DRIVES, .nvalues = 4 },
	{ "Floppy turbo", "Faster floppy reads than a real drive.",
	  .values = v_off_on, .get = mm_get_field, .set = mm_set_field, .kind = UI_CYCLE, .arg = MMF_FLOPPYTURBO, .nvalues = 2 },
	{ "Floppy sounds", "Drive noises for the floppies (needs the drive sounds file on the card).",
	  .values = v_off_on, .get = mm_get_sound, .set = mm_set_sound, .avail = sounds_avail,
	  .kind = UI_CYCLE, .arg = DRIVESOUNDS_FLOPPY, .nvalues = 2 },
	SEP,
	{ "IDE", "The Gayle IDE controller (hard disks, CD-ROM). A change here or below takes effect with the reset offered on leaving.",
	  .values = v_off_on, .get = mm_get_ide, .set = mm_set_ide, .kind = UI_CYCLE, .nvalues = 2 },
	HDF_TYPE("Port 1 master", "The first IDE drive: a hardfile (with a partition table, or one filesystem), the SD card or a partition.", 0, 0),
	HDF_FILE_("The image file of the drive above. Enter chooses one (HDF; ISO or CUE for a CD-ROM).", 0, 0),
	HDF_TYPE("Port 1 slave", "The second IDE drive (types as the master).", 1, 0),
	HDF_FILE_("The image file of the drive above. Enter chooses one.", 1, 0),
	HDF_TYPE("Port 2 master", "IDE port 2 (needs AtapiMagic or IDEfix97 on the Amiga; not bootable). Also the CD-ROM drive.", 2, UI_IDE2),
	HDF_FILE_("The image file of the drive above. Enter chooses one (ISO or CUE for the CD-ROM).", 2, UI_IDE2),
	HDF_TYPE("Port 2 slave", "IDE port 2, second drive (needs AtapiMagic or IDEfix97; not bootable).", 3, UI_IDE2),
	HDF_FILE_("The image file of the drive above. Enter chooses one.", 3, UI_IDE2),
	{ "Hard disk sounds", "Drive noises for the hard disks (needs the drive sounds file on the card).",
	  .values = v_off_on, .get = mm_get_sound, .set = mm_set_sound, .avail = ide_avail,
	  .kind = UI_CYCLE, .arg = DRIVESOUNDS_HDD, .nvalues = 2 },
};

/* ---- Video ---- */

static const char *const v_scanlines[] = { "off", "dim", "black" };
static const char *const v_scaling[] = { "sharp", "area", "line rate" };
static const char *const v_mask[] = { "off", "grille", "grille+", "shadow" };
static const char *const v_bloom[] = { "off", "low", "high" };
static const char *const v_beam[] = { "off", "sharp", "medium", "soft" };

/* the position items edit the pair of the screen that is on (ui_rtg, read
   by ui.c when Video is shown and here at every step); their labels say
   which.  The labels are these buffers, "PAL" or "RTG" at POS_MODE. */
static char pos_h_label[] = "Position (PAL) horizontal";
static char pos_v_label[] = "Position (PAL) vertical";
#define POS_MODE 10

void ui_video_mode(void)
{
	const char *m = ui_rtg ? "RTG" : "PAL";
	memcpy(pos_h_label + POS_MODE, m, 3);
	memcpy(pos_v_label + POS_MODE, m, 3);
}

static const char *pos_text(unsigned char vertical)
{
	return mm_text_pos(vertical, ui_rtg);
}

static void pos_step(unsigned char vertical, int dir)
{
	ui_rtg = osd2_rtg_active();
	ui_video_mode();
	mm_step_pos(vertical, dir, ui_rtg);
}

static void clkdelay_step(unsigned char arg, int dir)
{
	(void)arg;
	mm_step_clkdelay(dir);
}

static char hdmi_help[128];

static const char *clkdelay_help(unsigned char arg)
{
	(void)arg;
	strcpy(hdmi_help, "The HDMI chip's sampling point (sparkles: too near an edge).\n");
	strcat(hdmi_help, mm_text_hdmi_readback());
	return hdmi_help;
}

/* the OSD menu itself (config.h CONFIG_OSD_*): live, the window moves at
   once (ui_window); Large / Small, Centre / Top / Bottom (3 shows Centre) */
static const char *const v_osdsize[] = { "large", "small" };
static const char *const v_osdpos[] = { "centre", "top", "bottom" };

static unsigned char osd_get(unsigned char arg)
{
	unsigned char v = mm_get_field(arg);
	return arg == MMF_OSDPOS && v > CONFIG_OSD_BOTTOM ? CONFIG_OSD_CENTRE : v;
}

static void osd_set(unsigned char arg, unsigned char v)
{
	mm_set_field(arg, v);
	ui_window();
}

static const struct ui_item video_items[] = {
	{ "Scanlines", "Dark lines between the picture's lines, as on a CRT.",
	  .values = v_scanlines, .get = mm_get_field, .set = mm_set_field, .kind = UI_CYCLE, .arg = MMF_SCANLINES, .nvalues = 3 },
	{ "Scaling", "How the picture is scaled to 720p: sharp or area (exactly 2.5x / 3x), or line rate.",
	  .values = v_scaling, .get = mm_get_scaling, .set = mm_set_scaling, .kind = UI_CYCLE, .nvalues = 3 },
	{ "CRT mask", "The phosphor mask of a CRT.",
	  .values = v_mask, .get = mm_get_field, .set = mm_set_field, .kind = UI_CYCLE, .arg = MMF_MASK, .nvalues = 4 },
	{ "Bloom", "Bright parts glow into the gaps between the lines (needs Scanlines, Beam width, or Scaling sharp or area).",
	  .values = v_bloom, .get = mm_get_bloom, .set = mm_set_bloom, .avail = mm_bloom_avail, .kind = UI_CYCLE, .nvalues = 3 },
	{ "Beam width", "The width of the CRT beam spot.",
	  .values = v_beam, .get = mm_get_field, .set = mm_set_field, .kind = UI_CYCLE, .arg = MMF_BEAM, .nvalues = 4 },
	SEP,
	{ pos_h_label, "Moves the picture left or right, 8 HD pixels a step. The RTG screen keeps its own position.",
	  .text = pos_text, .step = pos_step, .kind = UI_CYCLE, .arg = 0 },
	{ pos_v_label, "Moves the picture up or down, 2 Amiga lines a step. The RTG screen keeps its own position.",
	  .text = pos_text, .step = pos_step, .kind = UI_CYCLE, .arg = 1 },
	{ "HDMI clock delay", 0, .text = mm_text_clkdelay, .step = clkdelay_step, .helpf = clkdelay_help, .kind = UI_CYCLE },
	SEP,
	{ "OSD size", "This menu: large (1024 x 640 pixels) or small (512 x 320), the same text. Saved with the configuration.",
	  .values = v_osdsize, .get = osd_get, .set = osd_set, .kind = UI_CYCLE, .arg = MMF_OSDSIZE, .nvalues = 2 },
	{ "OSD position", "Where this menu sits on the screen: in the centre, at the top or at the bottom.",
	  .values = v_osdpos, .get = osd_get, .set = osd_set, .kind = UI_CYCLE, .arg = MMF_OSDPOS, .nvalues = 3 },
};

/* ---- Acceleration ---- */

static const char *const v_cpu[] = { "68000", "68010", "68020" };
static const char *const v_turbo[] = { "none", "CHIPRAM", "KICK", "BOTH" };
static const char *const v_chipslots[] = { "Standard", "Fast" };

/* a core with a fixed 68040: the line says so, greyed (the classic page) */
static unsigned char cpu_avail(unsigned char arg)
{
	(void)arg;
	return !CORE_CPU_FIXED_040();
}

static const struct ui_item accel_items[] = {
	{ "CPU", "The CPU the Amiga has (a core with the 68040 has only that).",
	  .values = v_cpu, .get = mm_get_cpu, .set = mm_set_cpu, .text = mm_text_cpu, .avail = cpu_avail,
	  .kind = UI_CYCLE, .nvalues = 3 },
	{ "Turbo", "Chip RAM and/or Kickstart ROM at fast-RAM speed for the CPU.",
	  .values = v_turbo, .get = mm_get_field, .set = mm_set_field, .kind = UI_CYCLE, .arg = MMF_TURBO, .nvalues = 4 },
	{ "Chip slots", "Standard: the 7 MHz machine. Fast: a chip cycle ends with its slot (the AGA rate).",
	  .values = v_chipslots, .get = mm_get_field, .set = mm_set_field, .kind = UI_CYCLE, .arg = MMF_CHIPSLOTS, .nvalues = 2 },
};

#define N(a) (sizeof(a) / sizeof((a)[0]))

/* the icons' colours: osd_icons.h (house, floppy, chip, monitor, bolt) */
const struct ui_tab ui_tabs[UI_TABS] = {
	{ "Main", "Floppies, the CD-ROM, configurations, reset.", main_items, N(main_items), OSD2_C_YELLOW },
	{ "Storage", "Floppy and hard disk drives.", storage_items, N(storage_items), OSD2_C_WHITE },
	{ "System", "Chipset, memory, Kickstart, joystick, volume.", system_items, N(system_items), OSD2_C_GREEN },
	{ "Video", "The HDMI picture: CRT effects, scaling, position, the HDMI clock.", video_items, N(video_items), OSD2_C_WHITE },
	{ "Acceleration", "CPU and chip-bus speed.", accel_items, N(accel_items), OSD2_C_RED },
};

/* migrate_test: the migration check of the OSD redesign (findings/
 * osd-redesign/plan.md Phase 4 "Done"): every setting the classic menu
 * offers, changed once through the classic menu (menu.c HandleUI_legacy,
 * osd2_caps 0) and once through the new one (ui.c, osd2_caps 1), from the
 * same start; the two runs must leave the same effect:
 *   - the config struct, byte for byte (212 bytes);
 *   - the Config* SPI byte stream to the core: every OSD frame whose
 *     command is a config register (0x04 chipset, 0x14 CPU, 0x24 memory,
 *     0x34 video, 0x44 floppy, 0x54/0x58 IDE, 0x64 joystick), from the real
 *     Config* functions of osd.c (cut out: osdcfg.inc), in order;
 *   - both Video Pos registers (VIDEOSCALE, VIDEOSCALE_RTG);
 *   - the calls with an effect, in order: resets (OsdReset, OsdDoReset,
 *     ColdBoot), the IDE apply (OpenHardfile, ApplyCDROM, ConfigIDEPorts),
 *     drive sounds, the audio volume, the HDMI clock delay, config files
 *     (Load, Save, Apply), the CD drive (CD_Insert, CD_Eject);
 *   - the floppy drives (df[], drives), adv_clkdelay.
 * The drawing of both menus is not compared (it differs by design): the
 * classic bitmap OSD is stubbed, the new menu draws on the real osd2.c into
 * the mock's SPI trace, whose text-layer frames (0x2C..0x5C), keyboard
 * frames (0x28) and VERSION reads (0x88) are left out.
 * The keys go in through the stub OsdGetCtrl, one per HandleUI() pass, each
 * followed by passes without a key until the menu has settled (the classic
 * menu draws a page in one pass and reads its keys in the next).
 * A RTG case (layer version 2, VERSION byte 14 = 1) checks that the new
 * menu then edits the RTG pair and only that: the one case whose effect
 * differs on purpose (the classic menu has no RTG pair).
 *   make -C fw/ctrl/test run-migrate_test
 */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "hardware.h"
#include "errors.h"
#include "fat.h"
#include "fdd.h"
#include "hdd.h"
#include "osd.h"
#include "fpga.h"
#include "config.h"
#include "cdrom.h"
#include "drivesounds.h"
#include "adv7511.h"
#include "audio.h"
#include "menu.h"
#include "menu_model.h"
#include "osd2.h"
#include "ui.h"
#include "mock_hw.h"

static int fails, cases;

static int check(const char *what, long got, long want)
{
	cases++;
	if (got != want) {
		printf("FAIL %s: got %ld, want %ld\n", what, got, want);
		fails++;
		return 0;
	}
	printf("ok   %s = %ld\n", what, got);
	return 1;
}

/* ---- the call log: calls with an effect ---- */
static char calls[8192];
static void logc(const char *fmt, ...)
{
	size_t n = strlen(calls);
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(calls + n, sizeof calls - n, fmt, ap);
	va_end(ap);
	n = strlen(calls);
	if (n + 1 < sizeof calls) {
		calls[n] = ';';
		calls[n + 1] = 0;
	}
}

/* ---- firmware state ---- */
configTYPE config;
fileTYPE file;
char s[40];
char DebugMode;
unsigned char DEBUG;
int checksum_pre;
const char version[] = "migrate_test";
unsigned char drives;
adfTYPE df[4];
cdromTYPE cdrom;
unsigned char core_caps;
unsigned char core_version[4];
const char fw_version[] = "";
unsigned char adv_clkdelay = 4;
unsigned long adv_services;
unsigned char adv_int_now;
unsigned long adv_status_hist;
unsigned char osd_keyq_lost;
DIRENTRY DirEntry[MAXDIRENTRIES];
char DirEntryLFN[MAXDIRENTRIES][261];
unsigned char sort_table[MAXDIRENTRIES];
unsigned char nDirEntries, iSelectedEntry;
unsigned long iCurrentDirectory;
unsigned char fat32;
unsigned char fat_dir_window = MAXDIRENTRIES;
int partitioncount = 1;
hdfTYPE hdf[HDD_SLOTS];
extern char *fs_pFileExt;   /* menu.c */

hardfileTYPE *SlotConfig(int slot)
{
	return slot < 2 ? &config.hardfile[slot] : &config.secondaryhardfile[slot - 2];
}

/* ---- osd.c: the Config* functions as they are (osdcfg.inc, cut out by the
   Makefile), the rest stubbed: the bitmap OSD draws nothing here ---- */
void audio_volume(unsigned char v) { logc("audio_volume(%d)", v); }
#include "osdcfg.inc"

static unsigned char keyq[2];
static int kq_n, kq_i;
unsigned char OsdGetCtrl(void) { return kq_i < kq_n ? keyq[kq_i++] : 0; }
void OsdShow(unsigned char mode) { (void)mode; }
void OsdHide(void) { }
void OsdClear(void) { }
void OsdWaitVBL(void) { }
void OsdColor(unsigned char c) { (void)c; }
void OsdSetTitle(char *t, int a) { (void)t; (void)a; }
void OsdWrite(unsigned char n, char *t, unsigned char inv, unsigned char st) { (void)n; (void)t; (void)inv; (void)st; }
void OsdDrawLogo(unsigned char n, char row, char sup) { (void)n; (void)row; (void)sup; }
void OsdWriteFramebuffer(unsigned char n, const char *t) { (void)n; (void)t; }
void StarsInit(void) { }
void StarsUpdate(void) { }
void FireworksInit(void) { }
void FireworksUpdate(void) { }
void ScrollText(char n, const char *str, int len, int max_len, unsigned char invert)
{
	(void)n; (void)str; (void)len; (void)max_len; (void)invert;
}
void ScrollReset(void) { }
void OsdReset(void) { logc("OsdReset"); }
void OsdDoReset(int enter, int leave) { logc("OsdDoReset(%d,%d)", enter, leave); }
/* Amiga raw key -> ASCII: the letters the scripts type */
#define KEY_A 0x20
#define KEY_K 0x27
#define KEY_L 0x28
unsigned char GetASCIIKey(unsigned char c)
{
	switch (c) {
	case KEY_A: return 'A';
	case KEY_K: return 'K';
	case KEY_L: return 'L';
	}
	return 0;
}

/* ---- config.c ---- */
static unsigned cfg_exists, cfg_slot;
void SetConfigurationFilename(int slot) { cfg_slot = (unsigned)slot; }
unsigned char ConfigurationExists(char *name) { (void)name; return (cfg_exists >> cfg_slot) & 1; }
unsigned char LoadConfiguration(char *name)
{
	(void)name;
	logc("Load(%u)", cfg_slot);
	config.audio.volume = (unsigned char)(10 + cfg_slot);   /* what the file holds */
	return 1;
}
unsigned char SaveConfiguration(char *name) { (void)name; logc("Save(%u)", cfg_slot); cfg_exists |= 1u << cfg_slot; return 1; }
int ApplyConfiguration(char k, char d) { logc("Apply(%d,%d)", k, d); return 1; }
void ApplyCDROM(void) { logc("ApplyCDROM"); }
void ConfigIDEPorts(void) { logc("ConfigIDEPorts"); }

/* ---- hdd.c, cdrom.c, drive sounds, the ADV7511, the rest ---- */
static unsigned char hdf_filetype = HDF_FILETYPE_RDB;
unsigned char GetHDFFileType(char *name) { logc("GetHDFFileType(%.11s)", name); return hdf_filetype; }
unsigned char OpenHardfile(unsigned int unit) { logc("OpenHardfile(%u)", unit); return 1; }
int CD_Insert(const char *name, const char *long_name, unsigned long dir)
{
	logc("CD_Insert(%.11s,%s,%lu)", name, long_name ? long_name : "-", dir);
	cdrom.unit.media = 1;
	snprintf(cdrom.unit.name, sizeof cdrom.unit.name, "%s", long_name ? long_name : "?");
	return CD_OK;
}
int CD_Eject(void) { logc("CD_Eject"); cdrom.unit.media = 0; return CD_OK; }
const char *CD_Message(void) { return "bad CUE"; }
int CD_Locked(void) { return 0; }
int CD_PlayingTrack(void) { return 0; }
void drivesounds_queueevent(enum DriveSound_Type t) { logc("drivesound(%d)", (int)t); }
int drivesounds_loaded(void) { return 1; }
void drivesounds_enable(int type) { logc("ds_enable(%d)", type); }
void drivesounds_disable(int type) { logc("ds_disable(%d)", type); }
void adv7511_set_clkdelay(unsigned char step) { adv_clkdelay = step; logc("clkdelay(%d)", step); }
unsigned char adv7511_read_clkdelay(void) { return (unsigned char)(adv_clkdelay << 5); }
void i2c_bus_recover(void) { logc("i2c_bus_recover"); }
void adv7511_init(void) { logc("adv7511_init"); }
int ColdBoot(void) { logc("ColdBoot"); return 1; }

/* ---- the FAT directory model: one directory, the window of fat.c ---- */
struct fent { const char *lfn; const char *n83; unsigned short cl; };
static const struct fent root_dir[] = {
	{ "Another World.iso", "ANOTHE~1ISO", 20 },
	{ "Arkanoid.hdf", "ARKANOIDHDF", 21 },
	{ "Elite.adf", "ELITE   ADF", 23 },
	{ "Gods.adf", "GODS    ADF", 24 },
	{ "Kick31.rom", "KICK31  ROM", 25 },
	{ "Lemmings.adf", "LEMMINGSADF", 26 },
	{ "Lotus.adf", "LOTUS   ADF", 27 },
	{ "Pinball.adf", "PINBALL ADF", 28 },
	{ "Speedball.adf", "SPEEDBALADF", 30 },
	{ "Zool.adf", "ZOOL    ADF", 36 },
};
#define NE(a) ((int)(sizeof(a) / sizeof((a)[0])))
static int win;

static void fill(void)
{
	int i, n = NE(root_dir) - win;
	if (n > fat_dir_window)
		n = fat_dir_window;
	nDirEntries = (unsigned char)n;
	memset(DirEntry, 0, sizeof DirEntry);
	for (i = 0; i < n; i++) {
		const struct fent *f = &root_dir[win + i];
		memcpy(DirEntry[i].Name, f->n83, 8);
		memcpy(DirEntry[i].Extension, f->n83 + 8, 3);
		DirEntry[i].Attributes = ATTR_ARCHIVE;
		DirEntry[i].StartCluster = f->cl;
		DirEntry[i].FileSize = 901120;
		strcpy(DirEntryLFN[i], f->lfn);
		sort_table[i] = (unsigned char)i;
	}
}

void ChangeDirectory(unsigned long c) { iCurrentDirectory = c; win = 0; }
unsigned long CurrentDirectory(void) { return iCurrentDirectory; }

static void select_abs(int idx)
{
	win = idx;
	if (win > NE(root_dir) - fat_dir_window)
		win = NE(root_dir) - fat_dir_window;
	if (win < 0)
		win = 0;
	fill();
	iSelectedEntry = (unsigned char)(idx - win);
}

char ScanDirectory(unsigned long mode, char *ext, unsigned char opts)
{
	int i;
	(void)ext;
	(void)opts;
	if (mode == SCAN_INIT) {
		win = 0;
		iSelectedEntry = 0;
		fill();
		return 0;
	}
	if (mode == SCAN_NEXT) {
		if (iSelectedEntry + 1 < nDirEntries)
			iSelectedEntry++;
		else if (win + nDirEntries < NE(root_dir)) {
			win++;
			fill();
		}
	} else if (mode == (unsigned long)SCAN_PREV) {
		if (iSelectedEntry)
			iSelectedEntry--;
		else if (win) {
			win--;
			fill();
		}
	} else if (mode >= 'A' && mode <= 'Z') {
		int from = win + iSelectedEntry;
		for (i = 1; i <= NE(root_dir); i++) {
			int k = (from + i) % NE(root_dir);
			if (root_dir[k].lfn[0] == (char)mode) {
				select_abs(k);
				return 1;
			}
		}
	}
	return 0;
}

unsigned char FileNextSector(fileTYPE *f)
{
	f->cluster++;
	return 1;
}

/* ---- one run: the start state, the keys, what it did ---- */
static configTYPE base;
static adfTYPE base_df[4];
static unsigned char base_drives;

struct effect {
	configTYPE config;
	adfTYPE df[4];
	unsigned char drives, clkdelay;
	unsigned vpos[2];
	char spi[4096];
	char calls[2048];
};
static struct effect e_old, e_new;

/* the trace's config frames (cs 20, the first byte a config register),
   their bytes out */
static void config_frames(char *out, size_t size)
{
	const char *t = mock_trace();
	size_t n = 0;
	out[0] = 0;
	while (*t) {
		const char *nl = strchr(t, '\n');
		size_t len = nl ? (size_t)(nl - t) : strlen(t);
		unsigned cs, cmd;
		if (sscanf(t, "%x %x", &cs, &cmd) == 2 && cs == 0x20 &&
		    (cmd == 0x04 || cmd == 0x14 || cmd == 0x24 || cmd == 0x34 || cmd == 0x44 ||
		     cmd == 0x54 || cmd == 0x58 || cmd == 0x64)) {
			const char *slash = memchr(t, '/', len);
			size_t k = slash ? (size_t)(slash - t) : len;
			if (n + k + 2 < size) {
				memcpy(out + n, t, k);
				n += k;
				out[n++] = '|';
				out[n] = 0;
			}
		}
		t += len + (nl ? 1 : 0);
	}
}

static void pass(void)
{
	kq_n = kq_i = 0;
	HandleUI();
}

static void key(unsigned char c)
{
	int i;
	kq_n = kq_i = 0;
	keyq[kq_n++] = c;
	HandleUI();
	for (i = 0; i < 4; i++)
		pass();
}

static void keys(const unsigned char *k, int n)
{
	while (n--)
		key(*k++);
}

static unsigned char ver_status;
static int ver_n = 99;
static unsigned char ver_miso(void *ctx, unsigned char out)
{
	static const unsigned char v[15] = { 1, 26, 10, 2, 0xA4, 0x80, 0, 0, 0, 0, 0xB5, 2, 64, 32, 0 };
	(void)ctx;
	if (out == 0x88 && ver_n >= 15) {
		ver_n = 0;
		return 0xff;
	}
	if (ver_n < 15) {
		unsigned char b = ver_n == 14 ? ver_status : v[ver_n];
		ver_n++;
		return b;
	}
	return 0xff;
}

/* the start of a run: the menus closed, the same config and drives */
static void start(unsigned char caps)
{
	unsigned char v[4] = { 0xB5, caps, 64, 32 };
	extern unsigned char menustate, menusub;
	config = base;
	memcpy(df, base_df, sizeof df);
	drives = base_drives;
	adv_clkdelay = 4;
	cfg_exists = 0x05;
	hdf_filetype = HDF_FILETYPE_RDB;
	memset(&cdrom, 0, sizeof cdrom);
	cdrom.active = 1;
	cdrom.slot = 2;
	ChangeDirectory(0);
	fs_pFileExt = NULL;
	ClearError(ERROR_ALL);
	osd2_detect(caps != 0, v);
	if (caps)
		osd2_init(OSD2_ATTR(OSD2_C_WHITE, OSD2_C_BLACK));
	menustate = MENU_NONE1;
	menusub = 0;
	ui_tab = UI_TAB_MAIN;
	pass();
	pass();
	mock_reset();
	mock_timer_step(0);
	mock_script_fn(0x20, ver_miso, NULL);
	mock_vpos_set(0, 0xdead);
	mock_vpos_set(1, 0xdead);
	calls[0] = 0;
}

static void finish(struct effect *e)
{
	pass();
	pass();
	e->config = config;
	memcpy(e->df, df, sizeof df);
	e->drives = drives;
	e->clkdelay = adv_clkdelay;
	e->vpos[0] = mock_vpos(0);
	e->vpos[1] = mock_vpos(1);
	config_frames(e->spi, sizeof e->spi);
	snprintf(e->calls, sizeof e->calls, "%s", calls);
}

/* ---- the new menu by label: the cursor onto the item (from the sidebar:
   into the list first) ---- */
#define A_SEL OSD2_ATTR(OSD2_C_WHITE, OSD2_C_BLUE)
static int go(const char *label)
{
	int i, dir;
	unsigned r;
	for (dir = 0; dir < 2; dir++)
		for (i = 0; i < 18; i++) {
			for (r = UI_LIST_ROW; r < UI_LIST_ROW + UI_LIST_ROWS; r++)
				if (osd2_atr[r][UI_LABEL_COL] == A_SEL &&
				    !memcmp(&osd2_chr[r][UI_LABEL_COL], label, strlen(label)))
					return 1;
			if (ui_focus == UI_F_SIDEBAR)
				key(KEY_RIGHT);
			else
				key(dir ? KEY_UP : KEY_DOWN);
		}
	printf("FAIL go(\"%s\"): not found\n", label);
	fails++;
	return 0;
}

static void compare(const char *name, int want_same_config)
{
	char what[160];
	int same_cfg = !memcmp(&e_old.config, &e_new.config, sizeof(configTYPE));
	snprintf(what, sizeof what, "%s: config", name);
	if (want_same_config)
		check(what, same_cfg, 1);
	if (!same_cfg && want_same_config) {
		const unsigned char *a = (const unsigned char *)&e_old.config, *b = (const unsigned char *)&e_new.config;
		unsigned k;
		for (k = 0; k < sizeof(configTYPE); k++)
			if (a[k] != b[k])
				printf("     config byte %u: classic %02x, new %02x\n", k, a[k], b[k]);
	}
	snprintf(what, sizeof what, "%s: the Config* SPI stream", name);
	if (!check(what, strcmp(e_old.spi, e_new.spi) == 0, 1))
		printf("     classic %s\n     new     %s\n", e_old.spi, e_new.spi);
	snprintf(what, sizeof what, "%s: the calls", name);
	if (!check(what, strcmp(e_old.calls, e_new.calls) == 0, 1))
		printf("     classic %s\n     new     %s\n", e_old.calls, e_new.calls);
	snprintf(what, sizeof what, "%s: the Video Pos registers", name);
	if (!check(what, e_old.vpos[0] == e_new.vpos[0] && e_old.vpos[1] == e_new.vpos[1], 1))
		printf("     classic %04x %04x, new %04x %04x\n", e_old.vpos[0], e_old.vpos[1], e_new.vpos[0], e_new.vpos[1]);
	snprintf(what, sizeof what, "%s: the floppy drives", name);
	check(what, !memcmp(e_old.df, e_new.df, sizeof e_old.df) && e_old.drives == e_new.drives, 1);
	snprintf(what, sizeof what, "%s: the HDMI clock delay", name);
	check(what, e_new.clkdelay, e_old.clkdelay);
}

/* something must have happened, or the case proves nothing */
static void changed(const char *name)
{
	char what[160];
	snprintf(what, sizeof what, "%s: the classic run changed something", name);
	check(what, memcmp(&e_old.config, &base, sizeof base) != 0 || e_old.calls[0] || e_old.spi[0] ||
	      memcmp(e_old.df, base_df, sizeof base_df) != 0 || e_old.clkdelay != 4, 1);
}

#define LEGACY(...) do { static const unsigned char k_[] = { __VA_ARGS__ }; \
	start(0); keys(k_, (int)sizeof k_); finish(&e_old); } while (0)
#define NEWK(...) do { static const unsigned char k_[] = { __VA_ARGS__ }; keys(k_, (int)sizeof k_); } while (0)
#define NEW_BEGIN(tab) do { start(1); key(KEY_MENU); key(tab); } while (0)
#define NEW_END() finish(&e_new)
#define CASE(name) compare(name, 1), changed(name)

/* the classic menu's ways in (from closed) */
#define C_SETTINGS KEY_MENU, KEY_RIGHT                       /* MAIN2_1, menusub 0 */
#define C_CHIPSET  C_SETTINGS, KEY_DOWN, KEY_DOWN, KEY_ENTER   /* CHIPSET1, menusub 0 */
#define C_MEMORY   C_SETTINGS, KEY_DOWN, KEY_DOWN, KEY_DOWN, KEY_ENTER
#define C_VIDEO    C_SETTINGS, KEY_DOWN, KEY_DOWN, KEY_DOWN, KEY_DOWN, KEY_ENTER
#define C_AUDIO    C_SETTINGS, KEY_DOWN, KEY_DOWN, KEY_DOWN, KEY_DOWN, KEY_DOWN, KEY_ENTER
/* Main: DF0, DF1 (drives 1), then Floppy disk settings, Hard disk settings */
#define C_FLOPPY   KEY_MENU, KEY_DOWN, KEY_DOWN, KEY_ENTER
#define C_HARDFILE KEY_MENU, KEY_DOWN, KEY_DOWN, KEY_DOWN, KEY_ENTER
#define C_MISC     C_SETTINGS, KEY_RIGHT
/* the new menu: EDIT, n steps, done */
#define R1 KEY_RIGHT, KEY_RIGHT, KEY_ENTER
#define R2 KEY_RIGHT, KEY_RIGHT, KEY_RIGHT, KEY_ENTER

int main(void)
{
	memset(&base, 0, sizeof base);
	base.chipset = CONFIG_ECS;
	base.memory = 0x15;
	base.cpu = 3;
	base.audio.volume = 20;
	base.floppy.drives = 1;
	base.floppy.speed = 0;
	base.enable_ide = 1;
	base.hardfile[0].enabled = HDF_FILE;
	base.hardfile[0].present = 1;
	memcpy(base.hardfile[0].name, "WORKBENC", 8);
	base.secondaryhardfile[0].enabled = HDF_CDROM;
	memcpy(base.kickstart.name, "KICK    ", 8);
	base.videopos.hpos = (unsigned char)-8;
	base.videopos.vpos = 4;
	base.scanlines = 1 | (SCALING_AREA << SCALING_SHIFT);
	base.crt_mask = 1;
	base.hdmi_clkdelay = 5;
	base_drives = 1;
	base_df[0].status = DSK_INSERTED | DSK_WRITABLE;
	memcpy(base_df[0].name, "Elite                 ", sizeof base_df[0].name);
	core_caps = CORE_CAPS_IDE2;

	/* ================= System (classic Chipset, Memory, Audio pages) ================= */
	LEGACY(C_CHIPSET, KEY_DOWN, KEY_DOWN, KEY_ENTER, KEY_MENU, KEY_MENU);
	NEW_BEGIN(KEY_F3); go("Video standard"); NEWK(R1, KEY_MENU); NEW_END();
	CASE("Video standard NTSC");

	/* a chipset change: no prompt in the classic menu, the new one asks
	   (memory or chipset): No is the classic effect */
	LEGACY(C_CHIPSET, KEY_DOWN, KEY_DOWN, KEY_DOWN, KEY_ENTER, KEY_MENU, KEY_MENU);
	NEW_BEGIN(KEY_F3); go("Chipset"); NEWK(R1, KEY_MENU, KEY_RIGHT, KEY_ENTER); NEW_END();
	CASE("Chipset ECS -> AGA (the new prompt: No)");

	LEGACY(C_CHIPSET, KEY_DOWN, KEY_DOWN, KEY_DOWN, KEY_DOWN, KEY_ENTER, KEY_MENU, KEY_MENU);
	NEW_BEGIN(KEY_F3); go("CD32 pad"); NEWK(R1, KEY_MENU); NEW_END();
	CASE("CD32 pad on");

	/* Chip RAM 1.0 -> 1.5 MB, the memory-changed prompt, Yes */
	LEGACY(C_MEMORY, KEY_ENTER, KEY_MENU, KEY_ENTER);
	NEW_BEGIN(KEY_F3); go("Chip RAM"); NEWK(R1, KEY_MENU, KEY_ENTER); NEW_END();
	CASE("Chip RAM, reset Yes");

	/* Slow RAM, the prompt, No */
	LEGACY(C_MEMORY, KEY_DOWN, KEY_ENTER, KEY_MENU, KEY_DOWN, KEY_ENTER, KEY_MENU);
	NEW_BEGIN(KEY_F3); go("Slow RAM"); NEWK(R1, KEY_MENU, KEY_RIGHT, KEY_ENTER); NEW_END();
	CASE("Slow RAM, reset No");

	/* Fast RAM, HRTmon, boards together, Yes */
	LEGACY(C_MEMORY, KEY_DOWN, KEY_DOWN, KEY_ENTER, KEY_DOWN, KEY_DOWN, KEY_ENTER, KEY_DOWN, KEY_ENTER,
	       KEY_MENU, KEY_ENTER);
	NEW_BEGIN(KEY_F3); go("Fast RAM"); NEWK(R1); go("HRTmon"); NEWK(R1); go("Fast-RAM boards"); NEWK(R1, KEY_MENU, KEY_ENTER); NEW_END();
	CASE("Fast RAM, HRTmon, boards, reset Yes");

	/* the Kickstart: the file, the reload prompt (No by default), Yes */
	LEGACY(C_MEMORY, KEY_DOWN, KEY_DOWN, KEY_DOWN, KEY_ENTER, KEY_K, KEY_ENTER, KEY_UP, KEY_ENTER);
	NEW_BEGIN(KEY_F3); go("Kickstart ROM"); NEWK(KEY_ENTER, KEY_K, KEY_ENTER, KEY_LEFT, KEY_ENTER); NEW_END();
	CASE("Kickstart reload");

	LEGACY(C_AUDIO, KEY_ENTER, KEY_ENTER, KEY_ENTER, KEY_DOWN, KEY_ENTER, KEY_MENU, KEY_MENU);
	NEW_BEGIN(KEY_F3); go("Volume"); NEWK(KEY_RIGHT, KEY_RIGHT, KEY_RIGHT, KEY_RIGHT, KEY_LEFT, KEY_ENTER, KEY_MENU); NEW_END();
	CASE("Volume +3 -1");

	/* ================= Storage (classic Floppy and Harddisks pages) ================= */
	LEGACY(C_FLOPPY, KEY_ENTER, KEY_MENU);
	NEW_BEGIN(KEY_F2); go("Floppy drives"); NEWK(R1, KEY_MENU); NEW_END();
	CASE("Floppy drives 2 -> 3");

	LEGACY(C_FLOPPY, KEY_DOWN, KEY_ENTER, KEY_MENU);
	NEW_BEGIN(KEY_F2); go("Floppy turbo"); NEWK(R1, KEY_MENU); NEW_END();
	CASE("Floppy turbo on");

	LEGACY(C_FLOPPY, KEY_DOWN, KEY_DOWN, KEY_ENTER, KEY_MENU);
	NEW_BEGIN(KEY_F2); go("Floppy sounds"); NEWK(R1, KEY_MENU); NEW_END();
	CASE("Floppy sounds on");

	/* IDE off, leaving: the hardfile-changed prompt (No by default), Yes */
	LEGACY(C_HARDFILE, KEY_ENTER, KEY_MENU, KEY_UP, KEY_ENTER);
	NEW_BEGIN(KEY_F2); go("IDE"); NEWK(R1, KEY_MENU, KEY_LEFT, KEY_ENTER); NEW_END();
	CASE("IDE off, reset Yes");

	/* Port 1 slave: Hardfile, its file (an RDB), Yes */
	LEGACY(C_HARDFILE, KEY_DOWN, KEY_DOWN, KEY_DOWN, KEY_ENTER, KEY_DOWN, KEY_ENTER, KEY_A, KEY_ENTER,
	       KEY_MENU, KEY_UP, KEY_ENTER);
	NEW_BEGIN(KEY_F2); go("Port 1 slave"); NEWK(R1, KEY_DOWN, KEY_ENTER, KEY_A, KEY_ENTER, KEY_MENU, KEY_LEFT, KEY_ENTER); NEW_END();
	CASE("Port 1 slave hardfile, reset Yes");

	/* Port 1 master's file, no partition table: the warning, then No */
	hdf_filetype = HDF_FILETYPE_UNKNOWN;
	{
		static const unsigned char k_[] = { C_HARDFILE, KEY_DOWN, KEY_DOWN, KEY_ENTER, KEY_A, KEY_ENTER,
		                                    KEY_ENTER, KEY_MENU, KEY_ENTER, KEY_MENU };
		start(0);
		hdf_filetype = HDF_FILETYPE_UNKNOWN;
		keys(k_, (int)sizeof k_);
		finish(&e_old);
	}
	start(1);
	hdf_filetype = HDF_FILETYPE_UNKNOWN;
	key(KEY_MENU);
	key(KEY_F2);
	go("Port 1 master");
	NEWK(KEY_DOWN, KEY_ENTER, KEY_A, KEY_ENTER);
	check("no partition table: the new menu's warning", ui_focus, UI_F_DIALOG);
	NEWK(KEY_ENTER, KEY_MENU, KEY_ENTER);
	NEW_END();
	compare("Port 1 master no RDB, warning, reset No", 1);
	check("no RDB, No: config unchanged", memcmp(&e_new.config, &base, sizeof base), 0);
	check("no RDB, No: the type was probed in both", strstr(e_old.calls, "GetHDFFileType") && strstr(e_new.calls, "GetHDFFileType") ? 1 : 0, 1);

	/* the live CD slot (port 2 master): a disc at once, no prompt */
	LEGACY(C_HARDFILE, KEY_RIGHT, KEY_DOWN, KEY_ENTER, KEY_ENTER, KEY_MENU, KEY_MENU);
	NEW_BEGIN(KEY_F2); go("Port 2 master"); NEWK(KEY_DOWN, KEY_ENTER, KEY_ENTER, KEY_MENU); NEW_END();
	CASE("live CD slot disc");

	/* (the slave is Disabled: its file line is not selectable) */
	LEGACY(C_HARDFILE, KEY_DOWN, KEY_DOWN, KEY_DOWN, KEY_DOWN, KEY_ENTER, KEY_MENU, KEY_MENU);
	NEW_BEGIN(KEY_F2); go("Hard disk sounds"); NEWK(R1, KEY_MENU); NEW_END();
	CASE("Hard disk sounds on");

	/* ================= Video (classic Video, Video Pos, HDMI pages) ================= */
	LEGACY(C_VIDEO, KEY_ENTER, KEY_MENU, KEY_MENU);
	NEW_BEGIN(KEY_F4); go("Scanlines"); NEWK(R1, KEY_MENU); NEW_END();
	CASE("Scanlines dim -> black");

	LEGACY(C_VIDEO, KEY_DOWN, KEY_ENTER, KEY_ENTER, KEY_MENU, KEY_MENU);
	NEW_BEGIN(KEY_F4); go("Scaling"); NEWK(R2, KEY_MENU); NEW_END();
	CASE("Scaling area -> line rate -> sharp");

	LEGACY(C_VIDEO, KEY_DOWN, KEY_DOWN, KEY_ENTER, KEY_ENTER, KEY_ENTER, KEY_MENU, KEY_MENU);
	/* (the classic page only steps forward: three steps, each sent) */
	NEW_BEGIN(KEY_F4); go("CRT mask"); NEWK(KEY_RIGHT, KEY_RIGHT, KEY_RIGHT, KEY_RIGHT, KEY_ENTER, KEY_MENU); NEW_END();
	CASE("CRT mask grille -> grille+ -> shadow -> off");

	LEGACY(C_VIDEO, KEY_DOWN, KEY_DOWN, KEY_DOWN, KEY_ENTER, KEY_ENTER, KEY_MENU, KEY_MENU);
	NEW_BEGIN(KEY_F4); go("Bloom"); NEWK(R2, KEY_MENU); NEW_END();
	CASE("Bloom off -> high");

	LEGACY(C_VIDEO, KEY_DOWN, KEY_DOWN, KEY_DOWN, KEY_DOWN, KEY_ENTER, KEY_MENU, KEY_MENU);
	NEW_BEGIN(KEY_F4); go("Beam width"); NEWK(R1, KEY_MENU); NEW_END();
	CASE("Beam width sharp");

	/* Video Pos: H +8 -8 -8, V +2 (the classic page's +/- lines) */
	LEGACY(C_VIDEO, KEY_RIGHT, KEY_ENTER, KEY_DOWN, KEY_ENTER, KEY_ENTER, KEY_DOWN, KEY_ENTER, KEY_MENU, KEY_MENU);
	NEW_BEGIN(KEY_F4); go("Position (PAL) horizontal");
	NEWK(KEY_RIGHT, KEY_RIGHT, KEY_LEFT, KEY_LEFT, KEY_ENTER); go("Position (PAL) vertical"); NEWK(R1, KEY_MENU); NEW_END();
	CASE("Video Pos H -8, V +2 (PAL)");
	check("Video Pos: the RTG register not written on a version-1 layer", e_new.vpos[1], 0xdead);

	/* the RTG screen on (layer version 2, byte 14 = 1): the new menu edits
	   the RTG pair only; the PAL register keeps its pair, written last */
	start(2);
	ver_status = 1;
	key(KEY_MENU);
	key(KEY_F4);
	go("Position (RTG) horizontal");
	NEWK(KEY_RIGHT, KEY_RIGHT, KEY_RIGHT, KEY_ENTER);
	go("Position (RTG) vertical");
	NEWK(KEY_RIGHT, KEY_LEFT, KEY_ENTER, KEY_MENU);
	ver_status = 0;
	NEW_END();
	check("RTG: the RTG pair +16 px, -2 lines", e_new.config.videopos_rtg.hpos == 16 &&
	      (signed char)e_new.config.videopos_rtg.vpos == -VPOS_STEP, 1);
	check("RTG: the PAL pair untouched", e_new.config.videopos.hpos == base.videopos.hpos &&
	      e_new.config.videopos.vpos == base.videopos.vpos, 1);
	check("RTG: VIDEOSCALE_RTG = {vpos, hpos}", e_new.vpos[1], (unsigned)(((unsigned char)-VPOS_STEP << 8) | 16));
	check("RTG: VIDEOSCALE = the PAL pair", e_new.vpos[0], (unsigned)((base.videopos.vpos << 8) + base.videopos.hpos));
	{
		configTYPE c = e_new.config;
		c.videopos_rtg = base.videopos_rtg;
		check("RTG: nothing else in config changed", memcmp(&c, &base, sizeof c), 0);
	}

	/* the HDMI clock delay: +2 -1 */
	LEGACY(C_VIDEO, KEY_RIGHT, KEY_RIGHT, KEY_ENTER, KEY_ENTER, KEY_DOWN, KEY_ENTER, KEY_MENU, KEY_MENU);
	NEW_BEGIN(KEY_F4); go("HDMI clock delay"); NEWK(KEY_RIGHT, KEY_RIGHT, KEY_RIGHT, KEY_LEFT, KEY_ENTER, KEY_MENU); NEW_END();
	CASE("HDMI clock delay +2 -1");

	/* ================= Acceleration (classic Chipset page) ================= */
	LEGACY(C_CHIPSET, KEY_ENTER, KEY_ENTER, KEY_MENU, KEY_MENU);
	NEW_BEGIN(KEY_F5); go("CPU"); NEWK(R2, KEY_MENU); NEW_END();
	CASE("CPU 68020 -> 68000 -> 68010");

	LEGACY(C_CHIPSET, KEY_DOWN, KEY_ENTER, KEY_ENTER, KEY_ENTER, KEY_MENU, KEY_MENU);
	NEW_BEGIN(KEY_F5); go("Turbo"); NEWK(KEY_RIGHT, KEY_RIGHT, KEY_RIGHT, KEY_RIGHT, KEY_ENTER, KEY_MENU); NEW_END();
	CASE("Turbo -> BOTH");

	LEGACY(C_CHIPSET, KEY_DOWN, KEY_DOWN, KEY_DOWN, KEY_DOWN, KEY_DOWN, KEY_ENTER, KEY_MENU, KEY_MENU);
	NEW_BEGIN(KEY_F5); go("Chip slots"); NEWK(R1, KEY_MENU); NEW_END();
	CASE("Chip slots Fast");

	/* ================= Main ================= */
	LEGACY(KEY_MENU, KEY_ENTER, KEY_MENU);
	NEW_BEGIN(KEY_F1); go("DF0"); NEWK(KEY_ENTER, KEY_MENU); NEW_END();
	CASE("DF0 eject");

	LEGACY(KEY_MENU, KEY_DOWN, KEY_ENTER, KEY_L, KEY_ENTER, KEY_MENU);
	NEW_BEGIN(KEY_F1); go("DF1"); NEWK(KEY_ENTER, KEY_L, KEY_ENTER, KEY_MENU); NEW_END();
	CASE("DF1 insert Lemmings");

	LEGACY(KEY_MENU, KEY_KPPLUS, KEY_MENU);
	NEW_BEGIN(KEY_F1); NEWK(KEY_KPPLUS, KEY_MENU); NEW_END();
	CASE("keypad +: a drive more");

	LEGACY(C_SETTINGS, KEY_ENTER, KEY_DOWN, KEY_ENTER);
	NEW_BEGIN(KEY_F1); go("Load configuration"); NEWK(KEY_RIGHT, KEY_RIGHT, KEY_ENTER, KEY_ENTER, KEY_ENTER); NEW_END();
	CASE("Load configuration 2");

	LEGACY(C_SETTINGS, KEY_DOWN, KEY_ENTER, KEY_DOWN, KEY_ENTER);
	NEW_BEGIN(KEY_F1); go("Save configuration"); NEWK(KEY_RIGHT, KEY_RIGHT, KEY_ENTER, KEY_ENTER, KEY_MENU); NEW_END();
	CASE("Save configuration 1");

	LEGACY(C_MISC, KEY_ENTER, KEY_ENTER);
	NEW_BEGIN(KEY_F1); go("Reset"); NEWK(KEY_ENTER, KEY_ENTER); NEW_END();
	CASE("Reset");

	LEGACY(C_MISC, KEY_DOWN, KEY_ENTER, KEY_ENTER);
	NEW_BEGIN(KEY_F1); go("Reboot"); NEWK(KEY_ENTER, KEY_ENTER); NEW_END();
	CASE("Reboot");

	printf("%s: %d cases, %d failed\n", fails ? "FAIL migrate_test" : "migrate_test passed", cases, fails);
	return fails ? 1 : 0;
}

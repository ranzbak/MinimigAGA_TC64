/* ui_test: the new OSD menu (ui.c, ui_tabs.c, menu_model.c; findings/
 * osd-redesign/plan.md Phase 3, the sidebar layout of 2026-10-27) on the
 * real osd2.c and the mock's SPI trace.
 * The rest of the firmware is stubbed here: osd.c's Config* calls and
 * OsdShow/OsdHide, config files, the CD-ROM, and a FAT directory model
 * (ScanDirectory's window semantics over two directories, the entries
 * stored out of order behind sort_table).  Keys go in through the stub
 * OsdGetCtrl, one per ui_handle() pass, as on the board.
 *
 * Checks: golden screens (gold/ui/<name>.txt: the 64 x 20 characters, a
 * glyph outside ASCII as ^, then the foreground and the background palette
 * index of every cell), the SPI frames that switch the layer and the
 * keyboard and upload the menu's glyphs, the calls the menu makes (Config*,
 * InsertFloppy's drive, CD_Insert, the reset sequences), the navigation
 * (sidebar with its preview, list, Left/Esc back, F keys, F12 closing from
 * anywhere), the help field (key hints until a key, then the focused
 * item's help, toasts for 1 s; every help text fits its two lines), and the
 * selected long name's scroll on the mock TIMER (start 500 ms, a cell per
 * 128 ms, end 1 s, restart; reset by a cursor move), and Main's About and
 * Supporters pages: their first frames, the effects' steps on the mock
 * TIMER (the copper's and the plasma's palette rotation, the stars never
 * on the text), the SPI bytes per step against the plan's budget, and the
 * menu after a page exactly as before it: cells, the font RAM and the
 * palette, modelled from the trace (UI_PRETTY=1 prints the pages with
 * their glyphs as text).
 *   make -C fw/ctrl/test run-ui_test
 *   UI_GOLD_WRITE=1 out/ui_test gold/ui     writes the golden screens
 */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "hardware.h"
#include "errors.h"
#include "fat.h"
#include "fdd.h"
#include "osd.h"
#include "fpga.h"
#include "config.h"
#include "cdrom.h"
#include "drivesounds.h"
#include "adv7511.h"
#include "i2c.h"
#include "menu.h"
#include "menu_model.h"
#include "osd2.h"
#include "osd_icons.h"
#include "osd_logo.h"
#include "font8x16.h"
#include "ui.h"
#include "mock_hw.h"

static int fails, cases;
static const char *golddir;

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

static int check_str(const char *what, const char *got, const char *want)
{
	cases++;
	if (strcmp(got, want)) {
		printf("FAIL %s:\n  got  \"%s\"\n  want \"%s\"\n", what, got, want);
		fails++;
		return 0;
	}
	printf("ok   %s\n", what);
	return 1;
}

static int check_has(const char *what, const char *hay, const char *needle, int want)
{
	int has = strstr(hay, needle) != NULL;
	cases++;
	if (has != want) {
		printf("FAIL %s: \"%s\" %s\n", what, needle, want ? "missing" : "present");
		fails++;
		return 0;
	}
	printf("ok   %s\n", what);
	return 1;
}

/* ---- the stubs' call log ---- */
static char calls[16384];
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
static void calls_clear(void) { calls[0] = 0; }

/* ---- firmware state the units use ---- */
configTYPE config;
fileTYPE file;
char DebugMode;
unsigned char drives;
adfTYPE df[4];
cdromTYPE cdrom;
unsigned char core_caps;
unsigned char core_version[4] = { 0, 26, 10, 27 };
const char fw_version[] = "2026-10-28-12-0";
unsigned char adv_clkdelay = 4;
unsigned char osd_keyq_lost;
char *fs_pFileExt;
DIRENTRY DirEntry[MAXDIRENTRIES];
char DirEntryLFN[MAXDIRENTRIES][261];
unsigned char sort_table[MAXDIRENTRIES];
unsigned char nDirEntries, iSelectedEntry;
unsigned long iCurrentDirectory;
unsigned char fat32;
unsigned char fat_dir_window = MAXDIRENTRIES;

hardfileTYPE *SlotConfig(int slot)
{
	return slot < 2 ? &config.hardfile[slot] : &config.secondaryhardfile[slot - 2];
}

/* ---- osd.c ---- */
static unsigned char keyq[8];
static int kq_n, kq_i;
unsigned char OsdGetCtrl(void) { return kq_i < kq_n ? keyq[kq_i++] : 0; }
void OsdShow(unsigned char mode) { logc("OsdShow(%d)", mode); }
void OsdHide(void) { logc("OsdHide"); }
void OsdReset(void) { logc("OsdReset"); }
void OsdDoReset(int enter, int leave) { logc("OsdDoReset(%d,%d)", enter, leave); }
void ConfigChipset(unsigned char v) { logc("ConfigChipset(%02x)", v); }
void ConfigMemory(unsigned char v) { logc("ConfigMemory(%02x)", v); }
void ConfigCPU(unsigned char v) { logc("ConfigCPU(%02x)", v); }
void ConfigAutofire(unsigned char v) { logc("ConfigAutofire(%02x)", v); }
void ConfigFloppy(unsigned char d, unsigned char s) { logc("ConfigFloppy(%d,%d)", d, s); }
void ConfigAudio(unsigned char v) { logc("ConfigAudio(%d)", v); }
void ConfigVideo(unsigned char a, unsigned char b, unsigned char c, unsigned char d)
{
	logc("ConfigVideo(%d,%d,%d,%d)", a, b, c, d);
}
/* Amiga raw key -> ASCII, the letters the test types */
unsigned char GetASCIIKey(unsigned char c)
{
	switch (c) {
	case 0x28: return 'L';
	case 0x14: return 'T';
	case 0x24: return 'G';
	}
	return 0;
}

/* ---- config.c ---- */
static unsigned cfg_exists, cfg_slot;
void SetConfigurationFilename(int slot) { cfg_slot = (unsigned)slot; }
unsigned char ConfigurationExists(char *name) { (void)name; return (cfg_exists >> cfg_slot) & 1; }
unsigned char LoadConfiguration(char *name) { (void)name; logc("Load(%u)", cfg_slot); return 1; }
unsigned char SaveConfiguration(char *name) { (void)name; logc("Save(%u)", cfg_slot); cfg_exists |= 1u << cfg_slot; return 1; }
int ApplyConfiguration(char k, char d) { logc("Apply(%d,%d)", k, d); return 1; }

/* ---- the rest ---- */
static int cd_insert_rc;
int CD_Insert(const char *name, const char *long_name, unsigned long dir)
{
	logc("CD_Insert(%.11s,%s,%lu)", name, long_name ? long_name : "-", dir);
	if (cd_insert_rc == CD_OK) {
		cdrom.unit.media = 1;
		snprintf(cdrom.unit.name, sizeof cdrom.unit.name, "%s", long_name ? long_name : "?");
	}
	return cd_insert_rc;
}
int CD_Eject(void)
{
	logc("CD_Eject");
	if (cdrom.unit.locked)
		return CD_LOCKED;
	cdrom.unit.media = 0;
	return CD_OK;
}
const char *CD_Message(void) { return "bad CUE"; }
int CD_Locked(void) { return cdrom.unit.locked; }
int CD_PlayingTrack(void) { return 0; }
void drivesounds_queueevent(enum DriveSound_Type t) { logc("drivesound(%d)", (int)t); }
static int ds_loaded;
int drivesounds_loaded(void) { return ds_loaded; }
void drivesounds_enable(int type) { logc("ds_enable(%d)", type); }
void drivesounds_disable(int type) { logc("ds_disable(%d)", type); }
/* adv7511.c, main.c: the HDMI clock delay and its readback */
unsigned long adv_services = 12;
unsigned char adv_int_now;
static unsigned char adv_chip = 0xff;   /* what 0xBA reads: ff = no answer */
void adv7511_set_clkdelay(unsigned char step) { adv_clkdelay = step; adv_chip = (unsigned char)(step << 5); logc("clkdelay(%d)", step); }
unsigned char adv7511_read_clkdelay(void) { return adv_chip; }
/* osd.c ConfigVideoPos: both pairs as they are (the RTG gate is osd.c's:
   migrate_test runs the real one) */
void ConfigVideoPos(void)
{
	logc("VPos(%02x%02x,%02x%02x)", config.videopos.vpos, config.videopos.hpos,
	     config.videopos_rtg.vpos, config.videopos_rtg.hpos);
}
/* the core's VERSION reply (cs 0x20) after 0x88: bytes 0..14, byte 14 the
   text layer's status (osd2_rtg_active) */
static unsigned char ver_status;
static int ver_n = 99, ver_reads;
static unsigned char ver_miso(void *ctx, unsigned char out)
{
	static const unsigned char v[15] = { 1, 26, 10, 2, 0xA4, 0x80, 0, 0, 0, 0, 0xB5, 2, 64, 32, 0 };
	(void)ctx;
	if (out == 0x88 && ver_n >= 15) {
		ver_n = 0;
		ver_reads++;
		return 0xff;
	}
	if (ver_n < 15) {
		unsigned char b = ver_n == 14 ? ver_status : v[ver_n];
		ver_n++;
		return b;
	}
	return 0xff;
}
/* the layer version: 1 (the bitstream of 10-27: no byte 14) or 2 */
static void layer_version(unsigned char ver)
{
	unsigned char v[4] = { 0xB5, ver, 64, 32 };
	osd2_detect(1, v);
}
void i2c_bus_recover(void) { logc("i2c_bus_recover"); }
void adv7511_init(void) { logc("adv7511_init"); }
int ColdBoot(void) { logc("ColdBoot"); return 1; }
void SanityCheck(void) { logc("SanityCheck"); }
static int debug_draws;
void _showdebugmessages(void) { debug_draws++; }
void debug2_show(int on) { logc("debug2_show(%d)", on); }
/* hdd.c, config.c: the Storage tab's hardfile flow (menu_model.c mm_hdf_*) */
int partitioncount = 1;
static unsigned char hdf_filetype = HDF_FILETYPE_RDB;
unsigned char GetHDFFileType(char *name) { logc("GetHDFFileType(%.11s)", name); return hdf_filetype; }
unsigned char OpenHardfile(unsigned int unit) { logc("OpenHardfile(%u)", unit); return 1; }
void ApplyCDROM(void) { logc("ApplyCDROM"); }
void ConfigIDEPorts(void) { logc("ConfigIDEPorts"); }

/* ---- the FAT directory model ---- */
struct fent { const char *lfn; const char *n83; unsigned char dir; unsigned short cl; };
static const struct fent root_dir[] = {
	{ "Games", "GAMES      ", 1, 5 },
	{ "Utilities", "UTILS      ", 1, 6 },
	{ "Another World (1991)(Delphine).adf", "ANOTHE~1ADF", 0, 20 },
	{ "Arkanoid.adf", "ARKANOIDADF", 0, 21 },
	{ "", "DPAINT  ADF", 0, 22 },
	{ "Elite.adf", "ELITE   ADF", 0, 23 },
	{ "Gods.adf", "GODS    ADF", 0, 24 },
	{ "Kick31.rom", "KICK31  ROM", 0, 25 },
	{ "Lemmings.adf", "LEMMINGSADF", 0, 26 },
	{ "Lotus Turbo Challenge 2.adf", "LOTUST~1ADF", 0, 27 },
	{ "Pinball Dreams.adf", "PINBAL~1ADF", 0, 28 },
	{ "Shadow of the Beast (1989)(Psygnosis)(Disk 1 of 2).adf", "SHADOW~1ADF", 0, 29 },
	{ "Speedball 2.adf", "SPEEDB~1ADF", 0, 30 },
	{ "Stunt Car Racer.adf", "STUNTC~1ADF", 0, 31 },
	{ "Super Frog.adf", "SUPERF~1ADF", 0, 32 },
	{ "Turrican II - The Final Fight (1991)(Rainbow Arts).adf", "TURRIC~1ADF", 0, 33 },
	{ "Workbench 3.1.adf", "WORKBE~1ADF", 0, 34 },
	{ "Xenon 2.adf", "XENON2~1ADF", 0, 35 },
	{ "Zool.adf", "ZOOL    ADF", 0, 36 },
	{ "Zool 2.adf", "ZOOL2~1 ADF", 0, 37 },
};
static const struct fent games_dir[] = {
	{ "", "..         ", 1, 0 },
	{ "Monkey Island.adf", "MONKEY~1ADF", 0, 50 },
	{ "Zak McKracken.adf", "ZAKMCK~1ADF", 0, 51 },
};
static const struct fent utils_dir[] = {
	{ "", "..         ", 1, 0 },
};
#define NE(a) ((int)(sizeof(a) / sizeof((a)[0])))
static const struct fent *tbl = root_dir;
static int tbl_n = NE(root_dir), win;
static unsigned long prev_dir;
static int scans;

/* the window into DirEntry, stored in reverse behind sort_table */
static void fill(void)
{
	int i, n = tbl_n - win;
	if (n > fat_dir_window)
		n = fat_dir_window;
	nDirEntries = (unsigned char)n;
	memset(DirEntry, 0, sizeof DirEntry);
	for (i = 0; i < n; i++) {
		const struct fent *f = &tbl[win + i];
		int k = n - 1 - i;
		memcpy(DirEntry[k].Name, f->n83, 8);
		memcpy(DirEntry[k].Extension, f->n83 + 8, 3);
		DirEntry[k].Attributes = f->dir ? ATTR_DIRECTORY : ATTR_ARCHIVE;
		DirEntry[k].StartCluster = f->cl;
		DirEntry[k].FileSize = f->dir ? 0 : 901120;
		strcpy(DirEntryLFN[k], f->lfn);
		sort_table[i] = (unsigned char)k;
	}
}

void ChangeDirectory(unsigned long c)
{
	prev_dir = iCurrentDirectory;
	iCurrentDirectory = c;
	tbl = c == 5 ? games_dir : c == 6 ? utils_dir : root_dir;
	tbl_n = c == 5 ? NE(games_dir) : c == 6 ? NE(utils_dir) : NE(root_dir);
	win = 0;                        /* (fat.c leaves the table as it was) */
}
unsigned long CurrentDirectory(void) { return iCurrentDirectory; }

static char first_upper(const struct fent *f)
{
	char c = f->lfn[0] ? f->lfn[0] : f->n83[0];
	return (char)(c >= 'a' && c <= 'z' ? c - 32 : c);
}

static void select_abs(int idx)
{
	win = idx;
	if (win > tbl_n - fat_dir_window)
		win = tbl_n - fat_dir_window;
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
	scans++;
	if (mode == SCAN_INIT) {
		win = 0;
		iSelectedEntry = 0;
		fill();
		return 0;
	}
	if (!nDirEntries)
		return 0;
	if (mode == SCAN_NEXT) {
		if (iSelectedEntry + 1 < nDirEntries)
			iSelectedEntry++;
		else if (win + nDirEntries < tbl_n) {
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
	} else if (mode == SCAN_NEXT_PAGE) {
		if (iSelectedEntry + 1 < nDirEntries)
			iSelectedEntry = nDirEntries - 1;
		else
			select_abs(win + nDirEntries - 1 + fat_dir_window - 1 < tbl_n ? win + nDirEntries - 1 + fat_dir_window - 1 : tbl_n - 1);
	} else if (mode == (unsigned long)SCAN_PREV_PAGE) {
		if (iSelectedEntry)
			iSelectedEntry = 0;
		else {
			win = win > fat_dir_window - 1 ? win - (fat_dir_window - 1) : 0;
			fill();
		}
	} else if (mode == SCAN_INIT_FIRST) {
		for (i = 0; i < tbl_n; i++)
			if (tbl[i].cl == prev_dir && tbl[i].dir) {
				select_abs(i);
				return 1;
			}
		return 0;
	} else if (mode == SCAN_INIT_NEXT) {
		return 0;
	} else {
		/* a letter: the next entry starting with it, after the selected one */
		int from = win + iSelectedEntry;
		for (i = 1; i <= tbl_n; i++) {
			int k = (from + i) % tbl_n;
			if (first_upper(&tbl[k]) == (char)mode) {
				select_abs(k);
				return 1;
			}
		}
		return 0;
	}
	return 0;
}

unsigned char FileNextSector(fileTYPE *f)
{
	f->cluster++;
	return 1;
}

/* ---- driving the engine ---- */
static void key(unsigned char c)
{
	kq_n = kq_i = 0;
	keyq[kq_n++] = c;
	ui_handle();
}
static void keys(const unsigned char *c, int n)
{
	while (n--)
		key(*c++);
}
static void pass(int n)
{
	while (n--)
		ui_handle();
}
/* time passes, one TIMER count per pass */
static void wait_counts(int n)
{
	while (n--) {
		hosttest_advance(1);
		ui_handle();
	}
}

static char rowbuf[OSD2_COLS + 1];
static const char *row(unsigned r)
{
	unsigned c;
	for (c = 0; c < OSD2_COLS; c++) {
		unsigned char ch = osd2_chr[r][c];
		rowbuf[c] = (ch >= 0x20 && ch < 0x7f) ? (char)ch : '^';
	}
	rowbuf[OSD2_COLS] = 0;
	return rowbuf;
}
static char cellbuf[OSD2_COLS + 1];
static const char *cells(unsigned r, unsigned c, unsigned n)
{
	memcpy(cellbuf, row(r) + c, n);
	cellbuf[n] = 0;
	return cellbuf;
}

#define A_SEL  OSD2_ATTR(OSD2_C_WHITE, OSD2_C_BLUE)
#define A_GREY OSD2_ATTR(OSD2_C_DKBLUE, OSD2_C_BLACK)

/* the list row the cursor is on (its label cell on the blue bar), or -1 */
static int sel_row(void)
{
	unsigned r;
	for (r = UI_LIST_ROW; r < UI_LIST_ROW + UI_LIST_ROWS; r++)
		if (osd2_atr[r][UI_LABEL_COL] == A_SEL)
			return (int)r;
	return -1;
}

/* the cursor onto the item whose label starts with `label` (from the
   sidebar: into the list first) */
static int go(const char *label)
{
	int i, dir;
	for (dir = 0; dir < 2; dir++)
		for (i = 0; i < 18; i++) {
			int r = sel_row();
			if (r >= 0 && !strncmp(row((unsigned)r) + UI_LABEL_COL, label, strlen(label)))
				return r;
			if (ui_focus == UI_F_SIDEBAR)
				key(KEY_RIGHT);
			else
				key(dir ? KEY_UP : KEY_DOWN);
		}
	printf("FAIL go(\"%s\"): not found\n", label);
	fails++;
	return -1;
}

/* ---- golden screens ---- */
static char scr[8192];
static void dump(void)
{
	static const char hex[] = "0123456789abcdef";
	char *p = scr;
	unsigned r, c;
	p += sprintf(p, "chars\n");
	for (r = 0; r < UI_ROWS; r++)
		p += sprintf(p, "%s\n", row(r));
	p += sprintf(p, "fg\n");
	for (r = 0; r < UI_ROWS; r++) {
		for (c = 0; c < UI_COLS; c++)
			*p++ = hex[osd2_atr[r][c] & 15];
		*p++ = '\n';
	}
	p += sprintf(p, "bg\n");
	for (r = 0; r < UI_ROWS; r++) {
		for (c = 0; c < UI_COLS; c++)
			*p++ = hex[osd2_atr[r][c] >> 4];
		*p++ = '\n';
	}
	*p = 0;
}

static void screen(const char *name)
{
	char path[512], *want;
	FILE *f;
	long n;
	cases++;
	dump();
	snprintf(path, sizeof path, "%s/%s.txt", golddir, name);
	if (getenv("UI_GOLD_WRITE")) {
		f = fopen(path, "w");
		if (!f || fputs(scr, f) < 0) {
			printf("FAIL screen %s: cannot write %s\n", name, path);
			fails++;
		} else
			printf("ok   screen %s written\n", name);
		if (f)
			fclose(f);
		return;
	}
	f = fopen(path, "r");
	if (!f) {
		printf("FAIL screen %s: no %s (UI_GOLD_WRITE=1 writes it)\n", name, path);
		fails++;
		return;
	}
	fseek(f, 0, SEEK_END);
	n = ftell(f);
	fseek(f, 0, SEEK_SET);
	want = calloc(1, (size_t)n + 1);
	if (fread(want, 1, (size_t)n, f) != (size_t)n)
		want[0] = 0;
	fclose(f);
	if (strcmp(scr, want)) {
		/* the first line that differs, and the screen as it is */
		const char *a = scr, *b = want;
		int line = 1;
		while (*a && *a == *b) {
			if (*a == '\n')
				line++;
			a++;
			b++;
		}
		printf("FAIL screen %s: differs from %s at line %d; the screen:\n%s", name, path, line, scr);
		fails++;
	} else
		printf("ok   screen %s\n", name);
	free(want);
}

/* the layer's window frames (0x5C) in the trace */
#define WIN_MENU_ON  "20 5c 03 10 05 40 14 /"
#define WIN_MENU_OFF "20 5c 02 10 05 40 14 /"
#define WIN_TOAST_ON "20 5c 03 28 4b 28 01 /"
#define WIN_TOAST_OFF "20 5c 02 28 4b 28 01 /"
#define KEYS_TO_OSD  "20 28 02 / ff ff"

static void setup(void)
{
	static const unsigned char v[4] = { 0xB5, 1, 64, 32 };
	mock_reset();
	mock_timer_step(0);             /* time moves only by wait_counts() */
	memset(&config, 0, sizeof config);
	config.chipset = CONFIG_AGA | CONFIG_ECS;
	config.memory = 0x23;           /* chip 2.0 MB, fast 4.0 MB */
	config.cpu = 3;                 /* 68020 */
	config.audio.volume = 20;
	config.floppy.drives = 1;
	config.enable_ide = 1;
	config.hardfile[0].enabled = HDF_FILE;
	config.hardfile[0].present = 1;
	memcpy(config.hardfile[0].name, "WORKBENC", 8);
	memcpy(config.hardfile[0].long_name, "Workbench31", 11);
	config.secondaryhardfile[0].enabled = HDF_CDROM;
	memcpy(config.kickstart.name, "KICK31  ", 8);
	memcpy(config.kickstart.long_name, "kick31.rom", 10);
	config.videopos.hpos = (unsigned char)-8;
	config.videopos.vpos = 4;
	config.scanlines = 1 | (SCALING_AREA << SCALING_SHIFT);
	config.crt_mask = 1;
	drives = 1;
	memset(df, 0, sizeof df);
	df[0].status = DSK_INSERTED;    /* write protected: the padlock */
	memcpy(df[0].name, "Lemmings              ", sizeof df[0].name);
	memset(&cdrom, 0, sizeof cdrom);
	cdrom.active = 1;
	cdrom.slot = 2;
	cfg_exists = 0x05;              /* Default and 2 */
	core_caps = CORE_CAPS_IDE2;
	osd2_detect(1, v);
	osd2_init(OSD2_ATTR(OSD2_C_WHITE, OSD2_C_BLACK));
	mock_reset();
	mock_timer_step(0);
	mock_script_fn(0x20, ver_miso, NULL);
	calls_clear();
}

/* the mock back to an empty trace, keeping the OSD's VERSION model */
static void trace_reset(void)
{
	mock_reset();
	mock_timer_step(0);
	mock_script_fn(0x20, ver_miso, NULL);
}


/* every help text fits the help field's two lines (osd2_wrap into the
   off-window scratch rows 30-31) */
static void help_fits(const char *what, const char *help)
{
	unsigned n;
	char name[96];
	if (!help)
		return;
	n = osd2_wrap(30, 0, UI_HELP_W, UI_HELP_ROWS, help, 0);
	if (n > UI_HELP_ROWS) {
		snprintf(name, sizeof name, "help of %s fits two lines (%u)", what, n);
		check(name, n, UI_HELP_ROWS);
	}
	cases++;
}


/* ---- the About and Supporters pages ---------------------------------- */

/* the layer's font RAM and palette as the trace wrote them: the font from
   the ROM font (osd_font.mem = font8x16.h), the palette from the menu's
   scheme (committed when the menu first opened); model_sync() applies the
   trace so far (call it before every trace reset) */
static unsigned char m_font[256 * 16];
static unsigned char m_pal[16][4];
/* rtl/openaars/adv7511/osd_font.mem: the font RAM's content after the
   bitstream loads ($readmemh), read by main (its second argument) */
static unsigned char rom_mem[256 * 16];
static int rom_lines;

static void load_mem(const char *path)
{
	FILE *f = fopen(path, "r");
	unsigned v;
	char line[16];
	rom_lines = 0;
	if (!f) {
		printf("FAIL ROM font: cannot open %s\n", path);
		fails++;
		return;
	}
	while (fgets(line, sizeof line, f))
		if (sscanf(line, "%2x", &v) == 1 && rom_lines < (int)sizeof rom_mem)
			rom_mem[rom_lines++] = (unsigned char)v;
		else
			rom_lines = -1000000;   /* not a line of two hex digits, or too many */
	fclose(f);
}

static void model_init(void)
{
	static const unsigned long scheme[8] = {
		0x000000, 0xF0F0F0, 0x1478E6, 0x3C5A9A, 0xF0C828, 0x3CC85A, 0xE03C3C, 0x000000
	};
	unsigned i;
	memcpy(m_font, rom_mem, sizeof m_font);     /* after the bitstream loads */
	for (i = 0; i < 16; i++) {
		unsigned long c = i < 8 ? scheme[i] : 0;
		m_pal[i][0] = i == OSD2_C_CLEAR ? OSD2_VIDEO << 6 : 0;
		m_pal[i][1] = (unsigned char)(c >> 16);
		m_pal[i][2] = (unsigned char)(c >> 8);
		m_pal[i][3] = (unsigned char)c;
	}
}

/* the out bytes of each OSD frame of the trace: fn(bytes, n) */
static unsigned char fb[8192];
static void frames(void (*fn)(const unsigned char *b, unsigned n))
{
	const char *p = mock_trace();
	while (*p) {
		const char *e = strchr(p, '\n');
		unsigned n = 0, v, cs;
		int k;
		if (!e)
			e = p + strlen(p);
		if (sscanf(p, "%x%n", &cs, &k) == 1 && cs == 0x20) {
			const char *q = p + k;
			while (q < e && sscanf(q, " %2x%n", &v, &k) == 1 && n < sizeof fb) {
				fb[n++] = (unsigned char)v;
				q += k;
			}
			fn(fb, n);
		}
		p = *e ? e + 1 : e;
	}
}

static void model_frame(const unsigned char *b, unsigned n)
{
	unsigned i;
	if (n >= 3 && b[0] == OSD2_CMD_FONT) {
		unsigned adr = ((b[1] & 0x0f) << 8) | b[2];
		for (i = 3; i < n; i++)
			m_font[(adr + i - 3) & 0xfff] = b[i];
	} else if (n >= 2 && b[0] == OSD2_CMD_PAL) {
		for (i = 2; i + 3 < n + 0 && b[1] + (i - 2) / 4 < 16; i += 4)
			memcpy(m_pal[b[1] + (i - 2) / 4], b + i, 4);
	}
}

/* the trace emptied, the TIMER kept (mock_reset sets it to 0: the page's
   frame timer would wait for it) */
unsigned short hosttest_timer_peek(void);
static void model_sync(void)
{
	unsigned t = hosttest_timer_peek();
	frames(model_frame);
	trace_reset();
	hosttest_advance(t);
}

/* the SPI bytes of the trace (each frame's out bytes, the command included) */
static unsigned spi_n, win_n;
static void count_frame(const unsigned char *b, unsigned n)
{
	spi_n += n;
	if (n && b[0] == OSD2_CMD_CFG)
		win_n++;
}
static unsigned trace_spi_bytes(void)
{
	spi_n = win_n = 0;
	frames(count_frame);
	return spi_n;
}

static unsigned char snap_chr[UI_ROWS][OSD2_COLS], snap_atr[UI_ROWS][OSD2_COLS];
static unsigned char snap_font[256 * 16], snap_pal[16][4];
static void snapshot(void)
{
	memcpy(snap_chr, osd2_chr, sizeof snap_chr);
	memcpy(snap_atr, osd2_atr, sizeof snap_atr);
	memcpy(snap_font, m_font, sizeof snap_font);
	memcpy(snap_pal, m_pal, sizeof snap_pal);
}
static int same_cells(void)
{
	return !memcmp(snap_chr, osd2_chr, sizeof snap_chr) && !memcmp(snap_atr, osd2_atr, sizeof snap_atr);
}

/* UI_PRETTY=1: a page's cells with its glyphs as text (logo #, stars . : *,
   the copper bar =, the dithers - + %) */
static void pretty(const char *name, int about)
{
	unsigned r, c;
	if (!getenv("UI_PRETTY"))
		return;
	printf("---- %s\n", name);
	for (r = 0; r < UI_ROWS; r++) {
		for (c = 0; c < UI_COLS; c++) {
			unsigned char ch = osd2_chr[r][c];
			unsigned s = ch >= 0xCA ? ch - 0xCAu + 64 : (ch >= 0x80 && ch < 0xC0) ? ch - 0x80u : 999;
			char o = (ch >= 0x20 && ch < 0x7f) ? (char)ch : '^';
			if (s < 999 && about)       /* 55 logo, 16 far, 16 mid, 8 near, the shade */
				o = s < 55 ? '#' : s < 71 ? '.' : s < 87 ? ':' : s < 95 ? '*' : '=';
			else if (s < 3)
				o = "-+%"[s];
			putchar(o);
		}
		putchar('\n');
	}
}

/* About: a space or a star (slots 55-94: after the logo's 55 glyphs) */
static int sky(unsigned char ch)
{
	unsigned i;
	if (ch == ' ')
		return 1;
	for (i = OSD_LOGO_GLYPHS; i < OSD_LOGO_GLYPHS + 40; i++)
		if (ch == ui_fx_code(i))
			return 1;
	return 0;
}

/* the ROM font: osd_font.mem (the RTL font RAM after boot) = font8x16.h
   (the firmware's copy), and the menu's uploads are its glyphs */
static void test_rom_font(void)
{
	unsigned i, n, same;
	check("ROM font: osd_font.mem has 4096 lines", rom_lines, 256 * 16);
	check("ROM font: osd_font.mem = font8x16.h", !memcmp(rom_mem, font8x16, sizeof rom_mem), 1);
	/* the menu opens on a core whose font RAM starts from osd_font.mem */
	model_init();
	trace_reset();
	key(KEY_MENU);
	model_sync();
	check("open: the font RAM still osd_font.mem (the uploads are the ROM font's glyphs)",
	      !memcmp(m_font, rom_mem, sizeof m_font), 1);
	key(KEY_MENU);
	/* ... and on a core with another font (an older bitstream): every glyph
	   the menu draws with besides the text is uploaded, as the ROM font has it */
	memset(m_font, 0xAA, sizeof m_font);
	trace_reset();
	key(KEY_MENU);
	model_sync();
	for (i = n = same = 0; i < 256; i++) {
		static const unsigned char aa[16] = {
			0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA
		};
		if (memcmp(m_font + i * 16, aa, 16)) {
			n++;
			same += !memcmp(m_font + i * 16, rom_mem + i * 16, 16);
		}
	}
	check("old font: glyphs uploaded (bar 9, lines/arrows 10, icons 10)", n, 29);
	check("old font: each the ROM font's", same, 29);
	check("old font: the bar, the lines, the icons among them",
	      !memcmp(m_font + OSD_G_BAR0 * 16, rom_mem + OSD_G_BAR0 * 16, OSD_G_BARS * 16) &&
	      !memcmp(m_font + OSD_G_HLINE * 16, rom_mem + OSD_G_HLINE * 16, 16) &&
	      !memcmp(m_font + OSD_ICON_MAIN * 16, rom_mem + OSD_ICON_MAIN * 16, 10 * 16), 1);
	key(KEY_MENU);
	trace_reset();
}

static void test_pages(void)
{
	unsigned i, k, steps, mx, sum, cost;
	unsigned char p0[16][4], vol;
	int moved, ontext;
	static unsigned char first[UI_ROWS][OSD2_COLS];

	/* the menu opens: its glyphs over the ROM font, its palette */
	model_init();
	trace_reset();
	key(KEY_MENU);
	key(KEY_F1);
	check("About selected", go("About"), 15);
	model_sync();
	snapshot();

	/* ---- About: the first frame ---- */
	key(KEY_ENTER);
	check("About: the page", ui_focus, UI_F_PAGE);
	check("About: the menu stays open", ui_open_now, 1);
	{
		const char *t = mock_trace();
		const char *f = strstr(t, "20 3c 08 00 "), *pal = strstr(t, "20 4c 08 "), *c = strstr(t, "20 2c ");
		check("About: the logo's first glyph to 0x80", f != NULL, 1);
		check("About: glyphs, palette, then the cells", f && pal && c && f < pal && pal < c, 1);
	}
	model_sync();
	for (k = 0, i = 0; i < OSD_LOGO_GLYPHS; i++)
		k += !memcmp(m_font + ui_fx_code(i) * 16, osd_logo_glyph[i], 16);
	check("About: the 55 logo glyphs in their slots", k, OSD_LOGO_GLYPHS);
	check("About: the icons (0xC0-0xC9) untouched", !memcmp(m_font + 0xC0 * 16, snap_font + 0xC0 * 16, 10 * 16), 1);
	check("About: the menu's glyphs (0x00-0x7F) untouched", !memcmp(m_font, snap_font, 0x80 * 16), 1);
	check("About: the logo row 1, col 18 = logo glyph 0", osd2_chr[1][18], ui_fx_code(osd_logo_map[0][0]));
	check_str("About: the title on the bar", cells(4, 29, 5), "About");
	check_str("About: the credits", cells(6, 19, 26), "Minimig AGA by Rok Krajnc,");
	check_str("About: the cut credits back (TG68K)", cells(10, 15, 33), "TG68K softcore by Tobias Gubener.");
	check_str("About: the cut credits back (logo)", cells(13, 8, 48), "Minimig logo based on a design by Loriano Pagni.");
	check_str("About: the licence", cells(16, 13, 37), "GNU General Public License version 3.");
	check_str("About: the versions", cells(17, 11, 42), "Core 2026-10-27   Firmware 2026-10-28-12-0");
	check("About: a name yellow", osd2_atr[6][34], OSD2_ATTR(OSD2_C_YELLOW, OSD2_C_BLACK));
	check_str("About: the help", cells(18, 1, 9), "Esc back ");
	check("About: the bar's centre band (entry 8)", osd2_atr[4][31] >> 4, 8);
	check("About: the bar's edge band (entry 15)", osd2_atr[4][0] >> 4, 15);
	screen("about");
	pretty("about, the first frame", 1);
	memcpy(first, osd2_chr, sizeof first);

	/* ---- About: the effect, a step per UI_T_FX + 1 counts ---- */
	memcpy(p0, m_pal, sizeof p0);
	wait_counts(UI_T_FX);
	check("About: no step before 3 counts", trace_spi_bytes(), 0);
	wait_counts(1);
	trace_spi_bytes();
	check("About: a step after 3 counts (one window commit)", win_n, 1);
	model_sync();
	check("About: the copper moved one step", memcmp(p0[8], m_pal[8], 4) != 0, 1);
	/* 32 steps later entry 8 + k holds what 8 + k - 1 held: the colours
	   flow outward one band per 32 steps */
	memcpy(p0, m_pal, sizeof p0);
	for (i = 0; i < 32; i++) {
		wait_counts(UI_T_FX + 1);
		model_sync();
	}
	for (k = 0, i = 9; i < 16; i++)
		k += !memcmp(m_pal[i], p0[i - 1], 4);
	check("About: 32 steps rotate the copper one band", k, 7);
	check("About: the menu's colours (0-7) untouched", !memcmp(m_pal, snap_pal, 8 * 4), 1);
	/* the cost of a step, and the stars: they move, never onto the text */
	mx = sum = 0;
	moved = ontext = 0;
	for (steps = 0; steps < 400; steps++) {
		wait_counts(UI_T_FX + 1);
		k = trace_spi_bytes();
		model_sync();
		sum += k;
		if (k > mx)
			mx = k;
		for (i = 0; i < UI_ROWS * OSD2_COLS; i++) {
			unsigned r = i / OSD2_COLS, c = i % OSD2_COLS;
			if (osd2_chr[r][c] != first[r][c]) {
				moved = 1;
				if (!sky(first[r][c]) || !sky(osd2_chr[r][c]) || r >= UI_HELP_ROW || r == 4)
					ontext++;
			}
		}
	}
	check("About: the stars move", moved, 1);
	check("About: never on the logo, the text, the bar or the help", ontext, 0);
	printf("     About: SPI bytes per step: max %u, mean %u\n", mx, sum / steps);
	/* ~65 CPU cycles per SPI byte (plan 3.8): < 50 k cycles per step */
	cost = mx * 65;
	check("About: a step under 50 k cycles of SPI (max bytes x 65)", cost < 50000, 1);
	check("About: a step at most 640 SPI bytes", mx <= 640, 1);

	/* ---- About: Esc back, the menu as it was: cells, glyphs, palette ---- */
	key(KEY_ESC);
	check("About Esc: the list", ui_focus, UI_F_LIST);
	check("About Esc: on About", sel_row(), 15);
	model_sync();
	check("About Esc: the menu's cells as before", same_cells(), 1);
	check("About Esc: the font as before (every glyph)", !memcmp(m_font, snap_font, sizeof m_font), 1);
	check("About Esc: the font RAM = osd_font.mem again", !memcmp(m_font, rom_mem, sizeof m_font), 1);
	check("About Esc: the icons as before", !memcmp(m_font + 0xC0 * 16, snap_font + 0xC0 * 16, 10 * 16), 1);
	check("About Esc: the palette as before", !memcmp(m_pal, snap_pal, sizeof m_pal), 1);
	pass(3);
	check("About Esc: no step after it", trace_spi_bytes(), 0);
	/* Left, Enter and Space close it too; F12 closes the menu; F3 a category */
	key(KEY_ENTER);
	key(KEY_LEFT);
	check("About Left: the list", ui_focus == UI_F_LIST && same_cells(), 1);
	key(KEY_ENTER);
	key(KEY_ENTER);
	check("About Enter: the list", ui_focus == UI_F_LIST && same_cells(), 1);
	key(KEY_ENTER);
	key(KEY_SPACE);
	check("About Space: the list", ui_focus == UI_F_LIST && same_cells(), 1);
	key(KEY_ENTER);
	key(KEY_UP);
	key(KEY_RIGHT);
	check("About Up/Right: still the page", ui_focus, UI_F_PAGE);
	key(KEY_F3);
	check("About F3: System's list", ui_tab == UI_TAB_SYSTEM && ui_focus == UI_F_LIST, 1);
	key(KEY_F1);
	go("About");
	key(KEY_ENTER);
	wait_counts(10);
	model_sync();
	key(KEY_MENU);
	check("About F12: closed", ui_open_now, 0);
	model_sync();
	check("About F12: the font as before", !memcmp(m_font, snap_font, sizeof m_font), 1);
	key(KEY_MENU);
	model_sync();
	check("About F12, opened again: the palette as before", !memcmp(m_pal, snap_pal, sizeof m_pal), 1);

	/* ---- Supporters ---- */
	key(KEY_F1);
	check("Supporters selected", go("Supporters"), 16);
	model_sync();
	snapshot();
	key(KEY_ENTER);
	check("Supporters: the page", ui_focus, UI_F_PAGE);
	model_sync();
	check_str("Supporters: the title", cells(0, 27, 9), "Thanks to");
	check_str("Supporters: the first name", cells(2, 2, 15), "Jens Schoenfeld");
	check_str("Supporters: the longest name", cells(5, 2, 23), "Juan Jose Velez Ramirez");
	check_str("Supporters: column 2", cells(2, 26, 12), "Dirk Vroomen");
	check_str("Supporters: the last name", cells(9, 46, 10), "Tad Watson");
	check_str("Supporters: the other contributors", cells(11, 19, 25), "+ all other contributors.");
	check_str("Supporters: the donation line", cells(17, 3, 28), "Donate: paypal.me/robinsonb5");
	check("Supporters: a name on entry 14, the plasma behind", osd2_atr[2][2] & 15, 14);
	check("Supporters: the plasma's colours behind the text", (osd2_atr[2][2] >> 4) >= 8 && (osd2_atr[2][2] >> 4) <= 13, 1);
	check("Supporters: the icons untouched", !memcmp(m_font + 0xC0 * 16, snap_font + 0xC0 * 16, 10 * 16), 1);
	check_str("Supporters: the help", cells(18, 1, 26), "Down the message  Esc back");
	screen("supporters");
	pretty("supporters, the first frame", 0);
	memcpy(first, osd2_chr, sizeof first);
	/* the plasma: no cell changes, the palette cycles: 16 steps on, entry
	   8 + k holds what 8 + k + 1 held */
	memcpy(p0, m_pal, sizeof p0);
	for (i = 0; i < 16; i++) {
		wait_counts(UI_T_FX + 1);
		model_sync();
	}
	for (k = 0, i = 8; i < 13; i++)
		k += !memcmp(m_pal[i], p0[i + 1], 4);
	check("Supporters: 16 steps cycle the plasma one colour", k, 5);
	check("Supporters: the names faded in part (entry 14 brighter)", m_pal[14][1] > p0[14][1], 1);
	mx = sum = 0;
	for (steps = 0; steps < 200; steps++) {
		wait_counts(UI_T_FX + 1);
		k = trace_spi_bytes();
		model_sync();
		sum += k;
		if (k > mx)
			mx = k;
	}
	check("Supporters: no cell written by the effect", !memcmp(first, osd2_chr, sizeof first), 1);
	printf("     Supporters: SPI bytes per step: max %u, mean %u\n", mx, sum / steps);
	check("Supporters: a step under 10 k cycles of SPI (max bytes x 65)", mx * 65 < 10000, 1);
	check("Supporters: faded in: the names white", m_pal[14][1] == 0xF0 && m_pal[14][2] == 0xF0 && m_pal[14][3] == 0xF0, 1);
	check("Supporters: faded in: the rest yellow", m_pal[15][1] == 0xF0 && m_pal[15][2] == 0xC8 && m_pal[15][3] == 0x28, 1);
	/* Down: the message; Up: the names again */
	key(KEY_DOWN);
	check("Supporters Down: still the page", ui_focus, UI_F_PAGE);
	check_str("Supporters Down: the message", cells(2, 1, 31), "I'm very grateful to these peop");
	check_str("Supporters Down: its last line", cells(9, 1, 60), "on this screen, or the equivalent screen of future projects.");
	check_str("Supporters Down: the help", cells(18, 1, 22), "Up the names  Esc back");
	screen("supporters_msg");
	pretty("supporters, the message", 0);
	model_sync();
	key(KEY_UP);
	check_str("Supporters Up: the names", cells(2, 2, 15), "Jens Schoenfeld");
	key(KEY_ESC);
	check("Supporters Esc: the list", ui_focus, UI_F_LIST);
	model_sync();
	check("Supporters Esc: the menu's cells as before", same_cells(), 1);
	check("Supporters Esc: the font as before", !memcmp(m_font, snap_font, sizeof m_font), 1);
	check("Supporters Esc: the font RAM = osd_font.mem again", !memcmp(m_font, rom_mem, sizeof m_font), 1);
	check("Supporters Esc: the palette as before", !memcmp(m_pal, snap_pal, sizeof m_pal), 1);

	/* a toast over a page: in its help field, then the page's help again */
	key(KEY_ENTER);
	vol = config.audio.volume;
	key(KEY_LSHIFT);
	key(KEY_KPPLUS);
	key(KEY_LSHIFT | KEY_UPSTROKE);
	check_str("page toast: in the help field", cells(18, 1, 4), "vol ");
	config.audio.volume = vol;          /* (the later cases count from it) */
	check("page toast: the page stays", ui_focus, UI_F_PAGE);
	wait_counts(UI_T_TOAST + 1);
	check_str("page toast: gone, the page's help", cells(18, 1, 8), "Down the");
	/* an error while a page shows: the error page, the menu's glyphs back */
	ui_error_show(0);
	model_sync();
	check("page error: the error page", ui_focus, UI_F_ERROR);
	check("page error: the font as before", !memcmp(m_font, snap_font, sizeof m_font), 1);
	key(KEY_ENTER);
	check("page error: Enter closes", ui_open_now, 0);
	ClearError(ERROR_ALL);
	trace_reset();
	calls_clear();
}

/* ---- F6 see-through: the black background (entry 0) transparent ---------
   the palette as the trace wrote it (model_sync); entry 0 {mode << 6, r, g,
   b}: 0x00 opaque, 0x80 the video unchanged.  Starts with the menu closed. */
static int pal0(void)
{
	model_sync();
	return m_pal[0][0];
}

static void test_see_through(void)
{
	static const unsigned char black[4] = { 0, 0, 0, 0 };
	unsigned char before[16][4], sl;
	unsigned k;

	model_init();
	trace_reset();
	key(KEY_MENU);
	check("F6: opened, entry 0 opaque", pal0(), 0x00);
	check_str("F6: the sidebar's hint names it", cells(18, 1, 59), "Up/Down select  Right/Enter open  F12 close  F6 see-through");
	memcpy(before, m_pal, sizeof before);
	key(KEY_F6);
	check_has("F6: entry 0 alone sent, the video mode", mock_trace(), "20 4c 00 80 00 00 00 /", 1);
	check("F6: entry 0 transparent", pal0(), 0x80);
	for (k = 1; k < 16 && !memcmp(m_pal[k], before[k], 4); k++)
		;
	check("F6: entries 1-15 unchanged", k, 16);
	check("F6: the black ink (entry 8) opaque black", !memcmp(m_pal[OSD2_C_INK], black, 4), 1);
	check_str("F6: the toast", cells(18, 1, 20), "See-through on (F6) ");
	check("F6: the focus stays in the sidebar", ui_focus == UI_F_SIDEBAR && ui_open_now, 1);
	wait_counts(UI_T_TOAST + 1);
	check_str("F6: the toast gone, the sidebar's hints again", cells(18, 1, 14), "Up/Down select");
	check("F6: still transparent after the toast", pal0(), 0x80);
	key(KEY_F6);
	check("F6 again: entry 0 opaque", pal0(), 0x00);
	check_str("F6 again: the toast", cells(18, 1, 20), "See-through off (F6)");

	/* the list and EDIT: EDIT stays on, its value on the opaque black ink */
	key(KEY_F4);
	check("Video Scanlines", go("Scanlines"), 2);
	key(KEY_F6);
	check("F6 in the list: transparent", pal0(), 0x80);
	check("F6 in the list: still the list", ui_focus == UI_F_LIST && ui_tab == UI_TAB_VIDEO, 1);
	key(KEY_RIGHT);
	check("Scanlines Right: EDIT", ui_edit, 1);
	wait_counts(UI_T_TOAST + 1);    /* F6's toast gone */
	check_str("EDIT: the hint names F6", cells(18, 1, 45), "Left/Right change  Enter done  F6 see-through");
	check("EDIT: the value's black on the ink (8), not the background (0)",
	      osd2_atr[2][UI_VALUE_END] & 15, OSD2_C_INK);
	key(KEY_F6);
	check("F6 in EDIT: opaque", pal0(), 0x00);
	check("F6 in EDIT: EDIT stays", ui_edit == 1 && ui_focus == UI_F_LIST, 1);
	key(KEY_F6);
	check("F6 in EDIT again: transparent", pal0(), 0x80);
	sl = config.scanlines & 3;
	key(KEY_RIGHT);
	check("EDIT after F6: Right still changes", (config.scanlines & 3) != sl, 1);
	key(KEY_LEFT);
	key(KEY_ENTER);
	check("EDIT done: scanlines back", ui_edit == 0 && (config.scanlines & 3) == sl, 1);

	/* the file selector and a dialog: the focus stays */
	key(KEY_F3);
	go("Kickstart ROM");
	key(KEY_ENTER);
	check("F6 file selector: open", ui_focus, UI_F_FILESEL);
	key(KEY_F6);
	check("F6 in the file selector: opaque, the selector stays", pal0() == 0x00 && ui_focus == UI_F_FILESEL, 1);
	key(KEY_F6);
	key(KEY_ESC);
	key(KEY_F1);
	go("Reset");
	key(KEY_ENTER);
	check("F6 dialog: open", ui_focus, UI_F_DIALOG);
	key(KEY_F6);
	check("F6 in a dialog: opaque, the dialog stays", pal0() == 0x00 && ui_focus == UI_F_DIALOG, 1);
	key(KEY_F6);
	check("F6 in a dialog again: transparent", pal0(), 0x80);
	key(KEY_ESC);
	check("F6 dialog: cancelled", ui_focus, UI_F_LIST);

	/* About: opaque black while it shows, F6 ignored there; Esc: the menu's
	   palette with see-through, exactly as before the page */
	go("About");
	wait_counts(UI_T_TOAST + 1);    /* F6's toast gone */
	model_sync();
	memcpy(before, m_pal, sizeof before);
	key(KEY_ENTER);
	check("About with see-through: the page", ui_focus, UI_F_PAGE);
	check("About with see-through: entry 0 opaque", pal0(), 0x00);
	key(KEY_F6);
	check("About F6: ignored (opaque, the page stays)", pal0() == 0x00 && ui_focus == UI_F_PAGE, 1);
	check_str("About F6: no toast", cells(18, 1, 9), "Esc back ");
	wait_counts(10);
	key(KEY_ESC);
	check("About Esc with see-through: entry 0 transparent again", pal0(), 0x80);
	check("About Esc with see-through: the palette as before the page", !memcmp(m_pal, before, sizeof m_pal), 1);
	go("Supporters");
	key(KEY_ENTER);
	check("Supporters with see-through: entry 0 opaque", pal0(), 0x00);
	key(KEY_ESC);
	check("Supporters Esc with see-through: entry 0 transparent again", pal0(), 0x80);

	/* closed and opened again: re-applied, also after something else (the
	   debug page, menu.c debug2_show) loaded the scheme into the layer */
	key(KEY_MENU);
	check("F6: closed", ui_open_now, 0);
	osd2_pal_default();
	osd2_commit(0, 1, 0, 0, 0, 0);
	check("closed: the debug page's opaque scheme", pal0(), 0x00);
	key(KEY_MENU);
	check("reopened with see-through: entry 0 transparent", pal0(), 0x80);
	key(KEY_F6);
	check("F6 off for the rest", pal0(), 0x00);
	key(KEY_MENU);
	trace_reset();
	calls_clear();
}

int main(int argc, char **argv)
{
	int i;
	unsigned t;
	golddir = argc > 1 ? argv[1] : "gold/ui";
	load_mem(argc > 2 ? argv[2] : "../../../rtl/openaars/adv7511/osd_font.mem");
	setup();

	/* ---- start: closed, the bitmap OSD off ---- */
	pass(1);
	check_has("start: OsdHide", calls, "OsdHide;", 1);
	check("start: the menu closed", ui_open_now, 0);

	/* ---- F12 opens: the keyboard to the OSD (bitmap off), glyphs, cells, window ---- */
	mock_reset();
	mock_timer_step(0);
	calls_clear();
	key(KEY_MENU);
	check("open: ui_open_now", ui_open_now, 1);
	check_has("open: OSD_CMD_OSD 0x02 (keyboard to the OSD, bitmap off)", mock_trace(), KEYS_TO_OSD, 1);
	check_has("open: the window 64 x 20 at (16, 5), scale 2, on", mock_trace(), WIN_MENU_ON, 1);
	check_has("open: no OsdShow (the bitmap stays off)", calls, "OsdShow", 0);
	/* 0x04 empty, 0x05 1/8: rows 3-12 0x80 */
	check_has("open: the bar glyphs uploaded (0x04..)", mock_trace(),
	          "20 3c 00 40 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 80 80 ", 1);
	check_has("open: the icons uploaded (0xC0..)", mock_trace(), "20 3c 0c 00 00 01 03 07 0e ", 1);
	check_has("open: the submenu arrow uploaded (0x16)", mock_trace(), "20 3c 01 60 00 00 00 00 60 70 38 1c ", 1);
	{
		const char *t = mock_trace();
		const char *w = strstr(t, WIN_MENU_ON), *c = strstr(t, "20 2c "), *f = strstr(t, "20 3c ");
		check("open: the cells before the window is switched on", c && w && c < w, 1);
		check("open: the glyphs before the cells", f && c && f < c, 1);
	}
	check("open: the focus in the sidebar", ui_focus, UI_F_SIDEBAR);
	check("open: on Main", ui_tab, UI_TAB_MAIN);
	check_str("open: the sidebar's key hints in the help field", cells(18, 1, 44), "Up/Down select  Right/Enter open  F12 close ");
	check_str("open: the second line empty", cells(19, 1, 15), "               ");
	check("open: Main's bar blue", osd2_atr[3][5], A_SEL);
	check("open: Main's icon, left glyph", osd2_chr[3][1], OSD_ICON_MAIN);
	check("open: Main's icon yellow on the bar", osd2_atr[3][2], OSD2_ATTR(OSD2_C_YELLOW, OSD2_C_BLUE));
	check("open: no item highlighted", sel_row(), -1);
	screen("open");

	/* ---- the sidebar: Up/Down choose the category, its items at once ---- */
	key(KEY_DOWN);
	check("sidebar Down: Storage", ui_tab, UI_TAB_STORAGE);
	check("sidebar Down: the focus stays in the sidebar", ui_focus, UI_F_SIDEBAR);
	check_str("sidebar Down: the header", cells(0, 20, 8), "Storage ");
	check_str("sidebar Down: Storage's items shown at once", cells(2, 20, 13), "Floppy drives");
	check_str("sidebar Down: the category's help", cells(18, 1, 10), "Floppy and");
	check("sidebar Down: Storage's bar blue, Main's black", osd2_atr[6][5] == A_SEL && osd2_atr[3][5] == OSD2_ATTR(OSD2_C_WHITE, OSD2_C_BLACK), 1);
	key(KEY_UP);
	key(KEY_UP);
	check("sidebar Up at the top: Main", ui_tab, UI_TAB_MAIN);
	check_str("sidebar Up: Main's items again", cells(2, 20, 3), "DF0");

	/* ---- into the list and back ---- */
	key(KEY_RIGHT);
	check("Right: the list", ui_focus, UI_F_LIST);
	check("Right: DF0 highlighted", sel_row(), 2);
	check_str("Right: the list's key hints", cells(18, 1, 42), "Up/Down move  Right/Enter edit  Left back ");
	check("Right: Main's bar dark blue (the focus in its list)", osd2_atr[3][5], OSD2_ATTR(OSD2_C_WHITE, OSD2_C_DKBLUE));
	key(KEY_DOWN);
	key(KEY_UP);
	check("Down, Up: DF0", sel_row(), 2);
	check_str("Up/Down in the list: the item's help", cells(18, 1, 15), "Floppy drive 0.");
	screen("main");
	key(KEY_LEFT);
	check("Left on DF0 (no value): back to the sidebar", ui_focus, UI_F_SIDEBAR);
	key(KEY_ENTER);
	check("Enter in the sidebar: the list", ui_focus, UI_F_LIST);
	check("Enter in the sidebar: the cursor where it was", sel_row(), 2);
	key(KEY_ESC);
	check("Esc in the list: the sidebar", ui_focus, UI_F_SIDEBAR);
	check("Esc in the list: still open", ui_open_now, 1);
	key(KEY_ESC);
	check("Esc in the sidebar: closed", ui_open_now, 0);
	key(KEY_MENU);
	key(KEY_SPACE);
	check("Space in the sidebar: the list", ui_focus, UI_F_LIST);
	key(KEY_MENU);
	check("F12 in the list: closed", ui_open_now, 0);
	key(KEY_MENU);
	check("reopened: the sidebar", ui_focus, UI_F_SIDEBAR);
	check_str("reopened: the key hints again", cells(18, 1, 14), "Up/Down select");
	check("reopened: not in EDIT", ui_edit, 0);

	/* ---- Storage: the list, EDIT and back without a change ---- */
	key(KEY_DOWN);
	key(KEY_RIGHT);
	check("Storage list", ui_tab == UI_TAB_STORAGE && ui_focus == UI_F_LIST, 1);
	screen("storage");
	key(KEY_RIGHT);
	check("Storage Right on Floppy drives: EDIT", ui_edit, 1);
	key(KEY_ESC);
	check("Storage Esc: done, config unchanged", ui_edit == 0 && config.floppy.drives == 1, 1);
	check_str("Storage: the item's help", cells(18, 1, 15), "How many floppy");
	key(KEY_F3);
	check("F3: System", ui_tab, UI_TAB_SYSTEM);
	check("F3: into its list", ui_focus, UI_F_LIST);
	screen("system");
	key(KEY_PGDN);
	check("PgDn: Video", ui_tab, UI_TAB_VIDEO);
	check("PgDn in the list: the list", ui_focus, UI_F_LIST);
	screen("video");
	key(KEY_F5);
	screen("accel");
	key(KEY_PGDN);
	check("PgDn wraps: Main", ui_tab, UI_TAB_MAIN);
	key(KEY_ESC);
	key(KEY_PGUP);
	check("PgUp wraps: Acceleration", ui_tab, UI_TAB_ACCEL);
	check("PgUp in the sidebar: the sidebar", ui_focus, UI_F_SIDEBAR);

	/* ---- System: a memory change and the reset prompt on leaving ---- */
	key(KEY_F3);
	calls_clear();
	key(KEY_DOWN);
	key(KEY_DOWN);                  /* past the separator: Chip RAM */
	check_str("System: Chip RAM selected", cells(5, 20, 8), "Chip RAM");
	check("Chip RAM: no change arrows outside EDIT", osd2_chr[5][53] != OSD_G_LEFT && osd2_chr[5][62] != OSD_G_RIGHT, 1);
	key(KEY_LEFT);
	check("Left on Chip RAM (a value): back to the sidebar", ui_focus, UI_F_SIDEBAR);
	check("Left on Chip RAM: the value unchanged", config.memory & 3, 3);
	key(KEY_RIGHT);
	check("Right: the list, on Chip RAM", sel_row(), 5);
	check("Right: not in EDIT yet", ui_edit, 0);
	key(KEY_RIGHT);
	check("Right on Chip RAM: EDIT", ui_edit, 1);
	check("Right on Chip RAM: the value unchanged", config.memory & 3, 3);
	check("EDIT: the change arrows", osd2_chr[5][53] == OSD_G_LEFT && osd2_chr[5][62] == OSD_G_RIGHT, 1);
	check("EDIT: the value black (the ink, entry 8) on yellow", osd2_atr[5][55], OSD2_ATTR(OSD2_C_INK, OSD2_C_YELLOW));
	check_str("EDIT: its hint", cells(18, 1, 30), "Left/Right change  Enter done ");
	key(KEY_LEFT);
	check("Chip RAM Left: 1.5 MB", config.memory & 3, 2);
	check_has("Chip RAM Left: ConfigMemory(22)", calls, "ConfigMemory(22);", 1);
	check("EDIT Left: still in EDIT, the list", ui_edit == 1 && ui_focus == UI_F_LIST, 1);
	key(KEY_ENTER);
	check("Enter in EDIT: done", ui_edit, 0);
	check("Enter in EDIT: the change stays", config.memory & 3, 2);
	check("done: still on Chip RAM", sel_row(), 5);
	key(KEY_ENTER);
	check("Enter on Chip RAM: EDIT again", ui_edit, 1);
	key(KEY_DOWN);
	check("Down in EDIT: done and moved", ui_edit == 0 && sel_row() == 6, 1);
	key(KEY_UP);
	key(KEY_SPACE);
	key(KEY_ESC);
	check("Space then Esc in EDIT: done, in the list", ui_edit == 0 && ui_focus == UI_F_LIST, 1);
	key(KEY_F1);
	check("leaving System after a change: the dialog", ui_focus, UI_F_DIALOG);
	check("leaving System: still on System", ui_tab, UI_TAB_SYSTEM);
	screen("dialog_memory");
	key(KEY_RIGHT);
	key(KEY_ENTER);                 /* No */
	check("No: on to Main", ui_tab, UI_TAB_MAIN);
	check("No: into Main's list (F1)", ui_focus, UI_F_LIST);
	check_has("No: no reset", calls, "OsdReset", 0);
	key(KEY_F3);
	key(KEY_RIGHT);                 /* EDIT */
	key(KEY_RIGHT);                 /* Chip RAM back to 2.0 MB: changed against 1.5 */
	check("EDIT, Right: 2.0 MB", config.memory & 3, 3);
	calls_clear();
	mock_reset();
	mock_timer_step(0);
	key(KEY_MENU);
	check("F12 after a change: the dialog", ui_focus, UI_F_DIALOG);
	key(KEY_ENTER);                 /* Yes (the default) */
	check_has("Yes: closed, then OsdReset", calls, "OsdHide;debug2_show(0);OsdReset;", 1);
	check("Yes: the menu closed", ui_open_now, 0);
	check_has("closing: the window off", mock_trace(), WIN_MENU_OFF, 1);

	/* ---- Volume: a bar, Left/Right, clamped; the LShift shortcut's toast ---- */
	key(KEY_MENU);
	check("reopened on System", ui_tab, UI_TAB_SYSTEM);
	check("System: Volume", go("Volume"), 14);
	key(KEY_RIGHT);
	check("Right on Volume: EDIT", ui_edit, 1);
	calls_clear();
	key(KEY_RIGHT);
	check("Volume Right: 21", config.audio.volume, 21);
	check_has("Volume Right: ConfigAudio(21)", calls, "ConfigAudio(21);", 1);
	check_str("Volume value: 21", cells(14, 59, 2), "21");
	/* 21 / 31 of 16 cells = 87 eighths: 10 full, one 7/8, the rest empty */
	check("Volume bar: cell 0 full", osd2_chr[14][UI_BAR_COL], OSD_G_BAR0 + 8);
	check("Volume bar: cell 9 full", osd2_chr[14][UI_BAR_COL + 9], OSD_G_BAR0 + 8);
	check("Volume bar: cell 10 7/8", osd2_chr[14][UI_BAR_COL + 10], OSD_G_BAR0 + 7);
	check("Volume bar: cell 11 empty", osd2_chr[14][UI_BAR_COL + 11], OSD_G_BAR0);
	check("Volume bar: white on the dark blue track", osd2_atr[14][UI_BAR_COL], OSD2_ATTR(OSD2_C_WHITE, OSD2_C_DKBLUE));
	check("Volume: the change arrows", osd2_chr[14][UI_BAR_COL - 2] == OSD_G_LEFT && osd2_chr[14][62] == OSD_G_RIGHT, 1);
	config.audio.volume = 31;
	calls_clear();
	key(KEY_RIGHT);
	check("Volume clamps at 31", config.audio.volume, 31);
	check_has("Volume at 31: no ConfigAudio", calls, "ConfigAudio", 0);
	check("Volume 31: the bar full", osd2_chr[14][UI_BAR_COL + 15], OSD_G_BAR0 + 8);
	config.audio.volume = 20;
	key(KEY_ENTER);
	check("Enter: EDIT done", ui_edit, 0);
	key(KEY_LSHIFT);
	key(KEY_KPPLUS);
	key(KEY_LSHIFT | KEY_UPSTROKE);
	check("LShift keypad +: 21", config.audio.volume, 21);
	check_str("LShift keypad +: the toast in the help field", cells(18, 1, 22), "vol 21 ###########    ");
	wait_counts(UI_T(1000) + 1);
	check_str("the toast gone after 1 s: the help again", cells(18, 1, 9), "The audio");

	/* ---- Main: eject DF0, the file selector, insert ---- */
	key(KEY_F1);
	check("F1: DF0 selected", sel_row(), 2);
	calls_clear();
	key(KEY_ENTER);
	check("DF0 Enter: ejected", df[0].status, 0);
	check_has("DF0 Enter: the eject sound", calls, "drivesound(1);", 1);
	scans = 0;
	key(KEY_ENTER);
	check("DF0 Enter again: the file selector", ui_focus, UI_F_FILESEL);
	check("file selector: from the root", iCurrentDirectory, 0);
	check("file selector: 16 entries", nDirEntries, 16);
	check("file selector: fat_dir_window 16", fat_dir_window, 16);
	check_str("file selector: the header", cells(0, 20, 10), "Floppy DF0");
	check_str("file selector: its help", cells(18, 1, 26), "Choose a disk image (ADF).");
	screen("filesel");

	/* the selected long name scrolls; unselected long names are cut with ~ */
	check_str("a long name that fits: whole", cells(4, 20, 42), "Another World (1991)(Delphine)            ");
	check_str("Shadow of the Beast: cut with ~", cells(13, 61, 1), "~");
	for (i = 0; i < 11; i++)
		key(KEY_DOWN);
	check_str("Shadow of the Beast selected, from its start", cells(13, 20, 42), "Shadow of the Beast (1989)(Psygnosis)(Disk");
	{
		/* "Shadow of the Beast (1989)(Psygnosis)(Disk 1 of 2)": 50 cells,
		   field 42: 8 steps */
		int tm = 0, step = 0, at[20], back = -1;
		const char *full = "Shadow of the Beast (1989)(Psygnosis)(Disk 1 of 2)";
		char want[43];
		while (tm < 1200 && back < 0) {
			wait_counts(1);
			tm++;
			memcpy(want, full + step + 1, 42);
			want[42] = 0;
			if (step < 8 && !strcmp(cells(13, 20, 42), want))
				at[step++] = tm;
			else if (step == 8 && !strncmp(cells(13, 20, 42), full, 42))
				back = tm;
		}
		check("scroll: 8 steps to the end", step, 8);
		if (step == 8) {
			check("scroll: the start held 500 ms (86 counts)", at[0], 86);
			check("scroll: a step every 128 ms (22 counts)", at[1] - at[0], 22);
			check("scroll: the last step on time", at[7] - at[6], 22);
			check("scroll: the end held 1 s (172 counts), then the start", back - at[7], 172);
		}
		wait_counts(86 - 1);
		check("scroll: the start held again", strncmp(cells(13, 20, 42), full, 42), 0);
		wait_counts(1);
		check("scroll: and again", strncmp(cells(13, 20, 42), full + 1, 42), 0);
		wait_counts(30);
		key(KEY_DOWN);
		key(KEY_UP);
		check("scroll: a cursor move resets it", strncmp(cells(13, 20, 42), full, 42), 0);
		wait_counts(85);
		check("scroll: and holds the start again", strncmp(cells(13, 20, 42), full, 42), 0);
	}

	/* a letter, a directory and back, then insert */
	key(0x24);                      /* G: after Shadow, round to Games */
	check_str("letter G: Games", cells(2 + iSelectedEntry, 20, 5), "Games");
	key(0x24);
	check_str("letter G again: Gods", cells(2 + iSelectedEntry, 20, 4), "Gods");
	key(KEY_HOME);
	check("Home: the first entry", iSelectedEntry, 0);
	key(KEY_ENTER);                 /* Games */
	check("Enter on a directory: in it", iCurrentDirectory, 5);
	check_str("in Games: the parent first", cells(2, 20, 7), "..     ");
	check_str("in Games: <DIR>", cells(2, 57, 5), "<DIR>");
	key(KEY_BACK);
	check("Backspace: the root", iCurrentDirectory, 0);
	check_str("Backspace: on Games", cells(2 + iSelectedEntry, 20, 5), "Games");
	key(0x28);                      /* L */
	check_str("letter L: Lemmings", cells(2 + iSelectedEntry, 20, 8), "Lemmings");
	calls_clear();
	key(KEY_ENTER);
	check("insert: back to the list", ui_focus, UI_F_LIST);
	check("insert: DF0 inserted, writable", df[0].status, DSK_INSERTED | DSK_WRITABLE);
	check_str("insert: DF0's name, right-aligned", cells(2, 49, 12), "    Lemmings");
	check("insert: 160 tracks", df[0].tracks, 160);
	check_has("insert: the insert sound", calls, "drivesound(0);", 1);
	check_str("insert: the cursor on DF1", cells(3, 20, 3), "DF1");
	check("insert: highlighted", osd2_atr[3][20], A_SEL);

	/* the selector again with the same kind of file: where it was */
	scans = 0;
	key(KEY_ENTER);
	check("DF1: the selector without a new scan", scans, 0);
	check_str("DF1: still on Lemmings", cells(2 + iSelectedEntry, 20, 8), "Lemmings");
	key(KEY_PGDN);
	key(KEY_PGDN);
	check_str("PgDn twice: the last entry", cells(2 + iSelectedEntry, 20, 6), "Zool 2");
	key(KEY_ESC);
	check("Esc: back to the list", ui_focus, UI_F_LIST);
	check("Esc: DF1 still empty", df[1].status, 0);

	/* ---- keypad +: a drive more (after a reset) ---- */
	calls_clear();
	key(KEY_KPPLUS);
	check("keypad +: 3 drives", config.floppy.drives, 2);
	check_has("keypad +: ConfigFloppy(2,0)", calls, "ConfigFloppy(2,0);", 1);
	check_str("DF2: active after reset", cells(4, 39, 22), "* active after reset *");
	check("DF2: greyed (dark blue)", osd2_atr[4][39], A_GREY);

	/* ---- the CD-ROM: insert, eject, locked ---- */
	key(KEY_DOWN);                  /* DF2, DF3 are not selectable: the CD */
	check_str("CD selected", cells(6, 20, 2), "CD");
	key(KEY_ENTER);
	check("CD Enter: the selector", ui_focus, UI_F_FILESEL);
	check_str("CD selector: the header", cells(0, 20, 12), "CD-ROM image");
	key(KEY_DOWN);
	key(KEY_DOWN);
	calls_clear();
	key(KEY_ENTER);                 /* Another World */
	check_has("CD: CD_Insert", calls, "CD_Insert(ANOTHE~1ADF,Another World (1991)(Delphine),0);", 1);
	check_str("CD: its name (25 cells), right-aligned", cells(6, 36, 25), "Another World (1991)(Delp");
	cdrom.unit.locked = 1;
	key(KEY_ENTER);
	check_str("CD locked: the message", cells(6, 42, 19), "locked by the Amiga");
	check("CD locked: still in", cdrom.unit.media, 1);
	cdrom.unit.locked = 0;
	key(KEY_ENTER);
	check("CD eject", cdrom.unit.media, 0);

	/* ---- Load configuration: the slots that exist ---- */
	key(KEY_DOWN);
	check_str("Load selected, Default", cells(8, 54, 7), "Default");
	key(KEY_RIGHT);
	check("Load Right: EDIT (choose the slot)", ui_edit, 1);
	check("Load EDIT: the left change arrow", osd2_chr[8][52], OSD_G_LEFT);
	key(KEY_RIGHT);
	check_str("Load Right: slot 2 (1 has no file)", cells(8, 60, 1), "2");
	key(KEY_LEFT);
	key(KEY_LEFT);
	check_str("Load Left twice: back over Default to 2", cells(8, 60, 1), "2");
	key(KEY_ENTER);
	check("Load Enter in EDIT: done, no dialog", ui_edit == 0 && ui_focus == UI_F_LIST, 1);
	key(KEY_ENTER);
	check("Load Enter: a dialog", ui_focus, UI_F_DIALOG);
	check_str("Load dialog: the dialog's hints", cells(18, 1, 26), "Left/Right choose a button");
	screen("dialog_load");
	calls_clear();
	mock_reset();
	mock_timer_step(0);
	key(KEY_ENTER);
	check_has("Load: the classic sequence", calls, "Load(2);Apply(1,1);OsdDoReset(3,0);OsdHide;", 1);
	check("Load: closed", ui_open_now, 0);

	/* ---- Save: overwrite asks, a new slot does not ---- */
	key(KEY_MENU);
	key(KEY_RIGHT);                 /* the list, on Load */
	key(KEY_DOWN);
	check_str("Save selected", cells(9, 20, 4), "Save");
	check_str("Save: Default (exists)", cells(9, 45, 16), "Default (exists)");
	calls_clear();
	key(KEY_ENTER);
	check("Save over a file: a dialog", ui_focus, UI_F_DIALOG);
	key(KEY_ESC);
	check_has("Esc: not saved", calls, "Save", 0);
	check("Esc in a dialog: back to the list", ui_focus, UI_F_LIST);
	key(KEY_RIGHT);                 /* EDIT */
	key(KEY_RIGHT);                 /* slot 1 */
	key(KEY_ENTER);                 /* done */
	check_has("Save: EDIT done saves nothing", calls, "Save", 0);
	key(KEY_ENTER);
	check_has("Save to 1: saved at once", calls, "Save(1);", 1);
	check_str("Save: the toast", cells(18, 1, 19), "Configuration saved");
	check_str("Save: 1 (exists) now", cells(9, 51, 10), "1 (exists)");

	/* ---- Reset: Right opens its dialog (a submenu item), Yes ---- */
	key(KEY_DOWN);
	key(KEY_DOWN);                  /* Reboot; Chameleon is hidden on this platform */
	check_str("Reboot selected", cells(12, 20, 6), "Reboot");
	check("Reboot: the submenu arrow", osd2_chr[12][62], OSD_G_SUB);
	key(KEY_UP);
	calls_clear();
	key(KEY_RIGHT);
	check("Right on Reset: its dialog", ui_focus, UI_F_DIALOG);
	key(KEY_ENTER);
	check_has("Reset: closed, then OsdReset", calls, "OsdHide;debug2_show(0);OsdReset;", 1);

	/* ---- Kickstart: the selector, the dialog (No first) ---- */
	key(KEY_MENU);
	key(KEY_F3);
	check("Kickstart selected", go("Kickstart ROM"), 10);
	check_str("Kickstart: kick31.rom, right-aligned", cells(10, 51, 10), "kick31.rom");
	check("Kickstart: the submenu arrow", osd2_chr[10][62], OSD_G_SUB);
	scans = 0;
	key(KEY_ENTER);
	check("Kickstart: another kind of file, scanned again", scans > 0, 1);
	key(0x14);                      /* T: Turrican */
	for (i = 0; i < 8; i++)
		key(KEY_UP);                /* Kick31.rom */
	check_str("Kick31.rom selected", cells(2 + iSelectedEntry, 20, 6), "Kick31");
	key(KEY_ENTER);
	check("chosen: the dialog", ui_focus, UI_F_DIALOG);
	screen("dialog_kick");
	calls_clear();
	key(KEY_ENTER);                 /* No (the default) */
	check_has("No: nothing loaded", calls, "Apply", 0);
	check_str("No: the Kickstart unchanged", config.kickstart.long_name, "kick31.rom");
	key(KEY_ENTER);
	key(KEY_ENTER);
	key(KEY_LEFT);
	calls_clear();
	key(KEY_ENTER);                 /* Yes */
	check_has("Yes: the reload sequence", calls, "OsdDoReset(0,6);Apply(1,0);OsdDoReset(3,0);OsdHide;", 1);
	check_str("Yes: the Kickstart's name", config.kickstart.long_name, "Kick31");

	/* ---- F12 in the file selector and in a dialog: closed ---- */
	key(KEY_MENU);
	key(KEY_F3);
	go("Kickstart ROM");
	key(KEY_ENTER);
	check("the selector open", ui_focus, UI_F_FILESEL);
	key(KEY_MENU);
	check("F12 in the file selector: closed", ui_open_now, 0);
	key(KEY_MENU);
	key(KEY_F1);
	go("Reset");
	key(KEY_ENTER);
	check("the Reset dialog", ui_focus, UI_F_DIALOG);
	calls_clear();
	key(KEY_MENU);
	check("F12 in a dialog: closed", ui_open_now, 0);
	check_has("F12 in a dialog: cancelled, no reset", calls, "OsdReset", 0);

	/* ---- the ROM font and the menu's glyphs ---- */
	test_rom_font();
	/* ---- About and Supporters: pages of their own (plan 3.8) ---- */
	test_pages();
	/* ---- F6 see-through ---- */
	test_see_through();
	/* no other hand-over is left: no item of any category is "classic" */
	{
		int n = 0;
		for (t = 0; t < UI_TABS; t++)
			for (i = 0; i < ui_tabs[t].n; i++)
				if (ui_tabs[t].items[i].label && strstr(ui_tabs[t].items[i].label, "lassic"))
					n++;
		check("no Classic menu item left", n, 0);
	}

	/* ---- toasts with the menu closed: their own window ---- */
	mock_reset();
	mock_timer_step(0);
	calls_clear();
	key(KEY_CTRL);
	key(KEY_LALT);
	key(KEY_KPPLUS);
	check("Ctrl-Alt-keypad +: turbo", config.chipset & CONFIG_TURBO, CONFIG_TURBO);
	check_has("Ctrl-Alt-keypad +: ConfigChipset", calls, "ConfigChipset(19);", 1);
	check_has("toast: its window on", mock_trace(), WIN_TOAST_ON, 1);
	check_str("toast: TURBO, centred", cells(0, 0, 40), "                 TURBO                  ");
	key(KEY_KP0);
	check("Ctrl-Alt-keypad 0: autofire fast", config.autofire, 1);
	check_str("toast: autofire", cells(0, 13, 13), "AUTOFIRE FAST");
	key(KEY_CTRL | KEY_UPSTROKE);
	key(KEY_LALT | KEY_UPSTROKE);
	wait_counts(UI_T(1000));
	check_has("toast: still on before 1 s", mock_trace(), WIN_TOAST_OFF, 0);
	wait_counts(1);
	check_has("toast: its window off after 1 s", mock_trace(), WIN_TOAST_OFF, 1);
	check_has("toast: the bitmap OSD never on", calls, "OsdShow", 0);

	/* ---- Ctrl-Alt-F12: debug mode on the classic OSD, closed ---- */
	calls_clear();
	key(KEY_CTRL);
	key(KEY_LALT);
	key(KEY_MENU);
	key(KEY_CTRL | KEY_UPSTROKE);
	key(KEY_LALT | KEY_UPSTROKE);
	check("Ctrl-Alt-F12: DebugMode", DebugMode, 1);
	check_has("Ctrl-Alt-F12: SanityCheck, the debug page on the layer", calls, "SanityCheck;OsdHide;debug2_show(1);", 1);
	debug_draws = 0;
	pass(3);
	check("debug mode: the lines drawn every pass", debug_draws, 3);
	key(KEY_MENU);
	check_has("menu over debug mode: the keyboard to the OSD, bitmap off", mock_trace(), KEYS_TO_OSD, 1);
	check_has("menu over debug mode: the menu's window", mock_trace(), WIN_MENU_ON, 1);
	calls_clear();
	mock_reset();
	mock_timer_step(0);
	key(KEY_ESC);
	check_has("closing in debug mode: the debug page back on the layer", calls, "OsdHide;debug2_show(1);", 1);
	check_has("closing in debug mode: the layer not switched off", mock_trace(), WIN_MENU_OFF, 0);
	check_has("debug mode: the bitmap OSD never on", calls, "OsdShow", 0);
	/* a toast in debug mode: the debug lines wait, then the page comes back */
	calls_clear();
	mock_reset();
	mock_timer_step(0);
	key(KEY_LSHIFT);
	key(KEY_KPPLUS);
	key(KEY_LSHIFT | KEY_UPSTROKE);
	check_has("debug mode toast: its window on", mock_trace(), WIN_TOAST_ON, 1);
	check_str("debug mode toast: on row 0", cells(0, 11, 7), "vol 22 ");
	debug_draws = 0;
	pass(3);
	check("debug mode toast: the debug lines not drawn over it", debug_draws, 0);
	wait_counts(UI_T(1000) + 1);
	check_has("debug mode toast ends: the debug page back", calls, "debug2_show(1);", 1);
	check_has("debug mode toast ends: the layer not switched off", mock_trace(), WIN_TOAST_OFF, 0);
	pass(1);
	check("debug mode toast ended: the debug lines again", debug_draws > 0, 1);
	/* debug mode off: the layer off */
	calls_clear();
	key(KEY_CTRL);
	key(KEY_LALT);
	key(KEY_MENU);
	key(KEY_CTRL | KEY_UPSTROKE);
	key(KEY_LALT | KEY_UPSTROKE);
	check("Ctrl-Alt-F12 again: DebugMode off", DebugMode, 0);
	check_has("debug mode off: the page off", calls, "OsdHide;debug2_show(0);", 1);

	/* ================= Phase 4: every setting native ================= */

	/* ---- the error page (menu.c ShowError on a core with the layer) ---- */
	key(KEY_MENU);                  /* the menu open on Main ... */
	key(KEY_F1);
	SetError(ERROR_FDD, "ADF has too many tracks!", 170, 0);
	calls_clear();
	ui_error_show(ERROR_FDD);       /* ... the error page over it */
	pass(1);
	check("error: the menu open", ui_open_now, 1);
	check("error: the error page", ui_focus, UI_F_ERROR);
	check_str("error: the header", cells(0, 20, 6), "Error ");
	check_str("error: the category", cells(5, 20, 16), "Floppy emulation");
	check_str("error: its text", cells(6, 20, 24), "ADF has too many tracks!");
	check_str("error: a in hex", cells(7, 20, 5), "0xAA ");
	check_str("error: the page number", cells(5, 55, 6), "4 of 5");
	check_str("error: OK", cells(11, 20, 4), " OK ");
	screen("error");
	key(KEY_MENU);
	key(KEY_ESC);
	check("error: F12 and Esc leave it open (as the classic page)", ui_open_now == 1 && ui_focus == UI_F_ERROR, 1);
	key(KEY_LEFT);
	check_str("error Left: Kickstart ROM", cells(5, 20, 13), "Kickstart ROM");
	check("error Left: greyed (no error there)", osd2_atr[5][20], A_GREY);
	key(KEY_RIGHT);
	key(KEY_RIGHT);
	key(KEY_RIGHT);
	check_str("error Right x3: Harddrive, then wraps to SD Card", cells(5, 20, 7), "SD Card");
	key(KEY_ENTER);
	check("error Enter: closed", ui_open_now, 0);
	check("error Enter: the error cleared", ErrorMask, 0);
	check_has("error Enter: no reboot", calls, "ColdBoot", 0);
	FatalError(ERROR_SDCARD, "no card", 1, 2);
	ui_error_show(ERROR_SDCARD);
	pass(1);
	check_str("fatal: the header", cells(0, 20, 11), "Fatal error");
	check_str("fatal: Reboot", cells(11, 20, 8), " Reboot ");
	calls_clear();
	key(KEY_SPACE);
	check_has("fatal Space: reboots", calls, "ColdBoot", 1);
	ClearError(ERROR_ALL);

	/* ---- Storage: the floppies at once ---- */
	key(KEY_MENU);
	key(KEY_F2);
	calls_clear();
	check("Storage: Floppy drives", go("Floppy drives"), 2);
	config.floppy.drives = 3;       /* 4 drives: Right wraps to 1 (the classic cycle) */
	key(KEY_RIGHT);
	key(KEY_RIGHT);
	check("Floppy drives Right: 4 -> 1", config.floppy.drives, 0);
	check_has("Floppy drives: ConfigFloppy(0,0)", calls, "ConfigFloppy(0,0);", 1);
	key(KEY_LEFT);
	check("Floppy drives Left: 4 again", config.floppy.drives, 3);
	key(KEY_LEFT);
	key(KEY_LEFT);
	check("Floppy drives Left twice: 2", config.floppy.drives, 1);
	key(KEY_DOWN);                  /* EDIT done, Floppy turbo */
	key(KEY_RIGHT);
	key(KEY_RIGHT);
	check("Floppy turbo: on", config.floppy.speed, 1);
	check_has("Floppy turbo: ConfigFloppy(1,1)", calls, "ConfigFloppy(1,1);", 1);
	key(KEY_LEFT);
	key(KEY_ENTER);
	check("Floppy sounds without the sounds file: greyed", osd2_atr[4][20], A_GREY);
	key(KEY_DOWN);
	check("Down from Floppy turbo: over the greyed sounds, IDE", sel_row(), 6);
	ds_loaded = 1;
	key(KEY_UP);
	check("with the sounds file: Floppy sounds selectable", sel_row(), 4);
	calls_clear();
	key(KEY_RIGHT);
	key(KEY_RIGHT);
	check("Floppy sounds on", config.drivesounds & DRIVESOUNDS_FLOPPY, DRIVESOUNDS_FLOPPY);
	check_has("Floppy sounds on: enabled", calls, "ds_enable(1);", 1);
	key(KEY_LEFT);
	check_has("Floppy sounds off: disabled", calls, "ds_disable(1);", 1);
	key(KEY_ENTER);
	ds_loaded = 0;
	key(KEY_F1);
	check("leaving Storage, floppies changed only: no dialog", ui_tab == UI_TAB_MAIN && ui_focus == UI_F_LIST, 1);

	/* ---- Storage: IDE on/off greys the drives; back unchanged: no dialog ---- */
	key(KEY_F2);
	go("IDE");
	key(KEY_RIGHT);
	key(KEY_RIGHT);
	check("IDE Right: off (the edit copy)", mm_ide_on, 0);
	check("IDE off: config not yet", config.enable_ide, 1);
	check("IDE off: Port 1 master greyed", osd2_atr[7][20], A_GREY);
	check("IDE off: Hard disk sounds greyed", osd2_atr[15][20], A_GREY);
	key(KEY_RIGHT);
	key(KEY_ENTER);
	calls_clear();
	key(KEY_F1);
	check("IDE back on: no dialog on leaving", ui_tab == UI_TAB_MAIN && ui_focus == UI_F_LIST, 1);
	check_has("no change: no reset", calls, "OsdReset", 0);

	/* ---- Storage: a hardfile without a partition table, the reset prompt, No ---- */
	key(KEY_F2);
	check("Port 1 slave", go("Port 1 slave"), 9);
	check_str("Port 1 slave: Disabled", cells(9, 53, 8), "Disabled");
	check("its file: not selectable while Disabled", osd2_atr[10][20], A_GREY);
	key(KEY_RIGHT);
	key(KEY_RIGHT);
	check_str("type Right: Hardfile (disk img)", cells(9, 42, 19), "Hardfile (disk img)");
	key(KEY_LEFT);
	key(KEY_LEFT);
	check_str("type Left twice: backwards round to SD partition 1", cells(9, 47, 14), "SD partition 1");
	key(KEY_RIGHT);
	key(KEY_RIGHT);
	check_str("type Right twice: Hardfile (disk img)", cells(9, 42, 19), "Hardfile (disk img)");
	key(KEY_DOWN);
	check_str("its file: not found yet", cells(10, 41, 20), "** file not found **");
	key(KEY_ENTER);
	check("file Enter: the selector", ui_focus, UI_F_FILESEL);
	check_str("selector: Hard disk image: Port 1 slave", cells(0, 20, 30), "Hard disk image: Port 1 slave ");
	key(KEY_HOME);
	key(KEY_DOWN);
	key(KEY_DOWN);
	key(KEY_DOWN);                  /* Arkanoid */
	hdf_filetype = HDF_FILETYPE_UNKNOWN;
	calls_clear();
	key(KEY_ENTER);
	check_has("chosen: its type probed", calls, "GetHDFFileType(ARKANOIDADF);", 1);
	check("no partition table: the warning", ui_focus, UI_F_DIALOG);
	screen("dialog_nordb");
	key(KEY_ENTER);
	check("OK: back to the list, on the file", ui_focus == UI_F_LIST && sel_row() == 10, 1);
	check_str("the file: Arkanoid", cells(10, 53, 8), "Arkanoid");
	check("config not yet changed", config.hardfile[1].enabled, 0);
	key(KEY_F1);
	check("leaving Storage after a change: the reset dialog", ui_focus, UI_F_DIALOG);
	check("leaving: still on Storage", ui_tab, UI_TAB_STORAGE);
	screen("dialog_hdf");
	calls_clear();
	key(KEY_ENTER);                 /* No, the default (the classic menusub 1) */
	check("No: on to Main", ui_tab == UI_TAB_MAIN && ui_focus == UI_F_LIST, 1);
	check("No: config unchanged", config.hardfile[1].enabled, 0);
	check_has("No: no reset, nothing opened", calls, "OpenHardfile", 0);
	key(KEY_F2);
	check_str("back on Storage: the change dropped", cells(9, 53, 8), "Disabled");

	/* ---- the same with an RDB hardfile, F12, Yes: applied and reset ---- */
	go("Port 1 slave");
	key(KEY_RIGHT);
	key(KEY_RIGHT);
	key(KEY_DOWN);
	key(KEY_ENTER);
	key(KEY_HOME);
	key(KEY_DOWN);
	key(KEY_DOWN);
	key(KEY_DOWN);
	hdf_filetype = HDF_FILETYPE_RDB;
	key(KEY_ENTER);
	check("an RDB hardfile: no warning", ui_focus, UI_F_LIST);
	calls_clear();
	trace_reset();
	key(KEY_MENU);
	check("F12 after a change: the reset dialog", ui_focus, UI_F_DIALOG);
	key(KEY_LEFT);
	key(KEY_ENTER);                 /* Yes */
	check_has("Yes: closed, slot 1 opened, CD, ports, reset",
	          calls, "OsdHide;debug2_show(0);OpenHardfile(1);ApplyCDROM;ConfigIDEPorts;OsdReset;", 1);
	check("Yes: config has the hardfile", config.hardfile[1].enabled == HDF_FILE && config.hardfile[1].present == 1 &&
	      !memcmp(config.hardfile[1].name, "ARKANOID", 8), 1);
	check("Yes: the menu closed", ui_open_now, 0);

	/* ---- the live CD slot: a disc at once, no reset ---- */
	cd_msg_on = 0;                  /* (the locked message of the Main test) */
	key(KEY_MENU);
	check("reopened on Storage", ui_tab, UI_TAB_STORAGE);
	check("Port 2 master", go("Port 2 master"), 11);
	check_str("Port 2 master: the CD-ROM", cells(11, 49, 12), "CD-ROM (ISO)");
	key(KEY_DOWN);
	check_str("its disc: none", cells(12, 50, 11), "* no disc *");
	key(KEY_ENTER);
	check_str("CD slot: the selector's header", cells(0, 20, 27), "CD-ROM image: Port 2 master");
	key(KEY_HOME);
	key(KEY_DOWN);
	key(KEY_DOWN);
	calls_clear();
	key(KEY_ENTER);
	check_has("live CD slot: CD_Insert at once", calls, "CD_Insert(ANOTHE~1ADF,Another World (1991)(Delphine),0);", 1);
	key(KEY_F1);
	check("live disc change: no reset dialog", ui_tab == UI_TAB_MAIN && ui_focus == UI_F_LIST, 1);
	key(KEY_F2);
	calls_clear();
	go("Hard disk sounds");
	key(KEY_RIGHT);
	key(KEY_RIGHT);
	check("Hard disk sounds on", config.drivesounds & DRIVESOUNDS_HDD, DRIVESOUNDS_HDD);
	check_has("Hard disk sounds: enabled", calls, "ds_enable(2);", 1);
	key(KEY_LEFT);
	key(KEY_ENTER);

	/* ---- Video ---- */
	key(KEY_F4);
	screen("video_edit");
	calls_clear();
	check("Scanlines", go("Scanlines"), 2);
	key(KEY_RIGHT);
	key(KEY_RIGHT);
	check("Scanlines Right: black", config.scanlines & 3, 2);
	check_has("Scanlines: ConfigVideo", calls, "ConfigVideo(18,1,0,0);", 1);
	key(KEY_RIGHT);
	check("Scanlines Right: wraps to off (3 values)", config.scanlines & 3, 0);
	key(KEY_RIGHT);
	key(KEY_DOWN);                  /* dim again; Scaling */
	key(KEY_RIGHT);
	key(KEY_RIGHT);
	check("Scaling Right: area -> line rate", CONFIG_SCALING(config.scanlines), SCALING_LINE);
	key(KEY_RIGHT);
	check("Scaling Right: line rate -> sharp (the classic cycle)", CONFIG_SCALING(config.scanlines), SCALING_SHARP);
	key(KEY_RIGHT);
	key(KEY_DOWN);                  /* area again; CRT mask */
	key(KEY_RIGHT);
	key(KEY_LEFT);
	check("CRT mask Left: off", config.crt_mask, 0);
	key(KEY_RIGHT);
	key(KEY_DOWN);                  /* grille again; Bloom */
	key(KEY_RIGHT);
	key(KEY_RIGHT);
	check("Bloom Right: low", config.crt_bloom, 1);
	key(KEY_LEFT);
	key(KEY_ENTER);
	/* Bloom needs a gap to fill: scanlines off, beam off, line rate -> greyed */
	config.scanlines = (unsigned char)(SCALING_LINE << SCALING_SHIFT);
	key(KEY_UP);
	check("no scanlines, no beam, line rate: Bloom greyed", osd2_atr[5][20], A_GREY);
	key(KEY_DOWN);
	check("Down from CRT mask: over Bloom", sel_row(), 6);
	config.scanlines = 1 | (SCALING_AREA << SCALING_SHIFT);
	/* the position: the PAL pair on a version-1 layer (no byte 14 asked) */
	calls_clear();
	ver_reads = 0;
	check("Position (PAL) horizontal", go("Position (PAL) horizontal"), 8);
	key(KEY_RIGHT);
	key(KEY_RIGHT);
	check("H Right: -8 -> 0", (signed char)config.videopos.hpos, 0);
	check_str("H: 0 px", cells(8, 57, 4), "0 px");
	key(KEY_LEFT);
	key(KEY_LEFT);
	check("H Left twice: -16", (signed char)config.videopos.hpos, -16);
	check_has("H: both pairs to the core", calls, "VPos(04f0,0000);", 1);
	key(KEY_DOWN);
	key(KEY_RIGHT);
	key(KEY_RIGHT);
	check("V Right: 4 -> 6 (VPOS_STEP)", config.videopos.vpos, 4 + VPOS_STEP);
	check_str("V: +6 lines", cells(9, 53, 8), "+6 lines");
	check("version-1 layer: byte 14 never asked", ver_reads, 0);
	config.videopos.vpos = VPOS_MAX;
	key(KEY_RIGHT);
	check("V clamps at VPOS_MAX", config.videopos.vpos, VPOS_MAX);
	config.videopos.vpos = 4;
	key(KEY_ENTER);
	/* a version-2 layer: byte 14 asked, the RTG screen on: its own pair */
	layer_version(2);
	ver_status = 1;
	key(KEY_F1);
	key(KEY_F4);
	check("Video shown: byte 14 asked", ver_reads, 1);
	check_str("RTG on: the label says RTG", cells(8, 20, 25), "Position (RTG) horizontal");
	go("Position (RTG) horizontal");
	calls_clear();
	key(KEY_RIGHT);
	key(KEY_RIGHT);
	check("RTG: H Right edits the RTG pair", (signed char)config.videopos_rtg.hpos, 8);
	check("RTG: the PAL pair untouched", (signed char)config.videopos.hpos, -16);
	check_has("RTG: both pairs to the core", calls, "VPos(04f0,0008);", 1);
	check("RTG: byte 14 asked again at the step", ver_reads, 2);
	ver_status = 0;                 /* RTG off meanwhile: the next step is PAL's */
	key(KEY_RIGHT);
	check("RTG off: H Right edits PAL", (signed char)config.videopos.hpos, -8);
	check("RTG off: the RTG pair kept", (signed char)config.videopos_rtg.hpos, 8);
	check_str("RTG off: the label says PAL", cells(8, 20, 25), "Position (PAL) horizontal");
	key(KEY_ENTER);
	layer_version(1);
	/* the HDMI clock delay: the readback in the help field */
	check("HDMI clock delay", go("HDMI clock delay"), 10);
	check_str("HDMI: the readback (ff: no answer)", cells(19, 1, 42), "Chip 0xBA: ff  set: 80  INT 0  serviced 12");
	calls_clear();
	key(KEY_RIGHT);
	key(KEY_RIGHT);
	check("HDMI Right: 5", adv_clkdelay, 5);
	check("HDMI: saved + 1", config.hdmi_clkdelay, 6);
	check_str("HDMI: +0.8 ns", cells(10, 54, 7), "+0.8 ns");
	check_str("HDMI: the help in EDIT is EDIT's hint", cells(18, 1, 17), "Left/Right change");
	key(KEY_ENTER);
	key(KEY_UP);
	key(KEY_DOWN);
	check_str("HDMI: the readback after the change", cells(19, 1, 23), "Chip 0xBA: a0  set: a0 ");
	adv_services = 13;
	wait_counts(UI_T(1000) + 1);
	check_str("HDMI: the readback live, every second", cells(19, 32, 11), "serviced 13");
	key(KEY_RIGHT);
	for (i = 0; i < 5; i++)
		key(KEY_RIGHT);
	check("HDMI clamps at 7", adv_clkdelay, 7);
	key(KEY_ENTER);
	adv7511_set_clkdelay(4);
	adv_chip = 0xff;

	/* ---- OSD size and position (config.autofire bits 5:3): live, in the
	   config (saved with it); bits 0, a config file of older firmware:
	   Large, Centre ---- */
	config.autofire = 0x05;         /* CD32 pad on, autofire fast: kept */
	check("OSD size", go("OSD size"), 12);
	check_str("OSD size: large (the bits 0)", cells(12, 56, 5), "large");
	check_str("OSD position: centre (the bits 0)", cells(13, 55, 6), "centre");
	key(KEY_RIGHT);                 /* EDIT */
	trace_reset();
	key(KEY_RIGHT);
	check("OSD size Right: small", config.autofire & CONFIG_OSD_SMALL, CONFIG_OSD_SMALL);
	check("OSD size: autofire and CD32 pad kept", config.autofire & 0x07, 0x05);
	check_has("OSD size small: the window at once, scale 1, (48, 25)", mock_trace(), "20 5c 01 30 19 40 14 /", 1);
	check_has("OSD size: nothing to the core", calls, "ConfigAutofire", 0);
	check_str("OSD size: small shown", cells(12, 56, 5), "small");
	key(KEY_DOWN);                  /* done; OSD position */
	check("OSD position", sel_row(), 13);
	key(KEY_RIGHT);
	trace_reset();
	key(KEY_RIGHT);
	check("OSD position Right: top", CONFIG_OSD_POS(config.autofire), CONFIG_OSD_TOP);
	check_has("OSD position top: small at (48, 4)", mock_trace(), "20 5c 01 30 04 40 14 /", 1);
	trace_reset();
	key(KEY_RIGHT);
	check("OSD position Right: bottom", CONFIG_OSD_POS(config.autofire), CONFIG_OSD_BOTTOM);
	check_has("OSD position bottom: small at (48, 46)", mock_trace(), "20 5c 01 30 2e 40 14 /", 1);
	check("OSD position: the size kept", config.autofire & CONFIG_OSD_SMALL, CONFIG_OSD_SMALL);
	check("OSD position: autofire and CD32 pad kept", config.autofire & 0x07, 0x05);
	screen("video_osd");
	key(KEY_RIGHT);
	check("OSD position Right: round to centre (3 values)", (config.autofire & CONFIG_OSD_POS_MASK) >> CONFIG_OSD_POS_SHIFT, CONFIG_OSD_CENTRE);
	key(KEY_LEFT);
	key(KEY_ENTER);
	key(KEY_UP);                    /* OSD size: back to large, at the bottom */
	key(KEY_RIGHT);
	trace_reset();
	key(KEY_LEFT);
	check("OSD size Left: large", config.autofire & CONFIG_OSD_SMALL, 0);
	check_has("OSD large at the bottom: scale 2, (16, 10)", mock_trace(), "20 5c 03 10 0a 40 14 /", 1);
	key(KEY_DOWN);
	key(KEY_RIGHT);
	trace_reset();
	key(KEY_LEFT);
	check_has("OSD large at the top: (16, 2)", mock_trace(), "20 5c 03 10 02 40 14 /", 1);
	key(KEY_ENTER);
	/* the menu opens where the config says */
	key(KEY_MENU);
	trace_reset();
	key(KEY_MENU);
	check_has("reopened: large at the top", mock_trace(), "20 5c 03 10 02 40 14 /", 1);
	key(KEY_MENU);
	/* a toast with the menu closed: at the menu's scale */
	config.autofire |= CONFIG_OSD_SMALL;
	trace_reset();
	key(KEY_CTRL);
	key(KEY_LALT);
	key(KEY_KP0);
	check("Ctrl-Alt-keypad 0: the OSD bits kept", config.autofire & ~0x03, 0x04 | CONFIG_OSD_SMALL | (CONFIG_OSD_TOP << CONFIG_OSD_POS_SHIFT));
	check_has("small: the toast's window at scale 1, (60, 77)", mock_trace(), "20 5c 01 3c 4d 28 01 /", 1);
	key(KEY_CTRL | KEY_UPSTROKE);
	key(KEY_LALT | KEY_UPSTROKE);
	wait_counts(UI_T(1000) + 1);
	/* position 3 (never written) is Centre */
	config.autofire = (unsigned char)(3 << CONFIG_OSD_POS_SHIFT);
	trace_reset();
	key(KEY_MENU);
	check_has("position bits 3: large, centred", mock_trace(), WIN_MENU_ON, 1);
	key(KEY_F4);
	check("position bits 3", go("OSD position"), 13);
	check_str("position bits 3: shown as centre", cells(13, 55, 6), "centre");
	config.autofire = 0;            /* the same window: large, centred */

	/* ---- Acceleration ---- */
	key(KEY_F5);
	calls_clear();
	check("CPU", go("CPU"), 2);
	key(KEY_RIGHT);
	key(KEY_RIGHT);
	check("CPU Right: 68020 -> 68000", config.cpu & 3, 0);
	check_has("CPU: ConfigCPU(00)", calls, "ConfigCPU(00);", 1);
	key(KEY_RIGHT);
	check("CPU Right: 68010", config.cpu & 3, 1);
	key(KEY_RIGHT);
	check("CPU Right: 68020 (config 3)", config.cpu & 3, 3);
	key(KEY_DOWN);
	key(KEY_RIGHT);
	key(KEY_RIGHT);
	check("Turbo Right: CHIPRAM", (config.cpu >> 2) & 3, 1);
	check("Turbo: the CPU kept", config.cpu & 3, 3);
	key(KEY_LEFT);
	key(KEY_DOWN);
	key(KEY_RIGHT);
	key(KEY_RIGHT);
	check("Chip slots Right: Fast", config.cpu & CONFIG_CPU_FASTCHIP, CONFIG_CPU_FASTCHIP);
	key(KEY_LEFT);
	key(KEY_ENTER);
	core_caps |= CORE_CAPS_AP040 | CORE_CAPS_FPU | CORE_CAPS_MMU;
	key(KEY_UP);
	key(KEY_UP);
	check("fixed 68040: the CPU line not selectable", sel_row(), 3);
	check_str("fixed 68040: what it is", cells(2, 48, 13), "68040/FPU/MMU");
	check("fixed 68040: greyed", osd2_atr[2][20], A_GREY);
	screen("accel_040");
	core_caps = CORE_CAPS_IDE2;
	key(KEY_MENU);

	/* ---- every help text fits the help field ---- */
	{
		int before = fails;
		char what[64];
		for (t = 0; t < UI_TABS; t++) {
			help_fits(ui_tabs[t].name, ui_tabs[t].help);
			for (i = 0; i < ui_tabs[t].n; i++) {
				snprintf(what, sizeof what, "%s: %s", ui_tabs[t].name, ui_tabs[t].items[i].label ? ui_tabs[t].items[i].label : "-");
				help_fits(what, ui_tabs[t].items[i].helpf ? ui_tabs[t].items[i].helpf(ui_tabs[t].items[i].arg)
				                                          : ui_tabs[t].items[i].help);
			}
		}
		check("every help text fits two lines of 62", fails - before, 0);
	}

	(void)keys;
	(void)ver_reads;
	printf("%s: %d cases, %d failed\n", fails ? "FAIL ui_test" : "ui_test passed", cases, fails);
	return fails ? 1 : 0;
}

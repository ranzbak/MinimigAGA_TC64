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
 * 128 ms, end 1 s, restart; reset by a cursor move).
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
int drivesounds_loaded(void) { return 0; }
void i2c_bus_recover(void) { logc("i2c_bus_recover"); }
void adv7511_init(void) { logc("adv7511_init"); }
int ColdBoot(void) { logc("ColdBoot"); return 1; }
void SanityCheck(void) { logc("SanityCheck"); }
static int debug_draws;
void _showdebugmessages(void) { debug_draws++; }
void debug2_show(int on) { logc("debug2_show(%d)", on); }
void menu_classic_open(unsigned char page, unsigned char sub) { logc("classic(%d,%d)", page, sub); }

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
	calls_clear();
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

int main(int argc, char **argv)
{
	int i;
	unsigned t;
	golddir = argc > 1 ? argv[1] : "gold/ui";
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
	check_str("open: the key hints in the help field", cells(18, 1, 14), "Up/Down select");
	check_str("open: the second hint line", cells(19, 1, 15), "F1-F5 category ");
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
	check_str("Right: the help field shows DF0's help", cells(18, 1, 15), "Floppy drive 0.");
	check("Right: Main's bar dark blue (the focus in its list)", osd2_atr[3][5], OSD2_ATTR(OSD2_C_WHITE, OSD2_C_DKBLUE));
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

	/* ---- Storage: read-only values, the toast in the help field ---- */
	key(KEY_DOWN);
	key(KEY_RIGHT);
	check("Storage list", ui_tab == UI_TAB_STORAGE && ui_focus == UI_F_LIST, 1);
	screen("storage");
	key(KEY_LEFT);
	check_str("Storage Left: read-only toast", cells(18, 1, 37), "Read-only here: see Open classic menu");
	check("Storage Left: the toast yellow", osd2_atr[18][1], OSD2_ATTR(OSD2_C_YELLOW, OSD2_C_DKBLUE));
	check("Storage Left: config unchanged", config.floppy.drives, 1);
	check("Storage Left (a value): still in the list", ui_focus, UI_F_LIST);
	wait_counts(UI_T(1000) + 1);
	check_str("the toast gone: the item's help again", cells(18, 1, 15), "How many floppy");
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
	check("System: the change arrows", osd2_chr[5][53] == OSD_G_LEFT && osd2_chr[5][62] == OSD_G_RIGHT, 1);
	key(KEY_LEFT);
	check("Chip RAM Left: 1.5 MB", config.memory & 3, 2);
	check_has("Chip RAM Left: ConfigMemory(22)", calls, "ConfigMemory(22);", 1);
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
	key(KEY_RIGHT);                 /* Chip RAM back to 2.0 MB: changed against 1.5 */
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
	check("Load: the left change arrow", osd2_chr[8][52], OSD_G_LEFT);
	key(KEY_RIGHT);
	check_str("Load Right: slot 2 (1 has no file)", cells(8, 60, 1), "2");
	key(KEY_LEFT);
	key(KEY_LEFT);
	check_str("Load Left twice: back over Default to 2", cells(8, 60, 1), "2");
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
	key(KEY_RIGHT);
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

	/* ---- Storage: hand over to the classic menu ---- */
	key(KEY_MENU);
	key(KEY_F2);
	check("Open classic menu selected", go("Open classic menu"), 17);
	calls_clear();
	mock_reset();
	mock_timer_step(0);
	key(KEY_ENTER);
	check_has("classic: the Main page, Hard disk settings", calls, "classic(2,5);", 1);
	check("classic: ui_legacy_active", ui_legacy_active, 1);
	check("classic: the new menu closed", ui_open_now, 0);
	check_has("classic: the layer off", mock_trace(), WIN_MENU_OFF, 1);
	ui_legacy_active = 0;           /* menu.c's HandleUI does this when the classic menu closes */

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

	/* ---- the error page takes over ---- */
	key(KEY_MENU);
	mock_reset();
	mock_timer_step(0);
	ui_legacy_takeover();
	check("takeover: ui_legacy_active", ui_legacy_active, 1);
	check("takeover: closed", ui_open_now, 0);
	check_has("takeover: the layer off", mock_trace(), WIN_MENU_OFF, 1);
	ui_legacy_active = 0;

	/* ---- every help text fits the help field ---- */
	{
		int before = fails;
		char what[64];
		for (t = 0; t < UI_TABS; t++) {
			help_fits(ui_tabs[t].name, ui_tabs[t].help);
			for (i = 0; i < ui_tabs[t].n; i++) {
				snprintf(what, sizeof what, "%s: %s", ui_tabs[t].name, ui_tabs[t].items[i].label ? ui_tabs[t].items[i].label : "-");
				help_fits(what, ui_tabs[t].items[i].help);
			}
		}
		check("every help text fits two lines of 62", fails - before, 0);
	}

	(void)keys;
	printf("%s: %d cases, %d failed\n", fails ? "FAIL ui_test" : "ui_test passed", cases, fails);
	return fails ? 1 : 0;
}

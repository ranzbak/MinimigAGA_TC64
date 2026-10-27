/* ui: the OSD menu on the 720p text layer (ui.h has the layout and the
 * keys).  Everything is drawn into osd2's shadow; osd2_flush() sends only
 * the cells that changed, so a redraw of the whole screen after a key costs
 * the SPI bytes of what it changed (a cursor move: two rows).  All state is
 * in bss (the stack has ~1.3 KB spare). */
#include <string.h>

#include "hardware.h"
#include "fat.h"
#include "fdd.h"
#include "osd.h"
#include "fpga.h"
#include "config.h"
#include "cdrom.h"
#include "adv7511.h"
#include "i2c.h"
#include "menu.h"
#include "menu_model.h"
#include "ui.h"

extern unsigned char drives;
extern adfTYPE df[4];
extern DIRENTRY DirEntry[MAXDIRENTRIES];
extern unsigned char sort_table[MAXDIRENTRIES];
extern unsigned char nDirEntries;
extern unsigned char iSelectedEntry;
extern char DirEntryLFN[MAXDIRENTRIES][261];
extern char *fs_pFileExt;           /* menu.c: what the directory table was scanned for */
extern int ui_cd_shown_track;       /* ui_tabs.c */
void SanityCheck(void);             /* menu.c */

/* attributes */
#define A(fg, bg) OSD2_ATTR(OSD2_C_##fg, OSD2_C_##bg)
#define A_PANEL    A(TEXT, PANEL)
#define A_VALUE    A(VALUE, PANEL)
#define A_GREY     A(GREY, PANEL)
#define A_HI       A(HITEXT, HILITE)
#define A_TABBAR   A(TEXT, TABBAR)
#define A_TAB      A(BLACK, TAB)
#define A_TABHINT  A(GREY, TABBAR)
#define A_BORDER   A(BORDER, PANEL)
#define A_HELP     A(TEXT, HELP)
#define A_HELPHEAD A(WHITE, HELP)
#define A_HELPNOTE A(VALUE, HELP)
#define A_STATUS   A(TEXT, STATUS)
#define A_HINT     A(GREY, STATUS)
#define A_TOAST    A(OK, STATUS)
#define A_DLG      A(TEXT, STATUS)
#define A_DLGBOX   A(WARN, STATUS)
#define A_DLGHEAD  A(WHITE, WARN)
#define A_BTN      A(TEXT, TABBAR)
#define A_POPUP    A(HITEXT, HILITE)

/* the file selector's name fields (cols 2..): files 36, directories 30 + "<DIR>" */
#define FS_FILE_W 36
#define FS_DIR_W  30
#define FS_OPTS   (SCAN_DIR | SCAN_LFN)

#define PENDING_CLOSE 0xff

unsigned char ui_legacy_active;
unsigned char ui_cfg_mask;
unsigned char ui_open_now, ui_tab, ui_focus;

static unsigned char cur[UI_TABS];          /* the cursor of each tab */
static unsigned char dirty, started, popup;
static unsigned char m_ctrl, m_lalt, m_lshift;
static unsigned char toast_on;
static char toast[UI_TOAST_COLS + 1];
static unsigned long toast_timer, status_timer;
static unsigned char sys_mem, sys_chip;     /* System as the tab was entered */
static unsigned char pending;               /* after the System prompt: a tab or PENDING_CLOSE */

static struct {
	const char *title, *l1, *l2;
	const char *const *btn;
	unsigned char n, sel, back;
	void (*done)(unsigned char b);
} dlg;

static char ext_adf[] = "ADF", ext_cd[] = "ISOCUE", ext_rom[] = "ROM";
static char *const fs_ext[] = { ext_adf, ext_cd, ext_rom };
static unsigned char fs_target, fs_arg, fs_window_ok;
static unsigned short sc_pos;               /* the selected long name's first cell */
static unsigned long sc_timer;
static char namebuf[13];

/* ------------------------------------------------------------------ */
/* items                                                              */
/* ------------------------------------------------------------------ */

static const struct ui_item *item(unsigned i)
{
	return i < ui_tabs[ui_tab].n ? &ui_tabs[ui_tab].items[i] : 0;
}

static unsigned char avail(const struct ui_item *it)
{
	return it->avail ? it->avail(it->arg) : 1;
}

static int selectable(unsigned i)
{
	const struct ui_item *it = item(i);
	return it && it->kind != UI_SEP && avail(it);
}

/* the next selectable item from `from` in direction dir, or -1 */
static int find_sel(int from, int dir)
{
	int i;
	for (i = from; i >= 0 && i < (int)ui_tabs[ui_tab].n; i += dir)
		if (selectable((unsigned)i))
			return i;
	return -1;
}

static const char *value_text(const struct ui_item *it)
{
	unsigned char v;
	if (it->text)
		return it->text(it->arg);
	if (!it->values)
		return "";
	v = it->get(it->arg);
	return v < it->nvalues ? it->values[v] : "?";
}

/* ------------------------------------------------------------------ */
/* drawing                                                            */
/* ------------------------------------------------------------------ */

void ui_draw_item(unsigned i)
{
	const struct ui_item *it = item(i);
	unsigned row = UI_LIST_ROW + i, vc, vw;
	unsigned char av, sel, a, wide;

	if (i >= UI_LIST_ROWS)
		return;
	if (!it || it->kind == UI_SEP || (!(av = avail(it)) && (it->flags & UI_HIDE))) {
		osd2_fill(row, 0, UI_LIST_W, ' ', A_PANEL);
		return;
	}
	sel = ui_focus != UI_F_TABBAR && cur[ui_tab] == i;
	wide = it->flags & UI_WIDE;
	a = sel ? A_HI : av ? A_PANEL : A_GREY;
	osd2_fill(row, 0, UI_LIST_W, ' ', a);
	osd2_putn(row, UI_LABEL_COL, wide ? UI_WIDE_COL - UI_LABEL_COL - 1 : UI_VALUE_COL - UI_LABEL_COL - 1,
	          it->label, a);
	if (!it->text && !it->values)
		return;
	vc = wide ? UI_WIDE_COL : UI_VALUE_COL;
	vw = wide ? UI_WIDE_W : UI_VALUE_W;
	osd2_putn(row, vc, vw, value_text(it), sel ? A_HI : av ? A_VALUE : A_GREY);
	if (sel && it->kind == UI_CYCLE) {
		osd2_fill(row, vc - 1, 1, '<', a);
		osd2_fill(row, vc + vw, 1, '>', a);
	}
}

static void draw_tabs(void)
{
	unsigned i, col = 1;
	osd2_fill(0, 0, UI_COLS, ' ', A_TABBAR);
	for (i = 0; i < UI_TABS; i++) {
		unsigned n = strlen(ui_tabs[i].name);
		unsigned char a = i != ui_tab ? A_TABBAR : ui_focus == UI_F_TABBAR ? A_HI : A_TAB;
		osd2_fill(0, col, n + 2, ' ', a);
		osd2_put(0, col + 1, ui_tabs[i].name, a);
		col += n + 3;
	}
	osd2_put(0, UI_COLS - 6, "F1-F5", A_TABHINT);
}

static void draw_sep(unsigned row)
{
	osd2_fill(row, 0, UI_COLS, '-', A_BORDER);
	osd2_fill(row, UI_LIST_W, 1, '+', A_BORDER);
}

static void draw_help(void)
{
	static const char *const fs_head[] = { "Floppy DF", "CD-ROM", "Kickstart ROM" };
	static const char *const fs_help[] = {
		"Choose a disk image (ADF).",
		"Choose a CD image (ISO, or CUE with its tracks).",
		"Choose a Kickstart ROM image. Loading it restarts the Amiga."
	};
	const struct ui_item *it = item(cur[ui_tab]);
	const char *head = "", *help = "", *note = 0;
	unsigned r;

	for (r = UI_LIST_ROW; r < UI_LIST_ROW + UI_LIST_ROWS; r++) {
		osd2_fill(r, UI_LIST_W, 1, '|', A_BORDER);
		osd2_fill(r, UI_LIST_W + 1, UI_COLS - UI_LIST_W - 1, ' ', A_HELP);
	}
	if (ui_focus == UI_F_FILESEL) {
		head = fs_head[fs_target];
		help = fs_help[fs_target];
		note = "Enter opens a folder, Backspace goes up, a letter jumps to the next name with it.";
	} else if (ui_focus == UI_F_TABBAR || !it) {
		head = ui_tabs[ui_tab].name;
		help = ui_tabs[ui_tab].help;
	} else {
		head = it->label;
		help = it->help;
		if (it->kind == UI_INFO)
			note = "Shown here; change it in the classic menu (the last item of this tab).";
	}
	while (*head == ' ')
		head++;
	osd2_put(UI_LIST_ROW, UI_HELP_COL, head, A_HELPHEAD);
	if (ui_focus == UI_F_FILESEL && fs_target == UI_FS_FLOPPY) {
		char d[2] = { (char)('0' + fs_arg), 0 };
		osd2_put(UI_LIST_ROW, UI_HELP_COL + strlen(head), d, A_HELPHEAD);
	}
	osd2_wrap(UI_LIST_ROW + 2, UI_HELP_COL, UI_HELP_W, note ? 9 : 14, help ? help : "", A_HELP);
	if (note)
		osd2_wrap(UI_LIST_ROW + 12, UI_HELP_COL, UI_HELP_W, 4, note, A_HELPNOTE);
}

void ui_draw_status(void)
{
	static const char *const hints[] = {
		"Enter select  Left/Right change  F1-F5 tabs  Esc close",
		"Left/Right tab  Down/Enter items  Esc close",
		"Left/Right choose  Enter confirm  Esc cancel",
		"Enter choose  Backspace up  PgUp/PgDn page  Esc back",
	};
	const char *h = hints[ui_focus & 3];
	osd2_fill(UI_STATUS_ROW, 0, UI_COLS, ' ', A_STATUS);
	if (toast_on) {
		osd2_put(UI_STATUS_ROW, 1, toast, A_TOAST);
		return;
	}
	if (core_caps & CORE_CAPS_TEMP) {
		/* the XADC: T = raw * 503.975 / 4096 - 273.15 (whole degrees) */
		unsigned short raw = FPGA_TEMP_RAW;
		int t = (int)((((unsigned long)(raw & 0x0fff)) * 504) >> 12) - 273;
		char b[8], *p = b;
		if (t < 0) {
			*p++ = '-';
			t = -t;
		}
		p = mm_utoa(p, (unsigned)t);
		*p++ = 'C';
		*p = 0;
		osd2_put(UI_STATUS_ROW, 1, b, A_STATUS);
	}
	osd2_put(UI_STATUS_ROW, UI_COLS - 1 - strlen(h), h, A_HINT);
}

/* the file selector: a directory entry's name and its shown length (a
   file's long name without its extension; an 8.3 name without padding) */
static const char *entry_name(unsigned char k, unsigned *len, unsigned char *dir)
{
	const DIRENTRY *e = &DirEntry[k];
	const char *lfn = DirEntryLFN[k];
	unsigned n;
	*dir = (e->Attributes & ATTR_DIRECTORY) ? 1 : 0;
	if (lfn[0]) {
		n = strlen(lfn);
		if (!*dir && n > 4 && lfn[n - 4] == '.')
			n -= 4;
		*len = n;
		return lfn;
	}
	memcpy(namebuf, e->Name, 8);
	n = 8;
	while (n && namebuf[n - 1] == ' ')
		n--;
	if (*dir && e->Extension[0] != ' ') {
		namebuf[n++] = '.';
		memcpy(namebuf + n, e->Extension, 3);
		n += 3;
		while (namebuf[n - 1] == ' ')
			n--;
	}
	namebuf[n] = 0;
	*len = n;
	return namebuf;
}

static void draw_file_row(unsigned i)
{
	unsigned row = UI_LIST_ROW + i, len, w;
	unsigned char dir, sel, a;
	const char *name;

	if (i >= nDirEntries) {
		osd2_fill(row, 0, UI_LIST_W, ' ', A_PANEL);
		if (i == 0)
			osd2_put(row, UI_LABEL_COL, "No files!", A_GREY);
		return;
	}
	name = entry_name(sort_table[i], &len, &dir);
	sel = i == iSelectedEntry;
	a = sel ? A_HI : dir ? A_VALUE : A_PANEL;
	w = dir ? FS_DIR_W : FS_FILE_W;
	osd2_fill(row, 0, UI_LIST_W, ' ', a);
	if (sel && len > w) {
		unsigned p = sc_pos > len - w ? len - w : sc_pos;
		osd2_putn(row, UI_LABEL_COL, w, name + p, a);
	} else if (len > w) {                   /* not selected: cut, "~" */
		osd2_putn(row, UI_LABEL_COL, w - 1, name, a);
		osd2_fill(row, UI_LABEL_COL + w - 1, 1, '~', a);
	} else
		osd2_putn(row, UI_LABEL_COL, len, name, a);
	if (dir)
		osd2_put(row, UI_LABEL_COL + w + 1, "<DIR>", a);
}

static void draw_dialog(void)
{
	unsigned r, i, w, col;
	for (r = 7; r <= 12; r++)
		osd2_fill(r, 13, 38, ' ', A_DLG);
	osd2_box(6, 12, 13, 51, A_DLGBOX);
	w = strlen(dlg.title) + 2;
	osd2_fill(6, 32 - w / 2, w, ' ', A_DLGHEAD);
	osd2_put(6, 32 - w / 2 + 1, dlg.title, A_DLGHEAD);
	osd2_put(8, 32 - strlen(dlg.l1) / 2, dlg.l1, A_DLG);
	osd2_put(9, 32 - strlen(dlg.l2) / 2, dlg.l2, A_DLG);
	for (w = 0, i = 0; i < dlg.n; i++)
		w += strlen(dlg.btn[i]) + 2 + (i ? 2 : 0);
	col = 32 - w / 2;
	for (i = 0; i < dlg.n; i++) {
		unsigned n = strlen(dlg.btn[i]);
		unsigned char a = i == dlg.sel ? A_HI : A_BTN;
		osd2_fill(11, col, n + 2, ' ', a);
		osd2_put(11, col + 1, dlg.btn[i], a);
		col += n + 4;
	}
}

void ui_draw_all(void)
{
	unsigned i;
	draw_tabs();
	draw_sep(1);
	for (i = 0; i < UI_LIST_ROWS; i++) {
		if (ui_focus == UI_F_FILESEL)
			draw_file_row(i);
		else
			ui_draw_item(i);
	}
	draw_help();
	draw_sep(UI_STATUS_ROW - 1);
	ui_draw_status();
	if (ui_focus == UI_F_DIALOG)
		draw_dialog();
}

/* ------------------------------------------------------------------ */
/* open, close, toasts, the classic menu                              */
/* ------------------------------------------------------------------ */

/* the keyboard (and joystick 2) to the OSD or back to the Amiga; the
   classic bitmap OSD stays off (its enable bit, OSD_CMD_OSD bit 0) */
static void osd_keys(unsigned char to_osd)
{
	EnableOsd();
	SPI(OSD_CMD_OSD);
	SPI(to_osd ? DISABLE_KEYBOARD : 0);
	DisableOsd();
}

static void sys_snapshot(void)
{
	sys_mem = config.memory;
	sys_chip = config.chipset & 0x1c;
}

/* the cursor on a selectable item, else the tab bar */
static void fix_cursor(void)
{
	int i;
	if (ui_focus != UI_F_LIST)
		return;
	if (selectable(cur[ui_tab]))
		return;
	i = find_sel(0, 1);
	if (i < 0)
		ui_focus = UI_F_TABBAR;
	else
		cur[ui_tab] = (unsigned char)i;
}

static void ui_open(void)
{
	ui_open_now = 1;
	popup = 0;
	toast_on = 0;
	if (ui_focus != UI_F_TABBAR)
		ui_focus = UI_F_LIST;
	ui_cfg_mask = mm_config_scan();
	if (ui_tab == UI_TAB_SYSTEM)
		sys_snapshot();
	fix_cursor();
	osd_keys(1);
	status_timer = GetTimer(UI_T_STATUS);
	ui_draw_all();
	dirty = 0;
	osd2_flush();
	osd2_commit(1, UI_SCALE, UI_X0, UI_Y0, UI_COLS, UI_ROWS);
}

void ui_close(void)
{
	ui_open_now = 0;
	popup = 0;
	toast_on = 0;
	if (ui_focus != UI_F_TABBAR)
		ui_focus = UI_F_LIST;
	osd2_disable();
	if (DebugMode)
		OsdShow(0);                 /* the debug lines on the classic OSD, as the classic menu */
	else
		OsdHide();                  /* the keyboard back to the Amiga */
}

void ui_toast(const char *text)
{
	unsigned n;
	strncpy(toast, text, UI_TOAST_COLS);
	toast[UI_TOAST_COLS] = 0;
	toast_on = 1;
	toast_timer = GetTimer(UI_T_TOAST);
	if (ui_open_now) {
		ui_draw_status();
		return;
	}
	/* the menu is closed: a one-row window of its own on row 0 (the tab
	   bar's row, drawn again when the menu opens) */
	n = strlen(toast);
	osd2_fill(0, 0, UI_TOAST_COLS, ' ', A_POPUP);
	osd2_put(0, (UI_TOAST_COLS - n) / 2, toast, A_POPUP);
	osd2_flush();
	if (!popup)
		osd2_commit(1, UI_SCALE, UI_TOAST_X0, UI_TOAST_Y0, UI_TOAST_COLS, 1);
	popup = 1;
}

static void quiet_close(void)
{
	if (ui_open_now || popup)
		osd2_disable();
	ui_open_now = 0;
	popup = 0;
	toast_on = 0;
	if (ui_focus != UI_F_TABBAR)
		ui_focus = UI_F_LIST;
	fs_window_ok = 0;               /* the classic menu scans 8 entries */
	ui_legacy_active = 1;
}

void ui_classic(unsigned char page, unsigned char sub)
{
	quiet_close();
	menu_classic_open(page, sub);
}

void ui_legacy_takeover(void)
{
	if (osd2_caps)
		quiet_close();
}

/* ------------------------------------------------------------------ */
/* dialogs, tabs                                                      */
/* ------------------------------------------------------------------ */

void ui_dialog(const char *title, const char *l1, const char *l2,
               const char *const *buttons, unsigned char n, unsigned char sel,
               void (*done)(unsigned char button))
{
	dlg.title = title;
	dlg.l1 = l1;
	dlg.l2 = l2;
	dlg.btn = buttons;
	dlg.n = n;
	dlg.sel = sel;
	dlg.done = done;
	dlg.back = (ui_focus == UI_F_TABBAR) ? UI_F_TABBAR : UI_F_LIST;
	ui_focus = UI_F_DIALOG;
	dirty = 1;
}

static void dialog_end(unsigned char b)
{
	ui_focus = dlg.back;
	dirty = 1;
	dlg.done(b);
}

static void switch_tab(unsigned char t)
{
	ui_tab = t;
	if (t == UI_TAB_SYSTEM)
		sys_snapshot();
	fix_cursor();
	dirty = 1;
}

/* leaving System (another tab, or closing) after a change of memory or
   chipset: offer the reset it needs (the classic MENU_MEMORY_CHANGED) */
static void leave_done(unsigned char b)
{
	if (b == 0) {
		ui_close();
		OsdReset();
	} else if (pending == PENDING_CLOSE)
		ui_close();
	else
		switch_tab(pending);
}

static int leave_system(unsigned char to)
{
	static const char *const b[] = { "Yes", "No" };
	if (ui_tab != UI_TAB_SYSTEM || (config.memory == sys_mem && (config.chipset & 0x1c) == sys_chip))
		return 0;
	pending = to;
	ui_dialog("Reset", "Memory or chipset changed: this", "needs a reset. Reset the Amiga?", b, 2, 0, leave_done);
	return 1;
}

static void goto_tab(unsigned char t)
{
	if (t == ui_tab || leave_system(t))
		return;
	switch_tab(t);
}

static void request_close(void)
{
	if (!leave_system(PENDING_CLOSE))
		ui_close();
}

/* ------------------------------------------------------------------ */
/* the file selector                                                  */
/* ------------------------------------------------------------------ */

static void scroll_reset(void)
{
	sc_pos = 0;
	sc_timer = GetTimer(UI_T_SCROLL_HOLD);
}

void ui_fs_open(unsigned char target, unsigned char arg)
{
	char *ext = fs_ext[target];
	fat_dir_window = MAXDIRENTRIES;
	if (!fs_pFileExt || strcmp(ext, fs_pFileExt) != 0) {
		/* another kind of file: from the root (as the classic menu) */
		ChangeDirectory(DIRECTORY_ROOT);
		ScanDirectory(SCAN_INIT, ext, FS_OPTS);
	} else if (!fs_window_ok)
		ScanDirectory(SCAN_INIT, ext, FS_OPTS);   /* scanned by the classic menu: 8 entries */
	fs_pFileExt = ext;
	fs_window_ok = 1;
	fs_target = target;
	fs_arg = arg;
	ui_focus = UI_F_FILESEL;
	scroll_reset();
	dirty = 1;
}

/* the selected long name: start held, one cell per step to its end, end
   held, back to the start (plan 3.7) */
static void scroll_tick(void)
{
	unsigned len, w;
	unsigned char dir;
	if (!nDirEntries || !CheckTimer(sc_timer))
		return;
	entry_name(sort_table[iSelectedEntry], &len, &dir);
	w = dir ? FS_DIR_W : FS_FILE_W;
	if (len <= w) {
		sc_timer = GetTimer(UI_T_SCROLL_HOLD);
		return;
	}
	if (sc_pos >= len - w) {
		sc_pos = 0;
		sc_timer = GetTimer(UI_T_SCROLL_HOLD);
	} else {
		sc_pos++;
		sc_timer = GetTimer(sc_pos >= len - w ? UI_T_SCROLL_END : UI_T_SCROLL_STEP);
	}
	draw_file_row(iSelectedEntry);
}

static const char *const yes_no[] = { "Yes", "No" };

static void kick_done(unsigned char b)
{
	if (b)
		return;
	ui_toast("Loading Kickstart...");
	osd2_flush();
	mm_reload_kickstart();
	ui_close();
}

static void fs_chosen(void)
{
	static char name[37];
	ui_focus = UI_F_LIST;
	dirty = 1;
	switch (fs_target) {
	case UI_FS_FLOPPY:
		InsertFloppy(&df[fs_arg]);
		/* the next drive (Main's items 0..3 are DF0..DF3), as the classic menu */
		if (fs_arg + 1 <= drives)
			cur[UI_TAB_MAIN] = fs_arg + 1;
		break;
	case UI_FS_CD:
		cd_insert_msg(CD_Insert(file.name, file.long_name[0] ? file.long_name : 0, CurrentDirectory()));
		break;
	case UI_FS_KICK:
		if (file.long_name[0]) {
			strncpy(name, file.long_name, 36);
			name[36] = 0;
		} else {
			memcpy(name, file.name, 8);
			name[8] = 0;
		}
		ui_dialog("Kickstart", "Load this Kickstart and restart?", name, yes_no, 2, 1, kick_done);
		break;
	}
}

static void key_files(unsigned char c)
{
	char *ext = fs_ext[fs_target];
	unsigned char ch;
	switch (c) {
	case KEY_MENU:
	case KEY_ESC:
		ui_focus = UI_F_LIST;
		dirty = 1;
		return;
	case KEY_UP:
		ScanDirectory(SCAN_PREV, ext, FS_OPTS);
		break;
	case KEY_DOWN:
		ScanDirectory(SCAN_NEXT, ext, FS_OPTS);
		break;
	case KEY_PGUP:
	case KEY_LEFT:
		ScanDirectory(SCAN_PREV_PAGE, ext, FS_OPTS);
		break;
	case KEY_PGDN:
	case KEY_RIGHT:
		ScanDirectory(SCAN_NEXT_PAGE, ext, FS_OPTS);
		break;
	case KEY_HOME:
		ScanDirectory(SCAN_INIT, ext, FS_OPTS);
		break;
	case KEY_BACK:
		mm_fs_parent(ext, FS_OPTS);
		break;
	case KEY_ENTER:
	case KEY_SPACE:
		switch (mm_fs_enter(ext, FS_OPTS)) {
		case MM_FS_FILE:
			fs_chosen();
			return;
		case MM_FS_EMPTY:
			ui_focus = UI_F_LIST;
			dirty = 1;
			return;
		}
		break;
	default:
		ch = GetASCIIKey(c);
		if (!((ch >= '0' && ch <= '9') || (ch >= 'A' && ch <= 'Z')))
			return;
		mm_fs_find(ch, ext, FS_OPTS);
		break;
	}
	scroll_reset();
	dirty = 1;
}

/* ------------------------------------------------------------------ */
/* keys                                                               */
/* ------------------------------------------------------------------ */

static void change(const struct ui_item *it, int dir)
{
	unsigned char v, n = it->nvalues;
	if (it->kind == UI_INFO) {
		ui_toast("Read-only here: see Open classic menu");
		return;
	}
	if (it->kind != UI_CYCLE || !n)
		return;
	v = it->get(it->arg);
	if (dir > 0) {
		if (v + 1 < n)
			v++;
		else if (it->flags & UI_CLAMP)
			return;
		else
			v = 0;
	} else {
		if (v > 0)
			v--;
		else if (it->flags & UI_CLAMP)
			return;
		else
			v = n - 1;
	}
	it->set(it->arg, v);
	dirty = 1;
}

static void activate(const struct ui_item *it)
{
	if (it->kind == UI_CYCLE && !(it->flags & UI_ENTERACT))
		change(it, 1);
	else if (it->kind == UI_INFO)
		change(it, 1);
	else if (it->act)
		it->act(it->arg);
	dirty = 1;
}

static void key_dialog(unsigned char c)
{
	switch (c) {
	case KEY_LEFT:
	case KEY_UP:
		dlg.sel = dlg.sel ? dlg.sel - 1 : dlg.n - 1;
		break;
	case KEY_RIGHT:
	case KEY_DOWN:
		dlg.sel = dlg.sel + 1 < dlg.n ? dlg.sel + 1 : 0;
		break;
	case KEY_ENTER:
	case KEY_SPACE:
		dialog_end(dlg.sel);
		return;
	case KEY_MENU:
	case KEY_ESC:
		dialog_end(dlg.n - 1);
		return;
	default:
		return;
	}
	dirty = 1;
}

static void key_open(unsigned char c)
{
	const struct ui_item *it;
	int i;
	unsigned char t = ui_tab;

	if (ui_focus == UI_F_DIALOG) {
		key_dialog(c);
		return;
	}
	if (ui_focus == UI_F_FILESEL) {
		key_files(c);
		return;
	}
	if (c >= KEY_F1 && c <= KEY_F5) {
		goto_tab(c - KEY_F1);
		return;
	}
	switch (c) {
	case KEY_MENU:
	case KEY_ESC:
		request_close();
		return;
	case KEY_PGUP:
		goto_tab((t + UI_TABS - 1) % UI_TABS);
		return;
	case KEY_PGDN:
		goto_tab((t + 1) % UI_TABS);
		return;
	}
	if (t == UI_TAB_MAIN) {
		/* keypad +/- add or remove a floppy drive, Backspace ejects all */
		if ((c == KEY_KPPLUS && config.floppy.drives < 3) || (c == KEY_KPMINUS && config.floppy.drives > 0)) {
			config.floppy.drives += c == KEY_KPPLUS ? 1 : -1;
			ConfigFloppy(config.floppy.drives, config.floppy.speed);
			dirty = 1;
			return;
		}
		if (c == KEY_BACK) {
			for (i = 0; i <= drives && i < 4; i++)
				df[i].status = 0;
			dirty = 1;
			return;
		}
	}
	if (ui_focus == UI_F_TABBAR) {
		switch (c) {
		case KEY_LEFT:
			goto_tab((t + UI_TABS - 1) % UI_TABS);
			break;
		case KEY_RIGHT:
			goto_tab((t + 1) % UI_TABS);
			break;
		case KEY_DOWN:
		case KEY_ENTER:
		case KEY_SPACE:
			ui_focus = UI_F_LIST;
			fix_cursor();
			dirty = 1;
			break;
		}
		return;
	}
	it = item(cur[t]);
	switch (c) {
	case KEY_UP:
		i = find_sel(cur[t] - 1, -1);
		if (i < 0)
			ui_focus = UI_F_TABBAR;     /* past the first item: the tab bar */
		else
			cur[t] = (unsigned char)i;
		dirty = 1;
		break;
	case KEY_DOWN:
		i = find_sel(cur[t] + 1, 1);
		if (i >= 0)
			cur[t] = (unsigned char)i;
		dirty = 1;
		break;
	case KEY_LEFT:
	case KEY_RIGHT:
		if (it)
			change(it, c == KEY_RIGHT ? 1 : -1);
		break;
	case KEY_ENTER:
	case KEY_SPACE:
		if (it)
			activate(it);
		break;
	}
}

void ui_key(unsigned char c)
{
	static const char *const autofire_msg[] = { "AUTOFIRE OFF", "AUTOFIRE FAST", "AUTOFIRE MEDIUM", "AUTOFIRE SLOW" };
	unsigned char v;

	/* the modifiers and the classic shortcuts (menu.c's key decode) */
	switch (c) {
	case KEY_CTRL:                  m_ctrl = 1; return;
	case KEY_CTRL | KEY_UPSTROKE:   m_ctrl = 0; return;
	case KEY_LALT:                  m_lalt = 1; return;
	case KEY_LALT | KEY_UPSTROKE:   m_lalt = 0; return;
	case KEY_LSHIFT:                m_lshift = 1; return;
	case KEY_LSHIFT | KEY_UPSTROKE: m_lshift = 0; return;
	case KEY_KPPLUS:
	case KEY_KPMINUS:
		if (m_ctrl && m_lalt) {
			if (c == KEY_KPPLUS)
				config.chipset |= CONFIG_TURBO;
			else
				config.chipset &= ~CONFIG_TURBO;
			ConfigChipset(config.chipset);
			ui_toast(c == KEY_KPPLUS ? "TURBO" : "NORMAL");
			dirty = 1;
			return;
		}
		if (m_lshift) {
			v = mm_get_volume(0);
			if (c == KEY_KPPLUS && v < 31)
				v++;
			else if (c == KEY_KPMINUS && v > 0)
				v--;
			mm_set_volume(0, v);
			ui_toast(mm_text_volume_msg());
			dirty = 1;
			return;
		}
		break;
	case KEY_KPDOT:
		if (m_lshift) {
			ui_toast("Refreshing ADV7511 config");
			/* free the bus first: a slave stuck mid-byte would swallow the init */
			i2c_bus_recover();
			adv7511_init();
		}
		return;
	case KEY_KP0:
		if (m_ctrl && m_lalt && !ui_open_now) {
			/* bits 1:0 the rate; bit 2 the CD32 pad, kept */
			config.autofire = (config.autofire & 0x04) | ((config.autofire + 1) & 0x03);
			ConfigAutofire(config.autofire);
			ui_toast(autofire_msg[config.autofire & 0x03]);
		}
		return;
	case KEY_MENU:
		if (m_ctrl && m_lalt) {
			DebugMode = DebugMode ^ 1;
			if (DebugMode)
				SanityCheck();
			ui_close();
			return;
		}
		break;
	}
	if (c & KEY_UPSTROKE)
		return;
	if (!ui_open_now) {
		if (c == KEY_MENU)
			ui_open();
		return;
	}
	key_open(c);
}

/* ------------------------------------------------------------------ */
/* timers, the main-loop pass                                         */
/* ------------------------------------------------------------------ */

void ui_tick(void)
{
	if (toast_on && CheckTimer(toast_timer)) {
		toast_on = 0;
		if (popup) {
			popup = 0;
			osd2_disable();
		}
		if (ui_open_now)
			ui_draw_status();
	}
	if (!ui_open_now)
		return;
	if (ui_focus == UI_F_FILESEL)
		scroll_tick();
	else if (ui_tab == UI_TAB_MAIN &&
	         (cd_msg_expired() || (CD_SLOT() >= 0 && CD_PlayingTrack() != ui_cd_shown_track)))
		dirty = 1;      /* a CD message ended, or the play mark changed */
	if (CheckTimer(status_timer)) {
		status_timer = GetTimer(UI_T_STATUS);
		if ((core_caps & CORE_CAPS_TEMP) && !toast_on)
			ui_draw_status();
	}
}

void ui_handle(void)
{
	unsigned char c;
	if (!started) {
		started = 1;
		ui_close();
	}
	c = OsdGetCtrl();
	/* the core's key queue overflowed: an event was dropped; the flag is
	   only cleared (menu.c says why the modifiers are kept) */
	if (osd_keyq_lost)
		osd_keyq_lost = 0;
	if (c)
		ui_key(c);
	ui_tick();
	if (ui_open_now && dirty)
		ui_draw_all();
	dirty = 0;
	if (ui_open_now || popup)
		osd2_flush();
	if (!ui_open_now && DebugMode)
		_showdebugmessages();
}

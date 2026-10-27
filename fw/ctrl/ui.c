/* ui: the OSD menu on the 720p text layer (ui.h has the layout and the
 * keys).  Everything is drawn into osd2's shadow; osd2_flush() sends only
 * the cells that changed.  A row is composed in a buffer first (rc/ra) and
 * written once, so redrawing what is already there marks nothing and a
 * cursor move costs the SPI bytes of the cells it changed.  All state is in
 * bss (the stack has ~1.3 KB spare). */
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
#include "osd_icons.h"
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

/* attributes: black, white and blue carry it; dark blue for the help
   field, the bar track and what is not available; yellow / red accents */
#define A(fg, bg) OSD2_ATTR(OSD2_C_##fg, OSD2_C_##bg)
#define A_BASE    A(WHITE, BLACK)
#define A_SEL     A(WHITE, BLUE)      /* the selection bar */
#define A_SELDIM  A(WHITE, DKBLUE)    /* the category while the focus is in its list */
#define A_GREY    A(DKBLUE, BLACK)    /* not available */
#define A_DIM     A(DKBLUE, BLACK)    /* the temperature, the F key */
#define A_HEAD    A(BLUE, BLACK)      /* the panel's header */
#define A_LINE    A(DKBLUE, BLACK)
#define A_HELP    A(WHITE, DKBLUE)
#define A_TOAST   A(YELLOW, DKBLUE)
#define A_BARC    A(WHITE, DKBLUE)    /* a bar cell: filled white, the track dark blue */
#define A_DLGBOX  A(RED, BLACK)
#define A_DLGHEAD A(WHITE, RED)
#define A_BTN     A(WHITE, DKBLUE)
#define A_DIRTAG  A(BLUE, BLACK)
#define A_ERR     A(RED, BLACK)
#define A_POPUP   A(WHITE, BLUE)
#define A_EDIT    A(BLACK, YELLOW)    /* the value in EDIT */
#define A_EDARR   A(YELLOW, BLUE)     /* EDIT's change arrows */

/* the file selector's name fields (from UI_LABEL_COL): files to the
   marker column, directories 6 less ("<DIR>" right-aligned) */
#define FS_FILE_W (UI_MARK_COL - UI_LABEL_COL)
#define FS_DIR_W  (FS_FILE_W - 6)
#define FS_OPTS   (SCAN_DIR | SCAN_LFN)

#define PENDING_CLOSE 0xff

unsigned char ui_legacy_active;
unsigned char ui_cfg_mask;
unsigned char ui_open_now, ui_tab, ui_focus, ui_hints_on, ui_edit;

static unsigned char cur[UI_TABS];          /* the cursor of each category */
static unsigned char dirty, started, popup;
static unsigned char m_ctrl, m_lalt, m_lshift;
static unsigned char toast_on;
static char toast[UI_TOAST_COLS + 1];
static unsigned long toast_timer, status_timer;
static unsigned char sys_mem, sys_chip;     /* System as it was entered */
static unsigned char pending, pending_into; /* after the System prompt: a category (into its list) or PENDING_CLOSE */

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

/* the row being composed: chars (NUL after the last column) and attrs */
static char rc[UI_COLS + 1];
static unsigned char ra[UI_COLS];
/* glyph uploads: the bars, then the icons split into their two glyphs */
static unsigned char gbuf[10 * 16];

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

/* Left/Right change it (a read-only one: a toast) */
static int has_value(const struct ui_item *it)
{
	return it->kind == UI_CYCLE || it->kind == UI_INFO;
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

/* the item list has the focus (also under a dialog opened from it) */
static int list_focus(void)
{
	return ui_focus == UI_F_LIST || (ui_focus == UI_F_DIALOG && dlg.back == UI_F_LIST);
}

/* ------------------------------------------------------------------ */
/* the row buffer                                                     */
/* ------------------------------------------------------------------ */

static void rfill(unsigned c, unsigned n, unsigned char ch, unsigned char a)
{
	for (; n && c < UI_COLS; n--, c++) {
		rc[c] = (char)ch;
		ra[c] = a;
	}
}

/* at most n characters of s from col c; returns how many */
static unsigned rput(unsigned c, const char *s, unsigned n, unsigned char a)
{
	unsigned i;
	for (i = 0; i < n && s[i] && c + i < UI_COLS; i++) {
		rc[c + i] = s[i];
		ra[c + i] = a;
	}
	return i;
}

/* cols c0..c1-1 of the composed row into the shadow, one osd2_putn per run
   of one attribute (the chars are never 0: spaces, text, glyphs >= 0x04) */
static void rout(unsigned row, unsigned c0, unsigned c1)
{
	unsigned i = c0, j;
	char save;
	while (i < c1) {
		for (j = i + 1; j < c1 && ra[j] == ra[i]; j++)
			;
		save = rc[j];
		rc[j] = 0;
		osd2_putn(row, i, j - i, rc + i, ra[i]);
		rc[j] = save;
		i = j;
	}
}

/* ------------------------------------------------------------------ */
/* drawing                                                            */
/* ------------------------------------------------------------------ */

/* the menu's glyphs into the font RAM (osd_icons.h) */
static void ui_glyphs(void)
{
	unsigned i, r;
	for (i = 0; i < OSD_G_BARS; i++)
		for (r = 0; r < 16; r++)
			gbuf[i * 16 + r] = (r >= 3 && r <= 12) ? (unsigned char)(0xff00u >> i) : 0;
	osd2_font(OSD_G_BAR0, OSD_G_BARS, gbuf);
	for (i = 0; i < sizeof osd_glyphs / sizeof osd_glyphs[0]; i++)
		osd2_font(osd_glyphs[i].code, 1, osd_glyphs[i].rows);
	for (i = 0; i < UI_TABS; i++)
		for (r = 0; r < 16; r++) {
			gbuf[i * 32 + r] = (unsigned char)(osd_icons[i][r] >> 8);
			gbuf[i * 32 + 16 + r] = (unsigned char)osd_icons[i][r];
		}
	osd2_font(OSD_ICON_MAIN, 2 * UI_TABS, gbuf);
}

/* the dialog's part of row r, over the composed panel row */
static void dialog_row(unsigned r)
{
	unsigned i, w, c;
	if (ui_focus != UI_F_DIALOG || r < UI_DLG_R0 || r > UI_DLG_R1)
		return;
	rfill(UI_PANEL_COL, UI_PANEL_W, ' ', A_BASE);   /* only the box on these rows */
	if (r == UI_DLG_R0 || r == UI_DLG_R1) {
		rfill(UI_DLG_C0, 1, r == UI_DLG_R0 ? OSD_G_TL : OSD_G_BL, A_DLGBOX);
		rfill(UI_DLG_C0 + 1, UI_DLG_C1 - UI_DLG_C0 - 1, OSD_G_HLINE, A_DLGBOX);
		rfill(UI_DLG_C1, 1, r == UI_DLG_R0 ? OSD_G_TR : OSD_G_BR, A_DLGBOX);
		if (r == UI_DLG_R0) {
			w = strlen(dlg.title) + 2;
			rfill(UI_DLG_MID - w / 2, w, ' ', A_DLGHEAD);
			rput(UI_DLG_MID - w / 2 + 1, dlg.title, w - 2, A_DLGHEAD);
		}
		return;
	}
	rfill(UI_DLG_C0, 1, OSD_G_VLINE, A_DLGBOX);
	rfill(UI_DLG_C0 + 1, UI_DLG_C1 - UI_DLG_C0 - 1, ' ', A_BASE);
	rfill(UI_DLG_C1, 1, OSD_G_VLINE, A_DLGBOX);
	if (r == UI_DLG_R0 + 2)
		rput(UI_DLG_MID - strlen(dlg.l1) / 2, dlg.l1, UI_DLG_C1 - UI_DLG_C0 - 2, A_BASE);
	else if (r == UI_DLG_R0 + 3)
		rput(UI_DLG_MID - strlen(dlg.l2) / 2, dlg.l2, UI_DLG_C1 - UI_DLG_C0 - 2, A_BASE);
	else if (r == UI_DLG_R0 + 5) {
		for (w = 0, i = 0; i < dlg.n; i++)
			w += strlen(dlg.btn[i]) + 2 + (i ? 2 : 0);
		c = UI_DLG_MID - w / 2;
		for (i = 0; i < dlg.n; i++) {
			unsigned n = strlen(dlg.btn[i]);
			unsigned char a = i == dlg.sel ? A_SEL : A_BTN;
			rfill(c, n + 2, ' ', a);
			rput(c + 1, dlg.btn[i], n, a);
			c += n + 4;
		}
	}
}

void ui_draw_item(unsigned i)
{
	const struct ui_item *it = item(i);
	unsigned row = UI_LIST_ROW + i, lw, vs = UI_MARK_COL, n, k;
	unsigned char av = 0, sel, a, ed, va;

	if (i >= UI_LIST_ROWS)
		return;
	rfill(UI_PANEL_COL, UI_PANEL_W, ' ', A_BASE);
	if (it && it->kind != UI_SEP && ((av = avail(it)) || !(it->flags & UI_HIDE))) {
		sel = list_focus() && cur[ui_tab] == i;
		ed = sel && ui_edit;
		a = sel ? A_SEL : av ? A_BASE : A_GREY;
		va = ed ? A_EDIT : a;
		rfill(UI_PANEL_COL, UI_PANEL_W, ' ', a);
		lw = rput(UI_LABEL_COL, it->label, UI_VALUE_END - UI_LABEL_COL, a);
		if (it->flags & UI_BAR) {
			/* the bar in eighths of a cell, then the number */
			unsigned v = it->get(it->arg), mx = it->nvalues - 1;
			unsigned e = mx ? (v * 8 * UI_BAR_W + mx / 2) / mx : 0;
			char nb[4], *p = nb;
			for (k = 0; k < UI_BAR_W; k++) {
				unsigned f = e > 8 * k ? e - 8 * k : 0;
				rfill(UI_BAR_COL + k, 1, OSD_G_BAR0 + (f > 8 ? 8 : f), av ? A_BARC : A_GREY);
			}
			p = mm_utoa(p, v);
			*p = 0;
			rput(UI_VALUE_END + 1 - (unsigned)(p - nb), nb, 3, va);
			vs = UI_BAR_COL;
		} else if (it->text || it->values) {
			/* right-aligned, trailing spaces dropped, cut to leave two
			   cells after the label (the change arrow's place) */
			const char *t = value_text(it);
			unsigned max = UI_VALUE_END - UI_LABEL_COL - lw - 2;
			n = strlen(t);
			while (n && t[n - 1] == ' ')
				n--;
			if (n > max)
				n = max;
			vs = UI_VALUE_END + 1 - n;
			rput(vs, t, n, va);
		}
		if (it->flags & UI_SUB)
			rfill(UI_MARK_COL, 1, OSD_G_SUB, a);
		else if (ed) {
			rfill(vs - 2, 1, OSD_G_LEFT, A_EDARR);
			rfill(UI_MARK_COL, 1, OSD_G_RIGHT, A_EDARR);
		}
	}
	dialog_row(row);
	rout(row, UI_PANEL_COL, UI_COLS);
}

static void draw_temp(void)
{
	rfill(0, UI_SIDE_W, ' ', A_BASE);
	if (core_caps & CORE_CAPS_TEMP) {
		/* the XADC: T = raw * 503.975 / 4096 - 273.15 (whole degrees) */
		unsigned short raw = FPGA_TEMP_RAW;
		int t = (int)((((unsigned long)(raw & 0x0fff)) * 504) >> 12) - 273;
		char b[12], *p = b;
		memcpy(p, "FPGA ", 5);
		p += 5;
		if (t < 0) {
			*p++ = '-';
			t = -t;
		}
		p = mm_utoa(p, (unsigned)t);
		*p++ = 'C';
		*p = 0;
		rput(1, b, UI_SIDE_W - 1, A_DIM);
	}
	rout(UI_TEMP_ROW, 0, UI_SIDE_W);
}

/* the title, the five categories (3-row bars: icon and name in the middle
   row), the temperature */
static void draw_sidebar(void)
{
	unsigned r, t;
	for (r = 0; r < UI_TEMP_ROW; r++) {
		rfill(0, UI_SIDE_W, ' ', A_BASE);
		if (r == 0)
			rput(1, "Minimig AGA", UI_SIDE_W - 1, A_BASE);
		else if (r >= UI_CAT_ROW && r < UI_CAT_ROW + UI_TABS * UI_CAT_H) {
			unsigned char a, ia;
			t = (r - UI_CAT_ROW) / UI_CAT_H;
			a = t != ui_tab ? A_BASE : ui_focus == UI_F_SIDEBAR ? A_SEL : A_SELDIM;
			rfill(0, UI_SIDE_W, ' ', a);
			if ((r - UI_CAT_ROW) % UI_CAT_H == 1) {
				ia = (unsigned char)((a & 0xf0) | ui_tabs[t].icon_fg);
				rfill(UI_ICON_COL, 1, OSD_ICON_MAIN + 2 * t, ia);
				rfill(UI_ICON_COL + 1, 1, OSD_ICON_MAIN + 2 * t + 1, ia);
				rput(UI_CAT_COL, ui_tabs[t].name, UI_SIDE_W - UI_CAT_COL, a);
			}
		}
		rout(r, 0, UI_SIDE_W);
	}
	draw_temp();
}

/* the vertical line, the header's underline */
static void draw_lines(void)
{
	unsigned r;
	for (r = 0; r < UI_HELP_ROW; r++)
		osd2_fill(r, UI_LINE_COL, 1, r == UI_HEAD_ROW + 1 ? OSD_G_TEE_R : OSD_G_VLINE, A_LINE);
	osd2_fill(UI_HEAD_ROW + 1, UI_PANEL_COL, UI_PANEL_W, OSD_G_HLINE, A_LINE);
}

/* the category's name in blue (the F key at the right), or the file
   selector's target */
static void draw_header(void)
{
	static const char *const fs_head[] = { "Floppy DF", "CD-ROM image", "Kickstart ROM" };
	unsigned n;
	rfill(UI_PANEL_COL, UI_PANEL_W, ' ', A_BASE);
	if (ui_focus == UI_F_FILESEL) {
		n = rput(UI_LABEL_COL, fs_head[fs_target], UI_PANEL_W, A_HEAD);
		if (fs_target == UI_FS_FLOPPY)
			rfill(UI_LABEL_COL + n, 1, (unsigned char)('0' + fs_arg), A_HEAD);
	} else {
		rput(UI_LABEL_COL, ui_tabs[ui_tab].name, UI_PANEL_W, A_HEAD);
		rfill(UI_MARK_COL - 1, 1, 'F', A_DIM);
		rfill(UI_MARK_COL, 1, (unsigned char)('1' + ui_tab), A_DIM);
	}
	rout(UI_HEAD_ROW, UI_PANEL_COL, UI_COLS);
}

static const char hint_side[] = "Up/Down select  Right/Enter open  F12 close";
static const char hint_list[] = "Up/Down move  Right/Enter edit  Left back";
static const char hint_edit[] = "Left/Right change  Enter done";

static const char *help_text(void)
{
	static const char *const fs_help[] = {
		"Choose a disk image (ADF). Enter opens a folder, Backspace goes up, a letter jumps to the next name with it.",
		"Choose a CD image (ISO, or CUE with its tracks). Enter opens a folder, Backspace goes up, a letter jumps.",
		"Choose a Kickstart ROM image; loading it restarts the Amiga. Backspace goes up, a letter jumps."
	};
	const struct ui_item *it;
	if (ui_focus == UI_F_LIST && ui_edit)
		return hint_edit;
	if (ui_hints_on && ui_focus == UI_F_SIDEBAR)
		return hint_side;
	if (ui_hints_on && ui_focus == UI_F_LIST)
		return hint_list;
	switch (ui_focus) {
	case UI_F_DIALOG:
		return "Left/Right choose a button  Enter confirm  Esc cancel";
	case UI_F_FILESEL:
		return fs_help[fs_target];
	case UI_F_SIDEBAR:
		return ui_tabs[ui_tab].help;
	}
	it = item(cur[ui_tab]);
	return it && it->help ? it->help : ui_tabs[ui_tab].help;
}

/* the help field: the focus's key hints when the focus moved, the focused
   item's help after the next key, EDIT's hint while editing; a toast over
   any of them for 1 s */
void ui_draw_help(void)
{
	unsigned r;
	for (r = UI_HELP_ROW; r < UI_HELP_ROW + UI_HELP_ROWS; r++) {
		osd2_fill(r, 0, UI_HELP_COL, ' ', A_HELP);
		osd2_fill(r, UI_HELP_COL + UI_HELP_W, UI_COLS - UI_HELP_COL - UI_HELP_W, ' ', A_HELP);
	}
	osd2_wrap(UI_HELP_ROW, UI_HELP_COL, UI_HELP_W, UI_HELP_ROWS,
	          toast_on ? toast : help_text(), toast_on ? A_TOAST : A_HELP);
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

	rfill(UI_PANEL_COL, UI_PANEL_W, ' ', A_BASE);
	if (i >= nDirEntries) {
		if (i == 0)
			rput(UI_LABEL_COL, "No files!", FS_FILE_W, A_ERR);
	} else {
		name = entry_name(sort_table[i], &len, &dir);
		sel = i == iSelectedEntry;
		a = sel ? A_SEL : A_BASE;
		w = dir ? FS_DIR_W : FS_FILE_W;
		rfill(UI_PANEL_COL, UI_PANEL_W, ' ', a);
		if (sel && len > w) {
			unsigned p = sc_pos > len - w ? len - w : sc_pos;
			rput(UI_LABEL_COL, name + p, w, a);
		} else if (len > w) {               /* not selected: cut, "~" */
			rput(UI_LABEL_COL, name, w - 1, a);
			rfill(UI_LABEL_COL + w - 1, 1, '~', a);
		} else
			rput(UI_LABEL_COL, name, len, a);
		if (dir)
			rput(UI_MARK_COL - 5, "<DIR>", 5, sel ? a : A_DIRTAG);
	}
	rout(row, UI_PANEL_COL, UI_COLS);
}

void ui_draw_all(void)
{
	unsigned i;
	draw_sidebar();
	draw_lines();
	draw_header();
	for (i = 0; i < UI_LIST_ROWS; i++) {
		if (ui_focus == UI_F_FILESEL)
			draw_file_row(i);
		else
			ui_draw_item(i);
	}
	ui_draw_help();
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

/* the cursor on a selectable item, else the focus back to the sidebar */
static void fix_cursor(void)
{
	int i;
	if (ui_focus != UI_F_LIST)
		return;
	if (selectable(cur[ui_tab]))
		return;
	i = find_sel(0, 1);
	if (i < 0)
		ui_focus = UI_F_SIDEBAR;
	else
		cur[ui_tab] = (unsigned char)i;
}

static void ui_open(void)
{
	ui_open_now = 1;
	popup = 0;
	toast_on = 0;
	ui_focus = UI_F_SIDEBAR;        /* on the last category */
	ui_hints_on = 1;                /* the sidebar's key hints until a key */
	ui_edit = 0;
	ui_cfg_mask = mm_config_scan();
	if (ui_tab == UI_TAB_SYSTEM)
		sys_snapshot();
	osd_keys(1);
	ui_glyphs();
	osd2_pal_default();
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
	OsdHide();                      /* the keyboard back to the Amiga */
	if (DebugMode)
		debug2_show(1);             /* the debug page on the layer (menu.c), in place of the menu */
	else {
		osd2_disable();
		debug2_show(0);
	}
}

void ui_toast(const char *text)
{
	unsigned n;
	strncpy(toast, text, UI_TOAST_COLS);
	toast[UI_TOAST_COLS] = 0;
	toast_on = 1;
	toast_timer = GetTimer(UI_T_TOAST);
	if (ui_open_now) {
		ui_draw_help();
		return;
	}
	/* the menu is closed: a one-row window of its own on row 0 (the
	   title's and header's row, drawn again when the menu opens) */
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
/* dialogs, categories                                                */
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
	dlg.back = (ui_focus == UI_F_SIDEBAR) ? UI_F_SIDEBAR : UI_F_LIST;
	ui_focus = UI_F_DIALOG;
	dirty = 1;
}

static void dialog_end(unsigned char b)
{
	ui_focus = dlg.back;
	dirty = 1;
	dlg.done(b);
}

/* the focus into the category's list (stays in the sidebar if it has no
   selectable item) */
static void enter_list(void)
{
	ui_focus = UI_F_LIST;
	ui_edit = 0;
	fix_cursor();
	ui_hints_on = 1;                /* the focus moved: its key hints */
	dirty = 1;
}

static void to_sidebar(void)
{
	ui_focus = UI_F_SIDEBAR;
	ui_edit = 0;
	ui_hints_on = 1;
	dirty = 1;
}

/* EDIT the focused value item (a read-only one: the toast) */
static void edit_item(const struct ui_item *it)
{
	if (it->kind == UI_INFO)
		ui_toast("Read-only here: see Open classic menu");
	else
		ui_edit = 1;
}

static void switch_tab(unsigned char t)
{
	ui_tab = t;
	if (t == UI_TAB_SYSTEM)
		sys_snapshot();
	fix_cursor();
	dirty = 1;
}

/* leaving System (another category, or closing) after a change of memory
   or chipset: offer the reset it needs (the classic MENU_MEMORY_CHANGED) */
static void leave_done(unsigned char b)
{
	if (b == 0) {
		ui_close();
		OsdReset();
	} else if (pending == PENDING_CLOSE)
		ui_close();
	else {
		switch_tab(pending);
		if (pending_into)
			enter_list();
	}
}

static int leave_system(unsigned char to, unsigned char into)
{
	static const char *const b[] = { "Yes", "No" };
	if (ui_tab != UI_TAB_SYSTEM || (config.memory == sys_mem && (config.chipset & 0x1c) == sys_chip))
		return 0;
	pending = to;
	pending_into = into;
	ui_dialog("Reset", "Memory or chipset changed: this", "needs a reset. Reset the Amiga?", b, 2, 0, leave_done);
	return 1;
}

/* category t; into: the focus into its list */
static void goto_tab(unsigned char t, unsigned char into)
{
	if (t != ui_tab) {
		if (leave_system(t, into))
			return;
		switch_tab(t);
	}
	if (into)
		enter_list();
}

static void request_close(void)
{
	if (!leave_system(PENDING_CLOSE, 0))
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

/* an action item, a submenu, or Load/Save configuration's act */
static void activate(const struct ui_item *it)
{
	if (it->act)
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
	case KEY_ESC:
		dialog_end(dlg.n - 1);
		return;
	default:
		return;
	}
	dirty = 1;
}

static void key_sidebar(unsigned char c)
{
	unsigned char t = ui_tab;
	switch (c) {
	case KEY_UP:
		if (t > 0)
			goto_tab(t - 1, 0);
		break;
	case KEY_DOWN:
		if (t + 1 < UI_TABS)
			goto_tab(t + 1, 0);
		break;
	case KEY_RIGHT:
	case KEY_ENTER:
	case KEY_SPACE:
		enter_list();
		break;
	case KEY_ESC:
		request_close();
		break;
	}
}

static void key_list(unsigned char c)
{
	const struct ui_item *it = item(cur[ui_tab]);
	int i;
	if (ui_edit) {
		switch (c) {
		case KEY_LEFT:
		case KEY_RIGHT:
			if (it)
				change(it, c == KEY_RIGHT ? 1 : -1);
			return;
		case KEY_ENTER:
		case KEY_SPACE:
		case KEY_ESC:
			ui_edit = 0;        /* done: the change stays */
			return;
		case KEY_UP:
		case KEY_DOWN:
			ui_edit = 0;        /* done, and move */
			break;
		default:
			return;
		}
	}
	switch (c) {
	case KEY_LEFT:              /* back to the sidebar, whatever the item */
		to_sidebar();
		break;
	case KEY_ESC:
		to_sidebar();
		break;
	case KEY_UP:
		i = find_sel(cur[ui_tab] - 1, -1);
		if (i >= 0)
			cur[ui_tab] = (unsigned char)i;
		break;
	case KEY_DOWN:
		i = find_sel(cur[ui_tab] + 1, 1);
		if (i >= 0)
			cur[ui_tab] = (unsigned char)i;
		break;
	case KEY_RIGHT:
		if (it && has_value(it))
			edit_item(it);
		else if (it && (it->flags & UI_SUB))
			activate(it);
		break;
	case KEY_ENTER:
	case KEY_SPACE:
		if (it && has_value(it) && !(it->flags & UI_ENTERACT))
			edit_item(it);
		else if (it)
			activate(it);
		break;
	}
}

static void key_open(unsigned char c)
{
	int i;
	unsigned char t = ui_tab;

	ui_hints_on = 0;                    /* a key: the help field shows the help */
	dirty = 1;
	/* EDIT keeps only its own keys (key_list); any other ends it */
	if (ui_edit && c != KEY_LEFT && c != KEY_RIGHT && c != KEY_UP && c != KEY_DOWN &&
	    c != KEY_ENTER && c != KEY_SPACE && c != KEY_ESC)
		ui_edit = 0;
	if (c == KEY_MENU) {
		/* F12 (and the menu button, the same code) closes from anywhere:
		   a dialog is cancelled first (the System prompt may close) */
		if (ui_focus == UI_F_DIALOG) {
			dialog_end(dlg.n - 1);
			if (!ui_open_now || ui_focus == UI_F_DIALOG)
				return;
		}
		if (ui_focus == UI_F_FILESEL)
			ui_focus = UI_F_LIST;
		request_close();
		return;
	}
	if (ui_focus == UI_F_DIALOG) {
		key_dialog(c);
		return;
	}
	if (ui_focus == UI_F_FILESEL) {
		key_files(c);
		return;
	}
	if (c >= KEY_F1 && c <= KEY_F5) {
		goto_tab(c - KEY_F1, 1);
		return;
	}
	switch (c) {
	case KEY_PGUP:
		goto_tab((t + UI_TABS - 1) % UI_TABS, ui_focus == UI_F_LIST);
		return;
	case KEY_PGDN:
		goto_tab((t + 1) % UI_TABS, ui_focus == UI_F_LIST);
		return;
	}
	if (t == UI_TAB_MAIN) {
		/* keypad +/- add or remove a floppy drive, Backspace ejects all */
		if ((c == KEY_KPPLUS && config.floppy.drives < 3) || (c == KEY_KPMINUS && config.floppy.drives > 0)) {
			config.floppy.drives += c == KEY_KPPLUS ? 1 : -1;
			ConfigFloppy(config.floppy.drives, config.floppy.speed);
			return;
		}
		if (c == KEY_BACK) {
			for (i = 0; i <= drives && i < 4; i++)
				df[i].status = 0;
			return;
		}
	}
	if (ui_focus == UI_F_SIDEBAR)
		key_sidebar(c);
	else
		key_list(c);
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
			if (DebugMode)
				debug2_show(1);     /* the debug page back over the toast's row */
			else
				osd2_disable();
		}
		if (ui_open_now)
			ui_draw_help();
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
		if (core_caps & CORE_CAPS_TEMP)
			draw_temp();
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
	if (!ui_open_now && !popup && DebugMode)
		_showdebugmessages();       /* (not under a toast: it draws row 0 too) */
}

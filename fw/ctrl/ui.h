#ifndef UI_H
#define UI_H

/*
 * ui: the OSD menu on the 720p text layer (osd2.h; findings/osd-redesign/
 * plan.md 3.6, 3.7, 3.11, 5), in the layout of Paul's Samsung monitor OSD
 * (2026-10-27).  A 64 x 20 window of cells at scale 2:
 *
 *   cols 0-16   the sidebar: row 0 the title; the five categories (Main,
 *               Storage, System, Video, Acceleration) as 3-row bars from
 *               row 2 (icon at cols 1-2, the name from col 4 on the middle
 *               row); the selected one on a blue bar (dark blue while the
 *               focus is in its list); row 17 the die temperature
 *   col 17      a vertical line
 *   cols 18-63  the item panel: row 0 the category's name (blue), row 1 a
 *               line, rows 2-17 the items: label at col 20, the value
 *               right-aligned to col 60 (numbers as a bar and the number),
 *               col 62 the marker (the submenu arrow; the change arrows
 *               around the focused value: one cell before the value and
 *               at col 62)
 *   rows 18-19  the help field (dark blue), full width: the key hints when
 *               the menu opens, then the focused item's help; a toast for
 *               1 s
 *
 * Over the panel: one dialog at a time (a red box over rows 6-13), the
 * file selector (16 entries in the item rows, the selected long name
 * scrolls), or the error page (menu.c ShowError).  Main's About and
 * Supporters are pages over the whole window (below).  With the menu
 * closed a toast shows as a one-row window of its own.
 *
 * menu.c's HandleUI() runs ui_handle() on a core with the text layer
 * (osd2_caps); on any other core the classic menu is all there is.  (Its
 * ui_legacy_active, the hand-over to the classic pages About and
 * Supporters had, is never set since they are native; Phase 6 deletes the
 * classic menu with it.)
 *
 * Keys (Paul, 2026-10-27; joystick: Up/Down/Left/Right, fire = Enter,
 * fire 2 = the menu button, which sends F12's code):
 *   The menu opens with the focus in the sidebar, on the last category.
 *   Sidebar: Up/Down the category (its items shown at once); Right, Enter
 *   or Space into its list; Esc closes.
 *   List (Samsung, Paul 10-27): Up/Down the item; Left or Esc back to the
 *   sidebar, whatever the item; Right on a value item EDIT (a read-only
 *   value: a toast), on a submenu item opens it; Enter/Space: a value item
 *   EDIT, anything else activates (Load/Save configuration: Enter loads /
 *   saves, Right chooses the slot in EDIT).
 *   EDIT: Left/Right change the value (live); Enter, Space or Esc done (the
 *   change stays); Up/Down done and move; any other key ends it too.
 *   Anywhere: F1-F5 a category and into its list; PgUp/PgDn the previous/
 *   next category; F12 (the menu button) closes.
 *   Dialog: Left/Right (Up/Down) the button, Enter/Space it, Esc cancels.
 *   Error page: Left/Right the other error categories, Enter/Space OK (or
 *   Reboot); nothing else, as the classic page.
 *   Leaving a category (another one, or closing): System after a memory or
 *   chipset change offers the reset (MENU_MEMORY_CHANGED), Storage after a
 *   change of the IDE slots the reset that applies it (MENU_HARDFILE_CHANGED,
 *   No drops the change).
 *   File selector: Up/Down, PgUp/PgDn (and Left/Right) a page, Home the
 *   top, Backspace the parent directory, a letter the next name with it,
 *   Esc back to the list.  Main: keypad +/- add or remove a floppy drive,
 *   Backspace ejects all floppies.
 *   The classic shortcuts as in menu.c: Ctrl-Alt-keypad +/- turbo,
 *   LShift-keypad +/- volume, LShift-keypad . refreshes the ADV7511,
 *   Ctrl-Alt-keypad 0 autofire (menu closed), Ctrl-Alt-F12 debug mode.
 */

#include "osd2.h"

/* the window (cells at scale 2: 16 x 32 pixels; x0, y0 in 8-pixel units) */
#define UI_COLS  64
#define UI_ROWS  20
#define UI_SCALE 2
#define UI_X0    16           /* (1280 - 64 * 16) / 2 / 8 */
#define UI_Y0    5            /* (720 - 20 * 32) / 2 / 8 */
/* the toast window with the menu closed: row 0, 40 cells, lower middle */
#define UI_TOAST_COLS 40
#define UI_TOAST_X0   40
#define UI_TOAST_Y0   75

/* the sidebar */
#define UI_SIDE_W     17      /* cols 0-16 */
#define UI_CAT_ROW    2       /* category k: rows 2 + 3k .. 4 + 3k */
#define UI_CAT_H      3
#define UI_ICON_COL   1
#define UI_CAT_COL    4
#define UI_TEMP_ROW   17
#define UI_LINE_COL   17      /* the vertical line */
/* the item panel */
#define UI_PANEL_COL  18
#define UI_PANEL_W    46
#define UI_HEAD_ROW   0
#define UI_LIST_ROW   2
#define UI_LIST_ROWS  16
#define UI_LABEL_COL  20
#define UI_VALUE_END  60      /* values end here (right-aligned), a space after */
#define UI_MARK_COL   62      /* the submenu / change arrow */
#define UI_BAR_W      16      /* UI_BAR: 16 cells, a space, 2 digits */
#define UI_BAR_COL    (UI_VALUE_END - 2 - UI_BAR_W)
/* the help field */
#define UI_HELP_ROW   18
#define UI_HELP_ROWS  2
#define UI_HELP_COL   1
#define UI_HELP_W     62
/* the dialog box */
#define UI_DLG_R0     6
#define UI_DLG_R1     13
#define UI_DLG_C0     21
#define UI_DLG_C1     60
#define UI_DLG_MID    41      /* text centred here */

/* GetTimer offsets for ms milliseconds: TIMER counts of 5.804 ms, less the
   one count CheckTimer adds (it fires once TIMER passed the armed count) */
#define UI_T(ms) (((ms) * 1000UL + 2902) / 5804 - 1)
#define UI_T_TOAST       UI_T(1000)
#define UI_T_SCROLL_HOLD UI_T(500)   /* a long name: its start, held */
#define UI_T_SCROLL_STEP UI_T(125)   /* then one cell per step: 8 cells/s */
#define UI_T_SCROLL_END  UI_T(1000)  /* its end, held, then from the start */
#define UI_T_STATUS      UI_T(1000)  /* the temperature's refresh */

/* item kinds */
enum {
	UI_SEP,       /* an empty row */
	UI_CYCLE,     /* a value: EDIT's Left/Right step it (get/set over nvalues,
	                 or step()); Enter EDIT (or act, UI_ENTERACT) */
	UI_ACTION     /* Enter runs act(); a value text if text() */
};
/* item flags */
#define UI_CLAMP    0x02      /* Left/Right stop at the ends (volume) */
#define UI_HIDE     0x04      /* not available: an empty row, not greyed */
#define UI_ENTERACT 0x08      /* UI_CYCLE: Enter runs act() */
#define UI_BAR      0x10      /* the value 0..nvalues-1 as a bar and the number */
#define UI_SUB      0x20      /* Enter opens something: the submenu arrow */
#define UI_IDE2     0x40      /* only on a core with IDE port 2 (else an empty row) */

struct ui_item {
	const char *label;
	const char *help;
	const char *const *values;               /* value names, or NULL: text() */
	unsigned char (*get)(unsigned char arg);  /* the value index */
	void (*set)(unsigned char arg, unsigned char v);
	const char *(*text)(unsigned char arg);   /* the value as text */
	void (*act)(unsigned char arg);
	unsigned char (*avail)(unsigned char arg); /* 0: greyed, not selectable */
	/* EDIT's Left (-1) / Right (+1) when the value is no index (Video Pos,
	   the IDE slot type): in place of get/set */
	void (*step)(unsigned char arg, int dir);
	/* the help with a live part (the HDMI readback): in place of help,
	   drawn again every second while the item is focused */
	const char *(*helpf)(unsigned char arg);
	unsigned char kind, arg, nvalues, flags;
};

struct ui_tab {
	const char *name;
	const char *help;
	const struct ui_item *items;
	unsigned char n;
	unsigned char icon_fg;          /* the icon's colour (osd_icons.h: OSD_ICON_MAIN + 2 * tab) */
};

#define UI_TABS 5
enum { UI_TAB_MAIN, UI_TAB_STORAGE, UI_TAB_SYSTEM, UI_TAB_VIDEO, UI_TAB_ACCEL };
extern const struct ui_tab ui_tabs[UI_TABS];

/* focus */
enum { UI_F_LIST, UI_F_SIDEBAR, UI_F_DIALOG, UI_F_FILESEL, UI_F_ERROR, UI_F_PAGE };

/* Main's About and Supporters pages (ui_about.c, ui_supporters.c; plan
   3.8): the whole window (rows 0-17 the page, 18-19 the help field), an
   effect animated from ui_tick() every UI_T_FX, drawn through the shadow
   (cells that change) and palette entries 8-15 (the menu uses 0-7).
   Esc, Left, Enter or Space back to Main's list, F1-F5 a category, F12
   closes; a page may take other keys first (Supporters: Up/Down its other
   view).  Its glyphs go into font slots the menu does not use (ui_fx_code)
   when it opens, and the ROM font (font8x16.h) back into them when it
   ends, with the menu's palette: the menu after a page is the menu before
   it, cell, glyph and colour. */
enum { UI_PAGE_ABOUT, UI_PAGE_SUPPORTERS };
void ui_page_open(unsigned char which);      /* an item's act */
struct ui_page {
	void (*open)(void);           /* glyphs, palette (committed), rows 0-17 into the shadow */
	void (*step)(void);           /* one frame of the effect */
	int (*key)(unsigned char c);  /* the page's own keys (1: taken), or NULL */
	const char *(*help)(void);    /* the help field's text */
	unsigned char slots;          /* the glyph slots 0..slots-1 it uploads */
};
extern const struct ui_page ui_about, ui_supporters;
/* the frame time: GetTimer(2) fires after 3 TIMER counts, 17.4 ms (57 Hz;
   the layer latches the palette at its next frame, 50 or 60 Hz) */
#define UI_T_FX 2
/* glyph slots: the font codes the menu leaves alone, 0x80-0xBF and, past
   the icons (0xC0-0xC9), 0xCA-0xFF */
#define UI_FX_SLOTS 118
unsigned char ui_fx_code(unsigned slot);
/* n glyphs (16 rows each) into slots slot.. (split around the icons) */
void ui_fx_font(unsigned slot, unsigned n, const unsigned char *rows);
/* xorshift32: the effects' random numbers (deterministic: the goldens) */
unsigned long ui_fx_rand(void);
void ui_fx_seed(unsigned long seed);

/* the engine, once per main-loop pass (menu.c HandleUI) */
void ui_handle(void);
/* one key event (OsdGetCtrl's code), and the timers: ui_handle's parts */
void ui_key(unsigned char c);
void ui_tick(void);
/* draw into the shadow (osd2_flush sends it) */
void ui_draw_all(void);
void ui_draw_item(unsigned i);
void ui_draw_help(void);

/* menu.c HandleUI: the classic menu instead (nothing sets it since About
   and Supporters are native; Phase 6 deletes it with the classic menu) */
extern unsigned char ui_legacy_active;
/* the error page (menu.c ShowError / ErrorMessage on a core with the
   layer): the menu opens on it at error category `page` (errors.h) */
void ui_error_show(int page);

/* for the item tables (ui_tabs.c) */
void ui_toast(const char *text);
/* the file selector; on a chosen file: InsertFloppy / CD_Insert / the
   Kickstart reload dialog / the IDE slot arg's image (mm_hdf_selected:
   a hardfile, or a disc of a CD slot) */
enum { UI_FS_FLOPPY, UI_FS_CD, UI_FS_KICK, UI_FS_HDF, UI_FS_HDCD };
void ui_fs_open(unsigned char target, unsigned char arg);
/* a dialog: title, two lines, buttons; done(button) on Enter, done(n - 1)
   on Esc */
void ui_dialog(const char *title, const char *l1, const char *l2,
               const char *const *buttons, unsigned char n, unsigned char sel,
               void (*done)(unsigned char button));
void ui_close(void);
/* the configuration files found when the menu opened (bit = slot) */
extern unsigned char ui_cfg_mask;
/* Video: the RTG screen is on (osd2_rtg_active), read when the category
   is shown and at each position step; the position items edit its pair */
extern unsigned char ui_rtg;
/* the state the item tables show (the engine's); ui_hints_on: the help
   field shows the key hints of the focus (set when the focus moves between
   sidebar and list, cleared by the next key: then the item's help);
   ui_edit: the focused value item is being changed (EDIT, list focus) */
extern unsigned char ui_open_now, ui_tab, ui_focus, ui_hints_on, ui_edit;

#endif

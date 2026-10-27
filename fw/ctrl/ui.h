#ifndef UI_H
#define UI_H

/*
 * ui: the OSD menu on the 720p text layer (osd2.h; findings/osd-redesign/
 * plan.md 3.6, 3.7, 3.11, 5).  A 64 x 20 window of cells at scale 2:
 *
 *   row 0       the tab bar: Main, Storage, System, Video, Acceleration
 *   row 1       a separator
 *   rows 2-17   the items (cols 0-39: label at 2, value at 22) and the help
 *               panel (cols 41-63: the item's help, word-wrapped)
 *   row 18      a separator
 *   row 19      the status line: die temperature, key hints, or a message
 *               (a "toast", 1 s)
 *
 * Over the list: one dialog at a time (a box over rows 6-13), or the file
 * selector (16 entries, the selected long name scrolls).  With the menu
 * closed a toast shows as a one-row window of its own.
 *
 * menu.c's HandleUI() runs ui_handle() on a core with the text layer
 * (osd2_caps) unless the classic menu was asked for (ui_legacy_active);
 * on any other core the classic menu is all there is.
 *
 * Keys (plan 3.11): F1-F5 a tab; PgUp/PgDn the previous/next tab; Up past
 * the first item onto the tab bar, where Left/Right change the tab and
 * Down/Enter go back to the list (the joystick's way: it has no F keys);
 * Left/Right change the focused value; Enter/Space activate; Esc, F12 or
 * the menu button close (or back out of a dialog / the file selector).
 * File selector: Up/Down, PgUp/PgDn (and Left/Right) a page, Home the top,
 * Backspace the parent directory, a letter the next name with it.  Main:
 * keypad +/- add or remove a floppy drive, Backspace ejects all floppies.
 * The classic shortcuts as in menu.c: Ctrl-Alt-keypad +/- turbo,
 * LShift-keypad +/- volume, LShift-keypad . refreshes the ADV7511,
 * Ctrl-Alt-keypad 0 autofire (menu closed), Ctrl-Alt-F12 debug mode.
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

/* list geometry */
#define UI_LIST_ROW   2
#define UI_LIST_ROWS  16
#define UI_LIST_W     40
#define UI_LABEL_COL  2
#define UI_VALUE_COL  22
#define UI_VALUE_W    16
#define UI_WIDE_COL   8       /* UI_WIDE items: the value from here */
#define UI_WIDE_W     30
#define UI_HELP_COL   42
#define UI_HELP_W     21
#define UI_STATUS_ROW 19

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
	UI_CYCLE,     /* a value: Left/Right step it, Enter the next (or act, UI_ENTERACT) */
	UI_INFO,      /* a value shown, changed in the classic menu (Phase 4 brings it here) */
	UI_ACTION     /* Enter runs act(); a value text if text() */
};
/* item flags */
#define UI_WIDE     0x01      /* the value from col 8, 30 wide (floppies, CD) */
#define UI_CLAMP    0x02      /* Left/Right stop at the ends (volume) */
#define UI_HIDE     0x04      /* not available: an empty row, not greyed */
#define UI_ENTERACT 0x08      /* UI_CYCLE: Enter runs act() */

struct ui_item {
	const char *label;
	const char *help;
	const char *const *values;               /* value names, or NULL: text() */
	unsigned char (*get)(unsigned char arg);  /* the value index */
	void (*set)(unsigned char arg, unsigned char v);
	const char *(*text)(unsigned char arg);   /* the value as text */
	void (*act)(unsigned char arg);
	unsigned char (*avail)(unsigned char arg); /* 0: greyed, not selectable */
	unsigned char kind, arg, nvalues, flags;
};

struct ui_tab {
	const char *name;
	const char *help;
	const struct ui_item *items;
	unsigned char n;
};

#define UI_TABS 5
enum { UI_TAB_MAIN, UI_TAB_STORAGE, UI_TAB_SYSTEM, UI_TAB_VIDEO, UI_TAB_ACCEL };
extern const struct ui_tab ui_tabs[UI_TABS];

/* focus */
enum { UI_F_LIST, UI_F_TABBAR, UI_F_DIALOG, UI_F_FILESEL };

/* the engine, once per main-loop pass (menu.c HandleUI) */
void ui_handle(void);
/* one key event (OsdGetCtrl's code), and the timers: ui_handle's parts */
void ui_key(unsigned char c);
void ui_tick(void);
/* draw into the shadow (osd2_flush sends it) */
void ui_draw_all(void);
void ui_draw_item(unsigned i);
void ui_draw_status(void);

/* set while the classic menu runs instead (menu.c clears it when it closes) */
extern unsigned char ui_legacy_active;
/* the classic menu takes over (an error page, menu.c ShowError) */
void ui_legacy_takeover(void);

/* for the item tables (ui_tabs.c) */
void ui_toast(const char *text);
/* the file selector; on a chosen file: InsertFloppy / CD_Insert / the
   Kickstart reload dialog */
enum { UI_FS_FLOPPY, UI_FS_CD, UI_FS_KICK };
void ui_fs_open(unsigned char target, unsigned char arg);
/* a dialog: title, two lines, buttons; done(button) on Enter, done(n - 1)
   on Esc */
void ui_dialog(const char *title, const char *l1, const char *l2,
               const char *const *buttons, unsigned char n, unsigned char sel,
               void (*done)(unsigned char button));
void ui_close(void);
/* hand over to the classic menu at one of its pages (menu.h MENU_*) */
void ui_classic(unsigned char page, unsigned char sub);
/* the configuration files found when the menu opened (bit = slot) */
extern unsigned char ui_cfg_mask;
/* the state the item tables show (the engine's) */
extern unsigned char ui_open_now, ui_tab, ui_focus;

/* provided by menu.c: the classic menu, opened at a page */
void menu_classic_open(unsigned char page, unsigned char sub);

#endif

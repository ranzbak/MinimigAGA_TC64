/* ui_supporters: Main's Supporters page of the new menu (ui.h "the About
 * and Supporters pages"; findings/osd-redesign/plan.md 3.8).  The classic
 * page's thanks -- every supporter (osd.c supporters[]) and the lines
 * after them, its scroller's text that Phase 0 cut, the donation lines --
 * over a palette-cycled plasma, in two views (Up/Down):
 *
 *   names    row 0 "Thanks to"; rows 2-9 the 24 names in three columns;
 *            row 11 "+ all other contributors."; rows 13-15 the thanks to
 *            Espen Skog, Jens Drossler and the facebook group; row 17 the
 *            donation lines
 *   message  row 0 the title; rows 2-9 the scroller's text (why and how to
 *            support the work); rows 11-12 the donation lines
 *   rows 18-19 the help field (ui.c)
 *
 * The plasma is a field of static cells, drawn once: each cell's value v
 * (four sines of its row and column, one of them radial; 0..23) is the
 * palette colour 8 + v / 4 dithered towards the next one by v % 4 quarters
 * (a space, 25 %, 50 % or 75 % of the glyph's pixels in the next colour).
 * Entries 8-13 cycle: entry 8 + k is ramp(16k + t), a ramp of 96 colours
 * through six dark keys, t one more per step: the colours flow through the
 * field, one band per 16 steps.  The text has the plasma's colour of its
 * cell as background (its dither dropped), entry 14 (the names, the
 * message) or 15 (the rest) as foreground: both fade in from the plasma's
 * mid tone, 14 to white over the first 32 steps of a view, 15 to yellow 16
 * steps later.  Per step only the palette: 6 entries (8 with a fade) and
 * the window, 32 to 40 SPI bytes; no cell changes.  All state in bss.
 */
#include <string.h>

#include "hardware.h"
#include "osd.h"
#include "osd2.h"
#include "ui.h"

#define P_FIELD   OSD2_C_FREE         /* 8..13: the plasma */
#define P_NCOL    6
#define P_NAME    14                  /* the names, the message */
#define P_TEXT    15                  /* the title and the rest */
#define RAMP_LG   4
#define RAMP_STEP (1 << RAMP_LG)      /* ramp colours per key: 16 */
#define RAMP      (P_NCOL * RAMP_STEP)
#define FADE_LG   5
#define FADE      (1 << FADE_LG)      /* steps of a fade: 32 */
#define FADE2     16                  /* entry 15 starts this much later */

/* glyph slots: the three dithers */
#define S_DITHER  0
#define SLOTS     3

#define R_FIELD   18                  /* the plasma: rows 0..17 */
#define R_TITLE   0
#define R_NAMES   2
#define N_ROWS    8                   /* names per column */

/* the supporters, as the classic page's list had them (osd.c's
   supporters[], deleted in Phase 6): three columns of eight, top to bottom */
static const char *const names[24] = {
	"Jens Schoenfeld", "Jim Farley", "SIDKidd64", "Juan Jose Velez Ramirez",
	"Dag Jacobsen", "Bartol Filipovic", "Pasi Ylinen", "Andreas Beck",
	"Dirk Vroomen", "Nils Andreas", "Alvaro Fussen", "Sebastian",
	"Sebastian Bessler", "Valentin Angelovski", "Claudio Russo", "Dominic Skilton",
	"Sebastian Hermann", "Graham Campbell", "gamma0511", "Steve Jones",
	"Arkadiusz Kwasny", "Harry Fisch", "Sonke Smiletzki", "Tad Watson",
};
static const unsigned char name_col[3] = { 2, 26, 46 };
static const char *const thanks[] = {
	"Thanks also to Espen Skog, Jens Drossler and everyone",
	"on the Turbo Chameleon 64 facebook group",
	"for their enthusiasm and suggestions.",
};
static const char donate[] = "Donate: paypal.me/robinsonb5";
static const char patreon[] = "Patreon: coresforchameleon";
/* the classic page's scroller (Phase 0 cut it to the two lines above) */
static const char message[] =
	"I'm very grateful to these people for their support, which will give me the means "
	"and motivation to continue working on this core and others.  If you would like to "
	"contribute then one-off donations at paypal.me/robinsonb5 are very welcome, or if you "
	"wish you can contribute regularly at patreon.com/coresforchameleon - if you donate "
	"20UKP or more, or join the second tier at Patreon your name will be included on this "
	"screen, or the equivalent screen of future projects.";

/* the plasma's six keys (dark: the white text stays readable) and the
   text's fades */
static const unsigned long key_col[P_NCOL] = {
	0x10185A, 0x3A1470, 0x6A1458, 0x2A2C8A, 0x0E5A78, 0x0C3A5A
};
#define FADE_FROM 0x3A3A6AUL
#define NAME_TO   0xF0F0F0UL
#define TEXT_TO   0xF0C828UL

/* 32 + 31 sin(2 pi i / 64) */
static const unsigned char sin64[64] = {
	32, 35, 38, 41, 44, 46, 49, 51, 54, 56, 58, 59, 61, 62, 62, 63,
	63, 63, 62, 62, 61, 59, 58, 56, 54, 51, 49, 46, 44, 41, 38, 35,
	32, 28, 25, 22, 19, 17, 14, 12,  9,  7,  5,  4,  2,  1,  1,  0,
	 0,  0,  1,  1,  2,  4,  5,  7,  9, 12, 14, 17, 19, 22, 25, 28,
};

static unsigned char view, t, fade;
static unsigned char gl[SLOTS * 16];

/* the plasma's value of a cell, 0..23 */
static unsigned field(unsigned r, unsigned c)
{
	int dc = (int)c - 44, dr = 2 * ((int)r - 6);    /* the cells are twice as tall as wide */
	unsigned d2 = (unsigned)(dc * dc + dr * dr), d = 0, v;
	while ((d + 1) * (d + 1) <= d2)
		d++;
	v = sin64[(c * 2) & 63] + sin64[(r * 5 + 16) & 63] + sin64[(c + r * 3) & 63] + sin64[(d * 3) & 63];
	return (v >> 3) % (P_NCOL * 4);
}

static unsigned char field_bg(unsigned r, unsigned c)
{
	return (unsigned char)(P_FIELD + field(r, c) / 4);
}

static void field_rows(unsigned r0, unsigned r1)
{
	unsigned r, c;
	for (r = r0; r <= r1; r++)
		for (c = 0; c < UI_COLS; c++) {
			unsigned v = field(r, c), i = v / 4, q = v % 4;
			osd2_fill(r, c, 1, q ? ui_fx_code(S_DITHER + q - 1) : ' ',
			          OSD2_ATTR(P_FIELD + (i + 1) % P_NCOL, P_FIELD + i));
		}
}

/* text from (r, c): its own colour fg, the plasma's colour there bg */
static void text(unsigned r, unsigned c, const char *s, unsigned n, unsigned fg)
{
	for (; n && *s && c < UI_COLS; n--, s++, c++)
		osd2_fill(r, c, 1, (unsigned char)*s, OSD2_ATTR(fg, field_bg(r, c)));
}

static void centred(unsigned r, const char *s, unsigned fg)
{
	unsigned n = strlen(s);
	text(r, (UI_COLS - n) / 2, s, n, fg);
}

/* the message from row r, words wrapped at 62 columns from column 1 */
static void paragraph(unsigned r, const char *s)
{
	while (*s) {
		unsigned n = 0, brk = 0;
		while (s[n] && n < UI_COLS - 2) {
			if (s[n] == ' ')
				brk = n;
			n++;
		}
		if (s[n] && brk)
			n = brk;            /* break at the last space that fits */
		text(r++, 1, s, n, P_NAME);
		s += n;
		while (*s == ' ')
			s++;
	}
}

static void draw_view(void)
{
	unsigned i;
	field_rows(R_TITLE + 1, R_FIELD - 1);
	if (view == 0) {
		for (i = 0; i < 24; i++)
			text(R_NAMES + i % N_ROWS, name_col[i / N_ROWS], names[i], UI_COLS, P_NAME);
		centred(11, "+ all other contributors.", P_TEXT);
		for (i = 0; i < 3; i++)
			centred(13 + i, thanks[i], P_TEXT);
		text(17, 3, donate, UI_COLS, P_TEXT);
		text(17, UI_COLS - 3 - (unsigned)strlen(patreon), patreon, UI_COLS, P_TEXT);
	} else {
		paragraph(R_NAMES, message);
		centred(11, donate, P_TEXT);
		centred(12, patreon, P_TEXT);
	}
	fade = 0;
}

/* f / 2^lg of the way from colour a to b (f <= 2^lg) */
static unsigned long mix(unsigned long a, unsigned long b, unsigned f, unsigned lg)
{
	unsigned long out = 0;
	unsigned sh, n = 1u << lg;
	for (sh = 0; sh < 24; sh += 8) {
		unsigned x = (a >> sh) & 255, y = (b >> sh) & 255;
		out |= (unsigned long)((x * (n - f) + y * f) >> lg) << sh;
	}
	return out;
}

static void palette(void)
{
	unsigned k, f2 = fade > FADE2 ? fade - FADE2 : 0;
	for (k = 0; k < P_NCOL; k++) {
		unsigned j = (k * RAMP_STEP + t) % RAMP;
		osd2_pal(P_FIELD + k, OSD2_OPAQUE,
		         mix(key_col[j / RAMP_STEP], key_col[(j / RAMP_STEP + 1) % P_NCOL], j % RAMP_STEP, RAMP_LG));
	}
	osd2_pal(P_NAME, OSD2_OPAQUE, mix(FADE_FROM, NAME_TO, fade < FADE ? fade : FADE, FADE_LG));
	osd2_pal(P_TEXT, OSD2_OPAQUE, mix(FADE_FROM, TEXT_TO, f2 < FADE ? f2 : FADE, FADE_LG));
	osd2_commit(1, UI_SCALE, UI_X0, UI_Y0, UI_COLS, UI_ROWS);
}

static void sup_open(void)
{
	unsigned r;
	/* 25 %, 50 %, 75 % of the pixels (fg) */
	for (r = 0; r < 16; r++) {
		gl[r] = (r & 1) ? 0x22 : 0x88;
		gl[16 + r] = (r & 1) ? 0x55 : 0xAA;
		gl[32 + r] = (unsigned char)~gl[r];
	}
	ui_fx_font(S_DITHER, SLOTS, gl);
	view = 0;
	t = 0;
	fade = 0;
	palette();
	field_rows(R_TITLE, R_TITLE);
	centred(R_TITLE, "Thanks to", P_TEXT);
	draw_view();
}

static void sup_step(void)
{
	t = (unsigned char)((t + 1) % RAMP);
	if (fade < 255)
		fade++;
	palette();
}

/* Up/PgUp the names, Down/PgDn the message */
static int sup_key(unsigned char c)
{
	unsigned char v;
	switch (c) {
	case KEY_UP:
	case KEY_PGUP:
		v = 0;
		break;
	case KEY_DOWN:
	case KEY_PGDN:
		v = 1;
		break;
	default:
		return 0;
	}
	if (v != view) {
		view = v;
		draw_view();
		palette();
	}
	return 1;
}

static const char *sup_help(void)
{
	return view == 0 ? "Down the message  Esc back" : "Up the names  Esc back";
}

const struct ui_page ui_supporters = { sup_open, sup_step, sup_key, sup_help, SLOTS };

/* ui_about: Main's About page of the new menu (ui.h "the About and
 * Supporters pages"; findings/osd-redesign/plan.md 3.8, 3.9).  The Minimig
 * logo (osd_logo.h) and the credits of the classic page -- its scroller's
 * whole text, cut to two lines in Phase 0, as static lines -- over a
 * starfield, the title on a copper bar:
 *
 *   row  0      stars
 *   rows 1-2    the logo, 28 x 2 glyphs, centred (cols 18-45)
 *   row  3      stars
 *   row  4      the copper bar, "About" on it
 *   row  5      stars
 *   rows 6-13   the credits, centred, the names yellow
 *   row  14     stars
 *   rows 15-16  the licence
 *   row  17     the core's and the firmware's version
 *   rows 18-19  the help field (ui.c)
 *
 * One step per UI_T_FX:
 *  - the stars: 48 in three layers of 16 drift right to left, far 1/2 font
 *    pixel per step (a 1 x 1 dot), mid 1 (1 x 2), near 2 (2 x 2).  A star
 *    is one glyph, its dot at the star's x within the cell (one of two
 *    heights).  It shows only in a cell two spaces away from anything
 *    (never on the logo, the text or the bar: it passes behind them), so a
 *    step is char-only writes of the cells that change, the old cell back
 *    to a space, the new one its glyph.  Past the left edge it comes back
 *    at the right, on another row and height.
 *  - the copper bar: palette entry 8 + k (the bar's band k, 4 cells each
 *    outward from the centre) is hue(phase - 32k); the phase advances one
 *    per step, so the colours flow outward, one band per 32 steps (a full
 *    cycle of the hues 256 steps, 4.5 s).
 * Per step the palette (8 entries: 34 SPI bytes and the window's 6) and
 * the changed star cells; ui_test measures the bytes.  All state in bss.
 */
#include <string.h>

#include "hardware.h"
#include "fpga.h"
#include "menu_model.h"
#include "osd2.h"
#include "osd_logo.h"
#include "ui.h"

#define A(fg, bg) OSD2_ATTR(fg, bg)
#define A_SKY   A(OSD2_C_WHITE, OSD2_C_BLACK)   /* the sky: the stars white */
#define A_TEXT  A(OSD2_C_WHITE, OSD2_C_BLACK)
#define A_NAME  A(OSD2_C_YELLOW, OSD2_C_BLACK)
#define A_LIC   A(OSD2_C_BLUE, OSD2_C_BLACK)
#define A_VER   A(OSD2_C_DKBLUE, OSD2_C_BLACK)

/* glyph slots (ui_fx_code) */
#define S_LOGO  0
#define S_FAR   (S_LOGO + OSD_LOGO_GLYPHS)  /* 16: x 0..7 at the two heights */
#define S_MID   (S_FAR + 16)                /* 16: the same, two rows tall */
#define S_NEAR  (S_MID + 16)                /* 8: x 0, 2, 4, 6, 2 x 2, two heights */
#define S_SHADE (S_NEAR + 8)                /* the copper bar's cell */
#define SLOTS   (S_SHADE + 1)
_Static_assert(SLOTS <= UI_FX_SLOTS, "the About page's glyphs fit the free slots");

#define R_LOGO  1
#define C_LOGO  ((UI_COLS - OSD_LOGO_COLS) / 2)
#define R_BAR   4
#define R_CRED  6
#define R_LIC   15
#define R_VER   17
#define R_SKY   18                          /* the stars' rows: 0..17 */

#define NSTARS  48                          /* 16 per layer: far, mid, near */
#define X_SPAN  (UI_COLS * 8 * 16)          /* x in 1/16 font pixel */
#define Y_TOP   4                           /* the two heights in the cell */
#define Y_LOW   11

struct star {
	unsigned short x;
	unsigned char row, h;                   /* where it flies: cell row, height 0/1 */
	unsigned char drow, dcol, dch;          /* where it is drawn (dch 0: nowhere) */
};
static struct star stars[NSTARS];
static const unsigned char speed[3] = { 8, 16, 32 };
/* the cells a star shows in: bit c & 31 of word c >> 5 */
static unsigned long sky[R_SKY][2];
static unsigned char sky_row[R_SKY], n_sky;
static unsigned char phase;
static unsigned char gl[16];
static char ver[64];

/* the credits of the classic page (its scroller's text, Phase 0 cut it):
   a line each, centred; between '\1's a name */
static const char *const credits[] = {
	"Minimig AGA by \1Rok Krajnc\1,",
	"ported to Turbo Chameleon 64 by \1Alastair M. Robinson\1.",
	"Original Minimig by \1Dennis van Weeren\1",
	"with chipset improvements by \1Jakub Bednarski\1 and \1Sascha Boing\1.",
	"TG68K softcore by \1Tobias Gubener\1.",
	"Menu / disk code by \1Dennis van Weeren\1, \1Jakub Bednarski\1,",
	"\1Alastair M. Robinson\1 and \1Christian Vogelgsang\1.",
	"Minimig logo based on a design by \1Loriano Pagni\1.",
};
static const char *const licence[] = {
	"Minimig is distributed under the terms of the",
	"GNU General Public License version 3.",
};

/* a saturated colour of hue h (0..255), the copper's */
static unsigned long hue(unsigned h)
{
	unsigned s = (h & 255) * 6, f = s & 255, lo = 0x20, hi = 0xE8;
	unsigned long up = lo + ((hi - lo) * f >> 8), dn = hi - ((hi - lo) * f >> 8);
	switch (s >> 8) {
	case 0:  return ((unsigned long)hi << 16) | (up << 8) | lo;
	case 1:  return (dn << 16) | ((unsigned long)hi << 8) | lo;
	case 2:  return ((unsigned long)lo << 16) | ((unsigned long)hi << 8) | up;
	case 3:  return ((unsigned long)lo << 16) | (dn << 8) | hi;
	case 4:  return (up << 16) | ((unsigned long)lo << 8) | hi;
	default: return ((unsigned long)hi << 16) | ((unsigned long)lo << 8) | dn;
	}
}

static void copper(void)
{
	unsigned k;
	for (k = 0; k < 8; k++)
		osd2_pal(OSD2_C_FREE + k, OSD2_OPAQUE, hue((unsigned)(phase - 32 * k)));
	osd2_commit(1, UI_SCALE, UI_X0, UI_Y0, UI_COLS, UI_ROWS);
}

/* a star glyph: a dot w pixels wide at x, rows y..y+h-1 */
static void star_glyph(unsigned slot, unsigned x, unsigned w, unsigned y, unsigned h)
{
	unsigned r;
	memset(gl, 0, sizeof gl);
	for (r = y; r < y + h; r++)
		gl[r] = (unsigned char)((w == 2 ? 0xC0u : 0x80u) >> x);
	ui_fx_font(slot, 1, gl);
}

static void glyphs(void)
{
	static const unsigned char shade[16] = {
		0xFF, 0x55, 0x22, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x88, 0xAA, 0xFF
	};
	unsigned i;
	ui_fx_font(S_LOGO, OSD_LOGO_GLYPHS, (const unsigned char *)osd_logo_glyph);
	for (i = 0; i < 16; i++) {
		star_glyph(S_FAR + i, i & 7, 1, i < 8 ? Y_TOP : Y_LOW, 1);
		star_glyph(S_MID + i, i & 7, 1, i < 8 ? Y_TOP : Y_LOW, 2);
	}
	for (i = 0; i < 8; i++)
		star_glyph(S_NEAR + i, (i & 3) * 2, 2, i < 4 ? Y_TOP : Y_LOW, 2);
	ui_fx_font(S_SHADE, 1, shade);
}

/* a line with '\1' name marks, centred on row r */
static void credit(unsigned r, const char *t)
{
	unsigned n = 0, c;
	const char *p;
	unsigned char a = A_TEXT;
	for (p = t; *p; p++)
		if (*p != 1)
			n++;
	c = (UI_COLS - n) / 2;
	for (p = t; *p; p++) {
		if (*p == 1) {
			a = a == A_TEXT ? A_NAME : A_TEXT;
			continue;
		}
		osd2_fill(r, c++, 1, (unsigned char)*p, a);
	}
}

static char *two(char *p, unsigned v)
{
	*p++ = (char)('0' + v / 10 % 10);
	*p++ = (char)('0' + v % 10);
	return p;
}

/* "Core 2026-10-27   Firmware 2026-10-28-14-5" (VERSION bytes 0-3, version.h) */
static void version_line(void)
{
	char *p = ver;
	memcpy(p, "Core 20", 7);
	p = two(p + 7, core_version[1]);
	*p++ = '-';
	p = two(p, core_version[2]);
	*p++ = '-';
	p = two(p, core_version[3]);
	if (core_version[0]) {
		memcpy(p, " BETA", 5);
		p += 5;
	}
	memcpy(p, "   Firmware ", 12);
	p += 12;
	strncpy(p, fw_version, (size_t)(ver + sizeof ver - 1 - p));
	ver[sizeof ver - 1] = 0;
	osd2_put(R_VER, (UI_COLS - strlen(ver)) / 2, ver, A_VER);
}

static int blank(unsigned r, int c)
{
	return c < 0 || c >= UI_COLS || osd2_chr[r][c] == ' ';
}

/* the cells a star may show in: spaces with two more on each side (a star
   keeps off the text), not on the bar */
static void sky_map(void)
{
	unsigned r;
	int c;
	n_sky = 0;
	for (r = 0; r < R_SKY; r++) {
		sky[r][0] = sky[r][1] = 0;
		if (r == R_BAR)
			continue;
		for (c = 0; c < UI_COLS; c++)
			if (blank(r, c - 2) && blank(r, c - 1) && blank(r, c) && blank(r, c + 1) && blank(r, c + 2))
				sky[r][c >> 5] |= 1UL << (c & 31);
		if (sky[r][0] | sky[r][1])
			sky_row[n_sky++] = (unsigned char)r;
	}
}

static void star_new_row(struct star *s)
{
	unsigned long v = ui_fx_rand();
	s->row = sky_row[v % n_sky];
	s->h = (unsigned char)((v >> 8) & 1);
}

/* the star's glyph and column now */
static unsigned char star_ch(const struct star *s, unsigned layer)
{
	unsigned px = (s->x >> 4) & 7;
	if (layer == 0)
		return ui_fx_code(S_FAR + s->h * 8 + px);
	if (layer == 1)
		return ui_fx_code(S_MID + s->h * 8 + px);
	return ui_fx_code(S_NEAR + s->h * 4 + px / 2);
}

static void star_draw(struct star *s, unsigned layer)
{
	unsigned col = s->x >> 7;
	if (!((sky[s->row][col >> 5] >> (col & 31)) & 1)) {
		s->dch = 0;
		return;
	}
	s->drow = s->row;
	s->dcol = (unsigned char)col;
	s->dch = star_ch(s, layer);
	osd2_fill(s->drow, s->dcol, 1, s->dch, osd2_atr[s->drow][s->dcol]);
}

static void about_open(void)
{
	unsigned i, r, c;
	ui_fx_seed(0x2C0FFEEUL);
	glyphs();
	phase = 0;
	copper();
	osd2_clear_rows(0, R_SKY - 1, ' ', A_SKY);
	for (r = 0; r < OSD_LOGO_ROWS; r++)
		for (c = 0; c < OSD_LOGO_COLS; c++)
			osd2_fill(R_LOGO + r, C_LOGO + c, 1, ui_fx_code(S_LOGO + osd_logo_map[r][c]), A_TEXT);
	for (c = 0; c < UI_COLS; c++) {
		unsigned d = c < UI_COLS / 2 ? UI_COLS / 2 - 1 - c : c - UI_COLS / 2;   /* 0..31 from the centre */
		osd2_fill(R_BAR, c, 1, ui_fx_code(S_SHADE), A(OSD2_C_BLACK, OSD2_C_FREE + (d >> 2)));
	}
	for (i = 0, c = (UI_COLS - 5) / 2; i < 5; i++, c++)
		osd2_fill(R_BAR, c, 1, (unsigned char)"About"[i], osd2_atr[R_BAR][c]);
	for (i = 0; i < sizeof credits / sizeof credits[0]; i++)
		credit(R_CRED + i, credits[i]);
	for (i = 0; i < sizeof licence / sizeof licence[0]; i++)
		osd2_put(R_LIC + i, (UI_COLS - strlen(licence[i])) / 2, licence[i], A_LIC);
	version_line();
	sky_map();
	for (i = 0; i < NSTARS; i++) {
		struct star *s = &stars[i];
		s->x = (unsigned short)(ui_fx_rand() % X_SPAN);
		if (i / 16 == 2)
			s->x &= (unsigned short)~31u;   /* near: whole pixel pairs (2 x 2 at x 0, 2, 4, 6) */
		star_new_row(s);
		star_draw(s, i / 16);
	}
}

static void about_step(void)
{
	unsigned i;
	/* the stars that move to another cell or glyph leave theirs first, */
	for (i = 0; i < NSTARS; i++) {
		struct star *s = &stars[i];
		unsigned v = speed[i / 16];
		if (s->x < v) {
			s->x = (unsigned short)(s->x + X_SPAN - v);
			star_new_row(s);
		} else
			s->x = (unsigned short)(s->x - v);
		if (s->dch && (s->drow != s->row || s->dcol != s->x >> 7 || s->dch != star_ch(s, i / 16))) {
			osd2_fill(s->drow, s->dcol, 1, ' ', osd2_atr[s->drow][s->dcol]);
			s->dch = 0;
		}
	}
	/* then all are drawn, far to near (a star the erasing hit comes back;
	   one that did not move writes nothing) */
	for (i = 0; i < NSTARS; i++)
		star_draw(&stars[i], i / 16);
	phase++;
	copper();
}

static const char *about_help(void)
{
	return "Esc back";
}

const struct ui_page ui_about = { about_open, about_step, 0, about_help, SLOTS };

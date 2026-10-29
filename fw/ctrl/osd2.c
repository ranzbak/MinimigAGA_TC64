/* osd2: the driver of the 720p text layer (osd2.h has the model and the
 * SPI commands; findings/osd-redesign/plan.md 4.1, 5).  All state is in bss:
 * the shadow cell RAM (4 KB), per row the changed column span and whether
 * chars, attrs or both changed, the shadow palette and the last window. */
#include <string.h>

#include "hardware.h"
#include "osd.h"
#include "osd2.h"

unsigned char osd2_caps;
unsigned char osd2_chr[OSD2_ROWS][OSD2_COLS];
unsigned char osd2_atr[OSD2_ROWS][OSD2_COLS];

/* per row: the changed span lo..hi (valid while kind != 0) and what changed */
#define K_CHR 1
#define K_ATR 2
static unsigned char d_lo[OSD2_ROWS], d_hi[OSD2_ROWS], d_kind[OSD2_ROWS];

static unsigned char pal[16][4];        /* {mode << 6, r, g, b}, as sent */
static unsigned short pal_dirty;        /* entries changed since the last commit */
static unsigned short pal_sent;         /* entries sent at least once */
static unsigned char win[5];            /* the last 0x5C bytes */

unsigned char osd2_detect(int magic_a4, const unsigned char v[4])
{
	osd2_caps = (magic_a4 && v[0] == OSD2_MAGIC && v[1] != 0 &&
	             v[2] == OSD2_COLS && v[3] == OSD2_ROWS) ? v[1] : 0;
	return osd2_caps;
}

static void mark(unsigned row, unsigned col, unsigned kind)
{
	if (!d_kind[row]) {
		d_lo[row] = d_hi[row] = (unsigned char)col;
	} else {
		if (col < d_lo[row]) d_lo[row] = (unsigned char)col;
		if (col > d_hi[row]) d_hi[row] = (unsigned char)col;
	}
	d_kind[row] |= (unsigned char)kind;
}

/* one cell, in range; kinds: which of char / attr to write */
static void cell(unsigned row, unsigned col, unsigned char ch, unsigned char attr, unsigned kinds)
{
	unsigned k = 0;
	if ((kinds & K_CHR) && osd2_chr[row][col] != ch) {
		osd2_chr[row][col] = ch;
		k |= K_CHR;
	}
	if ((kinds & K_ATR) && osd2_atr[row][col] != attr) {
		osd2_atr[row][col] = attr;
		k |= K_ATR;
	}
	if (k)
		mark(row, col, k);
}

/* n cells from (row, col): the first len characters of s, then spaces */
static void put_len(unsigned row, unsigned col, unsigned n, const char *s, unsigned len,
                    unsigned char attr)
{
	unsigned i;
	if (row >= OSD2_ROWS)
		return;
	for (i = 0; i < n && col + i < OSD2_COLS; i++)
		cell(row, col + i, i < len ? (unsigned char)s[i] : ' ', attr, K_CHR | K_ATR);
}

void osd2_put(unsigned row, unsigned col, const char *text, unsigned char attr)
{
	unsigned len = strlen(text);
	put_len(row, col, len, text, len, attr);
}

void osd2_putn(unsigned row, unsigned col, unsigned n, const char *text, unsigned char attr)
{
	unsigned len = strlen(text);
	put_len(row, col, n, text, len < n ? len : n, attr);
}

void osd2_fill(unsigned row, unsigned col, unsigned n, unsigned char ch, unsigned char attr)
{
	unsigned i;
	if (row >= OSD2_ROWS)
		return;
	for (i = 0; i < n && col + i < OSD2_COLS; i++)
		cell(row, col + i, ch, attr, K_CHR | K_ATR);
}

void osd2_attr(unsigned row, unsigned col, unsigned n, unsigned char attr)
{
	unsigned i;
	if (row >= OSD2_ROWS)
		return;
	for (i = 0; i < n && col + i < OSD2_COLS; i++)
		cell(row, col + i, 0, attr, K_ATR);
}

void osd2_char(unsigned row, unsigned col, unsigned char ch)
{
	if (osd2_chr[row][col] != ch) {
		osd2_chr[row][col] = ch;
		mark(row, col, K_CHR);
	}
}

void osd2_box(unsigned r0, unsigned c0, unsigned r1, unsigned c1, unsigned char attr)
{
	unsigned r, c;
	if (r1 < r0 || c1 < c0)
		return;
	for (c = c0; c <= c1 && c < OSD2_COLS; c++) {
		unsigned char ch = (c == c0 || c == c1) ? OSD2_BOX_CORNER : OSD2_BOX_H;
		if (r0 < OSD2_ROWS) cell(r0, c, ch, attr, K_CHR | K_ATR);
		if (r1 < OSD2_ROWS) cell(r1, c, ch, attr, K_CHR | K_ATR);
	}
	for (r = r0 + 1; r < r1 && r < OSD2_ROWS; r++) {
		if (c0 < OSD2_COLS) cell(r, c0, OSD2_BOX_V, attr, K_CHR | K_ATR);
		if (c1 < OSD2_COLS) cell(r, c1, OSD2_BOX_V, attr, K_CHR | K_ATR);
	}
}

void osd2_clear_rows(unsigned r0, unsigned r1, unsigned char ch, unsigned char attr)
{
	unsigned r;
	for (r = r0; r <= r1 && r < OSD2_ROWS; r++)
		osd2_fill(r, 0, OSD2_COLS, ch, attr);
}

unsigned osd2_wrap(unsigned row, unsigned col, unsigned width, unsigned lines,
                   const char *text, unsigned char attr)
{
	const char *p = text;
	unsigned used = 0, k;
	if (!width)
		return 0;
	while (*p) {
		unsigned i = 0, take, next, hard = 0;
		while (p[i] && p[i] != '\n' && i < width)
			i++;
		if (!p[i]) {                    /* the rest fits */
			take = next = i;
		} else if (p[i] == '\n') {      /* a hard break */
			take = i;
			next = i + 1;
			hard = 1;
		} else if (p[i] == ' ') {       /* width reached at a space */
			take = i;
			next = i + 1;
		} else {
			/* width reached inside a word: break before the word, or cut
			   a word longer than the width */
			unsigned j = i;
			while (j > 0 && p[j - 1] != ' ')
				j--;
			if (j == 0) {
				take = next = width;
			} else {
				take = j - 1;
				next = j;
			}
		}
		if (used < lines)
			put_len(row + used, col, width, p, take, attr);
		used++;
		if (!hard)                      /* a soft break eats the spaces after it */
			while (p[next] == ' ')
				next++;
		p += next;
	}
	for (k = used; k < lines; k++)
		put_len(row + k, col, width, "", 0, attr);
	return used;
}

void osd2_invalidate(void)
{
	unsigned r;
	for (r = 0; r < OSD2_ROWS; r++) {
		d_lo[r] = 0;
		d_hi[r] = OSD2_COLS - 1;
		d_kind[r] = K_CHR | K_ATR;
	}
}

unsigned osd2_flush(void)
{
	unsigned n = 0, r, c;
	for (r = 0; r < OSD2_ROWS; r++) {
		unsigned k = d_kind[r];
		unsigned idx = r * OSD2_COLS + d_lo[r];
		if (!k)
			continue;
		EnableOsd();
		SPI(OSD2_CMD_TXT);
		SPI(k == (K_CHR | K_ATR) ? OSD2_TXT_PAIRS : k == K_CHR ? OSD2_TXT_CHARS : OSD2_TXT_ATTRS);
		SPI((idx >> 8) & 0x07);
		SPI(idx & 0xff);
		n += 4;
		for (c = d_lo[r]; c <= d_hi[r]; c++) {
			if (k & K_CHR) { SPI(osd2_chr[r][c]); n++; }
			if (k & K_ATR) { SPI(osd2_atr[r][c]); n++; }
		}
		DisableOsd();
		d_kind[r] = 0;
	}
	return n;
}

void osd2_pal(unsigned i, unsigned mode, unsigned long rgb)
{
	unsigned char e[4];
	if (i > 15)
		return;
	e[0] = (unsigned char)((mode & 3) << 6);
	e[1] = (unsigned char)(rgb >> 16);
	e[2] = (unsigned char)(rgb >> 8);
	e[3] = (unsigned char)rgb;
	if (memcmp(pal[i], e, 4) || !(pal_sent & (1u << i))) {
		/* a changed entry, or one never sent (the layer's staging palette
		   is not the shadow's zeros after a firmware restart) */
		memcpy(pal[i], e, 4);
		pal_dirty |= (unsigned short)(1u << i);
	}
}

/* the menu's eight colours (osd2.h); 8-15 free, loaded black */
static const unsigned long pal_scheme[8] = {
	0x000000, 0xF0F0F0, 0x1478E6, 0x3C5A9A, 0xF0C828, 0x3CC85A, 0xE03C3C, 0x000000
};

void osd2_pal_default(void)
{
	unsigned i;
	for (i = 0; i < 16; i++)
		osd2_pal(i, i == OSD2_C_CLEAR ? OSD2_VIDEO : OSD2_OPAQUE, i < 8 ? pal_scheme[i] : 0);
}

static void send_win(void)
{
	unsigned i;
	EnableOsd();
	SPI(OSD2_CMD_CFG);
	for (i = 0; i < 5; i++)
		SPI(win[i]);
	DisableOsd();
}

void osd2_commit(int enable, int scale, unsigned x0, unsigned y0, unsigned cols, unsigned rows)
{
	if (pal_dirty) {
		unsigned lo = 0, hi = 15, e, b;
		while (!(pal_dirty & (1u << lo))) lo++;
		while (!(pal_dirty & (1u << hi))) hi--;
		EnableOsd();
		SPI(OSD2_CMD_PAL);
		SPI(lo);
		for (e = lo; e <= hi; e++)
			for (b = 0; b < 4; b++)
				SPI(pal[e][b]);
		DisableOsd();
		pal_sent |= pal_dirty;
		pal_dirty = 0;
	}
	win[0] = (unsigned char)((enable ? 1 : 0) | (scale == 2 ? 2 : 0));
	win[1] = (unsigned char)x0;
	win[2] = (unsigned char)y0;
	win[3] = (unsigned char)cols;
	win[4] = (unsigned char)rows;
	send_win();
}

void osd2_disable(void)
{
	win[0] &= (unsigned char)~1u;
	send_win();
}

void osd2_font(unsigned first, unsigned n, const unsigned char *data)
{
	unsigned adr = first * 16, i;
	EnableOsd();
	SPI(OSD2_CMD_FONT);
	SPI((adr >> 8) & 0x0f);
	SPI(adr & 0xff);
	for (i = 0; i < n * 16; i++)
		SPI(data[i]);
	DisableOsd();
}

void osd2_init(unsigned char attr)
{
	memset(osd2_chr, ' ', sizeof osd2_chr);
	memset(osd2_atr, attr, sizeof osd2_atr);
	osd2_invalidate();
	pal_dirty = 0;
	pal_sent = 0;
	osd2_pal_default();
	osd2_commit(0, 1, 0, 0, 0, 0);
}

unsigned char osd2_rtg_active(void)
{
	unsigned i;
	unsigned char st;
	if (osd2_caps < OSD2_V_STATUS)
		return 0;
	EnableOsd();
	SPI(OSD_CMD_VERSION);
	for (i = 0; i < 14; i++)
		SPI_reply();
	st = SPI_reply();
	DisableOsd();
	return (st & OSD2_ST_RTG) ? 1 : 0;
}

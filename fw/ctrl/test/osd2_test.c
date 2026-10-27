/* osd2_test: the text layer driver (osd2.c, findings/osd-redesign/plan.md 4.1,
 * 5) on the mock's SPI trace.  The expected byte streams are written from
 * the command spec of userio_osd.v (plan 4.1), not from a run of the code:
 *   0x2C mode, cell[10:8], cell[7:0], then per cell char,attr (mode 0),
 *        char (mode 1) or attr (mode 2); cell = row * 64 + col
 *   0x3C adr[11:8], adr[7:0], bytes (glyph n row r at n * 16 + r)
 *   0x4C first entry, {mode << 6, r, g, b} per entry
 *   0x5C ctrl {bit 0 enable, bit 1 scale 2}, x0/8, y0/8, cols, rows
 * Every frame is one OSD chip select (trace "20 <out> / <in>"); the OSD
 * answers the idle byte 0xFF.  Also: detection (VERSION bytes 10..13), the
 * dirty-row bookkeeping (a change is sent once, as one run per row with the
 * smallest mode that covers it; an unchanged redraw sends nothing),
 * clipping, word wrap, the palette resend rule.
 *   make -C fw/ctrl/test run-osd2_test
 */
#include <stdio.h>
#include <string.h>

#include "hardware.h"
#include "osd2.h"
#include "mock_hw.h"

static int fails, cases;
static void check(const char *what, long got, long want)
{
	cases++;
	if (got != want) {
		printf("FAIL %s: got %ld, want %ld\n", what, got, want);
		fails++;
	} else
		printf("ok   %s = %ld\n", what, got);
}
static void check_str(const char *what, const char *got, const char *want)
{
	cases++;
	if (strcmp(got, want)) {
		printf("FAIL %s:\n  got  \"%s\"\n  want \"%s\"\n", what, got, want);
		fails++;
	} else
		printf("ok   %s\n", what);
}

/* the expected trace, built frame by frame */
static char want[65536];
static void want_reset(void) { want[0] = 0; }
static void want_frame(const unsigned char *b, size_t n)
{
	char *p = want + strlen(want);
	p += sprintf(p, "20");
	for (size_t i = 0; i < n; i++) p += sprintf(p, " %02x", b[i]);
	p += sprintf(p, " /");
	for (size_t i = 0; i < n; i++) p += sprintf(p, " ff");
	sprintf(p, "\n");
}
#define FRAME(...) do { static const unsigned char f_[] = { __VA_ARGS__ }; want_frame(f_, sizeof f_); } while (0)

/* a fresh driver after osd2_init(attr), trace emptied, everything flushed */
static void fresh(unsigned char attr)
{
	mock_reset();
	osd2_init(attr);
	osd2_flush();
	mock_reset();
}

static unsigned char rowtxt[OSD2_COLS + 1];
static const char *row_text(unsigned r, unsigned c, unsigned n)
{
	memcpy(rowtxt, &osd2_chr[r][c], n);
	rowtxt[n] = 0;
	return (const char *)rowtxt;
}

int main(void)
{
	unsigned char v[4];
	unsigned n;

	/* ---- detection: bytes 10..13 behind the 0xA4 magic of byte 4 ---- */
	v[0] = 0xB5; v[1] = 1; v[2] = 64; v[3] = 32;
	check("detect: B5 01 40 20", osd2_detect(1, v), 1);
	check("detect: osd2_caps", osd2_caps, 1);
	check("detect: no 0xA4 in byte 4", osd2_detect(0, v), 0);
	v[0] = 0x1B; v[1] = 0x1B; v[2] = 0x1B; v[3] = 0x1B;    /* an old core: MINION_VER */
	check("detect: MINION_VER bytes", osd2_detect(1, v), 0);
	v[0] = 0xB5; v[1] = 0; v[2] = 64; v[3] = 32;
	check("detect: version 0", osd2_detect(1, v), 0);
	v[1] = 2; v[2] = 80;
	check("detect: another grid", osd2_detect(1, v), 0);
	v[2] = 64;
	check("detect: version 2", osd2_detect(1, v), 2);

	/* ---- init: the whole palette, then the window off ---- */
	mock_reset();
	osd2_init(OSD2_ATTR(OSD2_C_WHITE, OSD2_C_BLACK));
	want_reset();
	/* the eight menu colours (7 transparent: mode 2), 8-15 black */
	FRAME(0x4c, 0x00,
	      0x00, 0x00, 0x00, 0x00,  0x00, 0xf0, 0xf0, 0xf0,  0x00, 0x14, 0x78, 0xe6,  0x00, 0x3c, 0x5a, 0x9a,
	      0x00, 0xf0, 0xc8, 0x28,  0x00, 0x3c, 0xc8, 0x5a,  0x00, 0xe0, 0x3c, 0x3c,  0x80, 0x00, 0x00, 0x00,
	      0x00, 0x00, 0x00, 0x00,  0x00, 0x00, 0x00, 0x00,  0x00, 0x00, 0x00, 0x00,  0x00, 0x00, 0x00, 0x00,
	      0x00, 0x00, 0x00, 0x00,  0x00, 0x00, 0x00, 0x00,  0x00, 0x00, 0x00, 0x00,  0x00, 0x00, 0x00, 0x00);
	FRAME(0x5c, 0x00, 0x00, 0x00, 0x00, 0x00);
	check_str("init: palette (0x4C, 16 entries) and window off (0x5C)", mock_trace(), want);

	/* ---- the first flush: every row, pairs, 64 cells ---- */
	mock_reset();
	n = osd2_flush();
	check("init flush: bytes", n, 32 * (4 + 128));
	check("init flush: frames", mock_frames(), 32);
	{
		const char *t = mock_trace();
		check_str("init flush: row 0 header", strncmp(t, "20 2c 00 00 00 20 01 20 01", 26) ? "no" : "yes", "yes");
		const char *last = strstr(t, "20 2c 00 07 c0 ");
		check_str("init flush: row 31 at cell 0x7C0", last ? "yes" : "no", "yes");
	}
	mock_reset();
	check("clean flush: bytes", osd2_flush(), 0);
	check("clean flush: frames", mock_frames(), 0);

	/* ---- the three modes ---- */
	fresh(0x12);
	osd2_put(2, 5, "AB", 0x21);                    /* chars and attrs change: pairs */
	want_reset();
	FRAME(0x2c, 0x00, 0x00, 0x85, 'A', 0x21, 'B', 0x21);
	check("pairs: bytes", osd2_flush(), 8);
	check_str("pairs: row 2 col 5 (cell 0x085)", mock_trace(), want);

	mock_reset();
	osd2_attr(2, 5, 2, 0x33);                      /* attrs only */
	want_reset();
	FRAME(0x2c, 0x02, 0x00, 0x85, 0x33, 0x33);
	osd2_flush();
	check_str("attrs only: mode 2", mock_trace(), want);

	mock_reset();
	osd2_put(2, 5, "XY", 0x33);                    /* same attrs, new chars: chars only */
	want_reset();
	FRAME(0x2c, 0x01, 0x00, 0x85, 'X', 'Y');
	osd2_flush();
	check_str("chars only: mode 1", mock_trace(), want);

	mock_reset();
	osd2_put(2, 5, "XY", 0x33);                    /* nothing changes */
	osd2_attr(2, 5, 2, 0x33);
	check("unchanged redraw: bytes", osd2_flush(), 0);
	check("unchanged redraw: frames", mock_frames(), 0);

	/* one run per row over the changed span, the cells between included */
	fresh(0x12);
	osd2_put(20, 10, "Q", 0x12);                   /* char only, col 10 */
	osd2_attr(20, 3, 1, 0x7f);                     /* attr only, col 3 */
	want_reset();
	FRAME(0x2c, 0x00, 0x05, 0x03,                  /* cell 20 * 64 + 3 = 0x503 */
	      ' ', 0x7f, ' ', 0x12, ' ', 0x12, ' ', 0x12, ' ', 0x12, ' ', 0x12, ' ', 0x12, 'Q', 0x12);
	osd2_flush();
	check_str("span: cols 3..10 of row 20, pairs", mock_trace(), want);

	/* two rows: two frames, in row order */
	mock_reset();
	osd2_put(31, 63, "z", 0x12);
	osd2_put(0, 0, "a", 0x12);
	want_reset();
	FRAME(0x2c, 0x01, 0x00, 0x00, 'a');
	FRAME(0x2c, 0x01, 0x07, 0xff, 'z');
	osd2_flush();
	check_str("two rows: row 0 then row 31 (cell 0x7FF)", mock_trace(), want);

	/* ---- clipping ---- */
	fresh(0x12);
	osd2_put(4, 62, "ABCD", 0x12);
	osd2_put(32, 0, "nope", 0x12);
	osd2_fill(40, 0, 5, 'x', 0x12);
	osd2_attr(99, 0, 5, 0x55);
	want_reset();
	FRAME(0x2c, 0x01, 0x01, 0x3e, 'A', 'B');
	osd2_flush();
	check_str("clip: cols 62, 63 only; rows >= 32 ignored", mock_trace(), want);

	/* ---- putn, fill, clear_rows, box (shadow) ---- */
	fresh(0x12);
	osd2_putn(1, 0, 6, "abcdefgh", 0x34);
	check_str("putn: 6 of 8", row_text(1, 0, 7), "abcdef ");
	osd2_putn(1, 0, 6, "ab", 0x34);
	check_str("putn: 2 then spaces", row_text(1, 0, 6), "ab    ");
	osd2_fill(3, 60, 10, '#', 0x56);
	check_str("fill: clipped at col 63", row_text(3, 58, 6), "  ####");
	check("fill: attr", osd2_atr[3][63], 0x56);
	osd2_box(5, 2, 7, 6, 0x78);
	check_str("box: top", row_text(5, 2, 5), "+---+");
	check_str("box: side", row_text(6, 2, 5), "|   |");
	check_str("box: bottom", row_text(7, 2, 5), "+---+");
	check("box: attr", osd2_atr[6][6], 0x78);
	check("box: inside untouched", osd2_atr[6][3], 0x12);
	osd2_clear_rows(5, 7, '.', 0x9a);
	check_str("clear_rows", row_text(6, 0, 4), "....");
	check("clear_rows: row 8 untouched", osd2_chr[8][0], ' ');

	/* ---- wrap ---- */
	fresh(0x12);
	n = osd2_wrap(10, 40, 10, 4, "The quick brown fox jumps", 0x21);
	check("wrap: lines needed", n, 3);
	check_str("wrap: line 1", row_text(10, 40, 10), "The quick ");
	check_str("wrap: line 2", row_text(11, 40, 10), "brown fox ");
	check_str("wrap: line 3", row_text(12, 40, 10), "jumps     ");
	check_str("wrap: line 4 blank", row_text(13, 40, 10), "          ");
	check_str("wrap: col 50 untouched", row_text(10, 50, 1), " ");
	n = osd2_wrap(10, 40, 5, 3, "abcdefghijklmnopq", 0x21);
	check("wrap: long word, lines needed", n, 4);
	check_str("wrap: cut 1", row_text(10, 40, 5), "abcde");
	check_str("wrap: cut 3", row_text(12, 40, 5), "klmno");
	check_str("wrap: line 4 not drawn", row_text(13, 40, 5), "     ");
	n = osd2_wrap(20, 0, 8, 4, "one\n\ntwo   three", 0x21);
	check("wrap: hard breaks, lines", n, 4);
	check_str("wrap: hard 1", row_text(20, 0, 8), "one     ");
	check_str("wrap: hard 2 empty", row_text(21, 0, 8), "        ");
	check_str("wrap: spaces eaten", row_text(22, 0, 8), "two     ");
	check_str("wrap: next word", row_text(23, 0, 8), "three   ");
	n = osd2_wrap(20, 0, 8, 2, "", 0x21);
	check("wrap: empty", n, 0);
	check_str("wrap: empty blanks the area", row_text(20, 0, 8), "        ");

	/* ---- palette and window ---- */
	fresh(0x12);
	osd2_pal(5, OSD2_BLEND, 0x123456);
	osd2_commit(1, 2, 16, 5, 64, 20);
	want_reset();
	FRAME(0x4c, 0x05, 0xc0, 0x12, 0x34, 0x56);
	FRAME(0x5c, 0x03, 0x10, 0x05, 0x40, 0x14);
	check_str("commit: entry 5 blend, window scale 2 at (16, 5) 64 x 20", mock_trace(), want);
	mock_reset();
	osd2_pal(5, OSD2_BLEND, 0x123456);              /* unchanged: not resent */
	osd2_commit(1, 1, 0, 0, 1, 1);
	want_reset();
	FRAME(0x5c, 0x01, 0x00, 0x00, 0x01, 0x01);
	check_str("commit: unchanged entry not resent, scale 1", mock_trace(), want);
	mock_reset();
	osd2_pal(7, OSD2_VIDEO, 0x000001);
	osd2_pal(3, OSD2_DIM, 0xFFFFFF);
	osd2_commit(1, 2, 16, 5, 64, 20);
	want_reset();
	FRAME(0x4c, 0x03,
	      0x40, 0xff, 0xff, 0xff,  0x00, 0xf0, 0xc8, 0x28,  0xc0, 0x12, 0x34, 0x56,
	      0x00, 0xe0, 0x3c, 0x3c,  0x80, 0x00, 0x00, 0x01);
	FRAME(0x5c, 0x03, 0x10, 0x05, 0x40, 0x14);
	check_str("commit: entries 3..7 as one run", mock_trace(), want);
	mock_reset();
	osd2_disable();
	want_reset();
	FRAME(0x5c, 0x02, 0x10, 0x05, 0x40, 0x14);
	check_str("disable: enable bit cleared, geometry kept", mock_trace(), want);
	mock_reset();
	osd2_pal(16, OSD2_OPAQUE, 0);
	osd2_commit(0, 1, 0, 0, 0, 0);
	want_reset();
	FRAME(0x5c, 0x00, 0x00, 0x00, 0x00, 0x00);
	check_str("pal: entry 16 ignored", mock_trace(), want);

	/* ---- font ---- */
	{
		unsigned char g[32];
		for (unsigned i = 0; i < 32; i++) g[i] = (unsigned char)(i * 7 + 1);
		mock_reset();
		osd2_font(0x80, 1, g);
		osd2_font(0xff, 1, g + 16);
		want_reset();
		FRAME(0x3c, 0x08, 0x00, 0x01, 0x08, 0x0f, 0x16, 0x1d, 0x24, 0x2b, 0x32,
		      0x39, 0x40, 0x47, 0x4e, 0x55, 0x5c, 0x63, 0x6a);
		FRAME(0x3c, 0x0f, 0xf0, 0x71, 0x78, 0x7f, 0x86, 0x8d, 0x94, 0x9b, 0xa2,
		      0xa9, 0xb0, 0xb7, 0xbe, 0xc5, 0xcc, 0xd3, 0xda);
		check_str("font: glyph 0x80 at 0x800, glyph 0xFF at 0xFF0", mock_trace(), want);
	}

	/* ---- invalidate: everything again ---- */
	fresh(0x12);
	osd2_invalidate();
	check("invalidate: bytes", osd2_flush(), 32 * (4 + 128));

	printf("%s: %d cases, %d failed\n", fails ? "FAIL osd2_test" : "osd2_test passed", cases, fails);
	return fails ? 1 : 0;
}

#ifndef OSD2_H
#define OSD2_H

/*
 * osd2: the driver of the OSD's native 720p text layer
 * (rtl/openaars/adv7511/osd_text.v, written through userio_osd.v;
 * findings/osd-redesign/plan.md 3.2-3.5, 4.1, 5).
 *
 * The layer shows a window of character cells, 8x16 pixels each (16x32 at
 * scale 2), anywhere on the 1280x720 raster, over the picture after the CRT
 * effects.  Cell RAM: 64 columns x 32 rows (stride 64), cell = {attr, char};
 * attr[3:0] the foreground, attr[7:4] the background palette index.  Palette:
 * 16 entries {mode, r, g, b}; mode 0 opaque, 1 the video dimmed, 2 the video
 * unchanged, 3 50/50 colour and video.
 *
 * The driver keeps a shadow of the whole cell RAM in bss (never on the
 * stack: the stack has ~1.3 KB spare).  The drawing calls change the shadow
 * only and mark what changed; osd2_flush() sends the changed cells of each
 * row as one 0x2C run (char,attr pairs, chars only or attrs only, whichever
 * covers the change).  A call that writes what the shadow already holds
 * marks nothing, so redrawing a page every main-loop pass costs no SPI
 * traffic.  Palette and window go out together at osd2_commit() (0x4C, then
 * 0x5C): the layer copies them to its live registers at its next frame, so
 * they never tear.
 *
 * Rows and columns are cell coordinates (0..OSD2_ROWS-1, 0..OSD2_COLS-1);
 * anything outside is clipped.  Nothing here touches the legacy bitmap OSD.
 *
 * SPI commands (userio_osd.v, the OSD chip select):
 *   0x2C TXT_WR   mode (0 pairs, 1 chars, 2 attrs), cell[10:8], cell[7:0], data...
 *   0x3C FONT_WR  adr[11:8], adr[7:0], bytes...   (glyph n row r at n*16 + r)
 *   0x4C PAL_WR   first entry, then {mode << 6, r, g, b} per entry
 *   0x5C TXT_CFG  ctrl {bit 0 enable, bit 1 scale 2}, x0/8, y0/8, cols, rows
 *                 (the fifth byte commits palette and window)
 *   0x88 VERSION  reply bytes 10..13: 0xB5, layer version, 64, 32;
 *                 layer version >= 2 (OSD2_V_STATUS): byte 14 the status
 *                 {bit 0 the RTG screen is on}, and the RTG screen has its
 *                 own Video Pos register (hardware.h VIDEOSCALE_RTG)
 */

#define OSD2_COLS 64          /* the cell RAM's stride and width */
#define OSD2_ROWS 32

/* VERSION reply byte 10 of a core with the layer */
#define OSD2_MAGIC 0xB5
/* the layer version (byte 11) from which byte 14 is the status byte and the
   RTG Video Pos register exists.  A version-1 core (the bitstream of
   2026-10-27) answers MINION_VER at byte 14 and decodes every address of
   0xFFFFFF5x as the PAL position: neither is used below this version. */
#define OSD2_V_STATUS 2
#define OSD2_ST_RTG   0x01    /* status bit 0: the RTG screen is on */

/* SPI command bytes */
#define OSD2_CMD_TXT  0x2C
#define OSD2_CMD_FONT 0x3C
#define OSD2_CMD_PAL  0x4C
#define OSD2_CMD_CFG  0x5C

/* 0x2C modes */
#define OSD2_TXT_PAIRS 0
#define OSD2_TXT_CHARS 1
#define OSD2_TXT_ATTRS 2

/* palette modes */
#define OSD2_OPAQUE 0
#define OSD2_DIM    1         /* the video >> 1 */
#define OSD2_VIDEO  2         /* the video as it is (transparent) */
#define OSD2_BLEND  3         /* (colour + video) / 2 */

/* the menu's eight colours (Paul, 2026-10-27: black, white, blue, dark blue,
   yellow, green, red, transparent), as loaded by osd2_pal_default().
   Black, white and blue carry the menu; yellow, green and red are accents
   (icons, toasts, errors).  Entries 8-15 are free (loaded black): the
   About/Supporters effects cycle them. */
enum {
	OSD2_C_BLACK = 0,     /* the background */
	OSD2_C_WHITE,         /* 0xF0F0F0 text */
	OSD2_C_BLUE,          /* 0x1478E6 the selection bar, headers */
	OSD2_C_DKBLUE,        /* 0x3C5A9A the help field, bar tracks, greyed text */
	OSD2_C_YELLOW,        /* 0xF0C828 */
	OSD2_C_GREEN,         /* 0x3CC85A */
	OSD2_C_RED,           /* 0xE03C3C errors, the dialog frame */
	OSD2_C_CLEAR,         /* transparent: the video unchanged (OSD2_VIDEO) */
	OSD2_C_FREE           /* 8..15: free */
};

/* a cell attribute from foreground and background palette indices */
#define OSD2_ATTR(fg, bg) ((unsigned char)((((bg) & 15) << 4) | ((fg) & 15)))

/* box drawing (osd2_box): ASCII until the font has box glyphs (plan Phase 5) */
#define OSD2_BOX_H      '-'
#define OSD2_BOX_V      '|'
#define OSD2_BOX_CORNER '+'

/* 0: the core has no text layer (or predates the question): use the legacy
   OSD.  Otherwise the layer's version (VERSION reply byte 11). */
extern unsigned char osd2_caps;

/* the shadow of the cell RAM, [row][col]; read only outside osd2.c (the
   host tests compare it against golden screens) */
extern unsigned char osd2_chr[OSD2_ROWS][OSD2_COLS];
extern unsigned char osd2_atr[OSD2_ROWS][OSD2_COLS];

/* VERSION reply bytes 10..13 (fpga.c reads them), magic_a4: byte 4 was 0xA4
   (the core answers the extended reply at all).  Sets osd2_caps; returns it. */
unsigned char osd2_detect(int magic_a4, const unsigned char v[4]);

/* the shadow to spaces in `attr`, every row marked: the next flush writes the
   whole cell RAM; the window off.  Called once the layer is detected. */
void osd2_init(unsigned char attr);

/* drawing into the shadow (clipped; marks only cells that change) */
void osd2_put(unsigned row, unsigned col, const char *text, unsigned char attr);
/* at most n characters of text, the rest of the n cells spaces */
void osd2_putn(unsigned row, unsigned col, unsigned n, const char *text, unsigned char attr);
void osd2_fill(unsigned row, unsigned col, unsigned n, unsigned char ch, unsigned char attr);
void osd2_attr(unsigned row, unsigned col, unsigned n, unsigned char attr);
/* one cell's char (row, col in range: not clipped), marked if it changes;
   the attribute kept.  The effects' fast path (ui_about.c's stars). */
void osd2_char(unsigned row, unsigned col, unsigned char ch);
/* a frame from (r0, c0) to (r1, c1) inclusive, inside untouched */
void osd2_box(unsigned r0, unsigned c0, unsigned r1, unsigned c1, unsigned char attr);
/* every cell of rows r0..r1 to ch / attr */
void osd2_clear_rows(unsigned r0, unsigned r1, unsigned char ch, unsigned char attr);
/* text word-wrapped into `lines` rows of `width` cells from (row, col):
   breaks at spaces and '\n', a word longer than width is cut; every row of
   the area is written (padded with spaces).  Returns the rows the whole text
   needs (may exceed lines: the rest is not shown). */
unsigned osd2_wrap(unsigned row, unsigned col, unsigned width, unsigned lines,
                   const char *text, unsigned char attr);

/* the marked cells to the cell RAM; returns the SPI bytes sent */
unsigned osd2_flush(void);
/* mark everything (the cell RAM's content is unknown, e.g. after a reset) */
void osd2_invalidate(void);

/* palette entry i (0..15) into the shadow palette; sent at the next commit */
void osd2_pal(unsigned i, unsigned mode, unsigned long rgb);
/* the scheme of the enum above */
void osd2_pal_default(void);
/* the changed palette entries (0x4C), then the window (0x5C): enable,
   scale 1 or 2, top left (x0, y0) in 8-pixel units, cols x rows cells;
   live from the layer's next frame */
void osd2_commit(int enable, int scale, unsigned x0, unsigned y0, unsigned cols, unsigned rows);
/* the window off (geometry kept) */
void osd2_disable(void);
/* n glyphs from glyph `first`, 16 bytes each (row-major, bit 7 = left) */
void osd2_font(unsigned first, unsigned n, const unsigned char *data);

/* 1: the RTG screen is on now (VERSION byte 14, one SPI transaction of 15
   bytes; it reads byte 9 too, which clears the input diagnostic's sticky
   half: nothing in this firmware reads it).  0 on a core below
   OSD2_V_STATUS, without asking. */
unsigned char osd2_rtg_active(void);

#endif

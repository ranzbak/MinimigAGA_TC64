#ifndef OSD_ICONS_H
#define OSD_ICONS_H

/*
 * osd_icons: the glyphs the new OSD menu (ui.c) uploads into the text
 * layer's font RAM (osd2_font) when it opens; findings/osd-redesign/plan.md
 * 3.3 (glyph map: 0x00-0x1F symbols and lines, 0xC0-0xFF icons) and 3.10.
 * Bitmaps are 1 bpp, bit 7 (icons: bit 15) = the left pixel, 16 rows; on
 * screen at scale 2 a glyph is 16 x 32 pixels.  The ROM font (font8x16.h,
 * osd_font.mem) is made from this file too (tools/mkfontmem.py, make check
 * (l)): it holds these same glyphs at these codes, so the upload changes
 * nothing on a core whose font RAM starts from today's osd_font.mem and
 * puts them in place on one with an older font.  The classic menu draws with
 * charrom.h on the bitmap OSD and never sees this font, the debug page on
 * the layer uses ASCII only.  From the ROM font (font/symbols.txt): 0x17 the
 * padlock, 0x19 the note (value texts).
 *
 * Glyph map of the menu:
 *   0x04-0x0C  the value bar: OSD_G_BAR0 + k = k/8 of the cell filled from
 *              the left, rows 3-12 (computed at upload, ui.c ui_glyphs);
 *              drawn white on dark blue, the empty part is the track:
 *                k = 3:  rows 0-2   ........
 *                        rows 3-12  ###.....
 *                        rows 13-15 ........
 *   0x0D-0x0F, 0x1A-0x1D  lines: horizontal, vertical, the vertical with a
 *              branch to the right, the four box corners
 *   0x10, 0x11 the change arrows (left, right); 0x16 the submenu arrow
 *   0xC0-0xC9  the five category icons, two glyphs each (16 x 16 pixels):
 *              OSD_ICON_MAIN + 2 * category, left glyph then right glyph
 */

#define OSD_G_BAR0   0x04
#define OSD_G_BARS   9        /* 0/8 .. 8/8 */
#define OSD_G_LEFT    0x10
#define OSD_G_RIGHT   0x11
#define OSD_G_SUB     0x16
#define OSD_G_HLINE   0x0D
#define OSD_G_VLINE   0x0E
#define OSD_G_TEE_R   0x0F
#define OSD_G_TL      0x1A
#define OSD_G_TR      0x1B
#define OSD_G_BL      0x1C
#define OSD_G_BR      0x1D
#define OSD_ICON_MAIN 0xC0      /* .. 0xC9: Main, Storage, System, Video, Acceleration */

/* the line, corner and arrow glyphs, uploaded one by one: {code, 16 rows} */
struct osd_glyph { unsigned char code, rows[16]; };

static const struct osd_glyph osd_glyphs[] = {
	/* 0x10 OSD_G_LEFT: the change arrow, left (Left/Right change the value) */
	{ 0x10, {
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x0C,   /* ....##.. */
		0x1C,   /* ...###.. */
		0x3C,   /* ..####.. */
		0x7C,   /* .#####.. */
		0x7C,   /* .#####.. */
		0x3C,   /* ..####.. */
		0x1C,   /* ...###.. */
		0x0C,   /* ....##.. */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
	} },
	/* 0x11 OSD_G_RIGHT: the change arrow, right */
	{ 0x11, {
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x30,   /* ..##.... */
		0x38,   /* ..###... */
		0x3C,   /* ..####.. */
		0x3E,   /* ..#####. */
		0x3E,   /* ..#####. */
		0x3C,   /* ..####.. */
		0x38,   /* ..###... */
		0x30,   /* ..##.... */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
	} },
	/* 0x16 OSD_G_SUB: the submenu arrow (the item opens something) */
	{ 0x16, {
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x60,   /* .##..... */
		0x70,   /* .###.... */
		0x38,   /* ..###... */
		0x1C,   /* ...###.. */
		0x1C,   /* ...###.. */
		0x38,   /* ..###... */
		0x70,   /* .###.... */
		0x60,   /* .##..... */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
	} },
	/* 0x0D OSD_G_HLINE: a horizontal line */
	{ 0x0D, {
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0xFF,   /* ######## */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
	} },
	/* 0x0E OSD_G_VLINE: a vertical line */
	{ 0x0E, {
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
	} },
	/* 0x0F OSD_G_TEE_R: the vertical line with a branch to the right */
	{ 0x0F, {
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x1F,   /* ...##### */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
	} },
	/* 0x1A OSD_G_TL: a box corner, top left */
	{ 0x1A, {
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x1F,   /* ...##### */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
	} },
	/* 0x1B OSD_G_TR: a box corner, top right */
	{ 0x1B, {
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0xF0,   /* ####.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
	} },
	/* 0x1C OSD_G_BL: a box corner, bottom left */
	{ 0x1C, {
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x1F,   /* ...##### */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
	} },
	/* 0x1D OSD_G_BR: a box corner, bottom right */
	{ 0x1D, {
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0x10,   /* ...#.... */
		0xF0,   /* ####.... */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
		0x00,   /* ........ */
	} },
};

/* the category icons, 16 x 16, bit 15 = the left pixel: the left glyph is
   the high byte of each row, the right glyph the low byte (ui.c splits them) */
static const unsigned short osd_icons[5][16] = {
	/* OSD_ICON_MAIN + 0: Main: a house (drawn yellow) */
	{
		0x0000,   /* ................ */
		0x0180,   /* .......##....... */
		0x03C0,   /* ......####...... */
		0x07E0,   /* .....######..... */
		0x0E70,   /* ....###..###.... */
		0x1C38,   /* ...###....###... */
		0x381C,   /* ..###......###.. */
		0x700E,   /* .###........###. */
		0xF00F,   /* ####........#### */
		0x300C,   /* ..##........##.. */
		0x33CC,   /* ..##..####..##.. */
		0x33CC,   /* ..##..####..##.. */
		0x33CC,   /* ..##..####..##.. */
		0x33CC,   /* ..##..####..##.. */
		0x3FFC,   /* ..############.. */
		0x0000,   /* ................ */
	},
	/* OSD_ICON_MAIN + 2: Storage: a 3.5" floppy disk (drawn white) */
	{
		0xFFFC,   /* ##############.. */
		0xCF36,   /* ##..####..##.##. */
		0xCF33,   /* ##..####..##..## */
		0xCF33,   /* ##..####..##..## */
		0xCF33,   /* ##..####..##..## */
		0xCFF3,   /* ##..########..## */
		0xC003,   /* ##............## */
		0xC003,   /* ##............## */
		0xDFFB,   /* ##.##########.## */
		0xD00B,   /* ##.#........#.## */
		0xD00B,   /* ##.#........#.## */
		0xD00B,   /* ##.#........#.## */
		0xD00B,   /* ##.#........#.## */
		0xD00B,   /* ##.#........#.## */
		0xFFFF,   /* ################ */
		0x0000,   /* ................ */
	},
	/* OSD_ICON_MAIN + 4: System: a chip (drawn green) */
	{
		0x0000,   /* ................ */
		0x0A50,   /* ....#.#..#.#.... */
		0x0A50,   /* ....#.#..#.#.... */
		0x1FF8,   /* ...##########... */
		0x7FFE,   /* .##############. */
		0x19F8,   /* ...##..######... */
		0x79FE,   /* .####..########. */
		0x1FF8,   /* ...##########... */
		0x1FF8,   /* ...##########... */
		0x7FFE,   /* .##############. */
		0x1FF8,   /* ...##########... */
		0x7FFE,   /* .##############. */
		0x1FF8,   /* ...##########... */
		0x0A50,   /* ....#.#..#.#.... */
		0x0A50,   /* ....#.#..#.#.... */
		0x0000,   /* ................ */
	},
	/* OSD_ICON_MAIN + 6: Video: a monitor (drawn white) */
	{
		0x0000,   /* ................ */
		0xFFFF,   /* ################ */
		0xC003,   /* ##............## */
		0xD803,   /* ##.##.........## */
		0xD003,   /* ##.#..........## */
		0xC003,   /* ##............## */
		0xC003,   /* ##............## */
		0xC003,   /* ##............## */
		0xC003,   /* ##............## */
		0xFFFF,   /* ################ */
		0xFFFF,   /* ################ */
		0x03C0,   /* ......####...... */
		0x03C0,   /* ......####...... */
		0x1FF8,   /* ...##########... */
		0x1FF8,   /* ...##########... */
		0x0000,   /* ................ */
	},
	/* OSD_ICON_MAIN + 8: Acceleration: a lightning bolt (drawn red) */
	{
		0x0000,   /* ................ */
		0x00FE,   /* ........#######. */
		0x01FC,   /* .......#######.. */
		0x03F8,   /* ......#######... */
		0x07F0,   /* .....#######.... */
		0x0FE0,   /* ....#######..... */
		0x1FFE,   /* ...############. */
		0x3FFC,   /* ..############.. */
		0x00F8,   /* ........#####... */
		0x01F0,   /* .......#####.... */
		0x03E0,   /* ......#####..... */
		0x0780,   /* .....####....... */
		0x0E00,   /* ....###......... */
		0x1800,   /* ...##........... */
		0x2000,   /* ..#............. */
		0x0000,   /* ................ */
	},
};

#endif

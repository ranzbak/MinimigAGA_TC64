/* Host test of the boot ROM's lock-step check (../lockstep.c, design 5.5,
   findings/osd-redesign/plan.md 3.12): fw_start() against a mock VERSION
   register and a mock OSD (its OSD_CMD_VERSION reply: a core with the text
   layer version 2, version 1, or none), with the boot ROM's own
   small_printf (both compiled with -Dputchar=rv_putchar: the UART text is
   captured here byte for byte, as the boot ROM prints it).

   usage: lockstep_test <osd_font.mem> [<firmware file>]
                         (test/Makefile: the text layer's power-up font,
                         rtl/openaars/adv7511/osd_font.mem; FWBIN, fw/ctrl's
                         build output, fw/ctrl/fwname.mk)
     the in-memory cases below, the mismatch message's glyphs not blank in
     the font;
     a file: also that file (fw/ctrl's build, trailer appended by its
             Makefile) must boot with VERSION = SDC_VERSION on a core with
             the text layer OSD2_REQUIRED (its trailer bytes 4-5) and stop
             with VERSION = SDC_VERSION + 1, and on a core with the layer one
             version older (or none)
   Exit status 0 = pass. */
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../lockstep.h"
#include "../../ctrl/sdc.h"
static unsigned mock_version;
static char out[512];
static unsigned outn;
static int codes[8], ncodes, booted, halted, fails;
static jmp_buf env;

/* the core's OSD_CMD_VERSION reply bytes 10 and 11 (the text layer) */
enum core { LAYER2, LAYER1, NOLAYER, LAYER3 };
static const char *const core_name[] = { "layer 2", "layer 1", "no layer", "layer 3" };
static enum core mock_core;
static unsigned core_layer(enum core c) { return c == NOLAYER ? 0 : c == LAYER1 ? 1 : c == LAYER3 ? 3 : 2; }

/* cfide's SPI as lockstep.c drives the OSD: the frames (bytes between a
   select and a deselect) */
#define NF 6
static unsigned char osd[NF][128];
static unsigned osdlen[NF], nframes, sel, bad_osd, frames_at_err;
void hosttest_osd(int what, unsigned char b)
{
	switch (what) {
	case 0: if (sel) bad_osd++; sel = 1; if (nframes < NF) osdlen[nframes] = 0; break;
	case 1: if (!sel) bad_osd++; sel = 0; nframes++; break;
	case 2: if (!sel) bad_osd++;
		else if (nframes < NF && osdlen[nframes] < sizeof osd[0]) osd[nframes][osdlen[nframes]++] = b;
		break;
	}
}
/* a reply byte: 0xff out, in the reply to the frame's command so far (the
   VERSION reply as userio_osd.v gives it: byte k of the reply to data byte
   k; bytes 10 and 11 the text layer, MINION_VER 0x1B without it) */
unsigned char hosttest_osd_rx(void)
{
	unsigned k = nframes < NF && osdlen[nframes] ? osdlen[nframes] - 1 : 99;
	static const unsigned char v[10] = { 1, 26, 10, 0x1b, 0xa4, 0x7d, 0, 0, 0, 0 };
	hosttest_osd(2, 0xff);
	if (!sel || nframes >= NF || osd[nframes][0] != 0x88)
		return 0x00;
	if (k < 10)
		return v[k];
	if (k == 10)
		return mock_core == NOLAYER ? 0x1b : 0xb5;
	if (k == 11)
		return mock_core == NOLAYER ? 0x1b : (unsigned char)core_layer(mock_core);
	return 0x1b;
}
void osd_cmd(unsigned char cmd, unsigned char v)	/* boot.c's */
{
	hosttest_osd(0, 0);
	hosttest_osd(2, cmd);
	hosttest_osd(2, v);
	hosttest_osd(1, 0);
}

/* frame 0, on every run: the VERSION read, 88 and 12 reply bytes (bytes
   10 and 11: the layer) */
static int ver_ok(char *why, size_t n)
{
	static const unsigned char want[13] = { 0x88, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	                                        0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
	if (bad_osd || sel) { snprintf(why, n, "select / deselect out of order"); return 0; }
	if (nframes < 1 || osdlen[0] != 13 || memcmp(osd[0], want, 13)) {
		snprintf(why, n, "frame 1 is not the VERSION read 88 + 12 x ff");
		return 0;
	}
	return 1;
}

/* the mismatch's OSD after the VERSION read: the palette (entry 0 red,
   1 white, opaque), "FIRMWARE MISMATCH" in cells 0..16 (pairs, attr 01),
   the 17 x 1 window at scale 2, centred (x0 63, y0 43); ErrorCode after
   all four frames */
static int osd_ok(char *why, size_t n)
{
	static const char text[] = "FIRMWARE MISMATCH";
	static const unsigned char pal[] = { 0x4c, 0x00, 0x00, 0xe0, 0x3c, 0x3c, 0x00, 0xf0, 0xf0, 0xf0 };
	static const unsigned char cfg[] = { 0x5c, 0x03, 63, 43, 17, 1 };
	unsigned i;
	if (!ver_ok(why, n)) return 0;
	if (nframes != 4) { snprintf(why, n, "%u OSD frames, want 4", nframes); return 0; }
	if (osdlen[1] != sizeof pal || memcmp(osd[1], pal, sizeof pal)) { snprintf(why, n, "frame 2 is not the palette 4c 00 {00 e0 3c 3c} {00 f0 f0 f0}"); return 0; }
	if (osdlen[2] != 4 + 2 * (sizeof text - 1) || memcmp(osd[2], "\x2c\0\0\0", 4)) { snprintf(why, n, "frame 3: %u bytes, not 2c 00 00 00 + 17 pairs", osdlen[2]); return 0; }
	for (i = 0; i < sizeof text - 1; i++)
		if (osd[2][4 + 2 * i] != (unsigned char)text[i] || osd[2][5 + 2 * i] != 0x01) {
			snprintf(why, n, "cell %u: %02x %02x, want '%c' 01", i, osd[2][4 + 2 * i], osd[2][5 + 2 * i], text[i]);
			return 0;
		}
	if (osdlen[3] != sizeof cfg || memcmp(osd[3], cfg, sizeof cfg)) { snprintf(why, n, "frame 4 is not the window 5c 03 3f 2b 11 01"); return 0; }
	if (frames_at_err != 4) { snprintf(why, n, "ErrorCode(0x0ff) after %u OSD frames, want after all four (the ROM's last access)", frames_at_err); return 0; }
	return 1;
}

/* sdc.h under HOSTTEST: SDC_R() reads come here */
unsigned short hosttest_sdc_rd(unsigned off)
{
	if (off != SDC_VER) {
		fprintf(stderr, "lockstep_test: unexpected register read at %02x\n", off);
		abort();
	}
	return (unsigned short)mock_version;
}

int rv_putchar(int c)
{
	if (outn < sizeof out - 1)
		out[outn++] = (char)c;
	out[outn] = 0;
	return c;
}

void _boot(void)
{
	booted++;
	longjmp(env, 1);
}

void ErrorCode(int code)
{
	if (ncodes < 8)
		codes[ncodes] = code;
	ncodes++;
	frames_at_err = nframes;	/* the OSD's frames before it (ErrorCode: the last access) */
}

void boot_halt(void)
{
	halted++;
	longjmp(env, 2);
}

/* run fw_start on img[0..size) with VERSION = ver on core c; boot = 1: it must jump */
static void runc(const char *name, const unsigned char *img, unsigned size, unsigned ver, enum core c, int boot)
{
	char want[128];
	int ok;
	char why[160] = "";

	mock_version = ver;
	mock_core = c;
	outn = 0;
	out[0] = 0;
	ncodes = booted = halted = 0;
	nframes = sel = bad_osd = frames_at_err = 0;
	if (setjmp(env) == 0) {
		fw_start(img, size);
		printf("FAIL %s: fw_start returned\n", name);
		fails++;
		return;
	}
	if (boot) {
		snprintf(want, sizeof want, "Firmware SDC %04X, bitstream SDC %04X\n", ver, ver);
		ok = booted == 1 && !halted && ncodes == 0 && !strcmp(out, want);
		if (!ver_ok(why, sizeof why)) ok = 0;
		else if (nframes != 1) { snprintf(why, sizeof why, "%u OSD frames on a boot, want the VERSION read only", nframes); ok = 0; }
	} else {
		snprintf(want, sizeof want, "Firmware does not match this bitstream (need SDC %04X, OSD layer <= %u)\n",
		         ver, core_layer(c));
		ok = !booted && halted == 1 && ncodes == 1 && codes[0] == 0x0ff && !strcmp(out, want);
		if (!osd_ok(why, sizeof why)) ok = 0;
	}
	if (ok)
		printf("PASS %s (%s)\n", name, core_name[c]);
	else {
		printf("FAIL %s (%s): booted %d, halted %d, ErrorCode calls %d (first %03x)%s%s\n"
		       "  UART got:  \"%s\"\n  UART want: \"%s\"\n",
		       name, core_name[c], booted, halted, ncodes, ncodes ? codes[0] : 0, why[0] ? "; OSD: " : "", why, out, want);
		fails++;
	}
}

/* the SDC cases, on a core with the layer */
static void run(const char *name, const unsigned char *img, unsigned size, unsigned ver, int boot)
{
	runc(name, img, size, ver, LAYER2, boot);
}

static unsigned char img[4096];

/* the trailer at img[end - 8 .. end) */
static void trailer(unsigned end, unsigned char b4, unsigned char b5, unsigned v)
{
	unsigned char *t = img + end - 8;
	t[0] = 'S'; t[1] = 'D'; t[2] = 'C'; t[3] = 'V';
	t[4] = b4; t[5] = b5; t[6] = (unsigned char)(v >> 8); t[7] = (unsigned char)v;
}

static void fill(void)
{
	unsigned i;
	for (i = 0; i < sizeof img; i++)
		img[i] = (unsigned char)(i * 37 + 11);
}

/* the message's glyphs in the text layer's power-up font (16 bytes a
   glyph, one hex byte a line): none blank but the space */
static void font_check(const char *path)
{
	static unsigned char font[4096];
	static const char text[] = "FIRMWARE MISMATCH";
	unsigned i, k, n = 0, v;
	FILE *f = fopen(path, "r");
	if (!f) { perror(path); exit(2); }
	while (n < sizeof font && fscanf(f, "%x", &v) == 1)
		font[n++] = (unsigned char)v;
	fclose(f);
	if (n != sizeof font) { printf("FAIL font %s: %u bytes, want 4096\n", path, n); fails++; return; }
	for (i = 0; i < sizeof text - 1; i++) {
		unsigned c = (unsigned char)text[i], ink = 0;
		for (k = 0; k < 16; k++)
			ink |= font[c * 16 + k];
		if (c != ' ' && !ink) { printf("FAIL font: glyph '%c' (0x%02x) is blank\n", c, c); fails++; return; }
	}
	printf("PASS the message's glyphs in %s\n", path);
}

int main(int argc, char **argv)
{
	static const enum core cores[] = { LAYER2, LAYER1, NOLAYER };
	unsigned i;

	if (argc < 2) { fprintf(stderr, "usage: lockstep_test <osd_font.mem> [<firmware file>]\n"); return 2; }
	font_check(argv[1]);

	fill();
	trailer(3000, 0, 0, 0x5D00);
	run("trailer 5D00, VERSION 5D01: mismatch", img, 3000, 0x5D01, 0);
	trailer(3000, 0, 0, 0x5C01);
	run("trailer 5C01, VERSION 5D01: mismatch (high byte)", img, 3000, 0x5D01, 0);
	trailer(3000, 0, 0, 0x5D01);
	run("trailer 5D01, VERSION 5D01: boots", img, 3000, 0x5D01, 1);
	run("trailer 5D01, VERSION 5D02: mismatch, need from the register", img, 3000, 0x5D02, 0);
	fill();
	run("no SDCV magic (firmware without a trailer): mismatch", img, 3000, 0x5D01, 0);
	trailer(3000, 0, 0, 0x5D01);
	img[2992 + 3] = 'W';
	run("magic SDCW: mismatch", img, 3000, 0x5D01, 0);
	/* the trailer is found from the file length, not at a fixed offset */
	fill();
	trailer(3000, 0, 0, 0x5D01);
	run("trailer 1 byte before the end (size 3001): mismatch", img, 3001, 0x5D01, 0);
	run("trailer past the end (size 2999): mismatch", img, 2999, 0x5D01, 0);
	fill();
	trailer(512, 0, 0, 0x5D01);
	run("a trailer inside the file, none at its end: mismatch", img, 3000, 0x5D01, 0);
	fill();
	trailer(1027, 0, 0, 0x5D01);
	run("odd length 1027 with its trailer: boots", img, 1027, 0x5D01, 1);
	trailer(8, 0, 0, 0x5D01);
	run("file of exactly the trailer (8 bytes): boots", img, 8, 0x5D01, 1);
	run("file of 7 bytes: mismatch", img + 1, 7, 0x5D01, 0);
	run("empty file: mismatch", img, 0, 0x5D01, 0);
	trailer(8, 0, 0, 0x0000);
	run("trailer 0000, VERSION 5D01: mismatch", img, 8, 0x5D01, 0);
	trailer(8, 0, 0, 0xFFFF);
	run("trailer FFFF, VERSION FFFF: boots (16 bits compared)", img, 8, 0xFFFF, 1);

	/* OSD2_REQUIRED (bytes 4-5) x the core's text layer: an old firmware
	   (00 00) boots on any core, a new one (00 02) only on a layer >= 2 */
	for (i = 0; i < sizeof cores / sizeof cores[0]; i++) {
		fill();
		trailer(3000, 0, 0, 0x5D02);
		runc("old firmware (OSD2_REQUIRED 0), SDC match: boots", img, 3000, 0x5D02, cores[i], 1);
		trailer(3000, 0, 2, 0x5D02);
		runc("new firmware (OSD2_REQUIRED 2), SDC match", img, 3000, 0x5D02, cores[i], cores[i] == LAYER2);
		runc("new firmware (OSD2_REQUIRED 2), SDC mismatch", img, 3000, 0x5D03, cores[i], 0);
	}
	trailer(3000, 0, 3, 0x5D02);
	runc("OSD2_REQUIRED 3 on layer 2: mismatch", img, 3000, 0x5D02, LAYER2, 0);
	runc("OSD2_REQUIRED 3 on layer 3: boots", img, 3000, 0x5D02, LAYER3, 1);
	trailer(3000, 1, 0, 0x5D02);
	runc("OSD2_REQUIRED 0x0100 (16 bits compared) on layer 3: mismatch", img, 3000, 0x5D02, LAYER3, 0);
	trailer(3000, 0, 1, 0x5D02);
	runc("OSD2_REQUIRED 1 on layer 1: boots", img, 3000, 0x5D02, LAYER1, 1);
	runc("OSD2_REQUIRED 1 without a layer: mismatch", img, 3000, 0x5D02, NOLAYER, 0);

	if (argc > 2) {
		FILE *f = fopen(argv[2], "rb");
		static unsigned char fw[1 << 20];
		size_t n;
		unsigned req;
		if (!f) { perror(argv[2]); return 2; }
		n = fread(fw, 1, sizeof fw, f);
		fclose(f);
		if (n == sizeof fw) { fprintf(stderr, "%s: larger than 1 MB\n", argv[2]); return 2; }
		if (n < 8) { fprintf(stderr, "%s: shorter than its trailer\n", argv[2]); return 2; }
		req = fw[n - 4] << 8 | fw[n - 3];
		if (req != 2) { printf("FAIL built firmware file: OSD2_REQUIRED %u, want 2\n", req); fails++; }
		runc("built firmware file, VERSION = SDC_VERSION: boots", fw, (unsigned)n, SDC_VERSION, LAYER2, 1);
		runc("built firmware file, VERSION = SDC_VERSION + 1: mismatch", fw, (unsigned)n, SDC_VERSION + 1, LAYER2, 0);
		runc("built firmware file, an older text layer: mismatch", fw, (unsigned)n, SDC_VERSION, LAYER1, 0);
		runc("built firmware file, no text layer: mismatch", fw, (unsigned)n, SDC_VERSION, NOLAYER, 0);
	}
	if (fails) {
		printf("lockstep host test: %d FAILED\n", fails);
		return 1;
	}
	printf("lockstep host test: ALL PASS\n");
	return 0;
}

/* Host test of the boot ROM's lock-step check (../lockstep.c, design 5.5):
   fw_start() against a mock VERSION register, with the boot ROM's own
   small_printf (both compiled with -Dputchar=rv_putchar: the UART text is
   captured here byte for byte, as the boot ROM prints it).

   usage: lockstep_test [<firmware file>]   (test/Makefile: FWBIN, fw/ctrl's
                                           build output, fw/ctrl/fwname.mk)
     no argument: the in-memory cases below
     a file:      also that file (fw/ctrl's build, trailer appended by its
                  Makefile) must boot with VERSION = SDC_VERSION and stop
                  with VERSION = SDC_VERSION + 1
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
}

void boot_halt(void)
{
	halted++;
	longjmp(env, 2);
}

/* run fw_start on img[0..size) with VERSION = ver; boot = 1: it must jump */
static void run(const char *name, const unsigned char *img, unsigned size, unsigned ver, int boot)
{
	char want[128];
	int ok;

	mock_version = ver;
	outn = 0;
	out[0] = 0;
	ncodes = booted = halted = 0;
	if (setjmp(env) == 0) {
		fw_start(img, size);
		printf("FAIL %s: fw_start returned\n", name);
		fails++;
		return;
	}
	if (boot) {
		snprintf(want, sizeof want, "Firmware SDC %04X, bitstream SDC %04X\n", ver, ver);
		ok = booted == 1 && !halted && ncodes == 0 && !strcmp(out, want);
	} else {
		snprintf(want, sizeof want, "Firmware does not match this bitstream (need SDC %04X)\n", ver);
		ok = !booted && halted == 1 && ncodes == 1 && codes[0] == 0x0ff && !strcmp(out, want);
	}
	if (ok)
		printf("PASS %s\n", name);
	else {
		printf("FAIL %s: booted %d, halted %d, ErrorCode calls %d (first %03x)\n"
		       "  UART got:  \"%s\"\n  UART want: \"%s\"\n",
		       name, booted, halted, ncodes, ncodes ? codes[0] : 0, out, want);
		fails++;
	}
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

int main(int argc, char **argv)
{
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
	trailer(3000, 0, 1, 0x5D01);
	run("bytes 4-5 not 0 (00 01): mismatch", img, 3000, 0x5D01, 0);
	trailer(3000, 1, 0, 0x5D01);
	run("bytes 4-5 not 0 (01 00): mismatch", img, 3000, 0x5D01, 0);
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

	if (argc > 1) {
		FILE *f = fopen(argv[1], "rb");
		static unsigned char fw[1 << 20];
		size_t n;
		if (!f) { perror(argv[1]); return 2; }
		n = fread(fw, 1, sizeof fw, f);
		fclose(f);
		if (n == sizeof fw) { fprintf(stderr, "%s: larger than 1 MB\n", argv[1]); return 2; }
		run("built firmware file, VERSION = SDC_VERSION: boots", fw, (unsigned)n, SDC_VERSION, 1);
		run("built firmware file, VERSION = SDC_VERSION + 1: mismatch", fw, (unsigned)n, SDC_VERSION + 1, 0);
	}
	if (fails) {
		printf("lockstep host test: %d FAILED\n", fails);
		return 1;
	}
	printf("lockstep host test: ALL PASS\n");
	return 0;
}

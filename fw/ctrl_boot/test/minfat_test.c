/* Host test for the boot ROM FAT code: links ../minfat.c and ../swap.c against a
   mock sd_read_sector() that reads a raw card image made by tools/sim/mkcard.sh.

   usage: minfat_test <card.img> <expected-file | ->
     expected-file given : FindDrive() must succeed and LoadFile(OSDNAME) must return
                           the file's size and bytes.
     "-"                 : FindDrive() must succeed and LoadFile(OSDNAME) must return 0.
   Exit status 0 = pass.  Set VERBOSE=1 to see the boot ROM's own messages. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdint.h>

#include "../minfat.h"

#ifndef OSDNAME
#error OSDNAME must be defined (the boot ROM build passes -DOSDNAME=...)
#endif

static FILE *img;
static int verbose;
static unsigned long sectors_read;

int sd_read_sector(unsigned long lba, unsigned char *buf)
{
	sectors_read++;
	if (fseek(img, (long)lba * 512, SEEK_SET) != 0)
		return 0;
	return fread(buf, 1, 512, img) == 512;
}

/* minfat.c is compiled with -Dputs=rv_puts, and printf is small_printf (small_printf.h). */
int rv_puts(const char *s)
{
	if (verbose)
		fputs(s, stdout);
	return (int)strlen(s);
}

int small_printf(const char *fmt, ...)
{
	va_list ap;
	int r = 0;
	va_start(ap, fmt);
	if (verbose)
		r = vprintf(fmt, ap);
	va_end(ap);
	return r;
}

static unsigned char loadbuf[65536] __attribute__((aligned(4)));

int main(int argc, char **argv)
{
	unsigned char *want = NULL;
	long wantsize = 0;
	int n;

	if (argc != 3) {
		fprintf(stderr, "usage: %s card.img (expected-file|-)\n", argv[0]);
		return 2;
	}
	verbose = getenv("VERBOSE") != NULL;
	img = fopen(argv[1], "rb");
	if (!img) { perror(argv[1]); return 2; }
	if (strcmp(argv[2], "-")) {
		FILE *f = fopen(argv[2], "rb");
		if (!f) { perror(argv[2]); return 2; }
		fseek(f, 0, SEEK_END);
		wantsize = ftell(f);
		fseek(f, 0, SEEK_SET);
		want = malloc(wantsize);
		if (fread(want, 1, wantsize, f) != (size_t)wantsize) { perror("read"); return 2; }
		fclose(f);
	}

	memset(loadbuf, 0xA5, sizeof loadbuf);
	if (!FindDrive()) {
		printf("FAIL %s: FindDrive() returned 0\n", argv[1]);
		return 1;
	}
	n = LoadFile(OSDNAME, loadbuf);
	if (!want) {
		if (n != 0) { printf("FAIL %s: LoadFile returned %d for a missing file\n", argv[1], n); return 1; }
		printf("PASS %s: file absent -> LoadFile()==0 (%lu sectors read)\n", argv[1], sectors_read);
		return 0;
	}
	if (n != wantsize) { printf("FAIL %s: LoadFile returned %d, want %ld\n", argv[1], n, wantsize); return 1; }
	if (memcmp(loadbuf, want, wantsize)) { printf("FAIL %s: file contents differ\n", argv[1]); return 1; }
	free(want);
	printf("PASS %s: %ld bytes identical (%lu sectors read)\n", argv[1], wantsize, sectors_read);
	return 0;
}

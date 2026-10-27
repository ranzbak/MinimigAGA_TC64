/* cfgconv: a Minimig config file from the byte order of the previous
 * (big-endian) firmware, "BE", to the RISC-V firmware's, "RV", and back
 * (README.md).
 *
 *   cfgconv --to-rv  <in> <out>   BE (big-endian, MINMGAA.CFG) -> RV (little-endian, MINMGAR.CFG)
 *   cfgconv --to-be  <in> <out>   RV -> BE
 *   cfgconv --check  <in>         the byte order and every field, "name = value"
 *
 * Refused (exit 1, nothing written): a file that is not a config file
 * (cfg_order() == CFG_BAD: length, id, version), a file that is already in
 * the target order, and an output that is the input.  Usage errors exit 2.
 * The conversion itself is cfgswap.c, the code the firmware uses. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "cfgswap.h"
#include "swap.h"

/* configTYPE (fw/ctrl/config.h) for --check: name, offset, size (1 =
 * byte, 4 = 32-bit number, 8/16 = char array).  config_test checks this
 * table's output against test/gold/mkcfgbe.py. */
struct field { const char *name; unsigned off, size; };

#define HARDFILE(n, b) \
	{ n ".enabled", (b), 1 }, { n ".present", (b) + 1, 1 }, \
	{ n ".name", (b) + 2, 8 }, { n ".long_name", (b) + 10, 16 }

static const struct field fields[] = {
	{ "id", 0, 8 },                 { "version", CFG_OFF_VERSION, 4 },
	{ "kickstart.name", 12, 8 },    { "kickstart.long_name", 20, 16 },
	{ "filter.lores", 36, 1 },      { "filter.hires", 37, 1 },
	{ "memory", 38, 1 },            { "chipset", 39, 1 },
	{ "floppy.speed", 40, 1 },      { "floppy.drives", 41, 1 },
	{ "disable_ar3", 42, 1 },       { "enable_ide", 43, 1 },
	{ "scanlines", 44, 1 },         { "misc", 45, 1 },
	HARDFILE("hardfile[0]", 46),    HARDFILE("hardfile[1]", 72),
	{ "cpu", 98, 1 },               { "fastram", 99, 1 },
	{ "kick13patch", 100, 1 },      { "autofire", 101, 1 },
	{ "extrom.name", 102, 8 },      { "extrom.long_name", 110, 16 },
	{ "drivesounds", 126, 1 },      { "crt_beam", 127, 1 },
	{ "crt_mask", 128, 1 },         { "crt_bloom", 129, 1 },
	{ "videopos_rtg.hpos", 130, 1 }, { "videopos_rtg.vpos", 131, 1 },
	{ "kickdir", CFG_OFF_KICKDIR, 4 }, { "extromdir", CFG_OFF_EXTROMDIR, 4 },
	{ "hdfdir[0]", CFG_OFF_HDFDIR, 4 },      { "hdfdir[1]", CFG_OFF_HDFDIR + 4, 4 },
	{ "hdfdir[2]", CFG_OFF_HDFDIR + 8, 4 },  { "hdfdir[3]", CFG_OFF_HDFDIR + 12, 4 },
	HARDFILE("secondaryhardfile[0]", 156), HARDFILE("secondaryhardfile[1]", 182),
	{ "audio.volume", 208, 1 },     { "videopos.hpos", 209, 1 },
	{ "videopos.vpos", 210, 1 },    { "hdmi_clkdelay", 211, 1 },
};

static int usage(void)
{
	fprintf(stderr, "usage: cfgconv --to-rv <in> <out>    big-endian (BE) config file -> RISC-V\n"
	                "       cfgconv --to-be <in> <out>    RISC-V config file -> big-endian (BE)\n"
	                "       cfgconv --check <in>          byte order and fields\n");
	return 2;
}

/* why cfg_order() said CFG_BAD */
static void bad_reason(const char *path, const uint8_t *buf, size_t len)
{
	if (len > CFG_SIZE)
		fprintf(stderr, "cfgconv: %s: not a config file: more than %d bytes\n", path, CFG_SIZE);
	else if (len < CFG_MIN_SIZE)
		fprintf(stderr, "cfgconv: %s: not a config file: %zu bytes, not %d..%d\n",
		        path, len, CFG_MIN_SIZE, CFG_SIZE);
	else if (memcmp(buf, CFG_ID, CFG_ID_LEN) != 0)
		fprintf(stderr, "cfgconv: %s: not a config file: the id is not %s\n", path, CFG_ID);
	else
		fprintf(stderr, "cfgconv: %s: not a config file: version %lu little-endian, %lu big-endian, "
		        "neither is 1..%d\n", path, (unsigned long)rd_le32(buf + CFG_OFF_VERSION),
		        (unsigned long)rd_be32(buf + CFG_OFF_VERSION), CFG_VERSION_MAX);
}

/* the file into buf (CFG_SIZE + 1 bytes, the rest 0): its length, or -1 */
static long load(const char *path, uint8_t *buf)
{
	FILE *f = fopen(path, "rb");
	size_t n;
	if (!f) {
		perror(path);
		return -1;
	}
	memset(buf, 0, CFG_SIZE + 1);
	n = fread(buf, 1, CFG_SIZE + 1, f);
	if (ferror(f)) {
		perror(path);
		fclose(f);
		return -1;
	}
	fclose(f);
	return (long)n;
}

static void show_string(const uint8_t *p, unsigned size)
{
	unsigned i;
	putchar('"');
	for (i = 0; i < size && p[i]; i++) {
		if (p[i] >= 0x20 && p[i] <= 0x7e && p[i] != '"' && p[i] != '\\')
			putchar(p[i]);
		else
			printf("\\x%02x", p[i]);
	}
	putchar('"');
}

static int check(const uint8_t *buf, size_t len, int order)
{
	size_t i;
	printf("order = %s\n", order == CFG_BE ? "BE" : "RV");
	for (i = 0; i < sizeof fields / sizeof fields[0]; i++) {
		const struct field *f = &fields[i];
		const uint8_t *p = buf + f->off;
		if (f->off + f->size > len)
			continue;           /* a shorter file of older firmware */
		printf("%s = ", f->name);
		if (f->size == 1)
			printf("%u", p[0]);
		else if (f->size == 4)
			printf("%lu", (unsigned long)(order == CFG_BE ? rd_be32(p) : rd_le32(p)));
		else
			show_string(p, f->size);
		putchar('\n');
	}
	return 0;
}

static int same_file(const char *a, const char *b)
{
	struct stat sa, sb;
	if (strcmp(a, b) == 0)
		return 1;
	return stat(a, &sa) == 0 && stat(b, &sb) == 0 && sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino;
}

int main(int argc, char **argv)
{
	uint8_t buf[CFG_SIZE + 1];
	int to, order;
	long len;
	FILE *f;

	if (argc == 3 && strcmp(argv[1], "--check") == 0)
		to = 0;
	else if (argc == 4 && strcmp(argv[1], "--to-rv") == 0)
		to = CFG_RV;
	else if (argc == 4 && strcmp(argv[1], "--to-be") == 0)
		to = CFG_BE;
	else
		return usage();

	if ((len = load(argv[2], buf)) < 0)
		return 1;
	order = cfg_order(buf, (size_t)len);
	if (order == CFG_BAD) {
		bad_reason(argv[2], buf, (size_t)len);
		return 1;
	}
	if (!to)
		return check(buf, (size_t)len, order);

	if (order == to) {
		fprintf(stderr, "cfgconv: %s is already in %s byte order\n", argv[2], to == CFG_RV ? "RV" : "BE");
		return 1;
	}
	if (same_file(argv[2], argv[3])) {
		fprintf(stderr, "cfgconv: the output %s is the input\n", argv[3]);
		return 1;
	}
	cfg_swap(buf);
	if (cfg_order(buf, (size_t)len) != to) {    /* cannot happen: cfg_swap swaps version too */
		fprintf(stderr, "cfgconv: %s: internal error, the result is not in the target order\n", argv[2]);
		return 1;
	}
	f = fopen(argv[3], "wb");
	if (!f || fwrite(buf, 1, (size_t)len, f) != (size_t)len) {
		perror(argv[3]);
		if (f)
			fclose(f);
		return 1;
	}
	if (fclose(f) != 0) {
		perror(argv[3]);
		return 1;
	}
	return 0;
}

/* config_test: the config file's byte order (Task 11, decision 12.4).
 *   config_test <case dir> <image dir> <out prefix>
 * Run by config_check.sh (make -C fw/ctrl/test run-config_test), which
 * makes the inputs first: gold/mkcfgbe.py's big-endian (BE) files of the
 * previous firmware (<case>.cfg) and the
 * expected fields (cfgcases.h, compiled in), cfgconv --to-rv of each valid
 * case (<case>.rv), and the card images (tools/sim/mkcard.sh):
 *   rv.img     MINMGAR.CFG = distinct.rv              (a) only an RV file
 *   abe.img    MINMGAA.CFG = distinct.cfg, MINMGAA1.CFG = v2.cfg,
 *              MINMGAA2.CFG = v3_208.cfg              (b) only BE files
 *   wrong.img  MINMGAR.CFG = distinct.cfg             (c) BE order, RV name
 *   both.img   MINMGAR.CFG = distinct.rv, MINMGAA.CFG = l2.cfg   (d) both
 *   rvasbe.img MINMGAA.CFG = distinct.rv              (e) RV order, BE name
 *   empty.img  no config file                         the defaults
 * Checks:
 *   - cfg_order() of every case; every field of each cfgconv --to-rv result,
 *     read through the firmware's configTYPE, against mkcfgbe.py's table;
 *     cfg_swap() of the BE bytes == the cfgconv result
 *   - LoadConfiguration()/ConfigurationExists() through the real fat.c and
 *     mmc.c on the card model: what config holds, the BootPrint and UART
 *     lines, and every byte the run changed on the card: none for (a), (c),
 *     (d), (e) and the defaults; for (b) only the new RV files' directory entries,
 *     FAT entries and data cluster -- the BE files' entries and clusters
 *     stay byte for byte (read back by bytes here, not through fat.c)
 *   - (b) the RV files read back through fat.c; the card is saved to
 *     <out prefix>_abe.img for config_check.sh (mtools, fsck.fat -n)
 * The firmware's messages about a BE file keep the old wording ("Converted
 * 832 configuration ...", "(832 byte order)": 832 was the previous
 * firmware's CPU); the checks below look for that text.
 * The BPB and directory are parsed here from the image bytes, independently
 * of fat.c.  The firmware's printf (rvlibc.c) goes to the mock UART; this
 * program reports with fprintf(stdout) (say). */
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "errors.h"
#include "hardware.h"
#include "mmc.h"
#include "fat.h"
#include "hdd.h"
#include "cdrom.h"
#include "config.h"
#include "fpga.h"
#include "osd.h"
#include "adv7511.h"
#include "cfgswap.h"
#include "mock_hw.h"

/* ---- what config.c needs from the rest of the firmware ---- */
char s[40];
unsigned char core_caps;
hdfTYPE hdf[HDD_SLOTS];
cdromTYPE cdrom;
static char bootlog[4096];   /* BootPrint texts, each followed by '|' */
char BootPrint(const char *text)
{
	size_t n = strlen(bootlog);
	snprintf(bootlog + n, sizeof bootlog - n, "%s|", text);
	return 0;
}
void BootPrintEx(char *str) { (void)str; }
int SendFileV2(RAFile *file, unsigned char *key, int keysize, int address, int size) { return 1; }
unsigned char OpenHardfile(unsigned int unit) { return 0; }
int CD_Open(int slot) { return 0; }
void ConfigIDE(unsigned char port, unsigned char on, unsigned char master, unsigned char slave, unsigned char atapi) { }
void ConfigMemory(unsigned char memory) { }
void ConfigCPU(unsigned char cpu) { }
void ConfigChipset(unsigned char chipset) { }
void ConfigFloppy(unsigned char drives, unsigned char speed) { }
void ConfigVideo(unsigned char scanlines, unsigned char crt_mask, unsigned char crt_bloom,
                 unsigned char crt_beam) { }
void ConfigVideoPos(void) { }
void ConfigAutofire(unsigned char autofire) { }
void adv7511_set_clkdelay(unsigned char step) { }

/* the layout cfgswap.h and the files rely on, on this ABI too */
_Static_assert(sizeof(configTYPE) == CFG_SIZE, "configTYPE is 212 bytes");
_Static_assert(offsetof(configTYPE, filter) == 36, "config_check.sh zeroes the filter bytes at 36");

static int fails, cases;

static void say(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stdout, fmt, ap);
	va_end(ap);
}

static int check(const char *what, unsigned long got, unsigned long want)
{
	cases++;
	if (got != want) {
		say("FAIL %s: got %lu (0x%lx), want %lu (0x%lx)\n", what, got, got, want, want);
		fails++;
		return 0;
	}
	say("ok   %s = %lu\n", what, got);
	return 1;
}

static int check_mem(const char *what, const void *got, const void *want, size_t n)
{
	const uint8_t *g = got, *w = want;
	cases++;
	for (size_t i = 0; i < n; i++)
		if (g[i] != w[i]) {
			say("FAIL %s: byte %zu is %02x, want %02x\n", what, i, g[i], w[i]);
			fails++;
			return 0;
		}
	say("ok   %s (%zu bytes)\n", what, n);
	return 1;
}

static int check_has(const char *what, const char *hay, const char *needle)
{
	cases++;
	if (!strstr(hay, needle)) {
		say("FAIL %s: \"%s\" not in \"%s\"\n", what, needle, hay);
		fails++;
		return 0;
	}
	say("ok   %s\n", what);
	return 1;
}

static int check_hasnt(const char *what, const char *hay, const char *needle)
{
	cases++;
	if (strstr(hay, needle)) {
		say("FAIL %s: \"%s\" in \"%s\"\n", what, needle, hay);
		fails++;
		return 0;
	}
	say("ok   %s\n", what);
	return 1;
}

/* a whole file; *len its size */
static uint8_t *slurp(const char *dir, const char *name, size_t *len)
{
	char path[1024];
	snprintf(path, sizeof path, "%s/%s", dir, name);
	FILE *f = fopen(path, "rb");
	if (!f) { say("FAIL cannot open %s\n", path); exit(1); }
	fseek(f, 0, SEEK_END);
	long n = ftell(f);
	fseek(f, 0, SEEK_SET);
	uint8_t *p = calloc((size_t)n + 1, 1);
	if (!p || fread(p, 1, (size_t)n, f) != (size_t)n) { say("FAIL cannot read %s\n", path); exit(1); }
	fclose(f);
	*len = (size_t)n;
	return p;
}

/* ---- the cases of mkcfgbe.py ------------------------------------------- */
static void fields(const char *name, const configTYPE *c)
{
	char what[160];
	(void)what;
#define CFG_CASE(n, order, len)
#define CFG_FIELD_U(n, m, v) \
	if (!strcmp(name, #n)) { snprintf(what, sizeof what, "%s.rv " #m, name); check(what, c->m, v); }
#define CFG_FIELD_S(n, m, v) \
	if (!strcmp(name, #n)) { snprintf(what, sizeof what, "%s.rv " #m, name); \
	                         _Static_assert(sizeof(c->m) == sizeof(v) - 1, #m); \
	                         check_mem(what, c->m, v, sizeof(c->m)); }
#include "cfgcases.h"
#undef CFG_CASE
#undef CFG_FIELD_U
#undef CFG_FIELD_S
}

static const struct { const char *name; int order; size_t len; } case_list[] = {
#define CFG_CASE(n, order, len) { #n, order, len },
#define CFG_FIELD_U(n, m, v)
#define CFG_FIELD_S(n, m, v)
#include "cfgcases.h"
#undef CFG_CASE
#undef CFG_FIELD_U
#undef CFG_FIELD_S
};

static void order_and_fields(const char *dir)
{
	char what[160], fn[64];
	for (size_t i = 0; i < sizeof case_list / sizeof case_list[0]; i++) {
		const char *name = case_list[i].name;
		size_t len, rlen;
		snprintf(fn, sizeof fn, "%s.cfg", name);
		uint8_t *b = slurp(dir, fn, &len);
		snprintf(what, sizeof what, "%s.cfg length", name);
		check(what, len, case_list[i].len);
		snprintf(what, sizeof what, "cfg_order(%s.cfg)", name);
		check(what, (unsigned long)cfg_order(b, len), (unsigned long)case_list[i].order);
		if (case_list[i].order != CFG_BAD) {
			snprintf(fn, sizeof fn, "%s.rv", name);
			uint8_t *r = slurp(dir, fn, &rlen);
			snprintf(what, sizeof what, "%s.rv length", name);
			check(what, rlen, len);
			snprintf(what, sizeof what, "cfg_order(%s.rv)", name);
			check(what, (unsigned long)cfg_order(r, rlen), CFG_RV);
			/* the library on the BE bytes == the tool's output */
			uint8_t sw[CFG_SIZE] = { 0 };
			memcpy(sw, b, len);
			cfg_swap(sw);
			snprintf(what, sizeof what, "cfg_swap(%s.cfg) == %s.rv", name, name);
			check_mem(what, sw, r, rlen);
			configTYPE c;
			memset(&c, 0, sizeof c);
			memcpy(&c, r, rlen);
			fields(name, &c);
			free(r);
		}
		free(b);
	}
}

/* ---- the card, read by bytes (not through fat.c) ------------------------ */
static uint8_t *img0;          /* the image as it was loaded */
static size_t img0_len;
static struct { unsigned long part, fat, nfats, fatsz, root, rootents, data, spc; } bpb;

static unsigned long le16_at(const uint8_t *b) { return b[0] | (unsigned long)b[1] << 8; }
static unsigned long le32_at(const uint8_t *b) { return le16_at(b) | le16_at(b + 2) << 16; }

static void parse_bpb(void)
{
	const uint8_t *b;
	bpb.part = le32_at(img0 + 454);
	b = img0 + bpb.part * 512;
	bpb.spc = b[13];
	bpb.fat = bpb.part + le16_at(b + 14);
	bpb.nfats = b[16];
	bpb.rootents = le16_at(b + 17);
	bpb.fatsz = le16_at(b + 22);
	bpb.root = bpb.fat + bpb.nfats * bpb.fatsz;
	bpb.data = bpb.root + bpb.rootents * 32 / 512;
}

/* the card model's byte at offset o */
static uint8_t card_byte(size_t o)
{
	const unsigned char *p = mock_card_sector((unsigned)(o / 512));
	return p ? p[o % 512] : 0;
}

/* the offset of the root directory entry of an 11-character name on the
   card model (now = 1) or in the loaded image (now = 0); 0 = none */
static size_t find_entry(const char *name11, int now)
{
	for (unsigned long i = 0; i < bpb.rootents; i++) {
		size_t o = bpb.root * 512 + i * 32;
		uint8_t e[32];
		for (int k = 0; k < 32; k++)
			e[k] = now ? card_byte(o + k) : img0[o + k];
		if (e[0] == 0)
			break;
		if (e[0] == 0xE5 || e[11] == 0x0F)
			continue;
		if (!memcmp(e, name11, 11))
			return o;
	}
	return 0;
}

/* every byte that differs between the card model and the loaded image must
   lie in the entry, the FAT entries or the data cluster of one of the named
   new files; "what" bytes may change in all */
static void check_changes(const char *what, const char *const *newnames, int nnew)
{
	struct { size_t lo, hi; } ok[16];
	int n = 0;
	char w[200];
	for (int i = 0; i < nnew; i++) {
		size_t e = find_entry(newnames[i], 1);
		snprintf(w, sizeof w, "%s: %.11s is in the root directory", what, newnames[i]);
		if (!check(w, e != 0, 1))
			continue;
		unsigned long cl = card_byte(e + 26) | (unsigned long)card_byte(e + 27) << 8;
		ok[n].lo = e; ok[n++].hi = e + 32;
		for (unsigned long f = 0; f < bpb.nfats; f++) {
			ok[n].lo = (bpb.fat + f * bpb.fatsz) * 512 + cl * 2;
			ok[n].hi = ok[n].lo + 2;
			n++;
		}
		ok[n].lo = (bpb.data + (cl - 2) * bpb.spc) * 512;
		ok[n].hi = ok[n].lo + bpb.spc * 512;
		n++;
	}
	unsigned long changed = 0, outside = 0;
	for (size_t o = 0; o < img0_len; o++) {
		if (card_byte(o) == img0[o])
			continue;
		changed++;
		int in = 0;
		for (int k = 0; k < n; k++)
			if (o >= ok[k].lo && o < ok[k].hi)
				in = 1;
		if (!in) {
			if (outside < 4)
				say("     byte %zu (sector %zu) changed %02x -> %02x\n", o, o / 512, img0[o], card_byte(o));
			outside++;
		}
	}
	snprintf(w, sizeof w, "%s: bytes changed outside the new files' entries, FAT entries and clusters", what);
	check(w, outside, 0);
	if (!nnew) {
		snprintf(w, sizeof w, "%s: bytes changed on the card", what);
		check(w, changed, 0);
	}
}

/* a BE file: entry and data cluster byte for byte as loaded */
static void check_untouched(const char *what, const char *name11, const uint8_t *content, size_t len)
{
	char w[200];
	size_t e = find_entry(name11, 0);
	snprintf(w, sizeof w, "%s: %.11s in the loaded image", what, name11);
	if (!check(w, e != 0, 1))
		return;
	uint8_t now[32];
	for (int k = 0; k < 32; k++)
		now[k] = card_byte(e + k);
	snprintf(w, sizeof w, "%s: %.11s directory entry unchanged", what, name11);
	check_mem(w, now, img0 + e, 32);
	unsigned long cl = le16_at(img0 + e + 26);
	size_t d = (bpb.data + (cl - 2) * bpb.spc) * 512;
	uint8_t *c = malloc(bpb.spc * 512);
	for (size_t k = 0; k < bpb.spc * 512; k++)
		c[k] = card_byte(d + k);
	snprintf(w, sizeof w, "%s: %.11s data cluster unchanged", what, name11);
	check_mem(w, c, img0 + d, bpb.spc * 512);
	snprintf(w, sizeof w, "%s: %.11s holds the BE file", what, name11);
	check_mem(w, c, content, len);
	snprintf(w, sizeof w, "%s: %.11s size in its entry", what, name11);
	check(w, le32_at(now + 28), len);
	free(c);
}

/* a file read back through fat.c */
static void check_fat_file(const char *what, const char *name11, const void *want, size_t len)
{
	char w[200];
	unsigned char buf[512] __attribute__((aligned(4)));
	fileTYPE f;
	ChangeDirectory(0);
	snprintf(w, sizeof w, "%s: FileOpen(\"%.11s\")", what, name11);
	if (!check(w, FileOpen(&f, name11), 1))
		return;
	snprintf(w, sizeof w, "%s: %.11s size", what, name11);
	check(w, f.size, len);
	snprintf(w, sizeof w, "%s: FileRead(%.11s)", what, name11);
	check(w, FileRead(&f, buf), 1);
	snprintf(w, sizeof w, "%s: %.11s contents", what, name11);
	check_mem(w, buf, want, len);
}

static void card(const char *imgdir, const char *name)
{
	char path[1024];
	struct stat st;
	snprintf(path, sizeof path, "%s/%s.img", imgdir, name);
	free(img0);
	img0 = slurp(imgdir, strrchr(path, '/') + 1, &img0_len);
	mock_reset();
	if (stat(path, &st) || st.st_size % 512) { say("FAIL %s: no image of whole sectors\n", path); exit(1); }
	if (mock_card_load(path, (unsigned)(st.st_size / 512))) { say("FAIL cannot load %s\n", path); exit(1); }
	say("---- %s\n", path);
	check("MMC_Init: SDHC", MMC_Init(), CARDTYPE_SDHC);
	check("FindDrive()", FindDrive(), 1);
	parse_bpb();
	bootlog[0] = 0;
	mock_uart_clear();
	ClearError(ERROR_ALL);
	memset(&config, 0xEE, sizeof config);   /* LoadConfiguration must set every byte */
}

/* LoadConfiguration of a slot, as ColdBoot / the Load page do */
static unsigned char load(int slot)
{
	config.kickstart.name[0] = 0;
	SetConfigurationFilename(slot);
	return LoadConfiguration(NULL);
}

static configTYPE defaults_cfg;

int main(int argc, char **argv)
{
	if (argc != 4) {
		say("usage: config_test <case dir> <image dir> <out prefix>\n");
		return 2;
	}
	const char *dir = argv[1], *imgs = argv[2], *pre = argv[3];
	char path[1024];
	size_t n, n2;

	order_and_fields(dir);
	uint8_t *distinct_rv = slurp(dir, "distinct.rv", &n);
	uint8_t *distinct_be = slurp(dir, "distinct.cfg", &n);
	uint8_t *defaults_rv = slurp(dir, "defaults.rv", &n);
	uint8_t *v2_rv = slurp(dir, "v2.rv", &n);
	uint8_t *v2_be = slurp(dir, "v2.cfg", &n);
	uint8_t *v3s_rv = slurp(dir, "v3_208.rv", &n2);
	uint8_t *v3s_be = slurp(dir, "v3_208.cfg", &n2);
	uint8_t *l2_be = slurp(dir, "l2.cfg", &n);
	/* distinct has the Lores/Hires Filter bytes set, as a file from before
	   their removal (plan.md 3.13) can: it loads, and they read and save as 0 */
	configTYPE distinct_want;
	memcpy(&distinct_want, distinct_rv, CFG_SIZE);
	check("distinct.rv: the filter bytes set (an old file)",
	      distinct_want.filter.lores != 0 && distinct_want.filter.hires != 0, 1);
	distinct_want.filter.lores = distinct_want.filter.hires = 0;

	/* no config file: the defaults == mkcfgbe.py's defaults (converted) */
	card(imgs, "empty");
	check("empty: ConfigurationExists(slot 0)", (SetConfigurationFilename(0), ConfigurationExists(0)), 0);
	check("empty: LoadConfiguration", load(0), 0);
	check_mem("empty: config == the defaults of mkcfgbe.py", &config, defaults_rv, CFG_SIZE);
	check_changes("empty", NULL, 0);
	defaults_cfg = config;

	/* the RTG screen's Video Pos (Phase 4): the two bytes before kickdir, a
	   212-byte struct still; a file of older firmware holds 0 there (the
	   defaults' bytes): centred; distinct's bytes land in it */
	check("videopos_rtg at offset 130", offsetof(configTYPE, videopos_rtg), 130);
	check("configTYPE still 212 bytes", sizeof(configTYPE), 212);
	check("defaults: videopos_rtg centred", config.videopos_rtg.hpos | config.videopos_rtg.vpos, 0);
	check("defaults.rv: bytes 130-131 0", defaults_rv[130] | defaults_rv[131], 0);
	/* the OSD menu's size and position (config.h CONFIG_OSD_*): autofire
	   bits 5:3, 0 in the defaults and in files of older firmware: Large,
	   Centre */
	check("defaults: OSD large, centre", config.autofire & (CONFIG_OSD_SMALL | CONFIG_OSD_POS_MASK), 0);
	check("OSD bits inside autofire's free bits 7:3", (CONFIG_OSD_SMALL | CONFIG_OSD_POS_MASK) & 0x07, 0);
	check("distinct.rv: videopos_rtg = bytes 130-131",
	      distinct_want.videopos_rtg.hpos == distinct_rv[130] && distinct_want.videopos_rtg.vpos == distinct_rv[131] &&
	      distinct_rv[130] && distinct_rv[131], 1);

	/* (a) only the RV file */
	card(imgs, "rv");
	check("(a) ConfigurationExists(slot 0)", (SetConfigurationFilename(0), ConfigurationExists(0)), 1);
	check("(a) LoadConfiguration", load(0), 1);
	check_mem("(a) config == distinct.rv, filters 0", &config, &distinct_want, CFG_SIZE);
	check("(a) distinct's autofire has OSD bits set", (distinct_want.autofire & (CONFIG_OSD_SMALL | CONFIG_OSD_POS_MASK)) != 0, 1);
	check("(a) the OSD bits loaded as the file holds them", config.autofire, distinct_want.autofire);
	check_hasnt("(a) no conversion line", mock_uart(), "Converted 832");
	check_changes("(a)", NULL, 0);

	/* (b) only BE files: converted, saved under the RV names, the BE files untouched */
	card(imgs, "abe");
	for (int slot = 0; slot <= 3; slot++) {
		snprintf(path, sizeof path, "(b) ConfigurationExists(slot %d), BE file only", slot);
		check(path, (SetConfigurationFilename(slot), ConfigurationExists(0)), slot <= 2);
	}
	check("(b) LoadConfiguration slot 0", load(0), 1);
	check_mem("(b) slot 0: config == distinct.rv (cfgconv --to-rv), filters 0", &config, &distinct_want, CFG_SIZE);
	check_has("(b) slot 0: UART conversion line", mock_uart(), "Converted 832 configuration MINMGAA.CFG\n");
	check_has("(b) slot 0: BootPrint conversion line", bootlog, "|Converted 832 configuration MINMGAA.CFG|");
	check_fat_file("(b) slot 0", "MINMGAR CFG", &distinct_want, CFG_SIZE);
	{
		/* slot 1: a version 2 file -- swapped first, then the old-format
		   rules (ROM paths, secondary hardfiles, drive sounds) and version 4 */
		configTYPE want;
		memcpy(&want, v2_rv, CFG_SIZE);
		want.version = CONFIG_VERSION;
		want.kickdir = 0;
		want.hdfdir[0] = want.hdfdir[1] = want.hdfdir[2] = want.hdfdir[3] = 0;
		for (int i = 0; i < 2; i++) {
			want.secondaryhardfile[i].enabled = want.secondaryhardfile[i].present = 0;
			want.secondaryhardfile[i].name[0] = want.secondaryhardfile[i].long_name[0] = 0;
		}
		want.drivesounds = 0;
		want.filter.lores = want.filter.hires = 0;
		check("(b) LoadConfiguration slot 1 (version 2)", load(1), 1);
		check_mem("(b) slot 1: config == v2.rv after the version-2 rules", &config, &want, CFG_SIZE);
		check_has("(b) slot 1: UART conversion line", mock_uart(), "Converted 832 configuration MINMGAA1.CFG\n");
		check_fat_file("(b) slot 1", "MINMGAR1CFG", &want, CFG_SIZE);
		/* slot 2: 208 bytes (older firmware), version 3: no rule applies;
		   the 4 bytes after the file are the rest of its sector (0) */
		memset(&want, 0, sizeof want);
		memcpy(&want, v3s_rv, n2);
		want.version = CONFIG_VERSION;
		want.filter.lores = want.filter.hires = 0;
		check("(b) LoadConfiguration slot 2 (208 bytes, version 3)", load(2), 1);
		check_mem("(b) slot 2: config == v3_208.rv, version 4", &config, &want, CFG_SIZE);
		check_fat_file("(b) slot 2", "MINMGAR2CFG", &want, CFG_SIZE);
	}
	{
		static const char *const rvnames[] = { "MINMGAR CFG", "MINMGAR1CFG", "MINMGAR2CFG" };
		check_changes("(b)", rvnames, 3);
	}
	check_untouched("(b)", "MINMGAA CFG", distinct_be, CFG_SIZE);
	check_untouched("(b)", "MINMGAA1CFG", v2_be, CFG_SIZE);
	check_untouched("(b)", "MINMGAA2CFG", v3s_be, n2);
	snprintf(path, sizeof path, "%s_abe.img", pre);
	check("(b) card saved", mock_card_save(path), 0);
	/* a second boot: the RV file is loaded, nothing is converted or written */
	mock_uart_clear();
	bootlog[0] = 0;
	{
		uint8_t *before = malloc(img0_len);
		for (size_t o = 0; o < img0_len; o++)
			before[o] = card_byte(o);
		check("(b) second boot: LoadConfiguration slot 0", load(0), 1);
		check_mem("(b) second boot: config == distinct.rv, filters 0", &config, &distinct_want, CFG_SIZE);
		check_hasnt("(b) second boot: no conversion line", mock_uart(), "Converted 832");
		unsigned long changed = 0;
		for (size_t o = 0; o < img0_len; o++)
			changed += card_byte(o) != before[o];
		check("(b) second boot: bytes changed on the card", changed, 0);
		free(before);
	}

	/* (c) a BE-order file under the RV name: rejected, the defaults, nothing written */
	card(imgs, "wrong");
	check("(c) LoadConfiguration", load(0), 0);
	check_mem("(c) config == the defaults", &config, &defaults_cfg, CFG_SIZE);
	check_has("(c) BootPrint: wrong format, BE byte order", bootlog,
	          "|Wrong configuration file format!\n|(832 byte order)|");
	check_has("(c) UART: BE byte order", mock_uart(), "(832 byte order)\n");
	check_hasnt("(c) no conversion line", mock_uart(), "Converted 832");
	check_changes("(c)", NULL, 0);

	/* (d) both files: the RV one wins, nothing converted or written */
	card(imgs, "both");
	check("(d) LoadConfiguration", load(0), 1);
	check_mem("(d) config == distinct.rv (the RV file), filters 0", &config, &distinct_want, CFG_SIZE);
	check_hasnt("(d) no conversion line", mock_uart(), "Converted 832");
	check_changes("(d)", NULL, 0);
	check_untouched("(d)", "MINMGAA CFG", l2_be, CFG_SIZE);

	/* (e) an RV-order file under the BE name: only a BE-order file is
	   converted -- the defaults, nothing written */
	card(imgs, "rvasbe");
	check("(e) LoadConfiguration", load(0), 0);
	check_mem("(e) config == the defaults", &config, &defaults_cfg, CFG_SIZE);
	check_hasnt("(e) no conversion line", mock_uart(), "Converted 832");
	check_changes("(e)", NULL, 0);

	/* (f) the config file's read fails (a card error, retries out; Task 10
	   fix round 1): no config, the defaults, the message.  The read is the
	   load's last block: the blocks of a good load counted first */
	{
		unsigned b0, d;
		card(imgs, "rv");
		b0 = mock_card_blocks_read();
		check("(f) a good load first", load(0), 1);
		d = mock_card_blocks_read() - b0;
		card(imgs, "rv");
		mock_card_error(MOCK_ERR_RDCRC, mock_card_blocks_read() + d, 5);
		check("(f) read error: LoadConfiguration 0", load(0), 0);
		check_mem("(f) config == the defaults", &config, &defaults_cfg, CFG_SIZE);
		check_has("(f) the message", bootlog, "Config file read error - using defaults");
		check_changes("(f)", NULL, 0);
	}

	snprintf(path, sizeof path, "%s.uart", pre);
	FILE *u = fopen(path, "wb");
	if (u) { fwrite(mock_uart(), 1, mock_uart_len(), u); fclose(u); }
	free(distinct_rv); free(distinct_be); free(defaults_rv); free(v2_rv); free(v2_be);
	free(v3s_rv); free(v3s_be); free(l2_be); free(img0);

	say("\n%d cases: %d failed\n", cases, fails);
	if (fails) { say("config_test FAIL\n"); return 1; }
	say("config_test PASS\n");
	return 0;
}

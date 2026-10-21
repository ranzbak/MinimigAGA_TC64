/* mmc_test: the real mmc.c (SD/MMC over SPI) on the card model of mock_hw.c.
 *   mmc_test <gold dir> <out prefix>
 * The card image is made here (<out prefix>.img: byte i of sector n =
 * (37 n + 11 i + (n >> 8)) mod 256, the formula of gold/dmode.py).
 *   - MMC_Init on the SDHC model: the card's command log equals
 *     gold/mmc_init_cmds.txt (the SD model's log of the L2 boot run), the SPI
 *     ran slow (0x3f) from before CMD0 and fast (0x01) after CMD58
 *   - MMC_Read with token delay 0, 4, 200 bytes; MMC_ReadMultiple (+ CMD12);
 *     MMC_Write with busy 8 and 2000 bytes; MMC_GetCapacity (CMD9): data
 *     against the image, each frame exactly as long as the protocol says
 *   - the five SD_TIMEOUT bounds (CMD17, CMD9 and CMD18 data token, CMD24
 *     and CMD12 busy) on a card that never answers: failure after the bound,
 *     the TIMER read once per byte, the trace no longer than the bound
 *   - direct mode (MMC_Read(lba, NULL): EnableDMode, SPI(0xFF), RDSPI,
 *     DisableDMode): the trace equals gold/dmode.txt (gold/dmode.py),
 *     written to <out prefix>_dmode.txt
 *   - the model: CMD55, CMD0, CMD41 is a plain CMD41 (sd_spi_model.v's case)
 * The TIMER: during MMC_Init the mock's default (1 count per TIMER read);
 * for the transfers 1 count per 16 SPI bytes and none per read (a card
 * far slower than the board's, where a 5.804 ms count is ~4000 bytes at the
 * fast SPI speed: 200 token bytes are 13 counts, 2000 busy bytes 125, both
 * inside SD_TIMEOUT = 173 counts, and SD_TIMEOUT 0 gives up after 16 bytes);
 * for the timeout cases the default again: the loop reads the TIMER once per
 * byte, so the bound in counts is the bound in bytes. */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "errors.h"
#include "hardware.h"
#include "mmc.h"
#include "mock_hw.h"

/* what mmc.c needs from the rest of the firmware */
int ErrorMask, ErrorFatal;
struct Error Errors[ERROR_MAX + 1];

extern unsigned char CardType;	/* mmc.c */

/* the brief's bound (exec-3 Task 10): 173 counts x 5.804 ms = 1.004 s; kept
   here, not taken from mmc.c, so that a changed SD_TIMEOUT shows */
#define BOUND 173

#define SECTORS   16384		/* 8 MB card, C_SIZE 15 */
#define IMG_SECTORS 1024	/* the pattern; the rest of the card is 0 */

/* the firmware's printf is rvlibc.c's (to the mock UART): this program
   reports with fprintf(stdout) */
static void say(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void say(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stdout, fmt, ap);
	va_end(ap);
}

static int fails;
static int cases;
static int check(const char *what, long got, long want)
{
	cases++;
	if (got != want) {
		say("FAIL %s: got %ld (0x%lx), want %ld (0x%lx)\n", what, got, (unsigned long)got, want, (unsigned long)want);
		fails++;
		return 0;
	}
	say("ok   %s = %ld\n", what, got);
	return 1;
}
static int check_str(const char *what, const char *got, const char *want)
{
	cases++;
	if (strcmp(got, want)) {
		say("FAIL %s:\n--- got\n%s--- want\n%s---\n", what, got, want);
		fails++;
		return 0;
	}
	say("ok   %s\n", what);
	return 1;
}

static unsigned char pattern(unsigned n, unsigned i) { return (unsigned char)(37 * n + 11 * i + (n >> 8)); }

static char *slurp(const char *path)
{
	FILE *f = fopen(path, "rb");
	if (!f) { say("FAIL cannot read %s\n", path); exit(1); }
	fseek(f, 0, SEEK_END);
	long n = ftell(f);
	fseek(f, 0, SEEK_SET);
	char *s = malloc((size_t)n + 1);
	if (!s || fread(s, 1, (size_t)n, f) != (size_t)n) { say("FAIL reading %s\n", path); exit(1); }
	s[n] = 0;
	fclose(f);
	return s;
}

/* the gold file without its '#' comment lines */
static char *gold_lines(const char *path)
{
	char *s = slurp(path), *o = malloc(strlen(s) + 1), *w = o;
	for (char *l = s; *l; ) {
		char *e = strchr(l, '\n');
		size_t n = e ? (size_t)(e - l) + 1 : strlen(l);
		if (*l != '#') { memcpy(w, l, n); w += n; }
		l += n;
	}
	*w = 0;
	free(s);
	return o;
}

/* the trace since `mark` (strlen of an earlier mock_trace()) */
static size_t mark;
static void trace_mark(void) { mark = strlen(mock_trace()); }
static const char *trace_since(void) { return mock_trace() + mark; }

/* out bytes of the last frame with chip select cs since the mark, -1 = none */
static long last_frame_len(unsigned cs)
{
	const char *t = trace_since(), *last = NULL;
	char head[4];
	snprintf(head, sizeof head, "%02x ", cs);
	for (const char *l = t; *l; ) {
		if (!strncmp(l, head, 3)) last = l;
		const char *e = strchr(l, '\n');
		if (!e) break;
		l = e + 1;
	}
	if (!last) return -1;
	long n = 0;
	for (const char *p = last + 2; *p && *p != '/'; p++)
		if (*p == ' ' && p[1] != '/') n++;
	return n;
}

static void errors_clear(void) { ErrorMask = 0; ErrorFatal = 0; memset(Errors, 0, sizeof Errors); }

static void make_image(const char *path)
{
	FILE *f = fopen(path, "wb");
	if (!f) { say("FAIL cannot write %s\n", path); exit(1); }
	for (unsigned n = 0; n < IMG_SECTORS; n++)
		for (unsigned i = 0; i < 512; i++) fputc(pattern(n, i), f);
	if (fclose(f)) { say("FAIL writing %s\n", path); exit(1); }
}

static int sector_is_pattern(const unsigned char *b, unsigned n)
{
	for (unsigned i = 0; i < 512; i++)
		if (b[i] != pattern(n, i)) return 0;
	return 1;
}

/* the transfers' clock (see the header) */
static void slow_card_clock(void) { mock_timer_step(0); mock_timer_spi_rate(16); }
/* the timeout cases: one count per TIMER read = per byte of the wait loop */
static void read_clock(void) { mock_timer_spi_rate(0); mock_timer_step(1); }

/* ---- MMC_Init ---- */
static void init_sequence(const char *img, const char *gold)
{
	char path[1024], want[128];
	char *g;
	unsigned n = 0;

	mock_reset();
	if (!check("card image loads", mock_card_load(img, SECTORS), 0)) return;
	CardType = 0;
	errors_clear();
	check("MMC_Init on the SDHC model", MMC_Init(), CARDTYPE_SDHC);
	check("CardType", CardType, CARDTYPE_SDHC);
	snprintf(path, sizeof path, "%s/mmc_init_cmds.txt", gold);
	g = gold_lines(path);
	check_str("the card's commands = gold/mmc_init_cmds.txt (L2 boot run)", mock_card_log(), g);
	for (const char *p = g; *p; p++) n += *p == '\n';
	free(g);
	snprintf(want, sizeof want, "3f after 0 commands\n01 after %u commands\n", n);
	check_str("SPI slow before CMD0, fast after CMD58, no other SPEED write", mock_spi_speed_log(), want);
	check("no fatal error", ErrorFatal, 0);
}

/* ---- MMC_Read, token delay ---- */
static void read_delay(int dly)
{
	unsigned char buf[512];
	char what[96];
	unsigned lba = 100 + (unsigned)dly;

	mock_card_params(dly, 8, 1, 2);
	errors_clear();
	trace_mark();
	snprintf(what, sizeof what, "MMC_Read lba %u, token delay %d", lba, dly);
	check(what, MMC_Read(lba, buf), 1);
	check("... == the image", sector_is_pattern(buf, lba), 1);
	/* flush + 6 command bytes, NCR + R1, the delay + token, 512 + 2 CRC */
	check("... frame bytes (7 + 2 + delay + 1 + 514)", last_frame_len(0x02), 7 + 2 + dly + 1 + 514);
	check("... no fatal error", ErrorFatal, 0);
}

/* ---- MMC_ReadMultiple ---- */
static void read_multiple(int dly, unsigned count)
{
	unsigned char buf[4 * 512];
	char what[96];
	unsigned lba = 300 + (unsigned)dly;
	int ok = 1;

	mock_card_params(dly, 8, 1, 2);
	errors_clear();
	trace_mark();
	snprintf(what, sizeof what, "MMC_ReadMultiple lba %u x %u, token delay %d", lba, count, dly);
	check(what, MMC_ReadMultiple(lba, buf, count), 1);
	for (unsigned k = 0; k < count; k++) ok &= sector_is_pattern(buf + 512 * k, lba + k);
	check("... == the image", ok, 1);
	/* CMD18 (7 + 2), per block delay + token + 514, CMD12: 6 command
	   bytes, stuff byte, NCR + R1, 8 busy bytes + the first 0xFF */
	check("... frame bytes", last_frame_len(0x02), 9 + (long)count * (dly + 515) + 6 + 1 + 2 + 9);
	check("... no fatal error", ErrorFatal, 0);
}

/* ---- MMC_Write, busy ---- */
static void write_busy(int busy)
{
	unsigned char buf[512], back[512];
	char what[96];
	unsigned lba = 2000 + (unsigned)busy;

	for (unsigned i = 0; i < 512; i++) buf[i] = (unsigned char)(i * 5 + busy);
	mock_card_params(4, busy, 1, 2);
	errors_clear();
	trace_mark();
	snprintf(what, sizeof what, "MMC_Write lba %u, busy %d bytes", lba, busy);
	check(what, MMC_Write(lba, buf), 1);
	/* 7 + 2, gap, token, 512, 2 CRC, data response, busy + the first 0xFF */
	check("... frame bytes (7 + 2 + 1 + 1 + 512 + 2 + 1 + busy + 1)", last_frame_len(0x02), 527 + busy);
	check("... in the card memory", memcmp(mock_card_sector(lba), buf, 512), 0);
	check("... read back", MMC_Read(lba, back), 1);
	check("... equal", memcmp(back, buf, 512), 0);
	check("... no fatal error", ErrorFatal, 0);
}

/* ---- the bounds ---- */
/* the wait loop's bytes in the last card frame: frame length - fixed part;
   one TIMER read per byte, the first count after GetTimer: BOUND + 1 bytes.
   reads: the TIMER reads of the call, less `other` reads before the wait */
static void bound(const char *what, long frame, long fixed, unsigned reads, unsigned other)
{
	char w[128];
	long bytes = frame - fixed;
	reads -= other;
	snprintf(w, sizeof w, "%s: wait bytes %ld in [BOUND, BOUND + 1]", what, bytes);
	check(w, bytes >= BOUND && bytes <= BOUND + 1, 1);
	snprintf(w, sizeof w, "%s: TIMER reads %u in [BOUND + 1, BOUND + 2]", what, reads);
	check(w, reads >= BOUND + 1 && reads <= BOUND + 2, 1);
}

static void timeouts(void)
{
	unsigned char buf[2 * 512];
	unsigned r0;

	read_clock();

	mock_card_params(-1, 8, 1, 2);	/* no data token, ever */
	errors_clear(); mock_uart_clear(); trace_mark(); r0 = mock_timer_reads();
	check("CMD17, no token: MMC_Read fails", MMC_Read(10, buf), 0);
	check("... FatalError(ERROR_SDCARD)", ErrorFatal && (ErrorMask & (1 << ERROR_SDCARD)), 1);
	check("... the message", strstr(mock_uart(), "CMD17 (READ_BLOCK): no data token!") != NULL, 1);
	bound("CMD17", last_frame_len(0x02), 9, mock_timer_reads() - r0, 0);

	errors_clear(); mock_uart_clear(); trace_mark(); r0 = mock_timer_reads();
	check("CMD9, no token: MMC_GetCSD fails", MMC_GetCSD(), 0);
	check("... the message", strstr(mock_uart(), "CMD9 (READ_BLOCK): no data token!") != NULL, 1);
	bound("CMD9", last_frame_len(0x02), 9, mock_timer_reads() - r0, 0);

	errors_clear(); mock_uart_clear(); trace_mark(); r0 = mock_timer_reads();
	check("CMD18, no token: MMC_ReadMultiple fails", MMC_ReadMultiple(10, buf, 2), 0);
	check("... the message", strstr(mock_uart(), "CMD18 (READ_MULTIPLE_BLOCK): no data token!") != NULL, 1);
	bound("CMD18", last_frame_len(0x02), 9, mock_timer_reads() - r0, 0);

	mock_card_params(4, -1, 1, 2);	/* busy without end */
	memset(buf, 0xA5, 512);
	errors_clear(); mock_uart_clear(); trace_mark(); r0 = mock_timer_reads();
	check("CMD24, busy forever: MMC_Write fails", MMC_Write(20, buf), 0);
	check("... the message", strstr(mock_uart(), "CMD24 (WRITE_BLOCK): busy wait timeout!") != NULL, 1);
	bound("CMD24", last_frame_len(0x02), 526, mock_timer_reads() - r0, 0);

	/* CMD12 busy: MMC_CMD12 gives up, MMC_ReadMultiple still returns 1 (it
	   does not look at MMC_CMD12's result) */
	errors_clear(); mock_uart_clear(); trace_mark(); r0 = mock_timer_reads();
	check("CMD12, busy forever: MMC_ReadMultiple returns (1)", MMC_ReadMultiple(30, buf, 2), 1);
	check("... the data", sector_is_pattern(buf, 30) && sector_is_pattern(buf + 512, 31), 1);
	check("... the message", strstr(mock_uart(), "CMD12 (STOP_TRANSMISSION): busy wait timeout!") != NULL, 1);
	/* before it, the two token waits: GetTimer + 4 checks each */
	bound("CMD12", last_frame_len(0x02), 9 + 2 * (4 + 515) + 6 + 1 + 2, mock_timer_reads() - r0, 2 * (1 + 4));
	mock_card_params(4, 8, 1, 2);
}

/* ---- CMD9 ---- */
static void capacity(void)
{
	mock_card_params(200, 8, 1, 2);
	errors_clear();
	check("MMC_GetCapacity (CMD9, token delay 200)", MMC_GetCapacity(), SECTORS);
	check("... no fatal error", ErrorFatal, 0);
	mock_card_params(4, 8, 1, 2);
}

/* ---- direct mode ---- */
static void dmode(const char *gold, const char *prefix)
{
	char path[1024];
	char *g;
	FILE *f;

	mock_card_params(4, 8, 1, 2);
	errors_clear();
	trace_mark();
	check("MMC_Read(513, NULL): direct mode", MMC_Read(513, NULL), 1);
	snprintf(path, sizeof path, "%s_dmode.txt", prefix);
	f = fopen(path, "w");
	if (!f || fputs(trace_since(), f) < 0 || fclose(f)) { check("write the dmode trace", 0, 1); return; }
	snprintf(path, sizeof path, "%s/dmode.txt", gold);
	g = slurp(path);
	check_str("the direct-mode trace = gold/dmode.txt", trace_since(), g);
	free(g);
	check("... no fatal error", ErrorFatal, 0);
}

/* ---- the model: CMD0 ends an application command ---- */
static unsigned char cmd(unsigned char c, unsigned arg)
{
	unsigned char r = 0xFF;
	SPI(0xFF);
	SPI(c);
	SPI(arg >> 24); SPI(arg >> 16); SPI(arg >> 8); SPI(arg);
	SPI(0x95);
	for (int i = 0; i < 16 && r == 0xFF; i++) r = SPI(0xFF);
	return r;
}
static void model_app_cmd(void)
{
	EnableCard();
	check("model: CMD0", cmd(CMD0, 0), 0x01);
	check("model: CMD55", cmd(CMD55, 0), 0x01);
	check("model: CMD0 after CMD55", cmd(CMD0, 0), 0x01);
	check("model: then CMD41 is plain CMD41 (illegal: 05)", cmd(CMD41, 1u << 30), 0x05);
	DisableCard();
}

int main(int argc, char **argv)
{
	char img[1024];
	setvbuf(stdout, NULL, _IOLBF, 0);	/* every line out before a sanitizer abort */
	if (argc < 3) { say("usage: mmc_test <gold dir> <out prefix>\n"); return 2; }
	snprintf(img, sizeof img, "%s.img", argv[2]);
	make_image(img);

	/* a section that fails ends the run: a later one may wait on a broken card */
	init_sequence(img, argv[1]);
	if (!fails) {
		slow_card_clock();
		read_delay(0);
		read_delay(4);
		read_delay(200);
		read_multiple(4, 3);
		read_multiple(200, 2);
		write_busy(8);
		write_busy(2000);
		capacity();
		dmode(argv[1], argv[2]);
	}
	if (!fails) timeouts();
	if (!fails) model_app_cmd();
	say("\n%d cases: %d failed\n", cases, fails);
	if (fails) { say("mmc_test FAIL\n"); return 1; }
	remove(img);
	say("mmc_test PASS\n");
	return 0;
}

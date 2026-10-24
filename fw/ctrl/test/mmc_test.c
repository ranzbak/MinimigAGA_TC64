/* mmc_test: the real mmc.c, since findings/sdcard-engine Task 10 sd_sync()
 * wrappers over sdproto.c, the SD card peripheral driver sdc.c and the real
 * arch/irq.c, on the mock peripheral and card (mock_sdc.c, mock_hw.c).
 *   mmc_test <gold dir> <out prefix>
 * The card image is made here (<out prefix>.img: byte i of sector n =
 * (37 n + 11 i + (n >> 8)) mod 256).
 *   - MMC_Init on the SDHC model: the card's command log up to the first
 *     CMD58 equals gold/mmc_init_cmds.txt (the SD model's log of the L2 boot
 *     run; sim/l3/gold/mmc_init_rv.txt holds the same lines), then CMD59(1)
 *     (CRC on) and CMD9; the CSD in CSDData; the peripheral at div 2 with
 *     CS off; nothing on cfide's SPI (no SPEED write, no card frame)
 *   - MMC_Read with token delay 0, 4, 200 bytes, MMC_ReadMultiple (+ CMD12),
 *     MMC_Write with busy 8 and 2000 bytes, MMC_WriteMultiple (CMD25),
 *     MMC_GetCapacity (CMD9): data against the image and the card memory
 *   - MMC_Read(lba, NULL): the block into the Gayle FIFO of ide_port (the
 *     mock bridge), no direct-mode frame (cs 42) on cfide's SPI
 *   - the bounds, in peripheral time (the TIMER standing still: time moves
 *     only with the peripheral's bytes and waits): a card that does not
 *     answer (4 R1 waits of T_NCR, then CMD13's), one that sends no data
 *     token (4 token waits of T_TOKEN, then CMD13 answers; MMC_Read and
 *     MMC_GetCSD; the init before the next call fails at its CMD9), one
 *     whose busy
 *     never ends (4 busy waits of T_BUSY): each call returns 0 within its
 *     bound, MMCErr says why, ERROR_SDCARD is set, nothing is fatal
 *   - no card at all: every MMC_* returns 0 at once, MMC_GetCapacity 0
 *   - the model: CMD55, CMD0, CMD41 is a plain CMD41 (sd_spi_model.v's case)
 * The bounds are literals here (16, 1732, 6926 units of 16384 clk_114,
 * design.md section 11), not taken from sdproto.c, so that a changed bound
 * shows. */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "errors.h"
#include "hardware.h"
#include "mmc.h"
#include "sdproto.h"
#include "mock_hw.h"

/* what mmc.c needs from the rest of the firmware */
int ErrorMask, ErrorFatal;
struct Error Errors[ERROR_MAX + 1];

#define SECTORS   16384		/* 8 MB card, C_SIZE 15 */
#define IMG_SECTORS 1024	/* the pattern; the rest of the card is 0 */

/* the bounds (design.md section 11), TIMEOUT units of 16384 cycles */
#define UNIT     16384ULL
#define B_NCR    16
#define B_TOKEN  1732
#define B_BUSY   6926

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

static int count_str(const char *hay, const char *needle)
{
	int n = 0;
	for (const char *p = hay; (p = strstr(p, needle)); p++) n++;
	return n;
}

/* ---- MMC_Init ---- */
static void init_sequence(const char *img, const char *gold)
{
	char path[1024];
	char *g;
	const char *log, *c58;
	struct mock_sdc_peek p;

	mock_reset();
	if (!check("card image loads", mock_card_load(img, SECTORS), 0)) return;
	CardType = 0;
	errors_clear();
	check("MMC_Init on the SDHC model", MMC_Init(), CARDTYPE_SDHC);
	check("CardType", CardType, CARDTYPE_SDHC);
	snprintf(path, sizeof path, "%s/mmc_init_cmds.txt", gold);
	g = gold_lines(path);
	log = mock_card_log();
	c58 = strstr(log, "CMD58 ");
	if (check("CMD58 in the card's log", c58 != NULL, 1)) {
		size_t n = (size_t)(strchr(c58, '\n') + 1 - log);
		char *head = strndup(log, n);
		check_str("the card's commands up to CMD58 = gold/mmc_init_cmds.txt (L2 boot run)", head, g);
		check_str("then CRC on (CMD59 1) and the CSD (CMD9)", log + n, "CMD59 arg=00000001\nCMD9 arg=00000000\n");
		free(head);
	}
	free(g);
	check("the card checks CRCs", mock_card_crc_on(), 1);
	mock_sdc_peek(&p);
	check("the peripheral at div 2 (18.9 MHz), CS off", p.div == 2 && !p.cs, 1);
	check_str("cfide's SPI: no SPEED write", mock_spi_speed_log(), "");
	check_str("cfide's SPI: no frame at all", mock_trace(), "");
	check("CSDData: CSD v2.0", CSDData[0], 0x40);
	check("CSDData: C_SIZE", CSDData[8] << 8 | CSDData[9], SECTORS / 1024 - 1);
	check("no error", ErrorMask, 0);
}

/* ---- MMC_Read, token delay ---- */
static void read_delay(int dly)
{
	unsigned char buf[512];
	char what[96];
	unsigned lba = 100 + (unsigned)dly;

	mock_card_params(dly, 8, 1, 2);
	errors_clear();
	snprintf(what, sizeof what, "MMC_Read lba %u, token delay %d", lba, dly);
	check(what, MMC_Read(lba, buf), 1);
	check("... == the image", sector_is_pattern(buf, lba), 1);
	check("... MMCErr", MMCErr, SD_OK);
	check("... no error", ErrorMask, 0);
}

/* ---- MMC_ReadMultiple ---- */
static void read_multiple(int dly, unsigned count)
{
	unsigned char buf[4 * 512];
	char what[96], want[96];
	unsigned lba = 300 + (unsigned)dly;
	int ok = 1;

	mock_card_params(dly, 8, 1, 2);
	errors_clear();
	snprintf(what, sizeof what, "MMC_ReadMultiple lba %u x %u, token delay %d", lba, count, dly);
	check(what, MMC_ReadMultiple(lba, buf, count), 1);
	for (unsigned k = 0; k < count; k++) ok &= sector_is_pattern(buf + 512 * k, lba + k);
	check("... == the image", ok, 1);
	snprintf(want, sizeof want, "CMD18 arg=%08x\nCMD12 arg=00000000\n", lba);
	check("... CMD18 then CMD12", strstr(mock_card_log(), want) != NULL, 1);
	check("... no error", ErrorMask, 0);
}

/* ---- MMC_Write / MMC_WriteMultiple, busy ---- */
static void write_busy(int busy, unsigned count)
{
	unsigned char buf[3 * 512], back[3 * 512];
	char what[96];
	unsigned lba = 2000 + (unsigned)busy + count;

	for (unsigned i = 0; i < sizeof buf; i++) buf[i] = (unsigned char)(i * 5 + busy + (i >> 9));
	mock_card_params(4, busy, 1, 2);
	errors_clear();
	snprintf(what, sizeof what, "MMC_Write%s lba %u x %u, busy %d bytes", count > 1 ? "Multiple" : "", lba, count, busy);
	check(what, count > 1 ? MMC_WriteMultiple(lba, buf, count) : MMC_Write(lba, buf), 1);
	check("... the command", count_str(mock_card_log(), count > 1 ? "CMD25 arg" : "CMD24 arg") > 0, 1);
	for (unsigned k = 0; k < count; k++)
		check("... in the card memory", memcmp(mock_card_sector(lba + k), buf + 512 * k, 512), 0);
	check("... read back", MMC_ReadMultiple(lba, back, count), 1);
	check("... equal", memcmp(back, buf, 512 * count), 0);
	check("... no error", ErrorMask, 0);
}

/* ---- CMD9 ---- */
static void capacity(void)
{
	mock_card_params(200, 8, 1, 2);
	errors_clear();
	check("MMC_GetCapacity (CMD9, token delay 200)", MMC_GetCapacity(), SECTORS);
	check("... no error", ErrorMask, 0);
	mock_card_params(4, 8, 1, 2);
}

/* ---- MMC_Read(lba, NULL): into Gayle ---- */
static void to_gayle(void)
{
	size_t n0, n1;
	const unsigned char *g;
	errors_clear();
	ide_port = 1;
	check("MMC_Read(513, NULL) into Gayle port 1", MMC_Read(513, NULL), 1);
	g = mock_gayle_into(1, &n1);
	check("... 512 bytes there", (long)n1, 512);
	check("... the block", n1 == 512 && sector_is_pattern(g, 513), 1);
	mock_gayle_into(0, &n0);
	check("... none into port 0", (long)n0, 0);
	ide_port = 0;
	check("MMC_ReadMultiple(514, NULL, 2) into Gayle port 0", MMC_ReadMultiple(514, NULL, 2), 1);
	g = mock_gayle_into(0, &n0);
	check("... 1024 bytes there", (long)n0, 1024);
	check("... the blocks", n0 == 1024 && sector_is_pattern(g, 514) && sector_is_pattern(g + 512, 515), 1);
	check("... no direct-mode transfer on cfide's SPI", mock_dmode_blocks(), 0);
	check("... nothing on cfide's SPI", mock_frames(), 0);
}

/* ---- the bounds ---- */
/* an MMC_* call that fails: returns 0 with MMCErr `err`, ERROR_SDCARD set,
   not fatal, in [lo, lo + 3 units] cycles of peripheral time: the waits'
   bounds plus the bytes around them (commands, the block, at most 33,040
   cycles here), less than the 4 units that one unit more on each of the 4
   waits adds */
static void bound(const char *what, int got, int err, unsigned long long t0, unsigned long long lo)
{
	char w[160];
	unsigned long long dt = mock_now() - t0, slack = 3 * UNIT;
	snprintf(w, sizeof w, "%s: returns 0", what);
	check(w, got, 0);
	snprintf(w, sizeof w, "%s: MMCErr", what);
	check(w, MMCErr, err);
	snprintf(w, sizeof w, "%s: ERROR_SDCARD set, not fatal", what);
	check(w, ((ErrorMask >> ERROR_SDCARD) & 1) && !ErrorFatal, 1);
	snprintf(w, sizeof w, "%s: ended after %llu cycles, in [%llu, %llu]", what, dt, lo, lo + slack);
	check(w, dt >= lo && dt <= lo + slack, 1);
}

/* a good read first: the card initialised (an init would add its 400 kHz
   bytes to the time of the call that needs it) */
static void ready(void)
{
	unsigned char buf[512];
	mock_card_params(4, 8, 1, 2);
	errors_clear();
	check("ready: MMC_Read ok", MMC_Read(9, buf), 1);
	errors_clear();
}

static void timeouts(void)
{
	unsigned char buf[512];
	unsigned long long t0;

	mock_timer_step(0);		/* time moves with the peripheral only */

	/* no answer at all: 4 R1 waits (1 + 3 retries), the CMD13 probe's */
	ready();
	mock_card_remove();
	errors_clear();
	t0 = mock_now();
	bound("no answer: MMC_Read", MMC_Read(10, buf), SD_E_GONE, t0, 5 * B_NCR * UNIT);
	mock_card_insert();
	errors_clear();
	check("card back: MMC_Read ok (initialised again)", MMC_Read(10, buf), 1);
	check("... the data", sector_is_pattern(buf, 10), 1);

	/* no data token: 4 token waits, CMD13 answers */
	ready();
	mock_card_params(-1, 8, 1, 2);
	errors_clear();
	t0 = mock_now();
	bound("no token: MMC_Read", MMC_Read(11, buf), SD_E_RETRIES, t0, 4 * B_TOKEN * UNIT);
	ready();
	mock_card_params(-1, 8, 1, 2);
	t0 = mock_now();
	bound("no token: MMC_GetCSD", MMC_GetCSD(), SD_E_RETRIES, t0, 4 * B_TOKEN * UNIT);
	/* the card is initialised again first, whose CMD9 meets the same card */
	check("no token: MMC_GetCapacity 0", MMC_GetCapacity(), 0);
	check("no token: ... the init failed at its CMD9", MMCErr, SD_E_NOCARD);

	/* busy for ever: 4 busy waits, then CMD13 (answered by the busy 00) */
	ready();
	mock_card_params(4, -1, 1, 2);
	memset(buf, 0xA5, sizeof buf);
	errors_clear();
	t0 = mock_now();
	bound("busy for ever: MMC_Write", MMC_Write(20, buf), SD_E_RETRIES, t0, 4 * B_BUSY * UNIT);
	mock_card_params(4, 8, 1, 2);

	/* the card works again: initialised again on the next call */
	errors_clear();
	check("after the errors: MMC_Read ok", MMC_Read(12, buf), 1);
	check("... the data", sector_is_pattern(buf, 12), 1);

	/* no card at all (the card-detect pin says so): 0 at once */
	mock_sdc_pull_card();
	mock_run(2000000);		/* the debounce */
	errors_clear();
	t0 = mock_now();
	check("no card: MMC_Read 0", MMC_Read(12, buf), 0);
	check("no card: MMC_Write 0", MMC_Write(12, buf), 0);
	check("no card: MMC_GetCapacity 0", MMC_GetCapacity(), 0);
	check("no card: MMCErr", MMCErr, SD_E_NOCARD);
	check("no card: not fatal", ErrorFatal, 0);
	check("no card: within 1 ms", mock_now() - t0 < 113460, 1);
	check("no card: MMC_Init 0", MMC_Init(), CARDTYPE_NONE);
	mock_timer_step(1);
}

/* ---- the model: CMD0 ends an application command (cfide's SPI by hand) ---- */
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
	mock_reset();
	mock_card_new(64);
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
		read_delay(0);
		read_delay(4);
		read_delay(200);
		read_multiple(4, 3);
		read_multiple(200, 2);
		write_busy(8, 1);
		write_busy(2000, 1);
		write_busy(8, 3);
		capacity();
		to_gayle();
	}
	if (!fails) timeouts();
	if (!fails) model_app_cmd();
	say("\n%d cases: %d failed\n", cases, fails);
	if (fails) { say("mmc_test FAIL\n"); return 1; }
	remove(img);
	say("mmc_test PASS\n");
	return 0;
}

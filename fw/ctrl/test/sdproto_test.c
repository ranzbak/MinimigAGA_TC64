/* sdproto_test: the SD protocol (../sdproto.c, findings/sdcard-engine plan
 * Task 10) on the Task 9 driver (../sdc.c) and the mock peripheral and card
 * (mock_sdc.c: rtl/host/sdcard_spi.v's header contract; mock_hw.c:
 * sim/common/sd_spi_model.v's Task 4 card), with the real interrupt
 * dispatcher (../arch/irq.c).
 *   make -C fw/ctrl/test run-sdproto_test
 * The plan's cases (step 1): init_crc_on, read_ok, read_crc_retry,
 * read_crc_exhaust, write_reject_retry, write_fail_0D, cmd25_acmd22,
 * timeout_cmd13_gone, busy_500ms, token_100ms, one_op_at_a_time; and
 * multi-block reads (CMD18 + CMD12, a CRC failure inside the run: CMD12,
 * then CMD18 from the failed block), the to_gayle form (RX_TO_GAYLE per
 * block, port bit, an abandoned command: SD_E_GAYLE, the card stopped), a
 * command CRC error (R1 08) once and four times (CMD13 answers:
 * SD_E_RETRIES), a single-block write rejected five times (the sector
 * untouched), card gone in the middle of an op and the re-init after it,
 * the CSD op, bad ops.
 * Expected values come from the SD spec and the retry table (design 5.1),
 * the card data from the test's own pattern; the bytes on the wire from
 * mock_sdc_wire(), the card's commands from mock_card_log().  The TIMER
 * runs at the mock's default (one count, 5.8 ms, per read): sdc_wait's
 * polling lets the peripheral run. */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "hardware.h"
#include "irq.h"
#include "sdc.h"
#include "sdproto.h"
#include "mmc.h"
#include "mock_hw.h"

/* the firmware's printf is rvlibc.c's (to the mock UART): this program
   reports with vfprintf(stdout) */
static void say(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void say(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stdout, fmt, ap);
	va_end(ap);
}

static int fails, cases;
static void check(const char *what, long got, long want)
{
	cases++;
	if (got != want) {
		say("FAIL %s: got %ld (0x%lx), want %ld (0x%lx)\n", what, got, (unsigned long)got,
		       want, (unsigned long)want);
		fails++;
	} else
		say("ok   %s = %ld\n", what, got);
}
static void check_has(const char *what, const char *hay, const char *needle)
{
	cases++;
	if (!strstr(hay, needle)) {
		say("FAIL %s: \"%s\" not in \"%.600s\"\n", what, needle, hay);
		fails++;
	} else
		say("ok   %s\n", what);
}
static void check_not(const char *what, const char *hay, const char *needle)
{
	cases++;
	if (strstr(hay, needle)) {
		say("FAIL %s: \"%s\" found\n", what, needle);
		fails++;
	} else
		say("ok   %s\n", what);
}

/* ---- the card ---- */
#define SECTORS 16384
static unsigned char pat(unsigned lba, unsigned i) { return (unsigned char)(lba * 37 + i * 11 + (lba >> 8) + 5); }
static void card(void)
{
	mock_reset();
	mock_card_new(SECTORS);
	for (unsigned l = 0; l < 2048; l++) {
		unsigned char *s = mock_card_wsector(l);
		for (unsigned i = 0; i < 512; i++) s[i] = pat(l, i);
	}
	memset(sd_err_count, 0, sizeof sd_err_count);
	sd_sck_step = 0;	/* the firmware's power-on value */
	sd_forget();		/* a new card for each case: its first init */
}
static int is_pat(const unsigned char *b, unsigned lba)
{
	for (unsigned i = 0; i < 512; i++)
		if (b[i] != pat(lba, i)) return 0;
	return 1;
}
static int count_str(const char *hay, const char *needle)
{
	int n = 0;
	for (const char *p = hay; (p = strstr(p, needle)); p++) n++;
	return n;
}
static unsigned div_now(void)
{
	struct mock_sdc_peek p;
	mock_sdc_peek(&p);
	return p.div;
}
static unsigned errs(void)
{
	unsigned n = 0;
	for (int r = 0; r < SD_ROWS; r++) n += sd_err_count[r];
	return n;
}
/* the bytes sent with CS asserted, from mock_sdc_wire() */
static unsigned char *wire_out(size_t *n)
{
	const char *w = mock_sdc_wire();
	size_t cap = strlen(w) / 3 + 16, k = 0;
	unsigned char *o = malloc(cap);
	for (const char *l = w; *l; ) {
		const char *e = strchr(l, '\n');
		if (!e) break;
		if (!strncmp(l, "sd ", 3)) {
			const char *p = l + 2;
			unsigned v;
			int used;
			while (p < e && sscanf(p, " %2x%n", &v, &used) == 1 && p[1] != '/') {
				o[k++] = (unsigned char)v;
				p += used;
			}
		}
		l = e + 1;
	}
	*n = k;
	return o;
}
static long last_at(const unsigned char *h, size_t hn, const unsigned char *nd, size_t nn)
{
	long at = -1;
	for (size_t i = 0; i + nn <= hn; i++)
		if (!memcmp(h + i, nd, nn)) at = (long)i;
	return at;
}
static int occurs(const unsigned char *h, size_t hn, const unsigned char *nd, size_t nn)
{
	int c = 0;
	for (size_t i = 0; i + nn <= hn; i++)
		if (!memcmp(h + i, nd, nn)) c++;
	return c;
}

/* SDPROTO_UART=1: the firmware's UART text of some cases on stdout */
static void uart_dump(const char *what)
{
	if (getenv("SDPROTO_UART"))
		say("--- UART after %s\n%s---\n", what, mock_uart());
}

static int init(void)
{
	int t = sd_init();
	if (t != CARDTYPE_SDHC) { say("FAIL sd_init: %d\n", t); fails++; cases++; }
	return t == CARDTYPE_SDHC;
}
static int rd(unsigned lba, unsigned n, unsigned char *buf)
{
	sd_op op = { 0 };
	op.lba = lba; op.count = n; op.buf = buf; op.kind = SD_READ;
	return sd_sync(&op);
}
static int wr(unsigned lba, unsigned n, unsigned char *buf, int *done)
{
	sd_op op = { 0 };
	int e;
	op.lba = lba; op.count = n; op.buf = buf; op.kind = SD_WRITE;
	e = sd_sync(&op);
	if (done) *done = op.done_blocks;
	return e;
}
static void wdata(unsigned char *b, unsigned n, unsigned seed)
{
	for (unsigned k = 0; k < n * 512; k++) b[k] = (unsigned char)(k * 7 + seed * 13 + (k >> 9));
}

/* ---- the plan's cases ---- */
static void t_init_crc_on(void)
{
	card();
	mock_uart_clear();
	check("init_crc_on: sd_init = SDHC", sd_init(), CARDTYPE_SDHC);
	check_has("init_crc_on: CMD0", mock_card_log(), "CMD0 arg=00000000\nCMD8 arg=000001aa\nCMD55 arg=00000000\nACMD41 arg=40000000\n");
	check_has("init_crc_on: CMD58 then CMD59(1), CMD10 (CID), CMD9 (CSD)", mock_card_log(),
	          "CMD58 arg=00000000\nCMD59 arg=00000001\nCMD10 arg=00000000\nCMD9 arg=00000000\n");
	check("init_crc_on: the card checks CRCs", mock_card_crc_on(), 1);
	check("init_crc_on: data rate div 2 (18.9 MHz)", div_now(), 2);
	check("init_crc_on: sd_sck_div", sd_sck_div(), 2);
	check("init_crc_on: CS off after init", ({ struct mock_sdc_peek p; mock_sdc_peek(&p); (long)p.cs; }), 0);
	check("init_crc_on: no error", errs(), 0);
	check_has("init_crc_on: UART: OCR and type", mock_uart(), "SD init: OCR c0ff8000, type 3");
	check_has("init_crc_on: UART: SCK", mock_uart(), "SD init: SCK div 2");
	check("init_crc_on: sd_card_type", sd_card_type(), CARDTYPE_SDHC);
	uart_dump("init_crc_on");
	/* the CSD the init read (CSD v2.0, C_SIZE = sectors / 1024 - 1) */
	check("init_crc_on: CSD byte 0 (v2.0)", sd_csd[0], 0x40);
	check("init_crc_on: CSD C_SIZE", sd_csd[9] | sd_csd[8] << 8, SECTORS / 1024 - 1);
}

static void t_read_ok(void)
{
	unsigned char b[512];
	card(); if (!init()) return;
	memset(b, 0, sizeof b);
	check("read_ok: sd_sync", rd(77, 1, b), SD_OK);
	check("read_ok: data", is_pat(b, 77), 1);
	check_has("read_ok: CMD17", mock_card_log(), "CMD17 arg=0000004d\n");
	check("read_ok: no error", errs(), 0);
}

static void t_read_crc_retry(void)
{
	unsigned char b[512];
	card(); if (!init()) return;
	mock_uart_clear();
	mock_card_error(MOCK_ERR_RDCRC, 1, 1);
	check("read_crc_retry: sd_sync", rd(300, 1, b), SD_OK);
	check("read_crc_retry: data right", is_pat(b, 300), 1);
	check("read_crc_retry: one read CRC error", sd_err_count[SD_ROW_RDCRC], 1);
	check("read_crc_retry: no other", errs(), 1);
	check("read_crc_retry: two CMD17", count_str(mock_card_log(), "CMD17 arg=0000012c"), 2);
	check_has("read_crc_retry: UART line", mock_uart(), "SD: read CRC, row 1, retry 1 of 4, lba 300");
	check("read_crc_retry: SCK unchanged", div_now(), 2);
}

static void t_read_crc_exhaust(void)
{
	unsigned char b[512];
	const char *u, *r2, *sck, *r3, *r4;
	card(); if (!init()) return;
	mock_uart_clear();
	memset(b, 0xA5, sizeof b);
	mock_card_error(MOCK_ERR_RDCRC, 1, 5);
	check("read_crc_exhaust: err", rd(301, 1, b), SD_E_RETRIES);
	check("read_crc_exhaust: buf untouched (no bad byte reaches the firmware)", b[0] == 0xA5 && b[511] == 0xA5, 1);
	check("read_crc_exhaust: 5 read CRC errors (1 + 4 retries)", sd_err_count[SD_ROW_RDCRC], 5);
	check("read_crc_exhaust: 5 CMD17", count_str(mock_card_log(), "CMD17 arg=0000012d"), 5);
	check("read_crc_exhaust: SCK one step slower", sd_sck_div(), sd_sck_divs[1]);
	check("read_crc_exhaust: the step is div 3", sd_sck_divs[1], 3);
	u = mock_uart();
	r2 = strstr(u, "retry 2 of 4");
	sck = strstr(u, "SD: SCK one step slower, div 3");
	r3 = strstr(u, "retry 3 of 4");
	r4 = strstr(u, "retry 4 of 4");
	check("read_crc_exhaust: the SCK line with retry 3 (after its line, before retry 4)", r2 && r3 && sck && r4 && r2 < r3 && r3 < sck && sck < r4, 1);
	check("read_crc_exhaust: one step only", count_str(u, "SCK one step slower"), 1);
	check_has("read_crc_exhaust: UART op line", u, "SD: op failed, err 1, lba 301, 0 of 1 blocks");
	uart_dump("read_crc_exhaust");
	/* the next op: the card is initialised again, at the lowered SCK */
	check("read_crc_exhaust: next read ok", rd(302, 1, b), SD_OK);
	check("read_crc_exhaust: next data", is_pat(b, 302), 1);
	check("read_crc_exhaust: SCK stays lowered", div_now(), 3);
	check("read_crc_exhaust: re-initialised (a second CMD0)", count_str(mock_card_log(), "CMD0 arg"), 2);
}

static void t_write_reject_retry(void)
{
	unsigned char b[512], blk[515];
	unsigned char *w;
	size_t n;
	unsigned c;
	card(); if (!init()) return;
	wdata(b, 1, 1);
	mock_card_error(MOCK_ERR_WRREJ, 1, 1);
	mock_sdc_wire_on(1);
	check("write_reject_retry: sd_sync", wr(500, 1, b, NULL), SD_OK);
	check("write_reject_retry: on the card", memcmp(mock_card_sector(500), b, 512), 0);
	check("write_reject_retry: one 0B", sd_err_count[SD_ROW_WRCRC], 1);
	check("write_reject_retry: no other", errs(), 1);
	check("write_reject_retry: two CMD24", count_str(mock_card_log(), "CMD24 arg=000001f4"), 2);
	/* the identical resend: token, data, CRC16 on the wire twice */
	c = 0;
	for (unsigned k = 0; k < 512; k++)
		for (int i = 7; i >= 0; i--)
			c = ((c << 1) & 0xFFFF) ^ ((((c >> 15) ^ (b[k] >> i)) & 1) ? 0x1021 : 0);
	blk[0] = 0xFE; memcpy(blk + 1, b, 512); blk[513] = c >> 8; blk[514] = c & 0xFF;
	w = wire_out(&n);
	check("write_reject_retry: the block (token + data + CRC16) sent twice", occurs(w, n, blk, 515), 2);
	free(w);
	mock_sdc_wire_on(0);
}

static void t_write_fail_0D(void)
{
	unsigned char b[512];
	int done = -1;
	card(); if (!init()) return;
	wdata(b, 1, 2);
	mock_card_error(MOCK_ERR_WRFAIL, 1, 1);
	check("write_fail_0D: err", wr(600, 1, b, &done), SD_E_WRFAIL);
	check("write_fail_0D: done_blocks", done, 0);
	check("write_fail_0D: not on the card", is_pat(mock_card_sector(600), 600), 1);
	check("write_fail_0D: one 0D", sd_err_count[SD_ROW_WRFAIL], 1);
	check("write_fail_0D: no other", errs(), 1);
	check("write_fail_0D: no retry (one CMD24)", count_str(mock_card_log(), "CMD24 arg=00000258"), 1);
	/* the card is still in use: no re-init */
	check("write_fail_0D: next read ok", rd(600, 1, b), SD_OK);
	check("write_fail_0D: no second CMD0", count_str(mock_card_log(), "CMD0 arg"), 1);
}

static void t_cmd25_acmd22(void)
{
	unsigned char b[5 * 512];
	int done = -1, ok = 1;
	card(); if (!init()) return;
	wdata(b, 5, 3);
	mock_card_error(MOCK_ERR_WRREJ, 3, 1);
	check("cmd25_acmd22: sd_sync", wr(700, 5, b, &done), SD_OK);
	check("cmd25_acmd22: done_blocks", done, 5);
	for (unsigned k = 0; k < 5; k++) ok &= !memcmp(mock_card_sector(700 + k), b + 512 * k, 512);
	check("cmd25_acmd22: card content right", ok, 1);
	check("cmd25_acmd22: other sectors untouched", is_pat(mock_card_sector(699), 699) && is_pat(mock_card_sector(705), 705), 1);
	check_has("cmd25_acmd22: CMD25, stop, ACMD22, CMD25 at the 3rd", mock_card_log(),
	          "CMD25 arg=000002bc\nCMD55 arg=00000000\nACMD22 arg=00000000\nCMD25 arg=000002be\n");
	check("cmd25_acmd22: one 0B", sd_err_count[SD_ROW_WRCRC], 1);
	check("cmd25_acmd22: no other", errs(), 1);
	check("cmd25_acmd22: the card's last CMD25 wrote 3", mock_card_wr_ok(), 3);
	uart_dump("cmd25_acmd22");
}

static void t_timeout_cmd13_gone(void)
{
	unsigned char b[512], *w;
	static const unsigned char cmd13[] = { 0x4D, 0, 0, 0, 0 }, cmd17[] = { 0x51, 0, 0, 0, 10 };
	size_t n;
	card(); if (!init()) return;
	mock_card_remove();		/* no answer, the card-detect pin still says present */
	mock_sdc_wire_on(1);
	check("timeout_cmd13_gone: err", rd(10, 1, b), SD_E_GONE);
	check("timeout_cmd13_gone: R1 timeouts 4 (1 + 3 retries) + CMD13's", sd_err_count[SD_ROW_TIMEOUT], 5);
	check("timeout_cmd13_gone: no other", errs(), 5);
	w = wire_out(&n);
	check("timeout_cmd13_gone: CMD13 sent once", occurs(w, n, cmd13, 5), 1);
	check("timeout_cmd13_gone: four CMD17", occurs(w, n, cmd17, 5), 4);
	check("timeout_cmd13_gone: CMD13 after the last CMD17", last_at(w, n, cmd13, 5) > last_at(w, n, cmd17, 5), 1);
	free(w);
	mock_sdc_wire_on(0);
	check("timeout_cmd13_gone: card to be initialised again", sd_card_type(), 0);
	check_has("timeout_cmd13_gone: the probe's line", mock_uart(), "SD: CMD13 probe: no answer, lba 10");
	mock_card_insert();
	check("timeout_cmd13_gone: after the card is back: read ok (re-init)", rd(10, 1, b), SD_OK);
	check("timeout_cmd13_gone: data", is_pat(b, 10), 1);
	check("timeout_cmd13_gone: CRC on again", mock_card_crc_on(), 1);
	uart_dump("timeout_cmd13_gone");
}

static void t_busy_500ms(void)
{
	unsigned char b[2 * 512];
	unsigned long busy;
	card(); if (!init()) return;
	busy = mock_sdc_bytes_for_us(500000);
	check("busy_500ms: 500 ms at div 2 in bytes", (long)busy, 1181875);
	mock_card_params(4, (int)busy, 1, 2);
	wdata(b, 2, 4);
	check("busy_500ms: CMD24 ok", wr(800, 1, b, NULL), SD_OK);
	check("busy_500ms: CMD25 ok (busy per block and after the stop token)", wr(801, 2, b, NULL), SD_OK);
	check("busy_500ms: on the card", !memcmp(mock_card_sector(800), b, 512) && !memcmp(mock_card_sector(802), b + 512, 512), 1);
	check("busy_500ms: no timeout", errs(), 0);
}

static void t_token_100ms(void)
{
	unsigned char b[512];
	sd_op op = { 0 };
	long loops = 0, moving = 0;
	unsigned long long b0;
	struct mock_sdc_peek p;
	card(); if (!init()) return;
	mock_card_params((int)mock_sdc_bytes_for_us(100000), 8, 1, 2);
	op.lba = 900; op.count = 1; op.buf = b; op.kind = SD_READ;
	check("token_100ms: submit", sd_submit(&op), 0);
	for (;;) {
		int r;
		mock_sdc_peek(&p);
		b0 = p.bytes;
		r = sd_poll();
		if (!r) break;
		loops++;
		mock_run(100000);	/* the main loop's other work: 0.88 ms */
		mock_sdc_peek(&p);
		/* the op active, the card clocked while the loop did other work */
		if (p.bytes > b0 && op.state != 0) moving++;
		if (loops > 100000) break;
	}
	check("token_100ms: no error", op.err, SD_OK);
	check("token_100ms: data", is_pat(b, 900), 1);
	check("token_100ms: no timeout", errs(), 0);
	check("token_100ms: the loop ran on (> 100 passes of 0.88 ms)", loops > 100, 1);
	check("token_100ms: the token wait went on in the peripheral during the passes (> 100)", moving > 100, 1);
	check("token_100ms: ended soon after the token (passes < 200: 176 ms)", loops < 200, 1);
	check("token_100ms: idle: sd_poll 0", sd_poll(), 0);
}

static void t_one_op(void)
{
	unsigned char a[512], c[512];
	sd_op x = { 0 }, y = { 0 };
	int n = 0;
	card(); if (!init()) return;
	x.lba = 40; x.count = 1; x.buf = a; x.kind = SD_READ;
	y.lba = 41; y.count = 1; y.buf = c; y.kind = SD_READ;
	check("one_op: first submit", sd_submit(&x), 0);
	check("one_op: second refused while the first runs", sd_submit(&y), -1);
	check("one_op: the second untouched", y.state == 0 && y.err == 0, 1);
	while (sd_poll() && n < 100000) { mock_sdc_step(); n++; }
	check("one_op: first done", x.err == SD_OK && is_pat(a, 40), 1);
	check("one_op: now the second", sd_submit(&y), 0);
	check("one_op: sd_sync of a third finishes the second first", rd(42, 1, a), SD_OK);
	check("one_op: second done", y.state == 0 && y.err == SD_OK && is_pat(c, 41), 1);
	check("one_op: third", is_pat(a, 42), 1);
}

/* ---- more ---- */
static void t_read_multi(void)
{
	unsigned char b[6 * 512];
	int ok = 1;
	card(); if (!init()) return;
	check("multi: 6 blocks", rd(1000, 6, b), SD_OK);
	for (unsigned k = 0; k < 6; k++) ok &= is_pat(b + 512 * k, 1000 + k);
	check("multi: data", ok, 1);
	check_has("multi: CMD18, CMD12", mock_card_log(), "CMD18 arg=000003e8\nCMD12 arg=00000000\n");
	/* a CRC error in the 3rd block: CMD12, CMD18 from the failed block */
	mock_card_error(MOCK_ERR_RDCRC, 9, 1);	/* blocks 1-6 above, 7, 8 good */
	memset(b, 0, sizeof b);
	check("multi crc: ok", rd(1100, 5, b), SD_OK);
	ok = 1;
	for (unsigned k = 0; k < 5; k++) ok &= is_pat(b + 512 * k, 1100 + k);
	check("multi crc: data", ok, 1);
	check_has("multi crc: re-read from the failed block", mock_card_log(),
	          "CMD18 arg=0000044c\nCMD12 arg=00000000\nCMD18 arg=0000044e\nCMD12 arg=00000000\n");
	check("multi crc: one error", sd_err_count[SD_ROW_RDCRC], 1);
}

static void t_gayle(void)
{
	size_t n;
	const unsigned char *g;
	sd_op op = { 0 };
	int ok = 1;
	card(); if (!init()) return;
	op.lba = 1200; op.count = 3; op.to_gayle = 1; op.port = 1; op.kind = SD_READ;
	check("gayle: 3 blocks to port 1", sd_sync(&op), SD_OK);
	g = mock_gayle_into(1, &n);
	check("gayle: 1536 bytes into port 1", (long)n, 1536);
	for (unsigned k = 0; k < 3 && n == 1536; k++) ok &= is_pat(g + 512 * k, 1200 + k);
	check("gayle: data", ok, 1);
	mock_gayle_into(0, &n);
	check("gayle: nothing into port 0", (long)n, 0);
	check_has("gayle: RX_TO_GAYLE 512 with bit 8", mock_sdc_log(), "CMD 0105 LEN 512\n");
	/* a CRC error: the bad block never reaches Gayle, the re-read does */
	mock_card_error(MOCK_ERR_RDCRC, 4, 1);
	op.lba = 1300; op.count = 1; op.port = 0;
	check("gayle crc: ok", sd_sync(&op), SD_OK);
	g = mock_gayle_into(0, &n);
	check("gayle crc: exactly one block into port 0", (long)n, 512);
	check("gayle crc: the good one", n == 512 && is_pat(g, 1300), 1);
	/* the Amiga abandons the command: Gayle error on the 2nd block */
	op.lba = 1400; op.count = 4; op.port = 0;
	mock_gayle_end(MOCK_GAYLE_ERR, 100);	/* armed: the next Gayle op ends with g_err after 100 words */
	check("gayle abandon: SD_E_GAYLE", sd_sync(&op), SD_E_GAYLE);
	check("gayle abandon: done_blocks 0", op.done_blocks, 0);
	check_has("gayle abandon: the card stopped (CMD12)", mock_card_log(), "CMD18 arg=00000578\nCMD12 arg=00000000\n");
	check("gayle abandon: not a card error", errs(), 1);
	check("gayle abandon: card still initialised", sd_card_type(), CARDTYPE_SDHC);
	check_not("gayle abandon: no op-failed line", mock_uart(), "err 6");
}

static void t_cmdcrc(void)
{
	unsigned char b[512];
	card(); if (!init()) return;
	mock_card_error(MOCK_ERR_CMDCRC, mock_card_commands() + 1, 1);
	check("cmdcrc: read ok", rd(50, 1, b), SD_OK);
	check("cmdcrc: data", is_pat(b, 50), 1);
	check("cmdcrc: one", sd_err_count[SD_ROW_CMDCRC], 1);
	check("cmdcrc: CMD17 twice", count_str(mock_card_log(), "CMD17 arg=00000032"), 2);
	/* four in a row: 3 retries, then CMD13 answers: SD_E_RETRIES */
	mock_card_error(MOCK_ERR_CMDCRC, mock_card_commands() + 1, 4);
	check("cmdcrc exhaust: err", rd(51, 1, b), SD_E_RETRIES);
	check("cmdcrc exhaust: 5 in all", sd_err_count[SD_ROW_CMDCRC], 5);
	check_has("cmdcrc exhaust: CMD13 after the 4th", mock_card_log(),
	          "CMD17 arg=00000033\nCMD17 arg=00000033\nCMD17 arg=00000033\nCMD17 arg=00000033\nCMD13 arg=00000000\n");
	check("cmdcrc exhaust: next read ok after re-init", rd(51, 1, b), SD_OK);
	check("cmdcrc exhaust: data", is_pat(b, 51), 1);
}

static void t_write_exhaust(void)
{
	unsigned char b[512];
	int done = -1;
	card(); if (!init()) return;
	wdata(b, 1, 5);
	mock_card_error(MOCK_ERR_WRREJ, 1, 5);
	check("write exhaust: err", wr(1500, 1, b, &done), SD_E_RETRIES);
	check("write exhaust: done 0", done, 0);
	check("write exhaust: sector untouched", is_pat(mock_card_sector(1500), 1500), 1);
	check("write exhaust: 5 rejections", sd_err_count[SD_ROW_WRCRC], 5);
	check("write exhaust: 5 CMD24", count_str(mock_card_log(), "CMD24 arg=000005dc"), 5);
	check("write exhaust: SCK lowered", sd_sck_div(), 3);
	check("write exhaust: next write ok", wr(1500, 1, b, NULL), SD_OK);
	check("write exhaust: on the card", memcmp(mock_card_sector(1500), b, 512), 0);
}

static void t_gone(void)
{
	unsigned char b[512];
	sd_op op = { 0 };
	int n = 0;
	card(); if (!init()) return;
	mock_card_params((int)mock_sdc_bytes_for_us(50000), 8, 1, 2);
	op.lba = 60; op.count = 1; op.buf = b; op.kind = SD_READ;
	memset(b, 0x5A, sizeof b);
	check("gone: submit", sd_submit(&op), 0);
	while (sd_poll() && n < 1000) {
		if (n == 5) mock_sdc_pull_card();	/* in the token wait */
		mock_run(100000);
		n++;
	}
	check("gone: SD_E_GONE", op.err, SD_E_GONE);
	check("gone: buf untouched", b[0] == 0x5A && b[511] == 0x5A, 1);
	check("gone: to be initialised", sd_card_type(), 0);
	check("gone: no card: sd_sync fails at once", rd(60, 1, b), SD_E_NOCARD);
	mock_card_insert();
	mock_sdc_cd(1);
	mock_run(2000000);		/* the debounce */
	mock_card_params(4, 8, 1, 2);
	check("gone: card back: read ok", rd(60, 1, b), SD_OK);
	check("gone: data", is_pat(b, 60), 1);
	uart_dump("gone");
}

/* Task 10 fix round 1: the card is swapped while out: another CID refuses
   all further I/O (until sd_forget, MMC_Init's), the card untouched */
static void t_cid(void)
{
	unsigned char b[512], w[512], before[512], other[16];
	card(); if (!init()) return;
	check("cid: kept at the first init", memcmp(sd_cid, "\x03SDMOCK1", 8), 0);
	/* the same card out and in: goes on (t_gone too) */
	mock_sdc_pull_card();
	mock_run(2000000);
	mock_card_insert();
	mock_sdc_cd(1);
	mock_run(2000000);
	check("cid: same card back: read ok", rd(70, 1, b), SD_OK);
	check("cid: not changed", sd_card_changed(), 0);
	/* another card */
	mock_sdc_pull_card();
	mock_run(2000000);
	memcpy(other, sd_cid, 16);
	other[9] ^= 0xFF;	/* another serial number */
	mock_card_cid(other);
	mock_card_insert();
	mock_sdc_cd(1);
	mock_run(2000000);
	memcpy(before, mock_card_sector(71), 512);
	wdata(w, 1, 7);
	check("cid: another card: read SD_E_GONE", rd(71, 1, b), SD_E_GONE);
	check("cid: changed", sd_card_changed(), 1);
	check("cid: write SD_E_GONE", wr(71, 1, w, NULL), SD_E_GONE);
	check("cid: the card untouched", memcmp(mock_card_sector(71), before, 512), 0);
	check("cid: sd_init refuses", sd_init(), 0);
	check("cid: still SD_E_GONE", rd(71, 1, b), SD_E_GONE);
	{
		unsigned c = mock_card_commands();
		rd(72, 1, b);
		check("cid: no command reaches the card", mock_card_commands(), c);
	}
	sd_forget();		/* the firmware's restart */
	check("cid: after sd_forget: init", sd_init(), CARDTYPE_SDHC);
	check("cid: the new CID kept", memcmp(sd_cid, other, 16), 0);
	check("cid: read ok", rd(71, 1, b), SD_OK);
}

/* the card reset itself (power): an R1 with the idle bit is SD_E_RESET, the
   next op initialises it again (same CID: goes on) */
static void t_card_reset(void)
{
	unsigned char b[512];
	card(); if (!init()) return;
	mock_uart_clear();
	mock_card_insert();	/* a power-on card: idle, CRC off; same memory, same CID */
	check("reset: read SD_E_RESET", rd(80, 1, b), SD_E_RESET);
	check_has("reset: UART line", mock_uart(), "SD: card in idle state (R1 05), lba 80");
	check("reset: to be initialised", sd_card_type(), 0);
	check("reset: next read ok", rd(80, 1, b), SD_OK);
	check("reset: data", is_pat(b, 80), 1);
	check("reset: CRC on again", mock_card_crc_on(), 1);
}

/* ACMD22 counts fewer than the card took: those blocks again from buf, each
   time a write retry, bounded */
static void t_acmd22_less(void)
{
	unsigned char b[5 * 512];
	int done = -1, ok = 1;
	card(); if (!init()) return;
	wdata(b, 5, 8);
	mock_card_error(MOCK_ERR_WRREJ, 3, 1);
	mock_card_acmd22_less(1, 1);	/* says 1 where 2 were written */
	check("acmd22 less: ok", wr(1700, 5, b, &done), SD_OK);
	check("acmd22 less: done 5", done, 5);
	for (unsigned k = 0; k < 5; k++) ok &= !memcmp(mock_card_sector(1700 + k), b + 512 * k, 512);
	check("acmd22 less: card content right", ok, 1);
	check_has("acmd22 less: CMD25 from the 2nd block", mock_card_log(),
	          "ACMD22 arg=00000000\nCMD25 arg=000006a5\n");
	check("acmd22 less: a write retry counted (0B + 1)", sd_err_count[SD_ROW_WRCRC], 2);
	/* a card that loses a block every time (every 2nd block 0B, ACMD22
	   one short): without the bound the rewritten blocks' 05s would reset
	   the write retries for ever */
	card(); if (!init()) return;	/* the mock's block count from 1 again */
	mock_card_wrrej_every(2);
	mock_card_acmd22_less(1, 1000);
	check("acmd22 lossy: ends SD_E_RETRIES", wr(1800, 3, b, NULL), SD_E_RETRIES);
	check("acmd22 lossy: 5 rejections + 5 losses (the 5th: retries out)", sd_err_count[SD_ROW_WRCRC], 10);
	mock_card_wrrej_every(0);
}

/* SCK at the last step: no further step, no line */
static void t_sck_floor(void)
{
	unsigned char b[512];
	card(); if (!init()) return;
	sd_sck_step = SD_SCK_STEPS - 1;
	mock_uart_clear();
	mock_card_error(MOCK_ERR_RDCRC, 1, 3);
	check("sck floor: read ok", rd(90, 1, b), SD_OK);
	check("sck floor: stays at the slowest", sd_sck_div(), sd_sck_divs[SD_SCK_STEPS - 1]);
	check_not("sck floor: no step-down line", mock_uart(), "SCK one step slower");
}

/* ---- from_gayle writes (findings/sdcard-engine Task 11a) ----
 * The Amiga's sectors come from Gayle's FIFO (the mock bridge's from[port])
 * by GAYLE_TO_TX, one block at a time, each only once it is there (ruling
 * T11-R1): the submit is the first block's go, sd_gayle_go() the next ones'
 * when sd_gayle_need() says the previous one was taken.  A run is a CMD25
 * (also of one block) ended by the stop token. */
static unsigned g_stops0;
static void g_mark(void) { g_stops0 = mock_card_stop_ends(); }
/* run op (from_gayle, set up) on the Amiga's data d: the Amiga writes
   sector k into the FIFO when the op wants it, for k < feed (then it
   stops), arming mock_gayle_end(MOCK_GAYLE_ERR, 100) for sector arm's
   GAYLE_TO_TX; stops at the end, or when parked with nothing to feed
   (returns 1 then) */
static unsigned g_fed;		/* sectors the Amiga wrote for the running op */
static int g_cont(sd_op *op, const unsigned char *d, unsigned feed, int arm)
{
	long n = 0;
	while (op->state) {
		if (sd_gayle_need(op) && g_fed < feed && g_fed < op->count) {
			if ((int)g_fed == arm) mock_gayle_end(MOCK_GAYLE_ERR, 100);
			mock_gayle_from(op->port, d + 512 * g_fed, 512);
			g_fed++;
			check("gayle wr: go accepted", sd_gayle_go(op), 0);
		}
		if (sd_gayle_parked(op) && g_fed >= feed) return 1;
		sd_poll();
		mock_sdc_step();
		if (++n > 200000) { say("FAIL gayle wr: no end\n"); fails++; return -1; }
	}
	return 0;
}
static int g_run(sd_op *op, const unsigned char *d, unsigned feed, int arm)
{
	if (arm == 0) mock_gayle_end(MOCK_GAYLE_ERR, 100);
	mock_gayle_from(op->port, d, 512);
	g_fed = 1;
	if (sd_submit(op)) return -1;
	return g_cont(op, d, feed, arm);
}
static void g_op(sd_op *op, unsigned lba, unsigned n, int port)
{
	memset(op, 0, sizeof *op);
	op->kind = SD_WRITE; op->from_gayle = 1; op->lba = lba; op->count = n; op->port = port;
}
static int on_card(unsigned lba, const unsigned char *d, unsigned n)
{
	for (unsigned k = 0; k < n; k++)
		if (memcmp(mock_card_sector(lba + k), d + 512 * k, 512)) return 0;
	return 1;
}

static void t_gayle_write(void)
{
	unsigned char d[4 * 512], b[512];
	sd_op op;
	struct mock_sdc_peek p;
	card(); if (!init()) return;
	wdata(d, 4, 21);
	/* 3 blocks from port 1 */
	g_mark();
	g_op(&op, 1900, 3, 1);
	check("gayle wr 3: ends", g_run(&op, d, 3, -1), 0);
	check("gayle wr 3: SD_OK", op.err, SD_OK);
	check("gayle wr 3: done 3", op.done_blocks, 3);
	check("gayle wr 3: on the card", on_card(1900, d, 3), 1);
	check("gayle wr 3: neighbours untouched", is_pat(mock_card_sector(1899), 1899) && is_pat(mock_card_sector(1903), 1903), 1);
	check_has("gayle wr 3: CMD25", mock_card_log(), "CMD25 arg=0000076c\n");
	check("gayle wr 3: three GAYLE_TO_TX 512 of port 1", count_str(mock_sdc_log(), "CMD 0104 LEN 512\n"), 3);
	check("gayle wr 3: each started with its sector in the FIFO (no wait for the Amiga)", mock_gayle_stalls(), 0);
	check("gayle wr 3: the stop token's busy ended", mock_card_stop_ends() - g_stops0, 1);
	check("gayle wr 3: the card idle", mock_card_idle(), 1);
	check("gayle wr 3: all of the Amiga's bytes taken", (long)mock_gayle_from_left(1), 0);
	/* one block: a CMD25 too (the stop token ends it whatever happens) */
	g_mark();
	g_op(&op, 1910, 1, 0);
	check("gayle wr 1: SD_OK", g_run(&op, d + 512, 1, -1) == 0 && op.err == SD_OK, 1);
	check("gayle wr 1: on the card", on_card(1910, d + 512, 1), 1);
	check_has("gayle wr 1: CMD25, not CMD24", mock_card_log(), "CMD25 arg=00000776\n");
	check("gayle wr 1: no CMD24", count_str(mock_card_log(), "CMD24"), 0);
	check("gayle wr 1: the stop token's busy ended", mock_card_stop_ends() - g_stops0, 1);
	/* the Amiga stops after the 1st of 3: parked, no peripheral op; closed:
	   the stop token, SD_OK with 1 block */
	g_mark();
	g_op(&op, 1920, 3, 0);
	check("gayle park: parked", g_run(&op, d, 1, -1), 1);
	mock_sdc_peek(&p);
	check("gayle park: no peripheral op while parked", p.busy, 0);
	check("gayle park: the 1st block on the card", on_card(1920, d, 1), 1);
	check("gayle park: needs the 2nd block", sd_gayle_need(&op), 1);
	sd_close(&op);
	check("gayle park: closed: ends", g_cont(&op, d, 1, -1), 0);
	check("gayle park: SD_OK", op.err, SD_OK);
	check("gayle park: done 1", op.done_blocks, 1);
	check("gayle park: the 2nd untouched", is_pat(mock_card_sector(1921), 1921), 1);
	check("gayle park: the stop token's busy ended", mock_card_stop_ends() - g_stops0, 1);
	check("gayle park: the card idle", mock_card_idle(), 1);
	/* parked: a CPU-side card user (sd_sync) closes the run first */
	g_op(&op, 1930, 3, 0);
	check("gayle park sync: parked", g_run(&op, d, 2, -1), 1);
	check("gayle park sync: sd_sync of a read", rd(10, 1, b), SD_OK);
	check("gayle park sync: its data", is_pat(b, 10), 1);
	check("gayle park sync: the run ended SD_OK with 2", op.state == 0 && op.err == SD_OK && op.done_blocks == 2, 1);
	check("gayle park sync: 2 blocks on the card", on_card(1930, d, 2) && is_pat(mock_card_sector(1932), 1932), 1);
	/* the Amiga abandons on the 2nd block (g_err after 100 words): no
	   partial block, the stop token, SD_E_GAYLE, no card error */
	g_mark();
	mock_uart_clear();
	g_op(&op, 1940, 3, 0);
	check("gayle abandon 2nd: ends", g_run(&op, d, 3, 1), 0);
	check("gayle abandon 2nd: SD_E_GAYLE", op.err, SD_E_GAYLE);
	check("gayle abandon 2nd: done 1", op.done_blocks, 1);
	check("gayle abandon 2nd: the 1st on the card", on_card(1940, d, 1), 1);
	check("gayle abandon 2nd: no partial block: the 2nd untouched", is_pat(mock_card_sector(1941), 1941), 1);
	check("gayle abandon 2nd: the stop token's busy ended", mock_card_stop_ends() - g_stops0, 1);
	check("gayle abandon 2nd: the card idle", mock_card_idle(), 1);
	check("gayle abandon 2nd: no card error", errs(), 0);
	check("gayle abandon 2nd: card still initialised", sd_card_type(), CARDTYPE_SDHC);
	check_not("gayle abandon 2nd: no op-failed line", mock_uart(), "op failed");
	/* ... on the 1st block: nothing written, the CMD25 ended */
	g_mark();
	g_op(&op, 1950, 2, 0);
	check("gayle abandon 1st: SD_E_GAYLE", g_run(&op, d, 2, 0) == 0 && op.err == SD_E_GAYLE, 1);
	check("gayle abandon 1st: done 0", op.done_blocks, 0);
	check("gayle abandon 1st: nothing written", is_pat(mock_card_sector(1950), 1950), 1);
	check("gayle abandon 1st: the stop token's busy ended", mock_card_stop_ends() - g_stops0, 1);
	check("gayle abandon 1st: the card idle", mock_card_idle(), 1);
	check("gayle abandon 1st: next read ok", rd(1950, 1, b) == SD_OK && is_pat(b, 1950), 1);
	/* a 0B on the 2nd block: sent again from TX (stop, ACMD22, CMD25) */
	card(); if (!init()) return;
	mock_card_error(MOCK_ERR_WRREJ, 2, 1);
	g_op(&op, 1960, 3, 0);
	check("gayle 0B: SD_OK", g_run(&op, d, 3, -1) == 0 && op.err == SD_OK, 1);
	check("gayle 0B: on the card", on_card(1960, d, 3), 1);
	check_has("gayle 0B: CMD25, ACMD22, CMD25 at the 2nd", mock_card_log(),
	          "CMD25 arg=000007a8\nCMD55 arg=00000000\nACMD22 arg=00000000\nCMD25 arg=000007a9\n");
	check("gayle 0B: one 0B", sd_err_count[SD_ROW_WRCRC], 1);
	/* ACMD22 says the card lost a block it took: Gayle's sector is gone,
	   nothing to send again: an error */
	card(); if (!init()) return;
	mock_card_error(MOCK_ERR_WRREJ, 3, 1);
	mock_card_acmd22_less(1, 1);
	g_op(&op, 1970, 4, 0);
	check("gayle lost: ends", g_run(&op, d, 4, -1), 0);
	check("gayle lost: SD_E_RETRIES", op.err, SD_E_RETRIES);
	check("gayle lost: the card idle", mock_card_idle(), 1);
	/* the card pulled while parked: SD_E_GONE without a step */
	card(); if (!init()) return;
	g_op(&op, 1980, 3, 0);
	check("gayle gone parked: parked", g_run(&op, d, 1, -1), 1);
	mock_sdc_pull_card();
	mock_run(2000000);		/* the debounce: the card-detect event */
	sd_poll();
	check("gayle gone parked: SD_E_GONE", op.state == 0 && op.err == SD_E_GONE, 1);
	check("gayle gone parked: sd idle", sd_poll(), 0);
	/* sd_gayle_busy: while a GAYLE_TO_TX runs (the bridge held) */
	card(); if (!init()) return;
	g_op(&op, 1990, 1, 1);
	mock_gayle_hold(1);
	mock_gayle_from(1, d, 512);
	check("gayle busy: submit", sd_submit(&op), 0);
	for (int k = 0; k < 1000 && !sd_gayle_busy() && op.state; k++) { sd_poll(); mock_sdc_step(); }
	check("gayle busy: during GAYLE_TO_TX", sd_gayle_busy(), 1);
	mock_gayle_hold(0);
	for (int k = 0; k < 100000 && op.state; k++) { sd_poll(); mock_sdc_step(); }
	check("gayle busy: ended SD_OK", op.err, SD_OK);
	check("gayle busy: not any more", sd_gayle_busy(), 0);
	/* bad from_gayle ops */
	g_op(&op, 1990, 1, 0);
	op.buf = b;
	check("gayle args: from_gayle with a buffer", sd_sync(&op), SD_E_ARG);
	g_op(&op, 1990, 1, 0);
	op.to_gayle = 1;
	check("gayle args: from and to Gayle", sd_sync(&op), SD_E_ARG);
	check("gayle args: go of a op not running", sd_gayle_go(&op), -1);
}

static void t_csd_and_args(void)
{
	unsigned char csd[16];
	sd_op op = { 0 };
	card(); if (!init()) return;
	op.kind = SD_CSD; op.buf = csd;
	check("csd: ok", sd_sync(&op), SD_OK);
	check("csd: = the init's", memcmp(csd, sd_csd, 16), 0);
	memset(&op, 0, sizeof op);
	op.kind = SD_READ; op.count = 1;
	check("args: no buf, not to_gayle", sd_sync(&op), SD_E_ARG);
	memset(&op, 0, sizeof op);
	op.kind = SD_READ; op.count = 0; op.buf = csd;
	check("args: count 0 is done", sd_sync(&op), SD_OK);
	memset(&op, 0, sizeof op);
	op.kind = SD_READ; op.count = 1; op.lba = SECTORS; op.buf = csd;
	check("args: beyond the card: R1 error", sd_sync(&op), SD_E_R1);
	check("args: not a retry-table error", errs(), 0);
}

int main(void)
{
	setvbuf(stdout, NULL, _IOLBF, 0);
	t_init_crc_on();
	t_read_ok();
	t_read_crc_retry();
	t_read_crc_exhaust();
	t_write_reject_retry();
	t_write_fail_0D();
	t_cmd25_acmd22();
	t_timeout_cmd13_gone();
	t_busy_500ms();
	t_token_100ms();
	t_one_op();
	t_read_multi();
	t_gayle();
	t_cmdcrc();
	t_write_exhaust();
	t_gone();
	t_csd_and_args();
	t_cid();
	t_card_reset();
	t_acmd22_less();
	t_sck_floor();
	t_gayle_write();
	say("\n%d checks: %d failed\n", cases, fails);
	say("sdproto_test %s (%d checks)\n", fails ? "FAIL" : "PASS", cases);
	return fails ? 1 : 0;
}

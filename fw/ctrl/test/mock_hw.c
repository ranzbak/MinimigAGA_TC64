/* mock_hw.c: see mock_hw.h.  Host tests only. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "mock_hw.h"

/* hardware.h's hooks (declared there under -DHOSTTEST); declared again here
   so that this file builds without them */
unsigned char hosttest_spi(unsigned char out);
unsigned char hosttest_rdspi(void);
void hosttest_cs(unsigned v);
void hosttest_spi_speed(unsigned v);
unsigned short hosttest_timer(void);
unsigned short hosttest_host_req(void);
volatile unsigned short *hosttest_platform(void);
volatile unsigned char *hosttest_audio(void);
void hosttest_uart(int c);
unsigned char *hosttest_audio_buffer(void);
/* sdc.h's and arch/irq.h's hooks */
unsigned short hosttest_sdc_rd(unsigned off);
void hosttest_sdc_wr(unsigned off, unsigned short v);
void hosttest_sdc_idle(void);
uint32_t hosttest_irq_save(void);
void hosttest_irq_restore(uint32_t s);
volatile unsigned int *hosttest_interrupt(void);
uint32_t hosttest_irq_pending(void);
volatile uint32_t *hosttest_irq_mask(void);
uint32_t hosttest_irq_raw(void);
volatile uint32_t *hosttest_irq_mode(void);
/* arch/irq.c's handler pointer, when the test links irq.c (weak: the other
   tests have no interrupt controller and take no interrupt) */
extern void (*volatile _InterruptVector)(void) __attribute__((weak));

static void die(const char *what)
{
	fprintf(stderr, "mock_hw: %s\n", what);
	abort();
}

/* growing byte buffer */
struct buf { unsigned char *p; size_t n, cap; };
static void buf_put(struct buf *b, const void *d, size_t n)
{
	if (b->n + n + 1 > b->cap) {
		b->cap = (b->n + n + 1) * 2;
		b->p = realloc(b->p, b->cap);
		if (!b->p) die("out of memory");
	}
	memcpy(b->p + b->n, d, n);
	b->n += n;
	b->p[b->n] = 0;
}
static const char *buf_str(struct buf *b) { buf_put(b, "", 0); return (const char *)b->p; }

/* CRCs of the SD spec, as sd_spi_model.v: CRC7 x^7+x^3+1, CRC16 CCITT
   x^16+x^12+x^5+1, init 0, MSB first */
static unsigned crc7(unsigned c, unsigned char b)
{
	for (int i = 7; i >= 0; i--)
		c = ((c << 1) & 0x7F) ^ ((((c >> 6) ^ (b >> i)) & 1) ? 0x09 : 0x00);
	return c;
}
static unsigned crc16(unsigned c, unsigned char b)
{
	for (int i = 7; i >= 0; i--)
		c = ((c << 1) & 0xFFFF) ^ ((((c >> 15) ^ (b >> i)) & 1) ? 0x1021 : 0x0000);
	return c;
}

/* ------------------------------------------------------------------ card */
/* The queue of bytes the card still has to send: runs (a byte, how many),
   so that busy and token-delay knobs of any size are one entry.  `mark`: the
   last data byte of a CMD17/CMD18 block (MOCK_ERR_RDCRC). */
#define QSZ 4096
struct qent { unsigned n; unsigned char b, mark; };
static struct {
	unsigned char *mem;
	unsigned sectors;
	int tok_dly, busy_n, ncr, init_polls;
	struct qent q[QSZ];
	unsigned qh, qt;
	unsigned char txb;
	int cmdcnt;
	unsigned char cmdb[6];
	unsigned cidx, carg;
	int app_cmd, idle, ready, polls;
	int rd_multi;
	unsigned rd_lba;
	int wstate;			/* 0 none, 1 token, 2 data, 3 crc */
	int wmulti;
	unsigned wlba;
	int wcnt;
	unsigned char wbuf[512];
	unsigned commands;
	int busy_stuck;			/* busy < 0: 0x00 until deselect or CMD0 */
	struct buf log;			/* one line per command (mock_card_log) */
	/* Task 4 (sd_spi_model.v) */
	int crc_on;			/* CMD59 */
	int crc_real;			/* blocks carry their real CRC16 (the command came through the SD peripheral) */
	unsigned wcrc, wrx;		/* CRC16 of the block being written, its CRC bytes as received */
	unsigned char werr;		/* CMD25: 0, or the error response that stopped it */
	unsigned wr_ok;			/* blocks written with 05 by the last CMD25 (ACMD22) */
	unsigned cmd_n, rd_blk_n, wr_blk_n;
	struct { unsigned at, left; } err[MOCK_ERR_KINDS];
	int gone;			/* mock_card_remove */
	int sel;			/* selected (cfide's CS bit 1 or the peripheral's CS) */
} card;
static int card_via_sdc;		/* the byte being exchanged comes from the SD peripheral */

static void c_push_n(unsigned char b, unsigned n, int mark)
{
	if (!n) return;
	if (!mark && card.qt != card.qh) {
		struct qent *e = &card.q[(card.qt - 1) % QSZ];
		if (!e->mark && e->b == b) { e->n += n; return; }
	}
	if (card.qt - card.qh >= QSZ) die("card queue full");
	card.q[card.qt % QSZ].n = n;
	card.q[card.qt % QSZ].b = b;
	card.q[card.qt % QSZ].mark = (unsigned char)mark;
	card.qt++;
}
static void c_push(unsigned char b) { c_push_n(b, 1, 0); }
static void c_push_r1(unsigned char r)
{
	c_push_n(0xFF, card.ncr > 0 ? (unsigned)card.ncr : 0, 0);
	c_push(r);
}
static void c_push_busy(void)
{
	if (card.busy_n < 0) card.busy_stuck = 1;
	else c_push_n(0x00, (unsigned)card.busy_n, 0);
}
/* token delay, the token, the bytes, their CRC16 (real, or the old 00 00) */
static void c_push_data(const unsigned char *d, unsigned n, int mark_last)
{
	unsigned c = 0;
	c_push_n(0xFF, (unsigned)card.tok_dly, 0);
	c_push(0xFE);
	for (unsigned k = 0; k < n; k++) {
		c_push_n(d[k], 1, mark_last && k == n - 1);
		c = crc16(c, d[k]);
	}
	if (!card.crc_real) c = 0;
	c_push(c >> 8); c_push(c & 0xFF);
}
static void c_push_block(unsigned lba)
{
	if (card.tok_dly < 0) return;	/* no token, ever */
	c_push_data(card.mem + (size_t)lba * 512, 512, 1);
}

static int err_hit(int k, unsigned event_n)
{
	if (card.err[k].at && event_n >= card.err[k].at && card.err[k].left) {
		card.err[k].left--;
		return 1;
	}
	return 0;
}

/* power-on state of the card (knobs, memory, counters unchanged) */
static void card_power_on(void)
{
	card.qh = card.qt = 0; card.txb = 0xFF; card.cmdcnt = 0;
	card.app_cmd = 0; card.idle = 1; card.ready = 0; card.polls = 0;
	card.rd_multi = 0; card.wstate = 0; card.wmulti = 0;
	card.busy_stuck = 0; card.crc_on = 0; card.werr = 0;
}

static void card_state_reset(void)
{
	card.tok_dly = 4; card.busy_n = 8; card.ncr = 1; card.init_polls = 2;
	card_power_on();
	card.rd_lba = card.wlba = 0; card.wcnt = 0; card.commands = 0;
	card.log.n = 0;
	card.cmd_n = card.rd_blk_n = card.wr_blk_n = 0; card.wr_ok = 0;
	memset(card.err, 0, sizeof card.err);
	card.gone = 0; card.sel = 0;
}

static void card_do_cmd(void)
{
	int was_app = card.app_cmd;
	char line[40];
	unsigned c7 = 0;
	card.app_cmd = 0;
	card.commands++;
	card.cmd_n++;
	card.crc_real = card_via_sdc;
	snprintf(line, sizeof line, "%sCMD%u arg=%08x\n", was_app ? "A" : "", card.cidx, card.carg);
	buf_put(&card.log, line, strlen(line));
	for (int k = 0; k < 5; k++) c7 = crc7(c7, card.cmdb[k]);
	if (err_hit(MOCK_ERR_NORESP, card.cmd_n))
		return;				/* no response, no effect */
	if (err_hit(MOCK_ERR_CMDCRC, card.cmd_n) || (card.crc_on && (unsigned)(card.cmdb[5] >> 1) != c7)) {
		c_push_r1(card.idle ? 0x09 : 0x08);
		return;
	}
	switch (card.cidx) {
	case 0:
		card.idle = 1; card.ready = 0; card.polls = 0; card.app_cmd = 0;
		card.rd_multi = 0; card.wstate = 0; card.busy_stuck = 0; card.crc_on = 0;
		c_push_r1(0x01);
		break;
	case 8:
		c_push_r1(card.idle ? 0x01 : 0x00);
		c_push(0x00); c_push(0x00); c_push(0x01); c_push(0xAA);
		break;
	case 55:
		card.app_cmd = 1; c_push_r1(card.idle ? 0x01 : 0x00);
		break;
	case 41:
		if (was_app) {
			if (card.polls >= card.init_polls) { card.idle = 0; card.ready = 1; }
			card.polls++;
			c_push_r1(card.idle ? 0x01 : 0x00);
		} else
			c_push_r1(0x05);
		break;
	case 58:
		c_push_r1(card.idle ? 0x01 : 0x00);
		if (card.ready) { c_push(0xC0); c_push(0xFF); c_push(0x80); c_push(0x00); }
		else            { c_push(0x00); c_push(0xFF); c_push(0x80); c_push(0x00); }
		break;
	case 16:
		c_push_r1(0x00);
		break;
	case 13:			/* R2 */
		c_push_r1(card.idle ? 0x01 : 0x00);
		c_push(0x00);
		break;
	case 59:
		card.crc_on = card.carg & 1;
		c_push_r1(card.idle ? 0x01 : 0x00);
		break;
	case 22:
		if (was_app) {		/* ACMD22: blocks written by the last CMD25 */
			unsigned char d[4] = { card.wr_ok >> 24, card.wr_ok >> 16, card.wr_ok >> 8, card.wr_ok };
			c_push_r1(0x00);
			if (card.tok_dly >= 0) c_push_data(d, 4, 0);
		} else
			c_push_r1(0x04);
		break;
	case 9: {			/* CSD v2.0 */
		unsigned csize = card.sectors / 1024 - 1;
		unsigned char csd[16] = { 0 };
		c_push_r1(0x00);
		if (card.tok_dly < 0) break;	/* no token, ever */
		csd[0] = 0x40;
		csd[7] = (csize >> 16) & 0x3F; csd[8] = (csize >> 8) & 0xFF; csd[9] = csize & 0xFF;
		c_push_data(csd, 16, 0);
		break;
	}
	case 17:
		if (card.carg >= card.sectors) c_push_r1(0x40);
		else { c_push_r1(0x00); c_push_block(card.carg); }
		break;
	case 18:
		if (card.carg >= card.sectors) c_push_r1(0x40);
		else {
			c_push_r1(0x00); c_push_block(card.carg);
			card.rd_multi = 1; card.rd_lba = card.carg + 1;
		}
		break;
	case 12:
		card.rd_multi = 0;
		card.qh = card.qt;	/* drop the rest of the stream */
		c_push(0xFF);		/* stuff byte */
		c_push_r1(0x00);
		c_push_busy();
		break;
	case 24:
	case 25:
		if (card.carg >= card.sectors) c_push_r1(0x40);
		else {
			c_push_r1(0x00);
			card.wstate = 1; card.wmulti = (card.cidx == 25);
			card.wlba = card.carg; card.werr = 0;
			if (card.cidx == 25) card.wr_ok = 0;
		}
		break;
	default:
		c_push_r1(0x04);	/* illegal command */
	}
}

/* the CRC bytes of a written block are in: the data response */
static void card_block_written(void)
{
	unsigned char resp, inj = 0;
	card.wr_blk_n++;
	if (err_hit(MOCK_ERR_WRREJ, card.wr_blk_n)) inj = 0x0B;
	else if (err_hit(MOCK_ERR_WRFAIL, card.wr_blk_n)) inj = 0x0D;
	if (card.werr) resp = card.werr;
	else if (card.crc_on && card.wrx != card.wcrc) resp = 0x0B;
	else if (inj) resp = inj;
	else resp = 0x05;
	if (resp == 0x05 && card.wlba < card.sectors) {
		memcpy(card.mem + (size_t)card.wlba * 512, card.wbuf, 512);
		if (card.wmulti) card.wr_ok++;
	}
	c_push(resp);
	if (resp != 0x0B) c_push_busy();
	if (card.wmulti) {
		card.wstate = 1; card.wlba++;
		if (resp != 0x05) card.werr = resp;
	} else
		card.wstate = 0;
}

/* one received byte; sets txb for the next 8 clocks */
static void card_on_byte(unsigned char b)
{
	if (card.wstate != 0) {
		switch (card.wstate) {
		case 1:
			if (b == 0xFE || (card.wmulti && b == 0xFC)) { card.wstate = 2; card.wcnt = 0; card.wcrc = 0; }
			else if (card.wmulti && b == 0xFD) { card.wstate = 0; c_push(0xFF); c_push_busy(); }
			break;
		case 2:
			card.wbuf[card.wcnt++] = b;
			card.wcrc = crc16(card.wcrc, b);
			if (card.wcnt == 512) { card.wstate = 3; card.wcnt = 0; }
			break;
		case 3:
			card.wrx = ((card.wrx << 8) | b) & 0xFFFF;
			if (++card.wcnt == 2) card_block_written();
			break;
		}
	} else if (card.cmdcnt == 0) {
		if ((b & 0xC0) == 0x40) { card.cmdb[0] = b; card.cmdcnt = 1; }
	} else {
		card.cmdb[card.cmdcnt++] = b;
		if (card.cmdcnt == 6) {
			card.cmdcnt = 0;
			card.cidx = card.cmdb[0] & 0x3F;
			card.carg = ((unsigned)card.cmdb[1] << 24) | ((unsigned)card.cmdb[2] << 16) |
			            ((unsigned)card.cmdb[3] << 8) | card.cmdb[4];
			card_do_cmd();
		}
	}
	/* multi-block read: keep the stream going */
	if (card.qh == card.qt && card.rd_multi) {
		if (card.rd_lba < card.sectors) { c_push_block(card.rd_lba); card.rd_lba++; }
		else card.rd_multi = 0;
	}
	if (card.qh != card.qt) {
		struct qent *e = &card.q[card.qh % QSZ];
		card.txb = e->b;
		if (e->mark) {		/* a read block's last data byte: MOCK_ERR_RDCRC */
			card.rd_blk_n++;
			if (err_hit(MOCK_ERR_RDCRC, card.rd_blk_n)) card.txb ^= 0x01;
		}
		if (--e->n == 0) card.qh++;
	} else
		card.txb = card.busy_stuck ? 0x00 : 0xFF;
}

/* the card's side of one byte: what it sends (MISO), then it takes `out` */
static unsigned char card_xchg(unsigned char out)
{
	unsigned char in;
	if (card.gone) return 0xFF;
	in = card.txb;
	card_on_byte(out);
	return in;
}

static void card_select(void) { card.cmdcnt = 0; card.txb = 0xFF; }
static void card_deselect(void)
{
	card.cmdcnt = 0; card.qh = card.qt; card.rd_multi = 0; card.wstate = 0;
	card.busy_stuck = 0;
}

void mock_card_params(int token_dly, int busy, int ncr, int init_polls)
{
	card.tok_dly = token_dly; card.busy_n = busy; card.ncr = ncr; card.init_polls = init_polls;
}

unsigned mock_card_commands(void) { return card.commands; }
const char *mock_card_log(void) { buf_put(&card.log, "", 0); return (const char *)card.log.p; }

int mock_card_load(const char *path, unsigned sectors)
{
	FILE *f = fopen(path, "rb");
	if (!f) return -1;
	fseek(f, 0, SEEK_END);
	long sz = ftell(f);
	fseek(f, 0, SEEK_SET);
	unsigned have = (unsigned)((sz + 511) / 512);
	if (!sectors) {
		sectors = have > 65536 ? (have + 1023) / 1024 * 1024 : 65536;
	}
	if (have > sectors) { fclose(f); return -1; }
	free(card.mem);
	card.mem = calloc(sectors, 512);
	if (!card.mem) die("out of memory");
	card.sectors = sectors;
	if (fread(card.mem, 1, (size_t)sz, f) != (size_t)sz) { fclose(f); return -1; }
	fclose(f);
	return 0;
}

int mock_card_new(unsigned sectors)
{
	free(card.mem);
	card.mem = calloc(sectors ? sectors : 1, 512);
	if (!card.mem) die("out of memory");
	card.sectors = sectors;
	return 0;
}

int mock_card_save(const char *path)
{
	FILE *f = fopen(path, "wb");
	if (!f || !card.mem) { if (f) fclose(f); return -1; }
	size_t n = (size_t)card.sectors * 512;
	int ok = fwrite(card.mem, 1, n, f) == n;
	return (fclose(f) == 0 && ok) ? 0 : -1;
}

const unsigned char *mock_card_sector(unsigned lba)
{
	return (card.mem && lba < card.sectors) ? card.mem + (size_t)lba * 512 : NULL;
}
unsigned char *mock_card_wsector(unsigned lba)
{
	return (card.mem && lba < card.sectors) ? card.mem + (size_t)lba * 512 : NULL;
}

void mock_card_error(enum mock_card_err_kind kind, unsigned n, unsigned cnt)
{
	if ((unsigned)kind >= MOCK_ERR_KINDS) die("mock_card_error: no such kind");
	card.err[kind].at = n;
	card.err[kind].left = cnt ? cnt : 1;
}
void mock_card_remove(void)
{
	card.gone = 1;
	card.qh = card.qt; card.rd_multi = 0; card.wstate = 0; card.cmdcnt = 0;
	card.txb = 0xFF; card.busy_stuck = 0;
}
void mock_card_insert(void)
{
	card.gone = 0;
	card_power_on();
}
int mock_card_crc_on(void) { return card.crc_on; }
unsigned mock_card_wr_ok(void) { return card.wr_ok; }

/* the card's chip select: cfide's CS bit 1 (the old path) or the SD
   peripheral's CFG bit 8 */
static int sdc_cs_now(void);
static unsigned scs;				/* cfide's scs register */
static void card_sel_update(void)
{
	int s = (scs & 2) || sdc_cs_now();
	if (s && !card.sel) card_select();
	if (!s && card.sel) card_deselect();
	card.sel = s;
}

/* ------------------------------------------------------------- SPI + CS */
struct script {
	struct buf q;
	size_t head;
	mock_miso_fn fn;
	void *ctx;
	unsigned char idle;
	unsigned underruns;
};
static struct script scripts[8];		/* by the bit number of the line, 0 = none */
static unsigned spi_speed;
static unsigned char last_in;
static unsigned dmode_blocks;			/* mock_dmode_blocks */

static struct buf speed_log;			/* mock_spi_speed_log */
static void timer_spi_byte(void);
static void order_put(char c);
static int gayle_op_busy(void);
static unsigned gayle_violations;

static struct buf trace;			/* closed frames */
static struct buf fr_out, fr_in;		/* the open frame */
static unsigned fr_cs;
static int frames;
static char *view;

static int slot_of(unsigned cs)			/* Enable value -> script slot */
{
	for (int i = 7; i >= 1; i--)
		if (cs & (1u << i)) return i;
	return 0;
}

static void render_frame(struct buf *dst)
{
	char t[8];
	snprintf(t, sizeof t, "%02x", fr_cs);
	buf_put(dst, t, strlen(t));
	for (size_t k = 0; k < fr_out.n; k++) { snprintf(t, sizeof t, " %02x", fr_out.p[k]); buf_put(dst, t, 3); }
	buf_put(dst, " /", 2);
	for (size_t k = 0; k < fr_in.n; k++) { snprintf(t, sizeof t, " %02x", fr_in.p[k]); buf_put(dst, t, 3); }
	buf_put(dst, "\n", 1);
}

static int frame_visible(void) { return fr_cs != 0 || fr_out.n > 0; }

static void frame_close(void)
{
	if (frame_visible()) { render_frame(&trace); frames++; }
	fr_out.n = fr_in.n = 0;
}

const char *mock_trace(void)
{
	struct buf v = { 0 };
	buf_put(&v, trace.p ? (char *)trace.p : "", trace.n);
	if (frame_visible()) render_frame(&v);
	free(view);
	view = (char *)v.p;
	if (!view) { view = strdup(""); }
	return view;
}

int mock_trace_write(const char *path)
{
	const char *s = mock_trace();
	FILE *f = fopen(path, "w");
	if (!f) return -1;
	int ok = fputs(s, f) >= 0;
	return (fclose(f) == 0 && ok) ? 0 : -1;
}

int mock_frames(void) { return frames + (frame_visible() ? 1 : 0); }
unsigned mock_cs(void) { return scs; }
unsigned mock_spi_speed(void) { return spi_speed; }
const char *mock_spi_speed_log(void) { buf_put(&speed_log, "", 0); return (const char *)speed_log.p; }

void hosttest_cs(unsigned v)
{
	unsigned n = scs;
	unsigned bit0 = (v & 1) ? 0 : 1;	/* Enable (bit 0 clear) sets, Disable clears */
	for (int i = 1; i < 8; i++)
		if (v & (1u << i)) n = bit0 ? (n | (1u << i)) : (n & ~(1u << i));
	n = bit0 ? (n | 1u) : (n & ~1u);
	if (n == scs) return;
	frame_close();
	/* an IDE command over scs(4) while the Gayle bridge owns the port */
	if (!(scs & 0x10) && (n & 0x10) && gayle_op_busy()) gayle_violations++;
	scs = n;
	card_sel_update();
	fr_cs = scs & 0xFE;
}

void hosttest_spi_speed(unsigned v)
{
	char line[48];
	spi_speed = v;
	snprintf(line, sizeof line, "%02x after %u commands\n", v, card.commands);
	buf_put(&speed_log, line, strlen(line));
}

unsigned char hosttest_spi(unsigned char out)
{
	unsigned char in;
	if ((scs & 2) && (scs & 0x40)) {
		/* direct mode: cfide clocks 4096 bits with MOSI high (sd_out FFFF,
		   shiftcnt "10111111111111"), the FPGA takes the card's bytes */
		const unsigned char ff = 0xFF;
		order_put('W'); order_put('R');
		for (int n = 0; n < 512; n++) {
			in = card_xchg(ff);
			buf_put(&fr_out, &ff, 1);
			buf_put(&fr_in, &in, 1);
			timer_spi_byte();
		}
		last_in = in;
		dmode_blocks++;
		return in;
	}
	order_put('W'); order_put('R');
	if (scs & 2) {
		in = card_xchg(out);
	} else {
		struct script *s = &scripts[slot_of(scs & 0xFE)];
		if (s->fn) in = s->fn(s->ctx, out);
		else if (s->head < s->q.n) in = s->q.p[s->head++];
		else { in = s->idle; s->underruns++; }
	}
	buf_put(&fr_out, &out, 1);
	buf_put(&fr_in, &in, 1);
	timer_spi_byte();
	last_in = in;
	return in;
}

unsigned char hosttest_rdspi(void) { order_put('R'); return last_in; }
unsigned mock_dmode_blocks(void) { return dmode_blocks; }

void mock_script_bytes(unsigned cs, const unsigned char *b, size_t n)
{
	buf_put(&scripts[slot_of(cs)].q, b, n);
}
void mock_script_fn(unsigned cs, mock_miso_fn fn, void *ctx)
{
	scripts[slot_of(cs)].fn = fn;
	scripts[slot_of(cs)].ctx = ctx;
}
void mock_script_idle(unsigned cs, unsigned char idle) { scripts[slot_of(cs)].idle = idle; }
unsigned mock_script_left(unsigned cs)
{
	struct script *s = &scripts[slot_of(cs)];
	return (unsigned)(s->q.n - s->head);
}
unsigned mock_underruns(unsigned cs) { return scripts[slot_of(cs)].underruns; }

/* ------------------------------------------------------------ the clock */
/* now: clk_114 cycles; sub: cycles not yet a whole TIMER count */
static unsigned long long now, sub;
static unsigned timer_count;
static void sdc_run(unsigned long long until);
static void irq_deliver(void);

/* time passes in cycles (register accesses, the peripheral's own steps):
   the TIMER moves with it */
static void time_cycles(unsigned long long c)
{
	now += c;
	sub += c;
	while (sub >= MOCK_CYC_PER_TIMER) { sub -= MOCK_CYC_PER_TIMER; timer_count++; }
	sdc_run(now);
}
/* time passes in TIMER counts (the old knobs) */
static void time_counts(unsigned n)
{
	timer_count += n;
	now += (unsigned long long)n * MOCK_CYC_PER_TIMER;
	sdc_run(now);
}
unsigned long long mock_now(void) { return now; }

/* ---------------------------------------------------------------- TIMER */
static unsigned timer_step, timer_reads, timer_spi_rate, timer_spi_bytes;

void hosttest_advance(unsigned n) { time_counts(n); }
void mock_timer_step(unsigned n) { timer_step = n; }
void mock_timer_spi_rate(unsigned n) { timer_spi_rate = n; timer_spi_bytes = 0; }
static void timer_spi_byte(void)
{
	if (timer_spi_rate && ++timer_spi_bytes == timer_spi_rate) { time_counts(1); timer_spi_bytes = 0; }
}
unsigned mock_timer_reads(void) { return timer_reads; }
unsigned short hosttest_timer(void)
{
	unsigned short v = (unsigned short)timer_count;
	time_counts(timer_step);
	timer_reads++;
	irq_deliver();
	return v;
}

/* ------------------------------------------------------------- HOST_REQ */
static unsigned host_req_zeros, host_req_reads;
static struct buf order;		/* mock_order */
static int order_on;

static void order_put(char c)
{
	if (!order_on) return;
	if (order.n < 4095) buf_put(&order, &c, 1);
	else if (order.n == 4095) buf_put(&order, "+", 1);
}
void mock_order_start(void) { order.n = 0; if (order.p) order.p[0] = 0; order_on = 1; }
const char *mock_order(void) { buf_put(&order, "", 0); return (const char *)order.p; }

void mock_host_req(unsigned zeros) { host_req_zeros = zeros; }
unsigned mock_host_req_reads(void) { return host_req_reads; }
unsigned short hosttest_host_req(void)
{
	unsigned short v = 1;
	host_req_reads++;
	if (host_req_zeros) {
		v = 0;
		if (host_req_zeros != MOCK_HOST_REQ_STUCK) host_req_zeros--;
	}
	order_put(v ? '1' : '0');
	return v;
}

/* ----------------------------------------------- UART, PLATFORM, AUDIO */
static struct buf uart;
static volatile unsigned short platform_reg;
static volatile unsigned char audio_reg;

void hosttest_uart(int c) { unsigned char b = (unsigned char)c; buf_put(&uart, &b, 1); }
const char *mock_uart(void) { buf_put(&uart, "", 0); return uart.p ? (const char *)uart.p : ""; }
size_t mock_uart_len(void) { return uart.n; }
void mock_uart_clear(void) { uart.n = 0; if (uart.p) uart.p[0] = 0; }
volatile unsigned short *hosttest_platform(void) { return &platform_reg; }
volatile unsigned char *hosttest_audio(void) { return &audio_reg; }
void mock_platform_set(unsigned short v) { platform_reg = v; }
void mock_audio_set(unsigned char v) { audio_reg = v; }

/* ------------------------------------------------- RAM below the ring */
/* The firmware's RAM from the end of its .bss up to and including the audio
   ring: one object, so that drivesounds.c's AUDIO_BUFFER - &__bss_end (the
   room for DRIVESND.BIN in front of the ring) is a difference inside it.
   The array is the linker symbol __bss_end the firmware declares. */
char __bss_end[MOCK_LOAD_AREA + MOCK_RING_BYTES] __attribute__((aligned(16)));
unsigned char *hosttest_audio_buffer(void) { return (unsigned char *)__bss_end + MOCK_LOAD_AREA; }
unsigned char *mock_ring(void) { return hosttest_audio_buffer(); }

/* ======================================================================
 * The SD peripheral (rtl/host/sdcard_spi.v): a byte-level model of its
 * header contract.  Names follow the RTL.
 * ====================================================================== */
#define NEVER (~0ULL)
#define OP_XFER 1
#define OP_WEQ 2
#define OP_WNE 3
#define OP_G2TX 4
#define OP_RX2G 5
#define OP_TXRW 6
#define OP_TXCM 7
#define OP_RXFL 8
#define OP_TXFL 9
#define OP_ABORT 15
#define X_TX 0x10
#define X_RX 0x20
#define X_CTX 0x40
#define X_CRX 0x80
/* STATUS bits kept in sdc.st (busy and card present come from the state) */
#define ST_CRC_OK 0x002
#define ST_TMO    0x004
#define ST_ABORT  0x010
#define ST_GONE   0x020
#define ST_REFUSE 0x040
#define ST_GERR   0x080
#define ST_MISUSE 0x100
#define I_DONE 0x01
#define I_RXHI 0x02
#define I_TXLO 0x04
#define I_ERR  0x08
#define I_CD   0x10
#define CD_DEBOUNCE (1ULL << 20)
#define TMO_UNIT 16384ULL

enum { END_NORMAL, END_ABORT, END_TMO, END_GONE, END_GERR };
static const char *const end_name[] = { "normal", "abort", "timeout", "gone", "gerr" };
static const char *const op_name[16] = { "?0", "XFER", "WAIT_EQ", "WAIT_NE", "GAYLE_TO_TX", "RX_TO_GAYLE",
	"TX_REWIND", "TX_COMMIT", "RX_FLUSH", "TX_FLUSH", "?10", "?11", "?12", "?13", "?14", "ABORT" };

static struct {
	/* registers */
	unsigned div, cs, len, match, tmo, irqen, wm_rx, wm_tx, last, cnt, pend, st;
	/* the op */
	int busy;
	unsigned op, cmd, xf;		/* xf: CMD bits 4-7 of an XFER (0 for the other ops) */
	unsigned loaded;		/* bytes loaded into the shifter by this op */
	int inflight;			/* a byte is being shifted */
	unsigned long long byte_end;
	unsigned char out;
	unsigned ph;			/* the byte being shifted: 0 data, 1 / 2 CRC byte 1 / 2 */
	unsigned crc;
	int ahead_ok, abort_pend;
	unsigned long long deadline;	/* wait ops: TIMEOUT runs out */
	/* FIFOs, free-running indices */
	unsigned char rx[1024], tx[1024];
	unsigned rx_rd, rx_wr, tx_cm, tx_snd, tx_wr, tx_wr0;
	unsigned verified;
	int poisoned;
	/* card detect: the synchronised level, the debounced one, since when */
	int cd_raw, cd_stable;
	unsigned long long cd_since;
	/* test knobs */
	int refuse_next;
	unsigned access_cyc;
	int (*stall_fn)(void *);
	void *stall_ctx;
	int stall_fatal;
	unsigned long long bytes;
	struct buf log;
	int wire_on;
	struct buf wire, wo, wi;	/* closed frames; the open frame's out / in */
	unsigned wire_cs;
} sdc;

/* the Gayle bridge */
static struct {
	struct buf from[2];
	size_t from_head[2];
	struct buf into[2];
	int hold;
	int end_how;
	unsigned end_words;
	unsigned word_cyc;
	unsigned words;			/* words moved by the running op */
	unsigned long long next;	/* its next word / g_ack */
	int stalled;			/* GAYLE_TO_TX waits for the Amiga's bytes */
} gay;

static int sdc_cs_now(void) { return sdc.cs; }
static unsigned rxlvl(void) { return sdc.rx_wr - sdc.rx_rd; }
static unsigned txlvl(void) { return sdc.tx_wr - sdc.tx_cm; }
static int is_gayle(unsigned op) { return op == OP_G2TX || op == OP_RX2G; }
static int gayle_op_busy(void) { return sdc.busy && is_gayle(sdc.op); }
static int sdc_line(void) { return (sdc.pend & sdc.irqen) != 0; }

/* the level-sticky watermark bits: set while their level holds */
static void sdc_levels(void)
{
	if ((rxlvl() >> 4) >= sdc.wm_rx) sdc.pend |= I_RXHI;
	if (txlvl() <= sdc.wm_tx * 16u) sdc.pend |= I_TXLO;
}

static void misuse(void) { sdc.st |= ST_MISUSE; sdc.pend |= I_ERR; }

static unsigned sdc_st_word(void)
{
	return (sdc.busy ? 1u : 0u) | sdc.st | (sdc.cd_stable ? 0x008u : 0u);
}

/* the wire log */
static void wire_close(void)
{
	char t[8];
	if (!sdc.wo.n) return;
	buf_put(&sdc.wire, sdc.wire_cs ? "sd" : "sd-", sdc.wire_cs ? 2 : 3);
	for (size_t k = 0; k < sdc.wo.n; k++) { snprintf(t, sizeof t, " %02x", sdc.wo.p[k]); buf_put(&sdc.wire, t, 3); }
	buf_put(&sdc.wire, " /", 2);
	for (size_t k = 0; k < sdc.wi.n; k++) { snprintf(t, sizeof t, " %02x", sdc.wi.p[k]); buf_put(&sdc.wire, t, 3); }
	buf_put(&sdc.wire, "\n", 1);
	sdc.wo.n = sdc.wi.n = 0;
}

/* one byte on the wire: MOSI `out`, the card's MISO back */
static unsigned char sdc_xchg(unsigned char out)
{
	unsigned char in = 0xFF;		/* MISO pulled up */
	if (sdc.cs) {
		card_via_sdc = 1;
		in = card_xchg(out);
		card_via_sdc = 0;
	}
	sdc.bytes++;
	if (sdc.wire_on) {
		if (sdc.wire_cs != sdc.cs) { wire_close(); sdc.wire_cs = sdc.cs; }
		buf_put(&sdc.wo, &out, 1);
		buf_put(&sdc.wi, &in, 1);
	}
	return in;
}

static void sdc_end(int why)
{
	int rxop = sdc.op == OP_XFER && (sdc.xf & X_RX);
	char line[96];

	sdc.st &= ~(ST_CRC_OK | ST_TMO | ST_ABORT | ST_GONE | ST_GERR);
	switch (why) {
	case END_NORMAL:
		if (sdc.op == OP_XFER && (sdc.xf & X_CRX)) {
			if (sdc.crc == 0) {
				sdc.st |= ST_CRC_OK;
				if (rxop && sdc.ahead_ok) sdc.verified = rxlvl();	/* all of RX now verified */
			} else if (rxop)
				sdc.poisoned = 1;
		}
		break;
	case END_ABORT: sdc.st |= ST_ABORT; break;
	case END_TMO:   sdc.st |= ST_TMO; break;
	case END_GONE:  sdc.st |= ST_GONE; break;
	case END_GERR:  sdc.st |= ST_GERR; break;
	}
	/* GAYLE_TO_TX ending any way but normally: TX back to its state at the start */
	if (sdc.op == OP_G2TX && why != END_NORMAL) sdc.tx_wr = sdc.tx_wr0;
	if (is_gayle(sdc.op)) gay.end_how = MOCK_GAYLE_OK;	/* one shot */
	sdc.busy = 0;
	sdc.inflight = 0;
	sdc.abort_pend = 0;
	sdc.pend |= I_DONE;
	if (why == END_TMO || why == END_GONE || why == END_GERR) sdc.pend |= I_ERR;
	sdc_levels();
	snprintf(line, sizeof line, "END %s %s COUNT %u STATUS %04x\n", op_name[sdc.op], end_name[why],
	         sdc.cnt & 0x7FF, sdc_st_word());
	buf_put(&sdc.log, line, strlen(line));
}

/* the shifter loads its next byte at time t, if it can (else it pauses) */
static void sdc_load(unsigned long long t)
{
	unsigned k = sdc.loaded, ph = 0;
	unsigned char out;

	if (!sdc.busy || sdc.inflight || is_gayle(sdc.op) || sdc.abort_pend) return;
	if (sdc.op == OP_XFER && k >= sdc.len) ph = k - sdc.len + 1;	/* a CRC byte */
	if (ph == 0) {
		/* a data byte: TX empty for a TX op / RX full for an RX op: pause */
		if ((sdc.xf & X_TX) && sdc.tx_wr == sdc.tx_snd) return;
		if ((sdc.xf & X_RX) && rxlvl() >= 1024) return;
		out = (sdc.xf & X_TX) ? sdc.tx[sdc.tx_snd++ & 1023] : 0xFF;
		if (sdc.xf & X_CTX) sdc.crc = crc16(sdc.crc, out);
	} else if (sdc.xf & X_CTX) {	/* the CRC, high byte first */
		out = sdc.crc >> 8;
		sdc.crc = (sdc.crc << 8) & 0xFFFF;
	} else
		out = 0xFF;
	sdc.out = out;
	sdc.ph = ph;
	sdc.loaded++;
	sdc.inflight = 1;
	sdc.byte_end = t + mock_sdc_byte_cycles();
}

static void sdc_byte_done(void)
{
	unsigned long long t = sdc.byte_end;
	unsigned char in = sdc_xchg(sdc.out);
	int nat;

	sdc.inflight = 0;
	sdc.cnt++;
	sdc.last = in;
	if (sdc.xf & X_CRX) sdc.crc = crc16(sdc.crc, in);
	if ((sdc.xf & X_RX) && sdc.ph == 0) sdc.rx[sdc.rx_wr++ & 1023] = in;
	if (sdc.op == OP_WEQ || sdc.op == OP_WNE)
		nat = (in == sdc.match) ^ (sdc.op == OP_WNE);
	else if (sdc.xf & (X_CTX | X_CRX))
		nat = sdc.ph == 2;
	else
		nat = sdc.cnt == sdc.len;
	if (nat) sdc_end(END_NORMAL);
	else if (sdc.abort_pend) sdc_end(END_ABORT);
	else if ((sdc.op == OP_WEQ || sdc.op == OP_WNE) && t > sdc.deadline) sdc_end(END_TMO);
	else sdc_load(t);
	sdc_levels();
}

/* a Gayle word, or the bridge's end */
static void gayle_event(void)
{
	unsigned port = (sdc.cmd >> 8) & 1;
	if (gay.end_how != MOCK_GAYLE_OK && gay.words == gay.end_words) { sdc_end(END_GERR); return; }
	if (gay.words == sdc.len / 2) { sdc_end(END_NORMAL); return; }	/* g_ack, all words */
	if (sdc.op == OP_RX2G) {
		unsigned char w[2];
		w[0] = sdc.rx[sdc.rx_rd++ & 1023];
		w[1] = sdc.rx[sdc.rx_rd++ & 1023];
		sdc.verified = sdc.verified > 2 ? sdc.verified - 2 : 0;
		buf_put(&gay.into[port], w, 2);
	} else {
		if (gay.from[port].n - gay.from_head[port] < 2) { gay.stalled = 1; return; }
		sdc.tx[sdc.tx_wr++ & 1023] = gay.from[port].p[gay.from_head[port]++];
		sdc.tx[sdc.tx_wr++ & 1023] = gay.from[port].p[gay.from_head[port]++];
	}
	sdc.cnt += 2;
	gay.words++;
	gay.next += gay.word_cyc;
	sdc_levels();
}

static unsigned long long sdc_next_event(void)
{
	unsigned long long e = NEVER;
	if (sdc.busy && sdc.inflight) e = sdc.byte_end;
	if (gayle_op_busy() && !gay.hold && !gay.stalled && gay.next < e) e = gay.next;
	if (sdc.cd_raw != sdc.cd_stable && sdc.cd_since + CD_DEBOUNCE < e) e = sdc.cd_since + CD_DEBOUNCE;
	return e;
}

/* run the peripheral up to time `until` */
static void sdc_run(unsigned long long until)
{
	unsigned long long e;
	while ((e = sdc_next_event()) <= until) {
		if (sdc.cd_raw != sdc.cd_stable && e == sdc.cd_since + CD_DEBOUNCE) {
			sdc.cd_stable = sdc.cd_raw;
			sdc.pend |= I_CD;
		} else if (sdc.busy && sdc.inflight && e == sdc.byte_end)
			sdc_byte_done();
		else
			gayle_event();
	}
}

static void sdc_logcmd(unsigned v, const char *what)
{
	char line[64];
	snprintf(line, sizeof line, "CMD %04x LEN %u%s\n", v, sdc.len, what);
	buf_put(&sdc.log, line, strlen(line));
}

static void sdc_cmd(unsigned v)
{
	unsigned op = v & 15;
	int ok;

	if (op == OP_ABORT) {
		buf_put(&sdc.log, "ABORT\n", 6);
		if (!sdc.busy) { sdc.pend |= I_DONE; return; }
		sdc.abort_pend = 1;
		if (!sdc.inflight) sdc_end(END_ABORT);	/* paused, or a Gayle op: at once */
		return;
	}
	switch (op) {
	case OP_XFER: ok = (v & (X_CTX | X_CRX)) != (X_CTX | X_CRX); break;
	case OP_WEQ: case OP_WNE: case OP_TXRW: case OP_TXCM: case OP_RXFL: case OP_TXFL: ok = 1; break;
	case OP_G2TX: ok = sdc.len && !(sdc.len & 1) && txlvl() + sdc.len <= 1024; break;
	case OP_RX2G: ok = sdc.len && !(sdc.len & 1) && !sdc.poisoned && sdc.verified >= sdc.len; break;
	default: ok = 0;
	}
	if (sdc.busy || sdc.refuse_next || !ok) {
		sdc.refuse_next = 0;
		sdc.st |= ST_REFUSE;
		sdc.pend |= I_ERR;
		sdc_logcmd(v, " refused");
		return;
	}
	sdc_logcmd(v, "");
	sdc.st = 0;			/* STATUS 8:1 */
	sdc.cnt = 0;
	sdc.crc = 0;
	sdc.abort_pend = 0;
	sdc.ahead_ok = !sdc.poisoned && rxlvl() == sdc.verified;
	sdc.cmd = v;
	sdc.op = op;
	sdc.xf = op == OP_XFER ? (v & 0xF0) : 0;
	sdc.loaded = 0;
	sdc.inflight = 0;
	switch (op) {
	case OP_XFER:
		if (sdc.len == 0) sdc.pend |= I_DONE;	/* no bytes, no CRC */
		else sdc.busy = 1;
		break;
	case OP_WEQ: case OP_WNE:
		sdc.busy = 1;
		sdc.deadline = now + (sdc.tmo ? sdc.tmo : 1) * TMO_UNIT;
		break;
	case OP_G2TX: case OP_RX2G:
		sdc.busy = 1;
		sdc.tx_wr0 = sdc.tx_wr;
		gay.words = 0;
		gay.stalled = 0;
		gay.next = now + gay.word_cyc;
		break;
	case OP_TXRW: sdc.tx_snd = sdc.tx_cm; sdc.pend |= I_DONE; break;
	case OP_TXCM: sdc.tx_cm = sdc.tx_snd; sdc.pend |= I_DONE; break;
	case OP_RXFL: sdc.rx_rd = sdc.rx_wr; sdc.verified = 0; sdc.poisoned = 0; sdc.pend |= I_DONE; break;
	case OP_TXFL: sdc.tx_cm = sdc.tx_snd = sdc.tx_wr; sdc.pend |= I_DONE; break;
	}
	if (sdc.busy && !sdc.cd_raw) sdc_end(END_GONE);	/* no card: ends in its first cycle */
	else if (sdc.busy) sdc_load(now);
	sdc_levels();
}

static void tx_push(unsigned char b)
{
	if (txlvl() >= 1024) { misuse(); return; }	/* dropped */
	sdc.tx[sdc.tx_wr++ & 1023] = b;
}

/* pop n (1 or 2) bytes; fewer there: 00 for each missing one, STATUS 8 */
static unsigned rx_pop(unsigned n)
{
	unsigned v = 0, got = 0;
	for (unsigned k = 0; k < n; k++) {
		v <<= 8;
		if (rxlvl()) { v |= sdc.rx[sdc.rx_rd++ & 1023]; got++; }
	}
	if (got < n) misuse();
	sdc.verified = sdc.verified > got ? sdc.verified - got : 0;
	return v;
}

static void sdc_write(unsigned off, unsigned v)
{
	switch (off) {
	case 0x00:
	case 0x04:
		if (gayle_op_busy()) { misuse(); break; }	/* the data port is locked */
		if (off == 0x00) tx_push(v >> 8);
		tx_push(v & 0xFF);
		if (sdc.busy) sdc_load(now);			/* a paused TX op goes on */
		break;
	case 0x10: sdc_cmd(v); break;
	case 0x14: if (!sdc.busy) sdc.len = v & 0x7FF; break;
	case 0x18: if (!sdc.busy) sdc.match = v & 0xFF; break;
	case 0x1C: sdc.pend &= ~(v & 0x1F); break;
	case 0x20:
		if (sdc.busy) { sdc.st |= ST_REFUSE; sdc.pend |= I_ERR; break; }	/* CS / divider fixed during an op */
		sdc.div = v & 0xFF;
		if (sdc.cs != ((v >> 8) & 1)) {
			sdc.cs = (v >> 8) & 1;
			if (sdc.wire_on) { wire_close(); sdc.wire_cs = sdc.cs; }
			card_sel_update();
		}
		break;
	case 0x24: if (!sdc.busy) sdc.tmo = v; break;
	case 0x28: sdc.irqen = v & 0x1F; break;
	case 0x2C: sdc.wm_rx = (v >> 8) & 0xFF; sdc.wm_tx = v & 0xFF; break;
	default: break;
	}
	sdc_levels();
}

static unsigned sdc_read(unsigned off)
{
	unsigned v = 0;
	switch (off) {
	case 0x00:
	case 0x04:
		if (gayle_op_busy()) { misuse(); break; }	/* locked: 0000, nothing popped */
		v = rx_pop(off == 0x00 ? 2 : 1);
		if (sdc.busy) sdc_load(now);			/* a paused RX op goes on */
		break;
	case 0x08: v = rxlvl(); break;
	case 0x0C: v = txlvl(); break;
	case 0x10: v = sdc_st_word(); break;
	case 0x14: v = sdc.last; break;
	case 0x18: v = sdc.cnt & 0x7FF; break;
	case 0x1C: v = sdc.pend; break;
	case 0x20: v = (sdc.cs << 8) | sdc.div; break;
	case 0x24: v = sdc.tmo; break;
	case 0x28: v = sdc.irqen; break;
	case 0x2C: v = 0x5D01; break;			/* VERSION */
	default: break;
	}
	sdc_levels();
	return v;
}

static void sdc_check_off(unsigned off)
{
	if ((off & 3) || off > 0x3C) die("SD peripheral: register offset not in 0x00..0x3C, multiple of 4");
}

unsigned short hosttest_sdc_rd(unsigned off)
{
	unsigned v;
	sdc_check_off(off);
	time_cycles(sdc.access_cyc);
	v = sdc_read(off);
	irq_deliver();
	return (unsigned short)v;
}

void hosttest_sdc_wr(unsigned off, unsigned short v)
{
	sdc_check_off(off);
	time_cycles(sdc.access_cyc);
	sdc_write(off, v);
	irq_deliver();
}

void mock_sdc_access_cycles(unsigned n) { sdc.access_cyc = n; }
unsigned mock_sdc_byte_cycles(void) { return 16u * (sdc.div + 1); }
unsigned long mock_sdc_bytes_for_us(unsigned long us)
{
	return (unsigned long)((unsigned long long)us * MOCK_CLK_HZ / 1000000ULL / mock_sdc_byte_cycles());
}
void mock_sdc_cd(int present)
{
	present = present != 0;
	if (present == sdc.cd_raw) return;
	sdc.cd_raw = present;
	sdc.cd_since = now;
	if (!present && sdc.busy) sdc_end(END_GONE);	/* at once, mid-byte too */
	irq_deliver();
}
void mock_sdc_pull_card(void) { mock_card_remove(); mock_sdc_cd(0); }
void mock_sdc_refuse_next(void) { sdc.refuse_next = 1; }
void mock_sdc_on_stall(int (*fn)(void *ctx), void *ctx) { sdc.stall_fn = fn; sdc.stall_ctx = ctx; }
void mock_sdc_stall_fatal(int on) { sdc.stall_fatal = on; }
const char *mock_sdc_log(void) { return buf_str(&sdc.log); }
void mock_sdc_wire_on(int on) { sdc.wire_on = on; sdc.wire_cs = sdc.cs; }
const char *mock_sdc_wire(void) { wire_close(); return buf_str(&sdc.wire); }

void mock_sdc_peek(struct mock_sdc_peek *p)
{
	p->busy = sdc.busy; p->op = sdc.op; p->cmd = sdc.cmd; p->len = sdc.len;
	p->rxlvl = rxlvl(); p->txlvl = txlvl(); p->txunsent = sdc.tx_wr - sdc.tx_snd;
	p->verified = sdc.verified; p->poisoned = sdc.poisoned;
	p->cs = sdc.cs; p->div = sdc.div; p->status = sdc_st_word();
	p->irqpend = sdc.pend; p->irqen = sdc.irqen; p->count = sdc.cnt & 0x7FF; p->last = sdc.last;
	p->timeout = sdc.tmo; p->line = sdc_line(); p->bytes = sdc.bytes;
}

/* ------------------------------------------------------- Gayle bridge */
void mock_gayle_from(unsigned port, const unsigned char *b, size_t n)
{
	buf_put(&gay.from[port & 1], b, n);
	if (gay.stalled) { gay.stalled = 0; gay.next = now + gay.word_cyc; }
}
const unsigned char *mock_gayle_into(unsigned port, size_t *n)
{
	*n = gay.into[port & 1].n;
	return gay.into[port & 1].p;
}
void mock_gayle_end(int how, unsigned words) { gay.end_how = how; gay.end_words = words; }
void mock_gayle_hold(int on)
{
	if (gay.hold && !on) gay.next = now + gay.word_cyc;
	gay.hold = on;
}
void mock_gayle_word_cycles(unsigned n) { gay.word_cyc = n ? n : 1; }
unsigned mock_gayle_cs_violations(void) { return gayle_violations; }

/* ------------------------------------------------ interrupt controller */
static unsigned irqc_mie, irqc_in_trap, irqc_traps, irqc_stale, irqc_reads;
static volatile uint32_t irqc_mask, irqc_mode;
static uint32_t irqc_edge, irqc_prev, irqc_ext, irqc_last_level;
static volatile unsigned int legacy_reg;

static uint32_t irq_raw_now(void) { return irqc_ext | (sdc_line() ? 1u << 4 : 0u); }
/* EDGE bits latch the rising edges of their sources */
static void irq_sample(void)
{
	uint32_t r = irq_raw_now();
	irqc_edge |= r & ~irqc_prev & ~irqc_mode;
	irqc_prev = r;
}
static uint32_t irq_pending_peek(void)
{
	irq_sample();
	return (irqc_edge | (irq_raw_now() & irqc_mode)) & irqc_mask;
}

/* take the interrupt while the line is up (MIE on, no handler running) */
static void irq_deliver(void)
{
	int n = 0;
	if (!irqc_mie || irqc_in_trap || !&_InterruptVector || !_InterruptVector) return;
	while (irq_pending_peek()) {
		irqc_in_trap = 1; irqc_mie = 0; irqc_traps++; irqc_reads = 0;
		_InterruptVector();
		irqc_in_trap = 0; irqc_mie = 1;
		if (++n >= 10000) die("interrupt storm: the line stayed up for 10000 traps (a source nobody clears)");
	}
}

uint32_t hosttest_irq_save(void)
{
	uint32_t s = irqc_mie ? 8u : 0u;
	irqc_mie = 0;
	return s;
}
void hosttest_irq_restore(uint32_t s)
{
	if (s & 8u) { irqc_mie = 1; irq_deliver(); }
}
volatile unsigned int *hosttest_interrupt(void) { return &legacy_reg; }
uint32_t hosttest_irq_pending(void)
{
	uint32_t r, lvl, p;
	/* the dispatcher reads PENDING until it is 0: a source no handler
	   clears keeps it in one trap for ever (on the board too) */
	if (irqc_in_trap && ++irqc_reads >= 10000)
		die("interrupt storm: 10000 PENDING reads in one trap (a source nobody clears)");
	irq_sample();
	r = irq_raw_now();
	lvl = r & irqc_mode;
	p = (irqc_edge | lvl | (irqc_stale ? irqc_last_level & ~lvl : 0u)) & irqc_mask;
	irqc_edge &= ~p;			/* the EDGE bits it returns */
	irqc_last_level = lvl & irqc_mask;
	return p;
}
volatile uint32_t *hosttest_irq_mask(void) { return &irqc_mask; }
uint32_t hosttest_irq_raw(void) { irq_sample(); return irq_raw_now(); }
volatile uint32_t *hosttest_irq_mode(void) { return &irqc_mode; }

void mock_irq_pulse(unsigned bit)
{
	irq_sample();
	if (!(irqc_mode & (1u << bit))) irqc_edge |= 1u << bit;
	irq_deliver();
}
void mock_irq_level(unsigned bit, int v)
{
	if (v) irqc_ext |= 1u << bit; else irqc_ext &= ~(1u << bit);
	irq_sample();
	irq_deliver();
}
void mock_irq_deliver(void) { irq_deliver(); }
unsigned mock_irq_mask(void) { return irqc_mask; }
unsigned mock_irq_mode(void) { return irqc_mode; }
unsigned mock_irq_traps(void) { return irqc_traps; }
int mock_irq_mie(void) { return irqc_mie; }
unsigned mock_interrupt_reg(void) { return legacy_reg; }
void mock_irq_stale_level(int on) { irqc_stale = on; }

/* ------------------------------------------------------ stepping time */
int mock_sdc_step(void)
{
	unsigned long long limit, e;
	irq_deliver();
	if (sdc_next_event() == NEVER) return 0;
	limit = now + MOCK_CYC_PER_TIMER;
	while ((e = sdc_next_event()) != NEVER) {
		if (e > limit) { time_cycles(limit - now); break; }
		time_cycles(e - now);
		if (irq_pending_peek() && irqc_mie && !irqc_in_trap) break;
	}
	irq_deliver();
	return 1;
}

void mock_run(unsigned long long cycles)
{
	unsigned long long end = now + cycles, e;
	while ((e = sdc_next_event()) <= end) {
		time_cycles(e - now);
		irq_deliver();
	}
	time_cycles(end - now);
	irq_deliver();
}

void hosttest_sdc_idle(void)
{
	if (!irqc_mie || irqc_in_trap) die("sdc_wait with interrupts off: no event can arrive");
	if (mock_sdc_step()) return;
	if (sdc.stall_fn && sdc.stall_fn(sdc.stall_ctx)) { irq_deliver(); return; }
	if (sdc.stall_fatal)
		die("sdc_wait: the mock can make no progress (nothing busy, no event pending): a firmware bug");
	time_counts(1);				/* the CPU polls, time passes */
	irq_deliver();
}

static void sdc_reset(void)
{
	free(sdc.log.p); free(sdc.wire.p); free(sdc.wo.p); free(sdc.wi.p);
	memset(&sdc, 0, sizeof sdc);
	sdc.div = 0xFF;				/* reset: CFG 00FF, CS off */
	sdc.cd_raw = sdc.cd_stable = 1;		/* a card present at reset: no change IRQ */
	sdc.access_cyc = 16;
	sdc.stall_fatal = 1;
	sdc_levels();				/* IRQPEND 0006 */
	for (int p = 0; p < 2; p++) { free(gay.from[p].p); free(gay.into[p].p); }
	memset(&gay, 0, sizeof gay);
	gay.word_cyc = 12;
	gayle_violations = 0;
	irqc_mie = 1; irqc_in_trap = 0; irqc_traps = 0; irqc_stale = 0;
	irqc_mask = 0; irqc_mode = 0; irqc_edge = 0; irqc_prev = 0; irqc_ext = 0; irqc_last_level = 0;
	legacy_reg = 0;
}

void mock_reset(void)
{
	for (int i = 0; i < 8; i++) {
		free(scripts[i].q.p);
		memset(&scripts[i], 0, sizeof scripts[i]);
		scripts[i].idle = 0xFF;
	}
	free(trace.p); memset(&trace, 0, sizeof trace);
	free(fr_out.p); memset(&fr_out, 0, sizeof fr_out);
	free(fr_in.p); memset(&fr_in, 0, sizeof fr_in);
	free(view); view = NULL;
	frames = 0; fr_cs = 0; scs = 0; spi_speed = 0; last_in = 0xFF; dmode_blocks = 0;
	free(card.mem);
	free(card.log.p);
	memset(&card, 0, sizeof card);
	card_state_reset();
	free(speed_log.p); memset(&speed_log, 0, sizeof speed_log);
	now = 0; sub = 0;
	timer_count = 0; timer_step = 1; timer_reads = 0; timer_spi_rate = 0; timer_spi_bytes = 0;
	host_req_zeros = 0; host_req_reads = 0;
	free(order.p); memset(&order, 0, sizeof order); order_on = 0;
	mock_uart_clear();
	platform_reg = 0; audio_reg = 0;
	memset(__bss_end, 0, sizeof __bss_end);
	sdc_reset();
}

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
volatile unsigned int *hosttest_vpos(int rtg);
unsigned short hosttest_timer_peek(void);
/* the SD peripheral, its Gayle bridge and the interrupt controller are in
   mock_sdc.c; what the two files share is mock_int.h */
#include "mock_int.h"
#define die mock_die
#define buf_put mock_buf_put
#define buf_str mock_buf_str
#define crc16 mock_crc16

void mock_die(const char *what)
{
	fprintf(stderr, "mock_hw: %s\n", what);
	abort();
}

/* growing byte buffer */
void mock_buf_put(struct buf *b, const void *d, size_t n)
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
const char *mock_buf_str(struct buf *b) { buf_put(b, "", 0); return (const char *)b->p; }

/* CRCs of the SD spec, as sd_spi_model.v: CRC7 x^7+x^3+1, CRC16 CCITT
   x^16+x^12+x^5+1, init 0, MSB first */
static unsigned crc7(unsigned c, unsigned char b)
{
	for (int i = 7; i >= 0; i--)
		c = ((c << 1) & 0x7F) ^ ((((c >> 6) ^ (b >> i)) & 1) ? 0x09 : 0x00);
	return c;
}
unsigned mock_crc16(unsigned c, unsigned char b)
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
	unsigned char cid[16];		/* CMD10 (mock_card_cid) */
	unsigned acmd22_less, acmd22_times;	/* mock_card_acmd22_less */
	unsigned wrrej_every;		/* mock_card_wrrej_every */
	unsigned char stale12;		/* mock_card_cmd12_stale */
	int cs_keep;			/* mock_card_cs_keeps */
	unsigned stale12_n;
	int sel;			/* selected (cfide's CS bit 1 or the peripheral's CS) */
	int stop_pend;			/* a stop token's busy is still being sent */
	unsigned stop_ends;		/* stop-token busy periods sent to their end (mock_card_stop_ends) */
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
	card.busy_stuck = 0; card.crc_on = 0; card.werr = 0; card.stop_pend = 0;
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
	{
		static const unsigned char cid0[16] = { 0x03, 'S', 'D', 'M', 'O', 'C', 'K', '1', 0x10,
		                                        0x12, 0x34, 0x56, 0x78, 0x01, 0x9A, 0x01 };
		memcpy(card.cid, cid0, 16);
	}
	card.acmd22_less = card.acmd22_times = 0;
	card.wrrej_every = 0;
	card.stale12_n = 0;
	card.cs_keep = 0;
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
	/* in idle state (after power-on or CMD0, before ACMD41 / CMD1) a card
	   takes no data or register command: R1 idle + illegal */
	if (card.idle && !was_app && (card.cidx == 9 || card.cidx == 10 || card.cidx == 12 ||
	    card.cidx == 17 || card.cidx == 18 || card.cidx == 24 || card.cidx == 25)) {
		c_push_r1(0x05);
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
			unsigned w = card.wr_ok;
			if (card.acmd22_times && w >= card.acmd22_less) {	/* mock_card_acmd22_less */
				w -= card.acmd22_less;
				card.acmd22_times--;
			}
			unsigned char d[4] = { w >> 24, w >> 16, w >> 8, w };
			c_push_r1(0x00);
			if (card.tok_dly >= 0) c_push_data(d, 4, 0);
		} else
			c_push_r1(0x04);
		break;
	case 10:			/* CID */
		c_push_r1(0x00);
		if (card.tok_dly >= 0) c_push_data(card.cid, 16, 0);
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
		if (card.stale12_n) { card.stale12_n--; c_push(card.stale12); }	/* mock_card_cmd12_stale */
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
	else if (card.wrrej_every && card.wr_blk_n % card.wrrej_every == 0) inj = 0x0B;
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
			else if (card.wmulti && b == 0xFD) { card.wstate = 0; c_push(0xFF); c_push_busy(); card.stop_pend = 1; }
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
	/* the stop token's busy: its last byte is on its way, the next is FF */
	if (card.stop_pend && card.qh == card.qt && !card.busy_stuck) { card.stop_pend = 0; card.stop_ends++; }
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
/* the same for a byte from the SD peripheral (its blocks carry real CRCs) */
unsigned char mock_card_xchg_sdc(unsigned char out)
{
	unsigned char in;
	card_via_sdc = 1;
	in = card_xchg(out);
	card_via_sdc = 0;
	return in;
}

static void card_select(void) { card.cmdcnt = 0; card.txb = 0xFF; }
static void card_deselect(void)
{
	card.cmdcnt = 0;
	if (card.cs_keep)	/* mock_card_cs_keeps: a write / read run stays open */
		return;
	card.qh = card.qt; card.rd_multi = 0; card.wstate = 0;
	card.busy_stuck = 0; card.stop_pend = 0;
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
void mock_card_cid(const unsigned char cid[16]) { memcpy(card.cid, cid, 16); }
void mock_card_acmd22_less(unsigned n, unsigned times) { card.acmd22_less = n; card.acmd22_times = times; }
void mock_card_wrrej_every(unsigned k) { card.wrrej_every = k; }
void mock_card_cmd12_stale(unsigned char b, unsigned times) { card.stale12 = b; card.stale12_n = times; }
void mock_card_cs_keeps(int on) { card.cs_keep = on; }
unsigned mock_card_blocks_read(void) { return card.rd_blk_n; }
unsigned mock_card_wr_ok(void) { return card.wr_ok; }
unsigned mock_card_stop_ends(void) { return card.stop_ends; }
int mock_card_stop_busy(void) { return card.stop_pend; }
int mock_card_idle(void)
{
	return !card.gone && card.wstate == 0 && card.qh == card.qt && !card.busy_stuck && !card.rd_multi &&
	       !card.stop_pend && card.cmdcnt == 0;
}

/* the card's chip select: cfide's CS bit 1 (the old path) or the SD
   peripheral's CFG bit 8 */
static unsigned scs;				/* cfide's scs register */
void mock_card_sel_update(void)
{
	int s = (scs & 2) || mock_sdc_cs_now();
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
	if (!(scs & 0x10) && (n & 0x10)) mock_gayle_cs_open();
	scs = n;
	mock_card_sel_update();
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

/* time passes in cycles (register accesses, the peripheral's own steps):
   the TIMER moves with it */
void mock_time_cycles(unsigned long long c)
{
	now += c;
	sub += c;
	while (sub >= MOCK_CYC_PER_TIMER) { sub -= MOCK_CYC_PER_TIMER; timer_count++; }
	mock_sdc_run(now);
}
/* time passes in TIMER counts (the old knobs) */
void mock_time_counts(unsigned n)
{
	timer_count += n;
	now += (unsigned long long)n * MOCK_CYC_PER_TIMER;
	mock_sdc_run(now);
}
unsigned long long mock_now(void) { return now; }

/* ---------------------------------------------------------------- TIMER */
static unsigned timer_step, timer_reads, timer_spi_rate, timer_spi_bytes;

void hosttest_advance(unsigned n) { mock_time_counts(n); }
void mock_timer_step(unsigned n) { timer_step = n; }
void mock_timer_spi_rate(unsigned n) { timer_spi_rate = n; timer_spi_bytes = 0; }
static void timer_spi_byte(void)
{
	if (timer_spi_rate && ++timer_spi_bytes == timer_spi_rate) { mock_time_counts(1); timer_spi_bytes = 0; }
}
unsigned mock_timer_reads(void) { return timer_reads; }
unsigned short hosttest_timer(void)
{
	unsigned short v = (unsigned short)timer_count;
	mock_time_counts(timer_step);
	timer_reads++;
	mock_irq_deliver();
	return v;
}
/* the TIMER's value without a read: no time passes, not counted (sdc.c's
   trace timestamp under HOSTTEST) */
unsigned short hosttest_timer_peek(void) { return (unsigned short)timer_count; }

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
/* the two Video Pos registers (cfide pos_data_q / pos_rtg_q) */
static unsigned int vpos_reg[2];
volatile unsigned int *hosttest_vpos(int rtg) { return &vpos_reg[rtg ? 1 : 0]; }
unsigned mock_vpos(int rtg) { return vpos_reg[rtg ? 1 : 0]; }
void mock_vpos_set(int rtg, unsigned v) { vpos_reg[rtg ? 1 : 0] = v; }

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
	vpos_reg[0] = vpos_reg[1] = 0;
	memset(__bss_end, 0, sizeof __bss_end);
	mock_sdc_reset();
}

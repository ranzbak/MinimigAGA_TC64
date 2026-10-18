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
volatile unsigned short *hosttest_platform(void);
volatile unsigned char *hosttest_audio(void);
void hosttest_uart(int c);

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

/* ------------------------------------------------------------------ card */
#define QSZ 4096
static struct {
	unsigned char *mem;
	unsigned sectors;
	int tok_dly, busy_n, ncr, init_polls;
	unsigned char q[QSZ];
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
} card;

static void c_push(unsigned char b) { card.q[card.qt++ % QSZ] = b; }
static void c_push_r1(unsigned char r)
{
	for (int n = 0; n < card.ncr; n++) c_push(0xFF);
	c_push(r);
}
static void c_push_busy(void)
{
	if (card.busy_n < 0) card.busy_stuck = 1;
	for (int n = 0; n < card.busy_n; n++) c_push(0x00);
}
static void c_push_block(unsigned lba)
{
	if (card.tok_dly < 0) return;	/* no token, ever */
	for (int n = 0; n < card.tok_dly; n++) c_push(0xFF);
	c_push(0xFE);
	for (int n = 0; n < 512; n++) c_push(card.mem[(size_t)lba * 512 + n]);
	c_push(0x00); c_push(0x00);
}

static void card_state_reset(void)
{
	card.tok_dly = 4; card.busy_n = 8; card.ncr = 1; card.init_polls = 2;
	card.qh = card.qt = 0; card.txb = 0xFF; card.cmdcnt = 0;
	card.app_cmd = 0; card.idle = 1; card.ready = 0; card.polls = 0;
	card.rd_multi = 0; card.wstate = 0; card.wmulti = 0;
	card.rd_lba = card.wlba = 0; card.wcnt = 0; card.commands = 0;
	card.busy_stuck = 0; card.log.n = 0;
}

static void card_do_cmd(void)
{
	int was_app = card.app_cmd;
	char line[40];
	card.app_cmd = 0;
	card.commands++;
	snprintf(line, sizeof line, "%sCMD%u arg=%08x\n", was_app ? "A" : "", card.cidx, card.carg);
	buf_put(&card.log, line, strlen(line));
	switch (card.cidx) {
	case 0:
		card.idle = 1; card.ready = 0; card.polls = 0; card.app_cmd = 0;
		card.rd_multi = 0; card.wstate = 0; card.busy_stuck = 0;
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
	case 9: {			/* CSD v2.0 */
		unsigned csize = card.sectors / 1024 - 1;
		c_push_r1(0x00);
		if (card.tok_dly < 0) break;	/* no token, ever */
		for (int n = 0; n < card.tok_dly; n++) c_push(0xFF);
		c_push(0xFE);
		for (int n = 0; n < 16; n++) {
			switch (n) {
			case 0: c_push(0x40); break;
			case 7: c_push((csize >> 16) & 0x3F); break;
			case 8: c_push((csize >> 8) & 0xFF); break;
			case 9: c_push(csize & 0xFF); break;
			default: c_push(0x00);
			}
		}
		c_push(0x00); c_push(0x00);
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
			card.wlba = card.carg;
		}
		break;
	default:
		c_push_r1(0x04);	/* illegal command */
	}
}

/* one received byte; sets txb for the next 8 clocks */
static void card_on_byte(unsigned char b)
{
	if (card.wstate != 0) {
		switch (card.wstate) {
		case 1:
			if (b == 0xFE || (card.wmulti && b == 0xFC)) { card.wstate = 2; card.wcnt = 0; }
			else if (card.wmulti && b == 0xFD) { card.wstate = 0; c_push(0xFF); c_push_busy(); }
			break;
		case 2:
			card.wbuf[card.wcnt++] = b;
			if (card.wcnt == 512) { card.wstate = 3; card.wcnt = 0; }
			break;
		case 3:
			if (++card.wcnt == 2) {
				memcpy(card.mem + (size_t)card.wlba * 512, card.wbuf, 512);
				c_push(0x05); c_push_busy();
				if (card.wmulti) { card.wstate = 1; card.wlba++; }
				else card.wstate = 0;
			}
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
	if (card.qh != card.qt) card.txb = card.q[card.qh++ % QSZ];
	else card.txb = card.busy_stuck ? 0x00 : 0xFF;
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
static unsigned scs;				/* cfide's scs register */
static unsigned spi_speed;
static unsigned char last_in;

static struct buf speed_log;			/* mock_spi_speed_log */
static void timer_spi_byte(void);

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
	if (!(scs & 2) && (n & 2)) card_select();
	if ((scs & 2) && !(n & 2)) card_deselect();
	scs = n;
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
		for (int n = 0; n < 512; n++) {
			in = card.txb;
			card_on_byte(ff);
			buf_put(&fr_out, &ff, 1);
			buf_put(&fr_in, &in, 1);
			timer_spi_byte();
		}
		last_in = in;
		return in;
	}
	if (scs & 2) {
		in = card.txb;
		card_on_byte(out);
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

unsigned char hosttest_rdspi(void) { return last_in; }

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

/* ---------------------------------------------------------------- TIMER */
static unsigned timer_count, timer_step, timer_reads, timer_spi_rate, timer_spi_bytes;

void hosttest_advance(unsigned n) { timer_count += n; }
void mock_timer_step(unsigned n) { timer_step = n; }
void mock_timer_spi_rate(unsigned n) { timer_spi_rate = n; timer_spi_bytes = 0; }
static void timer_spi_byte(void)
{
	if (timer_spi_rate && ++timer_spi_bytes == timer_spi_rate) { timer_count++; timer_spi_bytes = 0; }
}
unsigned mock_timer_reads(void) { return timer_reads; }
unsigned short hosttest_timer(void)
{
	unsigned short v = (unsigned short)timer_count;
	timer_count += timer_step;
	timer_reads++;
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
	frames = 0; fr_cs = 0; scs = 0; spi_speed = 0; last_in = 0xFF;
	free(card.mem);
	free(card.log.p);
	memset(&card, 0, sizeof card);
	card_state_reset();
	free(speed_log.p); memset(&speed_log, 0, sizeof speed_log);
	timer_count = 0; timer_step = 1; timer_reads = 0; timer_spi_rate = 0; timer_spi_bytes = 0;
	mock_uart_clear();
	platform_reg = 0; audio_reg = 0;
}

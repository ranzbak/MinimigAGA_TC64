/* mock_sdc.c: the SD card peripheral (rtl/host/sdcard_spi.v), its Gayle
 * bridge, cfide's interrupt controller with the CPU's MIE, and the stepping
 * of time; see mock_hw.h.  Moved out of mock_hw.c unchanged (Task 9 fix
 * round 1); the card, the clock and the TIMER stay there (mock_int.h is
 * what the two share).  Host tests only. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "mock_hw.h"
#include "mock_int.h"

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

#define die mock_die
#define buf_put mock_buf_put
#define buf_str mock_buf_str
#define crc16 mock_crc16
#define time_cycles mock_time_cycles
#define time_counts mock_time_counts
#define now (mock_now())
static void irq_deliver(void);
static unsigned gayle_violations;

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
	int misuse_fatal;
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
	unsigned stalls;		/* times a GAYLE_TO_TX waited so (mock_gayle_stalls) */
	unsigned errs;			/* Gayle ops ended by a Gayle error (mock_gayle_errs) */
	int since[2];			/* sdcard_gayle.v cmd_since: abandoned (mock_gayle_abandon) */
	void (*on_end)(void *);		/* mock_gayle_on_end */
	void *on_end_ctx;
} gay;

int mock_sdc_cs_now(void) { return sdc.cs; }
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

/* STATUS 8 is always a firmware bug: fatal unless a test provokes it on
   purpose (mock_sdc_misuse_fatal(0)) */
static void misuse(void)
{
	if (sdc.misuse_fatal)
		die("SD peripheral: FIFO misuse (STATUS 8: a push into a full TX, a pop past RXLVL, "
		    "the data port during a Gayle op): a firmware bug");
	sdc.st |= ST_MISUSE;
	sdc.pend |= I_ERR;
}

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
	if (sdc.cs) in = mock_card_xchg_sdc(out);
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
	if (is_gayle(sdc.op) && why == END_GERR) gay.errs++;
	if (is_gayle(sdc.op) && why == END_NORMAL && gay.on_end) {
		void (*fn)(void *) = gay.on_end;
		sdc.busy = 0;			/* the op is over when the test acts */
		fn(gay.on_end_ctx);
	}
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
	if (gay.end_how != MOCK_GAYLE_OK && gay.words == gay.end_words) {
		/* g_err: the Amiga's FIFO was reset (a new command, a reset): the
		   rest of its sector is gone with it */
		if (gay.end_how == MOCK_GAYLE_ERR && sdc.op == OP_G2TX) gay.from_head[port] = gay.from[port].n;
		sdc_end(END_GERR);
		return;
	}
	if (gay.words == sdc.len / 2) { sdc_end(END_NORMAL); return; }	/* g_ack, all words */
	if (sdc.op == OP_RX2G) {
		unsigned char w[2];
		w[0] = sdc.rx[sdc.rx_rd++ & 1023];
		w[1] = sdc.rx[sdc.rx_rd++ & 1023];
		sdc.verified = sdc.verified > 2 ? sdc.verified - 2 : 0;
		buf_put(&gay.into[port], w, 2);
	} else {
		if (gay.from[port].n - gay.from_head[port] < 2) { gay.stalled = 1; gay.stalls++; return; }
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
void mock_sdc_run(unsigned long long until)
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
	else if (sdc.busy && is_gayle(op) && gay.since[(v >> 8) & 1]) sdc_end(END_GERR);	/* abandoned: g_err, no word */
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
			mock_card_sel_update();
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
	case 0x2C: v = 0x5D02; break;			/* VERSION */
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
void mock_sdc_misuse_fatal(int on) { sdc.misuse_fatal = on; }
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
unsigned mock_gayle_stalls(void) { return gay.stalls; }
unsigned mock_gayle_errs(void) { return gay.errs; }
size_t mock_gayle_from_left(unsigned port) { return gay.from[port & 1].n - gay.from_head[port & 1]; }
int mock_gayle_from_pop(unsigned port)
{
	port &= 1;
	if (gay.from_head[port] >= gay.from[port].n) return -1;
	return gay.from[port].p[gay.from_head[port]++];
}
void mock_gayle_abandon(unsigned port)
{
	port &= 1;
	gay.since[port] = 1;
	gay.from_head[port] = gay.from[port].n;		/* the FIFO reset */
	if (gayle_op_busy() && ((sdc.cmd >> 8) & 1) == port) sdc_end(END_GERR);
	irq_deliver();
}
void mock_gayle_seen(unsigned port) { gay.since[port & 1] = 0; }
void mock_gayle_on_end(void (*fn)(void *ctx), void *ctx) { gay.on_end = fn; gay.on_end_ctx = ctx; }
/* cfide's CS register opened cs 0x10 (an IDE command over scs(4)) */
void mock_gayle_cs_open(void) { if (gayle_op_busy()) gayle_violations++; }

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

/* traps taken up to the last hosttest_sdc_idle(): an interrupt since then
   (an op that ended in sdc_wait's TIMER read, whose time step lets the
   peripheral run) is progress: sdc_wait looks at sdc_events again */
static unsigned idle_traps;
void hosttest_sdc_idle(void)
{
	if (!irqc_mie || irqc_in_trap) die("sdc_wait with interrupts off: no event can arrive");
	if (irqc_traps != idle_traps) { idle_traps = irqc_traps; return; }
	if (mock_sdc_step() || irqc_traps != idle_traps) { idle_traps = irqc_traps; return; }
	if (sdc.stall_fn && sdc.stall_fn(sdc.stall_ctx)) { irq_deliver(); return; }
	if (sdc.stall_fatal)
		die("sdc_wait: the mock can make no progress (nothing busy, no event pending): a firmware bug");
	time_counts(1);				/* the CPU polls, time passes */
	irq_deliver();
}

void mock_sdc_reset(void)
{
	free(sdc.log.p); free(sdc.wire.p); free(sdc.wo.p); free(sdc.wi.p);
	memset(&sdc, 0, sizeof sdc);
	sdc.div = 0xFF;				/* reset: CFG 00FF, CS off */
	sdc.cd_raw = sdc.cd_stable = 1;		/* a card present at reset: no change IRQ */
	sdc.access_cyc = 16;
	sdc.stall_fatal = 1;
	sdc.misuse_fatal = 1;
	sdc_levels();				/* IRQPEND 0006 */
	for (int p = 0; p < 2; p++) { free(gay.from[p].p); free(gay.into[p].p); }
	memset(&gay, 0, sizeof gay);
	gay.word_cyc = 12;
	gayle_violations = 0;
	irqc_mie = 1; irqc_in_trap = 0; irqc_traps = 0; irqc_stale = 0; idle_traps = 0;
	irqc_mask = 0; irqc_mode = 0; irqc_edge = 0; irqc_prev = 0; irqc_ext = 0; irqc_last_level = 0;
	legacy_reg = 0;
}


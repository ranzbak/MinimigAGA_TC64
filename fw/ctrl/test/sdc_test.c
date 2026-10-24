/* sdc_test: the SD card peripheral driver (../sdc.c, findings/sdcard-engine
 * Task 9) on the mock peripheral (mock_hw.c, the model of
 * rtl/host/sdcard_spi.v's header contract) and the mock card (the model of
 * sim/common/sd_spi_model.v's Task 4 behaviour), with the real interrupt
 * dispatcher (../arch/irq.c) on the mock interrupt controller.
 *   make -C fw/ctrl/test run-sdc_test
 * Sections:
 *   irq     the interrupt migration: IrqSetupSources() (cut out of main.c)
 *           puts vblank on c64keys_inthandler and the Akiko request on
 *           akiko_inthandler (stubs here), EDGE, the legacy register off
 *   brief   the plan's step 1: push + XFER -> the card logs CMD0, sdc_wait
 *           returns with sdc_events bit 0, an RX XFER pops R1 + OCR, IRQEN
 *           off -> no event
 *   driver  sdc_init, sdc_start's refusals, sdc_wait's wake-ups (error,
 *           card detect), its HOSTTEST abort and its TIMER bound, the
 *           one-shot watermark bits, CFG, push / pop, the event trace
 *   periph  the mock against the header contract (reset values, byte time,
 *           a 500 ms card busy against TIMEOUT,
 *           TX keep / commit / rewind, CRC16 out and in, the interlock,
 *           wait ops and TIMEOUT, pauses, FIFO misuse, refused CFG, ABORT,
 *           card gone, card detect, level-sticky watermarks)
 *   gayle   ops 4 and 5 on the mock bridge: words, the locked data port,
 *           g_err / short g_ack with the TX rollback, Amiga pace, the cs
 *           0x10 rule
 *   card    the card's Task 4 behaviour: CMD59 / CRC7, CRC16 on writes,
 *           CMD13, CMD25 + stop token, ACMD22, RDCRC / WRREJ / WRFAIL /
 *           NORESP / CMDCRC with repeat counts, remove / insert
 * Expected values come from the contract texts (the RTL header,
 * sd_spi_model.v's), with CRC7 / CRC16 known answers computed by python
 * (the spec's CMD0 0x95 and CMD8 0x87; CRC16 of "123456789" = 0x31C3), not
 * from the code under test.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <sys/wait.h>

#include "hardware.h"
#include "irq.h"
#include "sdc.h"
#include "c64keys.h"
#include "akiko.h"
#include "mock_hw.h"

static int fails, cases;
static void check(const char *what, long got, long want)
{
	cases++;
	if (got != want) {
		printf("FAIL %s: got %ld (0x%lx), want %ld (0x%lx)\n", what, got, (unsigned long)got,
		       want, (unsigned long)want);
		fails++;
	} else
		printf("ok   %s = %ld\n", what, got);
}
static void check_str(const char *what, const char *got, const char *want)
{
	cases++;
	if (strcmp(got, want)) {
		printf("FAIL %s: got \"%s\", want \"%s\"\n", what, got, want);
		fails++;
	} else
		printf("ok   %s\n", what);
}
static void check_has(const char *what, const char *hay, const char *needle)
{
	cases++;
	if (!strstr(hay, needle)) {
		printf("FAIL %s: \"%s\" not in \"%.400s\"\n", what, needle, hay);
		fails++;
	} else
		printf("ok   %s\n", what);
}

/* ---- the interrupt migration: main.c's IrqSetupSources() on stubs ---- */
static int n_vbl, n_akiko;
static char hseq[32];
static void hput(char c) { size_t n = strlen(hseq); if (n < sizeof hseq - 1) hseq[n] = c; }
void c64keys_inthandler(void) { n_vbl++; hput('V'); }
void akiko_inthandler(void) { n_akiko++; hput('A'); }
#include "irqsetup.inc"

static void t_irq(void)
{
	uint32_t s;

	mock_reset();
	SetIntHandler(NULL);
	IrqSetupSources();
	check("irq: MASK = vblank + Akiko", mock_irq_mask(), 0x05);
	check("irq: both EDGE", mock_irq_mode() & 0x05, 0);
	check("irq: legacy INTERRUPT register off", mock_interrupt_reg(), 0);
	mock_irq_pulse(IRQ_VBLANK);
	check("irq: vblank -> c64keys_inthandler", n_vbl, 1);
	check("irq: vblank -> not akiko_inthandler", n_akiko, 0);
	mock_irq_pulse(IRQ_AKIKO);
	check("irq: Akiko -> akiko_inthandler", n_akiko, 1);
	check("irq: Akiko -> not c64keys_inthandler", n_vbl, 1);
	memset(hseq, 0, sizeof hseq);
	s = irq_save();
	mock_irq_pulse(IRQ_AKIKO);
	mock_irq_pulse(IRQ_VBLANK);
	check("irq: nothing taken inside irq_save", n_vbl + n_akiko, 2);
	irq_restore(s);
	check_str("irq: both at irq_restore, bit order", hseq, "VA");
	IrqDisable(IRQ_VBLANK);
	mock_irq_pulse(IRQ_VBLANK);
	check("irq: masked vblank not taken", n_vbl, 2);
	IrqEnable(IRQ_VBLANK);
	check("irq: the masked EDGE event delivered at IrqEnable", n_vbl, 3);
	IrqDisable(IRQ_VBLANK);
	IrqDisable(IRQ_AKIKO);
}

/* ---- helpers ---- */
/* CRC7 / CRC16 of the SD spec (the test's own, checked against python's
   known answers in t_crc) */
static unsigned crc7(const unsigned char *d, unsigned n)
{
	unsigned c = 0;
	for (unsigned k = 0; k < n; k++)
		for (int i = 7; i >= 0; i--)
			c = ((c << 1) & 0x7F) ^ ((((c >> 6) ^ (d[k] >> i)) & 1) ? 0x09 : 0);
	return (c << 1) | 1;
}
static unsigned crc16(const unsigned char *d, unsigned n)
{
	unsigned c = 0;
	for (unsigned k = 0; k < n; k++)
		for (int i = 7; i >= 0; i--)
			c = ((c << 1) & 0xFFFF) ^ ((((c >> 15) ^ (d[k] >> i)) & 1) ? 0x1021 : 0);
	return c;
}
static void frame(unsigned char *f, unsigned idx, unsigned arg, unsigned char crc)
{
	f[0] = 0x40 | idx;
	f[1] = arg >> 24; f[2] = arg >> 16; f[3] = arg >> 8; f[4] = arg;
	f[5] = crc;
}

/* an op through the driver, to its end; returns STATUS */
static unsigned op(unsigned cmd, unsigned len)
{
	if (sdc_start(cmd, len)) { printf("     (op %04x refused)\n", cmd); return 0xFFFF; }
	sdc_wait(SDC_IRQ_DONE);
	return sdc_status();
}
/* raw: the peripheral to idle by mock steps (no driver, no interrupt needed) */
static void until_idle(void)
{
	for (int n = 0; (SDC_R(SDC_STATUS) & SDC_ST_BUSY) && n < 1000000; n++)
		if (!mock_sdc_step()) break;
}
/* a command frame with CRC7 `crc` (0: the right one), sent and committed;
   the first byte that is not FF within 2 TIMEOUT units: R1, or FF */
static unsigned sdcmd_crc(unsigned idx, unsigned arg, unsigned crc)
{
	unsigned char f[6];
	frame(f, idx, arg, 0);
	f[5] = crc ? crc : crc7(f, 5);
	sdc_push(f, 6);
	op(SDC_OP_XFER | SDC_X_TX, 6);
	op(SDC_OP_TX_COMMIT, 0);
	SDC_W(SDC_MATCH, 0xFF);
	SDC_W(SDC_TIMEOUT, 2);
	op(SDC_OP_WAIT_NE, 0);
	return SDC_R(SDC_LAST);
}
static unsigned sdcmd(unsigned idx, unsigned arg) { return sdcmd_crc(idx, arg, 0); }
/* a fresh mock, the driver, a card of 2048 sectors, SCK at div 2, CS on */
static void setup(void)
{
	mock_reset();
	mock_timer_step(0);
	mock_card_new(2048);
	sdc_init();
	sdc_set_div(SDC_DIV_MIN);
	sdc_select(1);
}
/* the card through CMD0, CMD8, ACMD41 until ready, CMD58 */
static void card_init(void)
{
	unsigned r = 0xFF;
	sdcmd(0, 0);
	sdcmd(8, 0x1AA);
	op(SDC_OP_XFER | SDC_X_RX, 4);
	op(SDC_OP_RX_FLUSH, 0);
	for (int k = 0; k < 10 && r != 0; k++) {
		sdcmd(55, 0);
		r = sdcmd(41, 0x40000000);
	}
	check("card init: ACMD41 ready", r, 0);
}
/* the data token, then `n` bytes + CRC16 checked; STATUS */
static unsigned read_data(unsigned n, unsigned extra)
{
	SDC_W(SDC_MATCH, 0xFE);
	SDC_W(SDC_TIMEOUT, 4);
	if (op(SDC_OP_WAIT_EQ, 0) & SDC_ST_TIMEOUT) return 0xFFFF;
	return op(SDC_OP_XFER | SDC_X_RX | SDC_X_RXCRC | extra, n);
}
/* the card's data response after a block; then its busy */
static unsigned data_response(void)
{
	unsigned r;
	SDC_W(SDC_MATCH, 0xFF);
	SDC_W(SDC_TIMEOUT, 4);
	op(SDC_OP_WAIT_NE, 0);
	r = SDC_R(SDC_LAST) & 0x1F;
	SDC_W(SDC_MATCH, 0x00);
	SDC_W(SDC_TIMEOUT, 100);
	op(SDC_OP_WAIT_NE, 0);		/* busy over */
	return r;
}
/* a 512-byte block written from TX with token `tok`: CRC16 by the
   peripheral (or a wrong one), then the data response */
static unsigned write_block(const unsigned char *d, unsigned char tok, int bad_crc)
{
	sdc_push(&tok, 1);
	sdc_push(d, 512);
	op(SDC_OP_XFER | SDC_X_TX, 1);		/* the token: not in the CRC16 */
	if (bad_crc) {
		unsigned char c[2] = { 0x12, 0x34 };
		sdc_push(c, 2);
		op(SDC_OP_XFER | SDC_X_TX, 514);
	} else
		op(SDC_OP_XFER | SDC_X_TX | SDC_X_TXCRC, 512);
	op(SDC_OP_TX_COMMIT, 0);
	return data_response();
}
static void pattern(unsigned char *d, unsigned seed)
{
	for (unsigned k = 0; k < 512; k++) d[k] = (unsigned char)(seed * 37 + k * 11 + (k >> 8));
}

/* ---- known answers of the test's CRCs ---- */
static void t_crc(void)
{
	unsigned char f[6];
	frame(f, 0, 0, 0);
	check("crc: CRC7 CMD0 = 0x95", crc7(f, 5), 0x95);
	frame(f, 8, 0x1AA, 0);
	check("crc: CRC7 CMD8 1AA = 0x87", crc7(f, 5), 0x87);
	frame(f, 59, 1, 0);
	check("crc: CRC7 CMD59 1 = 0x83 (python)", crc7(f, 5), 0x83);
	check("crc: CRC16 \"123456789\" = 0x31C3", crc16((const unsigned char *)"123456789", 9), 0x31C3);
}

/* ---- brief step 1 ---- */
static void t_brief(void)
{
	unsigned char f[6], r[8];
	int rc;

	mock_reset();
	mock_timer_step(0);
	mock_card_new(2048);
	sdc_init();
	sdc_select(1);
	frame(f, 0, 0, 0x95);
	sdc_push(f, 6);
	rc = sdc_start(SDC_OP_XFER | SDC_X_TX, 6);
	check("brief: sdc_start XFER 6", rc, 0);
	rc = sdc_wait(SDC_IRQ_DONE);
	check("brief: sdc_wait(DONE) returns DONE", rc & SDC_IRQ_DONE, SDC_IRQ_DONE);
	check("brief: sdc_events bit 0", sdc_events & SDC_IRQ_DONE, SDC_IRQ_DONE);
	check_str("brief: the card logged CMD0", mock_card_log(), "CMD0 arg=00000000\n");
	sdc_start(SDC_OP_TX_COMMIT, 0);
	sdc_wait(SDC_IRQ_DONE);

	/* CMD58 before the card is ready: R1 01, OCR 00 FF 80 00 */
	frame(f, 58, 0, 0xFD);
	sdc_push(f, 6);
	sdc_start(SDC_OP_XFER | SDC_X_TX, 6);
	sdc_wait(SDC_IRQ_DONE);
	sdc_start(SDC_OP_TX_COMMIT, 0);
	sdc_wait(SDC_IRQ_DONE);
	sdc_start(SDC_OP_XFER | SDC_X_RX, 8);
	sdc_wait(SDC_IRQ_DONE);
	check("brief: RXLVL after an RX XFER of 8", SDC_R(SDC_RXLVL), 8);
	sdc_pop(r, 8);
	/* NCR 1 byte FF, R1 01 (idle), OCR 00 FF 80 00, then FF FF */
	{
		static const unsigned char want[8] = { 0xFF, 0x01, 0x00, 0xFF, 0x80, 0x00, 0xFF, 0xFF };
		check("brief: RX bytes = NCR, R1, OCR, idle", memcmp(r, want, 8), 0);
	}

	/* IRQEN off: the op ends (IRQPEND bit 0 in the peripheral), no event */
	SDC_W(SDC_IRQEN, 0);
	sdc_clear(SDC_IRQ_DONE | SDC_IRQ_ERR);
	rc = sdc_start(SDC_OP_XFER, 4);
	check("brief: IRQEN 0, sdc_start", rc, 0);
	while (SDC_R(SDC_STATUS) & SDC_ST_BUSY)
		mock_sdc_step();
	check("brief: IRQEN 0, IRQPEND bit 0 set", SDC_R(SDC_IRQPEND) & SDC_IRQ_DONE, SDC_IRQ_DONE);
	check("brief: IRQEN 0, no event", sdc_events & SDC_IRQ_DONE, 0);
}

/* ---- the driver ---- */
static void t_init(void)
{
	unsigned char b[3] = { 1, 2, 3 };

	mock_reset();
	mock_timer_step(0);
	/* state left behind by an earlier run: an op running, bytes in TX */
	SDC_W(SDC_CFG, 0x0105);
	sdc_push(b, 3);
	SDC_W(SDC_IRQEN, 0x1F);
	SDC_W(SDC_MATCH, 0x00);
	SDC_W(SDC_TIMEOUT, 1000);
	SDC_W(SDC_CMD, SDC_OP_WAIT_EQ);
	check("init: an op runs before", SDC_R(SDC_STATUS) & SDC_ST_BUSY, SDC_ST_BUSY);
	sdc_init();
	check("init: not busy (ABORT)", SDC_R(SDC_STATUS) & SDC_ST_BUSY, 0);
	check_has("init: ABORT written", mock_sdc_log(), "ABORT\n");
	check("init: CFG = div 141, CS off", SDC_R(SDC_CFG), SDC_DIV_INIT);
	check("init: TX flushed", SDC_R(SDC_TXLVL), 0);
	check("init: RX flushed", SDC_R(SDC_RXLVL), 0);
	check("init: IRQEN = done, error, card detect", SDC_R(SDC_IRQEN), SDC_IRQ_DONE | SDC_IRQ_ERR | SDC_IRQ_CD);
	check("init: nothing enabled pending", SDC_R(SDC_IRQPEND) & SDC_R(SDC_IRQEN), 0);
	check("init: sdc_events 0", sdc_events, 0);
	check("init: controller bit 4 enabled", mock_irq_mask() & (1u << IRQ_SDCARD), 1u << IRQ_SDCARD);
	check("init: controller bit 4 LEVEL", mock_irq_mode() & (1u << IRQ_SDCARD), 1u << IRQ_SDCARD);
	check("init: WMARK 0 (RX high and TX low hold)", SDC_R(SDC_IRQPEND) & 0x06, 0x06);
}

static void t_refuse(void)
{
	unsigned h, st;
	int rc;

	setup();
	/* busy: the driver does not write the CMD */
	sdc_set_div(255);
	sdc_start(SDC_OP_XFER, 100);
	h = sdc_trace_head;
	rc = sdc_start(SDC_OP_XFER, 4);
	check("refuse: busy -> -1", rc, -1);
	check("refuse: busy -> trace BUSY", sdc_trace[h % SDC_TRACE_N].what, SDC_TR_BUSY | SDC_OP_XFER);
	check("refuse: busy -> no refusal in the peripheral", SDC_R(SDC_STATUS) & SDC_ST_REFUSED, 0);
	sdc_wait(SDC_IRQ_DONE);
	/* the cycle after an op end */
	mock_sdc_refuse_next();
	h = sdc_trace_head;
	rc = sdc_start(SDC_OP_TX_FLUSH, 0);
	check("refuse: cycle after an op end -> -1", rc, -1);
	check("refuse: STATUS bit 6", SDC_R(SDC_STATUS) & SDC_ST_REFUSED, SDC_ST_REFUSED);
	check("refuse: its ERR acknowledged", SDC_R(SDC_IRQPEND) & SDC_IRQ_ERR, 0);
	check("refuse: no ERR event", sdc_events & SDC_IRQ_ERR, 0);
	check("refuse: trace REFUSED", sdc_trace[h % SDC_TRACE_N].what, SDC_TR_REFUSED | SDC_OP_TX_FLUSH);
	check("refuse: XFER bits 6 + 7", sdc_start(SDC_OP_XFER | SDC_X_TXCRC | SDC_X_RXCRC, 4), -1);
	check("refuse: op 0", sdc_start(0, 0), -1);
	check("refuse: op 12", sdc_start(12, 0), -1);
	check("refuse: GAYLE_TO_TX odd LEN", sdc_start(SDC_OP_GAYLE_TO_TX, 3), -1);
	check("refuse: GAYLE_TO_TX LEN 0", sdc_start(SDC_OP_GAYLE_TO_TX, 0), -1);
	check("refuse: RX_TO_GAYLE nothing verified", sdc_start(SDC_OP_RX_TO_GAYLE, 2), -1);
	rc = sdc_start(SDC_OP_TX_FLUSH, 0);
	check("refuse: then an accepted op", rc, 0);
	sdc_wait(SDC_IRQ_DONE);
	st = SDC_R(SDC_STATUS);
	check("refuse: accepted clears STATUS 6", st & SDC_ST_REFUSED, 0);
	/* ABORT is never refused, and gives a DONE when idle */
	sdc_clear(SDC_IRQ_ALL);
	check("refuse: ABORT idle -> 0", sdc_start(SDC_OP_ABORT, 0), 0);
	check("refuse: ABORT idle -> DONE", sdc_wait(SDC_IRQ_DONE), SDC_IRQ_DONE);
}

static int forked_wait_aborts(void)
{
	pid_t p = fork();
	int ws;
	if (p == 0) {
		mock_reset();
		mock_timer_step(0);
		sdc_init();
		sdc_wait(SDC_IRQ_DONE);		/* nothing runs: the mock aborts */
		_exit(0);
	}
	if (p < 0 || waitpid(p, &ws, 0) != p) return -1;
	return WIFSIGNALED(ws) ? WTERMSIG(ws) : 0;
}

static void t_wait(void)
{
	unsigned long long t0;
	unsigned r, h, t;
	int rc;

	/* a timeout: DONE and ERR; a mask without DONE still wakes on ERR */
	setup();
	sdc_select(0);				/* MISO stays FF */
	SDC_W(SDC_MATCH, 0xFE);
	SDC_W(SDC_TIMEOUT, 1);
	sdc_start(SDC_OP_WAIT_EQ, 0);
	r = sdc_wait(SDC_IRQ_TXLO);
	check("wait: wakes on ERR (mask TXLO)", r, SDC_IRQ_ERR);
	check("wait: timeout in STATUS", sdc_status() & SDC_ST_TIMEOUT, SDC_ST_TIMEOUT);
	check("wait: DONE latched too", sdc_events & SDC_IRQ_DONE, SDC_IRQ_DONE);
	/* card detect change */
	sdc_clear(SDC_IRQ_ALL);
	t0 = mock_now();
	mock_sdc_cd(0);
	r = sdc_wait(SDC_IRQ_RXHI);
	check("wait: wakes on card detect", r, SDC_IRQ_CD);
	check("wait: after the 2^20-cycle debounce", mock_now() - t0 >= (1ULL << 20), 1);
	check("wait: STATUS card bit 0", sdc_status() & SDC_ST_CARD, 0);
	/* nothing can happen: the mock aborts the test (the firmware bug) */
	printf("     (a forked child: its \"mock_hw: sdc_wait: ... no progress\" line on stderr is expected)\n");
	fflush(stdout);
	check("wait: no progress -> SIGABRT", forked_wait_aborts(), SIGABRT);
	/* the TIMER bound: an XFER from an empty TX pauses for ever */
	setup();
	mock_sdc_stall_fatal(0);
	rc = sdc_start(SDC_OP_XFER | SDC_X_TX, 4);
	check("wait bound: start", rc, 0);
	t = mock_timer_reads();
	h = sdc_trace_head;
	r = sdc_wait(SDC_IRQ_DONE);
	t = mock_timer_reads() - t;
	check("wait bound: returns 0", r, 0);
	/* the bound is 1800 TIMER counts (10.4 s): above the longest TIMEOUT,
	   65535 x 144.4 us = 9.46 s = 1630 counts.  TIMER step 0, one count per
	   idle call: GetTimer reads T0; CheckTimer is true at the first read
	   > T0 + 1800, the 1802nd; then the ABORT's trace entry and the
	   handler's: 1 + 1802 + 2 = 1805 reads */
	check("wait bound: TIMER reads = 1805", t, 1805);
	check("wait bound: then ABORT", sdc_trace[h % SDC_TRACE_N].what, SDC_TR_START | SDC_OP_ABORT);
	mock_sdc_step();
	check("wait bound: the op ended aborted", sdc_status() & (SDC_ST_BUSY | SDC_ST_ABORTED), SDC_ST_ABORTED);
}

static void t_watermark(void)
{
	unsigned traps;

	setup();
	sdc_select(0);
	SDC_W(SDC_WMARK, 0x0100);		/* RX high 16 bytes, TX low 0 */
	SDC_W(SDC_IRQACK, SDC_IRQ_RXHI);	/* RX empty: below the mark now */
	check("wmark: RX high clear below the mark", SDC_R(SDC_IRQPEND) & SDC_IRQ_RXHI, 0);
	sdc_arm(SDC_IRQ_RXHI);
	traps = mock_irq_traps();
	op(SDC_OP_XFER | SDC_X_RX, 32);
	check("wmark: RX high event", sdc_events & SDC_IRQ_RXHI, SDC_IRQ_RXHI);
	check("wmark: one shot: IRQEN bit 1 off", SDC_R(SDC_IRQEN) & SDC_IRQ_RXHI, 0);
	check("wmark: the level still holds", SDC_R(SDC_IRQPEND) & SDC_IRQ_RXHI, SDC_IRQ_RXHI);
	check("wmark: no storm (traps)", mock_irq_traps() - traps <= 3, 1);
	check("wmark: sdc_take", sdc_take(SDC_IRQ_RXHI), SDC_IRQ_RXHI);
	check("wmark: taken", sdc_events & SDC_IRQ_RXHI, 0);
	/* a stale LEVEL report after the line dropped: tolerated */
	mock_irq_stale_level(1);
	{
		unsigned h = sdc_trace_head;
		op(SDC_OP_TX_FLUSH, 0);
		check("stale: two trace entries (start, event)", sdc_trace_head - h, 2);
	}
	mock_irq_stale_level(0);
}

static void t_cfg_fifo(void)
{
	unsigned char d[8] = { 0x61, 0x62, 0x63, 0x64, 0x65, 0, 0, 0 }, r[8];
	int rc;

	setup();
	sdc_set_div(0);
	check("cfg: div 0 -> 2", SDC_R(SDC_CFG), SDC_CFG_CS | 2);
	sdc_set_div(1);
	check("cfg: div 1 -> 2", SDC_R(SDC_CFG), SDC_CFG_CS | 2);
	sdc_set_div(300);
	check("cfg: div 300 -> 255", SDC_R(SDC_CFG), SDC_CFG_CS | 255);
	sdc_set_div(141);
	check("cfg: div 141, CS kept", SDC_R(SDC_CFG), SDC_CFG_CS | 141);
	sdc_select(0);
	check("cfg: CS off, div kept", SDC_R(SDC_CFG), 141);
	sdc_start(SDC_OP_XFER, 50);
	rc = sdc_set_div(5);
	check("cfg: busy -> -1", rc, -1);
	check("cfg: busy -> CFG unchanged", SDC_R(SDC_CFG), 141);
	check("cfg: busy -> not written (no refusal)", SDC_R(SDC_STATUS) & SDC_ST_REFUSED, 0);
	check("cfg: busy -> select -1", sdc_select(1), -1);
	sdc_wait(SDC_IRQ_DONE);
	/* push / pop with odd counts: TXW pairs, TXB last */
	sdc_set_div(2);
	mock_sdc_wire_on(1);
	sdc_push(d, 5);
	check("fifo: TXLVL 5", SDC_R(SDC_TXLVL), 5);
	op(SDC_OP_XFER | SDC_X_TX, 5);
	op(SDC_OP_TX_COMMIT, 0);
	check_has("fifo: the 5 bytes in order", mock_sdc_wire(), "sd- 61 62 63 64 65 /");
	/* RX: CMD58 of an idle card, popped 3 + 2 + 3 */
	sdc_select(1);
	sdcmd(0, 0);
	{
		unsigned char f[6];
		frame(f, 58, 0, 0xFD);
		sdc_push(f, 6);
		op(SDC_OP_XFER | SDC_X_TX, 6);
		op(SDC_OP_TX_COMMIT, 0);
	}
	op(SDC_OP_XFER | SDC_X_RX, 8);
	sdc_pop(r, 3);
	sdc_pop(r + 3, 2);
	sdc_pop(r + 5, 3);
	{
		static const unsigned char want[8] = { 0xFF, 0x01, 0x00, 0xFF, 0x80, 0x00, 0xFF, 0xFF };
		check("fifo: pops 3 + 2 + 3", memcmp(r, want, 8), 0);
	}
	check("fifo: no misuse", SDC_R(SDC_STATUS) & SDC_ST_MISUSE, 0);
}

static void t_trace(void)
{
	unsigned h, k;

	setup();
	hosttest_advance(1234);		/* TIMER = 1234 + whatever setup took */
	h = sdc_trace_head;
	op(SDC_OP_TX_FLUSH, 0);
	check("trace: two entries", sdc_trace_head - h, 2);
	check("trace: start", sdc_trace[h % SDC_TRACE_N].what, SDC_TR_START | SDC_OP_TX_FLUSH);
	check("trace: start LEN", sdc_trace[h % SDC_TRACE_N].len, 0);
	check("trace: event", sdc_trace[(h + 1) % SDC_TRACE_N].what, SDC_TR_EVENT);
	check("trace: event IRQPEND has DONE", sdc_trace[(h + 1) % SDC_TRACE_N].irqpend & SDC_IRQ_DONE, SDC_IRQ_DONE);
	check("trace: time = TIMER", sdc_trace[h % SDC_TRACE_N].time >= 1234, 1);
	sdc_select(0);
	op(SDC_OP_XFER, 7);
	k = (sdc_trace_head - 1) % SDC_TRACE_N;
	check("trace: event COUNT", sdc_trace[k].len, 7);
	check("trace: event STATUS", sdc_trace[k].status & ~SDC_ST_CARD, 0);
	check("trace: start of the XFER, LEN", sdc_trace[(sdc_trace_head - 2) % SDC_TRACE_N].len, 7);
	/* wrap: 20 more ops, 40 entries */
	h = sdc_trace_head;
	for (k = 0; k < 20; k++)
		op(k & 1 ? SDC_OP_RX_FLUSH : SDC_OP_TX_FLUSH, 0);
	check("trace: head counts every entry", sdc_trace_head - h, 40);
	check("trace: newest = the last event", sdc_trace[(sdc_trace_head - 1) % SDC_TRACE_N].what, SDC_TR_EVENT);
	check("trace: the one before = the last start (RX_FLUSH)",
	      sdc_trace[(sdc_trace_head - 2) % SDC_TRACE_N].what, SDC_TR_START | SDC_OP_RX_FLUSH);
	/* the oldest left: entry head - 32 = h + 8, the start of op 4 (TX_FLUSH) */
	check("trace: oldest left after the wrap",
	      sdc_trace[sdc_trace_head % SDC_TRACE_N].what, SDC_TR_START | SDC_OP_TX_FLUSH);
	check("trace: oldest left is op 4", sdc_trace_head - 32 - h, 8);
}

/* ---- the peripheral contract (raw registers) ---- */
static void t_reset(void)
{
	mock_reset();
	check("reset: VERSION", SDC_R(SDC_VER), SDC_VERSION);
	check("reset: CFG 00FF", SDC_R(SDC_CFG), 0x00FF);
	check("reset: IRQPEND 0006", SDC_R(SDC_IRQPEND), 0x0006);
	check("reset: STATUS card present", SDC_R(SDC_STATUS), SDC_ST_CARD);
	check("reset: TIMEOUT 0", SDC_R(SDC_TIMEOUT), 0);
	check("reset: IRQEN 0", SDC_R(SDC_IRQEN), 0);
	check("reset: RXLVL 0", SDC_R(SDC_RXLVL), 0);
	check("reset: TXLVL 0", SDC_R(SDC_TXLVL), 0);
	check("reset: offset 0x30 reads 0", SDC_R(0x30), 0);
}

static void t_timing(void)
{
	unsigned long long t0;

	mock_reset();
	SDC_W(SDC_CFG, 2);
	SDC_W(SDC_LEN, 10);
	SDC_W(SDC_CMD, SDC_OP_XFER);
	t0 = mock_now();
	while (mock_sdc_step())
		;
	check("timing: 10 bytes at div 2 = 10 x 16 x 3 cycles", (long)(mock_now() - t0), 480);
	check("timing: COUNT", SDC_R(SDC_COUNT), 10);
	SDC_W(SDC_CFG, 141);
	check("timing: byte cycles at div 141", mock_sdc_byte_cycles(), 16 * 142);
	check("timing: bytes in 1000 us at div 141 (399.5 kHz)", mock_sdc_bytes_for_us(1000), 49);
}

static void t_txkeep(void)
{
	static const unsigned char a[4] = { 0xA1, 0xA2, 0xA3, 0xA4 }, b[4] = { 0xB1, 0xB2, 0xB3, 0xB4 },
		c[3] = { 0xC1, 0xC2, 0xC3 }, dd = 0xD1;
	struct mock_sdc_peek p;

	setup();
	sdc_select(0);
	mock_sdc_wire_on(1);
	sdc_push(a, 4);
	op(SDC_OP_XFER | SDC_X_TX, 4);
	check("txkeep: sent bytes stay (TXLVL)", SDC_R(SDC_TXLVL), 4);
	op(SDC_OP_TX_COMMIT, 0);
	check("txkeep: COMMIT frees them", SDC_R(SDC_TXLVL), 0);
	sdc_push(b, 4);
	op(SDC_OP_XFER | SDC_X_TX, 2);
	mock_sdc_peek(&p);
	check("txkeep: 2 of 4 sent, unsent", p.txunsent, 2);
	op(SDC_OP_TX_COMMIT, 0);
	check("txkeep: COMMIT frees the sent 2 only", SDC_R(SDC_TXLVL), 2);
	op(SDC_OP_XFER | SDC_X_TX, 2);
	op(SDC_OP_TX_COMMIT, 0);
	/* the retry recipe: block kept, a command behind it, REWIND to the block */
	sdc_push(c, 3);
	op(SDC_OP_XFER | SDC_X_TX, 3);
	sdc_push(&dd, 1);
	op(SDC_OP_XFER | SDC_X_TX, 1);
	op(SDC_OP_TX_REWIND, 0);
	check("txkeep: REWIND: all 4 kept", SDC_R(SDC_TXLVL), 4);
	mock_sdc_peek(&p);
	check("txkeep: REWIND: from the commit point, 4 unsent", p.txunsent, 4);
	op(SDC_OP_XFER | SDC_X_TX, 4);
	check_has("txkeep: bytes in order, then from the commit point again", mock_sdc_wire(),
	          "a1 a2 a3 a4 b1 b2 b3 b4 c1 c2 c3 d1 c1 c2 c3 d1 /");
	op(SDC_OP_TX_FLUSH, 0);
	check("txkeep: FLUSH", SDC_R(SDC_TXLVL), 0);
	/* CRC16 appended: "123456789" + 31 C3, COUNT 11 */
	sdc_push((const unsigned char *)"123456789", 9);
	op(SDC_OP_XFER | SDC_X_TX | SDC_X_TXCRC, 9);
	check_has("txcrc: CRC16 31 C3 after the data", mock_sdc_wire(), "31 32 33 34 35 36 37 38 39 31 c3 /");
	check("txcrc: COUNT counts the CRC bytes", SDC_R(SDC_COUNT), 11);
	op(SDC_OP_TX_FLUSH, 0);
	/* XFER LEN 0: done at once, no CRC bytes */
	{
		unsigned long long n = (mock_sdc_peek(&p), p.bytes);
		op(SDC_OP_XFER | SDC_X_TXCRC, 0);
		mock_sdc_peek(&p);
		check("xfer LEN 0: no byte", (long)(p.bytes - n), 0);
	}
}

static void t_readcrc(void)
{
	unsigned char d[512], f[6];
	const unsigned char *g;
	size_t n;
	struct mock_sdc_peek p;
	unsigned st;

	setup();
	card_init();
	pattern(mock_card_wsector(5), 5);
	pattern(d, 5);
	/* a good block: CRC ok, verified, to Gayle */
	check("read: CMD17 R1", sdcmd(17, 5), 0);
	st = read_data(512, 0);
	check("read: STATUS crc_ok", st & SDC_ST_CRC_OK, SDC_ST_CRC_OK);
	mock_sdc_peek(&p);
	check("read: RXLVL 512", p.rxlvl, 512);
	check("read: verified 512", p.verified, 512);
	check("read: RX_TO_GAYLE accepted", sdc_start(SDC_OP_RX_TO_GAYLE, 512), 0);
	sdc_wait(SDC_IRQ_DONE);
	check("read: Gayle op ended normally", sdc_status() & (SDC_ST_GERR | SDC_ST_BUSY), 0);
	g = mock_gayle_into(0, &n);
	check("read: 512 bytes into Gayle port 0", (long)n, 512);
	check("read: the sector's bytes", n == 512 ? memcmp(g, d, 512) : -1, 0);
	check("read: RX empty after", SDC_R(SDC_RXLVL), 0);
	/* a bad block (bit 0 of its last data byte flipped): poisoned */
	mock_card_error(MOCK_ERR_RDCRC, 2, 1);
	sdcmd(17, 5);
	st = read_data(512, 0);
	check("read bad: no crc_ok", st & SDC_ST_CRC_OK, 0);
	check("read bad: no error IRQ (a result)", sdc_events & SDC_IRQ_ERR, 0);
	mock_sdc_peek(&p);
	check("read bad: poisoned", p.poisoned, 1);
	check("read bad: RX_TO_GAYLE refused", sdc_start(SDC_OP_RX_TO_GAYLE, 512), -1);
	op(SDC_OP_RX_FLUSH, 0);
	mock_sdc_peek(&p);
	check("read bad: RX_FLUSH clears poisoned", p.poisoned, 0);
	sdcmd(17, 5);
	st = read_data(512, 0);
	check("read again: crc_ok", st & SDC_ST_CRC_OK, SDC_ST_CRC_OK);
	check("read again: RX_TO_GAYLE accepted (port 1)", sdc_start(SDC_OP_RX_TO_GAYLE | SDC_G_PORT1, 512), 0);
	sdc_wait(SDC_IRQ_DONE);
	g = mock_gayle_into(1, &n);
	check("read again: into port 1", n == 512 ? memcmp(g, d, 512) : -1, 0);
	/* interlock: an unverified byte ahead of a good block */
	op(SDC_OP_RX_FLUSH, 0);
	frame(f, 17, 5, 0);
	f[5] = crc7(f, 5);
	sdc_push(f, 6);
	op(SDC_OP_XFER | SDC_X_TX, 6);
	op(SDC_OP_TX_COMMIT, 0);
	op(SDC_OP_XFER | SDC_X_RX, 1);		/* NCR byte, into RX, unverified */
	SDC_W(SDC_MATCH, 0x00);
	SDC_W(SDC_TIMEOUT, 2);
	op(SDC_OP_WAIT_EQ, 0);			/* R1 */
	st = read_data(512, 0);
	mock_sdc_peek(&p);
	check("interlock: the block's CRC ok", st & SDC_ST_CRC_OK, SDC_ST_CRC_OK);
	check("interlock: nothing verified (unverified byte ahead)", p.verified, 0);
	check("interlock: RX_TO_GAYLE refused", sdc_start(SDC_OP_RX_TO_GAYLE, 512), -1);
	/* CRC check without RX: the result only */
	op(SDC_OP_RX_FLUSH, 0);
	sdcmd(17, 5);
	st = read_data(512, 0);
	(void)st;
	sdcmd(17, 5);
	SDC_W(SDC_MATCH, 0xFE);
	op(SDC_OP_WAIT_EQ, 0);
	st = op(SDC_OP_XFER | SDC_X_RXCRC, 512);
	mock_sdc_peek(&p);
	check("crc without RX: crc_ok", st & SDC_ST_CRC_OK, SDC_ST_CRC_OK);
	check("crc without RX: RX unchanged (the earlier block)", p.rxlvl, 512);
}

static void t_waitops(void)
{
	unsigned long long t0;
	unsigned st, cnt;

	setup();
	card_init();
	/* WAIT_NE FF: R1 after NCR; LAST = R1, COUNT = bytes clocked */
	{
		unsigned char f[6];
		frame(f, 13, 0, 0);
		f[5] = crc7(f, 5);
		sdc_push(f, 6);
		op(SDC_OP_XFER | SDC_X_TX, 6);
		op(SDC_OP_TX_COMMIT, 0);
	}
	SDC_W(SDC_MATCH, 0xFF);
	SDC_W(SDC_TIMEOUT, 1);
	st = op(SDC_OP_WAIT_NE, 0);
	check("wait_ne: ended normally", st & (SDC_ST_TIMEOUT | SDC_ST_BUSY), 0);
	check("wait_ne: LAST = R1 00", SDC_R(SDC_LAST), 0x00);
	check("wait_ne: COUNT = NCR + R1", SDC_R(SDC_COUNT), 2);
	check("wait_ne: nothing into RX", SDC_R(SDC_RXLVL), 0);
	/* TIMEOUT: 3 units of 16384 cycles, the op ends at the next byte */
	sdc_select(0);
	SDC_W(SDC_MATCH, 0x00);
	SDC_W(SDC_TIMEOUT, 3);
	t0 = mock_now();
	sdc_start(SDC_OP_WAIT_EQ, 0);
	sdc_wait(SDC_IRQ_DONE);
	st = sdc_status();
	cnt = SDC_R(SDC_COUNT);
	check("timeout: STATUS 2", st & SDC_ST_TIMEOUT, SDC_ST_TIMEOUT);
	check("timeout: ERR event", sdc_events & SDC_IRQ_ERR, SDC_IRQ_ERR);
	/* 3 x 16384 / 48 = 1024 bytes, the op ends at the byte after the bound */
	check("timeout: COUNT = 1025 bytes (bound / byte time + 1)", cnt, 1025);
	check("timeout: elapsed >= 3 units", mock_now() - t0 >= 3 * 16384, 1);
	check("timeout: elapsed < 3 units + 4 accesses + 2 bytes", mock_now() - t0 < 3 * 16384 + 64 + 96 + 400, 1);
	/* TIMEOUT 0 = 1 unit */
	SDC_W(SDC_TIMEOUT, 0);
	op(SDC_OP_WAIT_EQ, 0);
	check("timeout 0 = 1 unit: COUNT", SDC_R(SDC_COUNT), 16384 / 48 + 1);
	/* LEN, MATCH, TIMEOUT ignored while busy */
	SDC_W(SDC_TIMEOUT, 2);
	sdc_start(SDC_OP_WAIT_EQ, 0);
	SDC_W(SDC_TIMEOUT, 50);
	SDC_W(SDC_MATCH, 0xFF);			/* would end it at once */
	SDC_W(SDC_LEN, 33);
	sdc_wait(SDC_IRQ_DONE);
	check("busy: TIMEOUT write ignored", SDC_R(SDC_TIMEOUT), 2);
	check("busy: MATCH write ignored (timed out)", sdc_status() & SDC_ST_TIMEOUT, SDC_ST_TIMEOUT);
}

/* a slow card: 500 ms busy after a block (design 5.1, Task 10's
   busy_500ms) at div 2 against TIMEOUT: 3500 units (505 ms) is enough,
   3400 (490.97 ms) is not; the time moves the TIMER (5.804 ms counts) */
static void t_slowcard(void)
{
	unsigned char d[512];
	unsigned long busy;
	unsigned long long t0;
	unsigned short tm0;
	unsigned st;

	setup();
	card_init();
	busy = mock_sdc_bytes_for_us(500000);
	check("slow: 500 ms at div 2 = 1181875 bytes (500 ms x 113.46 MHz / 48 cycles a byte)", (long)busy, 1181875);
	mock_card_params(4, (int)busy, 1, 2);
	pattern(d, 3);
	for (int k = 0; k < 2; k++) {
		sdcmd(24, 7);
		sdc_push((const unsigned char *)"\xFE", 1);
		sdc_push(d, 512);
		op(SDC_OP_XFER | SDC_X_TX, 1);
		op(SDC_OP_XFER | SDC_X_TX | SDC_X_TXCRC, 512);
		op(SDC_OP_TX_COMMIT, 0);
		SDC_W(SDC_MATCH, 0xFF);
		SDC_W(SDC_TIMEOUT, 4);
		op(SDC_OP_WAIT_NE, 0);
		check("slow: data response 05", SDC_R(SDC_LAST) & 0x1F, 0x05);
		SDC_W(SDC_MATCH, 0x00);
		SDC_W(SDC_TIMEOUT, k ? 3400 : 3500);
		t0 = mock_now();
		tm0 = TIMER;
		st = op(SDC_OP_WAIT_NE, 0);
		if (k == 0) {
			check("slow: TIMEOUT 3500, busy over without a timeout", st & SDC_ST_TIMEOUT, 0);
			check("slow: it took 500 ms (+- 1 ms)", (long)((mock_now() - t0) / 113460), 500);
			check("slow: the TIMER moved 86 counts (500 ms / 5.804 ms)", (unsigned short)(TIMER - tm0), 86);
		} else {
			check("slow: TIMEOUT 3400, timeout", st & SDC_ST_TIMEOUT, SDC_ST_TIMEOUT);
			check("slow: after 490 ms (3400 x 16384 cycles = 490.97 ms)", (long)((mock_now() - t0) / 113460), 490);
			SDC_W(SDC_TIMEOUT, 200);	/* the rest of the busy: 9 ms */
			check("slow: then the rest of it", op(SDC_OP_WAIT_NE, 0) & SDC_ST_TIMEOUT, 0);
		}
	}
}

static void t_pause(void)
{
	unsigned char r[600];
	struct mock_sdc_peek p;
	static const unsigned char four[4] = { 1, 2, 3, 4 };

	setup();
	sdc_select(0);
	SDC_W(SDC_LEN, 1500);
	SDC_W(SDC_CMD, SDC_OP_XFER | SDC_X_RX);
	until_idle();
	mock_sdc_peek(&p);
	check("pause RX: busy at 1024", p.busy, 1);
	check("pause RX: RXLVL 1024", p.rxlvl, 1024);
	check("pause RX: COUNT 1024", p.count, 1024);
	check("pause RX: nothing can happen", mock_sdc_step(), 0);
	sdc_pop(r, 600);
	until_idle();
	mock_sdc_peek(&p);
	check("pause RX: went on after the pops", p.busy, 0);
	check("pause RX: COUNT 1500", p.count, 1500);
	check("pause RX: RXLVL 900", p.rxlvl, 900);
	check("pause RX: no misuse", p.status & SDC_ST_MISUSE, 0);
	op(SDC_OP_RX_FLUSH, 0);
	/* TX empty: pauses, goes on after a push */
	sdc_push(four, 4);
	SDC_W(SDC_LEN, 8);
	SDC_W(SDC_CMD, SDC_OP_XFER | SDC_X_TX);
	until_idle();
	mock_sdc_peek(&p);
	check("pause TX: busy after 4", p.busy, 1);
	check("pause TX: COUNT 4", p.count, 4);
	sdc_push(four, 4);
	until_idle();
	mock_sdc_peek(&p);
	check("pause TX: done", p.busy, 0);
	check("pause TX: COUNT 8", p.count, 8);
}

static void t_misuse(void)
{
	unsigned k, v;

	setup();
	sdc_select(0);
	for (k = 0; k < 1025; k++)
		SDC_W(SDC_TXB, k & 0xFF);
	check("misuse: TX full at 1024", SDC_R(SDC_TXLVL), 1024);
	check("misuse: STATUS 8", SDC_R(SDC_STATUS) & SDC_ST_MISUSE, SDC_ST_MISUSE);
	check("misuse: ERR event", sdc_events & SDC_IRQ_ERR, SDC_IRQ_ERR);
	op(SDC_OP_TX_FLUSH, 0);
	check("misuse: cleared by an accepted CMD", SDC_R(SDC_STATUS) & SDC_ST_MISUSE, 0);
	v = SDC_R(SDC_RXW);
	check("misuse: pop of empty RX = 0000", v, 0);
	check("misuse: pop of empty RX: STATUS 8", SDC_R(SDC_STATUS) & SDC_ST_MISUSE, SDC_ST_MISUSE);
	op(SDC_OP_XFER | SDC_X_RX, 1);
	v = SDC_R(SDC_RXW);
	check("misuse: RXW with 1 byte = FF00", v, 0xFF00);
	check("misuse: RXW with 1 byte: RX empty", SDC_R(SDC_RXLVL), 0);
	check("misuse: RXW with 1 byte: STATUS 8", SDC_R(SDC_STATUS) & SDC_ST_MISUSE, SDC_ST_MISUSE);
	/* ABORT does not clear STATUS 8 */
	op(SDC_OP_ABORT, 0);
	check("misuse: kept over an idle ABORT", SDC_R(SDC_STATUS) & SDC_ST_MISUSE, SDC_ST_MISUSE);
	/* CFG while busy: refused, unchanged, the op goes on */
	sdc_set_div(255);
	sdc_start(SDC_OP_XFER, 100);
	SDC_W(SDC_CFG, 0x0105);
	check("cfg busy: refused STATUS 6", SDC_R(SDC_STATUS) & (SDC_ST_REFUSED | SDC_ST_BUSY), SDC_ST_REFUSED | SDC_ST_BUSY);
	check("cfg busy: CFG unchanged", SDC_R(SDC_CFG), 255);
	check("cfg busy: ERR event", sdc_take(SDC_IRQ_ERR), SDC_IRQ_ERR);
	sdc_wait(SDC_IRQ_DONE);
	check("cfg busy: the op went on to its end", SDC_R(SDC_COUNT), 100);
}

static void t_abort_gone(void)
{
	unsigned bc;

	setup();
	sdc_set_div(10);
	sdc_select(0);
	bc = mock_sdc_byte_cycles();
	sdc_start(SDC_OP_XFER, 100);
	mock_run(bc * 5 + bc / 2);
	sdc_clear(SDC_IRQ_ALL);
	SDC_W(SDC_CMD, SDC_OP_ABORT);		/* raw: the driver would drop the events */
	sdc_wait(SDC_IRQ_DONE);
	check("abort: COUNT 6 (the byte being shifted finishes)", SDC_R(SDC_COUNT), 6);
	check("abort: STATUS 4", sdc_status() & (SDC_ST_ABORTED | SDC_ST_BUSY), SDC_ST_ABORTED);
	check("abort: DONE only, no ERR", sdc_events & (SDC_IRQ_DONE | SDC_IRQ_ERR), SDC_IRQ_DONE);
	sdc_clear(SDC_IRQ_ALL);
	SDC_W(SDC_CMD, SDC_OP_ABORT);
	sdc_wait(SDC_IRQ_DONE);
	check("abort idle: DONE", sdc_events & SDC_IRQ_DONE, SDC_IRQ_DONE);
	check("abort idle: STATUS unchanged", sdc_status() & SDC_ST_ABORTED, SDC_ST_ABORTED);
	/* card gone in the middle of a byte: at once */
	sdc_start(SDC_OP_XFER, 100);
	mock_run(bc * 5 + bc / 2);
	mock_sdc_cd(0);
	check("gone: ended at once", sdc_status() & SDC_ST_BUSY, 0);
	check("gone: COUNT 5 (the byte cut off)", SDC_R(SDC_COUNT), 5);
	check("gone: STATUS 5", sdc_status() & SDC_ST_GONE, SDC_ST_GONE);
	check("gone: DONE + ERR", sdc_events & (SDC_IRQ_DONE | SDC_IRQ_ERR), SDC_IRQ_DONE | SDC_IRQ_ERR);
	check("gone: STATUS 3 still set (debounce)", sdc_status() & SDC_ST_CARD, SDC_ST_CARD);
	mock_run(1u << 20);
	check("gone: STATUS 3 clear after 2^20 cycles", sdc_status() & SDC_ST_CARD, 0);
	check("gone: card-detect event", sdc_events & SDC_IRQ_CD, SDC_IRQ_CD);
	/* an op started without a card ends at once */
	sdc_clear(SDC_IRQ_ALL);
	sdc_start(SDC_OP_XFER, 10);
	check("no card: ended at once", sdc_status() & (SDC_ST_BUSY | SDC_ST_GONE), SDC_ST_GONE);
	check("no card: COUNT 0", SDC_R(SDC_COUNT), 0);
	/* back: a change again after the debounce, not before */
	sdc_clear(SDC_IRQ_ALL);
	mock_sdc_cd(1);
	mock_run((1u << 20) - 100);
	check("insert: no event before the debounce", sdc_events & SDC_IRQ_CD, 0);
	mock_run(200);
	check("insert: event after it", sdc_events & SDC_IRQ_CD, SDC_IRQ_CD);
	check("insert: STATUS 3", sdc_status() & SDC_ST_CARD, SDC_ST_CARD);
	/* a bounce shorter than the debounce: no event */
	sdc_clear(SDC_IRQ_ALL);
	mock_sdc_cd(0);
	mock_run(1000);
	mock_sdc_cd(1);
	mock_run(2u << 20);
	check("bounce: no event", sdc_events & SDC_IRQ_CD, 0);
}

static void t_levels(void)
{
	unsigned char r[20];
	static const unsigned char z[20] = { 0 };

	setup();
	sdc_select(0);
	SDC_W(SDC_WMARK, 0x0101);		/* RX high 16, TX low 16 */
	op(SDC_OP_XFER | SDC_X_RX, 32);
	SDC_W(SDC_IRQACK, SDC_IRQ_RXHI);
	check("level: RX high stays set while RX >= 16", SDC_R(SDC_IRQPEND) & SDC_IRQ_RXHI, SDC_IRQ_RXHI);
	sdc_pop(r, 20);
	SDC_W(SDC_IRQACK, SDC_IRQ_RXHI);
	check("level: RX high acks below the mark", SDC_R(SDC_IRQPEND) & SDC_IRQ_RXHI, 0);
	sdc_push(z, 20);
	SDC_W(SDC_IRQACK, SDC_IRQ_TXLO);
	check("level: TX low acks above the mark", SDC_R(SDC_IRQPEND) & SDC_IRQ_TXLO, 0);
	op(SDC_OP_TX_FLUSH, 0);
	check("level: TX low set again (TX empty)", SDC_R(SDC_IRQPEND) & SDC_IRQ_TXLO, SDC_IRQ_TXLO);
	sdc_push(z, 16);
	SDC_W(SDC_IRQACK, SDC_IRQ_TXLO);
	check("level: TX low holds at the mark (16 <= 16)", SDC_R(SDC_IRQPEND) & SDC_IRQ_TXLO, SDC_IRQ_TXLO);
}

/* ---- Gayle ops on the mock bridge ---- */
static int release_gayle(void *ctx)
{
	(void)ctx;
	mock_gayle_hold(0);
	return 1;
}

static void t_gayle(void)
{
	unsigned char d[512];
	struct mock_sdc_peek p;
	unsigned v;

	setup();
	sdc_select(0);
	pattern(d, 9);
	mock_gayle_from(1, d, 512);
	check("g2tx: accepted", sdc_start(SDC_OP_GAYLE_TO_TX | SDC_G_PORT1, 512), 0);
	sdc_wait(SDC_IRQ_DONE);
	check("g2tx: normal end", sdc_status() & (SDC_ST_GERR | SDC_ST_BUSY), 0);
	check("g2tx: TXLVL 512", SDC_R(SDC_TXLVL), 512);
	check("g2tx: COUNT 512", SDC_R(SDC_COUNT), 512);
	mock_sdc_wire_on(1);
	op(SDC_OP_XFER | SDC_X_TX, 512);
	{
		char want[16];
		snprintf(want, sizeof want, "sd- %02x %02x %02x", d[0], d[1], d[2]);
		check_has("g2tx: the Amiga's bytes go out", mock_sdc_wire(), want);
	}
	op(SDC_OP_TX_FLUSH, 0);
	/* no room for LEN: refused */
	sdc_push(d, 512);
	sdc_push(d, 100);
	check("g2tx: no room for 512 (612 kept) -> refused", sdc_start(SDC_OP_GAYLE_TO_TX, 512), -1);
	op(SDC_OP_TX_FLUSH, 0);
	/* held (Amiga pace): the data port is locked meanwhile */
	mock_gayle_from(0, d, 512);
	mock_gayle_hold(1);
	sdc_start(SDC_OP_GAYLE_TO_TX, 512);
	check("held: nothing can happen", mock_sdc_step(), 0);
	SDC_W(SDC_TXB, 0x55);
	v = SDC_R(SDC_RXW);
	mock_sdc_peek(&p);
	check("locked: push dropped", p.txlvl, 0);
	check("locked: pop reads 0000", v, 0);
	check("locked: STATUS 8", p.status & SDC_ST_MISUSE, SDC_ST_MISUSE);
	/* an IDE command over cs 0x10 now is a violation; afterwards it is not */
	EnableFpga();
	DisableFpga();
	check("cs 0x10 during a Gayle op counted", mock_gayle_cs_violations(), 1);
	check("locked: ERR event", sdc_take(SDC_IRQ_ERR), SDC_IRQ_ERR);
	mock_sdc_on_stall(release_gayle, NULL);
	sdc_wait(SDC_IRQ_DONE);
	mock_sdc_on_stall(NULL, NULL);
	check("held: released, normal end", sdc_status() & (SDC_ST_GERR | SDC_ST_BUSY), 0);
	EnableFpga();
	DisableFpga();
	check("cs 0x10 when idle not counted", mock_gayle_cs_violations(), 1);
	op(SDC_OP_TX_FLUSH, 0);
	/* g_err after 3 words: STATUS 7, ERR, TX rolled back */
	sdc_push(d, 10);
	mock_gayle_from(0, d, 512);
	mock_gayle_end(MOCK_GAYLE_ERR, 3);
	sdc_start(SDC_OP_GAYLE_TO_TX, 512);
	sdc_wait(SDC_IRQ_DONE);
	check("g_err: STATUS 7", sdc_status() & SDC_ST_GERR, SDC_ST_GERR);
	check("g_err: ERR event", sdc_events & SDC_IRQ_ERR, SDC_IRQ_ERR);
	check("g_err: COUNT 6 (3 words)", SDC_R(SDC_COUNT), 6);
	check("g_err: TX back to its 10 bytes", SDC_R(SDC_TXLVL), 10);
	/* a short g_ack: the same */
	mock_gayle_from(0, d, 512);
	mock_gayle_end(MOCK_GAYLE_SHORT, 100);
	sdc_start(SDC_OP_GAYLE_TO_TX, 512);
	sdc_wait(SDC_IRQ_DONE);
	check("short g_ack: STATUS 7", sdc_status() & SDC_ST_GERR, SDC_ST_GERR);
	check("short g_ack: TX back", SDC_R(SDC_TXLVL), 10);
	/* the knob is one shot: the next op is normal */
	mock_gayle_from(0, d, 512);
	sdc_start(SDC_OP_GAYLE_TO_TX, 512);
	sdc_wait(SDC_IRQ_DONE);
	check("next: normal", sdc_status() & SDC_ST_GERR, 0);
	check("next: TX 10 + 512", SDC_R(SDC_TXLVL), 522);
	op(SDC_OP_TX_FLUSH, 0);
	/* the Amiga's sector arrives late: the op waits for it */
	mock_reset();
	mock_timer_step(0);
	sdc_init();
	mock_gayle_from(0, d, 100);
	sdc_start(SDC_OP_GAYLE_TO_TX, 512);
	check("late: waits for the Amiga", mock_sdc_step() && !mock_sdc_step(), 1);
	mock_gayle_from(0, d + 100, 412);
	sdc_wait(SDC_IRQ_DONE);
	check("late: then a normal end", sdc_status() & (SDC_ST_GERR | SDC_ST_BUSY), 0);
	check("late: TXLVL 512", SDC_R(SDC_TXLVL), 512);
	/* ABORT a Gayle op: at once, rolled back */
	op(SDC_OP_TX_FLUSH, 0);
	mock_gayle_hold(1);
	mock_gayle_from(0, d, 512);
	sdc_start(SDC_OP_GAYLE_TO_TX, 512);
	mock_gayle_hold(0);
	mock_run(12 * 5);
	sdc_clear(SDC_IRQ_ALL);
	SDC_W(SDC_CMD, SDC_OP_ABORT);
	check("abort gayle: at once", sdc_status() & (SDC_ST_BUSY | SDC_ST_ABORTED), SDC_ST_ABORTED);
	check("abort gayle: rolled back", SDC_R(SDC_TXLVL), 0);
}

/* ---- the card's Task 4 behaviour ---- */
static void t_card(void)
{
	unsigned char d[512], e[512], r[6];
	unsigned st, v;

	setup();
	card_init();
	/* CMD59: CRC checking on */
	check("cmd59: R1", sdcmd(59, 1), 0x00);
	check("cmd59: on", mock_card_crc_on(), 1);
	check("crc7 bad: R1 08", sdcmd_crc(13, 0, 0x01), 0x08);
	check("crc7 good: CMD13 R1 00", sdcmd(13, 0), 0x00);
	op(SDC_OP_XFER | SDC_X_RX, 1);
	sdc_pop(r, 1);
	check("cmd13: R2 second byte 00", r[0], 0x00);
	/* a written block with a bad CRC16: 0B, not written; then good: 05 */
	pattern(d, 77);
	memcpy(e, mock_card_sector(5), 512);
	check("cmd24: R1", sdcmd(24, 5), 0x00);
	check("write bad crc16: 0B", write_block(d, 0xFE, 1), 0x0B);
	check("write bad crc16: not written", memcmp(mock_card_sector(5), e, 512), 0);
	sdcmd(24, 5);
	check("write good: 05", write_block(d, 0xFE, 0), 0x05);
	check("write good: written", memcmp(mock_card_sector(5), d, 512), 0);
	/* CMD25 of 3 with WRREJ on the 2nd: 05 0B 0B, stop token, ACMD22 = 1 */
	mock_card_error(MOCK_ERR_WRREJ, 4, 1);	/* written blocks so far: 2; the CMD25's 2nd is the 4th */
	check("cmd25: R1", sdcmd(25, 10), 0x00);
	pattern(d, 10);
	check("cmd25 block 1: 05", write_block(d, 0xFC, 0), 0x05);
	pattern(d, 11);
	check("cmd25 block 2: 0B (WRREJ)", write_block(d, 0xFC, 0), 0x0B);
	pattern(d, 12);
	check("cmd25 block 3: 0B (stopped)", write_block(d, 0xFC, 0), 0x0B);
	{
		unsigned char fd = 0xFD;
		sdc_push(&fd, 1);
		op(SDC_OP_XFER | SDC_X_TX, 1);
		op(SDC_OP_TX_COMMIT, 0);
		op(SDC_OP_XFER, 1);		/* the stuff byte */
		SDC_W(SDC_MATCH, 0x00);
		SDC_W(SDC_TIMEOUT, 10);
		st = op(SDC_OP_WAIT_EQ, 0);
		check("stop token: busy follows", st & SDC_ST_TIMEOUT, 0);
		SDC_W(SDC_MATCH, 0x00);
		op(SDC_OP_WAIT_NE, 0);
	}
	pattern(d, 10);
	check("cmd25: block 1 written", memcmp(mock_card_sector(10), d, 512), 0);
	pattern(d, 11);
	check("cmd25: block 2 not written", memcmp(mock_card_sector(11), d, 512) != 0, 1);
	check("acmd22: CMD55", sdcmd(55, 0), 0x00);
	check("acmd22: R1", sdcmd(22, 0), 0x00);
	op(SDC_OP_RX_FLUSH, 0);
	st = read_data(4, 0);
	check("acmd22: CRC16 ok", st & SDC_ST_CRC_OK, SDC_ST_CRC_OK);
	sdc_pop(r, 4);
	check("acmd22: 1 block written", (r[0] << 24) | (r[1] << 16) | (r[2] << 8) | r[3], 1);
	/* WRFAIL: 0D, then busy */
	mock_card_error(MOCK_ERR_WRFAIL, 6, 1);	/* written blocks so far: 5 */
	sdcmd(24, 20);
	pattern(d, 20);
	check("wrfail: 0D", write_block(d, 0xFE, 0), 0x0D);
	check("wrfail: not written", memcmp(mock_card_sector(20), d, 512) != 0, 1);
	/* NORESP: no R1 (the wait times out); CMDCRC: 08; NORESP wins */
	mock_card_error(MOCK_ERR_NORESP, mock_card_commands() + 1, 1);
	check("noresp: no R1", sdcmd(13, 0), 0xFF);
	check("noresp: the next answers", sdcmd(13, 0), 0x00);
	mock_card_error(MOCK_ERR_CMDCRC, mock_card_commands() + 1, 2);
	check("cmdcrc: 08", sdcmd(13, 0), 0x08);
	check("cmdcrc: CNT 2, 08 again", sdcmd(13, 0), 0x08);
	check("cmdcrc: then 00", sdcmd(13, 0), 0x00);
	mock_card_error(MOCK_ERR_NORESP, mock_card_commands() + 1, 1);
	mock_card_error(MOCK_ERR_CMDCRC, mock_card_commands() + 1, 1);
	check("noresp + cmdcrc: NORESP wins", sdcmd(13, 0), 0xFF);
	check("noresp + cmdcrc: CMDCRC unused, now", sdcmd(13, 0), 0x08);
	/* removed: MISO FF, nothing acted on; inserted: a power-on card */
	mock_card_remove();
	check("removed: no R1", sdcmd(0, 0), 0xFF);
	mock_card_insert();
	check("inserted: CMD0 R1 01", sdcmd(0, 0), 0x01);
	check("inserted: CRC checking off", mock_card_crc_on(), 0);
	/* CMD0 turns CRC checking off: a wrong CRC7 is fine again */
	v = sdcmd_crc(8, 0x1AA, 0x01);
	check("crc off: CMD8 with a wrong CRC7 answers 01", v, 0x01);
}

int main(void)
{
	setvbuf(stdout, NULL, _IOLBF, 0);	/* the lines before an abort reach the log */
	t_irq();
	t_crc();
	t_brief();
	t_init();
	t_refuse();
	t_wait();
	t_watermark();
	t_cfg_fifo();
	t_trace();
	t_reset();
	t_timing();
	t_txkeep();
	t_readcrc();
	t_waitops();
	t_slowcard();
	t_pause();
	t_misuse();
	t_abort_gone();
	t_levels();
	t_gayle();
	t_card();
	if (fails) {
		printf("sdc_test FAIL (%d of %d)\n", fails, cases);
		return 1;
	}
	printf("sdc_test PASS (%d checks)\n", cases);
	return 0;
}

/* sdproto.c: the SD card protocol (SPI mode) on the SD card peripheral; the
 * API and its rules are in sdproto.h, the peripheral's contract in the
 * header of rtl/host/sdcard_spi.v, the driver in sdc.h.
 *
 * Every step of an op is one peripheral op; its end (sdc_events DONE) makes
 * sd_poll() run step(), which reads the result and starts the next one.  A
 * command: [FF, 6 bytes with CRC7] pushed into TX and sent (XFER TX), then
 * WAIT_NE FF for R1 (TIMEOUT T_NCR), extra response bytes (XFER RX), R1b
 * busy (WAIT_EQ FF, T_BUSY).  A read block: WAIT_NE FF for the token
 * (T_TOKEN), XFER RX + CRC check of the block, then pop it into buf or
 * RX_TO_GAYLE it.  A written block: [FF, token, 512 bytes] pushed into TX
 * (kept there until the card took it), XFER TX 2, XFER TX + CRC16 512,
 * WAIT_NE FF for the data response, WAIT_EQ FF for the busy.
 *
 * TX bookkeeping: s.unsent = the bytes in TX behind the read point (pushed,
 * not yet sent).  While a written block is kept (s.kept: at the commit
 * point) TX is not flushed after a command, so a retry's commands stand
 * behind the block; TX_REWIND goes back to the block, which is sent again
 * byte for byte, and leaves the commands behind it unsent ("stale").
 * Stale bytes are clocked out with CS off (the card ignores them) before
 * the next command is pushed.  After the card took the block: TX_FLUSH.
 *
 * from_gayle (findings/sdcard-engine Task 11a): the block comes from
 * Gayle's FIFO, GAYLE_TO_TX 512 behind [FF, FC] pushed by the CPU, and is
 * then kept in TX like a buffer's block.  Every from_gayle op is a CMD25
 * (one block too): a stop token can end it at any block boundary (the
 * caller closes a run; the Amiga abandoned the command).  The next block is
 * taken only after the caller's go (its sector is in the FIFO: ST_WR_PARK
 * until then, no peripheral op). */
#include <stdio.h>
#include <string.h>

#include "hardware.h"
#include "sdc.h"
#include "sdproto.h"
#include "mmc.h"

/* Wait-op bounds, TIMEOUT units of 16384 clk_114 = 144.4 us (design 11):
   T_NCR   R1 and data response: 16 = 2.3 ms; the spec's NCR is <= 8 bytes
           (160 us at 400 kHz, 3.4 us at 18.9 MHz)
   T_TOKEN read data token: 1732 = 250.1 ms; the spec's read access time
           is <= 100 ms (SDHC / SDXC: fixed 100 ms)
   T_BUSY  write busy, CMD12 busy, the stop token's busy: 6926 = 1.000 s;
           the spec's write busy is <= 250 ms (SDSC), 500 ms (SDHC / SDXC)
   A wait that times out is retried (the timeout row: 3 retries), so a
   card has 4 x the bound before the CMD13 probe. */
#define T_NCR    16
#define T_TOKEN  1732
#define T_BUSY   6926
/* ACMD41 polling at init: TIMER counts (5.804 ms): 345 = 2.002 s; the
   spec's initialisation is <= 1 s */
#define SD_ACMD41_BOUND 345

unsigned sd_err_count[SD_ROWS];
unsigned char sd_csd[16];
unsigned char sd_debug;
/* SCK = 113.46 MHz / (2 (div + 1)): 18.9, 14.2, 9.5, 6.3, 4.1, 2.0 MHz */
const unsigned char sd_sck_divs[SD_SCK_STEPS] = { 2, 3, 5, 8, 13, 27 };

static unsigned char sd_type;		/* CARDTYPE_*; 0: initialise first */
unsigned char sd_cid[16];		/* the CID of the card of the first init */
static unsigned char cid_known;		/* sd_cid holds it */
static unsigned char inited;		/* a first init since sd_forget(): later ones compare the CID */
static unsigned char changed;		/* another card (or no CID): no I/O until sd_forget() */
unsigned char sd_sck_step;		/* sd_sck_divs[] index; only ever up */
static sd_op *cur;			/* the active op */
static unsigned char polling;		/* sd_poll's re-entry guard */

static const char *const row_name[SD_ROWS] = {
	"command CRC", "read CRC", "write CRC (0B)", "write error (0D)", "timeout"
};
static const unsigned char row_retries[SD_ROWS] = { 3, 4, 4, 0, 3 };

/* steps (s.st: the peripheral op running) */
enum {
	ST_IDLE,
	ST_DRAIN,		/* XFER TX of stale bytes, CS off */
	ST_C_TX,		/* XFER TX: the command frame */
	ST_C_R1,		/* WAIT_NE FF: R1 */
	ST_C_RESP,		/* XFER RX: R2's second byte */
	ST_C_BUSY,		/* WAIT_EQ FF: R1b busy */
	ST_RD_TOKEN,		/* WAIT_NE FF: data token */
	ST_RD_DATA,		/* XFER RX + CRC check */
	ST_RD_GAYLE,		/* RX_TO_GAYLE 512 */
	ST_WR_TOKEN,		/* XFER TX 2: gap + token */
	ST_WR_DATA,		/* XFER TX + CRC16 512 */
	ST_WR_RESP,		/* WAIT_NE FF: data response */
	ST_WR_BUSY,		/* WAIT_EQ FF: programming */
	ST_STOP_TX,		/* XFER TX 2: stop token FD + a byte */
	ST_STOP_BUSY,		/* WAIT_EQ FF */
	ST_WR_GAYLE,		/* GAYLE_TO_TX 512: a from_gayle block into TX */
	ST_WR_PARK		/* from_gayle: no peripheral op, waits for sd_gayle_go / sd_close */
};
/* what follows a command (s.after) */
enum { A_READ, A_STOP, A_WRITE, A_APP, A_ACMD22, A_CSD, A_PROBE };
/* what a data block is (s.dkind) */
enum { D_BLOCK, D_REG, D_22 };

static struct {
	unsigned char st, after, next;
	unsigned char f[8], flen;		/* bytes to send: a command frame or the stop token */
	unsigned char nresp, r1b, r1, last;
	unsigned char rb[4];
	unsigned char c_crc, c_tmo, junk;	/* this command's retries; non-R1 bytes seen */
	unsigned char t_tok, t_busy, t_resp;	/* timeouts since the last progress */
	unsigned char rd_crc, wr_crc;		/* the block's CRC retries */
	unsigned char multi, kept, dresp, retry22, probing, dkind, gone, bad;
	unsigned char lost;			/* ACMD22 said fewer than taken: write retries */
	unsigned char regcmd;			/* D_REG: 9 (CSD) or 10 (CID) */
	unsigned char fail;			/* the error to end with once the card is stopped */
	unsigned char closing;			/* from_gayle: end the run at the next block boundary */
	unsigned short unsent, txlen, blen;
	unsigned done, run0;			/* blocks done; done at the start of this CMD25 */
	unsigned gsig, gtaken;			/* from_gayle: blocks the caller said are in the FIFO; taken from it */
} s;

/* CRC7 of the SD spec (x^7 + x^3 + 1), bitwise (design 11): as the byte
   the command ends with, (crc << 1) | 1 */
static unsigned char crc7(const unsigned char *p, unsigned n)
{
	unsigned c = 0, b, i;

	while (n--) {
		b = *p++;
		for (i = 0; i < 8; i++) {
			c = ((c << 1) ^ ((((c >> 6) ^ (b >> 7)) & 1) ? 0x09 : 0)) & 0x7F;
			b <<= 1;
		}
	}
	return (unsigned char)((c << 1) | 1);
}

/* FF (the card's chip-select set-up byte), command, argument, CRC7 */
static void frame(unsigned char *f, unsigned idx, unsigned long arg)
{
	f[0] = 0xFF;
	f[1] = 0x40 | idx;
	f[2] = arg >> 24;
	f[3] = arg >> 16;
	f[4] = arg >> 8;
	f[5] = arg;
	f[6] = crc7(f + 1, 5);
}

static unsigned long addr(unsigned lba)
{
	return sd_type == CARDTYPE_SDHC ? lba : (unsigned long)lba << 9;
}

int sd_card_type(void) { return sd_type; }
unsigned sd_sck_div(void) { return sd_sck_divs[sd_sck_step]; }

/* ---- error lines ---- */
static unsigned long err_lba(void)
{
	return cur ? (unsigned long)(cur->lba + s.done) : 0;
}
/* an error of the row; `retry` (1..) runs next */
static void row_err(int row, unsigned retry)
{
	sd_err_count[row]++;
	printf("SD: %s, row %d, retry %d of %d, lba %lu\n", row_name[row], row, (int)retry,
	       row_retries[row], err_lba());
}
/* an error of the row with no retry left */
static void row_out(int row)
{
	sd_err_count[row]++;
	printf("SD: %s, row %d, retries out, lba %lu\n", row_name[row], row, err_lba());
}

/* one SCK step down; at the last step nothing (no line); the divider is
   written while idle, so sdc_set_div cannot refuse it here, but the step
   only counts when it did not */
static void slower(void)
{
	if (sd_sck_step >= SD_SCK_STEPS - 1 || sdc_set_div(sd_sck_divs[sd_sck_step + 1]))
		return;
	sd_sck_step++;
	printf("SD: SCK one step slower, div %u\n", (unsigned)sd_sck_divs[sd_sck_step]);
}

/* ---- peripheral ops of the state machine ---- */
static void start(unsigned cmd, unsigned len)
{
	if (s.bad)
		return;
	if (sdc_start(cmd, len))
		s.bad = 1;		/* refused: after_step() ends the op */
}
static void xfer(unsigned bits, unsigned len, unsigned char st)
{
	s.st = st;
	s.txlen = (bits & SDC_X_TX) ? len : 0;
	start(SDC_OP_XFER | bits, len);
}
static void waitop(unsigned op, unsigned tmo, unsigned char st)
{
	s.st = st;
	SDC_W(SDC_MATCH, 0xFF);
	SDC_W(SDC_TIMEOUT, tmo);
	start(op, 0);
}

static void finish(int err)
{
	sd_op *op = cur;

	sdc_start(SDC_OP_TX_FLUSH, 0);
	sdc_start(SDC_OP_RX_FLUSH, 0);
	sdc_select(0);
	s.unsent = 0;
	s.kept = 0;
	s.st = ST_IDLE;
	/* the card's state is not known: initialise it before further use */
	if (err == SD_E_GONE || err == SD_E_RETRIES || err == SD_E_ABORT || err == SD_E_INTERNAL ||
	    err == SD_E_RESET)
		sd_type = 0;
	/* the Amiga abandoned the command and stopping the card failed too:
	   still no status for the old command (the caller's rule) */
	if (s.fail == SD_E_GAYLE)
		err = SD_E_GAYLE;
	op->err = err;
	op->done_blocks = (int)s.done;
	op->state = ST_IDLE;
	cur = 0;
	if (err && err != SD_E_GAYLE)
		printf("SD: op failed, err %d, lba %lu, %u of %u blocks\n", err, (unsigned long)op->lba,
		       s.done, op->count);
}

/* send s.f[0..flen), then state `next`; stale TX bytes go out first, CS off */
static void tx_send(unsigned char next)
{
	s.next = next;
	if (s.unsent) {
		sdc_select(0);
		xfer(SDC_X_TX, s.unsent, ST_DRAIN);
		return;
	}
	sdc_push(s.f, s.flen);
	s.unsent += s.flen;
	xfer(SDC_X_TX, s.flen, next);
}

/* ---- commands ---- */
static void cmd(unsigned idx, unsigned long arg, unsigned char after)
{
	frame(s.f, idx, arg);
	s.flen = 7;
	if (idx == 12) {
		s.f[7] = 0xFF;		/* the stuff byte after CMD12 */
		s.flen = 8;
	}
	s.nresp = idx == 13 ? 1 : 0;
	s.r1b = idx == 12;
	s.after = after;
	s.c_crc = 0;
	s.c_tmo = 0;
	s.junk = 0;
	tx_send(ST_C_TX);
}

/* the CMD13 probe got no R1 (timeout, or only stream bytes): card gone */
static void probe_gone(void)
{
	sd_err_count[SD_ROW_TIMEOUT]++;
	printf("SD: CMD13 probe: no answer, lba %lu\n", err_lba());
	finish(SD_E_GONE);
}

/* CMD13: does the card answer at all? */
static void probe(void)
{
	s.probing = 1;
	cmd(13, 0, A_PROBE);
}

/* the command failed (row): send it again, or after the 3rd retry probe */
static void cmd_fail(int row, unsigned char *n)
{
	if (*n < 3) {
		(*n)++;
		row_err(row, *n);
		s.junk = 0;
		tx_send(ST_C_TX);
		return;
	}
	row_out(row);
	probe();
}

/* a timeout of a token / busy / data-response wait: retry() or probe */
static int tmo_left(unsigned char *n)
{
	if (*n < 3) {
		(*n)++;
		row_err(SD_ROW_TIMEOUT, *n);
		return 1;
	}
	row_out(SD_ROW_TIMEOUT);
	probe();
	return 0;
}

static void read_cmd(void)
{
	s.multi = cur->count - s.done > 1;
	s.dkind = D_BLOCK;
	s.blen = 512;
	cmd(s.multi ? 18 : 17, addr(cur->lba + s.done), A_READ);
}
static void stop12(void) { cmd(12, 0, A_STOP); }
static void token_wait(void) { waitop(SDC_OP_WAIT_NE, T_TOKEN, ST_RD_TOKEN); }

static void acmd22(void)
{
	s.dkind = D_22;
	s.blen = 4;
	cmd(55, 0, A_APP);
}

/* the read op ends with s.fail (0 = ok); a CMD18 first stops the card */
static void read_end(void)
{
	if (s.dkind == D_BLOCK && cur->kind == SD_READ && s.multi)
		stop12();
	else
		finish(s.fail);
}

/* the data block again (CRC or token retry) */
static void reread(void)
{
	if (s.dkind == D_REG)
		cmd(s.regcmd, 0, A_CSD);
	else if (s.dkind == D_22)
		acmd22();
	else if (s.multi)
		stop12();		/* A_STOP: CMD18 from the failed block */
	else
		read_cmd();
}

static void write_cmd(void)
{
	s.multi = cur->count > 1 || cur->from_gayle;
	s.run0 = s.done;
	s.dkind = D_BLOCK;
	cmd(s.multi ? 25 : 24, addr(cur->lba + s.done), A_WRITE);
}

static void stop_token(void);

/* [FF, token, 512 bytes]: pushed (from_gayle: the 512 by GAYLE_TO_TX once
   the caller said the sector is there; parked until then, or the stop
   token when the caller closed the run), or the kept one again */
static void send_block(void)
{
	if (!s.kept) {
		unsigned char h[2];
		if (cur->from_gayle && s.gsig == s.gtaken) {
			if (s.closing)
				stop_token();
			else
				s.st = ST_WR_PARK;
			return;
		}
		h[0] = 0xFF;
		h[1] = s.multi ? 0xFC : 0xFE;
		sdc_push(h, 2);
		if (cur->from_gayle) {
			s.unsent += 2;
			s.st = ST_WR_GAYLE;
			start(SDC_OP_GAYLE_TO_TX | (cur->port ? SDC_G_PORT1 : 0), 512);
			return;
		}
		sdc_push(cur->buf + 512 * s.done, 512);
		s.unsent += 514;
		s.kept = 1;
	} else {
		start(SDC_OP_TX_REWIND, 0);
		s.unsent = SDC_R(SDC_TXLVL);
	}
	xfer(SDC_X_TX, 2, ST_WR_TOKEN);
}

static void stop_token(void)
{
	s.f[0] = 0xFD;
	s.f[1] = 0xFF;		/* a byte before the busy */
	s.flen = 2;
	tx_send(ST_STOP_TX);
}

/* the block was not taken: send it again */
static void retry_block(void)
{
	if (s.multi) {
		s.retry22 = 1;		/* stop token, ACMD22, CMD25 from there */
		stop_token();
	} else
		cmd(24, addr(cur->lba + s.done), A_WRITE);
}

/* ACMD22's count of the blocks the last CMD25 wrote */
static void acmd22_done(void)
{
	unsigned long k = (unsigned long)s.rb[0] << 24 | (unsigned long)s.rb[1] << 16 |
	                  (unsigned)s.rb[2] << 8 | s.rb[3];
	unsigned acc = s.done - s.run0;

	s.rd_crc = 0;
	s.t_tok = 0;
	if (k > acc) {			/* more than it took: no sense in it */
		finish(SD_E_RETRIES);
		return;
	}
	if (k < acc && cur->from_gayle) {	/* lost: Gayle's sectors are gone, nothing to send again */
		row_out(SD_ROW_WRCRC);
		finish(SD_E_RETRIES);
		return;
	}
	if (k < acc) {			/* it lost blocks it took: from buf again */
		/* each a write retry: bounded by the write CRC budget (the 05s
		   of the rewritten blocks reset wr_crc, this not) */
		if (s.lost >= 4) {
			row_out(SD_ROW_WRCRC);
			finish(SD_E_RETRIES);
			return;
		}
		s.lost++;
		row_err(SD_ROW_WRCRC, s.lost);
		s.done = s.run0 + (unsigned)k;
		start(SDC_OP_TX_FLUSH, 0);
		s.unsent = 0;
		s.kept = 0;
	}
	write_cmd();
}

static void block_read(void)
{
	s.done++;
	s.rd_crc = 0;
	s.t_tok = 0;
	if (s.done == cur->count)
		read_end();
	else
		token_wait();
}

/* a command's R1 (and its response bytes, busy) is in */
static void after_cmd(void)
{
	switch (s.after) {
	case A_READ:
	case A_CSD:
	case A_ACMD22:
		if (s.r1) {
			finish(SD_E_R1);
			return;
		}
		token_wait();
		return;
	case A_STOP:		/* an R1 error of CMD12 is the op's error too */
		if (s.r1 && !s.fail)
			s.fail = SD_E_R1;
		if (s.fail || s.done == cur->count)
			finish(s.fail);
		else
			read_cmd();
		return;
	case A_WRITE:
		if (s.r1) {
			finish(SD_E_R1);
			return;
		}
		send_block();
		return;
	case A_APP:
		if (s.r1) {
			finish(SD_E_R1);
			return;
		}
		cmd(22, 0, A_ACMD22);
		return;
	case A_PROBE:		/* the card answered: alive, but the op failed */
		finish(SD_E_RETRIES);
		return;
	}
}

/* one peripheral op ended with STATUS st (s.last = LAST) */
static void step(unsigned st)
{
	unsigned char r;

	if (s.txlen) {
		if (!(st & (SDC_ST_ABORTED | SDC_ST_GONE)))
			s.unsent -= s.txlen;
		s.txlen = 0;
	}
	if (s.gone || (st & SDC_ST_GONE)) {
		finish(SD_E_GONE);
		return;
	}
	if (st & SDC_ST_ABORTED) {
		finish(SD_E_ABORT);
		return;
	}
	switch (s.st) {
	case ST_DRAIN:
		sdc_select(1);
		tx_send(s.next);
		return;

	case ST_C_TX:
		if (!s.kept) {
			start(SDC_OP_TX_FLUSH, 0);
			s.unsent = 0;
		}
		waitop(SDC_OP_WAIT_NE, T_NCR, ST_C_R1);
		return;
	case ST_C_R1:
		if (st & SDC_ST_TIMEOUT) {
			if (s.probing)
				probe_gone();
			else
				cmd_fail(SD_ROW_TIMEOUT, &s.c_tmo);
			return;
		}
		r = s.last;
		if (r & 0x80) {		/* not an R1: bytes of a stream still running */
			if (++s.junk < 16)
				waitop(SDC_OP_WAIT_NE, T_NCR, ST_C_R1);
			else if (s.probing)
				probe_gone();
			else
				cmd_fail(SD_ROW_TIMEOUT, &s.c_tmo);
			return;
		}
		if (r & 0x01) {		/* idle: the card reset itself (power) */
			printf("SD: card in idle state (R1 %02x), lba %lu\n", (unsigned)r, err_lba());
			finish(SD_E_RESET);
			return;
		}
		if ((r & 0x08) && !s.probing) {
			cmd_fail(SD_ROW_CMDCRC, &s.c_crc);
			return;
		}
		s.r1 = r;
		if (sd_debug)
			printf("SD cmd%u %08lx r1 %02x\n", (unsigned)(s.f[1] & 0x3F),
			       (unsigned long)s.f[2] << 24 | (unsigned long)s.f[3] << 16 |
			       (unsigned)s.f[4] << 8 | s.f[5], (unsigned)r);
		if (s.probing) {
			finish(SD_E_RETRIES);
			return;
		}
		if (s.nresp) {
			xfer(SDC_X_RX, s.nresp, ST_C_RESP);
			return;
		}
		/* fall through */
	case ST_C_RESP:
		if (s.st == ST_C_RESP)
			sdc_pop(s.rb, s.nresp);
		if (s.r1b) {
			waitop(SDC_OP_WAIT_EQ, T_BUSY, ST_C_BUSY);
			return;
		}
		after_cmd();
		return;
	case ST_C_BUSY:
		if (st & SDC_ST_TIMEOUT) {
			if (tmo_left(&s.t_busy))
				waitop(SDC_OP_WAIT_EQ, T_BUSY, ST_C_BUSY);
			return;
		}
		s.t_busy = 0;
		after_cmd();
		return;

	case ST_RD_TOKEN:
		if (st & SDC_ST_TIMEOUT) {
			if (tmo_left(&s.t_tok))
				reread();
			return;
		}
		if (s.last != 0xFE) {	/* a data error token */
			s.fail = SD_E_TOKEN;
			read_end();
			return;
		}
		xfer(SDC_X_RX | SDC_X_RXCRC, s.blen, ST_RD_DATA);
		return;
	case ST_RD_DATA:
		if (!(st & SDC_ST_CRC_OK)) {
			/* RX is poisoned: nothing of it leaves (the interlock) */
			start(SDC_OP_RX_FLUSH, 0);
			if (s.rd_crc >= 4) {
				row_out(SD_ROW_RDCRC);
				s.fail = SD_E_RETRIES;
				read_end();
				return;
			}
			s.rd_crc++;
			row_err(SD_ROW_RDCRC, s.rd_crc);
			if (s.rd_crc == 3)
				slower();
			reread();
			return;
		}
		if (s.dkind == D_REG) {
			sdc_pop(cur->buf, 16);
			finish(SD_OK);
			return;
		}
		if (s.dkind == D_22) {
			sdc_pop(s.rb, 4);
			acmd22_done();
			return;
		}
		if (cur->to_gayle) {
			s.st = ST_RD_GAYLE;
			start(SDC_OP_RX_TO_GAYLE | (cur->port ? SDC_G_PORT1 : 0), 512);
			return;
		}
		sdc_pop(cur->buf + 512 * s.done, 512);
		block_read();
		return;
	case ST_RD_GAYLE:
		if (st & SDC_ST_GERR) {	/* the Amiga abandoned the command */
			start(SDC_OP_RX_FLUSH, 0);
			s.fail = SD_E_GAYLE;
			read_end();
			return;
		}
		block_read();
		return;

	case ST_WR_GAYLE:
		if (st & SDC_ST_GERR) {	/* the Amiga abandoned the command (TX rolled back) */
			start(SDC_OP_TX_FLUSH, 0);	/* the [FF, FC] in front */
			s.unsent = 0;
			s.fail = SD_E_GAYLE;
			stop_token();
			return;
		}
		s.gtaken++;
		s.unsent += 512;
		s.kept = 1;
		xfer(SDC_X_TX, 2, ST_WR_TOKEN);
		return;
	case ST_WR_PARK:		/* a TX_FLUSH's own end: nothing runs */
		return;
	case ST_WR_TOKEN:
		xfer(SDC_X_TX | SDC_X_TXCRC, 512, ST_WR_DATA);
		return;
	case ST_WR_DATA:
		waitop(SDC_OP_WAIT_NE, T_NCR, ST_WR_RESP);
		return;
	case ST_WR_RESP:
		s.dresp = (st & SDC_ST_TIMEOUT) ? 0xFF : (s.last & 0x1F);
		waitop(SDC_OP_WAIT_EQ, T_BUSY, ST_WR_BUSY);
		return;
	case ST_WR_BUSY:
		if (st & SDC_ST_TIMEOUT) {
			if (tmo_left(&s.t_busy))
				waitop(SDC_OP_WAIT_EQ, T_BUSY, ST_WR_BUSY);
			return;
		}
		s.t_busy = 0;
		switch (s.dresp) {
		case 0x05:		/* taken and programmed */
			s.done++;
			s.wr_crc = 0;
			s.t_resp = 0;
			start(SDC_OP_TX_FLUSH, 0);
			s.unsent = 0;
			s.kept = 0;
			if (s.done < cur->count)
				send_block();
			else if (s.multi)
				stop_token();
			else
				finish(SD_OK);
			return;
		case 0x0D:		/* write error: no retry */
			row_out(SD_ROW_WRFAIL);
			s.fail = SD_E_WRFAIL;
			if (s.multi)
				stop_token();
			else
				finish(SD_E_WRFAIL);
			return;
		case 0x0B:		/* CRC: the same block again */
			if (s.wr_crc >= 4) {
				row_out(SD_ROW_WRCRC);
				s.fail = SD_E_RETRIES;
				if (s.multi)
					stop_token();
				else
					finish(SD_E_RETRIES);
				return;
			}
			s.wr_crc++;
			row_err(SD_ROW_WRCRC, s.wr_crc);
			if (s.wr_crc == 3)
				slower();
			retry_block();
			return;
		default:		/* no data response */
			if (tmo_left(&s.t_resp))
				retry_block();
			return;
		}
	case ST_STOP_TX:
		waitop(SDC_OP_WAIT_EQ, T_BUSY, ST_STOP_BUSY);
		return;
	case ST_STOP_BUSY:
		if (st & SDC_ST_TIMEOUT) {
			if (tmo_left(&s.t_busy))
				waitop(SDC_OP_WAIT_EQ, T_BUSY, ST_STOP_BUSY);
			return;
		}
		s.t_busy = 0;
		if (s.retry22 && !s.fail) {
			s.retry22 = 0;
			acmd22();
			return;
		}
		finish(s.fail);
		return;
	}
}

/* a refused start ends the op (a firmware bug: the peripheral says no) */
static void after_step(void)
{
	if (s.bad && cur) {
		s.bad = 0;
		if (sdc_status() & SDC_ST_BUSY)
			sdc_start(SDC_OP_ABORT, 0);
		finish(SD_E_INTERNAL);
	}
	if (cur)
		cur->state = s.st;
}

static void take_cd(void)
{
	if (sdc_events & SDC_IRQ_CD) {
		sdc_take(SDC_IRQ_CD);
		sd_type = 0;		/* card changed: initialise again */
		if (cur) {
			s.gone = 1;
			if (sdc_status() & SDC_ST_BUSY)
				sdc_start(SDC_OP_ABORT, 0);	/* its DONE ends the op */
			else if (s.st == ST_WR_PARK)
				finish(SD_E_GONE);	/* no op runs: no DONE will come */
		}
	}
}

int sd_submit(sd_op *op)
{
	int bad;

	if (cur)
		return -1;
	take_cd();
	op->err = SD_OK;
	op->done_blocks = 0;
	op->state = ST_IDLE;
	if (op->kind == SD_READ)
		bad = op->from_gayle || !op->buf == !op->to_gayle;
	else if (op->kind == SD_WRITE)
		bad = op->to_gayle || (op->from_gayle ? op->buf != 0 : !op->buf);
	else
		bad = (op->kind != SD_CSD && op->kind != SD_CID) || !op->buf;
	if (bad) {
		op->err = SD_E_ARG;
		return 0;
	}
	if ((op->kind == SD_READ || op->kind == SD_WRITE) && !op->count)
		return 0;
	if (changed) {			/* another card: nothing goes to it */
		op->err = SD_E_GONE;
		return 0;
	}
	if (!sd_type) {
		op->err = SD_E_NOCARD;
		return 0;
	}
	memset(&s, 0, sizeof s);
	s.gsig = op->from_gayle ? 1 : 0;	/* the submit is the first block's go */
	cur = op;
	sdc_start(SDC_OP_RX_FLUSH, 0);
	sdc_start(SDC_OP_TX_FLUSH, 0);
	sdc_select(1);
	if (op->kind == SD_READ)
		read_cmd();
	else if (op->kind == SD_WRITE)
		write_cmd();
	else {
		s.dkind = D_REG;
		s.blen = 16;
		s.regcmd = op->kind == SD_CID ? 10 : 9;
		cmd(s.regcmd, 0, A_CSD);
	}
	after_step();
	return 0;
}

int sd_poll(void)
{
	unsigned e, st;

	if (polling)
		return cur != 0;
	polling = 1;
	take_cd();
	e = sdc_events;
	if (cur && (e & SDC_IRQ_DONE)) {
		st = sdc_status();
		if (!(st & SDC_ST_BUSY)) {
			sdc_take(SDC_IRQ_DONE | SDC_IRQ_ERR);
			s.last = SDC_R(SDC_LAST);
			step(st);
			after_step();
		}
	} else if ((e & SDC_IRQ_ERR) && !(e & SDC_IRQ_DONE) && (sdc_status() & SDC_ST_BUSY))
		/* an error event of a running op that is not its end (FIFO
		   misuse, counted in sdc_misuse at the next start) */
		sdc_clear(SDC_IRQ_ERR);
	polling = 0;
	return cur != 0;
}

/* a parked from_gayle op that has its go or was closed: on */
static void unpark(void)
{
	if (polling || !cur || s.st != ST_WR_PARK || (s.gsig == s.gtaken && !s.closing))
		return;
	polling = 1;
	send_block();
	after_step();
	polling = 0;
}

int sd_gayle_need(const sd_op *op)
{
	return op && op == cur && op->from_gayle && !s.closing && !s.fail && s.gsig == s.gtaken &&
	       s.gtaken < op->count;
}

int sd_gayle_go(sd_op *op)
{
	if (!sd_gayle_need(op))
		return -1;
	s.gsig++;
	unpark();
	return 0;
}

void sd_close(sd_op *op)
{
	if (!op || op != cur || !op->from_gayle)
		return;
	s.closing = 1;
	unpark();
}

int sd_gayle_parked(const sd_op *op)
{
	return op && op == cur && s.st == ST_WR_PARK;
}

int sd_gayle_busy(void)
{
	return cur && (s.st == ST_RD_GAYLE || s.st == ST_WR_GAYLE);
}

/* the active op to its end; a parked from_gayle run is closed first (its
   feeder, the HDD path in the main loop, cannot run now) */
static void sync_cur(const sd_op *op)
{
	while (cur && (!op || cur == op)) {
		if (s.st == ST_WR_PARK) {
			sd_close(cur);
			if (s.st == ST_WR_PARK)
				break;		/* inside sd_poll: cannot be (sd_submit refuses then) */
			continue;
		}
		sdc_wait(SDC_IRQ_DONE);
		sd_poll();
	}
}

void sd_drain(void)
{
	sync_cur(0);
	sd_poll();
}

int sd_sync(sd_op *op)
{
	sync_cur(0);
	sd_poll();
	if (!sd_type && !changed)
		sd_init();
	if (sd_submit(op)) {
		op->err = SD_E_INTERNAL;
		return op->err;
	}
	sync_cur(op);
	return op->err;
}

/* ---- initialisation (synchronous: boot, or before the next op) ---- */
/* one peripheral op to its end: STATUS, or -1 (refused, sdc_wait's bound) */
static int run(unsigned c, unsigned len)
{
	unsigned e;

	if (sdc_start(c, len))
		return -1;
	for (;;) {
		e = sdc_wait(SDC_IRQ_DONE);
		if (!e)
			return -1;
		if (e & SDC_IRQ_DONE)
			break;
		sdc_clear(e);		/* ERR alone, CD: the op's STATUS tells */
	}
	sdc_take(SDC_IRQ_DONE | SDC_IRQ_ERR | SDC_IRQ_CD);
	return (int)sdc_status();
}

/* a command: R1, -1 no R1 after 4 tries, -2 card gone; n response bytes */
static int icmd(unsigned idx, unsigned long arg, unsigned char *resp, unsigned n)
{
	unsigned char f[7];
	unsigned tries;
	int st, r1;

	frame(f, idx, arg);
	for (tries = 1; tries <= 4; tries++) {
		sdc_push(f, 7);
		st = run(SDC_OP_XFER | SDC_X_TX, 7);
		sdc_start(SDC_OP_TX_FLUSH, 0);
		if (st < 0 || (st & SDC_ST_GONE))
			return -2;
		SDC_W(SDC_MATCH, 0xFF);
		SDC_W(SDC_TIMEOUT, T_NCR);
		st = run(SDC_OP_WAIT_NE, 0);
		if (st < 0 || (st & SDC_ST_GONE))
			return -2;
		if (st & SDC_ST_TIMEOUT) {
			if (tries <= 3)
				row_err(SD_ROW_TIMEOUT, tries);
			else
				row_out(SD_ROW_TIMEOUT);
			continue;
		}
		r1 = SDC_R(SDC_LAST);
		if ((r1 & 0x88) == 0x08) {
			if (tries <= 3)
				row_err(SD_ROW_CMDCRC, tries);
			else
				row_out(SD_ROW_CMDCRC);
			continue;
		}
		if (n) {
			st = run(SDC_OP_XFER | SDC_X_RX, n);
			if (st < 0 || (st & SDC_ST_GONE))
				return -2;
			sdc_pop(resp, n);
		}
		if (sd_debug)
			printf("SD cmd%u %08lx r1 %02x\n", idx, arg, (unsigned)r1);
		return r1;
	}
	return -1;
}

static void init_line(const char *what, int r1)
{
	printf("SD init: %s %02x\n", what, (unsigned)(r1 & 0xFF));
}

void sd_forget(void)
{
	inited = 0;
	cid_known = 0;
	changed = 0;
}

int sd_card_changed(void) { return changed; }

int sd_init(void)
{
	unsigned char r[4], cid[16];
	unsigned polls = 0, n;
	unsigned long t;
	int r1, v2, mmc = 0, type;
	sd_op op = { 0 };

	if (cur || changed)
		return 0;
	sd_type = 0;
	sdc_init();			/* SCK 400 kHz, CS off, FIFOs empty */
	/* >= 74 clocks with CS high */
	if (run(SDC_OP_XFER, 10) < 0 || sdc_select(1)) {
		init_line("no peripheral", 0xFF);
		return 0;
	}
	r1 = -1;
	for (n = 0; n < 4 && r1 != 0x01 && r1 != -2; n++)
		r1 = icmd(0, 0, 0, 0);
	init_line("CMD0", r1);
	if (r1 != 0x01)
		goto fail;
	r1 = icmd(8, 0x1AA, r, 4);
	init_line("CMD8", r1);
	if (r1 == 0x01) {
		if (r[2] != 0x01 || r[3] != 0xAA)
			goto fail;
		v2 = 1;
	} else if (r1 >= 0 && (r1 & 0x04))
		v2 = 0;			/* illegal command: SD v1 or MMC */
	else
		goto fail;
	t = GetTimer(SD_ACMD41_BOUND);
	do {
		polls++;
		if (!mmc) {
			r1 = icmd(55, 0, 0, 0);
			if (r1 >= 0 && !(r1 & 0xFE))
				r1 = icmd(41, v2 ? 1ul << 30 : 0, 0, 0);
			if (!v2 && r1 >= 0 && (r1 & 0x04))
				mmc = 1;	/* no ACMD41: MMC, CMD1 */
		}
		if (mmc)
			r1 = icmd(1, 0, 0, 0);
		if (r1 != 0x01)
			break;
	} while (!CheckTimer(t));
	printf("SD init: ACMD41 %02x, %u polls\n", (unsigned)(r1 & 0xFF), polls);
	if (r1 != 0)
		goto fail;
	type = mmc ? CARDTYPE_MMC : CARDTYPE_SD;
	if (v2) {
		r1 = icmd(58, 0, r, 4);
		if (r1 != 0) {
			init_line("CMD58", r1);
			goto fail;
		}
		if (r[0] & 0x40)
			type = CARDTYPE_SDHC;
		printf("SD init: OCR %08lx, type %d\n", (unsigned long)r[0] << 24 | (unsigned long)r[1] << 16 |
		       (unsigned)r[2] << 8 | r[3], type);
	} else
		printf("SD init: type %d (no OCR)\n", type);
	r1 = icmd(59, 1, 0, 0);		/* CRC on */
	init_line("CMD59", r1);
	if (r1 != 0)
		goto fail;
	if (type != CARDTYPE_SDHC) {
		r1 = icmd(16, 512, 0, 0);
		init_line("CMD16", r1);
		if (r1 != 0)
			goto fail;
	}
	sdc_select(0);
	sdc_set_div(sd_sck_divs[sd_sck_step]);
	sd_type = (unsigned char)type;
	/* the CID: kept at the first init; every later init (after card gone, a
	   card-detect change, retries out) must find the same card, or nothing
	   goes to the card any more until sd_forget() (the firmware's restart):
	   the mounted FAT and hardfiles describe the old card */
	op.kind = SD_CID;
	op.buf = cid;
	if (sd_submit(&op) == 0)
		sync_cur(&op);
	if (inited && (op.err || !cid_known || memcmp(cid, sd_cid, 16))) {
		changed = 1;
		sd_type = 0;
		init_line(op.err ? "CID unreadable: card changed? no I/O until a restart" :
		          "card changed (CID): no I/O until a restart", op.err);
		return 0;
	}
	if (!inited && !op.err) {
		memcpy(sd_cid, cid, 16);
		cid_known = 1;
	}
	if (op.err)
		init_line("CMD10", op.err);	/* the first init goes on without it */
	inited = 1;
	memset(&op, 0, sizeof op);
	op.kind = SD_CSD;
	op.buf = sd_csd;
	if (sd_submit(&op) == 0)
		sync_cur(&op);
	if (op.err) {
		init_line("CMD9", op.err);
		sd_type = 0;
		return 0;
	}
	printf("SD init: SCK div %u\n", (unsigned)sd_sck_divs[sd_sck_step]);
	return type;
fail:
	sdc_start(SDC_OP_TX_FLUSH, 0);
	sdc_start(SDC_OP_RX_FLUSH, 0);
	sdc_select(0);
	return 0;
}

void sd_report(void)
{
	printf("SD errors: cmdcrc %u rdcrc %u wrcrc %u wrfail %u timeout %u, SCK div %u\n",
	       sd_err_count[SD_ROW_CMDCRC], sd_err_count[SD_ROW_RDCRC], sd_err_count[SD_ROW_WRCRC],
	       sd_err_count[SD_ROW_WRFAIL], sd_err_count[SD_ROW_TIMEOUT], (unsigned)sd_sck_divs[sd_sck_step]);
}

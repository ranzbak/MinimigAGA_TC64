/* sdproto: the SD card protocol (SPI mode) on the SD card peripheral
 * (sdc.h, rtl/host/sdcard_spi.v; findings/sdcard-engine design.md 5.1 and
 * 11, plan Task 10).  mmc.c's MMC_* calls are sd_sync() wrappers.
 *
 * One card operation at a time: an op is one block command run on the card
 * (CMD17 / CMD18 + CMD12, CMD24 / CMD25 + stop token, CMD9) up to its end.
 * sd_submit() starts it, sd_poll() advances it on the peripheral's events
 * (sdc_events: one peripheral op per step, never a wait in the CPU),
 * sd_sync() runs one to its end for the CPU-side callers.
 *
 * Correctness rules (design 3.3):
 *  - CRC on: CMD59(1) after init, so the card checks every command's CRC7
 *    and every written block's CRC16; every read block's CRC16 is checked
 *    by the peripheral (XFER bit 7) before a byte of it leaves RX: popped
 *    into buf only after STATUS crc_ok, sent to Gayle (RX_TO_GAYLE) only
 *    through the peripheral's interlock.
 *  - A written block is pushed into TX whole and sent from there; a retry
 *    sends the same bytes again (TX keep, TX_REWIND), never a CPU copy.
 *  - Every wait is a peripheral wait op bounded by TIMEOUT, every XFER by
 *    its byte count (sd_sync: sdc_wait's TIMER bound on top): an op ends
 *    with err set, in bounded time.
 *  - Errors (the retry table, design 5.1; counted in sd_err_count[], one
 *    UART line each):
 *      row                       retries   then
 *      SD_ROW_CMDCRC  R1 bit 3     3       CMD13 probe: no answer = gone
 *      SD_ROW_RDCRC   block CRC16  4       re-read from the failed block;
 *                                          the 3rd retry drops SCK a step
 *      SD_ROW_WRCRC   data resp 0B 4       resend the block from TX (CMD25:
 *                                          stop token, ACMD22, resume); the
 *                                          3rd retry drops SCK a step
 *      SD_ROW_WRFAIL  data resp 0D 0       error
 *      SD_ROW_TIMEOUT R1 / token / 3       CMD13 probe: no answer = gone
 *                     busy / data response
 *    A lowered SCK stays lowered until the firmware restarts.  After
 *    SD_E_GONE, SD_E_RETRIES, SD_E_ABORT, SD_E_RESET (an R1 with the idle
 *    bit) or a card-detect change the card is initialised again (sd_sync
 *    does it) before any further use, and must be the same card (CID).
 *    ACMD22 counting fewer blocks than the card took: those again from buf,
 *    each time a write retry (at most 4 per op).
 *
 * Debug output (UART): sd_init's steps ("SD init: CMD0 01": the R1; ff no
 * answer, fe no card / card gone), one line per error (its row and retry),
 * each SCK step down, a line per failed op (its SD_E_* code; none for
 * SD_E_GAYLE), sd_report() (the counters).  Per command a line only with
 * sd_debug != 0 (set it over the GDB tunnel or from code).
 */
#ifndef SDPROTO_H
#define SDPROTO_H

/* the retry table's rows (design 5.1), the indices of sd_err_count[] */
enum sd_row {
	SD_ROW_CMDCRC,		/* command response CRC wrong (R1 bit 3) */
	SD_ROW_RDCRC,		/* read block CRC16 wrong */
	SD_ROW_WRCRC,		/* written block rejected, CRC (0x0B) */
	SD_ROW_WRFAIL,		/* written block rejected, write error (0x0D) */
	SD_ROW_TIMEOUT,		/* timeout: response, token, busy, data response */
	SD_ROWS
};
/* every error event of each row since power-on, retried ones included */
extern unsigned sd_err_count[SD_ROWS];

/* sd_op.err */
enum sd_err {
	SD_OK = 0,
	SD_E_RETRIES,		/* a row ran out of retries (the card answered CMD13) */
	SD_E_WRFAIL,		/* data response 0D: the card failed to program */
	SD_E_R1,		/* the card refused the command (R1 error bits) */
	SD_E_TOKEN,		/* a data error token instead of the block */
	SD_E_GONE,		/* card gone / changed / does not answer CMD13 */
	SD_E_GAYLE,		/* RX_TO_GAYLE ended by Gayle (STATUS 7): the Amiga
				   abandoned the command, report nothing for it */
	SD_E_NOCARD,		/* no initialised card (sd_init failed) */
	SD_E_ARG,		/* the op is not one this layer runs */
	SD_E_ABORT,		/* sdc_wait's bound ran out, the step was aborted */
	SD_E_RESET,		/* an R1 with the idle bit: the card reset itself (to be
				   initialised again) */
	SD_E_INTERNAL		/* the peripheral refused a step: a firmware bug */
};

/* sd_op.kind */
enum sd_kind { SD_READ, SD_WRITE, SD_CSD, SD_CID };

/* One op.  The caller fills lba, count, buf, to_gayle, from_gayle, port,
 * kind; sd_submit sets the rest.
 *  SD_READ: count blocks from lba (CMD17 for 1, CMD18 + CMD12 for more)
 *    into buf, or with to_gayle (buf 0) into Gayle's FIFO of port (0/1),
 *    one RX_TO_GAYLE of 512 bytes per block, each after its CRC.
 *  SD_WRITE: count blocks from buf to lba (CMD24 for 1, CMD25 + stop
 *    token for more).  from_gayle (GAYLE_TO_TX) is Task 11's: SD_E_ARG.
 *  SD_CSD: the 16 bytes of CMD9 into buf; SD_CID: CMD10's.
 * state: the step it is in (0 = not running), err: enum sd_err once it
 * ended, done_blocks: blocks delivered (read) / programmed (write). */
typedef struct sd_op {
	unsigned lba, count;
	unsigned char *buf;
	int to_gayle, from_gayle, port;
	int state, err, done_blocks;
	int kind;
} sd_op;

/* CMD0, CMD8, ACMD41 (HCS), CMD58, CMD59(1), CMD16 (byte-addressed cards),
   CMD9 into CSDData (mmc.h); SCK ~400 kHz, then the data rate (div 2 =
   18.9 MHz, or the lowered one).  Resets the peripheral first (sdc_init).
   Returns the card type (CARDTYPE_*, mmc.h), 0 when it failed.  Never while
   an op is active. */
int sd_init(void);
/* the CSD sd_init read (CMD9, CRC16 checked); the CID of the first init
   (CMD10, CRC16 checked) */
extern unsigned char sd_csd[16];
extern unsigned char sd_cid[16];
/* Card swap (the mounted FAT, hardfiles and ADFs describe the card they were
   opened on): the first sd_init after sd_forget() keeps the CID; every later
   one reads it again, and on another CID (or none) the card counts as
   changed: sd_init returns 0 and every op ends SD_E_GONE until sd_forget()
   (MMC_Init: the firmware's (re)start). */
void sd_forget(void);
int sd_card_changed(void);
/* the card type of the last sd_init, 0 = none / to be initialised again */
int sd_card_type(void);

/* start op: 0, or -1 when another op is active (op untouched).  An op that
   cannot start (no card, bad arguments) ends at once: 0, op->err set,
   op->state 0. */
int sd_submit(sd_op *op);
/* advance the active op on sdc_events (also takes a card-detect event):
   1 while an op is active, 0 when idle.  Non-reentrant: a nested call
   returns at once.  Never from an interrupt handler. */
int sd_poll(void);
/* finish the active op, initialise the card again if it must be, then run
   op to its end (sdc_wait: CPU-side callers only, interrupts on).  Returns
   op->err. */
int sd_sync(sd_op *op);

/* SCK divider step table, from the fastest to the slowest */
#define SD_SCK_STEPS 6
extern const unsigned char sd_sck_divs[SD_SCK_STEPS];
unsigned sd_sck_div(void);		/* the data-rate divider in use */
/* its index: 0 at power-on, one up per step down, never back (a test may
   set it) */
extern unsigned char sd_sck_step;

/* per-command UART lines when != 0 */
extern unsigned char sd_debug;
/* one UART line: sd_err_count[] and the SCK divider */
void sd_report(void);

#endif

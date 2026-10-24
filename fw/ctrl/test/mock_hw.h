/* mock_hw: the host-test model of the OSD CPU's hardware (SPI, TIMER, UART,
 * PLATFORM, AUDIO) behind the -DHOSTTEST hooks of ../hardware.h.
 *
 *  - SPI trace: every frame (a run of constant chip-select register) with the
 *    bytes out and the bytes in, in the normalised spi.txt format of the L2
 *    bench (sim/host_bridge/tb_host_bridge.v +SPI_LOG, read by spitrace.py):
 *        <cs> <out bytes> / <in bytes>        hex, lowercase, no timestamps
 *    <cs> is the Enable value of the selected line (20 OSD, 10 FPGA, 02 card,
 *    40 DMode, 80 RTC, 00 none; the register model is cfide's: Enable sets
 *    the line's bit and bit 0, Disable clears them, the trace shows the
 *    register without bit 0).  A frame with cs 00 and no bytes is not written.
 *  - MISO per chip select: a queue of reply bytes, or a callback; nothing
 *    scripted gives the idle byte (0xFF).  Card (cs 02): the card image model.
 *  - Direct mode (DMode, 0x40, with the card selected): one SPI write clocks
 *    512 bytes out of the card with MOSI high, as cfide does (shiftcnt
 *    "10111111111111": 4096 clocks); the trace shows them under cs 42.
 *  - TIMER: a counter, advanced by hosttest_advance(), by `step` on every
 *    read, so that a CheckTimer() loop ends, and (mock_timer_spi_rate) by 1
 *    every n SPI bytes: time that passes with the bytes on the wire.
 *  - HOST_REQ: bit 0 (OSD_RDY) 0 for a scripted number of reads, then 1;
 *    the order of those reads and the SPI DATA accesses (mock_order).
 *  - UART: the bytes of RS232(), kept as text.
 *  - RAM: AUDIO_BUFFER (the audio ring) and the room in front of it.
 *  - SD card engine (the second half of this file): the card model's Task 4
 *    knobs (CMD59, CMD13, CMD25, ACMD22, error injection, removal), one
 *    clock in clk_114 cycles that the TIMER follows, the SD peripheral of
 *    rtl/host/sdcard_spi.v behind sdc.h's SDC_R / SDC_W, its Gayle bridge,
 *    and cfide's interrupt controller with the CPU's MIE behind arch/irq.h.
 */
#ifndef MOCK_HW_H
#define MOCK_HW_H

#include <stddef.h>

/* everything back to power-on: trace, scripts, card (unloaded), timer 0 with
   step 1, UART empty, PLATFORM/AUDIO 0 */
void mock_reset(void);

/* ---- SPI trace ---- */
const char *mock_trace(void);               /* the open frame is closed first */
int mock_trace_write(const char *path);     /* 0 = ok */
int mock_frames(void);                      /* frames in the trace so far */
unsigned mock_cs(void);                     /* the CS register (cfide's scs) */
unsigned mock_spi_speed(void);              /* last SPEED write, 0 = none */
/* every SPEED write with the card commands parsed before it, one line each:
   "3f after 0 commands" */
const char *mock_spi_speed_log(void);

/* ---- scripted MISO ---- */
/* cs = the Enable value: 0x10 FPGA, 0x20 OSD, 0x40 DMode, 0x80 RTC, 0x00 no select */
void mock_script_bytes(unsigned cs, const unsigned char *b, size_t n);
typedef unsigned char (*mock_miso_fn)(void *ctx, unsigned char out);
void mock_script_fn(unsigned cs, mock_miso_fn fn, void *ctx);
void mock_script_idle(unsigned cs, unsigned char idle);   /* queue empty: this byte */
unsigned mock_script_left(unsigned cs);     /* queued bytes not yet read */
unsigned mock_underruns(unsigned cs);       /* reads that found the queue empty */
/* direct-mode transfers so far (512 card bytes each, into the FPGA): a
   callback's view of what reached the Gayle FIFO outside its own frames */
unsigned mock_dmode_blocks(void);

/* ---- SD card image model (sim/common/sd_spi_model.v) ---- */
/* sectors 0: 65536 or the image if larger (rounded up to 1024) */
int mock_card_load(const char *path, unsigned sectors);   /* 0 = ok */
int mock_card_save(const char *path);
const unsigned char *mock_card_sector(unsigned lba);      /* NULL beyond the card */
/* model defaults 4 8 1 2.  token_dly < 0: no data token ever (reads, CSD:
   0xFF until the card is deselected); busy < 0: busy (0x00) without end after
   a write or CMD12, until deselect or CMD0 (not in sd_spi_model.v: the timeout
   cases of mmc_test) */
void mock_card_params(int token_dly, int busy, int ncr, int init_polls);
unsigned mock_card_commands(void);          /* commands the card has parsed */
/* one line per command, as sd_spi_model.v's +SD_LOG=1 lines without the time
   and cs fields: "CMD0 arg=00000000", "ACMD41 arg=40000000" (A = after CMD55) */
const char *mock_card_log(void);

/* ---- TIMER ---- */
void hosttest_advance(unsigned n);
void mock_timer_step(unsigned n);           /* added after every read, default 1 */
void mock_timer_spi_rate(unsigned n);       /* +1 every n SPI bytes, 0 = off (default) */
unsigned mock_timer_reads(void);

/* ---- HOST_REQ (cfide 0xFFFFFFB4, bit 0 OSD_RDY) ---- */
/* the next `zeros` reads return 0, every read after them 1 (OSD_RDY);
   MOCK_HOST_REQ_STUCK: 0 for ever.  After mock_reset(): 1 at once. */
#define MOCK_HOST_REQ_STUCK (~0u)
void mock_host_req(unsigned zeros);
unsigned mock_host_req_reads(void);
/* the order of the HOST_REQ reads and the SPI DATA accesses since the last
   mock_order_start() (recording is off after mock_reset()): one character
   each, '0' / '1' a HOST_REQ read and its bit 0, 'W' an SPI DATA write,
   'R' a read of it (SPI(x) is "WR", RDSPI "R"); at most 4095 characters,
   then '+' and nothing more */
void mock_order_start(void);
const char *mock_order(void);

/* ---- UART, PLATFORM, AUDIO ---- */
const char *mock_uart(void);
size_t mock_uart_len(void);
void mock_uart_clear(void);
void mock_platform_set(unsigned short v);
void mock_audio_set(unsigned char v);   /* what reads of AUDIO return (until a write) */

/* ---- RAM: AUDIO_BUFFER and the room in front of it ---- */
/* AUDIO_BUFFER (hardware.h under HOSTTEST) is the ring, MOCK_RING_BYTES; the
   MOCK_LOAD_AREA bytes in front of it start at __bss_end (drivesounds_init
   loads DRIVESND.BIN there, as on the target: 0x70000 - __bss_end, 0x48f54
   bytes in the build of Task 14).  Zero after mock_reset(). */
#define MOCK_LOAD_AREA  0x48000
#define MOCK_RING_BYTES 0x10000          /* 2 x AUDIO_BUFFER_SIZE */
unsigned char *mock_ring(void);

/* =====================================================================
 * SD card engine (findings/sdcard-engine Task 9): the card model's Task 4
 * knobs, time, the SD peripheral, its Gayle bridge, the interrupt
 * controller.  Everything here is back to power-on after mock_reset().
 * ===================================================================== */

/* ---- the card model, sd_spi_model.v's Task 4 behaviour ----
 * CMD59 (arg bit 0: CRC checking on; CMD0 turns it off): a command whose
 * CRC7 is wrong gets R1 08 (| 01 idle) and is not executed; a written block
 * whose CRC16 is wrong gets data response 0B and is not written.  CMD13: R2
 * (R1, 00).  CMD25 + stop token (FD); after a 0B / 0D every further block of
 * the CMD25 gets the same response and is not written.  ACMD22: R1, token,
 * 4 bytes big-endian (blocks written with 05 by the last CMD25), CRC16.
 * Data responses: 05 + busy, 0B (no busy), 0D + busy.
 * Read blocks (CMD17/18/9, ACMD22) carry their real CRC16 when the command
 * came through the SD peripheral; through cfide's SPI() (the old card path,
 * whose goldens hold it, gold/dmode.txt) they carry the old mock's 00 00.
 * Busy and token-delay bytes are runs, so knobs of a million bytes are cheap
 * (mock_sdc_bytes_for_us() converts a time at the current SCK). */
enum mock_card_err_kind {
	MOCK_ERR_RDCRC,   /* the n-th CMD17/18 block: bit 0 of its last data byte flipped as it leaves the card */
	MOCK_ERR_WRREJ,   /* the n-th written block (CMD24/25): 0B, not written */
	MOCK_ERR_WRFAIL,  /* the n-th written block: 0D, not written (WRREJ on the same block wins) */
	MOCK_ERR_NORESP,  /* the n-th command (every 6-byte frame, CMD0 too): no response, no effect */
	MOCK_ERR_CMDCRC,  /* the n-th command: R1 08 (09 idle), not executed (NORESP wins) */
	MOCK_ERR_KINDS
};
/* +SD_ERR_<kind>=n, +SD_ERR_<kind>_CNT=cnt (0 counts as 1): events count
   from 1 at mock_reset(); the n-th and the cnt-1 after it fail.  n 0: off */
void mock_card_error(enum mock_card_err_kind kind, unsigned n, unsigned cnt);
/* a zeroed card of `sectors` (instead of mock_card_load), and a sector to
   write the test's data into */
int mock_card_new(unsigned sectors);
unsigned char *mock_card_wsector(unsigned lba);
/* remove_card(): MISO 1, nothing received is acted on, nothing written,
   until mock_card_insert() (a power-on card: idle, CRC off; same memory).
   The card-detect pin is mock_sdc_cd(); mock_sdc_pull_card() does both. */
void mock_card_remove(void);
void mock_card_insert(void);
int mock_card_crc_on(void);         /* CMD59 state */
unsigned mock_card_wr_ok(void);     /* what ACMD22 would answer now */

/* ---- time ----
 * One clock: clk_114 cycles since mock_reset().  The TIMER register moves
 * with it (MOCK_CYC_PER_TIMER cycles a count: 256 ticks of 44.1 kHz), and
 * every TIMER advance (mock_timer_step per read, hosttest_advance,
 * mock_timer_spi_rate) is time for the peripheral too.  Each register
 * access of the SD peripheral takes mock_sdc_access_cycles() (16: cfide's
 * clk_28 handshake).  The peripheral runs in that time, byte by byte.
 * So with the default TIMER step (1 count a read) every TIMER read lets
 * 5.8 ms pass: 13.7 KB at div 2, 290 bytes at div 141.  Code that reads the
 * TIMER while an op runs sees it end there; sdc.c's trace therefore takes
 * its timestamp with hosttest_timer_peek() (the value, no time, not
 * counted in mock_timer_reads()).  Between register accesses without a
 * TIMER read an op runs at its real speed, and tests that need exact
 * timing set mock_timer_step(0) and move time with mock_run /
 * mock_sdc_step. */
#define MOCK_CLK_HZ        113460000u
#define MOCK_CYC_PER_TIMER 658629u
unsigned long long mock_now(void);
void mock_run(unsigned long long cycles);   /* time passes; interrupts delivered after each event */

/* ---- the SD peripheral (rtl/host/sdcard_spi.v, its header is the contract) ----
 * Registers through sdc.h's SDC_R / SDC_W (hosttest_sdc_rd / _wr).  Modelled
 * at byte level: ops 1-9 and 15, TX keep / commit / rewind, the interlock
 * (verified bytes at the RX head, poisoned), refusals, STATUS 1-8, IRQPEND /
 * IRQEN / IRQACK with the level-sticky watermark bits, COUNT, LAST, TIMEOUT,
 * SCK = clk_114 / (2 (div + 1)) (a byte is 16 (div + 1) cycles, gapless),
 * pauses (TX empty for a TX op, RX full for an RX op), card gone (at once,
 * mid-byte), card detect (2^20-cycle debounce, IRQ bit 4).  Not modelled:
 * the cycle-level prefetch timing (strobes >= 4 cycles apart: never seen),
 * the one cycle after an op end (mock_sdc_refuse_next() instead). */
/* run until the CPU's interrupt line rises, the peripheral has nothing more
   to do, or one TIMER count has passed; interrupts delivered.  0: nothing
   can happen (idle, or paused / held with no event coming) */
int mock_sdc_step(void);
void mock_sdc_access_cycles(unsigned n);
unsigned mock_sdc_byte_cycles(void);                    /* 16 (div + 1) */
unsigned long mock_sdc_bytes_for_us(unsigned long us);  /* bytes in us at the current SCK */
void mock_sdc_cd(int present);      /* card-detect pin (default present) */
void mock_sdc_pull_card(void);      /* mock_sdc_cd(0) + mock_card_remove() */
void mock_sdc_refuse_next(void);    /* the next CMD meets the cycle after an op end: refused */
/* sdc_wait under HOSTTEST: when nothing can happen, fn(ctx) is called
   first (the test may release a Gayle op, feed it, ...: return 1 when it
   did something); then the test fails (fatal, the default) or, with
   mock_sdc_stall_fatal(0), one TIMER count passes */
void mock_sdc_on_stall(int (*fn)(void *ctx), void *ctx);
void mock_sdc_stall_fatal(int on);
/* FIFO misuse (STATUS 8: a push into a full TX, a pop past RXLVL, the data
   port during a Gayle op) is a firmware bug: it ends the test (default),
   or with mock_sdc_misuse_fatal(0) the peripheral does what the RTL does */
void mock_sdc_misuse_fatal(int on);
struct mock_sdc_peek {
	unsigned busy, op, cmd, len, rxlvl, txlvl, txunsent, verified, poisoned,
	         cs, div, status, irqpend, irqen, count, last, timeout;
	int line;                       /* irq = |(IRQPEND & IRQEN) */
	unsigned long long bytes;       /* bytes shifted since mock_reset() */
};
void mock_sdc_peek(struct mock_sdc_peek *p);    /* no side effect, no time */
/* one line per CMD write and per op end:
     "CMD 0031 LEN 6"  "CMD 0031 LEN 6 refused"  "ABORT"
     "END XFER normal COUNT 6 STATUS 0008"   (normal abort timeout gone gerr) */
const char *mock_sdc_log(void);
/* the bytes on the wire (off by default): one frame per CS level,
   "sd <out> / <in>" with CS asserted, "sd- ..." without */
void mock_sdc_wire_on(int on);
const char *mock_sdc_wire(void);

/* ---- the Gayle bridge behind ops 4 and 5 (not Gayle's FIFO itself) ----
 * RX_TO_GAYLE appends the words it moves to into[port]; GAYLE_TO_TX takes
 * them from from[port] (the "Amiga's" sector), and waits there while it
 * holds fewer than a word (Amiga pace).  A word every mock_gayle_word_cycles
 * (12), g_ack one word time after the last.  mock_gayle_end() arms the next
 * Gayle op to end after `words` words with g_err or a short g_ack (both
 * STATUS 7 + IRQ 3; GAYLE_TO_TX rolls TX back).  mock_gayle_hold(1): no
 * word moves until mock_gayle_hold(0).  A frame on cs 0x10 (EnableFpga, an
 * IDE command over scs(4)) opened while a Gayle op runs is counted. */
enum { MOCK_GAYLE_OK, MOCK_GAYLE_ERR, MOCK_GAYLE_SHORT };
void mock_gayle_from(unsigned port, const unsigned char *b, size_t n);
const unsigned char *mock_gayle_into(unsigned port, size_t *n);
void mock_gayle_end(int how, unsigned words);
void mock_gayle_hold(int on);
void mock_gayle_word_cycles(unsigned n);
unsigned mock_gayle_cs_violations(void);

/* ---- the interrupt controller (arch/irq.h under HOSTTEST) ----
 * cfide's controller (PENDING read clears the EDGE bits it returns; MASK,
 * MODE; RAW) and the CPU: MIE (crt0 sets it: on after mock_reset()),
 * irq_save / irq_restore, the trap.  Sources: bit 4 is the SD peripheral's
 * irq; others come from the test.  An interrupt is taken (the real
 * _InterruptVector, arch/irq.c's dispatcher, called until the line drops)
 * at every mock call that can change the line while MIE is on and no
 * handler runs: register accesses of the SD peripheral, TIMER reads,
 * irq_restore, mock_run / mock_sdc_step, the calls below.  10000 traps in a
 * row: the test fails (a source nobody clears). */
void mock_irq_pulse(unsigned bit);          /* an EDGE event (vblank 0, Akiko 2) */
void mock_irq_level(unsigned bit, int v);   /* a test-driven source line */
void mock_irq_deliver(void);
unsigned mock_irq_mask(void);
unsigned mock_irq_mode(void);
unsigned mock_irq_traps(void);              /* traps taken since mock_reset() */
int mock_irq_mie(void);
unsigned mock_interrupt_reg(void);          /* the legacy INTERRUPT register (0xFFFFFFA0) */
/* a LEVEL bit is reported once more by the PENDING read after its line
   dropped (cfide's synchroniser): handlers must tolerate the call */
void mock_irq_stale_level(int on);

#endif

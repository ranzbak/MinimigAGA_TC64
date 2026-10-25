/* sdc: driver of the SD card SPI peripheral (rtl/host/sdcard_spi.v; its
 * header comment is the hardware contract, findings/sdcard-engine design.md
 * sections 4 and 11).  The peripheral moves bytes; the SD protocol runs on
 * top of this driver (Task 10).
 *
 * Registers: 16 bit, at 0xFFFFFF00 + offset.  Driver code reaches them
 * through SDC_R(x) / SDC_W(x, v), never SDC(x) directly: under -DHOSTTEST
 * those two go to the mock peripheral (fw/ctrl/test/mock_hw.c), and SDC(x)
 * does not compile there.
 *
 * Interrupt: IRQ_SDCARD (4) on cfide's controller, LEVEL (the peripheral's
 * irq is |(IRQPEND & IRQEN), registered).  The handler (sdc.c) reads
 * IRQPEND & IRQEN, acknowledges exactly those bits (IRQACK) and ORs them
 * into sdc_events; the consumer clears them (sdc_clear / sdc_take).  The
 * watermark bits (1 RX high, 2 TX low) are level-sticky in the peripheral:
 * the handler takes them out of IRQEN when it sees them (one shot), so a
 * level that holds cannot re-enter the handler; sdc_arm() enables them
 * again.  sdc_init() enables bits 0 (done), 3 (error) and 4 (card detect
 * change) only.
 *
 * Event trace for the debugger: sdc_trace[] is a ring of the last
 * SDC_TRACE_N peripheral events, sdc_trace_head the number of entries ever
 * written (the newest is sdc_trace[(sdc_trace_head - 1) % SDC_TRACE_N], the
 * oldest still there sdc_trace[sdc_trace_head % SDC_TRACE_N] once the ring
 * has wrapped).  Every entry names its op in what's low 12 bits (the CMD
 * word: op in 3:0, bits 4-8), so an event is readable after its start entry
 * wrapped out; the kind is in bits 15:12.  One entry per sdc_start() (what =
 * SDC_TR_START | CMD, or SDC_TR_REFUSED | CMD, or SDC_TR_BUSY | CMD when the
 * driver did not write it; len = LEN; status = STATUS before the CMD write,
 * so a FIFO misuse (bit 8) since the last op shows there; irqpend 0) and one
 * per handler call that sees bit 0, 3 or 4 (what = SDC_TR_EVENT | CMD of the
 * last accepted op, or of an ABORT given while idle; len = COUNT; status =
 * STATUS; irqpend = IRQPEND as read).  time = TIMER (5.804 ms counts).
 * sdc_misuse counts the starts that found STATUS 8 set (always a firmware
 * bug: a push into a full TX, a pop past RXLVL, the data port during a
 * Gayle op).  With the board's GDB tunnel (HOSTCPU_RVDEBUG, tools/rvdebug):
 *     (gdb) p sdc_trace_head
 *     (gdb) p/x sdc_trace
 *     (gdb) p sdc_misuse
 * No printf: it costs a few register reads per event.
 */
#ifndef SDC_H
#define SDC_H

#define SDC_BASE    0xFFFFFF00
#define SDC(x)      (*(volatile unsigned short *)(SDC_BASE + (x)))

/* register offsets (write / read) */
#define SDC_TXW     0x00    /* W: push 2 bytes, 15:8 first */
#define SDC_RXW     0x00    /* R: pop 2 bytes, the first in 15:8 */
#define SDC_TXB     0x04    /* W: push 1 byte (7:0) */
#define SDC_RXB     0x04    /* R: pop 1 byte (7:0) */
#define SDC_RXLVL   0x08    /* R: bytes in RX (10:0) */
#define SDC_TXLVL   0x0C    /* R: bytes in TX, kept ones included (10:0) */
#define SDC_CMD     0x10    /* W: start an op */
#define SDC_STATUS  0x10    /* R */
#define SDC_LEN     0x14    /* W: byte count (10:0); ignored while busy */
#define SDC_LAST    0x14    /* R: last received byte */
#define SDC_MATCH   0x18    /* W: byte for the wait ops; ignored while busy */
#define SDC_COUNT   0x18    /* R: bytes moved by the last op (10:0) */
#define SDC_IRQACK  0x1C    /* W: 1 clears */
#define SDC_IRQPEND 0x1C    /* R */
#define SDC_CFG     0x20    /* R/W: 7:0 divider, 8 CS asserted; refused while busy */
#define SDC_TIMEOUT 0x24    /* R/W: wait-op bound, units of 16384 clk_114 (144.4 us), 0 = 1 unit */
#define SDC_IRQEN   0x28    /* R/W */
#define SDC_WMARK   0x2C    /* W: 15:8 RX high, 7:0 TX low, units of 16 bytes */
#define SDC_VER     0x2C    /* R: VERSION */

/* The VERSION register of this contract: the boot ROM boots only a firmware
   file whose trailer names it (lock-step, design 5.5).  Rule: bump it on any
   change of this header's contract or the Gayle bridge's (sdcard_spi.v,
   sdcard_gayle.v: registers, ops, flags the firmware relies on), on both
   sides at once -- rtl/host/sdcard_spi.v's VERSION parameter
   (fw/ctrl/Makefile check (j) compares the two).  0x5D02: the bridge's
   IDEF_CMD_WR (final review M2). */
#define SDC_VERSION 0x5D02

/* CMD 3:0: ops */
#define SDC_OP_XFER         1
#define SDC_OP_WAIT_EQ      2   /* clock $FF until the byte == MATCH (LAST) */
#define SDC_OP_WAIT_NE      3   /* ... != MATCH */
#define SDC_OP_GAYLE_TO_TX  4   /* LEN bytes from the Gayle bridge into TX */
#define SDC_OP_RX_TO_GAYLE  5   /* LEN verified bytes from RX to the bridge */
#define SDC_OP_TX_REWIND    6   /* send again from the commit point */
#define SDC_OP_TX_COMMIT    7   /* free the bytes sent so far */
#define SDC_OP_RX_FLUSH     8
#define SDC_OP_TX_FLUSH     9
#define SDC_OP_ABORT        15
/* CMD bits 4-8 */
#define SDC_X_TX     0x010  /* XFER: send from TX (else $FF) */
#define SDC_X_RX     0x020  /* XFER: receive into RX (else discard) */
#define SDC_X_TXCRC  0x040  /* XFER: then 2 bytes, CRC16 of the bytes sent */
#define SDC_X_RXCRC  0x080  /* XFER: then 2 bytes received, checked as CRC16 (STATUS 1) */
#define SDC_G_PORT1  0x100  /* Gayle ops: g_port 1 */

/* STATUS */
#define SDC_ST_BUSY     0x001
#define SDC_ST_CRC_OK   0x002
#define SDC_ST_TIMEOUT  0x004
#define SDC_ST_CARD     0x008   /* card present (debounced) */
#define SDC_ST_ABORTED  0x010
#define SDC_ST_GONE     0x020   /* card gone during the op */
#define SDC_ST_REFUSED  0x040
#define SDC_ST_GERR     0x080   /* Gayle error */
#define SDC_ST_MISUSE   0x100   /* FIFO misuse, sticky until the next accepted CMD */

/* IRQPEND / IRQEN / IRQACK */
#define SDC_IRQ_DONE  0x01
#define SDC_IRQ_RXHI  0x02  /* RX >= high watermark (level-sticky) */
#define SDC_IRQ_TXLO  0x04  /* TX <= low watermark (level-sticky) */
#define SDC_IRQ_ERR   0x08  /* refused CMD/CFG, FIFO misuse, timeout / card gone / Gayle error */
#define SDC_IRQ_CD    0x10  /* card-detect change */
#define SDC_IRQ_ALL   0x1F

/* CFG */
#define SDC_CFG_CS    0x100
#define SDC_CFG_DIV   0x0FF
/* SCK = clk_114 / (2 * (div + 1)), clk_114 = 113.46 MHz */
#define SDC_DIV_INIT  141   /* 399.5 kHz: card initialisation */
#define SDC_DIV_MIN   2     /* 18.9 MHz: the fastest (DAT0 input timing, Task 8) */

#define SDC_FIFO      1024  /* bytes per FIFO */

/* register access: see the top of this file */
#ifndef HOSTTEST
#define SDC_R(x)     SDC(x)
#define SDC_W(x, v)  (SDC(x) = (v))
#define SDC_IDLE()   ((void)0)
#define SDC_TRACE_TIME() TIMER
#else
unsigned short hosttest_sdc_rd(unsigned off);
void hosttest_sdc_wr(unsigned off, unsigned short v);
void hosttest_sdc_idle(void);   /* sdc_wait's loop: the mock steps; aborts the test when nothing can happen */
#undef SDC
#define SDC(x)       SDC_direct_access_use_SDC_R_or_SDC_W
#define SDC_R(x)     hosttest_sdc_rd(x)
#define SDC_W(x, v)  hosttest_sdc_wr((x), (v))
#define SDC_IDLE()   hosttest_sdc_idle()
/* the trace's timestamp must not be a TIMER read on the host: the mock's
   TIMER read advances time (mock_timer_step), and a running op would end
   inside sdc_start */
unsigned short hosttest_timer_peek(void);
#define SDC_TRACE_TIME() hosttest_timer_peek()
#endif

/* events the handler latched (IRQPEND bits); the handler ORs, the consumer
   clears (sdc_clear / sdc_take: inside irq_save) */
extern volatile unsigned sdc_events;
/* starts that found STATUS 8 (FIFO misuse) set: a firmware bug each */
extern volatile unsigned sdc_misuse;

/* handler on IRQ_SDCARD (LEVEL), any op stopped (ABORT), both FIFOs
   flushed, CFG = SDC_DIV_INIT with CS off, IRQPEND cleared, sdc_events 0,
   IRQEN = DONE | ERR | CD, the controller bit enabled.  Idempotent. */
void sdc_init(void);

/* start an op: cmd = op | bits (CMD), len = LEN.  A fresh op: the DONE and
   ERR events of earlier ops are dropped first (IRQACK and sdc_events; read
   sdc_status() before if they matter).  Returns 0 when the peripheral took
   it; -1 when it was busy (checked first: nothing written) or refused it
   (STATUS bit 6 read back after the CMD write: the cycle after an op end,
   XFER bits 6 + 7, a Gayle op's LEN / room / verified check, an unknown
   op); the refusal's own ERR event is acknowledged, STATUS keeps bit 6.
   STATUS bit 8 (FIFO misuse since the last accepted CMD) found set before
   the CMD write is counted in sdc_misuse and kept in the start's trace
   entry; the start goes on (the accepted CMD clears bit 8 in the
   peripheral; refusing would leave no way out but a separate clear).
   SDC_OP_ABORT is never refused (it stops a running op at the next byte
   boundary, STATUS 4; when idle it only gives a DONE event). */
int sdc_start(unsigned cmd, unsigned len);

/* wait for (sdc_events & (mask | ERR | CD)), the bits it returns (not
   cleared).  For boot-time and CPU-side sync wrappers only, never in the
   HDD/CD data path.  This core has no WFI (VexRiscv CsrPluginConfig.small
   decodes it as an illegal instruction), so it polls sdc_events with a
   TIMER bound of SDC_WAIT_BOUND counts, above the longest TIMEOUT
   (65535 x 144.4 us = 9.46 s): when that runs out it ABORTs the op,
   waits for it to stop (the byte being shifted: at most 36 us, bounded by
   2 TIMER counts) and returns 0.  Needs interrupts on (not from a handler, not inside
   irq_save).  Under HOSTTEST it steps the mock and fails the test when the
   mock can make no progress. */
#define SDC_WAIT_BOUND 1800     /* TIMER counts: 10.4 s */
int sdc_wait(unsigned mask);

/* sdc_events: clear bits / take (read and clear) bits, atomically */
void sdc_clear(unsigned mask);
unsigned sdc_take(unsigned mask);
/* IRQEN |= bits (the one-shot watermark bits 1, 2 again; set WMARK first) */
void sdc_arm(unsigned bits);

/* FIFO data: pairs through TXW / RXW, an odd last byte through TXB / RXB.
   The caller keeps to TXLVL / RXLVL (a push into a full TX is dropped, a
   pop past RXLVL reads 00: STATUS 8 + ERR); never during a Gayle op (the
   data port is locked then). */
void sdc_push(const unsigned char *p, unsigned n);
void sdc_pop(unsigned char *p, unsigned n);

/* CFG: SCK divider (clamped to SDC_DIV_MIN..255) and CS (on != 0: asserted,
   sd_cs_n low).  Only while idle: 0, or -1 when busy (nothing written: a
   CFG write while busy would be refused) */
int sdc_set_div(unsigned div);
int sdc_select(int on);

unsigned sdc_status(void);      /* STATUS */

/* the event trace (see the top of this file) */
#define SDC_TRACE_N     32      /* a power of two */
#define SDC_TR_START    0x1000  /* | CMD: accepted */
#define SDC_TR_REFUSED  0x2000  /* | CMD: written, refused */
#define SDC_TR_BUSY     0x3000  /* | CMD: not written, busy */
#define SDC_TR_EVENT    0x4000  /* | CMD of the op: the handler saw DONE / ERR / CD */
#define SDC_TR_KIND     0xF000
struct sdc_trace_ent {
	unsigned short time;
	unsigned short what;
	unsigned short len;
	unsigned short status;
	unsigned short irqpend;
};
extern struct sdc_trace_ent sdc_trace[SDC_TRACE_N];
extern volatile unsigned sdc_trace_head;

#endif

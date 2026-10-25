/* cdpath_test: the CD-ROM data path on the SD card peripheral
 * (findings/sdcard-engine Task 11b).
 *   cdpath_test <dir> <golden of cd_read_order (gold/cd_read10.txt)>
 * <dir> holds gold/cdcard.py's files and cdcard.sh's cd.img: a 32 MB card
 * (FAT16, 4 KB clusters) with TEST.ISO (300 CD sectors; its chain has a gap
 * after the file's 24th 512-byte sector), DISC.CUE (TEST.ISO + TRACK2.WAV)
 * and the WAV.
 *
 * The real cdrom.c (with atapi.c, cue.c, cdaudio.c) and hdd.c run over the
 * real fat.c, mmc.c, sdproto.c and sdc.c on the mock SD peripheral and card
 * (mock_hw.c, mock_sdc.c), driven by the main loop's disk pass (PollDisks
 * and HandleFpga, cut out of main.c) and a mock two-port Gayle on the FPGA
 * chip select (gayle_miso below):
 *   port 2 (firmware port 1): the CD drive in packet mode, as cdrom_test's
 *     model of gayle_port.v but at the SPI level; an ATAPI host that sends
 *     the command packet, reads each data-in block once all of it is in the
 *     FIFO (the CPU's CMD_IDE_DATA_WR bytes and the mock bridge's
 *     RX_TO_GAYLE words, in the order they arrived) and checks every phase
 *     (interrupt reason, byte count = block <= limit, the interrupt);
 *   port 1 (firmware port 0): an ATA disk (unit 0 = the whole card,
 *     HDF_CARD) and an Amiga that reads a READ SECTORS sector by sector:
 *     the second command of the one-command-at-a-time cases (ruling T11-R4).
 * The firmware port latch (paula_floppy.v hdd_port_r) follows bit 0 of
 * every HDD command word; hdd_cmd_req / hdd_dat_req (the status byte of
 * every frame) as gayle.v builds them from the latched port.  A command
 * word of one port while the other port's command is in progress (serving
 * up, busy) is a model error: the firmware serves one IDE command at a
 * time.  The Amiga-visible events of port 2 go to the log (gold/
 * cd_read10.txt: cd_read_order, recorded on the synchronous CD path before
 * Task 11b with CD_GOLD_WRITE=1).  The test reports with fprintf(stdout);
 * the firmware's printf (rvlibc.c) goes to the mock UART. */
#include <ctype.h>
#include <limits.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "errors.h"
#include "hardware.h"
#include "mmc.h"
#include "fat.h"
#include "hdd.h"
#include "cdrom.h"
#include "config.h"
#include "fpga.h"
#include "menu.h"
#include "drivesounds.h"
#include "diskstat.h"
#include "fdd.h"
#include "sdproto.h"
#include "mock_hw.h"
#include "sdc.h"
#include "atapi.h"
#include "cue.h"
#include "cdaudio.h"

#define ISO_SECTORS 300		/* gold/cdcard.py */
#define WAV_SECTORS 400

/* ---- what the firmware needs from the rest of it ---- */
configTYPE config;
char DebugMode;
static void die(const char *what);

hardfileTYPE *SlotConfig(int slot)
{
	return (slot & 2) ? &config.secondaryhardfile[slot & 1] : &config.hardfile[slot & 1];
}
void DebugMessage(char *message) { (void)message; }
void drivesounds_queueevent(enum DriveSound_Type type) { (void)type; }

/* the CD audio hardware of cdrom.c (HOSTTEST: the test's) on the mock's
   clock: 256 frames a TIMER count, the ring's half from the time since
   CDA_ENA (hdd_test's model) */
static unsigned cd_ena_timer;
static int cd_ena;
static uint8_t cd_ring[2 * CDA_HALF_BYTES];
uint32_t cda_port_timer(void) { return hosttest_timer_peek(); }
uint32_t cda_port_audio(void)
{
	unsigned units = (unsigned short)(hosttest_timer_peek() - cd_ena_timer);
	return cd_ena ? (units / CDA_HALF_UNITS) & 1 : 0;
}
void cda_port_control(uint32_t v)
{
	if (v & CDA_ENA) { cd_ena = 1; cd_ena_timer = hosttest_timer_peek(); }
	else cd_ena = 0;
}
uint8_t *cda_port_ring(void) { return cd_ring; }
void cda_port_claim(void) { }

/* fpga.c's, as it is */
unsigned char GetFPGAStatus(void)
{
	unsigned char status;
	EnableFpga();
	status = SPI(0);
	SPI(0);
	SPI(0);
	SPI(0);
	SPI(0);
	SPI(0);
	DisableFpga();
	return status;
}

/* main.c's HandleFpga and PollDisks (cut out by the Makefile); the floppy
   side a stub that sends one floppy frame (UpdateDriveStatus) and, with
   fdd_card, reads the card as the floppy does (MMC_Read: an sd_sync user) */
static int fdd_calls, fdd_card;
/* floppy work while the Amiga may be held inside a data-in block (Task 11b
   fix round 1; amiga_in_block, the model's view), the passes PollDisks ran
   the disks only */
static int fdd_in_block;
static long in_block_passes;
static int amiga_in_block(void);
static unsigned fdd_reads;
void HandleFDD(unsigned char c1, unsigned char c2, unsigned char c3, unsigned char c4)
{
	static unsigned char b[512];
	(void)c1; (void)c2; (void)c3; (void)c4;
	fdd_calls++;
	if (amiga_in_block())
		fdd_in_block++;
	if (fdd_card) {
		if (!MMC_Read(40 + fdd_reads % 8, b)) die("the floppy's card read failed");
		fdd_reads++;
		/* its sd_sync finished whatever op ran: that must not have left a
		   block part-delivered behind the rest of the floppy's work */
		if (amiga_in_block())
			fdd_in_block++;
	}
}
void UpdateDriveStatus(void)
{
	EnableFpga();
	SPI(0x10);
	SPI(0x00);
	DisableFpga();
}
#include "handlefpga.inc"

/* ---- reporting ---- */
static int fails, cases;
static const char *cur_case = "";

static void say(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stdout, fmt, ap);
	va_end(ap);
	fflush(stdout);
}

static int check(const char *what, long got, long want)
{
	cases++;
	if (got != want) {
		say("FAIL %s: got %ld, want %ld\n", what, got, want);
		fails++;
		return 0;
	}
	return 1;
}

static void die(const char *what)
{
	say("FAIL %s%s%s\n", cur_case, *cur_case ? ": " : "", what);
	exit(1);
}

/* ---- the ISO's bytes (gold/cdcard.py iso_byte) ---- */
static uint8_t iso_byte(unsigned long p)
{
	unsigned long s = p >> 9, i = p & 511;
	if (i < 4)
		return (uint8_t)(s >> (24 - 8 * i));
	return (uint8_t)(s * 31 + i * 7 + (i >> 8) * 101 + 0x55);
}

/* ---- the mock Gayle: two ports (gayle.v, gayle_port.v) ------------------ */
#define FIFO_BYTES 8192		/* gayle_fifo.v: 4096 words */
static struct port {
	uint8_t reg[8];		/* the task file: the host's, the firmware's writes while busy */
	int busy;		/* gayle_port.v busy: a command, until END (or the last ATA sector read) */
	int serving;		/* the firmware has written to the busy port: its command is in progress */
	int pio_in, pio_out, pkt, xfer_done, block_mark, irq, rst_seen, dev_wr;
	unsigned xfer_words;
	uint8_t fifo[FIFO_BYTES + 2];
	unsigned flen, frd;	/* bytes in the FIFO since its reset, bytes read out */
	size_t gay_seen;	/* mock_gayle_into() bytes already in the FIFO */
	int end_seen;
	uint8_t end_status;
	unsigned count, drained;	/* port 1 (ATA): the READ SECTORS' sectors, those the Amiga read */
	long lba;
} P[2];
static int latch;		/* the firmware port latch */
static char model_err[200];
static struct { char *p; size_t n, cap; } glog_buf;
static long passes;

static void gayle_err(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void gayle_err(const char *fmt, ...)
{
	va_list ap;
	if (model_err[0]) return;
	va_start(ap, fmt);
	vsnprintf(model_err, sizeof model_err, fmt, ap);
	va_end(ap);
}

static void glog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void glog(const char *fmt, ...)
{
	char line[96];
	va_list ap;
	int n;
	va_start(ap, fmt);
	n = vsnprintf(line, sizeof line, fmt, ap);
	va_end(ap);
	if (n < 0) return;
	if (glog_buf.n + (size_t)n + 2 > glog_buf.cap) {
		glog_buf.cap = (glog_buf.cap + (size_t)n + 2) * 2;
		glog_buf.p = realloc(glog_buf.p, glog_buf.cap);
		if (!glog_buf.p) die("out of memory");
	}
	memcpy(glog_buf.p + glog_buf.n, line, (size_t)n);
	glog_buf.n += (size_t)n;
	glog_buf.p[glog_buf.n++] = '\n';
	glog_buf.p[glog_buf.n] = 0;
}
static void glog_clear(void) { glog_buf.n = 0; if (glog_buf.p) glog_buf.p[0] = 0; }
static const char *glog_text(void) { return glog_buf.p ? glog_buf.p : ""; }

static void fifo_reset(int p)
{
	size_t n;
	mock_gayle_into((unsigned)p, &n);
	P[p].flen = P[p].frd = 0;
	P[p].gay_seen = n;	/* what the bridge moved before the reset is gone */
}

static void fifo_put(int p, uint8_t b)
{
	if (P[p].flen >= FIFO_BYTES) { gayle_err("port %d: FIFO overflow", p + 1); return; }
	P[p].fifo[P[p].flen++] = b;
}

/* the words the mock bridge's RX_TO_GAYLE moved since the last look */
static void sync_bridge(int p)
{
	size_t n;
	const uint8_t *b = mock_gayle_into((unsigned)p, &n);
	if (P[p].gay_seen < n && !P[p].pio_in)
		gayle_err("port %d: card data into the FIFO outside a data-in phase", p + 1);
	while (P[p].gay_seen < n)
		fifo_put(p, b[P[p].gay_seen++]);
}

static int drq(int p)
{
	struct port *q = &P[p];
	unsigned avail = q->flen - q->frd;
	if (q->pkt)
		return q->pio_in ? ((avail >= 512 || q->flen >= q->xfer_words * 2) && avail > 0) : (q->pio_out && !q->xfer_done);
	return q->pio_in && avail >= 512;
}
static int bsy(int p) { return P[p].busy && !drq(p); }

/* the Amiga may be reading inside a port-2 data-in block that is still
   being filled, held by nrdy on the empty FIFO: DRQ is up (256 words in)
   and the block is not all in (port 1 serves one-sector groups here) */
static int amiga_in_block(void)
{
	struct port *q = &P[1];
	unsigned want = q->xfer_words * 2;
	sync_bridge(1);
	return q->busy && q->pkt && q->pio_in && !q->xfer_done && want > 512 && q->flen >= 512 && q->flen < want;
}

static unsigned char flags_of(int p)
{
	struct port *q = &P[p];
	return (unsigned char)((p ? IDEF_PORT : 0) | (q->xfer_done ? IDEF_XFER_DONE : 0) | (q->dev_wr ? IDEF_DEV_WR : 0) |
	                       (q->rst_seen ? IDEF_RST_SEEN : 0) | (q->pkt ? IDEF_PKT : 0) | (bsy(0) ? IDEF_BSY0 : 0) |
	                       (bsy(1) ? IDEF_BSY1 : 0));
}

/* hdd_cmd_req / hdd_dat_req of the latched port (gayle.v) */
static unsigned char status_byte(void)
{
	int cmd = latch ? (bsy(1) || (bsy(0) && !P[1].busy)) : (bsy(0) || (bsy(1) && !P[0].busy));
	int dat = P[latch].pkt ? (P[latch].pio_out && P[latch].xfer_done) : 0;
	return (unsigned char)((cmd ? CMD_IDECMD : 0) | (dat ? CMD_IDEDAT : 0));
}

/* ---- the ATAPI host on port 2 ---- */
static struct {
	uint8_t cdb[12];
	int cdb_sent;
	uint8_t out[512];
	unsigned out_len;
	uint8_t in[ISO_SECTORS * 2048 + 4096];
	size_t in_len;
	unsigned limit;
	int blocks;
	unsigned block_bytes[1024];
	int phase_errors;
	unsigned long polls;
	/* what the Amiga does once it has read this many data-in blocks (-1: never) */
	int dead_at;		/* stops answering: a crashed driver */
	int reset_at;		/* Ctrl-Amiga-Amiga */
	int newcmd_at;		/* writes a new PACKET command (TEST UNIT READY) over this one */
	int hdd_at;		/* writes a READ SECTORS on port 1 (hdd_lba, hdd_count) */
	int gap_reset_at;	/* Ctrl-Amiga-Amiga in the next frame after the firmware saw XFER_DONE */
	int gap_armed;
	int slow, wait;		/* a slow host: it reads a block only at its slow-th look after the block is in */
	long hdd_lba;
	unsigned hdd_count;
} h;
/* the ATA Amiga on port 1: the sectors it read */
static uint8_t in0[64 * 512];
static unsigned in0_n;

static void host_reset(void)
{
	memset(&h, 0, offsetof(typeof(h), in));
	h.in_len = 0;
	h.limit = 0;
	h.blocks = 0;
	h.phase_errors = 0;
	h.polls = 0;
	h.dead_at = h.reset_at = h.newcmd_at = h.hdd_at = h.gap_reset_at = -1;
	h.gap_armed = 0;
	h.slow = h.wait = 0;
}

/* Ctrl-Amiga-Amiga: Gayle's reset (both ports: busy, packet mode, the FIFOs,
   rst_seen; the bridge's cmd_since) */
static void amiga_reset(void)
{
	glog("reset");
	for (int p = 0; p < 2; p++) {
		sync_bridge(p);
		P[p].busy = P[p].serving = P[p].pio_in = P[p].pio_out = P[p].pkt = P[p].xfer_done = 0;
		P[p].rst_seen = 1;
		fifo_reset(p);
		mock_gayle_abandon((unsigned)p);
	}
}

/* the host writes a command on port 2: busy, packet mode off, the FIFO reset
   (cmd_since until the pickup) */
static void amiga_command1(const unsigned char *t)
{
	struct port *q = &P[1];
	sync_bridge(1);
	memcpy(q->reg, t, 8);
	q->busy = 1;
	q->serving = 0;
	q->pkt = 0;
	q->xfer_done = 0;
	q->end_seen = 0;
	q->irq = 0;	/* the host took the last command's interrupt */
	fifo_reset(1);
	mock_gayle_abandon(1);
	glog("1 cmd %02x", t[7]);
}

/* a PACKET command (limit = the byte count registers), the CDB the host
   sends when asked */
static void packet_cmd(const uint8_t *cdb, unsigned limit)
{
	unsigned char t[8] = { 0, 0, 0, 0, (unsigned char)limit, (unsigned char)(limit >> 8), 0xA0, 0xA0 };
	memcpy(h.cdb, cdb, 12);
	h.cdb_sent = 0;
	h.limit = (limit == 0 || limit == 0xFFFF) ? 0xFFFE : (limit & ~1u);
	amiga_command1(t);
}

/* READ SECTORS on port 1, unit 0 (the card: HDF_CARD, 16 heads, 63 sectors) */
static void amiga_command0(long lba, unsigned count)
{
	struct port *q = &P[0];
	unsigned s = (unsigned)(lba % 63) + 1, hd = (unsigned)(lba / 63 % 16), c = (unsigned)(lba / 63 / 16);
	unsigned char t[8] = { 0, 0, (unsigned char)count, (unsigned char)s, (unsigned char)c, (unsigned char)(c >> 8),
	                       (unsigned char)(0xA0 | hd), ACMD_READ_SECTORS };
	sync_bridge(0);
	memcpy(q->reg, t, 8);
	q->busy = 1;
	q->serving = 0;
	q->pio_in = q->pio_out = 0;
	q->count = count;
	q->drained = 0;
	q->lba = lba;
	fifo_reset(0);
	mock_gayle_abandon(0);
	in0_n = 0;
	glog("0 cmd 20");
}

/* the Amiga on port 1 reads a sector once it is in the FIFO (at a status poll) */
static void amiga0_poll(void)
{
	struct port *q = &P[0];
	sync_bridge(0);
	if (!q->busy || !q->pio_in)
		return;
	if (q->flen - q->frd > 512)
		gayle_err("port 1: more than one sector in the FIFO: a refill before the drain");
	if (q->flen - q->frd < 512)
		return;
	if (in0_n < sizeof in0 / 512)
		memcpy(in0 + (size_t)in0_n++ * 512, q->fifo + q->frd, 512);
	q->frd += 512;
	glog("0 rd 1");
	if (++q->drained >= q->count) { q->busy = 0; q->pio_in = 0; q->serving = 0; }
}

/* the host's view of a DRQ for the phase the firmware set up on port 2 */
static void host1_act(void)
{
	struct port *q = &P[1];
	unsigned want = q->xfer_words * 2, bc = q->reg[4] | q->reg[5] << 8;
	sync_bridge(1);
	if (++h.polls > 400000) die("the firmware still polls the CD port: a hang");
	if (h.blocks == h.reset_at) { h.reset_at = -1; amiga_reset(); return; }
	if (h.blocks == h.newcmd_at) {
		static const uint8_t tur[12] = { 0 };
		h.newcmd_at = -1;
		packet_cmd(tur, 0xFFFE);
		return;
	}
	if (h.blocks == h.hdd_at) { h.hdd_at = -1; amiga_command0(h.hdd_lba, h.hdd_count); }
	if (h.blocks == h.dead_at || !q->busy || !q->pkt || q->xfer_done)
		return;
	if (q->pio_out && !h.cdb_sent) {
		if (q->reg[2] != 0x01 || q->xfer_words != 6 || q->irq) {
			h.phase_errors++;
			say("  packet phase: reason %02X words %u irq %d\n", q->reg[2], q->xfer_words, q->irq);
		}
		memcpy(q->fifo, h.cdb, 12);
		q->flen = 12;
		q->frd = 0;
		h.cdb_sent = 1;
		q->xfer_done = 1;
		glog("1 pkt");
	} else if (q->pio_out) {
		if (q->reg[2] != 0x00 || bc != want || !q->irq || bc > h.limit) {
			h.phase_errors++;
			say("  data-out phase: reason %02X bc %u words %u irq %d\n", q->reg[2], bc, q->xfer_words, q->irq);
		}
		q->irq = 0;
		memcpy(q->fifo, h.out, want < sizeof h.out ? want : sizeof h.out);
		q->flen = want;
		q->frd = 0;
		q->xfer_done = 1;
		glog("1 out %u", want);
	} else if (q->pio_in && q->flen >= want && want) {
		if (h.slow && ++h.wait < h.slow)
			return;
		h.wait = 0;
		if (q->block_mark) { q->irq = 1; q->block_mark = 0; }	/* the interrupt with the DRQ edge */
		if (q->reg[2] != 0x02 || (bc + 1) / 2 != q->xfer_words || !q->irq || bc > h.limit) {
			h.phase_errors++;
			say("  data-in phase: reason %02X bc %u words %u irq %d limit %u\n", q->reg[2], bc, q->xfer_words, q->irq, h.limit);
		}
		if (q->flen > want)
			gayle_err("port 2: %u bytes in the FIFO for a %u-byte block", q->flen, want);
		q->irq = 0;
		if (h.in_len + bc <= sizeof h.in) {
			memcpy(h.in + h.in_len, q->fifo, bc);
			h.in_len += bc;
		}
		q->frd = q->flen;
		q->pio_in = 0;
		q->xfer_done = 1;
		h.block_bytes[h.blocks++ & 1023] = bc;
		glog("1 in %u", bc);
	}
}

/* a Gayle error the test armed (mock_gayle_end, gerr_newcmd): the Amiga's
   new command (TEST UNIT READY) reset the FIFO during the op; the errors
   of the model's own abandons (a reset, a command write) are not that */
static unsigned gerrs_seen;
static int gerr_newcmd;
static void look_gerr(void)
{
	if (mock_gayle_errs() == gerrs_seen)
		return;
	gerrs_seen = mock_gayle_errs();
	if (gerr_newcmd) {
		static const uint8_t tur[12] = { 0 };
		gerr_newcmd = 0;
		packet_cmd(tur, 0xFFFE);
	}
}

static int is_hdd_word(unsigned char out)
{
	return (out & 0xC0) == 0x80 || (out & 0xF0) == 0xC0 || (out & 0xF0) == 0xF0;
}

static int frame_no = -1;
static unsigned fpos;
static unsigned char fcmd, fb[24], snap;
static unsigned char gayle_miso(void *ctx, unsigned char out)
{
	(void)ctx;
	int f = mock_frames();
	if (f != frame_no) { frame_no = f; fpos = 0; }
	unsigned k = fpos++;
	int p = fcmd & 1;
	if (k == 0) {
		if (h.gap_armed) { h.gap_armed = 0; amiga_reset(); }
		sync_bridge(0);
		sync_bridge(1);
		fcmd = out;
		p = out & 1;
		if (is_hdd_word(out)) {
			if (P[!p].busy && P[!p].serving)
				gayle_err("a port-%d command word %02X inside port %d's command (one IDE command at a time)", p + 1, out, 2 - p);
			latch = p;
			/* a write to the busy port: the firmware serves its command */
			if ((out & 0xF0) != CMD_IDE_REGS_RD && (out & 0xF0) != CMD_IDE_DATA_RD && P[p].busy)
				P[p].serving = 1;
		}
		if ((out & 0xF0) == CMD_IDE_REGS_RD) {
			mock_gayle_seen((unsigned)p);	/* "I have seen this port's command" */
			if (p) host1_act();
			snap = flags_of(p);
			P[p].rst_seen = P[p].dev_wr = 0;
			if (p && (snap & IDEF_XFER_DONE) && h.blocks == h.gap_reset_at) { h.gap_reset_at = -1; h.gap_armed = 1; }
		}
		if (out == 0) {
			amiga0_poll();
			return status_byte();
		}
		return 0;
	}
	if (k < sizeof fb) fb[k] = out;
	switch (fcmd & 0xFE) {
	case CMD_IDE_REGS_RD:
		if (k < 6 || k >= 22) return 0;
		return (k - 6) & 1 ? P[p].reg[(k - 6) / 2] : snap;
	case CMD_IDE_REGS_WR:
		if (k == 19) {
			if (!P[p].busy) gayle_err("port %d: a task file write while not busy (an abandoned command's?)", p + 1);
			P[p].reg[1] = fb[9]; P[p].reg[2] = fb[11]; P[p].reg[3] = fb[13];
			P[p].reg[4] = fb[15]; P[p].reg[5] = fb[17]; P[p].reg[6] = fb[19];
			glog("%d tf %02x %02x %02x %02x %02x %02x", p, fb[9], fb[11], fb[13], fb[15], fb[17], fb[19]);
		}
		return 0;
	case CMD_IDE_STATUS_WR:
		if (k == 1) {
			struct port *q = &P[p];
			glog("%d st %02x", p, out);
			if (!q->busy) { gayle_err("port %d: a status write %02x while not busy (an abandoned command's?)", p + 1, out); return 0; }
			if (out & IDE_STATUS_RDY) { q->pio_in = 1; q->block_mark = 1; }
			if (out & IDE_STATUS_REQ) q->pio_out = 1;
			if (q->pkt && (out & IDE_STATUS_IRQ) && !(out & IDE_STATUS_RDY)) q->irq = 1;
			if (out & IDE_STATUS_END) {
				q->busy = q->serving = q->pio_in = q->pio_out = 0;
				q->end_seen = 1;
				q->end_status = out;
			}
		}
		return 0;
	case CMD_IDE_XFER_WR:
		if (k == 3) {
			struct port *q = &P[p];
			unsigned words = (unsigned)(fb[2] & 0x1F) << 8 | out;
			if (p && words && q->pkt && q->pio_in && !q->xfer_done && q->flen)
				gayle_err("port 2: a new data phase before the host read the last block (a refill before the drain)");
			fifo_reset(p);
			q->pkt = fb[2] >> 7;
			q->xfer_words = words;
			q->xfer_done = 0;
			q->pio_in = q->pio_out = 0;
			glog("%d xfer %u %u", p, words, q->pkt);
		}
		return 0;
	case CMD_IDE_DATA_WR:
		if (k >= 6) {
			if (!P[p].pio_in) gayle_err("port %d: CPU data into the FIFO outside a data-in phase", p + 1);
			fifo_put(p, out);
		}
		return 0;
	case CMD_IDE_DATA_RD:
		if (k < 6) return 0;
		if (P[p].frd >= P[p].flen) { gayle_err("port %d: a FIFO read past its data", p + 1); return 0; }
		return P[p].fifo[P[p].frd++];
	}
	return 0;
}

/* ---- the card ---- */
static const char *dir;

static void cd_slot(const char *name8, int present)
{
	memset(&config.secondaryhardfile[0], 0, sizeof config.secondaryhardfile[0]);
	config.secondaryhardfile[0].enabled = HDF_CDROM;
	memcpy(config.secondaryhardfile[0].name, name8, 8);
	config.secondaryhardfile[0].present = (unsigned char)present;
	config.hdfdir[2] = 0;
}

static void loop_pass(void);
static void run_loop(void);
static void packet(const uint8_t *cdb, unsigned limit);

static void card_up(void)
{
	char path[1024];
	struct stat st;
	static const uint8_t tur[12] = { 0 };
	snprintf(path, sizeof path, "%s/cd.img", dir);
	mock_reset();
	if (stat(path, &st) || st.st_size % 512) die("no card image of whole sectors");
	if (mock_card_load(path, (unsigned)(st.st_size / 512))) die("cannot load the card image");
	mock_script_fn(0x10, gayle_miso, NULL);
	memset(P, 0, sizeof P);
	host_reset();
	frame_no = -1;
	if (MMC_Init() != CARDTYPE_SDHC) die("MMC_Init");
	if (!FindDrive()) die("FindDrive");
	memset(&config, 0, sizeof config);
	/* unit 0 (port 1 master): the whole card, READ SECTORS by CHS */
	memset(&hdf[0], 0, sizeof hdf[0]);
	hdf[0].type = HDF_CARD;
	hdf[0].cylinders = 1000;
	hdf[0].heads = 16;
	hdf[0].sectors = 63;
	cd_slot("TEST    ", CD_PRESENT_ISO);
	if (CD_Open(2) != CD_OK) die("CD_Open(2) of TEST.ISO");
	packet(tur, 0xFFFE);	/* the insert's UNIT ATTENTION */
}

/* ---- the main loop ---- */
static int fw_busy(void) { return hdd_busy() || sd_poll(); }

static void loop_pass(void)
{
	if (PollDisks(1))
		in_block_passes++;
	mock_sdc_step();
	look_gerr();
	host1_act();	/* the Amiga reads a block when it is there, whether the firmware polls or not */
	passes++;
}

static void run_loop(void)
{
	long n = 0;
	do {
		loop_pass();
		if (++n > 2000000) die("the command never ends (a hang)");
	} while (P[0].busy || P[1].busy || fw_busy());
}

static void packet_begin(const uint8_t *cdb, unsigned limit)
{
	int dead = h.dead_at, rst = h.reset_at, nc = h.newcmd_at, hd = h.hdd_at, gap = h.gap_reset_at, slow = h.slow;
	host_reset();
	h.dead_at = dead; h.reset_at = rst; h.newcmd_at = nc; h.hdd_at = hd; h.gap_reset_at = gap; h.slow = slow;
	glog_clear();
	model_err[0] = 0;
	packet_cmd(cdb, limit);
}

static void packet(const uint8_t *cdb, unsigned limit)
{
	packet_begin(cdb, limit);
	run_loop();
}

static void cdb6(uint8_t *c, uint8_t op, uint8_t b4)
{
	memset(c, 0, 12);
	c[0] = op;
	c[4] = b4;
}

static void read10(uint8_t *c, uint32_t lba, uint16_t count)
{
	memset(c, 0, 12);
	c[0] = 0x28;
	c[2] = (uint8_t)(lba >> 24); c[3] = (uint8_t)(lba >> 16); c[4] = (uint8_t)(lba >> 8); c[5] = (uint8_t)lba;
	c[7] = (uint8_t)(count >> 8); c[8] = (uint8_t)count;
}

/* the status phase */
static int completed(void) { return P[1].end_seen && P[1].reg[2] == 0x03 && (P[1].end_status & IDE_STATUS_IRQ); }
static int good_end(void) { return completed() && !(P[1].end_status & IDE_STATUS_ERR) && P[1].reg[1] == 0; }
static int check_end(uint8_t error) { return completed() && (P[1].end_status & IDE_STATUS_ERR) && P[1].reg[1] == error; }

static int iso_matches(uint32_t lba, size_t bytes)
{
	for (size_t i = 0; i < bytes; i++)
		if (h.in[i] != iso_byte((unsigned long)lba * 2048 + i))
			return 0;
	return 1;
}

/* the card's command log since a mark */
static size_t log_mark;
static void card_log_mark(void) { log_mark = strlen(mock_card_log()); }
/* card sectors of TEST.ISO (map_iso) */
static uint8_t iso_lba[65536];
/* reads of TEST.ISO's sectors (CMD17 / CMD18) since the mark */
static int card_data_reads(void)
{
	int n = 0;
	const char *p = mock_card_log() + log_mark;
	unsigned arg;
	while ((p = strstr(p, "CMD1"))) {
		if ((p[4] == '7' || p[4] == '8') && sscanf(p + 5, " arg=%x", &arg) == 1 && arg < sizeof iso_lba && iso_lba[arg])
			n++;
		p += 4;
	}
	return n;
}
/* the card sectors of the ISO's 512-byte sector s, by the bytes (independent of fat.c) */
static unsigned *iso_card;
static void map_iso(void)
{
	unsigned found = 0;
	iso_card = calloc(ISO_SECTORS * 4, sizeof *iso_card);
	if (!iso_card) die("out of memory");
	for (unsigned l = 0; l < 65536 && found < ISO_SECTORS * 4; l++) {
		const uint8_t *b = mock_card_sector(l);
		unsigned s;
		if (!b) break;
		s = (unsigned)b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3];
		if (s >= ISO_SECTORS * 4 || iso_card[s]) continue;
		if (b[4] != iso_byte((unsigned long)s * 512 + 4) || b[511] != iso_byte((unsigned long)s * 512 + 511)) continue;
		iso_card[s] = l;
		if (l < sizeof iso_lba) iso_lba[l] = 1;
		found++;
	}
	if (found != ISO_SECTORS * 4) die("TEST.ISO is not on the card");
	check("TEST.ISO: its chain has a gap after the file's 24th sector (the card is fragmented)",
	      iso_card[24] != iso_card[23] + 1 && iso_card[23] == iso_card[0] + 23, 1);
}
/* runs a READ of CD sectors lba.. in data-in blocks of per 512-byte
   sectors needs: one per block and cluster (FAT clusters of cluster_size) */
static int runs_of(uint32_t lba, unsigned count, unsigned per)
{
	unsigned long s = (unsigned long)lba * 4, left = (unsigned long)count * 4;
	int runs = 0;
	while (left) {
		unsigned n = left < per ? (unsigned)left : per;
		for (unsigned long a = s; a < s + n; a = (a / cluster_size + 1) * cluster_size)
			runs++;
		s += n;
		left -= n;
	}
	return runs;
}

static void check_cd(const char *what)
{
	char w[240];
	snprintf(w, sizeof w, "%s: Gayle model (%s)", what, model_err[0] ? model_err : "no error");
	check(w, model_err[0] != 0, 0);
	snprintf(w, sizeof w, "%s: host phase errors", what);
	check(w, h.phase_errors, 0);
	snprintf(w, sizeof w, "%s: no FPGA frame (IDE command) while a Gayle op runs", what);
	check(w, (long)mock_gayle_cs_violations(), 0);
	snprintf(w, sizeof w, "%s: no HandleFpga (floppy) work inside a part-delivered data-in block", what);
	check(w, fdd_in_block, 0);
	snprintf(w, sizeof w, "%s: the firmware done (no command, no card op left)", what);
	check(w, fw_busy(), 0);
}

/* READ(10) of count CD sectors at lba with limit: the blocks (min(limit,
   8 KB) in 512-byte units, at least one), the data, a good end, the card
   runs (one per block and cluster, at most 16 sectors each; extra_runs:
   the retries' reads on top) */
static int extra_runs;
static void read_case(const char *what, uint32_t lba, unsigned count, unsigned limit)
{
	char w[240];
	uint8_t c[12];
	unsigned l = (limit == 0 || limit == 0xFFFF) ? 0xFFFE : limit & ~1u, per = l >> 9;
	int nb, ok = 1;
	if (per > 16) per = 16;
	if (!per) per = 1;
	nb = (int)((count * 4 + per - 1) / per);
	read10(c, lba, (uint16_t)count);
	card_log_mark();
	cur_case = what;
	packet(c, limit);
	cur_case = "";
	check_cd(what);
	snprintf(w, sizeof w, "%s: data-in blocks", what);
	if (check(w, h.blocks, nb))
		for (int i = 0; i < nb && ok; i++) {
			unsigned want = (unsigned)((i < nb - 1 ? per : count * 4 - per * (unsigned)(nb - 1)) * 512);
			snprintf(w, sizeof w, "%s: block %d bytes", what, i);
			ok = check(w, h.block_bytes[i], want);
		}
	snprintf(w, sizeof w, "%s: the data (TEST.ISO sectors %u..%u)", what, lba, lba + count - 1);
	check(w, h.in_len == (size_t)count * 2048 && iso_matches(lba, (size_t)count * 2048), 1);
	snprintf(w, sizeof w, "%s: a good end", what);
	check(w, good_end(), 1);
	snprintf(w, sizeof w, "%s: card data reads: one per block and cluster", what);
	check(w, card_data_reads(), runs_of(lba, count, per) + extra_runs);
}

/* cd_read_order: the Amiga-visible events of READ(10)s (three data-in
   block sizes, one read across the chain's gap) against the golden
   recorded on the synchronous CD path before Task 11b (CD_GOLD_WRITE=1
   writes it) */
static void cd_read_order(const char *golden)
{
	static char got[16384], want[16384];
	size_t n = 0;
	FILE *f;
	got[0] = 0;
	read_case("cd_read_order: READ(10) 5+9 (8 KB blocks, across the gap)", 5, 9, 0xFFFE);
	strncat(got, glog_text(), sizeof got - strlen(got) - 1);
	read_case("cd_read_order: READ(10) 100+3, limit 4 KB", 100, 3, 0x1000);
	strncat(got, glog_text(), sizeof got - strlen(got) - 1);
	read_case("cd_read_order: READ(10) 200+2, limit 2 KB", 200, 2, 0x0800);
	strncat(got, glog_text(), sizeof got - strlen(got) - 1);
	if (getenv("CD_GOLD_WRITE")) {
		f = fopen(golden, "w");
		if (!f || fputs(got, f) < 0 || fclose(f)) die("cd_read_order: cannot write the golden");
		say("cd_read_order: golden written to %s\n", golden);
		return;
	}
	f = fopen(golden, "r");
	if (!f) die("cd_read_order: no golden");
	n = fread(want, 1, sizeof want - 1, f);
	fclose(f);
	want[n] = 0;
	cases++;
	if (strcmp(got, want)) {
		say("FAIL cd_read_order: the Gayle trace differs from %s\n--- got\n%s--- want\n%s", golden, got, want);
		fails++;
	}
}

static void sense_case(const char *what, uint8_t key, uint8_t asc, uint8_t ascq)
{
	char w[240];
	uint8_t c[12];
	cdb6(c, 0x03, 18);
	packet(c, 0xFFFE);
	snprintf(w, sizeof w, "%s: REQUEST SENSE %02X/%02X/%02X", what, key, asc, ascq);
	check(w, good_end() && h.in_len == 18 && h.in[2] == key && h.in[12] == asc && h.in[13] == ascq, 1);
	if (!(h.in_len == 18 && h.in[2] == key && h.in[12] == asc && h.in[13] == ascq))
		say("  sense %02X/%02X/%02X\n", h.in[2], h.in[12], h.in[13]);
}

/* reads: the whole disc, the last sector, past the end; the limits */
static void read_cases(void)
{
	uint8_t c[12];
	read_case("READ(10) 0+300 (the whole ISO)", 0, ISO_SECTORS, 0xFFFE);
	read_case("READ(10) 299+1 (the last sector)", ISO_SECTORS - 1, 1, 0xFFFE);
	read_case("READ(10) 3+5, limit 6 KB (12-sector blocks across clusters and the gap)", 3, 5, 0x1800);
	read_case("READ(10) 20+2, limit 1 KB (2-sector blocks)", 20, 2, 0x0400);
	h.slow = 6;	/* drain, then refill: the next block only after the host took this one */
	read_case("slow host: READ(10) 8+24 (the host reads a block at its 6th look)", 8, 24, 0xFFFE);
	h.slow = 0;
	read10(c, ISO_SECTORS - 1, 2);
	packet(c, 0xFFFE);
	check_cd("READ(10) 299+2 (past the end)");
	check("READ(10) 299+2: no data phase, CHECK error 54", h.blocks == 0 && check_end(0x54), 1);
	sense_case("past the end", 0x05, 0x21, 0x00);
}

/* card errors: the card gone (CHECK 03/11/00, ERROR_SDCARD, the transfer
   dropped); back, the next READ initialises it again; CRC errors retried
   (the data right); CRC errors past the retries (03/11/00) */
static void error_cases(void)
{
	uint8_t c[12];
	ClearError(ERROR_ALL);
	mock_card_remove();
	read10(c, 40, 8);
	cur_case = "card gone";
	packet(c, 0xFFFE);
	cur_case = "";
	check_cd("card gone: READ(10) 40+8");
	check("card gone: no data-in block", h.blocks, 0);
	check("card gone: CHECK, error 30 (MEDIUM ERROR)", check_end(0x30), 1);
	check("card gone: ERROR_SDCARD set", (ErrorMask >> ERROR_SDCARD) & 1, 1);
	mock_card_insert();
	sense_case("card gone", 0x03, 0x11, 0x00);
	ClearError(ERROR_ALL);
	read_case("card back: READ(10) 40+8", 40, 8, 0xFFFE);
	check("card back: no error", ErrorMask, 0);
	/* a block CRC error twice: retried, the data right */
	mock_card_error(MOCK_ERR_RDCRC, mock_card_blocks_read() + 6, 2);
	extra_runs = 2;	/* each retry reads again from the failed block */
	read_case("CRC errors retried: READ(10) 60+8", 60, 8, 0xFFFE);
	extra_runs = 0;
	check("CRC errors retried: no error", ErrorMask, 0);
	mock_card_error(MOCK_ERR_RDCRC, 0, 0);
	/* a block that never comes in good: past the retries */
	mock_card_error(MOCK_ERR_RDCRC, mock_card_blocks_read() + 20, 50);
	read10(c, 80, 8);
	packet(c, 0xFFFE);
	mock_card_error(MOCK_ERR_RDCRC, 0, 0);
	check_cd("CRC errors past the retries: READ(10) 80+8");
	check("CRC errors past the retries: the first block, then CHECK error 30", h.blocks == 1 && check_end(0x30), 1);
	check("CRC errors past the retries: the first block's data", h.in_len == 8192 && iso_matches(80, 8192), 1);
	check("CRC errors past the retries: ERROR_SDCARD set", (ErrorMask >> ERROR_SDCARD) & 1, 1);
	sense_case("CRC errors past the retries", 0x03, 0x11, 0x00);
	ClearError(ERROR_ALL);
	read_case("after the CRC errors: READ(10) 80+8", 80, 8, 0xFFFE);
}

/* the Amiga leaves a READ: no status for it, the next command served */
static void abandon_cases(void)
{
	uint8_t c[12];
	const char *t;
	/* a new command over the READ while the bridge moves a block (g_err) */
	mock_gayle_end(MOCK_GAYLE_ERR, 100);
	gerr_newcmd = 1;
	read10(c, 10, 8);
	cur_case = "abandon in a Gayle op";
	packet(c, 0xFFFE);
	cur_case = "";
	check_cd("abandon in a Gayle op: READ(10) 10+8, then TEST UNIT READY");
	t = strstr(glog_text(), "1 cmd a0\n");
	t = t ? strstr(t + 1, "1 cmd a0\n") : NULL;
	check("abandon in a Gayle op: the new command written", t != NULL && !gerr_newcmd, 1);
	check("abandon in a Gayle op: no status of the READ before it",
	      t && memmem(glog_text(), (size_t)(t - glog_text()), "1 st 9", 6) == NULL, 1);
	check("abandon in a Gayle op: nothing of the READ after it, the new command's packet phase next",
	      t && !strncmp(t + 9, "1 xfer 6 1\n", 11), 1);
	check("abandon in a Gayle op: the new command served (good end)", good_end(), 1);
	/* Ctrl-Amiga-Amiga after the 2nd block: no status, the UNIT ATTENTION */
	h.reset_at = 2;
	read10(c, 10, 16);
	packet(c, 0xFFFE);
	h.reset_at = -1;
	check_cd("reset after block 2: READ(10) 10+16");
	check("reset after block 2: two blocks, no status", h.blocks == 2 && !P[1].end_seen, 1);
	cdb6(c, 0x00, 0);
	packet(c, 0xFFFE);
	check("reset after block 2: the next command gets UNIT ATTENTION (error 60)", check_end(0x60), 1);
	/* a new command written after the 1st block (no reset): no status for
	   the READ, the new one served */
	h.newcmd_at = 1;
	read10(c, 30, 12);
	packet(c, 0xFFFE);
	h.newcmd_at = -1;
	check_cd("new command after block 1: READ(10) 30+12, then TEST UNIT READY");
	t = strstr(glog_text(), "1 cmd a0\n");
	t = t ? strstr(t + 1, "1 cmd a0\n") : NULL;
	check("new command after block 1: one block, then the new command", h.blocks == 1 && t != NULL, 1);
	check("new command after block 1: nothing of the READ after it, the new one's packet phase next",
	      t && !strncmp(t + 9, "1 xfer 6 1\n", 11), 1);
	check("new command after block 1: the new command served (good end)", good_end(), 1);
	/* a host that stops reading after the 2nd block: the firmware gives up
	   (CD_TIMEOUT), 0B/00/00 (error B4) */
	h.dead_at = 2;
	read10(c, 50, 16);
	packet(c, 0xFFFE);
	h.dead_at = -1;
	check_cd("host gone after block 2: READ(10) 50+16");
	check("host gone after block 2: two blocks, then CHECK error B4", h.blocks == 2 && check_end(0xB4), 1);
	sense_case("host gone after block 2", 0x0B, 0x00, 0x00);
}

/* ruling T11-R4: one IDE command at a time across both ports; the other
   port's command waits until this one ended, then is served */
static void one_command_cases(void)
{
	uint8_t c[12];
	const char *end, *first0;
	int ok = 1;
	/* an HDD READ SECTORS written while the CD reads */
	h.hdd_at = 2;
	h.hdd_lba = 5000;
	h.hdd_count = 3;
	read10(c, 120, 24);
	packet(c, 0xFFFE);
	h.hdd_at = -1;
	check_cd("HDD command during a CD READ: READ(10) 120+24, READ SECTORS 5000+3");
	check("HDD command during a CD READ: the CD data, a good end",
	      h.blocks == 6 && iso_matches(120, 24 * 2048) && good_end(), 1);
	end = strstr(glog_text(), "1 st 90\n");
	first0 = strstr(glog_text(), "0 tf ");
	check("HDD command during a CD READ: the HDD command served after the CD command ended",
	      end && first0 && first0 > end, 1);
	for (unsigned i = 0; i < 3 && ok; i++)
		ok = in0_n == 3 && !memcmp(in0 + i * 512, mock_card_sector(5000 + i), 512);
	check("HDD command during a CD READ: the HDD data", ok, 1);
	/* a CD READ written while the HDD command reads */
	glog_clear();
	model_err[0] = 0;
	host_reset();
	amiga_command0(5100, 8);
	for (long k = 0; k < 2000000 && P[0].drained < 2; k++) loop_pass();
	check("CD command during an HDD READ: the HDD command runs", P[0].busy && P[0].drained == 2, 1);
	read10(c, 140, 8);
	h.limit = 0xFFFE;
	memcpy(h.cdb, c, 12);
	h.cdb_sent = 0;
	{
		unsigned char t[8] = { 0, 0, 0, 0, 0xFE, 0xFF, 0xA0, 0xA0 };
		amiga_command1(t);
	}
	run_loop();
	check_cd("CD command during an HDD READ: READ SECTORS 5100+8, READ(10) 140+8");
	ok = in0_n == 8;
	for (unsigned i = 0; i < 8 && ok; i++)
		ok = !memcmp(in0 + i * 512, mock_card_sector(5100 + i), 512);
	check("CD command during an HDD READ: the HDD data", ok, 1);
	check("CD command during an HDD READ: the CD data, a good end",
	      h.blocks == 2 && iso_matches(140, 8 * 2048) && good_end(), 1);
	{
		const char *last0 = NULL, *p = glog_text(), *pk;
		for (const char *q = p; (q = strstr(q, "0 rd 1\n")); q++) last0 = q;
		pk = strstr(p, "1 xfer 6 1\n");
		check("CD command during an HDD READ: the CD command serving up after the HDD command's last sector",
		      last0 && pk && pk > last0, 1);
	}
}

/* CD audio (the real player) while the Amiga reads 300 sectors (a card with
   a slow read token: about 1.3 s, several halves of the ring): no underrun,
   still playing */
static void audio_case(void)
{
	uint8_t c[12];
	uint32_t u0;
	unsigned long long t0;
	static const uint8_t tur[12] = { 0 };
	cd_slot("DISC    ", CD_PRESENT_CUE);
	check("DISC.CUE: CD_Open", CD_Open(2), CD_OK);
	packet(tur, 0xFFFE);
	memset(c, 0, 12);
	c[0] = 0x45;	/* PLAY AUDIO(10): track 2, 300 sectors */
	c[4] = (uint8_t)((ISO_SECTORS + 150) >> 8); c[5] = (uint8_t)(ISO_SECTORS + 150);
	c[8] = 250;
	packet(c, 0xFFFE);
	check("audio: PLAY AUDIO good", good_end(), 1);
	check("audio: the player plays", cda_status(), CDA_PLAYING);
	mock_timer_step(0);	/* time as the board has it: the card and the bridge move it */
	mock_card_params(1500, 8, 1, 2);
	u0 = cda_underruns();
	t0 = mock_now();
	read_case("audio: READ(10) 0+300 while CD audio plays", 0, ISO_SECTORS, 0xFFFE);
	mock_card_params(4, 8, 1, 2);
	check("audio: no underrun", (long)(cda_underruns() - u0), 0);
	check("audio: still playing", cda_status(), CDA_PLAYING);
	check("audio: the read lasted three halves of the ring or more",
	      mock_now() - t0 >= 3ull * CDA_HALF_UNITS * MOCK_CYC_PER_TIMER, 1);
	if (getenv("CD_INFO"))
		say("audio: the read took %.0f ms\n", (double)(mock_now() - t0) * 1000.0 / MOCK_CLK_HZ);
	cda_stop();
	mock_timer_step(1);
	cd_slot("TEST    ", CD_PRESENT_ISO);
	check("TEST.ISO again: CD_Open", CD_Open(2), CD_OK);
	packet(tur, 0xFFFE);
}

/* ---- the interrupt-driven CD data path (findings/sdcard-engine Task 11b) ---- */

/* the main loop keeps running during a long READ: passes, HandleFpga (the
   floppy, which reads the card itself: an sd_sync user that gets the card
   between the runs), no FPGA frame during a Gayle op (check_cd) */
static void cd_main_loop_runs(void)
{
	long p0 = passes;
	int f0 = fdd_calls;
	unsigned r0 = fdd_reads;
	fdd_card = 1;
	read_case("cd_main_loop_runs: READ(10) 0+300, the floppy reading the card on every pass", 0, ISO_SECTORS, 0xFFFE);
	fdd_card = 0;
	check("cd_main_loop_runs: main-loop passes during the READ >= its 75 blocks", passes - p0 >= 75, 1);
	check("cd_main_loop_runs: HandleFpga (the floppy) ran during the READ", fdd_calls - f0 >= 75, 1);
	check("cd_main_loop_runs: the floppy's card reads ran during the READ", (long)(fdd_reads - r0) >= 75, 1);
}

/* Ctrl-Amiga-Amiga in the gap after the firmware saw a block taken
   (XFER_DONE) and before the next block's phase: nothing of the READ after
   the reset (no phase, no status), UNIT ATTENTION next */
static void cd_reset_in_gap(void)
{
	uint8_t c[12];
	const char *r;
	h.gap_reset_at = 1;
	read10(c, 30, 12);
	packet(c, 0xFFFE);
	h.gap_reset_at = -1;
	check_cd("cd_reset_in_gap: READ(10) 30+12");
	r = strstr(glog_text(), "reset\n");
	check("cd_reset_in_gap: the reset after block 1", h.blocks == 1 && r != NULL, 1);
	check("cd_reset_in_gap: nothing of the READ after the reset", r && !strstr(r, "1 "), 1);
	cdb6(c, 0x00, 0);
	packet(c, 0xFFFE);
	check("cd_reset_in_gap: the next command gets UNIT ATTENTION (error 60)", check_end(0x60), 1);
}

/* the card fails during a run and the Amiga is reset at the same moment
   (after the READ's 2nd block reached Gayle: the card pulled, Ctrl-Amiga-
   Amiga): the card error must not end the old command with a status */
static int gayle_ends;
static void pull_and_reset(void *ctx)
{
	(void)ctx;
	if (++gayle_ends != 2)
		return;
	mock_sdc_pull_card();
	amiga_reset();
}
static void cd_error_after_reset(void)
{
	uint8_t c[12];
	static const uint8_t tur[12] = { 0 };
	const char *r;
	ClearError(ERROR_ALL);
	gayle_ends = 0;
	mock_gayle_on_end(pull_and_reset, NULL);
	read10(c, 160, 8);
	packet(c, 0xFFFE);
	mock_gayle_on_end(NULL, NULL);
	check_cd("cd_error_after_reset: READ(10) 160+8");
	r = strstr(glog_text(), "reset\n");
	check("cd_error_after_reset: the reset during the run", r != NULL && h.blocks == 0, 1);
	check("cd_error_after_reset: no status (nor anything else) of the READ after the reset", r && !strstr(r, "1 "), 1);
	check("cd_error_after_reset: the card error shown (ERROR_SDCARD)", (ErrorMask >> ERROR_SDCARD) & 1, 1);
	mock_sdc_cd(1);
	mock_card_insert();
	ClearError(ERROR_ALL);
	packet(tur, 0xFFFE);
	check("cd_error_after_reset: the next command gets UNIT ATTENTION (error 60)", check_end(0x60), 1);
	read_case("cd_error_after_reset: the card back, READ(10) 160+8", 160, 8, 0xFFFE);
}

/* the OSD ejects the disc (unlocked) while the Amiga reads: the READ ends
   first (CHECK 0B/00/00, error B4; its card op finished), the drive is
   empty, TEST UNIT READY 02/3A/00 (error 20); the disc back in */
static void cd_osd_eject(void)
{
	uint8_t c[12];
	static const uint8_t tur[12] = { 0 };
	long k;
	read10(c, 0, 64);
	packet_begin(c, 0xFFFE);
	for (k = 0; k < 2000000 && h.blocks < 2; k++)
		loop_pass();
	check("cd_osd_eject: the READ runs (2 blocks read)", h.blocks == 2 && P[1].busy, 1);
	check("cd_osd_eject: CD_Eject", CD_Eject(), CD_OK);
	check("cd_osd_eject: the READ ended at once: CHECK error B4", check_end(0xB4) && !P[1].busy, 1);
	check("cd_osd_eject: no command and no card op left", fw_busy(), 0);
	run_loop();
	check_cd("cd_osd_eject: READ(10) 0+64");
	check("cd_osd_eject: two blocks only", h.blocks, 2);
	check("cd_osd_eject: the drive empty", cdrom.unit.media, 0);
	packet(tur, 0xFFFE);
	check("cd_osd_eject: TEST UNIT READY: no medium (error 20)", check_end(0x20), 1);
	cd_slot("TEST    ", CD_PRESENT_ISO);
	check("cd_osd_eject: TEST.ISO again: CD_Open", CD_Open(2), CD_OK);
	packet(tur, 0xFFFE);
	read_case("cd_osd_eject: after it, READ(10) 0+4", 0, 4, 0xFFFE);
}

/* fix round 1: in packet mode the DRQ comes once 256 words are in, so the
   Amiga may be reading a data-in block, held by nrdy, while its later
   sectors come in (8 KB blocks are two runs here: 4 KB clusters).  While a
   block is part-delivered PollDisks runs the disks only: the floppy (with
   a card read of its own pending on every pass) only between blocks */
static void cd_block_gate(void)
{
	static const uint8_t tur[12] = { 0 };
	long p0;
	int f0;
	packet(tur, 0xFFFE);	/* the UNIT ATTENTION of cd_trace's reset */
	p0 = in_block_passes;
	f0 = fdd_calls;
	fdd_card = 1;
	read_case("cd_block_gate: READ(10) 0+40, the floppy reading the card on every pass", 0, 40, 0xFFFE);
	fdd_card = 0;
	check("cd_block_gate: passes of disk steps only inside a block", in_block_passes - p0 > 0, 1);
	check("cd_block_gate: HandleFpga (the floppy) ran between the blocks", fdd_calls - f0 >= 10, 1);
	p0 = in_block_passes;
	read_case("cd_block_gate: READ(10) 0+4, limit 512 (one-sector blocks: no gate)", 0, 4, 0x0200);
	check("cd_block_gate: no gate for one-sector blocks", in_block_passes - p0, 0);
}

/* dbg_flags DBG_ATA (ruling T11-R2): one line per CD command at its end
   too, quiet without the flag */
static void cd_trace(void)
{
	uint8_t c[12];
	dbg_flags = 0;
	mock_uart_clear();
	read10(c, 5, 9);
	packet(c, 0xFFFE);
	check("cd_trace: dbg_flags 0: no UART output from a READ(10)", (long)mock_uart_len(), 0);
	dbg_flags = DBG_ATA;
	mock_uart_clear();
	packet(c, 0xFFFE);
	check("cd_trace: DBG_ATA: the READ(10)'s line", strstr(mock_uart(), "ATA a0 lba 5 n 9 port 1 ok st 90 t ") != NULL, 1);
	mock_uart_clear();
	cdb6(c, 0x12, 36);
	packet(c, 0xFFFE);
	/* a command that ran to its end in the pickup: "done", as hdd.c's */
	check("cd_trace: DBG_ATA: INQUIRY's line", strstr(mock_uart(), "ATA a0 lba 0 n 0 port 1 done st 00 t 0\n") != NULL, 1);
	mock_uart_clear();
	read10(c, ISO_SECTORS - 1, 2);
	packet(c, 0xFFFE);
	check("cd_trace: DBG_ATA: a refused READ's line", strstr(mock_uart(), "ATA a0 lba 0 n 0 port 1 done st 00 t 0\n") != NULL, 1);
	mock_uart_clear();
	ClearError(ERROR_ALL);
	mock_card_remove();
	read10(c, 40, 8);
	packet(c, 0xFFFE);
	mock_card_insert();
	check("cd_trace: DBG_ATA: a card error's line", strstr(mock_uart(), "ATA a0 lba 40 n 8 port 1 error st 91 t ") != NULL, 1);
	ClearError(ERROR_ALL);
	mock_uart_clear();
	h.reset_at = 1;
	read10(c, 40, 8);
	packet(c, 0xFFFE);
	h.reset_at = -1;
	check("cd_trace: DBG_ATA: an abandoned READ's line", strstr(mock_uart(), "ATA a0 lba 40 n 8 port 1 abandoned st 00 t ") != NULL, 1);
	{
		const char *a = strstr(mock_uart(), "ATA ");
		if (!check("cd_trace: one ATA line for the command (the card's re-init lines aside)", a && !strstr(a + 1, "ATA "), 1))
			say("--- the UART\n%s", mock_uart());
	}
	dbg_flags = 0;
}

int main(int argc, char **argv)
{
	if (argc != 3) { fprintf(stderr, "usage: cdpath_test <dir> <golden of cd_read_order>\n"); return 2; }
	dir = argv[1];
	card_up();
	map_iso();
	cd_read_order(argv[2]);
	read_cases();
	error_cases();
	abandon_cases();
	one_command_cases();
	audio_case();
	cd_main_loop_runs();
	cd_reset_in_gap();
	cd_error_after_reset();
	cd_osd_eject();
	cd_trace();
	cd_block_gate();
	free(iso_card);
	free(glog_buf.p);
	say("%s: %d checks, %d failed\n", fails ? "FAIL" : "PASS", cases, fails);
	return fails ? 1 : 0;
}

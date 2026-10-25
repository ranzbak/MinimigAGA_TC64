/* hdd_test: the hard disk emulation's Amiga-facing bytes and its ATA paths
 * (Task 12, plan 5.2 items 1, 2, 7).
 *   hdd_test <dir> <golden of rd_multi_order (gold/hdd_rd_multi32.txt)>
 * <dir> holds what the Makefile made first: gold/rdb.py's rdbcases.h and
 * hdf/{WORK,SYNTH,ODD}.HDF, gold/identify.py's identcases.h (both compiled
 * in) and hdd.img, a tools/sim/mkcard.sh card with the three hardfiles.
 *
 * The real hdd.c runs over the real fat.c and mmc.c on the card model
 * (mock_hw.c), driven by the main loop's FPGA poll (HandleFpga, cut out of
 * main.c: it picks the command up through HandleHDD()) and a mock Gayle on
 * the FPGA chip select (gayle_miso below).  The checks:
 *   - FakeRDB: hdf[] set up as OpenHardfile does (type HDF_FILE |
 *     HDF_SYNTHRDB, the file size, GetHardfileGeometry, offset -heads *
 *     sectors) for a 2 MB, a 2 GB and an odd-sized (20001 blocks) hardfile:
 *     the geometry and the RDSK and PART blocks READ SECTORS sends, byte
 *     for byte against rdb.py (big-endian longs, checksum); the real
 *     OpenHardfile on SYNTH.HDF and ODD.HDF gives the same hdf[] fields
 *   - the RDB patch of an HDF's own RDB (hdd.c, unit 0, plain HDF_FILE,
 *     block 0): Flags 0x12 and the checksum still valid (rdb.py); unit 1
 *     sends the block as it is
 *   - IDENTIFY DEVICE: the 512 data bytes against identify.py (the
 *     firmware's stream: word values low byte first, ATA strings first character in
 *     bits 15:8), for the WORK.HDF cases (long name, 8.3, SYNTHRDB) and the
 *     card ones
 *   - READ SECTORS / READ MULTIPLE / WRITE SECTORS / WRITE MULTIPLE: the
 *     task file bytes -> LBA (CHS only: IDENTIFY offers no LBA
 *     mode), the task file written back (the last sector's CHS), the status
 *     writes, sector count 0 = 256, the chunks of READ MULTIPLE (at most
 *     SET MULTIPLE MODE's count between two "FIFO drained" polls, never
 *     more than the 16 sectors the Gayle FIFO holds), every block's data
 *     against the HDF file (reads) or on the card (writes: every other
 *     card byte unchanged), and the FakeRDB boundary loop (hdd.c, the
 *     Task 4 parenthesis) with READ/WRITE MULTIPLE ranges that cross from
 *     the synthesised first cylinder into the file inside one chunk.
 * The blocks the firmware sends are read back in the order they reach
 * Gayle: the data bytes of CMD_IDE_DATA_WR frames (the SPI trace) and the
 * card's blocks the SD peripheral's RX_TO_GAYLE moved (the mock bridge,
 * mock_gayle_into(); findings/sdcard-engine Task 10: what was cfide's
 * direct mode, cs 42, which must not appear any more).  Card errors: the
 * card stops answering during a READ and a WRITE (END | IRQ | ERR, no
 * block, ERROR_SDCARD; the next command initialises the card again), and
 * a read the Amiga abandons (Gayle error: no status at all).  The test
 * reports with fprintf(stdout) (say); the firmware's printf (rvlibc.c)
 * goes to the mock UART. */
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
#include "cdaudio.h"

#include "rdbcases.h"
#include "identcases.h"

/* ---- what hdd.c needs from the rest of the firmware ---- */
configTYPE config;
char DebugMode;
cdromTYPE cdrom;		/* BSS zero: no CD drive, CD_SLOT() is -1 */
static int audio_polls, full_polls, hdd_steps;
/* The CD player is busy (playing): the real CD_AudioPoll (cdrom.c) then reads
   the CD port's flags, ReadIDEFlags(1) -- a CMD_IDE_REGS_RD | 1, whose command
   word re-latches the Gayle's firmware port.  The stub does the same. */
static int cd_audio_busy;
/* the refill reads the card (cdrom.c's cda_port_read: FileRead, an sd_sync
   user that queues behind the HDD path's card op) */
static int cd_refill_card;
static unsigned refill_reads;
static void die(const char *what);

/* config.c's */
hardfileTYPE *SlotConfig(int slot)
{
	return (slot & 2) ? &config.secondaryhardfile[slot & 1] : &config.hardfile[slot & 1];
}
void DebugMessage(char *message) { (void)message; }
void CD_AudioPoll(void)
{
	audio_polls++;
	if (hdd_busy())
		full_polls++;	/* inside an HDD command: the flags read below re-latches the port */
	if (cd_audio_busy)
		ReadIDEFlags(1);	/* the CD on port 2, as cdrom.c CD_AudioPoll */
}
/* ---- the CD audio player (cdaudio.c, linked) on the mock's clock ----
 * cdrom.c's CD_AudioRefill is cda_poll() (and an underrun line in
 * DebugMode); its cda_port_read is FileRead from the disc file, an sd_sync
 * user.  Here the disc is one audio track whose blocks are card sectors
 * (MMC_Read: the same sd_sync path), the TIMER and the hardware's half are
 * the mock's clock (hosttest_timer_peek: 256 frames a count, no time). */
static int cd_playing;		/* the refill stub runs the player */
static unsigned cd_reads, cd_reads_in_cmd;
static unsigned cd_ena_timer;
static int cd_ena;
static uint8_t cd_ring[2 * CDA_HALF_BYTES];
int32_t cda_port_read(int32_t file, uint32_t block, uint8_t *dst)
{
	(void)file;
	cd_reads++;
	if (hdd_busy()) cd_reads_in_cmd++;
	return MMC_Read(100 + block % 512, dst);	/* card sectors of the image (not the HDF ones written) */
}
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

void CD_AudioRefill(void)
{
	static unsigned char b[512];
	audio_polls++;
	if (cd_playing)
		cda_poll();	/* as cdrom.c's CD_AudioRefill */
	if (cd_refill_card) {
		if (!MMC_Read(20 + refill_reads % 8, b)) die("the CD refill's card read failed");
		refill_reads++;
	}
}
void CD_Flags(int port, unsigned char flags) { }
void CD_HandleCommand(int port, unsigned char *tfr) { fprintf(stdout, "FAIL CD_HandleCommand called\n"); exit(1); }
/* the CD drive's READ states (cdrom.c, findings/sdcard-engine Task 11b):
   never in progress here (no CD drive); cdpath_test runs the real ones */
int CD_Busy(void) { return 0; }
int CD_Step(void) { fprintf(stdout, "FAIL CD_Step called\n"); exit(1); }
int CD_InBlock(void) { return 0; }
void drivesounds_queueevent(enum DriveSound_Type type) { if (type == DRIVESOUND_HDDSTEP) hdd_steps++; }

/* fpga.c's, as it is (fpga.c itself pulls in the boot and OSD code) */
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

/* main.c's HandleFpga, cut out by the Makefile (main.c holds main()): the
   main loop's poll of the FPGA's requests, which picks the IDE commands up
   (HandleHDD); the floppy side is a stub that sends one floppy command
   frame, as UpdateDriveStatus does (no HDD command word) */
static int fdd_calls;
/* floppy work (HandleFpga) while a READ MULTIPLE group was part-delivered
   (hdd_in_block: the Amiga may wait inside it on nrdy; findings/sdcard-engine
   Task 11b fix round 1), and the passes PollDisks ran the disks only */
static int fdd_in_block;
static long in_block_passes;
static int amiga_in_group(void);
void HandleFDD(unsigned char c1, unsigned char c2, unsigned char c3, unsigned char c4)
{
	(void)c1; (void)c2; (void)c3; (void)c4;
	fdd_calls++;
	if (amiga_in_group())
		fdd_in_block++;
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

static int check_mem(const char *what, const uint8_t *got, const uint8_t *want, size_t n)
{
	cases++;
	for (size_t i = 0; i < n; i++)
		if (got[i] != want[i]) {
			say("FAIL %s: byte %zu is %02x, want %02x\n", what, i, got[i], want[i]);
			fails++;
			return 0;
		}
	return 1;
}

/* the case running (read_case / write_case), for a die inside it */
static const char *cur_case = "";
static void die(const char *what)
{
	say("FAIL %s%s%s\n", cur_case, *cur_case ? ": " : "", what);
	exit(1);
}

/* ---- the mock Gayle (rtl/minimig/gayle_port.v, paula_floppy.v) ----------
 * Every FPGA frame starts with the command byte; its reply is the status
 * byte (paula_floppy spi_tx_data_0 bits 15:8: bit 3 hdd_dat_req =
 * CMD_IDEDAT, bit 2 hdd_cmd_req = CMD_IDECMD), which GetFPGAStatus and
 * HandleFpga read with a 0 command byte.  CMD_IDE_REGS_RD: 5 dummy bytes,
 * then per task file register the flags byte and the register.
 * CMD_IDE_REGS_WR, CMD_IDE_STATUS_WR, CMD_IDE_DATA_WR: the bytes as hdd.c
 * writes them.  CMD_IDE_DATA_RD: 5 dummy bytes, then the FIFO's bytes.
 * Port 1 only (the IDE port of every command here).
 *   - A command (amiga_command): busy, no direction yet: hdd_cmd_req (the
 *     firmware picks it up through HandleFpga, cut out of main.c).  The
 *     command write resets the FIFO: the bridge's cmd_since
 *     (mock_gayle_abandon), cleared by the pickup's CMD_IDE_REGS_RD
 *     (mock_gayle_seen).  END clears busy (and the direction).
 *   - pio in (status write with bit 3, RDY): hdd_cmd_req is bsy = busy &
 *     ~drq, drq = a sector in the FIFO.  The Amiga reads a group (READ
 *     MULTIPLE: SET MULTIPLE MODE's count, else 1; the last one the rest)
 *     at the first status poll that finds the whole group in the FIFO
 *     (logged "rd n"), and "drained" is the next poll; a poll that finds
 *     part of a group answers "busy" (the Amiga is reading); more than a
 *     group in the FIFO is a refill before the drain (gayle_port.v fires
 *     the interrupt on the DRQ edge: it would be lost).  The FIFO holds 16
 *     sectors (gayle_fifo.v, 4096 words).  After the last sector Gayle
 *     clears busy itself.
 *   - pio out (bit 2, REQ): every other poll the Amiga writes a sector
 *     while the FIFO is empty (drq) -- into the bridge's from[0], which
 *     GAYLE_TO_TX takes and CMD_IDE_DATA_RD pops (mock_gayle_from_pop) --
 *     and the next group only after the IRQ status write of this one
 *     (ATA: the host waits for INTRQ between blocks).  hdd_dat_req: a whole
 *     sector in the FIFO (with hdd_cmd_req: fifo_full makes bsy); after the
 *     last sector: hdd_cmd_req alone.
 *   - A Gayle error of the bridge (mock_gayle_end, an abandon) stands for
 *     the Amiga's new command: the model goes idle (no request), the
 *     abandon flag stays until the next pickup.
 * The firmware port latch (paula_floppy.v hdd_port_r, gayle.v fw_port): bit
 * 0 of the first byte of every HDD command word (10xx, 1100, 1111) selects
 * the port, and it stays latched for what follows without a command word
 * (GetFPGAStatus).  Every command here is on port 1: a port-2 command word
 * while the firmware serves it is an error (on the board: the next block
 * went to port 2's FIFO and "drained" hid behind the busy CD port, a
 * deadlock, 2026-10-20).
 * The Amiga-visible events go to g.log, one line each: "tf <6 bytes>"
 * (task file write: error, count, sector, cyl lo, cyl hi, dh), "st <status>",
 * "rd <n>" (the Amiga read n sectors), "reset", "cmd" (a new command). */
#define FIFO_SECTORS 16
#define MAXCHUNKS 300
static int fw_in_command(void);
static void status_irq(void);
/* the unit / LBA of the command being served: the IRQ check */
static int cur_unit;
static long cur_lba;
static struct gayle {
	int frame;		/* mock_frames() of the open frame */
	unsigned pos;		/* its byte index */
	unsigned char cmd, fb[24];
	unsigned char tfr[8];	/* the command the Amiga wrote */
	int busy;		/* gayle_port.v busy */
	int pio;		/* 0, 1 = in, 2 = out */
	unsigned count, chunk;	/* sectors of the command, of a group */
	unsigned long rx;	/* CMD_IDE_DATA_WR data bytes */
	unsigned drained;	/* sectors the Amiga read */
	int chunks[MAXCHUNKS], nchunks;
	unsigned char status[MAXCHUNKS + 2]; int nstatus;
	unsigned char tfw[8][6]; int ntfw;	/* task file writes: error, count, sector, cyl lo, cyl hi, dh */
	const uint8_t *wdata; size_t wlen;	/* the Amiga's write data */
	unsigned wready;	/* sectors the Amiga put in the FIFO */
	unsigned irqs;		/* IRQ status writes of a pio-out command (groups released) */
	int wtoggle;
	int rst_seen;		/* the next CMD_IDE_REGS_RD reports IDEF_RST_SEEN */
	unsigned gerrs;		/* mock_gayle_errs() the model has seen */
	int hook;		/* HOOK_*: what the Amiga does instead of writing sector hook_at */
	unsigned hook_at;
	unsigned pause;		/* HOOK_PAUSE: polls the Amiga waits */
	unsigned stop_mark;	/* mock_card_stop_ends() at the last IRQ status write */
	unsigned stops_at_reset;	/* mock_card_stop_ends() when the Amiga was reset */
	int log_dw;		/* log the CPU's data frames ("dw") */
	struct { int on; unsigned char tfr[8]; unsigned count, chunk; const uint8_t *wdata; size_t wlen; long lba; int unit; }
	        next;	/* the command the Amiga writes right after a reset (HOOK_RESET_DRAIN) */
	unsigned long busy_polls, polls;
	struct { char *p; size_t n, cap; } log;
	char err[160];
} g;

/* the bytes of the mock bridge (RX_TO_GAYLE) per Gayle port at the
   command's start, and the port-0 bytes when each CMD_IDE_DATA_WR frame
   began (the order of the two kinds of blocks) */
#define MAXBLOCKS 300
static size_t gay_base[2];
static size_t dw_at[MAXBLOCKS];
static int ndw;
static size_t gay_bytes(unsigned port)
{
	size_t n;
	mock_gayle_into(port, &n);
	return n - gay_base[port];
}

static void gayle_err(const char *msg)
{
	if (!g.err[0]) snprintf(g.err, sizeof g.err, "%s", msg);
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
	if (g.log.n + (size_t)n + 2 > g.log.cap) {
		g.log.cap = (g.log.cap + (size_t)n + 2) * 2;
		g.log.p = realloc(g.log.p, g.log.cap);
		if (!g.log.p) die("out of memory");
	}
	memcpy(g.log.p + g.log.n, line, (size_t)n);
	g.log.n += (size_t)n;
	g.log.p[g.log.n++] = '\n';
	g.log.p[g.log.n] = 0;
}

static unsigned fifo_sectors(void)
{
	if (g.rx % 512) gayle_err("a partial sector in the FIFO at a status poll");
	if (gay_bytes(0) % 512) gayle_err("a partial card block in the FIFO at a status poll");
	return (unsigned)(g.rx / 512) + (unsigned)(gay_bytes(0) / 512) - g.drained;
}

/* the Amiga may be reading inside a READ group that is still being filled,
   held by nrdy on the empty FIFO: Gayle's DRQ is up (a sector of the group
   in) and the group is not all in (Task 11b fix round 1) */
static int amiga_in_group(void)
{
	unsigned want, n;
	if (!g.busy || g.pio != 1)
		return 0;
	want = g.count - g.drained;
	if (want > g.chunk) want = g.chunk;
	n = (unsigned)(g.rx / 512) + (unsigned)(gay_bytes(0) / 512) - g.drained;
	return want > 1 && n > 0 && n < want;
}

/* sectors the firmware took out of the FIFO (the bridge or CMD_IDE_DATA_RD) */
static unsigned long consumed(void)
{
	return (unsigned long)g.wready * 512 - (unsigned long)mock_gayle_from_left(0);
}

/* a new command on port 1: what Gayle does on the command register write */
static void amiga_command(const unsigned char *t, unsigned count, unsigned chunk)
{
	memcpy(g.tfr, t, 8);
	g.busy = 1;
	g.pio = 0;
	g.count = count;
	g.chunk = chunk ? chunk : 1;
	g.stop_mark = mock_card_stop_ends();
	mock_gayle_abandon(0);	/* the FIFO reset: cmd_since until the pickup */
}

/* a Gayle error since the last look: the Amiga's new command (the model's
   stand-in: idle until the test's next command) */
static void look_gerr(void)
{
	if (mock_gayle_errs() != g.gerrs) {
		g.gerrs = mock_gayle_errs();
		g.busy = 0;
		g.pio = 0;
		mock_gayle_abandon(0);
	}
}

/* what the Amiga does when it comes to its sector hook_at (0-based) */
enum { HOOK_NONE, HOOK_RESET, HOOK_PULL, HOOK_ABANDON, HOOK_PAUSE, HOOK_RESET_END, HOOK_RESET_DRAIN, HOOK_RESET_DW };
static void amiga_reset(void)
{
	glog("reset");
	g.stops_at_reset = mock_card_stop_ends();
	g.busy = 0;
	g.pio = 0;
	g.rst_seen = 1;
	mock_gayle_abandon(0);	/* Gayle reset: the FIFO, cmd_since */
	g.hook = HOOK_NONE;
}

static void amiga_write(void);
/* pio out: the Amiga writes its next sector when DRQ is up (the FIFO
   empty, sectors left, its group released by the last IRQ) */
static void amiga_try_write(void)
{
	unsigned total = (unsigned)(g.wlen / 512), allowed = (g.irqs + 1) * g.chunk;
	if (total > g.count) total = g.count;
	if (g.busy && g.pio == 2 && !mock_gayle_from_left(0) && g.wready < total && g.wready < allowed)
		amiga_write();
}

/* Ctrl-Amiga-Amiga, then at once the next command (g.next) if one is set */
static void amiga_reset_next(void)
{
	amiga_reset();
	if (!g.next.on)
		return;
	glog("cmd");
	g.wdata = g.next.wdata;
	g.wlen = g.next.wlen;
	g.wready = 0;
	g.irqs = 0;
	g.rx = 0;
	g.drained = 0;
	cur_unit = g.next.unit;
	cur_lba = g.next.lba;
	mock_gayle_into(0, &gay_base[0]);
	amiga_command(g.next.tfr, g.next.count, g.next.chunk);
	g.next.on = 0;
}

/* the Amiga writes its next sector into the FIFO */
static void amiga_write(void)
{
	if (g.hook && g.wready == g.hook_at) {
		switch (g.hook) {
		case HOOK_RESET:
			amiga_reset();
			return;
		case HOOK_PULL:
			glog("card pulled");
			mock_sdc_pull_card();
			g.hook = HOOK_NONE;
			break;
		case HOOK_ABANDON:	/* a new command resets the FIFO while the bridge moves this sector */
			glog("abandon");
			mock_gayle_end(MOCK_GAYLE_ERR, 100);
			g.hook = HOOK_NONE;
			break;
		case HOOK_PAUSE:
			if (g.pause) { g.pause--; return; }
			g.hook = HOOK_NONE;
			break;
		}
	}
	mock_gayle_from(0, g.wdata + (size_t)g.wready * 512, 512);
	g.wready++;
}

static unsigned char gayle_poll(void)
{
	unsigned char st = 0;
	g.polls++;
	look_gerr();
	if (!g.busy)
		st = 0;
	else if (g.pio == 0)
		st = CMD_IDECMD;	/* the command, no direction yet */
	else if (g.pio == 1) {
		unsigned n = fifo_sectors(), want = g.count - g.drained;
		if (want > g.chunk) want = g.chunk;
		if (n > FIFO_SECTORS) gayle_err("more than 16 sectors in the FIFO");
		if (n > want) gayle_err("more than one group in the FIFO: a refill before the drain");
		if (n && n >= want && g.hook == HOOK_RESET_DRAIN && (unsigned)g.nchunks == g.hook_at) {
			/* Ctrl-Amiga-Amiga instead of reading this group, then at once
			   the next command (g.next): its request is what the old
			   command's drain wait sees */
			amiga_reset_next();
			return CMD_IDECMD;
		}
		if (n && n >= want) {
			if (g.nchunks < MAXCHUNKS) g.chunks[g.nchunks++] = (int)n;
			glog("rd %u", n);
			g.drained += n;
			if (g.drained >= g.count) { g.busy = 0; g.pio = 0; }	/* the last sector read */
		} else if (!n)
			st = CMD_IDECMD;
	} else if (g.pio == 2) {
		size_t left = mock_gayle_from_left(0);
		if (left % 512) gayle_err("a partial sector in the write FIFO at a status poll");
		if (g.wtoggle ^= 1)
			amiga_try_write();
		left = mock_gayle_from_left(0);
		if (g.hook == HOOK_RESET_END && consumed() >= (unsigned long)g.count * 512) {
			amiga_reset();	/* while the card programs the last group */
			return 0;
		}
		if (left >= 512) st = CMD_IDEDAT | CMD_IDECMD;	/* fifo_full: dat_req, and bsy */
		else if (g.wready >= g.count) st = CMD_IDECMD;	/* the last sector taken */
	}
	if (st) g.busy_polls = 0;
	else if (++g.busy_polls > 100000) die("the firmware polls a Gayle that never gets ready");
	return st;
}

static unsigned char gayle_miso(void *ctx, unsigned char out)
{
	(void)ctx;
	int f = mock_frames();
	if (f != g.frame) { g.frame = f; g.pos = 0; }
	unsigned pos = g.pos++;
	if (pos == 0) {
		/* HOOK_RESET_DW: the reset after the CPU's hook_at-th data block,
		   at the next frame (the firmware's next step) */
		if (g.hook == HOOK_RESET_DW && (out & 0xFE) != CMD_IDE_DATA_WR && ndw >= (int)g.hook_at)
			amiga_reset_next();
		g.cmd = out;
		if ((out & 0xC0) == 0x80 || (out & 0xF0) == 0xC0 || (out & 0xF0) == 0xF0) {
			char m[120];
			snprintf(m, sizeof m, "a port-2 command word %02X inside a port-1 command: re-latches hdd_port", out);
			if ((out & 1) && fw_in_command()) gayle_err(m);
		}
		if ((out & 0xFE) == CMD_IDE_DATA_WR) {
			if (ndw < MAXBLOCKS) dw_at[ndw++] = gay_bytes(0);
			if (g.log_dw) glog("dw");	/* the CPU writes a block into the FIFO */
		}
		if ((out & 0xF0) == CMD_IDE_REGS_RD) {
			mock_gayle_seen(out & 1);	/* "I have seen this port's command" */
			g.fb[0] = (unsigned char)((out & 1) ? IDEF_PORT : 0) | (unsigned char)(g.rst_seen && !(out & 1) ? IDEF_RST_SEEN : 0);
			if (!(out & 1)) g.rst_seen = 0;
		}
		return out == 0 ? gayle_poll() : 0;
	}
	if (pos < sizeof g.fb && (g.cmd & 0xF0) != CMD_IDE_REGS_RD) g.fb[pos] = out;
	switch (g.cmd & 0xFE) {
	case CMD_IDE_REGS_RD:
		if (pos < 6 || pos >= 22) return 0;
		return (pos - 6) & 1 ? g.tfr[(pos - 6) / 2] : g.fb[0];
	case CMD_IDE_REGS_WR:
		if (pos == 19 && g.ntfw < 8) {
			unsigned char *t = g.tfw[g.ntfw++];
			t[0] = g.fb[9]; t[1] = g.fb[11]; t[2] = g.fb[13];
			t[3] = g.fb[15]; t[4] = g.fb[17]; t[5] = g.fb[19];
			glog("tf %02x %02x %02x %02x %02x %02x", t[0], t[1], t[2], t[3], t[4], t[5]);
		}
		return 0;
	case CMD_IDE_STATUS_WR:
		if (pos == 1) {
			if (g.nstatus < (int)sizeof g.status) g.status[g.nstatus++] = out;
			glog("st %02x", out);
			if (!g.busy) gayle_err("a status write while the port is not busy (the old command's, after an abandon?)");
			if (out & IDE_STATUS_RDY) g.pio = 1;
			if (out & IDE_STATUS_REQ) g.pio = 2;
			if (g.pio == 2 && (out & IDE_STATUS_IRQ) && !(out & IDE_STATUS_ERR)) { status_irq(); g.irqs++; }
			if (out & IDE_STATUS_END) { g.busy = 0; g.pio = 0; }
		}
		return 0;
	case CMD_IDE_DATA_WR:
		if (pos >= 6) g.rx++;
		return 0;
	case CMD_IDE_DATA_RD: {
		int b;
		if (pos < 6) return 0;
		b = mock_gayle_from_pop(0);
		if (b < 0) { gayle_err("CMD_IDE_DATA_RD of a sector the Amiga has not written"); return 0; }
		return (unsigned char)b;
	}
	}
	return 0;
}

/* ---- the blocks of one command ---- */
static size_t trace_mark;
static uint8_t blocks[MAXBLOCKS][512];
static int nblocks;
static int bad_frames;
static int port2_blocks;	/* data blocks sent while the latch said port 2 */

static int nibble(char c)
{
	return isdigit((unsigned char)c) ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : -1;
}

static int hexval(const char **p)
{
	while (**p == ' ') (*p)++;
	int hi = nibble((*p)[0]), lo = hi < 0 ? -1 : nibble((*p)[1]);
	if (lo < 0) return -1;
	*p += 2;
	return hi << 4 | lo;
}

/* the data blocks since trace_mark (the end of the last call), in the order
   they reached Gayle: CMD_IDE_DATA_WR frames (cs 10, after the 6 command
   bytes) of the trace, and between them the card blocks the mock bridge
   moved into port 0 (dw_at).  A direct-mode frame (cs 42) is a bad frame
   now: the card is not on cfide's SPI.  Bytes into port 1 are blocks of
   port 2. */
static void add_block(const uint8_t *b)
{
	if (nblocks < MAXBLOCKS) memcpy(blocks[nblocks++], b, 512);
}
static void trace_blocks(void)
{
	const char *all = mock_trace(), *t = all + trace_mark;
	static uint8_t out[1 << 16], in[1 << 16];
	int latch = 0;	/* HandleHDD's first frame latches port 1 */
	size_t gn, gpos = 0;
	const uint8_t *gp = mock_gayle_into(0, &gn);
	int k = 0;
	gp += gay_base[0];
	gn -= gay_base[0];
	nblocks = 0;
	bad_frames = 0;
	port2_blocks = (int)(gay_bytes(1) / 512);
	while (*t) {
		const char *eol = strchr(t, '\n');
		if (!eol) break;
		const char *p = t;
		int cs = hexval(&p);
		size_t no = 0, ni = 0;
		int v;
		while (p < eol && (v = hexval(&p)) >= 0) if (no < sizeof out) out[no++] = (uint8_t)v;
		while (*p == ' ') p++;
		if (*p == '/') p++;
		while (p < eol && (v = hexval(&p)) >= 0) if (ni < sizeof in) in[ni++] = (uint8_t)v;
		if (cs == 0x10 && no && ((out[0] & 0xC0) == 0x80 || (out[0] & 0xF0) == 0xC0 || (out[0] & 0xF0) == 0xF0))
			latch = out[0] & 1;
		if (cs == 0x10 && no && (out[0] & 0xFE) == CMD_IDE_DATA_WR) {
			size_t upto = k < ndw ? dw_at[k] : gn;
			k++;
			port2_blocks += latch;
			for (; gpos + 512 <= upto; gpos += 512) add_block(gp + gpos);
			if (no != 6 + 512) bad_frames++;
			else add_block(out + 6);
		} else if (cs == 0x42 || (cs & 0x02))
			bad_frames++;	/* the card on cfide's SPI */
		(void)ni;
		t = eol + 1;
	}
	for (; gpos + 512 <= gn; gpos += 512) add_block(gp + gpos);
	trace_mark = strlen(all);
}

/* ---- the card and the hardfiles ---- */
static const char *dir;
struct hdfile {
	const char *name;	/* on the card, 8.3 */
	uint8_t *data;
	size_t len;
	unsigned *card_lba;	/* card sector of each block */
};
static struct hdfile files[] = { { "WORK.HDF", 0, 0, 0 }, { "SYNTH.HDF", 0, 0, 0 }, { "ODD.HDF", 0, 0, 0 } };
enum { F_WORK, F_SYNTH, F_ODD };

static uint8_t *slurp(const char *name, size_t *len)
{
	char path[1024];
	snprintf(path, sizeof path, "%s/%s", dir, name);
	FILE *f = fopen(path, "rb");
	if (!f) { say("FAIL cannot open %s\n", path); exit(1); }
	fseek(f, 0, SEEK_END);
	long n = ftell(f);
	fseek(f, 0, SEEK_SET);
	uint8_t *b = malloc((size_t)n ? (size_t)n : 1);
	if (!b || fread(b, 1, (size_t)n, f) != (size_t)n) die("cannot read a file");
	fclose(f);
	*len = (size_t)n;
	return b;
}

static unsigned card_sectors;

/* load the card, bring up mmc.c and fat.c; map every hardfile block to its
   card sector by the block's bytes (independently of fat.c) */
static void card_up(void)
{
	char path[1024];
	struct stat st;
	snprintf(path, sizeof path, "%s/hdd.img", dir);
	mock_reset();
	if (stat(path, &st) || st.st_size % 512) die("no card image of whole sectors");
	card_sectors = (unsigned)(st.st_size / 512);
	if (mock_card_load(path, card_sectors)) die("cannot load the card image");
	mock_script_fn(0x10, gayle_miso, NULL);
	memset(&g, 0, sizeof g);
	g.frame = -1;
	trace_mark = 0;
	if (MMC_Init() != CARDTYPE_SDHC) die("MMC_Init");
	if (!FindDrive()) die("FindDrive");
	for (int k = 0; k < 3; k++) {
		struct hdfile *h = &files[k];
		if (!h->data) {
			char n[64];
			snprintf(n, sizeof n, "hdf/%s", h->name);
			h->data = slurp(n, &h->len);
			h->card_lba = malloc(h->len / 512 * sizeof *h->card_lba);
			if (!h->card_lba) die("out of memory");
			for (size_t b = 0; b < h->len / 512; b++) h->card_lba[b] = UINT_MAX;
		}
	}
	/* rdb.py's blocks carry 'H', file, block number; WORK.HDF's block 0 (its RDB) is searched */
	for (unsigned l = 0; l < card_sectors; l++) {
		const uint8_t *s = mock_card_sector(l);
		if (s[0] != 'H' || s[1] < 1 || s[1] > 3) continue;
		struct hdfile *h = &files[s[1] - 1];
		size_t b = (size_t)s[2] << 8 | s[3];
		if (b < h->len / 512 && !memcmp(s, h->data + b * 512, 512)) h->card_lba[b] = l;
	}
	for (unsigned l = 0; l < card_sectors && files[F_WORK].card_lba[0] == UINT_MAX; l++)
		if (!memcmp(mock_card_sector(l), files[F_WORK].data, 512)) files[F_WORK].card_lba[0] = l;
	for (int k = 0; k < 3; k++)
		for (size_t b = 0; b < files[k].len / 512; b++)
			if (files[k].card_lba[b] == UINT_MAX) { say("FAIL %s block %zu is not on the card\n", files[k].name, b); exit(1); }
}

/* ---- one ATA command through HandleHDD ---- */
static struct unitcase {
	int file;		/* files[], -1: none */
	int type;
	unsigned cyl, heads, secs;
	long offset;
	const uint8_t *rdsk, *part;	/* the expected FakeRDB blocks 0 and 1 */
} uc[2];

static void lba2chs(int unit, long lba, unsigned *c, unsigned *h, unsigned *s)
{
	*s = (unsigned)(lba % uc[unit].secs) + 1;
	*h = (unsigned)(lba / uc[unit].secs % uc[unit].heads);
	*c = (unsigned)(lba / uc[unit].secs / uc[unit].heads);
}

/* the firmware serves a command (the main loop has work for it) */
static int fw_in_command(void)
{
	return hdd_busy();
}

/* one pass of the main loop's disk work (main.c PollDisks, cut out with
   HandleFpga), and the time the rest of the pass takes */
static long passes;
static void loop_pass(void)
{
	struct mock_sdc_peek p;
	if (PollDisks(1))
		in_block_passes++;
	mock_sdc_step();
	look_gerr();
	/* the Amiga writes on DRQ whether the firmware polls or not: a
	   GAYLE_TO_TX started before its sector (T11-R1 broken) waits for it,
	   counted in mock_gayle_stalls, instead of holding the polls off */
	mock_sdc_peek(&p);
	if (p.busy && p.op == 4)
		amiga_try_write();
	passes++;
}

/* the main loop until the firmware and the Amiga are through */
static void run_loop(void)
{
	long n = 0;
	do {
		loop_pass();
		if (++n > 2000000) die("the command never ends (a hang)");
	} while (g.busy || hdd_busy());
}

/* the IRQ check's write: cur_unit, cur_lba (above) */
static unsigned irq_early;	/* IRQ status writes before the group was on the card */

/* the task file of a command on unit 0/1 of port 1: CHS of lba, count byte;
   command_begin only writes it (the Amiga's side), command runs the main
   loop until the firmware and the Amiga are through */
static void command_begin(int unit, unsigned char cmd, long lba, unsigned char count)
{
	unsigned c, h, s;
	lba2chs(unit, lba, &c, &h, &s);
	unsigned char t[8] = { 0, 0, count, (unsigned char)s, (unsigned char)c, (unsigned char)(c >> 8),
	                       (unsigned char)(0xA0 | (unit & 1) << 4 | h), cmd };
	int frame = g.frame;
	const uint8_t *wd = g.wdata;
	size_t wl = g.wlen;
	unsigned gerrs = g.gerrs;
	int multiple = cmd == ACMD_READ_MULTIPLE || cmd == ACMD_WRITE_MULTIPLE;
	free(g.log.p);
	memset(&g, 0, sizeof g);
	g.frame = frame;
	g.wdata = wd;
	g.wlen = wl;
	g.gerrs = gerrs;
	cur_unit = unit;
	cur_lba = lba;
	mock_gayle_into(0, &gay_base[0]);
	mock_gayle_into(1, &gay_base[1]);
	ndw = 0;
	audio_polls = 0;
	full_polls = 0;
	amiga_command(t, count ? count : 256, multiple ? hdf[unit].sectors_per_block : 1);
}

static void command(int unit, unsigned char cmd, long lba, unsigned char count)
{
	command_begin(unit, cmd, lba, count);
	run_loop();
	trace_blocks();
}

/* the block a read of lba on unit returns (hdd.c's mapping) */
static const uint8_t *expect_block(int unit, long lba)
{
	static const uint8_t zero[512];
	long v = lba + uc[unit].offset;
	if (v < 0) return lba == 0 ? uc[unit].rdsk : lba == 1 ? uc[unit].part : zero;
	if (unit == 0 && uc[unit].type == HDF_FILE && lba == 0 && uc[unit].file == F_WORK) return work_rdb_patched;
	return files[uc[unit].file].data + (size_t)v * 512;
}

/* an IRQ status write of a write command (not an error's): every sector the
   firmware took so far is on the card with the Amiga's data and the card is
   idle (programmed: findings/sdcard-engine Task 11a, write-done timing) */
static void status_irq(void)
{
	unsigned k = (unsigned)(consumed() / 512);
	int ok = mock_card_idle(), to_card = 0;
	for (unsigned i = 0; i < k && ok && g.wdata; i++) {
		long v = cur_lba + (long)i + uc[cur_unit].offset;
		if (v >= 0 && uc[cur_unit].file >= 0 &&
		    ((size_t)v >= files[uc[cur_unit].file].len / 512 ||	/* past the end of the file */
		     memcmp(mock_card_sector(files[uc[cur_unit].file].card_lba[v]), g.wdata + (size_t)i * 512, 512)))
			ok = 0;
		if (i >= g.irqs * g.chunk && v >= 0) to_card = 1;	/* this group wrote to the card */
	}
	/* a group that went to the card: a CMD25 run (or more), the stop
	   token's busy over before this status (findings/sdcard-engine 11a) */
	if (to_card && mock_card_stop_ends() == g.stop_mark) ok = 0;
	g.stop_mark = mock_card_stop_ends();
	if (!ok) irq_early++;
}

static void check_taskfile(const char *what, int unit, long last, unsigned char count)
{
	char w[200];
	unsigned c, h, s;
	lba2chs(unit, last, &c, &h, &s);
	snprintf(w, sizeof w, "%s: task file writes", what);
	if (!check(w, g.ntfw, 1)) return;
	unsigned char want[6] = { 0, count, (unsigned char)s, (unsigned char)c, (unsigned char)(c >> 8),
	                          (unsigned char)(0xA0 | (unit & 1) << 4 | h) };
	snprintf(w, sizeof w, "%s: task file (error, count, sector, cyl lo, cyl hi, dh) of lba %ld", what, last);
	check_mem(w, g.tfw[0], want, 6);
}

static void check_gayle(const char *what)
{
	char w[200];
	snprintf(w, sizeof w, "%s: Gayle model (%s)", what, g.err[0] ? g.err : "no error");
	check(w, g.err[0] != 0, 0);
	snprintf(w, sizeof w, "%s: data frames of a wrong length", what);
	check(w, bad_frames, 0);
	snprintf(w, sizeof w, "%s: blocks sent to port 2's FIFO", what);
	check(w, port2_blocks, 0);
	snprintf(w, sizeof w, "%s: CD_AudioPoll (reads IDE flags) inside the command, not CD_AudioRefill", what);
	check(w, full_polls, 0);
	snprintf(w, sizeof w, "%s: no FPGA frame (IDE command) while a Gayle op runs", what);
	check(w, (long)mock_gayle_cs_violations(), 0);
	snprintf(w, sizeof w, "%s: no HandleFpga (floppy) work inside a part-delivered READ group", what);
	check(w, fdd_in_block, 0);
	snprintf(w, sizeof w, "%s: no Gayle op started before its data was there (T11-R1)", what);
	check(w, (long)mock_gayle_stalls(), 0);
	snprintf(w, sizeof w, "%s: the firmware done (no HDD state machine, no card op left)", what);
	check(w, hdd_busy() || sd_poll(), 0);
}

static void set_multiple(int unit, unsigned char n)
{
	char w[80];
	command(unit, ACMD_SET_MULTIPLE_MODE, 0, n);
	snprintf(w, sizeof w, "SET MULTIPLE MODE %u: sectors_per_block", n);
	check(w, hdf[unit].sectors_per_block, n);
	snprintf(w, sizeof w, "SET MULTIPLE MODE %u: status", n);
	check(w, g.nstatus == 1 ? g.status[0] : -1, IDE_STATUS_END | IDE_STATUS_IRQ);
}

/* the disk statistics (diskstat.c) of one command: diskstat_mark() before
   it, diskstat_check() after.  One count in the bucket of n sectors of its
   direction and no other; the Amiga polls are the HDD path's status polls
   of its waits for the FIFO (one per main-loop pass of a wait,
   findings/sdcard-engine Task 11a): at least one per wait, at most the
   status polls Gayle saw */
static unsigned ds_hist[2][DISKSTAT_BUCKETS], ds_amiga;
static unsigned ds_amiga_polls(void)
{
	unsigned n = 0;
	mock_uart_clear();
	diskstat_report();
	const char *p = strstr(mock_uart(), "amiga polls ");
	if (!p || sscanf(p, "amiga polls %u", &n) != 1) die("no amiga polls in diskstat_report()");
	mock_uart_clear();
	return n;
}
static void diskstat_mark(void)
{
	memcpy(ds_hist, diskstat_hist, sizeof ds_hist);
	ds_amiga = ds_amiga_polls();
}
static void diskstat_check(const char *what, int write, int n, int waits)
{
	char w[200];
	int b = n <= 1 ? 0 : n <= 2 ? 1 : n <= 4 ? 2 : n <= 8 ? 3 : n <= 16 ? 4 : n <= 64 ? 5 : 6;
	int other = 0;
	for (int d = 0; d < 2; d++)
		for (int i = 0; i < DISKSTAT_BUCKETS; i++)
			if ((d != write || i != b) && diskstat_hist[d][i] != ds_hist[d][i]) other = 1;
	snprintf(w, sizeof w, "%s: diskstat bucket %d of %s", what, b, write ? "w" : "r");
	check(w, (long)(diskstat_hist[write][b] - ds_hist[write][b]), 1);
	snprintf(w, sizeof w, "%s: diskstat no other bucket", what);
	check(w, other, 0);
	snprintf(w, sizeof w, "%s: diskstat amiga polls >= the waits", what);
	check(w, (long)(ds_amiga_polls() - ds_amiga) >= waits, 1);
	snprintf(w, sizeof w, "%s: diskstat amiga polls <= Gayle's status polls", what);
	check(w, (long)(ds_amiga_polls() - ds_amiga) <= (long)g.polls, 1);
}

/* a READ SECTORS / READ MULTIPLE of n sectors (count byte n & 255) at lba */
static void read_case(const char *what, int unit, int multiple, long lba, int n)
{
	char w[200];
	int spb = hdf[unit].sectors_per_block;
	diskstat_mark();
	cur_case = what;
	command(unit, multiple ? ACMD_READ_MULTIPLE : ACMD_READ_SECTORS, lba, (unsigned char)n);
	cur_case = "";
	check_gayle(what);
	check_taskfile(what, unit, lba + n - 1, (unsigned char)n);
	snprintf(w, sizeof w, "%s: blocks sent", what);
	if (check(w, nblocks, n))
		for (int i = 0; i < n; i++) {
			snprintf(w, sizeof w, "%s: block %d (lba %ld)", what, i, lba + i);
			check_mem(w, blocks[i], expect_block(unit, lba + i), 512);
		}
	/* chunks: multiple -> spb sectors (the last one the rest), else 1 */
	int per = multiple ? spb : 1, want_chunks = (n + per - 1) / per;
	snprintf(w, sizeof w, "%s: chunks", what);
	if (check(w, g.nchunks, want_chunks))
		for (int i = 0; i < want_chunks; i++) {
			snprintf(w, sizeof w, "%s: chunk %d", what, i);
			check(w, g.chunks[i], i < want_chunks - 1 ? per : n - per * (want_chunks - 1));
		}
	snprintf(w, sizeof w, "%s: status writes", what);
	if (check(w, g.nstatus, want_chunks))
		for (int i = 0; i < g.nstatus; i++) {
			snprintf(w, sizeof w, "%s: status write %d", what, i);
			check(w, g.status[i], IDE_STATUS_RDY);
		}
	snprintf(w, sizeof w, "%s: CD audio refills while the FIFO drains (the main loop ran)", what);
	check(w, audio_polls >= want_chunks - 1, 1);
	diskstat_check(what, 0, n, want_chunks);
}

/* SET MULTIPLE MODE with a count IDENTIFY does not offer (word 47: 16):
   ABRT -- error register 0x04, END | IRQ | ERR -- and the mode stays, so the
   next READ MULTIPLE runs in groups of the old count (final review M7: a
   group of more than 16 sectors overflowed Gayle's FIFO with good status).
   16 is accepted, 0 too (multiple mode off, as before) */
static void set_multiple_abrt_cases(void)
{
	static const unsigned char bad[] = { 17, 32, 128, 255 };
	char w[120];
	set_multiple(1, 4);
	for (unsigned i = 0; i < sizeof bad; i++) {
		unsigned char n = bad[i];
		mock_uart_clear();
		command(1, ACMD_SET_MULTIPLE_MODE, 0, n);
		check_gayle("SET MULTIPLE MODE > 16");
		snprintf(w, sizeof w, "SET MULTIPLE MODE %u: status END | IRQ | ERR only", n);
		check(w, g.nstatus == 1 && g.status[0] == (IDE_STATUS_END | IDE_STATUS_IRQ | IDE_STATUS_ERR), 1);
		snprintf(w, sizeof w, "SET MULTIPLE MODE %u: one task file write, error register ABRT (0x04), count kept", n);
		check(w, g.ntfw == 1 && g.tfw[0][0] == 0x04 && g.tfw[0][1] == n, 1);
		snprintf(w, sizeof w, "SET MULTIPLE MODE %u: sectors_per_block stays 4", n);
		check(w, hdf[1].sectors_per_block, 4);
		snprintf(w, sizeof w, "SET MULTIPLE MODE %u: the UART line", n);
		char line[48];
		snprintf(line, sizeof line, "Set Multiple Mode %u: ABRT\r", n);
		check(w, strstr(mock_uart(), line) != NULL, 1);
	}
	read_case("WORK.HDF READ MULTIPLE 1000+10 after SET MULTIPLE 32 was refused (groups of 4)", 1, 1, 1000, 10);
	set_multiple(1, 16);
	read_case("WORK.HDF READ MULTIPLE 1000+20 after SET MULTIPLE 16 (groups of 16)", 1, 1, 1000, 20);
	set_multiple(1, 0);
	command(1, ACMD_READ_MULTIPLE, 1000, 4);
	check_gayle("READ MULTIPLE with multiple mode off");
	check("READ MULTIPLE with multiple mode off: no block", nblocks, 0);
	check("READ MULTIPLE with multiple mode off: ABRT (0x04), END | IRQ | ERR",
	      g.nstatus == 1 && g.status[0] == (IDE_STATUS_END | IDE_STATUS_IRQ | IDE_STATUS_ERR) &&
	      g.ntfw >= 1 && g.tfw[g.ntfw - 1][0] == 0x04, 1);
	set_multiple(1, 16);
}

static void card_log_mark(void);
static int card_log_count(const char *needle);
static int clusters(long a, long n);

/* a WRITE SECTORS / WRITE MULTIPLE of n sectors of data at lba: the card
   afterwards is the card before with the written file blocks replaced */
static void write_case(const char *what, int unit, int multiple, long lba, int n, const uint8_t *data)
{
	char w[200];
	int spb = hdf[unit].sectors_per_block;
	size_t bytes = (size_t)card_sectors * 512;
	uint8_t *want = malloc(bytes);
	if (!want) die("out of memory");
	for (unsigned l = 0; l < card_sectors; l++) memcpy(want + (size_t)l * 512, mock_card_sector(l), 512);
	for (int i = 0; i < n; i++) {
		long v = lba + i + uc[unit].offset;
		if (v >= 0) memcpy(want + (size_t)files[uc[unit].file].card_lba[v] * 512, data + (size_t)i * 512, 512);
	}
	g.wdata = data;
	g.wlen = (size_t)n * 512;
	ClearError(ERROR_ALL);
	diskstat_mark();
	card_log_mark();
	cur_case = what;
	command(unit, multiple ? ACMD_WRITE_MULTIPLE : ACMD_WRITE_SECTORS, lba, (unsigned char)n);
	cur_case = "";
	if (uc[unit].file == F_WORK && !cd_refill_card && !cd_playing) {
		/* WORK.HDF (offset 0, contiguous): one CMD25 run per cluster of
		   each group, none split by the park bound (the Amiga keeps up) */
		int per = multiple ? spb : 1, runs = 0;
		for (long a = lba; a < lba + n; a += per)
			runs += clusters(a, a + per <= lba + n ? per : lba + n - a);
		snprintf(w, sizeof w, "%s: CMD25 runs: one per cluster of each group", what);
		check(w, card_log_count("CMD25 arg="), runs);
	}
	diskstat_check(what, 1, n, n);	/* one wait per block */
	check_gayle(what);
	check_taskfile(what, unit, lba + n - 1, (unsigned char)n);
	snprintf(w, sizeof w, "%s: sectors read from the FIFO", what);
	check(w, (long)consumed(), (long)n * 512);
	snprintf(w, sizeof w, "%s: every IRQ after its group was programmed (the card idle, the data on it)", what);
	check(w, irq_early, 0);
	int per = multiple ? spb : 1, want_chunks = (n + per - 1) / per;
	snprintf(w, sizeof w, "%s: status writes", what);
	if (check(w, g.nstatus, 1 + want_chunks)) {
		snprintf(w, sizeof w, "%s: status write 0", what);
		check(w, g.status[0], IDE_STATUS_REQ);
		for (int i = 1; i <= want_chunks; i++) {
			snprintf(w, sizeof w, "%s: status write %d", what, i);
			check(w, g.status[i], i < want_chunks ? IDE_STATUS_IRQ : (IDE_STATUS_END | IDE_STATUS_IRQ));
		}
	}
	for (unsigned l = 0; l < card_sectors; l++) {
		if (memcmp(mock_card_sector(l), want + (size_t)l * 512, 512)) {
			snprintf(w, sizeof w, "%s: card sector %u", what, l);
			check_mem(w, mock_card_sector(l), want + (size_t)l * 512, 512);
			break;
		}
	}
	cases++;
	free(want);
	for (int i = 0; i < n; i++) {	/* the file now holds the data: later reads expect it */
		long v = lba + i + uc[unit].offset;
		if (v >= 0) memcpy(files[uc[unit].file].data + (size_t)v * 512, data + (size_t)i * 512, 512);
	}
	g.wdata = NULL;
	g.wlen = 0;
}

static void open_unit(int unit, int f, int type, const char *name8)
{
	char w[120];
	hardfileTYPE *hf = SlotConfig(unit);
	memset(hf, 0, sizeof *hf);
	hf->enabled = (unsigned char)type;
	memcpy(hf->name, name8, 8);
	config.hdfdir[unit] = 0;
	snprintf(w, sizeof w, "OpenHardfile(%d) %s", unit, files[f].name);
	check(w, OpenHardfile((unsigned)unit), 1);
	uc[unit].file = f;
	uc[unit].type = type;
	uc[unit].cyl = hdf[unit].cylinders;
	uc[unit].heads = hdf[unit].heads;
	uc[unit].secs = hdf[unit].sectors;
	uc[unit].offset = hdf[unit].offset;
	uc[unit].rdsk = uc[unit].part = NULL;
}

/* ---- FakeRDB ---- */
#define RDB_CASE(n, size, c, h, s, off) { #n, size, c, h, s, off, rdb_rdsk_##n, rdb_part_##n }
static const struct rdbcase {
	const char *name;
	unsigned long size;
	unsigned cyl, heads, secs;
	long offset;
	const uint8_t *rdsk, *part;
} rdbcases[] = { RDB_CASE_SMALL, RDB_CASE_BIG, RDB_CASE_ODD };

static void fakerdb_cases(void)
{
	char w[200];
	for (size_t k = 0; k < sizeof rdbcases / sizeof rdbcases[0]; k++) {
		const struct rdbcase *r = &rdbcases[k];
		for (int unit = 0; unit < 2; unit++) {
			/* hdf[] as OpenHardfile sets it up for a SYNTHRDB file of this size */
			memset(&hdf[unit], 0, sizeof hdf[unit]);
			hdf[unit].type = HDF_FILE | HDF_SYNTHRDB;
			hdf[unit].file.size = r->size;
			GetHardfileGeometry(&hdf[unit]);
			hdf[unit].offset = -(hdf[unit].heads * hdf[unit].sectors);
			snprintf(w, sizeof w, "FakeRDB %s: geometry (cylinders)", r->name);
			check(w, hdf[unit].cylinders, r->cyl);
			snprintf(w, sizeof w, "FakeRDB %s: geometry (heads)", r->name);
			check(w, hdf[unit].heads, r->heads);
			snprintf(w, sizeof w, "FakeRDB %s: geometry (sectors)", r->name);
			check(w, hdf[unit].sectors, r->secs);
			uc[unit] = (struct unitcase){ -1, HDF_FILE | HDF_SYNTHRDB, r->cyl, r->heads, r->secs, r->offset, r->rdsk, r->part };
			command(unit, ACMD_READ_SECTORS, 0, 2);
			check_gayle(r->name);
			snprintf(w, sizeof w, "FakeRDB %s unit %d: blocks", r->name, unit);
			if (check(w, nblocks, 2)) {
				snprintf(w, sizeof w, "FakeRDB %s RDSK (unit %d)", r->name, unit);
				check_mem(w, blocks[0], r->rdsk, 512);
				snprintf(w, sizeof w, "FakeRDB %s PART (unit %d)", r->name, unit);
				check_mem(w, blocks[1], r->part, 512);
			}
		}
	}
}

/* ---- IDENTIFY DEVICE ---- */
static const struct identcase {
	const char *what;
	int type, partition;
	unsigned cyl, heads, secs;
	unsigned char name[8], long_name[16];
	const uint8_t *stream;
} identcases[] = { IDENT_CASES };

static void identify_cases(void)
{
	char w[200];
	for (size_t k = 0; k < sizeof identcases / sizeof identcases[0]; k++) {
		const struct identcase *c = &identcases[k];
		int unit = (int)(k & 1);
		memset(&hdf[unit], 0, sizeof hdf[unit]);
		hdf[unit].type = c->type;
		hdf[unit].partition = (unsigned short)c->partition;
		hdf[unit].cylinders = (unsigned short)c->cyl;
		hdf[unit].heads = (unsigned short)c->heads;
		hdf[unit].sectors = (unsigned short)c->secs;
		hardfileTYPE *hf = SlotConfig(unit);
		memset(hf, 0, sizeof *hf);
		hf->enabled = (unsigned char)c->type;
		memcpy(hf->name, c->name, 8);
		memcpy(hf->long_name, c->long_name, 16);
		uc[unit] = (struct unitcase){ -1, c->type, c->cyl, c->heads, c->secs, 0, NULL, NULL };
		command(unit, ACMD_IDENTIFY_DEVICE, 0, 1);
		check_gayle(c->what);
		snprintf(w, sizeof w, "IDENTIFY %s: data blocks", c->what);
		if (check(w, nblocks, 1)) {
			snprintf(w, sizeof w, "IDENTIFY %s", c->what);
			check_mem(w, blocks[0], c->stream, 512);
		}
		snprintf(w, sizeof w, "IDENTIFY %s: status writes RDY, END|IRQ", c->what);
		check(w, g.nstatus == 2 && g.status[0] == IDE_STATUS_RDY && g.status[1] == (IDE_STATUS_END | IDE_STATUS_IRQ), 1);
	}
}

/* card errors (findings/sdcard-engine Task 10): the card stops answering
   (the card-detect pin still says present): a READ and a WRITE end with
   END | IRQ | ERR and no block, ERROR_SDCARD is set (not fatal), the card
   is not written; with the card back the next command initialises it
   again.  A read the Amiga abandons (Gayle error on the first word): no
   status at all, no error, the card still in use. */
static uint8_t *wpattern(int n, int seed);
static void error_cases(void)
{
	char w[200];
	static const unsigned char err = IDE_STATUS_END | IDE_STATUS_IRQ | IDE_STATUS_ERR;
	uint8_t *d = wpattern(2, 9), *before = malloc((size_t)card_sectors * 512);
	int same = 1;
	if (!before) die("out of memory");
	for (unsigned l = 0; l < card_sectors; l++) memcpy(before + (size_t)l * 512, mock_card_sector(l), 512);
	ClearError(ERROR_ALL);
	mock_card_remove();
	command(1, ACMD_READ_SECTORS, 600, 2);
	check_gayle("card gone: READ SECTORS 600+2");
	check("card gone: READ: no block", nblocks, 0);
	check("card gone: READ: status RDY, then END | IRQ | ERR", g.nstatus == 2 && g.status[0] == IDE_STATUS_RDY && g.status[1] == err, 1);
	check("card gone: READ: the error register UNC (0x40)", g.ntfw == 2 ? g.tfw[1][0] : -1, 0x40);
	check("card gone: READ: ERROR_SDCARD set", (ErrorMask >> ERROR_SDCARD) & 1, 1);
	check("card gone: READ: not fatal", ErrorFatal, 0);
	ClearError(ERROR_ALL);
	g.wdata = d;
	g.wlen = 1024;
	command(1, ACMD_WRITE_SECTORS, 600, 2);
	check_gayle("card gone: WRITE SECTORS 600+2");
	check("card gone: WRITE: status REQ, then END | IRQ | ERR", g.nstatus == 2 && g.status[0] == IDE_STATUS_REQ && g.status[1] == err, 1);
	check("card gone: WRITE: the error register ABRT (0x04)", g.ntfw == 2 ? g.tfw[1][0] : -1, 0x04);
	check("card gone: WRITE: ERROR_SDCARD set", (ErrorMask >> ERROR_SDCARD) & 1, 1);
	for (unsigned l = 0; l < card_sectors; l++) same &= !memcmp(before + (size_t)l * 512, mock_card_sector(l), 512);
	check("card gone: WRITE: the card unchanged", same, 1);
	g.wdata = NULL;
	g.wlen = 0;
	ClearError(ERROR_ALL);
	mock_card_insert();
	read_case("card back: WORK.HDF READ SECTORS 600+2 (initialised again)", 1, 0, 600, 2);
	snprintf(w, sizeof w, "card back: no error");
	check(w, ErrorMask, 0);
	mock_gayle_end(MOCK_GAYLE_ERR, 0);
	command(1, ACMD_READ_SECTORS, 610, 2);
	check_gayle("abandoned: READ SECTORS 610+2");
	check("abandoned: no block", nblocks, 0);
	check("abandoned: status RDY only (none for the old command)", g.nstatus == 1 && g.status[0] == IDE_STATUS_RDY, 1);
	check("abandoned: no error", ErrorMask, 0);
	read_case("after the abandon: WORK.HDF READ SECTORS 610+2", 1, 0, 610, 2);
	free(before);
	free(d);
}

/* sectors past the end of the HDF (findings/sdcard-engine Task 10 fix
   round 2; a truncated HDF, an RDB whose partitions run past the file):
   END | IRQ | ERR before any sector is served or written, the card
   unchanged (WORK.HDF is 8192 sectors) */
static void past_end_cases(void)
{
	static const unsigned char err = IDE_STATUS_END | IDE_STATUS_IRQ | IDE_STATUS_ERR;
	uint8_t *d = wpattern(2, 11), *before = malloc((size_t)card_sectors * 512);
	int same = 1;
	if (!before) die("out of memory");
	for (unsigned l = 0; l < card_sectors; l++) memcpy(before + (size_t)l * 512, mock_card_sector(l), 512);
	ClearError(ERROR_ALL);
	command(1, ACMD_READ_SECTORS, 8191, 2);
	check_gayle("past the end: READ SECTORS 8191+2");
	check("past the end: READ SECTORS 8191+2: no block", nblocks, 0);
	check("past the end: READ SECTORS 8191+2: status END | IRQ | ERR only", g.nstatus == 1 && g.status[0] == err, 1);
	check("past the end: READ SECTORS 8191+2: the error register IDNF (0x10)", g.ntfw == 2 ? g.tfw[1][0] : -1, 0x10);
	set_multiple(1, 4);
	command(1, ACMD_READ_MULTIPLE, 8190, 4);
	check_gayle("past the end: READ MULTIPLE 8190+4");
	check("past the end: READ MULTIPLE 8190+4: no block", nblocks, 0);
	check("past the end: READ MULTIPLE 8190+4: status END | IRQ | ERR only", g.nstatus == 1 && g.status[0] == err, 1);
	set_multiple(1, 16);
	g.wdata = d;
	g.wlen = 1024;
	command(1, ACMD_WRITE_SECTORS, 8191, 2);
	check_gayle("past the end: WRITE SECTORS 8191+2");
	check("past the end: WRITE SECTORS 8191+2: status REQ, then END | IRQ | ERR", g.nstatus == 2 && g.status[0] == IDE_STATUS_REQ && g.status[1] == err, 1);
	check("past the end: WRITE SECTORS 8191+2: the error register IDNF (0x10)", g.ntfw == 2 ? g.tfw[1][0] : -1, 0x10);
	check("past the end: WRITE SECTORS 8191+2: no sector taken from the FIFO", (long)consumed(), 0);
	for (unsigned l = 0; l < card_sectors; l++) same &= !memcmp(before + (size_t)l * 512, mock_card_sector(l), 512);
	check("past the end: WRITE SECTORS 8191+2: the card unchanged", same, 1);
	g.wdata = NULL;
	g.wlen = 0;
	check("past the end: no card error", (ErrorMask >> ERROR_SDCARD) & 1, 0);
	/* commands that end at the file's last sector are good: a write (both
	   sectors on the card, the end of the chain after the last one is no
	   error) and the reads back */
	write_case("WORK.HDF WRITE SECTORS 8190+2 (ends at the file's last sector)", 1, 0, 8190, 2, d);
	read_case("WORK.HDF READ SECTORS 8190+2 after the write", 1, 0, 8190, 2);
	read_case("WORK.HDF READ SECTORS 8191+1 (the last sector)", 1, 0, 8191, 1);
	free(before);
	free(d);
}

/* a cluster chain shorter than the file's size (findings/sdcard-engine
   Task 10 fix round 3): WORK.HDF's chain cut after its block 4095 in the
   card's first FAT: BuildHardfileIndex refuses it, OpenHardfile fails with
   ERROR_HDD and the unit is off; with the FAT back the file opens again */
extern unsigned long fat_start, data_start, buffered_fat_index;
static void short_chain_case(void)
{
	const struct hdfile *h = &files[F_WORK];
	unsigned long cl = (h->card_lba[4095] - data_start) / cluster_size + 2;
	unsigned long off = cl * (fat32 ? 4 : 2);
	unsigned char *fs = mock_card_wsector((unsigned)(fat_start + off / 512)), save[4];
	memcpy(save, fs + off % 512, 4);
	memset(fs + off % 512, 0xFF, fat32 ? 4 : 2);	/* EOC (FAT32: the low 28 bits all set) */
	if (fat32) fs[off % 512 + 3] = 0x0F;
	buffered_fat_index = -1;
	ClearError(ERROR_ALL);
	hardfileTYPE *hf = SlotConfig(1);
	memset(hf, 0, sizeof *hf);
	hf->enabled = HDF_FILE;
	memcpy(hf->name, "WORK    ", 8);
	config.hdfdir[1] = 0;
	check("short chain: OpenHardfile(1) fails", OpenHardfile(1), 0);
	check("short chain: the unit is off", hdf[1].type, HDF_DISABLED);
	check("short chain: ERROR_HDD set", (ErrorMask >> ERROR_HDD) & 1, 1);
	check("short chain: the message", Errors[ERROR_HDD].string && !strcmp(Errors[ERROR_HDD].string, "Hardfile index read error"), 1);
	memcpy(fs + off % 512, save, 4);
	buffered_fat_index = -1;
	ClearError(ERROR_ALL);
	open_unit(1, F_WORK, HDF_FILE, "WORK    ");
}

/* rd_multi_order: the Amiga-visible order of a READ MULTIPLE 32 in groups
   of 16 (task file, status writes, the Amiga's reads) against the golden
   recorded on the firmware before findings/sdcard-engine Task 11a (the
   synchronous HDD path, f8e2f43b) with this model; HDD_GOLD_WRITE=1 writes
   the golden instead (the record, not a check) */
static void rd_multi_order(const char *golden)
{
	char want[4096];
	size_t n = 0;
	FILE *f;
	set_multiple(1, 16);
	read_case("rd_multi_order: WORK.HDF READ MULTIPLE 2000+32", 1, 1, 2000, 32);
	if (!golden) die("rd_multi_order: no golden file argument");
	if (getenv("HDD_GOLD_WRITE")) {
		f = fopen(golden, "w");
		if (!f || fputs(g.log.p, f) < 0 || fclose(f)) die("rd_multi_order: cannot write the golden");
		say("rd_multi_order: golden written to %s\n", golden);
		return;
	}
	f = fopen(golden, "r");
	if (!f) die("rd_multi_order: no golden");
	n = fread(want, 1, sizeof want - 1, f);
	fclose(f);
	want[n] = 0;
	cases++;
	if (strcmp(g.log.p ? g.log.p : "", want)) {
		say("FAIL rd_multi_order: the Gayle trace differs from %s\n--- got\n%s--- want\n%s", golden,
		    g.log.p ? g.log.p : "", want);
		fails++;
	}
}

/* ---- the interrupt-driven HDD data path (findings/sdcard-engine Task 11a) */

/* the card's command log since a mark: the CMD25 lines */
static size_t log_mark;
static void card_log_mark(void) { log_mark = strlen(mock_card_log()); }
static int card_log_has(const char *needle) { return strstr(mock_card_log() + log_mark, needle) != NULL; }
static int card_log_count(const char *needle)
{
	int n = 0;
	for (const char *p = mock_card_log() + log_mark; (p = strstr(p, needle)); p++) n++;
	return n;
}
/* the lines of the Gayle log after the last line `after` */
static const char *log_after(const char *after)
{
	const char *p = g.log.p ? g.log.p : "", *q, *at = NULL;
	for (q = p; (q = strstr(q, after)); q++) at = q;
	return at ? at + strlen(after) : NULL;
}
/* the file blocks lba.. of unit 1 (WORK.HDF) hold d now (after a write the
   test drove by hand) */
static void file_now(long lba, const uint8_t *d, unsigned n)
{
	for (unsigned i = 0; i < n; i++)
		memcpy(files[uc[1].file].data + (size_t)(lba + i + uc[1].offset) * 512, d + (size_t)i * 512, 512);
}
static int card_has(long lba, const uint8_t *d, unsigned n)
{
	for (unsigned i = 0; i < n; i++)
		if (memcmp(mock_card_sector(files[uc[1].file].card_lba[lba + i + uc[1].offset]), d + (size_t)i * 512, 512))
			return 0;
	return 1;
}
/* passes of the main loop until cond() or n passes */
static long run_until(int (*cond)(void), long n)
{
	long k = 0;
	while (k < n && !cond()) { loop_pass(); k++; }
	return k;
}
static int card_and_sd_idle(void) { return mock_card_idle() && !sd_poll() && !g.busy; }
static int fw_idle(void) { return !hdd_busy() && !sd_poll(); }
/* the command was picked up (a status written) and the firmware is idle again */
static int cmd_over(void) { return g.nstatus && fw_idle(); }
/* the old command abandoned, the new one served: the firmware idle, the Amiga done */
static int cmd_over_both(void) { return !g.next.on && !g.busy && fw_idle(); }
static int never(void) { return 0; }
static int count_lines(const char *t)
{
	int n = 0;
	for (; *t; t++) n += *t == '\n';
	return n;
}

/* every IRQ only after its group was programmed: the stop token's busy
   over (a slow card: 20000 busy bytes, 8.5 ms at div 2, per block) */
static void wr_irq_after_program(void)
{
	uint8_t *d = wpattern(40, 31);
	set_multiple(1, 16);
	mock_card_params(4, 20000, 1, 2);
	write_case("wr_irq_after_program: WORK.HDF WRITE MULTIPLE 3500+40 (busy 20000 bytes)", 1, 1, 3500, 40, d);
	check("wr_irq_after_program: three IRQs (16, 16, 8)", g.irqs, 3);
	mock_card_params(4, 8, 1, 2);
	free(d);
}

/* clusters of WORK.HDF (offset 0, file sector = LBA) sectors [a, a + n) touch */
static int clusters(long a, long n) { return (int)((a + n - 1) / cluster_size - a / cluster_size + 1); }

/* a group over cluster boundaries: a CMD25 run up to each boundary, the
   next one from it (the file is contiguous on this card: one run would
   write the right sectors too, the runs' starts are the check) */
static void wr_cluster_split(void)
{
	char w[200];
	long lba = 4L * cluster_size - 3, b;	/* WORK.HDF: offset 0 */
	uint8_t *d = wpattern(8, 33);
	int starts = 1;
	set_multiple(1, 16);
	card_log_mark();
	write_case("wr_cluster_split: WORK.HDF WRITE MULTIPLE over a cluster boundary", 1, 1, lba, 8, d);
	snprintf(w, sizeof w, "CMD25 arg=%08x\n", files[uc[1].file].card_lba[lba]);
	check("wr_cluster_split: a run from the first sector", card_log_has(w), 1);
	for (b = 4L * cluster_size; b < lba + 8; b += cluster_size) {
		snprintf(w, sizeof w, "CMD25 arg=%08x\n", files[uc[1].file].card_lba[b]);
		starts &= card_log_has(w);
	}
	check("wr_cluster_split: a run from each cluster boundary", starts, 1);
	check("wr_cluster_split: one run per cluster", card_log_count("CMD25 arg="), clusters(lba, 8));
	free(d);
}

/* the card pulled while the Amiga writes the 19th of 32 sectors (the 2nd
   group's run): no hang, END | IRQ | ERR with ABRT, ERROR_SDCARD, Gayle's
   port free; with the card back the firmware's restart (MMC_Init) works */
static void wr_card_gone(void)
{
	uint8_t *d = wpattern(32, 35);
	struct mock_sdc_peek p;
	long n;
	set_multiple(1, 16);
	ClearError(ERROR_ALL);
	g.wdata = d;
	g.wlen = 32 * 512;
	command_begin(1, ACMD_WRITE_MULTIPLE, 4700, 32);
	g.hook = HOOK_PULL;
	g.hook_at = 18;
	n = run_until(cmd_over, 200000);
	check("wr_card_gone: the command ended (no hang)", n < 200000 && cmd_over(), 1);
	check_gayle("wr_card_gone");
	check("wr_card_gone: status END | IRQ | ERR last", g.nstatus ? g.status[g.nstatus - 1] : -1,
	      IDE_STATUS_END | IDE_STATUS_IRQ | IDE_STATUS_ERR);
	check("wr_card_gone: the error register ABRT", g.ntfw ? g.tfw[g.ntfw - 1][0] : -1, 0x04);
	check("wr_card_gone: the 1st group's IRQ came", g.irqs, 1);
	check("wr_card_gone: ERROR_SDCARD set", (ErrorMask >> ERROR_SDCARD) & 1, 1);
	mock_sdc_peek(&p);
	check("wr_card_gone: no Gayle op running (the port is free)", p.busy, 0);
	check("wr_card_gone: the 1st group (its IRQ came) on the card", card_has(4700, d, 16), 1);
	check("wr_card_gone: the 19th not", card_has(4718, d + 18 * 512, 1), 0);
	file_now(4700, d, 16);
	for (long l = 4716; l < 4718; l++)	/* the 2nd group's run was cut: what the card has */
		memcpy(files[uc[1].file].data + (size_t)l * 512, mock_card_sector(files[uc[1].file].card_lba[l]), 512);
	g.busy = 0;	/* the Amiga goes on */
	g.wdata = NULL;
	g.wlen = 0;
	mock_card_insert();
	mock_sdc_cd(1);
	mock_run(2000000);	/* the debounce */
	ClearError(ERROR_ALL);
	check("wr_card_gone: card back: MMC_Init", MMC_Init(), CARDTYPE_SDHC);
	check("wr_card_gone: card back: FindDrive", FindDrive(), 1);
	open_unit(1, F_WORK, HDF_FILE, "WORK    ");
	set_multiple(1, 16);
	write_case("wr_card_gone: after the restart: WRITE MULTIPLE 4718+14", 1, 1, 4718, 14, d + 18 * 512);
	check("wr_card_gone: after the restart: no error", ErrorMask, 0);
	free(d);
}

/* the Amiga abandons the command while the bridge moves its 6th sector (a
   new command resets the FIFO: g_err after 100 words): no partial block on
   the card, no status for the old command, the engine idle; the next
   command is served */
static void wr_abandon(void)
{
	uint8_t *d = wpattern(16, 37);
	const char *after;
	long n;
	set_multiple(1, 16);
	ClearError(ERROR_ALL);
	g.wdata = d;
	g.wlen = 16 * 512;
	command_begin(1, ACMD_WRITE_MULTIPLE, 4800, 16);
	g.hook = HOOK_ABANDON;
	g.hook_at = 5;
	n = run_until(cmd_over, 200000);
	check("wr_abandon: the firmware idle again", n < 200000 && cmd_over(), 1);
	check_gayle("wr_abandon");
	after = log_after("abandon\n");
	check("wr_abandon: no status after the abandon", after && !strstr(after, "st "), 1);
	check("wr_abandon: the 5 sectors before it on the card", card_has(4800, d, 5), 1);
	check("wr_abandon: no partial block: the 6th untouched", card_has(4805, files[uc[1].file].data + 4805 * 512, 1), 1);
	check("wr_abandon: nothing after it", card_has(4806, files[uc[1].file].data + 4806 * 512, 10), 1);
	check("wr_abandon: the card idle (the run ended)", mock_card_idle(), 1);
	check("wr_abandon: no error", ErrorMask, 0);
	file_now(4800, d, 5);
	g.wdata = NULL;
	g.wlen = 0;
	read_case("wr_abandon: the next command: READ SECTORS 4800+8", 1, 0, 4800, 8);
	free(d);
}

/* Ctrl-Amiga-Amiga in the middle of a CMD25 run (the 2nd group's 5th
   sector never comes): the firmware ends the run cleanly (stop token, the
   card idle) and writes no status for the old command; the Amiga's next
   command (after the reset) is served.  Then a reset while the card
   programs a write's last group: no END for it either. */
static void wr_reset_mid_run(void)
{
	uint8_t *d = wpattern(32, 39);
	const char *after;
	unsigned stops;
	long n;
	set_multiple(1, 16);
	ClearError(ERROR_ALL);
	g.wdata = d;
	g.wlen = 32 * 512;
	stops = mock_card_stop_ends();
	command_begin(1, ACMD_WRITE_MULTIPLE, 4900, 32);
	g.hook = HOOK_RESET;
	g.hook_at = 20;
	n = run_until(card_and_sd_idle, 200000);
	check("wr_reset_mid_run: the run ended on the card", n < 200000 && card_and_sd_idle(), 1);
	check("wr_reset_mid_run: by a stop token after the reset", mock_card_stop_ends() > g.stops_at_reset, 1);
	check("wr_reset_mid_run: the 1st group's runs ended before it", g.stops_at_reset > stops, 1);
	check("wr_reset_mid_run: the 20 sectors before the reset on the card", card_has(4900, d, 20), 1);
	check("wr_reset_mid_run: nothing after them", card_has(4920, files[uc[1].file].data + 4920 * 512, 12), 1);
	n = run_until(never, 50);	/* the Amiga boots: the old command waits for a sector that never comes */
	after = log_after("reset\n");
	check("wr_reset_mid_run: no status after the reset", after && !strstr(after, "st "), 1);
	check("wr_reset_mid_run: no FPGA frame while a Gayle op runs", (long)mock_gayle_cs_violations(), 0);
	check("wr_reset_mid_run: no Gayle op started before its data was there", (long)mock_gayle_stalls(), 0);
	file_now(4900, d, 20);
	g.wdata = NULL;
	g.wlen = 0;
	read_case("wr_reset_mid_run: the next command after the reset: READ MULTIPLE 4900+24", 1, 1, 4900, 24);
	check("wr_reset_mid_run: no error", ErrorMask, 0);
	/* the reset while the last group is programmed */
	mock_card_params(4, 20000, 1, 2);
	g.wdata = d;
	g.wlen = 2 * 512;
	command_begin(1, ACMD_WRITE_MULTIPLE, 4950, 2);
	g.hook = HOOK_RESET_END;
	n = run_until(cmd_over, 200000);
	check("wr_reset_end: the firmware idle", n < 200000 && cmd_over(), 1);
	after = log_after("reset\n");
	check("wr_reset_end: the reset came during the programming", after != NULL, 1);
	check("wr_reset_end: no END for the old command", after && !strstr(after, "st "), 1);
	check("wr_reset_end: both sectors programmed", card_has(4950, d, 2), 1);
	check("wr_reset_end: the card idle", mock_card_idle(), 1);
	file_now(4950, d, 2);
	mock_card_params(4, 8, 1, 2);
	g.wdata = NULL;
	g.wlen = 0;
	read_case("wr_reset_end: the next command: READ SECTORS 4950+2", 1, 0, 4950, 2);
	free(d);
}

/* the Amiga pauses in the middle of a group: the parked run is closed
   after its bound (HDD_PARK_COUNTS) and the group goes on in a new run;
   one IRQ for the group, after both runs */
static void wr_pause(void)
{
	uint8_t *d = wpattern(16, 41);
	set_multiple(1, 16);
	card_log_mark();
	g.wdata = d;
	g.wlen = 16 * 512;
	command_begin(1, ACMD_WRITE_MULTIPLE, 5100, 16);
	g.hook = HOOK_PAUSE;
	g.hook_at = 7;
	g.pause = 40;
	run_loop();
	trace_blocks();
	check_gayle("wr_pause");
	check("wr_pause: status REQ, END | IRQ", g.nstatus == 2 && g.status[0] == IDE_STATUS_REQ &&
	      g.status[1] == (IDE_STATUS_END | IDE_STATUS_IRQ), 1);
	check("wr_pause: one run per cluster and one more (closed in the pause)", card_log_count("CMD25 arg="), clusters(5100, 16) + 1);
	check("wr_pause: the IRQ after both", irq_early, 0);
	check("wr_pause: on the card", card_has(5100, d, 16), 1);
	file_now(5100, d, 16);
	g.wdata = NULL;
	g.wlen = 0;
	free(d);
}

/* the Amiga slow with a run's first sector (and with each next group's):
   no run starts before the sector is in the FIFO (T11-R1: the Gayle op
   would wait for the Amiga) */
static void wr_slow_amiga(void)
{
	uint8_t *d = wpattern(20, 49);
	set_multiple(1, 16);
	g.wdata = d;
	g.wlen = 20 * 512;
	command_begin(1, ACMD_WRITE_MULTIPLE, 5150, 20);
	g.hook = HOOK_PAUSE;
	g.hook_at = 0;
	g.pause = 40;
	cur_case = "wr_slow_amiga";	/* a Gayle op waiting for the Amiga blocks the polls: a hang */
	run_loop();
	cur_case = "";
	trace_blocks();
	check_gayle("wr_slow_amiga");
	check("wr_slow_amiga: on the card", card_has(5150, d, 20), 1);
	check("wr_slow_amiga: the IRQs after their groups", irq_early, 0);
	file_now(5150, d, 20);
	g.wdata = NULL;
	g.wlen = 0;
	free(d);
}

/* the main loop keeps running during a 64-sector write: passes, the CD
   refill between runs (which reads the card itself: an sd_sync user that
   queues behind the runs), no flags read, no FPGA frame during a Gayle op */
static void main_loop_runs(void)
{
	uint8_t *d = wpattern(64, 43);
	long p0;
	set_multiple(1, 16);
	cd_audio_busy = 1;
	cd_refill_card = 1;
	refill_reads = 0;
	p0 = passes;
	write_case("main_loop_runs: WORK.HDF WRITE MULTIPLE 5200+64, the CD refill reading the card", 1, 1, 5200, 64, d);
	check("main_loop_runs: main-loop passes during the write >= 64", passes - p0 >= 64, 1);
	check("main_loop_runs: CD refills during the write >= 64", audio_polls >= 64, 1);
	check("main_loop_runs: the refill's card reads ran during the write", refill_reads >= 64, 1);
	cd_audio_busy = 0;
	cd_refill_card = 0;
	read_case("main_loop_runs: READ MULTIPLE 5200+0 (256)", 1, 1, 5200, 256);
	free(d);
}

/* OpenHardfile (the OSD's hardfile page) while the Amiga writes: the
   command ends with ERR first (hdd_cancel), the card's run closed */
static void wr_cancel(void)
{
	uint8_t *d = wpattern(16, 45);
	set_multiple(1, 16);
	g.wdata = d;
	g.wlen = 16 * 512;
	command_begin(1, ACMD_WRITE_MULTIPLE, 5300, 16);
	g.hook = HOOK_PAUSE;
	g.hook_at = 4;
	g.pause = 1000000;
	run_until(never, 30);
	check("wr_cancel: the write waits for the Amiga", hdd_busy(), 1);
	ClearError(ERROR_ALL);
	open_unit(1, F_WORK, HDF_FILE, "WORK    ");
	check("wr_cancel: the command ended", fw_idle(), 1);
	check("wr_cancel: END | IRQ | ERR", g.nstatus ? g.status[g.nstatus - 1] : -1, IDE_STATUS_END | IDE_STATUS_IRQ | IDE_STATUS_ERR);
	check("wr_cancel: ABRT", g.ntfw ? g.tfw[g.ntfw - 1][0] : -1, 0x04);
	check("wr_cancel: the card idle", mock_card_idle(), 1);
	check("wr_cancel: the 4 sectors before on the card", card_has(5300, d, 4), 1);
	file_now(5300, d, 4);
	g.busy = 0;
	g.wdata = NULL;
	g.wlen = 0;
	free(d);
}

/* the Amiga abandons during a run's first block (its GAYLE_TO_TX, staged
   in TX in front of the CMD25: fix round 1): no command reaches the card,
   no status for the old command, the engine idle */
static void wr_abandon_first(void)
{
	uint8_t *d = wpattern(4, 51);
	const char *after;
	long n;
	set_multiple(1, 4);
	ClearError(ERROR_ALL);
	g.wdata = d;
	g.wlen = 4 * 512;
	command_begin(1, ACMD_WRITE_MULTIPLE, 4804, 4);	/* the FAT sector of wr_abandon's: no FAT read */
	card_log_mark();
	g.hook = HOOK_ABANDON;
	g.hook_at = 0;
	n = run_until(cmd_over, 200000);
	check("wr_abandon_first: the firmware idle again", n < 200000 && cmd_over(), 1);
	check_gayle("wr_abandon_first");
	check("wr_abandon_first: no command reached the card", (long)strlen(mock_card_log() + log_mark), 0);
	after = log_after("abandon\n");
	check("wr_abandon_first: no status after the abandon", after && !strstr(after, "st "), 1);
	check("wr_abandon_first: the card idle", mock_card_idle(), 1);
	check("wr_abandon_first: nothing written", card_has(4804, files[uc[1].file].data + 4804 * 512, 4), 1);
	g.wdata = NULL;
	g.wlen = 0;
	set_multiple(1, 16);
	read_case("wr_abandon_first: the next command: READ SECTORS 4804+2", 1, 0, 4804, 2);
	free(d);
}

/* mock_gayle_on_end: once the bridge has delivered the read's 1st group,
   Ctrl-Amiga-Amiga and at once the next command (g.next) */
static void reset_after_group(void *ctx)
{
	(void)ctx;
	if (!g.next.on || g.pio != 1 || gay_bytes(0) < (size_t)g.chunk * 512)
		return;
	amiga_reset_next();
}

/* Ctrl-Amiga-Amiga while the Amiga should read a READ MULTIPLE's 1st group,
   the next command a WRITE at once: the old command's drain wait sees the
   new command's request as "drained"; the FakeRDB blocks of its 2nd group
   (the CPU's, not guarded by the bridge's cmd_since) and the 3rd group's
   RDY must not reach the new command (a pio in on a WRITE would drop the
   Amiga's data).  SYNTH.HDF on unit 0: 32 synthesised blocks */
static void rd_reset_to_write(void)
{
	uint8_t *d = wpattern(1, 53);
	unsigned c, h, sct;
	long n;
	const char *after, *tf;
	open_unit(0, F_SYNTH, HDF_FILE | HDF_SYNTHRDB, "SYNTH   ");
	uc[0].rdsk = rdbcases[0].rdsk;
	uc[0].part = rdbcases[0].part;
	set_multiple(0, 16);
	command_begin(0, ACMD_READ_MULTIPLE, 0, 48);
	g.log_dw = 1;
	g.hook = HOOK_RESET_DRAIN;
	g.hook_at = 0;
	lba2chs(0, 100, &c, &h, &sct);
	{
		unsigned char t[8] = { 0, 0, 1, (unsigned char)sct, (unsigned char)c, (unsigned char)(c >> 8),
		                       (unsigned char)(0xA0 | h), ACMD_WRITE_SECTORS };
		memcpy(g.next.tfr, t, 8);
	}
	g.next.count = 1;
	g.next.chunk = 1;
	g.next.wdata = d;
	g.next.wlen = 512;
	g.next.lba = 100;
	g.next.unit = 0;
	g.next.on = 1;
	n = run_until(cmd_over_both, 200000);
	check("rd_reset_to_write: both commands over", n < 200000 && cmd_over_both(), 1);
	check_gayle("rd_reset_to_write");
	after = log_after("cmd\n");
	tf = after ? strstr(after, "tf ") : NULL;
	check("rd_reset_to_write: the new command picked up", tf != NULL, 1);
	check("rd_reset_to_write: nothing of the old command between the reset and the new one's pickup",
	      after && tf && !memmem(after, (size_t)(tf - after), "st ", 3) && !memmem(after, (size_t)(tf - after), "dw", 2), 1);
	check("rd_reset_to_write: the WRITE's statuses REQ, END | IRQ",
	      tf && strstr(tf, "st 04\nst 90\n") != NULL && !strstr(tf, "st 08"), 1);
	check("rd_reset_to_write: its sector on the card",
	      !memcmp(mock_card_sector(files[F_SYNTH].card_lba[100 + uc[0].offset]), d, 512), 1);
	memcpy(files[F_SYNTH].data + (size_t)(100 + uc[0].offset) * 512, d, 512);
	g.log_dw = 0;
	g.wdata = NULL;
	g.wlen = 0;
	open_unit(0, F_WORK, HDF_FILE, "WORK    ");
	/* the reset in the gap between a group's last block reaching Gayle and
	   the next group's RDY (written while the run's CMD12 still runs): the
	   RDY must not go to the new command */
	set_multiple(1, 16);
	command_begin(1, ACMD_READ_MULTIPLE, 2000, 32);
	lba2chs(1, 6100, &c, &h, &sct);
	{
		unsigned char t[8] = { 0, 0, 1, (unsigned char)sct, (unsigned char)c, (unsigned char)(c >> 8),
		                       (unsigned char)(0xB0 | h), ACMD_WRITE_SECTORS };
		memcpy(g.next.tfr, t, 8);
	}
	g.next.count = 1;
	g.next.chunk = 1;
	g.next.wdata = d;
	g.next.wlen = 512;
	g.next.lba = 6100;
	g.next.unit = 1;
	g.next.on = 1;
	mock_gayle_on_end(reset_after_group, NULL);
	n = run_until(cmd_over_both, 200000);
	mock_gayle_on_end(NULL, NULL);
	check("rd_reset_rdy: both commands over", n < 200000 && cmd_over_both(), 1);
	check_gayle("rd_reset_rdy");
	after = log_after("cmd\n");
	tf = after ? strstr(after, "tf ") : NULL;
	check("rd_reset_rdy: the new command picked up", tf != NULL, 1);
	check("rd_reset_rdy: no RDY of the old command after the reset",
	      after && tf && !memmem(after, (size_t)(tf - after), "st ", 3), 1);
	check("rd_reset_rdy: the WRITE's statuses REQ, END | IRQ",
	      tf && strstr(tf, "st 04\nst 90\n") != NULL && !strstr(tf, "st 08"), 1);
	check("rd_reset_rdy: its sector on the card", card_has(6100, d, 1), 1);
	file_now(6100, d, 1);
	/* the reset right after a group of the CPU's blocks (SYNTH.HDF's 2nd
	   group of 16 synthesised ones), before the 3rd group's RDY */
	open_unit(0, F_SYNTH, HDF_FILE | HDF_SYNTHRDB, "SYNTH   ");
	uc[0].rdsk = rdbcases[0].rdsk;
	uc[0].part = rdbcases[0].part;
	set_multiple(0, 16);
	command_begin(0, ACMD_READ_MULTIPLE, 0, 48);
	g.hook = HOOK_RESET_DW;
	g.hook_at = 32;
	lba2chs(0, 101, &c, &h, &sct);
	{
		unsigned char t[8] = { 0, 0, 1, (unsigned char)sct, (unsigned char)c, (unsigned char)(c >> 8),
		                       (unsigned char)(0xA0 | h), ACMD_WRITE_SECTORS };
		memcpy(g.next.tfr, t, 8);
	}
	g.next.count = 1;
	g.next.chunk = 1;
	g.next.wdata = d;
	g.next.wlen = 512;
	g.next.lba = 101;
	g.next.unit = 0;
	g.next.on = 1;
	n = run_until(cmd_over_both, 200000);
	check("rd_reset_group: both commands over", n < 200000 && cmd_over_both(), 1);
	check_gayle("rd_reset_group");
	after = log_after("cmd\n");
	tf = after ? strstr(after, "tf ") : NULL;
	check("rd_reset_group: the new command picked up", tf != NULL, 1);
	check("rd_reset_group: no RDY of the old command after the reset",
	      after && tf && !memmem(after, (size_t)(tf - after), "st ", 3), 1);
	check("rd_reset_group: the WRITE's statuses REQ, END | IRQ",
	      tf && strstr(tf, "st 04\nst 90\n") != NULL && !strstr(tf, "st 08"), 1);
	check("rd_reset_group: its sector on the card",
	      !memcmp(mock_card_sector(files[F_SYNTH].card_lba[101 + uc[0].offset]), d, 512), 1);
	memcpy(files[F_SYNTH].data + (size_t)(101 + uc[0].offset) * 512, d, 512);
	g.hook = HOOK_NONE;
	open_unit(0, F_WORK, HDF_FILE, "WORK    ");
	g.wdata = NULL;
	g.wlen = 0;
	free(d);
}

/* Review Focus 4 at the HDD level: a card that takes 500 ms to program each
   block of a WRITE MULTIPLE (and its stop token): no timeout, each IRQ
   after the busy end, the main loop keeps running meanwhile */
static void wr_busy_500ms(void)
{
	uint8_t *d = wpattern(3, 55);
	unsigned t0 = sd_err_count[SD_ROW_TIMEOUT];
	long p0 = passes;
	set_multiple(1, 4);
	mock_card_params(4, (int)mock_sdc_bytes_for_us(500000), 1, 2);
	write_case("wr_busy_500ms: WORK.HDF WRITE MULTIPLE 5500+3, 500 ms busy per block", 1, 1, 5500, 3, d);
	mock_card_params(4, 8, 1, 2);
	check("wr_busy_500ms: no timeout", sd_err_count[SD_ROW_TIMEOUT] - t0, 0);
	/* 3 blocks + the stop token: 2 s; one pass covers at most a TIMER count (5.8 ms) */
	check("wr_busy_500ms: the main loop ran on (> 300 passes)", passes - p0 > 300, 1);
	check("wr_busy_500ms: CD refills during it (> 300)", audio_polls > 300, 1);
	set_multiple(1, 16);
	free(d);
}

/* Review Focus 5: CD audio plays (the real player, cdaudio.c) while the
   Amiga writes 128 sectors through the state machine (from_gayle CMD25
   runs, a card that takes 8.5 ms a block: about 1.1 s, six halves of the
   ring): the refill runs between the runs (its card reads during the
   write), no underrun, no FPGA frame during a Gayle op, the data and the
   IRQs right.  cdrom_test cannot link the HDD path (it stubs it): this is
   the HDD side of cdrom_test's cd_audio_during_write */
static void cd_audio_during_write(void)
{
	static struct cd_disc disc;
	uint8_t *d = wpattern(128, 57);
	uint32_t u0;
	unsigned long long t_start;
	memset(&disc, 0, sizeof disc);
	disc.tracks = 1;
	disc.files = 1;
	disc.leadout = 4000;
	disc.track[0].number = 1;
	disc.track[0].type = CD_AUDIO;
	disc.track[0].sectors = 4000;
	memcpy(disc.file[0].shortname, "AUDIO   BIN", 12);
	disc.file[0].data_bytes = 4000u * 2352;
	/* time as the board has it: the card and the bridge (mock_sdc_step)
	   move it, a TIMER read does not (the default step lets each one pass
	   5.8 ms: sd_sync's polls of the refill alone would run the music on) */
	mock_timer_step(0);
	cda_init();
	cda_play(&disc, 0, 4000);
	check("cd_audio_during_write: the player plays", cda_status(), CDA_PLAYING);
	u0 = cda_underruns();
	cd_playing = 1;
	cd_reads_in_cmd = 0;
	set_multiple(1, 16);
	mock_card_params(4, 20000, 1, 2);
	t_start = mock_now();
	write_case("cd_audio_during_write: WORK.HDF WRITE MULTIPLE 5600+128 while CD audio plays", 1, 1, 5600, 128, d);
	mock_card_params(4, 8, 1, 2);
	check("cd_audio_during_write: the refill read the disc during the write (between runs)", cd_reads_in_cmd > 0, 1);
	check("cd_audio_during_write: no underrun", cda_underruns() - u0, 0);
	check("cd_audio_during_write: still playing", cda_status(), CDA_PLAYING);
	check("cd_audio_during_write: the write lasted three halves of the ring or more",
	      mock_now() - t_start >= 3ull * CDA_HALF_UNITS * MOCK_CYC_PER_TIMER, 1);
	if (getenv("HDD_CD_INFO"))
		say("cd_audio_during_write: %.0f ms, %u disc reads during the write\n",
		    (double)(mock_now() - t_start) * 1000.0 / MOCK_CLK_HZ, cd_reads_in_cmd);
	cd_playing = 0;
	cda_stop();
	mock_timer_step(1);
	free(d);
}

/* fix round 1 (c): PollDisks runs the card op and the HDD path again while
   the card op makes steps (DISK_STEPS): a step whose next op is short (a
   2-byte token, a data response, R1) goes on in the same pass.  That needs
   a loop round as long as such an op (on the board the status poll over
   cfide's SPI alone takes microseconds; here the SD register accesses are
   made 100 clk_114 each for it): a WRITE MULTIPLE 64 then needs clearly
   fewer passes than card steps (one step per pass: as many) */
static void disk_passes(void)
{
	uint8_t *d = wpattern(64, 59);
	long p0;
	unsigned st0;
	set_multiple(1, 16);
	mock_sdc_access_cycles(100);
	p0 = passes;
	st0 = sd_steps;
	write_case("disk_passes: WORK.HDF WRITE MULTIPLE 2700+64", 1, 1, 2700, 64, d);
	mock_sdc_access_cycles(16);
	if (getenv("HDD_INFO"))
		say("disk_passes: %ld passes, %u card steps\n", passes - p0, sd_steps - st0);
	check("disk_passes: a quarter of the card steps or more taken in a pass with another",
	      (long)(sd_steps - st0) - (passes - p0) > (long)(sd_steps - st0) / 4, 1);
	free(d);
}

/* dbg_flags (ruling T11-R2): quiet by default (no UART byte from a good
   command); DBG_ATA: one line per ATA command at its end */
static void dbg_trace(void)
{
	uint8_t *d = wpattern(1, 47);
	dbg_flags = 0;
	mock_uart_clear();
	command(1, ACMD_READ_SECTORS, 600, 2);
	check("dbg_flags 0: no UART output from a READ", (long)mock_uart_len(), 0);
	command(1, ACMD_IDENTIFY_DEVICE, 0, 1);
	check("dbg_flags 0: no UART output from an IDENTIFY", (long)mock_uart_len(), 0);
	dbg_flags = DBG_ATA;
	mock_uart_clear();
	command(1, ACMD_READ_SECTORS, 600, 2);
	check("DBG_ATA: the READ's line", strstr(mock_uart(), "ATA 20 lba 600 n 2 port 0 ok st 00 t ") != NULL, 1);
	check("DBG_ATA: one line", (long)count_lines(mock_uart()), 1);
	mock_uart_clear();
	g.wdata = d;
	g.wlen = 512;
	command(1, ACMD_WRITE_SECTORS, 5600, 1);
	check("DBG_ATA: the WRITE's line", strstr(mock_uart(), "ATA 30 lba 5600 n 1 port 0 ok st 90 t ") != NULL, 1);
	file_now(5600, d, 1);
	mock_uart_clear();
	command(1, ACMD_READ_SECTORS, 8191, 2);
	check("DBG_ATA: an error's line", strstr(mock_uart(), "ATA 20 lba 8191 n 2 port 0 error st 91 t ") != NULL, 1);
	check("DBG_ATA: one line for it", (long)count_lines(mock_uart()), 1);
	mock_uart_clear();
	command(1, ACMD_IDENTIFY_DEVICE, 0, 1);
	check("DBG_ATA: a command that ran to its end in HandleHDD", strstr(mock_uart(), "ATA ec lba 0 n 1 port 0 done st 00 t 0") != NULL, 1);
	dbg_flags = 0;
	g.wdata = NULL;
	g.wlen = 0;
	free(d);
}

/* fix round 1 of Task 11b: in READ MULTIPLE Gayle's DRQ comes with a group's
   first sector (fifo_full: "a sector in"), so the Amiga may be reading the
   group, held by nrdy, while its later sectors come in: PollDisks runs the
   disks only then (no refill, no HandleFpga) until the group is complete.
   A group of 16 over two clusters (two runs): the gate engaged, the floppy
   ran between the groups, never inside one */
static void rd_group_gate(void)
{
	long p0 = in_block_passes;
	int f0 = fdd_calls;
	set_multiple(1, 16);
	read_case("rd_group_gate: WORK.HDF READ MULTIPLE 2004+48 (groups over cluster ends)", 1, 1, 2004, 48);
	check("rd_group_gate: passes of disk steps only inside a group", in_block_passes - p0 > 0, 1);
	check("rd_group_gate: HandleFpga (the floppy) ran between the groups", fdd_calls - f0 > 0, 1);
	p0 = in_block_passes;
	read_case("rd_group_gate: READ SECTORS 2004+4 (groups of one sector: no gate)", 1, 0, 2004, 4);
	check("rd_group_gate: no gate for one-sector groups", in_block_passes - p0, 0);
}

/* the Amiga's write data: block j = 'W', j, then a pattern */
static uint8_t *wpattern(int n, int seed)
{
	uint8_t *d = malloc((size_t)n * 512);
	if (!d) die("out of memory");
	for (int j = 0; j < n; j++)
		for (int i = 0; i < 512; i++)
			d[(size_t)j * 512 + i] = (uint8_t)(i == 0 ? 'W' : i == 1 ? j : (seed * 41 + j * 13 + i * 7) & 255);
	return d;
}

int main(int argc, char **argv)
{
	char w[200];
	if (argc != 3) { fprintf(stderr, "usage: hdd_test <dir> <golden of rd_multi_order>\n"); return 2; }
	dir = argv[1];

	card_up();
	fakerdb_cases();
	identify_cases();

	/* the real OpenHardfile on the card: the hdf[] fields of the FakeRDB cases */
	open_unit(0, F_SYNTH, HDF_FILE | HDF_SYNTHRDB, "SYNTH   ");
	open_unit(1, F_ODD, HDF_FILE | HDF_SYNTHRDB, "ODD     ");
	for (int unit = 0; unit < 2; unit++) {
		const struct rdbcase *r = &rdbcases[unit ? 2 : 0];
		snprintf(w, sizeof w, "OpenHardfile %s: cylinders, heads, sectors, offset", r->name);
		check(w, uc[unit].cyl == r->cyl && uc[unit].heads == r->heads && uc[unit].secs == r->secs &&
		         uc[unit].offset == r->offset, 1);
		uc[unit].rdsk = r->rdsk;
		uc[unit].part = r->part;
	}
	/* FakeRDB through the card path, and the boundary loop (hdd.c, Task 4) */
	read_case("SYNTH.HDF READ SECTORS 0+3", 0, 0, 0, 3);
	read_case("SYNTH.HDF READ SECTORS 30+4", 0, 0, 30, 4);	/* 32 blocks of RDB cylinder */
	set_multiple(1, 3);
	read_case("ODD.HDF READ MULTIPLE 0+3", 1, 1, 0, 3);
	read_case("ODD.HDF READ MULTIPLE 248+8", 1, 1, 248, 8);	/* chunks 248-250 | 251, file 0, 1 | file 2, 3 */
	set_multiple(1, 4);
	read_case("ODD.HDF READ MULTIPLE 250+4", 1, 1, 250, 4);	/* one chunk: 2 fake, 2 of the file */
	set_multiple(1, 16);
	read_case("ODD.HDF READ MULTIPLE 252+0 (256)", 1, 1, 252, 256);

	/* WORK.HDF: its own RDB on unit 0 (patched), as it is on unit 1 */
	open_unit(0, F_WORK, HDF_FILE, "WORK    ");
	open_unit(1, F_WORK, HDF_FILE, "WORK    ");
	check("WORK.HDF geometry 32/4/63, offset 0",
	      uc[0].cyl == 32 && uc[0].heads == 4 && uc[0].secs == 63 && uc[0].offset == 0, 1);
	read_case("WORK.HDF unit 0 lba 0 (own RDB, patched)", 0, 0, 0, 1);
	read_case("WORK.HDF unit 0 READ SECTORS 0+2", 0, 0, 0, 2);
	read_case("WORK.HDF unit 1 lba 0 (own RDB, as it is)", 1, 0, 0, 1);
	/* CHS: (1, 3, 61) = lba 501, over a head and a cylinder boundary */
	read_case("WORK.HDF READ SECTORS 501+5", 1, 0, 501, 5);
	set_multiple(1, 4);
	read_case("WORK.HDF READ MULTIPLE 1000+10", 1, 1, 1000, 10);
	set_multiple_abrt_cases();
	read_case("WORK.HDF READ MULTIPLE 4000+0 (256)", 1, 1, 4000, 256);
	rd_multi_order(argv[2]);
	read_case("WORK.HDF READ SECTORS 7000+0 (256)", 1, 0, 7000, 256);
	/* the file's last cluster: FileReadEx's seek after the last block meets
	   the end of the chain (fat.c), which is no error (Task 10 fix round 1) */
	read_case("WORK.HDF READ SECTORS 8190+2 (the last cluster)", 1, 0, 8190, 2);
	set_multiple(1, 4);
	read_case("WORK.HDF READ MULTIPLE 8188+4 (the last cluster)", 1, 1, 8188, 4);
	set_multiple(1, 16);
	past_end_cases();
	short_chain_case();
	/* the board deadlock of 2026-10-20: CD audio plays (CD on port 2), the
	   Amiga reads its HDF with READ MULTIPLE of more than one block */
	cd_audio_busy = 1;
	set_multiple(0, 16);
	read_case("CD audio playing: WORK.HDF unit 0 READ MULTIPLE 1200+19", 0, 1, 1200, 19);
	read_case("CD audio playing: WORK.HDF unit 0 READ SECTORS 1300+3", 0, 0, 1300, 3);
	cd_audio_busy = 0;
	snprintf(w, sizeof w, "drive sound steps (cylinder changes)");
	check(w, hdd_steps > 0, 1);
	set_multiple(1, 16);
	error_cases();

	/* writes: the card afterwards is the card before plus the written blocks */
	uint8_t *d5 = wpattern(5, 1), *d256 = wpattern(256, 2), *d4 = wpattern(4, 3), *d3 = wpattern(3, 4);
	write_case("WORK.HDF WRITE SECTORS 501+5", 1, 0, 501, 5, d5);
	set_multiple(1, 2);
	write_case("WORK.HDF WRITE MULTIPLE 3+3", 1, 1, 3, 3, d3);
	set_multiple(1, 16);
	write_case("WORK.HDF WRITE MULTIPLE 3000+0 (256)", 1, 1, 3000, 256, d256);
	write_case("WORK.HDF WRITE SECTORS 6000+0 (256)", 1, 0, 6000, 256, d256);
	cd_audio_busy = 1;
	set_multiple(0, 2);
	write_case("CD audio playing: WORK.HDF unit 0 WRITE MULTIPLE 5000+5", 0, 1, 5000, 5, d5);
	cd_audio_busy = 0;
	read_case("WORK.HDF READ MULTIPLE 3000+0 (256) after the write", 1, 1, 3000, 256);
	snprintf(w, sizeof w, "the read back is the data written");
	if (check(w, nblocks, 256)) check_mem(w, blocks[0], d256, (size_t)256 * 512);
	open_unit(1, F_ODD, HDF_FILE | HDF_SYNTHRDB, "ODD     ");
	uc[1].rdsk = rdbcases[2].rdsk;
	uc[1].part = rdbcases[2].part;
	set_multiple(1, 4);
	/* over the boundary: blocks 250, 251 go nowhere ("Write to auto-generated RDB!"), 252, 253 to file 0, 1 */
	write_case("ODD.HDF WRITE MULTIPLE 250+4", 1, 1, 250, 4, d4);
	check("ODD.HDF WRITE 250+4: ERROR_HDD set", (ErrorMask >> ERROR_HDD) & 1, 1);
	check("ODD.HDF WRITE 250+4: error lba", Errors[ERROR_HDD].a, -2);
	/* the interrupt-driven HDD path (findings/sdcard-engine Task 11a) */
	open_unit(1, F_WORK, HDF_FILE, "WORK    ");
	ClearError(ERROR_ALL);
	wr_irq_after_program();
	wr_cluster_split();
	wr_card_gone();
	wr_abandon();
	wr_reset_mid_run();
	wr_pause();
	wr_slow_amiga();
	wr_abandon_first();
	wr_busy_500ms();
	cd_audio_during_write();
	main_loop_runs();
	wr_cancel();
	dbg_trace();
	rd_reset_to_write();
	disk_passes();
	rd_group_gate();

	free(d5); free(d256); free(d4); free(d3);
	for (int k = 0; k < 3; k++) { free(files[k].data); free(files[k].card_lba); }
	say("%s: %d checks, %d failed\n", fails ? "FAIL" : "PASS", cases, fails);
	return fails ? 1 : 0;
}

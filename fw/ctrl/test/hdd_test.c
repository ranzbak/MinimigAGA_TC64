/* hdd_test: the hard disk emulation's Amiga-facing bytes and its ATA paths
 * (Task 12, plan 5.2 items 1, 2, 7).
 *   hdd_test <dir>
 * <dir> holds what the Makefile made first: gold/rdb.py's rdbcases.h and
 * hdf/{WORK,SYNTH,ODD}.HDF, gold/identify.py's identcases.h (both compiled
 * in) and hdd.img, a tools/sim/mkcard.sh card with the three hardfiles.
 *
 * The real hdd.c runs over the real fat.c and mmc.c on the card model
 * (mock_hw.c), driven through HandleHDD() by a mock Gayle on the FPGA chip
 * select (gayle_miso below).  The checks:
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
#include "mock_hw.h"

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

/* config.c's */
hardfileTYPE *SlotConfig(int slot)
{
	return (slot & 2) ? &config.secondaryhardfile[slot & 1] : &config.hardfile[slot & 1];
}
void DebugMessage(char *message) { (void)message; }
void CD_AudioPoll(void)
{
	audio_polls++;
	full_polls++;
	if (cd_audio_busy)
		ReadIDEFlags(1);	/* the CD on port 2, as cdrom.c CD_AudioPoll */
}
void CD_AudioRefill(void) { audio_polls++; }
void CD_Flags(int port, unsigned char flags) { }
void CD_HandleCommand(int port, unsigned char *tfr) { fprintf(stdout, "FAIL CD_HandleCommand called\n"); exit(1); }
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

static void die(const char *what)
{
	say("FAIL %s\n", what);
	exit(1);
}

/* ---- the mock Gayle (rtl/minimig/gayle_port.v, paula_floppy.v) ----------
 * Every FPGA frame starts with the command byte; its reply is the status
 * byte (paula_floppy spi_tx_data_0 bits 15:8: bit 3 hdd_dat_req =
 * CMD_IDEDAT, bit 2 hdd_cmd_req = CMD_IDECMD), which GetFPGAStatus reads
 * with a 0 command byte.  CMD_IDE_REGS_RD: 5 dummy bytes, then per task
 * file register the flags byte and the register.  CMD_IDE_REGS_WR,
 * CMD_IDE_STATUS_WR, CMD_IDE_DATA_WR: the bytes as hdd.c writes them.
 * CMD_IDE_DATA_RD: 5 dummy bytes, then the FIFO's bytes.
 * The FIFO holds 16 sectors (gayle_fifo.v, 4096 words).  pio in (status
 * write with bit 3, RDY): hdd_cmd_req is bsy = busy & ~drq, drq = at least
 * one sector in the FIFO: so a poll that finds data answers "busy" -- the
 * Amiga then reads all of it (one chunk, logged) -- and the next one
 * "drained".  pio out (bit 2, REQ): every other poll finds a sector the
 * Amiga wrote (hdd_dat_req), which the next CMD_IDE_DATA_RD reads.  The
 * flags of the register reads are 0 (port 1, no other port busy).
 * The firmware port latch (paula_floppy.v hdd_port_r, gayle.v fw_port): bit
 * 0 of the first byte of every HDD command word (10xx, 1100, 1111) selects
 * the port, and it stays latched for what follows without a command word
 * (the direct-mode blocks, GetFPGAStatus).  Every command here is on port 1:
 * a port-2 command word inside it is an error (on the board: the next block
 * went to port 2's FIFO and "drained" hid behind the busy CD port, a
 * deadlock, 2026-10-20). */
#define FIFO_SECTORS 16
#define MAXCHUNKS 300
static struct gayle {
	int frame;		/* mock_frames() of the open frame */
	unsigned pos;		/* its byte index */
	unsigned char cmd, fb[24];
	unsigned char tfr[8];	/* the command the Amiga wrote */
	int pio;		/* 0, 1 = in, 2 = out */
	unsigned long rx;	/* CMD_IDE_DATA_WR data bytes */
	unsigned drained;	/* sectors the Amiga read */
	int chunk[MAXCHUNKS], nchunks;
	unsigned char status[MAXCHUNKS + 2]; int nstatus;
	unsigned char tfw[8][6]; int ntfw;	/* task file writes: error, count, sector, cyl lo, cyl hi, dh */
	const uint8_t *wdata; size_t wlen, wpos;	/* the Amiga's write data */
	unsigned wready;	/* sectors the Amiga put in the FIFO */
	int wtoggle;
	unsigned long busy_polls;
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

static unsigned fifo_sectors(void)
{
	if (g.rx % 512) gayle_err("a partial sector in the FIFO at a status poll");
	if (gay_bytes(0) % 512) gayle_err("a partial card block in the FIFO at a status poll");
	return (unsigned)(g.rx / 512) + (unsigned)(gay_bytes(0) / 512) - g.drained;
}

static unsigned char gayle_poll(void)
{
	unsigned char st = 0;
	if (g.pio == 1) {
		unsigned n = fifo_sectors();
		if (n > FIFO_SECTORS) gayle_err("more than 16 sectors in the FIFO");
		if (n) {
			if (g.nchunks < MAXCHUNKS) g.chunk[g.nchunks++] = (int)n;
			g.drained += n;
		} else
			st = CMD_IDECMD;
	} else if (g.pio == 2) {
		if (g.wtoggle ^= 1) {
			if (g.wready * 512 < g.wlen) g.wready++;
		}
		if (g.wready * 512 > g.wpos) st = CMD_IDEDAT;
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
		g.cmd = out;
		if ((out & 0xC0) == 0x80 || (out & 0xF0) == 0xC0 || (out & 0xF0) == 0xF0) {
			char m[120];
			snprintf(m, sizeof m, "a port-2 command word %02X inside a port-1 command: re-latches hdd_port", out);
			if (out & 1) gayle_err(m);
		}
		if ((out & 0xFE) == CMD_IDE_DATA_WR && ndw < MAXBLOCKS)
			dw_at[ndw++] = gay_bytes(0);
		return out == 0 ? gayle_poll() : 0;
	}
	if (pos < sizeof g.fb) g.fb[pos] = out;
	switch (g.cmd & 0xFE) {
	case CMD_IDE_REGS_RD:
		if (pos < 6 || pos >= 22) return 0;
		return (pos - 6) & 1 ? g.tfr[(pos - 6) / 2] : 0;
	case CMD_IDE_REGS_WR:
		if (pos == 19 && g.ntfw < 8) {
			unsigned char *t = g.tfw[g.ntfw++];
			t[0] = g.fb[9]; t[1] = g.fb[11]; t[2] = g.fb[13];
			t[3] = g.fb[15]; t[4] = g.fb[17]; t[5] = g.fb[19];
		}
		return 0;
	case CMD_IDE_STATUS_WR:
		if (pos == 1) {
			if (g.nstatus < (int)sizeof g.status) g.status[g.nstatus++] = out;
			if (out & IDE_STATUS_RDY) g.pio = 1;
			if (out & IDE_STATUS_REQ) g.pio = 2;
		}
		return 0;
	case CMD_IDE_DATA_WR:
		if (pos >= 6) g.rx++;
		return 0;
	case CMD_IDE_DATA_RD:
		if (pos < 6) return 0;
		if (g.wpos >= g.wready * 512) { gayle_err("CMD_IDE_DATA_RD of a sector the Amiga has not written"); return 0; }
		return g.wdata[g.wpos++];
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

/* the task file of a command on unit 0/1 of port 1: CHS of lba, count byte */
static void command(int unit, unsigned char cmd, long lba, unsigned char count)
{
	unsigned c, h, s;
	lba2chs(unit, lba, &c, &h, &s);
	unsigned char t[8] = { 0, 0, count, (unsigned char)s, (unsigned char)c, (unsigned char)(c >> 8),
	                       (unsigned char)(0xA0 | (unit & 1) << 4 | h), cmd };
	int frame = g.frame;
	const uint8_t *wd = g.wdata;
	size_t wl = g.wlen;
	memset(&g, 0, sizeof g);
	g.frame = frame;
	g.wdata = wd;
	g.wlen = wl;
	memcpy(g.tfr, t, 8);
	mock_gayle_into(0, &gay_base[0]);
	mock_gayle_into(1, &gay_base[1]);
	ndw = 0;
	audio_polls = 0;
	full_polls = 0;
	HandleHDD(CMD_IDECMD, 0);
	if (g.pio == 1 && fifo_sectors()) {	/* the Amiga reads the last chunk */
		if (g.nchunks < MAXCHUNKS) g.chunk[g.nchunks++] = (int)fifo_sectors();
		g.drained += fifo_sectors();
	}
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
   direction and no other; the Amiga polls are one per wait for the FIFO
   plus one per CD_AudioRefill (a poll that found the FIFO not ready) */
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
	snprintf(w, sizeof w, "%s: diskstat amiga polls (waits + refills)", what);
	check(w, (long)(ds_amiga_polls() - ds_amiga), waits + audio_polls);
}

/* a READ SECTORS / READ MULTIPLE of n sectors (count byte n & 255) at lba */
static void read_case(const char *what, int unit, int multiple, long lba, int n)
{
	char w[200];
	int spb = hdf[unit].sectors_per_block;
	diskstat_mark();
	command(unit, multiple ? ACMD_READ_MULTIPLE : ACMD_READ_SECTORS, lba, (unsigned char)n);
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
			check(w, g.chunk[i], i < want_chunks - 1 ? per : n - per * (want_chunks - 1));
		}
	snprintf(w, sizeof w, "%s: status writes", what);
	if (check(w, g.nstatus, want_chunks))
		for (int i = 0; i < g.nstatus; i++) {
			snprintf(w, sizeof w, "%s: status write %d", what, i);
			check(w, g.status[i], IDE_STATUS_RDY);
		}
	snprintf(w, sizeof w, "%s: CD audio polls while the FIFO drains", what);
	check(w, audio_polls, want_chunks - 1);
	diskstat_check(what, 0, n, want_chunks);
}

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
	command(unit, multiple ? ACMD_WRITE_MULTIPLE : ACMD_WRITE_SECTORS, lba, (unsigned char)n);
	diskstat_check(what, 1, n, n);	/* one wait per block */
	check_gayle(what);
	check_taskfile(what, unit, lba + n - 1, (unsigned char)n);
	snprintf(w, sizeof w, "%s: sectors read from the FIFO", what);
	check(w, (long)g.wpos, (long)n * 512);
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
	check("card gone: READ: ERROR_SDCARD set", (ErrorMask >> ERROR_SDCARD) & 1, 1);
	check("card gone: READ: not fatal", ErrorFatal, 0);
	ClearError(ERROR_ALL);
	g.wdata = d;
	g.wlen = 1024;
	command(1, ACMD_WRITE_SECTORS, 600, 2);
	check_gayle("card gone: WRITE SECTORS 600+2");
	check("card gone: WRITE: status REQ, then END | IRQ | ERR", g.nstatus == 2 && g.status[0] == IDE_STATUS_REQ && g.status[1] == err, 1);
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
	if (argc != 2) { fprintf(stderr, "usage: hdd_test <dir>\n"); return 2; }
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
	set_multiple(1, 16);
	read_case("WORK.HDF READ MULTIPLE 4000+0 (256)", 1, 1, 4000, 256);
	read_case("WORK.HDF READ SECTORS 7000+0 (256)", 1, 0, 7000, 256);
	/* the file's last cluster: FileReadEx's seek after the last block meets
	   the end of the chain (fat.c), which is no error (Task 10 fix round 1) */
	read_case("WORK.HDF READ SECTORS 8190+2 (the last cluster)", 1, 0, 8190, 2);
	set_multiple(1, 4);
	read_case("WORK.HDF READ MULTIPLE 8188+4 (the last cluster)", 1, 1, 8188, 4);
	set_multiple(1, 16);
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

	free(d5); free(d256); free(d4); free(d3);
	for (int k = 0; k < 3; k++) { free(files[k].data); free(files[k].card_lba); }
	say("%s: %d checks, %d failed\n", fails ? "FAIL" : "PASS", cases, fails);
	return fails ? 1 : 0;
}

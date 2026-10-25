/*
 * Host test for the CD-ROM board glue (fw/ctrl/cdrom.c), task 1.4.
 *
 * Plan: findings/cdrom/plan.md 7.1, 7.3 (packet mode), 7.4, 9.
 * Build and run: make -C fw/ctrl/test
 *
 * cdrom.c is linked as it is built for the firmware, against fakes of what it
 * calls: the HDD SPI commands (hdd.c), the FAT layer, the timer, the
 * config.  The fakes model one Gayle port in packet mode the way
 * rtl/minimig/gayle_port.v behaves (sim/gayle checks the RTL itself), plus
 * an ATAPI host driver that acts whenever the firmware polls -- it sends
 * the command packet when the firmware asks for it, reads each data-in
 * block, sends data-out blocks -- and checks every phase against ATA/ATAPI:
 *
 *   packet phase   interrupt reason 1 (CoD), pio out, 6 words, no IRQ
 *   data in        reason 2 (IO), byte count = block <= limit, pio in,
 *                  IRQ with the data
 *   data out       reason 0, byte count = block, pio out, IRQ
 *   status         reason 3 (IO|CoD), END + IRQ, ERR and the error
 *                  register from the sense
 *
 * The SD card is a table of fake files (fake_dir): the ISO is synthetic,
 * byte i of sector n is (n * 7 + i) & 0xff with the sector number in its
 * first four bytes; a BIN carries the same user data in raw 2352-byte
 * MODE1 sectors, then audio; CUE sheets are text (phase 3, task 4).
 *
 * The READ's states (CD_Step, findings/sdcard-engine Task 11b) run on fakes
 * of the data path's helpers (hdd.c hdd_op_go / hdd_seek_* / hdd_file_run)
 * and the card op (sdproto.c sd_gayle_busy / sd_drain): a card run is a
 * fake op that ends one main-loop pass (cd_pass: the op, CD_Step as hdd.c
 * hdd_poll calls it, the refill as main.c PollDisks) after its start and
 * then puts its sectors into the FIFO; hdd_file_run cuts a run at the fake
 * cluster (fake_cluster sectors).  Every port access (cs 0x10) while a fake
 * op runs is an error, and so is a run started outside a data-in phase or
 * past its cluster, and a data-in phase set up before the host read the
 * last block (a refill before the drain).  The real engine is cdpath_test's.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "hardware.h"
#include "fat.h"
#include "hdd.h"
#include "config.h"
#include "fpga.h"
#include "errors.h"
#include "rafile.h"
#include "atapi.h"
#include "cue.h"
#include "cdaudio.h"
#include "sdproto.h"
#include "cdrom.h"

/* ---- bookkeeping ---- */

static int case_fails, total_fails, cases_run, cases_passed;
static const char *case_name;

#define EXPECT(cond, ...) do { \
	if (!(cond)) { \
		case_fails++; \
		printf("  FAIL %s (line %d): ", case_name, __LINE__); \
		printf(__VA_ARGS__); \
		printf("\n"); \
	} \
} while (0)

static void begin(const char *name)
{
	case_name = name;
	case_fails = 0;
}

static void end(void)
{
	cases_run++;
	if (case_fails) {
		total_fails += case_fails;
		printf("FAIL  %s\n", case_name);
	} else {
		cases_passed++;
		printf("ok    %s\n", case_name);
	}
}

/* ---- what cdrom.c links against ---- */

configTYPE config;
char DebugMode;
unsigned char ide_port;
unsigned char MMCErr;		/* mmc.c's: the SD_E_* code of the last card call */
hdfTYPE hdf[HDD_SLOTS];
unsigned char core_caps = CORE_CAPS_IDE2;
/* hdd.c's: an IDE command in progress, an HDD command (its data path runs
   from the main loop, findings/sdcard-engine Task 11a) or the CD's READ
   (Task 11b) */
static int hdd_cmd_running;
int hdd_busy(void) { return hdd_cmd_running || CD_Busy(); }

hardfileTYPE *SlotConfig(int slot)
{
	return (slot & 2) ? &config.secondaryhardfile[slot & 1] : &config.hardfile[slot & 1];
}

/* the timer: every poll advances it 1 ms */
static unsigned long now_ms;
unsigned long GetTimer(unsigned long offset) { return (now_ms + offset) << 16; }
unsigned long CheckTimer(unsigned long t) { return ((t - (now_ms << 16)) & 0x80000000) ? 1 : 0; }

/* ---- the SD card: fake files and the FAT fakes ---- */

#define ISO_SECTORS 64
#define BIN_SECTORS 40		/* Game.bin: 20 MODE1/2352 data sectors, then audio */
#define WAV_SECTORS 10
static char iso_name[12] = "TESTDISCISO";	/* 8.3 without the dot */
static unsigned long iso_dir = 0x1234;
static int fail_read_at = -1;			/* this card run (0-based) fails */
static int fail_err = 1;			/* ... with this sd_op.err (SD_E_*; 1 = SD_E_RETRIES) */
static int fail_reset;				/* ... and the Amiga is reset at that moment */
static long eoc_at = -1;			/* a seek to this 512-byte sector or past it meets the end
					   of the chain (-2), -1: never */
static int reads;				/* card runs ended */
unsigned long iCurrentDirectory, iPreviousDirectory;
static int clear_errors;			/* ClearError(ERROR_FILESYSTEM) calls */

static uint8_t iso_byte(unsigned long pos)
{
	unsigned long n = pos / ATAPI_SECTOR_SIZE, i = pos % ATAPI_SECTOR_SIZE;
	if (i < 4)
		return (uint8_t)(n >> (24 - 8 * i));
	return (uint8_t)(n * 7 + i);
}

/* Raw sectors: 0..19 MODE1 (16-byte header, the ISO's user data for that
   sector number, 288 bytes of EDC/ECC 0xEE), 20.. audio bytes. */
static uint8_t bin_byte(unsigned long pos)
{
	unsigned long n = pos / 2352, i = pos % 2352;
	if (n >= 20)
		return (uint8_t)(pos * 3 + 1);
	if (i < 16)
		return (uint8_t)((i >= 1 && i <= 10) ? 0xFF : (i == 15 ? 0x01 : 0x00));
	if (i < 16 + 2048)
		return iso_byte(n * ATAPI_SECTOR_SIZE + i - 16);
	return 0xEE;
}

/* WAV files: a 44-byte header (PCM, channels x 44100 x 16), then samples. */
static uint8_t wav_header[44], mono_header[44];

static void make_wav_header(uint8_t *h, uint32_t data_bytes, uint16_t channels)
{
	static const uint8_t fmt[16] = { 1, 0, 2, 0, 0x44, 0xAC, 0, 0, 0x10, 0xB1, 2, 0, 4, 0, 16, 0 };
	uint32_t riff = data_bytes + 36;
	int i;
	memcpy(h, "RIFF", 4);
	for (i = 0; i < 4; i++) {
		h[4 + i] = (uint8_t)(riff >> (8 * i));
		h[40 + i] = (uint8_t)(data_bytes >> (8 * i));
	}
	memcpy(h + 8, "WAVEfmt ", 8);
	h[16] = 16;
	h[17] = h[18] = h[19] = 0;
	memcpy(h + 20, fmt, 16);
	h[22] = (uint8_t)channels;
	memcpy(h + 36, "data", 4);
}

static uint8_t wav_byte(unsigned long pos)
{
	return pos < 44 ? wav_header[pos] : (uint8_t)((pos - 44) * 5);
}

static uint8_t mono_byte(unsigned long pos)
{
	return pos < 44 ? mono_header[pos] : 0;
}

static const char game_cue[] =
	"FILE \"Game.bin\" BINARY\r\n"
	"  TRACK 01 MODE1/2352\r\n"
	"    INDEX 01 00:00:00\r\n"
	"  TRACK 02 AUDIO\r\n"
	"    INDEX 00 00:00:20\r\n"
	"    INDEX 01 00:00:22\r\n";
static const char mixed_cue[] =
	"FILE \"Mixed (Track 1).iso\" BINARY\n"
	"  TRACK 01 MODE1/2048\n"
	"    INDEX 01 00:00:00\n"
	"FILE \"Mixed (Track 2).wav\" WAVE\n"
	"  TRACK 02 AUDIO\n"
	"    PREGAP 00:02:00\n"
	"    INDEX 01 00:00:00\n";
static const char twodata_cue[] =	/* a data read crosses a POSTGAP into another file */
	"FILE \"Mixed (Track 1).iso\" BINARY\n"
	"  TRACK 01 MODE1/2048\n"
	"    INDEX 01 00:00:00\n"
	"    POSTGAP 00:00:02\n"
	"FILE \"Game.bin\" BINARY\n"
	"  TRACK 02 MODE1/2352\n"
	"    INDEX 01 00:00:00\n";
static const char lower_cue[] = "FILE \"lower.bin\" BINARY\n TRACK 01 MODE1/2352\n INDEX 01 00:00:00\n";
static const char broken_cue[] = "FILE \"Nothere.wav\" WAVE\n TRACK 01 AUDIO\n INDEX 01 00:00:00\n";
static const char badcmd_cue[] = "FILE \"Game.bin\" BINARY\n TRACK 01 MODE1/2352\n INDEX 01 00:00:00\nBOGUS 1\n";
static const char mono_cue[] = "FILE \"Mono.wav\" WAVE\n TRACK 01 AUDIO\n INDEX 01 00:00:00\n";

struct fake_file {
	const char *short11;		/* 8.3 without the dot */
	const char *long_name;		/* LFN, 0 = none (an 8.3 name written in lower case) */
	unsigned long size;		/* ignored for text files */
	uint8_t (*byte)(unsigned long pos);
	const char *text;		/* a CUE sheet */
};

static const struct fake_file fake_dir[] = {
	{ "TESTDISCISO", "Test Disc.iso", ISO_SECTORS * ATAPI_SECTOR_SIZE, iso_byte, 0 },
	{ "GAME    CUE", "Game.cue", 0, 0, game_cue },
	{ "GAME    BIN", "Game.bin", BIN_SECTORS * 2352, bin_byte, 0 },
	{ "MIXED   CUE", "Mixed.cue", 0, 0, mixed_cue },
	{ "MIXED~1 ISO", "Mixed (Track 1).iso", ISO_SECTORS * ATAPI_SECTOR_SIZE, iso_byte, 0 },
	{ "MIXED~2 WAV", "Mixed (Track 2).wav", 44 + WAV_SECTORS * 2352, wav_byte, 0 },
	{ "TWODATA CUE", "Twodata.cue", 0, 0, twodata_cue },
	{ "LOWER   CUE", 0, 0, 0, lower_cue },
	{ "LOWER   BIN", 0, 4 * 2352, bin_byte, 0 },
	{ "BROKEN  CUE", "Broken.cue", 0, 0, broken_cue },
	{ "BADCMD  CUE", "Badcmd.cue", 0, 0, badcmd_cue },
	{ "MONOCUE CUE", "Monocue.cue", 0, 0, mono_cue },
	{ "MONO    WAV", "Mono.wav", 44 + 2352, mono_byte, 0 },
	{ 0, 0, 0, 0, 0 }
};

static unsigned long fake_size(const struct fake_file *f)
{
	return f->text ? strlen(f->text) : f->size;
}

/* fileTYPE.start_cluster = index + 1 of the fake file (0 = none). */
static const struct fake_file *fake_of(const fileTYPE *file)
{
	return file->start_cluster ? &fake_dir[file->start_cluster - 1] : 0;
}

static uint8_t fake_byte(const struct fake_file *f, unsigned long pos)
{
	if (pos >= fake_size(f))
		return 0;
	return f->text ? (uint8_t)f->text[pos] : f->byte(pos);
}

static void fake_read(const fileTYPE *file, unsigned long pos, uint8_t *dst, unsigned long len)
{
	const struct fake_file *f = fake_of(file);
	unsigned long i;
	for (i = 0; i < len; i++)
		dst[i] = f ? fake_byte(f, pos + i) : 0;
}

int ValidateDirectory(unsigned long directory) { return directory == iso_dir || directory == 0; }

void ChangeDirectory(unsigned long iStartCluster)
{
	iPreviousDirectory = iCurrentDirectory;
	iCurrentDirectory = iStartCluster;
}

void ClearError(int category)
{
	if (category == ERROR_FILESYSTEM)
		clear_errors++;
}

/* As fat.c: a long name matches on its first strlen(name) characters, the
   8.3 name on 11. */
unsigned char FileOpen(fileTYPE *file, const char *name)
{
	int i;
	EXPECT(iCurrentDirectory == iso_dir, "FileOpen(%s) outside the disc's directory (%lx)", name, iCurrentDirectory);
	memset(file, 0, sizeof(*file));
	for (i = 0; fake_dir[i].short11; i++) {
		const struct fake_file *f = &fake_dir[i];
		if ((f->long_name && strncmp(f->long_name, name, strlen(name)) == 0) || strncmp(f->short11, name, 11) == 0) {
			memcpy(file->name, f->short11, 11);
			file->size = fake_size(f);
			file->start_cluster = (unsigned long)i + 1;
			return 1;
		}
	}
	return 0;
}

unsigned char BuildHardfileIndex(hdfTYPE *h) { (void)h; return 1; }

unsigned char HardFileSeek(hdfTYPE *h, unsigned long lba)
{
	h->file.sector = lba;
	return 1;
}

static int file_reads[16];	/* FileRead calls per fake_dir entry */

unsigned char FileRead(fileTYPE *file, unsigned char *pBuffer)
{
	if (file->start_cluster && file->start_cluster <= 16)
		file_reads[file->start_cluster - 1]++;
	fake_read(file, file->sector * 512, pBuffer, 512);
	return 1;
}

/* ---- the audio hardware for the player (cdaudio.c through cdrom.c) ----
   44 frames per ms of now_ms; the play pointer runs while ENA is set. */

static uint8_t ring[0x10000];
static unsigned long ena_ms;
static int audio_ena, audio_claims;
static uint32_t audio_last;

static uint32_t frames_now(void) { return (uint32_t)(now_ms * 44); }

uint32_t cda_port_audio(void)
{
	uint32_t p = audio_ena ? (uint32_t)((now_ms - ena_ms) * 44) & 16383 : 0;
	return p >= 8192 ? CDA_REG_HALF : 0;
}

void cda_port_control(uint32_t v)
{
	audio_last = v;
	audio_ena = (v & CDA_ENA) ? 1 : 0;
	if (audio_ena)
		ena_ms = now_ms;
}

uint32_t cda_port_timer(void) { return (frames_now() >> 8) & 0xFFFF; }
uint8_t *cda_port_ring(void) { return ring; }
void cda_port_claim(void) { audio_claims++; }

int RAOpen(RAFile *f, const char *name)
{
	int ok = FileOpen(&f->file, name);
	f->size = f->file.size;
	f->ptr = 0;
	return ok;
}

int RASeek(RAFile *f, unsigned long offset, unsigned long origin)
{
	f->ptr = origin == SEEK_CUR ? f->ptr + offset : offset;
	return 1;
}

int RARead(RAFile *f, unsigned char *pBuffer, unsigned long bytes)
{
	fake_read(&f->file, f->ptr, pBuffer, bytes);
	f->ptr += bytes;
	return 1;
}

/* ---- the Gayle port model (gayle_port.v, packet mode) ---- */

static struct {
	uint8_t  reg[8];	/* task file as the firmware wrote it */
	int      busy, pio_in, pio_out, err, pkt, sig;
	unsigned xfer_words;
	int      xfer_done;
	uint8_t  fifo[8192 + 2];
	unsigned fifo_len, fifo_rd;
	int      irq;		/* the Gayle INTREQ, set by the model, cleared by the host */
	int      block_mark;	/* a pio-in status write arms the interrupt for the DRQ edge */
	int      end_seen;	/* the firmware wrote END */
	uint8_t  end_status;	/* that status write */
	int      rst_pending;	/* the next flag read reports rst_seen (and the port was reset) */
	int      xfers;		/* WriteXfer count */
} g;

/* ---- the host driver model ---- */

static struct {
	uint8_t  cdb[12];
	int      cdb_sent;
	uint8_t  out[4096];	/* data-out bytes to send */
	unsigned out_len, out_pos;
	uint8_t  in[65536];	/* data-in bytes received */
	unsigned in_len;
	unsigned limit;		/* byte count limit it set */
	int      blocks;	/* data blocks seen */
	unsigned block_bytes[64];
	int      dead;		/* never answers: a crashed driver */
	int      reset_at_poll;	/* the Amiga resets at this poll (0: never) */
	int      slow, wait;	/* a slow host: it reads a data-in block only at its slow-th poll after the block is in */
	int      polls;
	int      phase_errors;
} h;

static void host_reset_model(void)
{
	memset(&h, 0, sizeof(h));
}

static void port_reset_model(void)
{
	memset(&g, 0, sizeof(g));
}

/* The host's view of a DRQ for the data or packet phase the firmware has
   set up: checks the registers, then moves the bytes. */
static void host_act(void)
{
	unsigned want = g.xfer_words * 2;
	unsigned bc = g.reg[4] | (g.reg[5] << 8);
	h.polls++;
	if (h.polls > 100000) {
		/* far past the firmware's 10 s timeout: it hangs, and so would the OSD */
		printf("FAIL  %s: the firmware still polls after %d polls -- hung\n", case_name, h.polls);
		exit(1);
	}
	if (h.reset_at_poll && h.polls == h.reset_at_poll) {
		/* Amiga reset: Gayle reset clears busy, pkt_mode, the FIFO */
		g.busy = g.pio_in = g.pio_out = g.pkt = 0;
		g.fifo_len = g.fifo_rd = 0;
		g.xfer_done = 0;
		g.rst_pending = 1;
		return;
	}
	if (h.dead || !g.pkt || g.xfer_done)
		return;
	if (g.pio_out && !h.cdb_sent) {
		/* the command packet */
		if (g.reg[2] != 0x01 || g.xfer_words != 6 || g.irq) {
			h.phase_errors++;
			printf("  packet phase: reason %02X words %u irq %d\n", g.reg[2], g.xfer_words, g.irq);
		}
		memcpy(g.fifo, h.cdb, 12);
		g.fifo_len = 12;
		h.cdb_sent = 1;
		g.xfer_done = 1;
	} else if (g.pio_out) {
		/* data out */
		if (g.reg[2] != 0x00 || bc != want || !g.irq || bc > h.limit) {
			h.phase_errors++;
			printf("  data-out phase: reason %02X bc %u words %u irq %d\n", g.reg[2], bc, g.xfer_words, g.irq);
		}
		g.irq = 0;
		memcpy(g.fifo, h.out + h.out_pos, want);
		h.out_pos += want;
		g.fifo_len = want;
		g.xfer_done = 1;
		h.block_bytes[h.blocks++ & 63] = bc;
	} else if (g.pio_in && g.fifo_len >= want) {
		/* data in, all of the block in the FIFO: DRQ, and the interrupt
		   with it (gayle_port.v: block_mark, sim/gayle case c) */
		if (h.slow && ++h.wait < h.slow)
			return;
		h.wait = 0;
		if (g.block_mark) {
			g.irq = 1;
			g.block_mark = 0;
		}
		if (g.reg[2] != 0x02 || (bc + 1) / 2 != g.xfer_words || !g.irq || bc > h.limit) {
			h.phase_errors++;
			printf("  data-in phase: reason %02X bc %u words %u irq %d limit %u\n", g.reg[2], bc, g.xfer_words, g.irq, h.limit);
		}
		g.irq = 0;
		if (h.in_len + bc <= sizeof(h.in)) {
			memcpy(h.in + h.in_len, g.fifo, bc);
			h.in_len += bc;
		}
		g.fifo_rd = g.fifo_len;
		g.pio_in = 0;
		g.xfer_done = 1;
		h.block_bytes[h.blocks++ & 63] = bc;
	}
}

static sd_op *fop;
#define NO_GAYLE_OP(what) EXPECT(!fop, "%s (cs 0x10) while a Gayle op runs", what)

void WriteTaskFile(int error, int sector_count, int sector_number, int cylinder_low, int cylinder_high, int drive_head)
{
	NO_GAYLE_OP("task file write");
	EXPECT(g.busy, "task file written while not busy");
	g.reg[1] = (uint8_t)error;
	g.reg[2] = (uint8_t)sector_count;
	g.reg[3] = (uint8_t)sector_number;
	g.reg[4] = (uint8_t)cylinder_low;
	g.reg[5] = (uint8_t)cylinder_high;
	g.reg[6] = (uint8_t)drive_head;
}

void WriteStatus(unsigned int status)
{
	NO_GAYLE_OP("status write");
	EXPECT(g.busy, "status written while not busy (%02X)", status);
	if (!g.busy)
		return;
	if (status & IDE_STATUS_ERR)
		g.err = 1;
	if (status & IDE_STATUS_SIG)
		g.sig = 1;
	if (status & IDE_STATUS_RDY) {
		g.pio_in = 1;		/* the interrupt comes with the DRQ */
		g.block_mark = 1;
	}
	if (status & IDE_STATUS_REQ)
		g.pio_out = 1;
	if (g.pkt && (status & IDE_STATUS_IRQ) && !(status & IDE_STATUS_RDY))
		g.irq = 1;
	if (g.pio_in && !g.pkt && (status & IDE_STATUS_RDY))
		g.irq = 1;		/* ATA pio in: the DRQ edge after the block (simplified) */
	if (status & IDE_STATUS_END) {
		if (status & IDE_STATUS_IRQ)
			g.irq = 1;
		g.busy = 0;
		g.pio_out = 0;
		g.end_seen = 1;
		g.end_status = (uint8_t)status;
	}
}

void WriteXfer(unsigned int words, int pkt)
{
	NO_GAYLE_OP("xfer write");
	EXPECT(g.busy, "xfer written while not busy");
	EXPECT(!(words && g.pkt && g.pio_in && !g.xfer_done && g.fifo_len),
	       "a new data phase before the host read the last block (a refill before the drain)");
	EXPECT(words <= 4096, "xfer of %u words, more than the 8 KB FIFO", words);
	g.xfer_words = words;
	g.pkt = pkt;
	g.pio_in = g.pio_out = 0;
	g.xfer_done = 0;
	g.fifo_len = g.fifo_rd = 0;
	g.xfers++;
}

unsigned char ReadIDEFlags(int port)
{
	unsigned char f = (unsigned char)(port ? IDEF_PORT : 0);
	NO_GAYLE_OP("flags read");
	now_ms++;
	host_act();
	if (g.xfer_done)
		f |= IDEF_XFER_DONE;
	if (g.pkt)
		f |= IDEF_PKT;
	if (g.rst_pending) {
		f |= IDEF_RST_SEEN;
		g.rst_pending = 0;
	}
	return f;
}

unsigned char ReadTaskFile(int port, unsigned char *tfr)
{
	memcpy(tfr, g.reg, 8);
	return ReadIDEFlags(port);
}

unsigned char GetFPGAStatus(void)
{
	NO_GAYLE_OP("status read");
	now_ms++;
	host_act();
	return (unsigned char)((g.pkt && g.pio_out && g.xfer_done) ? 0x08 : 0x00);
}

void WriteIDEData(const unsigned char *buf, unsigned int bytes)
{
	NO_GAYLE_OP("data write");
	EXPECT(g.pio_in, "data written without pio in");
	EXPECT(g.fifo_len + bytes <= sizeof(g.fifo), "FIFO overflow");
	if (g.fifo_len + bytes > sizeof(g.fifo))
		return;
	if (buf)
		memcpy(g.fifo + g.fifo_len, buf, bytes);
	else
		memset(g.fifo + g.fifo_len, 0, bytes);
	g.fifo_len += bytes;
	if (bytes & 1)
		g.fifo[g.fifo_len++] = 0;	/* the last word's low byte */
}

void ReadIDEData(unsigned char *buf, unsigned int bytes)
{
	NO_GAYLE_OP("data read");
	EXPECT(g.pio_out && g.xfer_done, "data read without a complete pio-out phase");
	EXPECT(bytes <= g.fifo_len, "reading %u bytes of %u", bytes, g.fifo_len);
	if (buf)
		memcpy(buf, g.fifo, bytes);
}

/* ---- the data path's helpers and the card op (fakes, see the top) ---- */

volatile unsigned dbg_flags;			/* diskstat.c's: no trace here */
unsigned short hosttest_timer(void) { return (unsigned short)now_ms; }
static int traces;				/* ata_trace calls (the READ's end) */
static char trace_what[16];
void ata_trace(unsigned cmd, unsigned long lba, unsigned n, const char *what, unsigned st, unsigned t)
{
	(void)cmd; (void)lba; (void)n; (void)st; (void)t;
	traces++;
	snprintf(trace_what, sizeof trace_what, "%s", what);
}
static int sd_errors;				/* MMC_OpResult of a failed op */
unsigned char MMC_OpResult(const sd_op *op, const char *what)
{
	(void)what;
	MMCErr = (unsigned char)op->err;
	if (op->err && op->err != SD_E_GAYLE)
		sd_errors++;
	return op->err == SD_OK;
}

/* fop (above, the port fakes'): the card run in flight */
static unsigned fake_cluster = 64;		/* sectors of a fake cluster */
static unsigned run_room;			/* hdd_file_run's last cut */
static unsigned long run_lba;			/*                 its card sector */
static int runs, max_run, seeks, seek_wait, seek_err_at = -1;
static int fop_passes;				/* passes the run in flight has left */
static struct { hdfTYPE *h; unsigned long target; int wait; } fseek_;

/* the card sector: the fake file (start_cluster) and its 512-byte sector */
unsigned long hdd_file_run(hdfTYPE *h, unsigned *n)
{
	unsigned long sec = h->file.sector;
	unsigned room = fake_cluster - (unsigned)(sec % fake_cluster);
	if (*n > room)
		*n = room;
	run_room = *n;
	run_lba = h->file.start_cluster << 20 | sec;
	return run_lba;
}

void hdd_seek_begin(hdfTYPE *h, unsigned long target)
{
	fseek_.h = h;
	fseek_.target = target;
	fseek_.wait = seek_wait;
}

int hdd_seek_step(struct sd_op *op)
{
	if (fseek_.wait) {	/* a FAT read: one pass each */
		fseek_.wait--;
		return 0;
	}
	if (seeks++ == seek_err_at) {
		memset(op, 0, sizeof *op);
		op->err = SD_E_RETRIES;
		return -1;
	}
	if (eoc_at >= 0 && (long)fseek_.target >= eoc_at)
		return -2;
	fseek_.h->file.sector = fseek_.target;
	return 1;
}

int hdd_op_go(struct sd_op *op, int kind, unsigned long lba, unsigned n, unsigned char *buf, int port)
{
	if (fop)
		return -1;
	EXPECT(kind == SD_READ && !buf && port == 1, "a card op kind %d buf %p port %d, not a to_gayle read of port 2", kind, (void *)buf, port);
	EXPECT(lba == run_lba && n <= run_room, "a run of %u sectors at %lx, past its cluster (cut %u at %lx)", n, lba, run_room, run_lba);
	EXPECT(n >= 1 && n <= 16, "a card run of %u sectors", n);
	EXPECT(g.pio_in, "a run into the FIFO outside a data-in phase");
	memset(op, 0, sizeof *op);
	op->kind = kind;
	op->lba = (unsigned)lba;
	op->count = n;
	op->port = port;
	op->to_gayle = 1;
	op->state = 1;
	fop = op;
	fop_passes = 2;	/* in flight for the rest of this pass and the next one */
	runs++;
	if ((int)n > max_run)
		max_run = (int)n;
	return 0;
}

/* the run in flight ends: its sectors into the FIFO, or its error */
static void fop_finish(void)
{
	const struct fake_file *f;
	unsigned long sec;
	unsigned long i;
	if (!fop)
		return;
	f = fop->lba >> 20 && (fop->lba >> 20) <= 16 ? &fake_dir[(fop->lba >> 20) - 1] : 0;
	sec = fop->lba & 0xFFFFF;
	if (reads++ == fail_read_at) {
		fop->err = fail_err;
		if (fail_reset) {	/* Ctrl-Amiga-Amiga at the same moment */
			g.busy = g.pio_in = g.pio_out = g.pkt = 0;
			g.fifo_len = g.fifo_rd = 0;
			g.xfer_done = 0;
			g.rst_pending = 1;
		}
	} else {
		EXPECT(f && f->byte == iso_byte, "direct transfer from %s, not a 2048-byte-sector file", f ? f->short11 : "nothing");
		EXPECT(g.pio_in, "direct transfer without pio in");
		for (i = 0; i < fop->count * 512ul && g.fifo_len < sizeof(g.fifo); i++)
			g.fifo[g.fifo_len++] = f ? fake_byte(f, sec * 512 + i) : 0;
		fop->done_blocks = (int)fop->count;
	}
	fop->state = 0;
	fop = 0;
}

/* a pass: the run in flight goes on, or ends */
static void fop_end(void)
{
	if (fop && --fop_passes <= 0)
		fop_finish();
}

int sd_gayle_busy(void) { return fop != 0; }
void sd_drain(void) { fop_finish(); }

/* one main-loop pass for the CD: the card op, CD_Step as hdd.c hdd_poll
   calls it (at most 8 steps), the refill (main.c PollDisks) */
static long passes;
static void cd_pass(void)
{
	int k;
	fop_end();
	for (k = 0; k < 8 && CD_Busy(); k++)
		if (!CD_Step())
			break;
	if (CD_Busy())
		CD_AudioRefill();
	passes++;
}

static void run_cd(void)
{
	long n = 0;
	while (CD_Busy()) {
		cd_pass();
		if (++n > 200000) {
			printf("FAIL  %s: the READ never ends -- hung\n", case_name);
			exit(1);
		}
	}
}

/* ---- driving a command ---- */

/* The host writes the task file and the command; returns the registers
   the firmware reads (tfr) -- what HandleHDD hands to CD_HandleCommand. */
static void host_command(unsigned char *tfr, uint8_t features, unsigned limit, uint8_t cmd)
{
	port_reset_model();
	memset(tfr, 0, 8);
	tfr[1] = features;
	tfr[2] = 0;
	tfr[4] = (uint8_t)limit;
	tfr[5] = (uint8_t)(limit >> 8);
	tfr[6] = 0xA0;
	tfr[7] = cmd;
	memcpy(g.reg, tfr, 8);
	g.busy = 1;
	h.limit = (limit == 0 || limit == 0xFFFF) ? 0xFFFE : (limit & ~1u);
}

/* A PACKET command with this CDB through CD_HandleCommand on port 1 (slot 2). */
static void packet(const uint8_t *cdb, unsigned limit)
{
	unsigned char tfr[8];
	int dead = h.dead, reset_at = h.reset_at_poll, slow = h.slow;
	uint8_t out[4096];
	unsigned out_len = h.out_len;
	memcpy(out, h.out, sizeof(out));
	host_reset_model();
	h.dead = dead;
	h.reset_at_poll = reset_at;
	h.slow = slow;
	memcpy(h.out, out, sizeof(out));
	h.out_len = out_len;
	memcpy(h.cdb, cdb, 12);
	host_command(tfr, 0, limit, 0xA0);
	ide_port = 1;
	CD_HandleCommand(1, tfr);
	run_cd();	/* a READ goes on in the main loop's passes */
}

/* What the status phase said. */
static int completed(void) { return g.end_seen && g.reg[2] == 0x03 && (g.end_status & IDE_STATUS_IRQ); }
static int good_end(void) { return completed() && !(g.end_status & IDE_STATUS_ERR) && g.reg[1] == 0; }
static int check_end(uint8_t error) { return completed() && (g.end_status & IDE_STATUS_ERR) && g.reg[1] == error; }

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

static int iso_matches(uint32_t lba, unsigned bytes)
{
	unsigned i;
	for (i = 0; i < bytes; i++)
		if (h.in[i] != iso_byte((unsigned long)lba * ATAPI_SECTOR_SIZE + i))
			return 0;
	return 1;
}

/* A fresh drive in slot 2 (port 2 master) with the test ISO in it, the
   insert's UNIT ATTENTION consumed. */
static void fresh_drive(int with_disc)
{
	uint8_t c[12];
	memset(&config, 0, sizeof(config));
	config.secondaryhardfile[0].enabled = HDF_CDROM;
	if (with_disc) {
		memcpy(config.secondaryhardfile[0].name, iso_name, 8);
		strcpy(config.secondaryhardfile[0].long_name, "Test Disc");
		config.hdfdir[2] = iso_dir;
	}
	fail_read_at = -1;
	fail_err = SD_E_RETRIES;
	fail_reset = 0;
	reads = 0;
	eoc_at = -1;
	fake_cluster = 64;
	seek_wait = 0;
	seek_err_at = -1;
	seeks = runs = max_run = sd_errors = traces = 0;
	CD_Open(2);
	if (with_disc) {
		cdb6(c, 0x00, 0);	/* TEST UNIT READY: 06/28/00 once */
		packet(c, 0xFFFE);
	}
	host_reset_model();
}

/* ---- cases ---- */

static void t_open(void)
{
	begin("CD_Open from the config: slot, disc, present, name");
	fresh_drive(1);
	EXPECT(CD_SLOT() == 2, "slot %d", CD_SLOT());
	EXPECT(cdrom.unit.media == 1, "no disc");
	EXPECT(config.secondaryhardfile[0].present == 1, "present not set");
	EXPECT(strcmp(cdrom.unit.name, "Test Disc") == 0, "name '%s'", cdrom.unit.name);
	EXPECT(cdrom.unit.sectors == ISO_SECTORS, "sectors %u", (unsigned)cdrom.unit.sectors);
	CD_Open(-1);
	EXPECT(CD_SLOT() == -1, "CD_Open(-1) leaves a slot");
	end();
}

static void t_inquiry(void)
{
	uint8_t c[12];
	begin("INQUIRY: packet phase, one 36-byte data-in block, good status");
	fresh_drive(1);
	cdb6(c, 0x12, 36);
	packet(c, 0xFFFE);
	EXPECT(h.cdb_sent, "the command packet was never asked for");
	EXPECT(h.phase_errors == 0, "phase errors");
	EXPECT(h.blocks == 1 && h.block_bytes[0] == 36, "blocks %d, first %u", h.blocks, h.block_bytes[0]);
	EXPECT(h.in_len == 36 && h.in[0] == 0x05 && memcmp(h.in + 8, "MINIMIG ", 8) == 0, "inquiry data");
	EXPECT(memcmp(h.in + 16, "Test Disc       ", 16) == 0, "product '%.16s'", h.in + 16);
	EXPECT(good_end(), "status phase: reason %02X status %02X error %02X", g.reg[2], g.end_status, g.reg[1]);
	end();
}

static void t_limit_split(void)
{
	uint8_t c[12];
	begin("a response longer than the byte count limit: blocks of the limit");
	fresh_drive(1);
	cdb6(c, 0x12, 36);
	packet(c, 16);
	EXPECT(h.phase_errors == 0, "phase errors");
	EXPECT(h.blocks == 3 && h.block_bytes[0] == 16 && h.block_bytes[1] == 16 && h.block_bytes[2] == 4,
	       "blocks %d: %u %u %u", h.blocks, h.block_bytes[0], h.block_bytes[1], h.block_bytes[2]);
	EXPECT(h.in_len == 36 && memcmp(h.in + 8, "MINIMIG ", 8) == 0, "data");
	EXPECT(good_end(), "status phase");
	end();
}

static void t_odd_length(void)
{
	uint8_t c[12];
	begin("an odd allocation length: byte count 17, 9 words");
	fresh_drive(1);
	cdb6(c, 0x03, 17);	/* REQUEST SENSE */
	packet(c, 0xFFFE);
	EXPECT(h.phase_errors == 0, "phase errors");
	EXPECT(h.blocks == 1 && h.block_bytes[0] == 17, "block %u", h.block_bytes[0]);
	EXPECT(h.in[0] == 0x70, "sense response code %02X", h.in[0]);
	EXPECT(good_end(), "status phase");
	end();
}

static void t_read_one_block(void)
{
	uint8_t c[12];
	begin("READ(10) 3 sectors: one 6 KB block straight from the file");
	fresh_drive(1);
	read10(c, 16, 3);
	packet(c, 0xFFFE);
	EXPECT(h.phase_errors == 0, "phase errors");
	EXPECT(h.blocks == 1 && h.block_bytes[0] == 3 * 2048, "blocks %d first %u", h.blocks, h.block_bytes[0]);
	EXPECT(h.in_len == 3 * 2048 && iso_matches(16, 3 * 2048), "sector data");
	EXPECT(good_end(), "status phase");
	end();
}

static void t_read_blocks(void)
{
	uint8_t c[12];
	begin("READ(10) 5 sectors: 8 KB + 2 KB blocks (the FIFO holds 8 KB)");
	fresh_drive(1);
	read10(c, 40, 5);
	packet(c, 0xFFFE);
	EXPECT(h.phase_errors == 0, "phase errors");
	EXPECT(h.blocks == 2 && h.block_bytes[0] == 8192 && h.block_bytes[1] == 2048,
	       "blocks %d: %u %u", h.blocks, h.block_bytes[0], h.block_bytes[1]);
	EXPECT(h.in_len == 5 * 2048 && iso_matches(40, 5 * 2048), "sector data");
	EXPECT(good_end(), "status phase");
	end();
}

/* drain, then refill (findings/sdcard-engine Task 11b): a host that reads
   each block only at its 5th poll after it is in; the next block's phase
   only after it did (the model fails a phase set up over an unread block) */
static void t_slow_host(void)
{
	uint8_t c[12];
	begin("a slow host: READ(10) 10+9, each block read at the 5th poll: blocks in order, no refill before the drain");
	fresh_drive(1);
	h.slow = 5;
	read10(c, 10, 9);
	packet(c, 0xFFFE);
	h.slow = 0;
	EXPECT(h.phase_errors == 0, "phase errors");
	EXPECT(h.blocks == 3 && h.block_bytes[0] == 8192 && h.block_bytes[2] == 2048, "blocks %d", h.blocks);
	EXPECT(h.in_len == 9 * 2048 && iso_matches(10, 9 * 2048) && good_end(), "data, status");
	end();
}

static void t_read_limit(void)
{
	uint8_t c[12];
	begin("READ(10) 3 sectors with a 2 KB limit: three 2 KB blocks");
	fresh_drive(1);
	read10(c, 2, 3);
	packet(c, 0x0800);
	EXPECT(h.phase_errors == 0, "phase errors");
	EXPECT(h.blocks == 3 && h.block_bytes[0] == 2048 && h.block_bytes[2] == 2048, "blocks %d", h.blocks);
	EXPECT(h.in_len == 3 * 2048 && iso_matches(2, 3 * 2048), "sector data");
	EXPECT(good_end(), "status phase");
	end();
}

static void t_read_last(void)
{
	uint8_t c[12];
	begin("READ(10) of the last sector, and one beyond: 05/21/00, error 54");
	fresh_drive(1);
	read10(c, ISO_SECTORS - 1, 1);
	packet(c, 0xFFFE);
	EXPECT(h.in_len == 2048 && iso_matches(ISO_SECTORS - 1, 2048), "last sector");
	EXPECT(good_end(), "status phase");
	read10(c, ISO_SECTORS - 1, 2);
	packet(c, 0xFFFE);
	EXPECT(h.blocks == 0, "data phase for a failed read");
	EXPECT(check_end(0x54), "status: %02X error %02X", g.end_status, g.reg[1]);
	cdb6(c, 0x03, 18);
	packet(c, 0xFFFE);
	EXPECT(h.in[2] == 0x05 && h.in[12] == 0x21, "sense %02X/%02X", h.in[2], h.in[12]);
	end();
}

static void t_no_disc(void)
{
	uint8_t c[12];
	begin("no disc: TEST UNIT READY 02/3A/00, error 20 (no ABRT)");
	fresh_drive(0);
	cdb6(c, 0x00, 0);
	packet(c, 0xFFFE);
	EXPECT(check_end(0x20), "status: %02X error %02X", g.end_status, g.reg[1]);
	end();
}

static void t_unit_attention(void)
{
	uint8_t c[12];
	begin("insert: 06/28/00 once (error 60), then good");
	fresh_drive(0);
	EXPECT(CD_Insert(iso_name, "Other Disc", iso_dir) == CD_OK, "insert");
	cdb6(c, 0x00, 0);
	packet(c, 0xFFFE);
	EXPECT(check_end(0x60), "status: %02X error %02X", g.end_status, g.reg[1]);
	packet(c, 0xFFFE);
	EXPECT(good_end(), "second TEST UNIT READY");
	end();
}

static void t_mode_select(void)
{
	uint8_t c[12];
	begin("MODE SELECT(10) 24 bytes: data-out block, reason 0, IRQ");
	fresh_drive(1);
	memset(c, 0, 12);
	c[0] = 0x55;
	c[8] = 24;
	memset(h.out, 0xA5, 24);
	h.out_len = 24;
	packet(c, 0xFFFE);
	EXPECT(h.phase_errors == 0, "phase errors");
	EXPECT(h.blocks == 1 && h.block_bytes[0] == 24, "data-out blocks %d", h.blocks);
	EXPECT(good_end(), "status phase");
	end();
}

static void t_identify_packet(void)
{
	unsigned char tfr[8];
	begin("IDENTIFY PACKET DEVICE: 256 words, word 0 = 8580 low byte first");
	fresh_drive(1);
	host_command(tfr, 0, 0, 0xA1);
	ide_port = 1;
	CD_HandleCommand(1, tfr);
	EXPECT(g.fifo_len == 512, "%u bytes", g.fifo_len);
	EXPECT(g.fifo[0] == 0x80 && g.fifo[1] == 0x85, "word 0 bytes %02X %02X", g.fifo[0], g.fifo[1]);
	EXPECT(g.fifo[2 * 27] == 'e' && g.fifo[2 * 27 + 1] == 'T', "model 'Te' swapped: %c%c", g.fifo[54], g.fifo[55]);
	EXPECT(!g.pkt, "packet mode for an ATA PIO command");
	EXPECT(g.end_seen && (g.end_status & IDE_STATUS_IRQ) && !(g.end_status & IDE_STATUS_ERR), "END|IRQ");
	end();
}

static void t_ata_commands(void)
{
	unsigned char tfr[8];
	begin("ATA commands on the CD: EC abort + signature, 90/08 signature, EF 03, NOP, DMA packet");
	fresh_drive(1);
	host_command(tfr, 0, 0, 0xEC);
	CD_HandleCommand(1, tfr);
	EXPECT((g.end_status & (IDE_STATUS_END | IDE_STATUS_ERR | IDE_STATUS_IRQ)) == (IDE_STATUS_END | IDE_STATUS_ERR | IDE_STATUS_IRQ)
	       && g.reg[1] == 0x04 && g.reg[2] == 1 && g.reg[3] == 1 && g.reg[4] == 0x14 && g.reg[5] == 0xEB,
	       "IDENTIFY DEVICE: status %02X regs %02X %02X %02X %02X %02X", g.end_status, g.reg[1], g.reg[2], g.reg[3], g.reg[4], g.reg[5]);
	host_command(tfr, 0, 0, 0x90);
	CD_HandleCommand(1, tfr);
	EXPECT(g.end_seen && (g.end_status & IDE_STATUS_IRQ) && !(g.end_status & IDE_STATUS_ERR) && g.sig
	       && g.reg[1] == 0x01 && g.reg[4] == 0x14 && g.reg[5] == 0xEB, "DIAGNOSTIC: status %02X", g.end_status);
	host_command(tfr, 0, 0, 0x08);
	CD_HandleCommand(1, tfr);
	EXPECT(g.end_seen && !(g.end_status & IDE_STATUS_IRQ) && g.sig && g.reg[4] == 0x14,
	       "DEVICE RESET: status %02X", g.end_status);
	host_command(tfr, 0x03, 0, 0xEF);
	CD_HandleCommand(1, tfr);
	EXPECT(g.end_seen && !(g.end_status & IDE_STATUS_ERR), "SET FEATURES 03 accepted");
	host_command(tfr, 0x02, 0, 0xEF);
	CD_HandleCommand(1, tfr);
	EXPECT(g.end_seen && (g.end_status & IDE_STATUS_ERR) && g.reg[1] == 0x04, "SET FEATURES 02 aborted");
	host_command(tfr, 0, 0, 0x00);
	CD_HandleCommand(1, tfr);
	EXPECT(g.end_seen && (g.end_status & IDE_STATUS_ERR) && g.reg[1] == 0x04, "NOP aborted");
	host_command(tfr, 0x01, 0xFFFE, 0xA0);
	CD_HandleCommand(1, tfr);
	EXPECT(g.end_seen && (g.end_status & IDE_STATUS_ERR) && g.reg[1] == 0x04 && g.xfers == 0, "PACKET with DMA aborted");
	end();
}

static void t_lock_and_eject(void)
{
	uint8_t c[12];
	begin("PREVENT: OSD eject refused, Amiga eject 05/53/02; ALLOW: eject drops the file and the config name");
	fresh_drive(1);
	cdb6(c, 0x1E, 1);
	packet(c, 0xFFFE);
	EXPECT(good_end(), "PREVENT");
	EXPECT(CD_Locked(), "not locked");
	EXPECT(CD_Eject() == CD_LOCKED, "OSD eject while locked");
	EXPECT(CD_Insert(iso_name, "X", iso_dir) == CD_LOCKED, "OSD swap while locked");
	EXPECT(cdrom.unit.media && config.secondaryhardfile[0].name[0], "the disc left");
	cdb6(c, 0x1B, 0x02);
	packet(c, 0xFFFE);
	EXPECT(check_end(0x54), "Amiga eject while locked: status %02X error %02X", g.end_status, g.reg[1]);
	cdb6(c, 0x1E, 0);
	packet(c, 0xFFFE);
	cdb6(c, 0x1B, 0x02);
	packet(c, 0xFFFE);
	EXPECT(good_end(), "Amiga eject");
	EXPECT(!cdrom.unit.media && cdrom.hdf.type == HDF_DISABLED, "the file is still open");
	EXPECT(config.secondaryhardfile[0].name[0] == 0 && !config.secondaryhardfile[0].present, "config still names the disc");
	EXPECT(config.secondaryhardfile[0].enabled == HDF_CDROM, "the slot lost its type");
	end();
}

static void t_osd_insert_eject(void)
{
	begin("OSD insert writes the slot's config (name, 16-char long name, dir); eject clears it");
	fresh_drive(0);
	EXPECT(CD_Insert(iso_name, "A Very Long Disc Name Indeed", iso_dir) == CD_OK, "insert");
	EXPECT(memcmp(config.secondaryhardfile[0].name, iso_name, 8) == 0, "config name");
	EXPECT(memcmp(config.secondaryhardfile[0].long_name, "A Very Long Disc", 16) == 0, "config long name");
	EXPECT(config.secondaryhardfile[0].present == 1 && config.hdfdir[2] == iso_dir, "present / dir");
	EXPECT(strcmp(cdrom.unit.name, "A Very Long Disc Name Indeed") == 0, "unit name '%s'", cdrom.unit.name);
	EXPECT(CD_Insert("NOSUCHISISO", "Nope", iso_dir) == CD_NOFILE, "missing file");
	EXPECT(!cdrom.unit.media && config.secondaryhardfile[0].name[0] == 0, "a failed insert leaves the drive empty");
	EXPECT(CD_Insert(iso_name, 0, iso_dir) == CD_OK, "insert, no long name");
	EXPECT(strcmp(cdrom.unit.name, "TESTDISC") == 0, "short name '%s'", cdrom.unit.name);
	EXPECT(CD_Eject() == CD_OK && !cdrom.unit.media, "eject");
	EXPECT(config.secondaryhardfile[0].name[0] == 0 && !config.secondaryhardfile[0].present, "config after eject");
	end();
}

static void t_reset_mid_command(void)
{
	uint8_t c[12];
	begin("Amiga reset while the firmware waits for the packet: no status written, UA 06/29, lock cleared");
	fresh_drive(1);
	cdb6(c, 0x1E, 1);
	packet(c, 0xFFFE);
	EXPECT(CD_Locked(), "PREVENT");
	h.reset_at_poll = 1;
	cdb6(c, 0x00, 0);
	packet(c, 0xFFFE);
	EXPECT(!g.end_seen, "a status written after the reset");
	EXPECT(!CD_Locked(), "the lock survived the reset");
	h.reset_at_poll = 0;
	packet(c, 0xFFFE);
	EXPECT(check_end(0x60), "UA after reset: status %02X error %02X", g.end_status, g.reg[1]);
	cdb6(c, 0x03, 18);
	packet(c, 0xFFFE);
	EXPECT(good_end(), "REQUEST SENSE");
	end();
}

static void t_reset_mid_read(void)
{
	uint8_t c[12];
	begin("Amiga reset during a data-in block: the command ends there");
	fresh_drive(1);
	h.reset_at_poll = 2;	/* poll 1 takes the packet, poll 2 the reset */
	read10(c, 0, 8);
	packet(c, 0x0800);
	EXPECT(!g.end_seen, "a status written after the reset");
	EXPECT(h.blocks <= 1, "%d blocks after the reset", h.blocks);
	h.reset_at_poll = 0;
	end();
}

static void t_timeout(void)
{
	uint8_t c[12];
	begin("a host that never sends the packet: the firmware gives up (no hang), aborts");
	fresh_drive(1);
	h.dead = 1;
	cdb6(c, 0x00, 0);
	now_ms = 0;
	packet(c, 0xFFFE);
	EXPECT(g.end_seen && (g.end_status & IDE_STATUS_ERR) && (g.reg[1] & 0x04), "status %02X error %02X", g.end_status, g.reg[1]);
	EXPECT(now_ms >= 5000 && now_ms < 60000, "gave up after %lu ms", now_ms);
	h.dead = 0;
	end();
}

static void t_read_error(void)
{
	uint8_t c[12];
	begin("an SD read error in a READ: the transfer is dropped, CHECK 03/11/00 (error 30)");
	fresh_drive(1);
	fail_read_at = 1;	/* the second block */
	reads = 0;
	read10(c, 0, 5);
	packet(c, 0xFFFE);
	EXPECT(check_end(0x30), "status %02X error %02X", g.end_status, g.reg[1]);
	fail_read_at = -1;
	cdb6(c, 0x03, 18);
	packet(c, 0xFFFE);
	EXPECT(h.in[2] == 0x03 && h.in[12] == 0x11, "sense %02X/%02X", h.in[2], h.in[12]);
	end();
}

/* findings/sdcard-engine Task 10: a read the host abandoned (a new command
   reset the FIFO: the SD peripheral's Gayle op ends with a Gayle error,
   MMCErr SD_E_GAYLE) gets no status at all, and no sense */
static void t_read_abandon(void)
{
	uint8_t c[12];
	begin("an abandoned READ (Gayle error on the transfer): no status, no sense");
	fresh_drive(1);
	fail_read_at = 1;
	fail_err = SD_E_GAYLE;
	reads = 0;
	read10(c, 0, 5);
	packet(c, 0xFFFE);
	EXPECT(!g.end_seen, "a status for the abandoned command: %02X", g.end_status);
	fail_read_at = -1;
	fail_err = SD_E_RETRIES;
	cdb6(c, 0x03, 18);
	packet(c, 0xFFFE);
	EXPECT(h.in[2] == 0x00, "sense key %02X", h.in[2]);
	end();
}

/* Task 10 fix rounds 1 and 2: FileReadEx is 0 with no card error only when
   blocks are left after the end of the file's chain (a read ending at its
   last sector is 1: fat_test): the READ runs past the file, CHECK
   CONDITION, not a good end */
/* Task 10 fix round 3: the last chunk's FileReadEx fails with a card error
   (its final FAT read): CHECK 03/11/00, not a good end */
static void t_read_last_chunk_error(void)
{
	uint8_t c[12];
	begin("an SD card error in the last chunk of a READ: CHECK 03/11/00");
	fresh_drive(1);
	reads = 0;
	fail_read_at = 1;	/* 5 CD sectors = 20 blocks: chunks of 16 + 4, the second fails */
	fail_err = SD_E_RETRIES;
	read10(c, 0, 5);
	packet(c, 0xFFFE);
	EXPECT(check_end(0x30), "status %02X error %02X", g.end_status, g.reg[1]);
	fail_read_at = -1;
	end();
}

static void t_read_eoc(void)
{
	uint8_t c[12];
	begin("a READ whose seek meets the end of the file's chain inside its size (no card error): CHECK 03/11/00");
	fresh_drive(1);
	fake_cluster = 2;	/* the block's second run needs a seek to sector 2 */
	eoc_at = 2;
	read10(c, 0, 1);
	packet(c, 0xFFFE);
	EXPECT(check_end(0x30), "status %02X error %02X", g.end_status, g.reg[1]);
	EXPECT(h.blocks == 0, "%d data-in blocks for a read that failed", h.blocks);
	EXPECT(sd_errors == 0, "the end of the chain shown as a card error");
	eoc_at = -1;
	fake_cluster = 64;
	end();
}

/* ---- findings/sdcard-engine Task 11b: the READ's states ---- */

/* card runs: at most 16 sectors, cut at every cluster end (an odd fake
   cluster of 3), the data right; the main loop ran a pass per run or more */
static void t_cluster_runs(void)
{
	uint8_t c[12];
	long p0;
	begin("cluster runs: READ(10) 1+6, 3-sector clusters: 10 runs inside them, the data right");
	fresh_drive(1);
	fake_cluster = 3;
	runs = max_run = 0;
	p0 = passes;
	read10(c, 1, 6);
	packet(c, 0xFFFE);
	EXPECT(h.phase_errors == 0, "phase errors");
	EXPECT(h.blocks == 2 && h.block_bytes[0] == 8192 && h.block_bytes[1] == 4096, "blocks %d", h.blocks);
	EXPECT(h.in_len == 6 * 2048 && iso_matches(1, 6 * 2048), "sector data");
	EXPECT(good_end(), "status phase");
	/* sectors 4..19 cut at 6, 9, 12, 15, 18; 20..27 at 21, 24, 27 */
	EXPECT(runs == 10 && max_run == 3, "%d runs, the longest %d", runs, max_run);
	EXPECT(passes - p0 >= runs, "%ld passes for %d runs", passes - p0, runs);
	fake_cluster = 16;
	runs = max_run = 0;
	read10(c, 4, 8);	/* sectors 16..47: a block per cluster, one run each */
	packet(c, 0xFFFE);
	EXPECT(h.in_len == 8 * 2048 && iso_matches(4, 8 * 2048) && good_end(), "16-sector clusters: data");
	EXPECT(runs == 2 && max_run == 16, "16-sector clusters: %d runs, the longest %d", runs, max_run);
	runs = max_run = 0;
	read10(c, 2, 8);	/* sectors 8..39: 8..15 | 16..23, 24..31 | 32..39 */
	packet(c, 0xFFFE);
	EXPECT(h.in_len == 8 * 2048 && iso_matches(2, 8 * 2048) && good_end(), "16-sector clusters, misaligned: data");
	EXPECT(runs == 4 && max_run == 8, "16-sector clusters, misaligned: %d runs, the longest %d", runs, max_run);
	fake_cluster = 64;
	end();
}

/* FAT reads of the seeks take passes (async): the READ waits for them */
static void t_seek_wait(void)
{
	uint8_t c[12];
	begin("seeks that wait for FAT reads: READ(10) 0+9 right");
	fresh_drive(1);
	seek_wait = 3;
	fake_cluster = 8;
	read10(c, 0, 9);
	packet(c, 0xFFFE);
	EXPECT(h.phase_errors == 0 && h.blocks == 3, "blocks %d", h.blocks);
	EXPECT(h.in_len == 9 * 2048 && iso_matches(0, 9 * 2048) && good_end(), "data, status");
	seek_wait = 0;
	fake_cluster = 64;
	end();
}

/* a seek's FAT read fails: CHECK 03/11/00, the card error shown (MMC_OpResult) */
static void t_seek_error(void)
{
	uint8_t c[12];
	begin("a seek's FAT read fails in a READ: CHECK 03/11/00, the card error shown");
	fresh_drive(1);
	fake_cluster = 8;
	seek_err_at = 2;	/* the third seek: block 2's first run */
	seeks = sd_errors = 0;
	read10(c, 0, 8);
	packet(c, 0xFFFE);
	EXPECT(check_end(0x30), "status %02X error %02X", g.end_status, g.reg[1]);
	EXPECT(h.blocks == 1, "%d blocks before the error", h.blocks);
	EXPECT(sd_errors == 1, "MMC_OpResult of the failed FAT read: %d", sd_errors);
	seek_err_at = -1;
	fake_cluster = 64;
	end();
}

/* a card run fails and the Amiga is reset at that moment: no status for
   the command it left (the flags looked at before the error status) */
static void t_error_reset(void)
{
	uint8_t c[12];
	begin("a card error at an Amiga reset: no status, the command abandoned");
	fresh_drive(1);
	fail_read_at = 1;
	fail_reset = 1;
	traces = 0;
	read10(c, 0, 8);
	packet(c, 0xFFFE);
	EXPECT(!g.end_seen, "a status for the command the Amiga left: %02X", g.end_status);
	EXPECT(traces == 1 && !strcmp(trace_what, "abandoned"), "the end: %d traces, '%s'", traces, trace_what);
	fail_read_at = -1;
	fail_reset = 0;
	cdb6(c, 0x00, 0);
	packet(c, 0xFFFE);
	EXPECT(check_end(0x60), "UNIT ATTENTION after the reset: status %02X error %02X", g.end_status, g.reg[1]);
	end();
}

/* the OSD tries to eject a locked disc during a READ: refused, no IDE
   flags read for it (CD_Locked: a pending rst_seen stays for the READ's own
   look), the READ goes on to its good end */
static void t_locked_eject(void)
{
	uint8_t c[12];
	unsigned char tfr[8];
	long k;
	begin("OSD eject of a locked disc during a READ: refused, no flags read for it, the READ ends good");
	fresh_drive(1);
	cdb6(c, 0x1E, 1);	/* PREVENT MEDIUM REMOVAL */
	packet(c, 0xFFFE);
	EXPECT(good_end() && CD_Locked(), "not locked");
	read10(c, 0, 16);
	host_reset_model();
	memcpy(h.cdb, c, 12);
	host_command(tfr, 0, 0xFFFE, 0xA0);
	ide_port = 1;
	CD_HandleCommand(1, tfr);
	for (k = 0; k < 1000 && CD_Busy() && h.blocks < 1; k++)
		cd_pass();
	for (k = 0; k < 1000 && CD_Busy() && !fop; k++)
		cd_pass();
	EXPECT(CD_Busy() && fop, "the READ is not in a run (blocks %d)", h.blocks);
	{
		unsigned long t0 = now_ms;
		int polls = h.polls;
		EXPECT(CD_Eject() == CD_LOCKED, "a locked disc ejected");
		EXPECT(now_ms == t0 && h.polls == polls, "CD_Locked read the IDE flags during the READ");
	}
	run_cd();
	EXPECT(h.in_len == 16 * 2048 && iso_matches(0, 16 * 2048) && good_end(), "the READ after the refused eject");
	EXPECT(cdrom.unit.media, "the disc left");
	cdb6(c, 0x1E, 0);	/* ALLOW */
	packet(c, 0xFFFE);
	end();
}

/* the OSD ejects the disc (unlocked) during a READ: the READ ends first
   (CHECK 0B/00/00, error B4; the card op over), the drive empty */
static void t_osd_eject(void)
{
	uint8_t c[12];
	unsigned char tfr[8];
	long k;
	begin("OSD eject during a READ: CHECK 0B/00/00 first (error B4), the run over, the drive empty");
	fresh_drive(1);
	read10(c, 0, 16);
	host_reset_model();
	memcpy(h.cdb, c, 12);
	host_command(tfr, 0, 0xFFFE, 0xA0);
	ide_port = 1;
	CD_HandleCommand(1, tfr);
	for (k = 0; k < 1000 && CD_Busy() && !(h.blocks == 1 && fop); k++)
		cd_pass();
	EXPECT(CD_Busy() && fop && h.blocks == 1, "the READ is not in its second block's run (blocks %d)", h.blocks);
	EXPECT(CD_Eject() == CD_OK, "eject refused");
	EXPECT(!CD_Busy() && !fop, "the READ or its run still in progress");
	EXPECT(check_end(0xB4), "status %02X error %02X", g.end_status, g.reg[1]);
	EXPECT(!cdrom.unit.media && cdrom.hdf.type == HDF_DISABLED, "the disc still in");
	cdb6(c, 0x03, 18);
	packet(c, 0xFFFE);
	EXPECT(good_end() && h.in[2] == 0x0B, "sense key %02X", h.in[2]);
	end();
}

static void t_reset_flag(void)
{
	begin("CD_Flags: rst_seen on the CD's port resets the unit, on the other port it does not");
	fresh_drive(1);
	cdrom.unit.locked = 1;
	CD_Flags(0, IDEF_RST_SEEN);
	EXPECT(cdrom.unit.locked == 1, "port 1's reset reached the port 2 drive");
	CD_Flags(1, IDEF_RST_SEEN);
	EXPECT(cdrom.unit.locked == 0 && cdrom.unit.ua_asc == 0x29, "port 2's reset did not");
	end();
}

/* ---- phase 3: CUE sheets ---- */

/* An empty drive, then this disc from the fake card; its UNIT ATTENTION
   consumed when it went in. */
static int insert_disc(const char *name11, const char *long_name)
{
	uint8_t c[12];
	int r;
	fresh_drive(0);
	r = CD_Insert(name11, long_name, iso_dir);
	if (r == CD_OK) {
		cdb6(c, 0x00, 0);
		packet(c, 0xFFFE);
		host_reset_model();
	}
	return r;
}

static void t_cue_bincue(void)
{
	uint8_t c[12];
	begin("CUE + BIN (MODE1/2352, audio): user data from byte 16, a block per sector; audio 05/64/00");
	EXPECT(insert_disc("GAME    CUE", "Game") == CD_OK, "insert refused: '%s'", CD_Message());
	EXPECT(cdrom.unit.media && cdrom.unit.sectors == BIN_SECTORS, "sectors %u", (unsigned)cdrom.unit.sectors);
	EXPECT(strcmp(cdrom.unit.name, "Game") == 0, "name '%s'", cdrom.unit.name);
	EXPECT(memcmp(config.secondaryhardfile[0].name, "GAME    ", 8) == 0 &&
	       config.secondaryhardfile[0].present == CD_PRESENT_CUE, "config: '%.8s' present %u",
	       config.secondaryhardfile[0].name, config.secondaryhardfile[0].present);
	EXPECT(memcmp(cdrom.hdf.file.name, "GAME    BIN", 11) == 0, "data file '%.11s'", cdrom.hdf.file.name);
	read10(c, 0, 3);
	packet(c, 0xFFFE);
	EXPECT(h.phase_errors == 0, "phase errors");
	EXPECT(h.blocks == 3 && h.block_bytes[0] == 2048 && h.block_bytes[2] == 2048, "blocks %d", h.blocks);
	EXPECT(h.in_len == 3 * 2048 && iso_matches(0, 3 * 2048), "user data of sectors 0-2");
	EXPECT(good_end(), "status phase");
	read10(c, 18, 2);
	packet(c, 0xFFFE);
	EXPECT(h.in_len == 2 * 2048 && iso_matches(18, 2 * 2048) && good_end(), "sectors 18-19");
	read10(c, 5, 1);
	packet(c, 0x0400);
	EXPECT(h.phase_errors == 0 && h.blocks == 2 && h.block_bytes[1] == 1024 && iso_matches(5, 2048) && good_end(),
	       "a 1 KB limit: blocks %d", h.blocks);
	read10(c, 19, 2);	/* sector 20 is track 2's INDEX 00 */
	packet(c, 0xFFFE);
	EXPECT(h.blocks == 0 && check_end(0x54), "into the audio track: blocks %d error %02X", h.blocks, g.reg[1]);
	end();
}

static void t_cue_mixed(void)
{
	static const uint8_t toc[28] = {
		0x00, 0x1A, 0x01, 0x02,
		0x00, 0x14, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x00, 0x10, 0x02, 0x00, 0x00, 0x00, 0x00, 214,
		0x00, 0x10, 0xAA, 0x00, 0x00, 0x00, 0x00, 224
	};
	uint8_t c[12];
	begin("CUE + ISO + WAV by long name: ISO sectors on the direct path, TOC with the audio track");
	EXPECT(insert_disc("MIXED   CUE", "Mixed") == CD_OK, "insert refused: '%s'", CD_Message());
	EXPECT(cdrom.unit.sectors == ISO_SECTORS + 150 + WAV_SECTORS, "sectors %u", (unsigned)cdrom.unit.sectors);
	read10(c, 60, 4);
	packet(c, 0xFFFE);
	EXPECT(h.phase_errors == 0 && h.blocks == 1 && h.block_bytes[0] == 8192, "blocks %d first %u", h.blocks, h.block_bytes[0]);
	EXPECT(h.in_len == 8192 && iso_matches(60, 8192) && good_end(), "sectors 60-63");
	memset(c, 0, 12);
	c[0] = 0x43;
	c[7] = 0x00;
	c[8] = 0xFF;
	packet(c, 0xFFFE);
	EXPECT(h.in_len == 28 && memcmp(h.in, toc, 28) == 0 && good_end(), "TOC: %u bytes, track 2 %02X/%u",
	       h.in_len, h.in[13], h.in[19]);
	read10(c, 64, 1);	/* track 2's PREGAP */
	packet(c, 0xFFFE);
	EXPECT(check_end(0x54), "audio gap read: error %02X", g.reg[1]);
	end();
}

static void t_cue_split(void)
{
	uint8_t c[12];
	unsigned i;
	int zeros = 1, raw = 1;
	begin("a READ across a POSTGAP into another file: ISO direct, zeros, BIN user data; the data file follows");
	EXPECT(insert_disc("TWODATA CUE", "Two") == CD_OK, "insert refused: '%s'", CD_Message());
	EXPECT(cdrom.unit.sectors == ISO_SECTORS + 2 + BIN_SECTORS, "sectors %u", (unsigned)cdrom.unit.sectors);
	read10(c, 62, 6);
	packet(c, 0xFFFE);
	EXPECT(h.phase_errors == 0, "phase errors");
	EXPECT(h.blocks == 5 && h.block_bytes[0] == 4096 && h.block_bytes[1] == 2048 && h.block_bytes[4] == 2048,
	       "blocks %d: %u %u", h.blocks, h.block_bytes[0], h.block_bytes[1]);
	EXPECT(h.in_len == 6 * 2048 && iso_matches(62, 4096), "ISO sectors 62-63");
	for (i = 0; i < 4096; i++) {
		if (h.in[4096 + i])
			zeros = 0;
		if (h.in[8192 + i] != iso_byte(i))
			raw = 0;
	}
	EXPECT(zeros, "POSTGAP sectors not zero");
	EXPECT(raw, "BIN sectors 0-1 user data");
	EXPECT(good_end(), "status phase");
	EXPECT(memcmp(cdrom.hdf.file.name, "GAME    BIN", 11) == 0, "data file '%.11s'", cdrom.hdf.file.name);
	read10(c, 1, 1);
	packet(c, 0xFFFE);
	EXPECT(memcmp(cdrom.hdf.file.name, "MIXED~1 ISO", 11) == 0 && iso_matches(1, 2048) && good_end(),
	       "back to the ISO: '%.11s'", cdrom.hdf.file.name);
	end();
}

static void t_cue_names(void)
{
	begin("CUE FILE names: an 8.3 name in lower case (no long name entry) is found");
	EXPECT(insert_disc("LOWER   CUE", 0) == CD_OK, "insert refused: '%s'", CD_Message());
	EXPECT(cdrom.unit.sectors == 4, "sectors %u", (unsigned)cdrom.unit.sectors);
	EXPECT(strcmp(cdrom.unit.name, "LOWER   ") == 0, "name '%s'", cdrom.unit.name);
	EXPECT(memcmp(cdrom.hdf.file.name, "LOWER   BIN", 11) == 0, "data file '%.11s'", cdrom.hdf.file.name);
	end();
}

static void t_cue_refusals(void)
{
	begin("refused CUEs: the cause for the OSD, an empty drive, no config, the OSD's directory untouched");
	clear_errors = 0;
	iCurrentDirectory = 0x777;
	iPreviousDirectory = 0x666;
	EXPECT(insert_disc("BROKEN  CUE", "Broken") == CD_BADCUE, "a missing FILE accepted");
	EXPECT(strcmp(CD_Message(), "line 1: file missing") == 0, "message '%s'", CD_Message());
	EXPECT(!cdrom.unit.media && cdrom.hdf.type == HDF_DISABLED, "half a disc in the drive");
	EXPECT(config.secondaryhardfile[0].name[0] == 0 && !config.secondaryhardfile[0].present, "config names the refused disc");
	EXPECT(clear_errors > 0, "the failed lookup left a filesystem error for the OSD");
	EXPECT(iCurrentDirectory == 0x777 && iPreviousDirectory == 0x666, "directory state %lx %lx",
	       iCurrentDirectory, iPreviousDirectory);
	EXPECT(insert_disc("BADCMD  CUE", "Badcmd") == CD_BADCUE && strcmp(CD_Message(), "line 4: unknown cmd") == 0,
	       "unknown command: '%s'", CD_Message());
	EXPECT(insert_disc("MONOCUE CUE", "Mono") == CD_BADCUE && strcmp(CD_Message(), "line 1: WAV format") == 0,
	       "mono WAV: '%s'", CD_Message());
	EXPECT(insert_disc("NOSUCH  CUE", "Nope") == CD_NOFILE && CD_Message()[0] == 0, "missing CUE: '%s'", CD_Message());
	EXPECT(insert_disc("GAME    CUE", "Game") == CD_OK && CD_Message()[0] == 0, "a good CUE after: '%s'", CD_Message());
	end();
}

static void t_cue_config(void)
{
	begin("CD_Open from the config: present = CD_PRESENT_CUE opens NAME.CUE");
	memset(&config, 0, sizeof(config));
	config.secondaryhardfile[0].enabled = HDF_CDROM;
	memcpy(config.secondaryhardfile[0].name, "GAME    ", 8);
	strcpy(config.secondaryhardfile[0].long_name, "Game");
	config.secondaryhardfile[0].present = CD_PRESENT_CUE;
	config.hdfdir[2] = iso_dir;
	EXPECT(CD_Open(2) == CD_OK, "CD_Open refused: '%s'", CD_Message());
	EXPECT(cdrom.unit.media && cdrom.unit.sectors == BIN_SECTORS, "sectors %u", (unsigned)cdrom.unit.sectors);
	EXPECT(config.secondaryhardfile[0].present == CD_PRESENT_CUE, "present %u", config.secondaryhardfile[0].present);
	end();
}

/* ---- phase 3: CD audio through the glue ---- */

#define WAV_FILE 5	/* "MIXED~2 WAV" in fake_dir */
#define ISO2_FILE 4	/* "MIXED~1 ISO" */

static void play10(uint8_t *c, uint32_t lba, uint16_t len)
{
	memset(c, 0, 12);
	c[0] = 0x45;
	c[2] = (uint8_t)(lba >> 24); c[3] = (uint8_t)(lba >> 16); c[4] = (uint8_t)(lba >> 8); c[5] = (uint8_t)lba;
	c[7] = (uint8_t)(len >> 8); c[8] = (uint8_t)len;
}

/* The mixed disc in, track 2 (LBA 214, 10 sectors of WAV) playing. */
static void playing_mixed(void)
{
	uint8_t c[12];
	EXPECT(insert_disc("MIXED   CUE", "Mixed") == CD_OK, "insert refused: '%s'", CD_Message());
	memset(file_reads, 0, sizeof(file_reads));
	audio_claims = 0;
	play10(c, 214, 10);
	packet(c, 0xFFFE);
}

static void t_play(void)
{
	uint8_t c[12];
	int wav_reads;
	begin("PLAY AUDIO: GOOD, the player runs from the WAV (second file); READ SUB-CHANNEL sees it");
	playing_mixed();
	EXPECT(good_end(), "status: %02X error %02X", g.end_status, g.reg[1]);
	EXPECT(cda_status() == CDA_PLAYING && audio_claims == 1 && audio_ena, "player: status %02X claims %d ena %d",
	       (unsigned)cda_status(), audio_claims, audio_ena);
	EXPECT(file_reads[WAV_FILE] > 0, "nothing read from the WAV");
	EXPECT(memcmp(cdrom.hdf.file.name, "MIXED~1 ISO", 11) == 0, "the data file moved to '%.11s'", cdrom.hdf.file.name);
	memset(c, 0, 12);
	c[0] = 0x42;
	c[2] = 0x40;
	c[3] = 0x01;
	c[8] = 16;
	packet(c, 0xFFFE);
	EXPECT(h.in_len == 16 && h.in[1] == 0x11 && h.in[5] == 0x10 && h.in[6] == 2 && good_end(),
	       "sub-channel: status %02X control %02X track %u", h.in[1], h.in[5], h.in[6]);
	wav_reads = file_reads[WAV_FILE];
	read10(c, 0, 8);	/* data while the music plays: cd_wait polls the player */
	packet(c, 0x0800);
	EXPECT(h.in_len == 8 * 2048 && iso_matches(0, 8 * 2048) && good_end(), "data read while playing");
	EXPECT(file_reads[WAV_FILE] >= wav_reads, "WAV reads went backwards");
	EXPECT(cda_status() == CDA_PLAYING || cda_status() == CDA_COMPLETED, "player: %02X", (unsigned)cda_status());
	end();
}

static void t_play_refused(void)
{
	uint8_t c[12];
	begin("PLAY AUDIO of a data track: CHECK 05/64/00, the player stays idle");
	EXPECT(insert_disc("MIXED   CUE", "Mixed") == CD_OK, "insert refused: '%s'", CD_Message());
	audio_claims = 0;
	play10(c, 10, 10);
	packet(c, 0xFFFE);
	EXPECT(check_end(0x54), "status %02X error %02X", g.end_status, g.reg[1]);
	EXPECT(cda_status() == CDA_IDLE && audio_claims == 0, "player %02X claims %d", (unsigned)cda_status(), audio_claims);
	end();
}

static void t_play_stops(void)
{
	uint8_t c[12];
	begin("the music stops on STOP PLAY, START STOP stop, eject, Amiga reset, a new disc");
	playing_mixed();
	memset(c, 0, 12);
	c[0] = 0x4E;
	packet(c, 0xFFFE);
	EXPECT(good_end() && cda_status() == CDA_IDLE && !audio_ena && audio_last == CDA_CLEAR, "STOP PLAY: %02X",
	       (unsigned)cda_status());

	playing_mixed();
	memset(c, 0, 12);
	c[0] = 0x4B;	/* PAUSE */
	packet(c, 0xFFFE);
	EXPECT(good_end() && cda_status() == CDA_PAUSED && !audio_ena, "PAUSE: %02X", (unsigned)cda_status());
	c[8] = 0x01;	/* RESUME */
	packet(c, 0xFFFE);
	EXPECT(good_end() && cda_status() == CDA_PLAYING && audio_ena, "RESUME: %02X", (unsigned)cda_status());
	cdb6(c, 0x1B, 0x00);	/* START STOP UNIT: stop */
	packet(c, 0xFFFE);
	EXPECT(good_end() && cda_status() == CDA_IDLE && cdrom.unit.media, "START STOP stop: %02X", (unsigned)cda_status());

	playing_mixed();
	cdb6(c, 0x1B, 0x02);	/* eject */
	packet(c, 0xFFFE);
	EXPECT(good_end() && cda_status() == CDA_IDLE && !cdrom.unit.media, "eject: %02X", (unsigned)cda_status());

	playing_mixed();
	CD_Flags(1, IDEF_RST_SEEN);
	EXPECT(cda_status() == CDA_IDLE, "Amiga reset: %02X", (unsigned)cda_status());

	playing_mixed();
	EXPECT(CD_Insert("GAME    CUE", "Game", iso_dir) == CD_OK && cda_status() == CDA_IDLE, "new disc: %02X",
	       (unsigned)cda_status());
	end();
}

/* ---- phase 3: READ CD, MODE SELECT volume ---- */

static void t_read_cd(void)
{
	uint8_t c[12];
	unsigned i;
	int gap = 1, cdda = 1;
	begin("READ CD: silent gap and WAV sectors as 2352-byte CD-DA, ISO sectors as 2048 user bytes");
	EXPECT(insert_disc("MIXED   CUE", "Mixed") == CD_OK, "insert refused: '%s'", CD_Message());
	memset(c, 0, 12);
	c[0] = 0xBE;
	c[4] = 0x00; c[5] = 212;	/* LBA 212: two PREGAP sectors, then track 2 */
	c[8] = 4;
	c[9] = 0x10;
	packet(c, 0xFFFE);
	EXPECT(h.phase_errors == 0 && h.blocks == 4 && h.block_bytes[0] == 2352 && h.block_bytes[3] == 2352,
	       "blocks %d first %u", h.blocks, h.block_bytes[0]);
	for (i = 0; i < 2 * 2352; i++) {
		if (h.in[i])
			gap = 0;
		if (h.in[2 * 2352 + i] != wav_byte(44 + i))
			cdda = 0;
	}
	EXPECT(h.in_len == 4 * 2352 && gap && cdda, "data: gap %d cdda %d", gap, cdda);
	EXPECT(good_end(), "status phase");
	c[5] = 62;	/* ISO sectors 62-63 */
	c[8] = 2;
	packet(c, 0xFFFE);
	EXPECT(h.blocks == 1 && h.in_len == 4096 && iso_matches(62, 4096) && good_end(), "ISO through READ CD: blocks %d",
	       h.blocks);
	end();
}

static void t_volume_select(void)
{
	static const uint8_t mute[24] = {
		0, 0, 0, 0, 0, 0, 0, 0,
		0x0E, 0x0E, 0x04, 0, 0, 0, 0, 0, 0x01, 0x00, 0x02, 0x00, 0, 0, 0, 0
	};
	uint8_t c[12];
	unsigned i;
	int quiet = 1;
	begin("MODE SELECT page 0E through the glue: the volume reaches the player (0 = silence)");
	EXPECT(insert_disc("MIXED   CUE", "Mixed") == CD_OK, "insert refused: '%s'", CD_Message());
	memset(c, 0, 12);
	c[0] = 0x55;
	c[8] = 24;
	memcpy(h.out, mute, 24);
	h.out_len = 24;
	packet(c, 0xFFFE);
	EXPECT(good_end() && cdrom.unit.volume[0] == 0 && cdrom.unit.volume[1] == 0, "volume %02X %02X",
	       cdrom.unit.volume[0], cdrom.unit.volume[1]);
	play10(c, 214, 10);
	packet(c, 0xFFFE);
	for (i = 0; i < 0x8000; i++)
		if (ring[i])
			quiet = 0;
	EXPECT(cda_status() == CDA_PLAYING && quiet, "muted play: status %02X, ring silent %d", (unsigned)cda_status(), quiet);
	end();
}

/* Review fix (2026-10-16): an Amiga reset while the music plays and no
   port-2 command follows (a floppy game, a system without atapi.device)
   must stop the player at the next main-loop poll (13.7 "reset: stop"). */
static void t_reset_idle(void)
{
	begin("Amiga reset while playing, no command after it: the main-loop poll stops the music");
	playing_mixed();
	EXPECT(cda_status() == CDA_PLAYING, "player: %02X", (unsigned)cda_status());
	g.rst_pending = 1;	/* Ctrl-A-A: the CD port's rst_seen, nothing else */
	CD_AudioPoll();
	EXPECT(cda_status() == CDA_IDLE && !audio_ena, "after reset: player %02X ena %d",
	       (unsigned)cda_status(), audio_ena);
	end();
}

/* The board deadlock of 2026-10-20: the transfer loops of hdd.c and fdd.c
   poll the player between blocks, and a flags read there (a CMD_IDE_REGS_RD
   of the CD's port) re-latches the Gayle's firmware port in the middle of a
   port-1 transfer.  CD_AudioRefill reads no flags: a pending rst_seen stays
   for the main loop's CD_AudioPoll, which still stops the music (13.7). */
static void t_refill_no_flags(void)
{
	unsigned long t0;
	begin("CD_AudioRefill reads no IDE flags (transfer loops); CD_AudioPoll still stops on a reset");
	playing_mixed();
	EXPECT(cda_status() == CDA_PLAYING, "player: %02X", (unsigned)cda_status());
	g.rst_pending = 1;
	t0 = now_ms;
	CD_AudioRefill();
	CD_AudioRefill();
	EXPECT(g.rst_pending == 1 && now_ms == t0, "the refill read the CD port's flags (rst_pending %d, %lu reads)",
	       g.rst_pending, now_ms - t0);
	EXPECT(cda_status() == CDA_PLAYING, "player after the refill: %02X", (unsigned)cda_status());
	CD_AudioPoll();
	EXPECT(cda_status() == CDA_IDLE && !audio_ena, "after the main-loop poll: player %02X ena %d",
	       (unsigned)cda_status(), audio_ena);
	end();
}

/* findings/sdcard-engine Task 11a: during an HDD command the main loop
   (main.c PollDisks) calls CD_AudioRefill on every pass, not CD_AudioPoll
   (hdd_busy() stubbed here: cdrom_test does not link the HDD path; the real
   HDD write with the player refilling between its runs is hdd_test's
   cd_audio_during_write):
   the player stays fed by the refill alone over a long HDD write (100
   passes of 1 ms, the track 133 ms long: no underrun), no
   IDE flags are read (a pending rst_seen stays: the music goes on), and
   CD_Locked reads none either (the lock kept); with the command over the
   poll and CD_Locked read them again */
static void t_cd_flags_during_hdd(void)
{
	uint8_t c[12];
	uint32_t u0;
	int wav0, k;
	unsigned long t0;
	begin("cd_flags_during_hdd: the refill alone during an HDD command, no IDE flags read, CD_Locked keeps the lock");
	playing_mixed();
	cdb6(c, 0x1E, 0x01);	/* PREVENT MEDIUM REMOVAL */
	packet(c, 0xFFFE);
	EXPECT(CD_Locked(), "not locked");
	u0 = cda_underruns();
	wav0 = file_reads[WAV_FILE];
	hdd_cmd_running = 1;
	g.rst_pending = 1;	/* would stop the music and the lock at a flags read */
	t0 = now_ms;
	for (k = 0; k < 100; k++) {
		now_ms++;	/* the pass's HDD work */
		CD_AudioRefill();
	}
	EXPECT(CD_Locked(), "the lock dropped while the HDD command runs");
	EXPECT(g.rst_pending == 1, "IDE flags read during the HDD command");
	EXPECT(now_ms - t0 == 100, "the refill polled the Gayle (%lu ms)", now_ms - t0 - 100);
	EXPECT(cda_underruns() == u0, "underruns during the write: %u", (unsigned)(cda_underruns() - u0));
	EXPECT(file_reads[WAV_FILE] >= wav0, "the WAV reads went backwards");
	EXPECT(cda_status() == CDA_PLAYING, "player: %02X", (unsigned)cda_status());
	hdd_cmd_running = 0;
	EXPECT(!CD_Locked(), "after the command: the reset seen, the lock cleared");
	CD_AudioPoll();
	EXPECT(cda_status() == CDA_IDLE, "after the command: the poll's flags stop the music: %02X", (unsigned)cda_status());
	end();
}

static void t_playing_track(void)
{
	uint8_t c[12];
	begin("CD_PlayingTrack: the track while playing or paused, 0 otherwise (the OSD's play mark)");
	EXPECT(insert_disc("MIXED   CUE", "Mixed") == CD_OK, "insert refused: '%s'", CD_Message());
	EXPECT(CD_PlayingTrack() == 0, "track %d before any play", CD_PlayingTrack());
	play10(c, 214, 10);
	packet(c, 0xFFFE);
	EXPECT(CD_PlayingTrack() == 2, "playing: track %d", CD_PlayingTrack());
	memset(c, 0, 12);
	c[0] = 0x4B;	/* PAUSE */
	packet(c, 0xFFFE);
	EXPECT(CD_PlayingTrack() == 2, "paused: track %d", CD_PlayingTrack());
	c[0] = 0x4E;	/* STOP */
	packet(c, 0xFFFE);
	EXPECT(CD_PlayingTrack() == 0, "stopped: track %d", CD_PlayingTrack());
	end();
}

int main(void)
{
	make_wav_header(wav_header, WAV_SECTORS * 2352, 2);
	make_wav_header(mono_header, 2352, 1);

	t_open();
	t_inquiry();
	t_limit_split();
	t_odd_length();
	t_read_one_block();
	t_read_blocks();
	t_read_limit();
	t_slow_host();
	t_read_last();
	t_no_disc();
	t_unit_attention();
	t_mode_select();
	t_identify_packet();
	t_ata_commands();
	t_lock_and_eject();
	t_osd_insert_eject();
	t_reset_mid_command();
	t_reset_mid_read();
	t_timeout();
	t_read_error();
	t_read_abandon();
	t_read_eoc();
	t_read_last_chunk_error();
	t_cluster_runs();
	t_seek_wait();
	t_seek_error();
	t_error_reset();
	t_osd_eject();
	t_locked_eject();
	t_reset_flag();
	t_cue_bincue();
	t_cue_mixed();
	t_cue_split();
	t_cue_names();
	t_cue_refusals();
	t_cue_config();
	t_play();
	t_play_refused();
	t_play_stops();
	t_reset_idle();
	t_refill_no_flags();
	t_cd_flags_during_hdd();
	t_read_cd();
	t_volume_select();
	t_playing_track();

	printf("\n%d cases: %d passed, %d failed (%d failed checks)\n",
	       cases_run, cases_passed, cases_run - cases_passed, total_fails);
	return total_fails ? 1 : 0;
}

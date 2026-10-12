/*
 * Host test for the CD-ROM board glue (fw/ctrl_832/cdrom.c), task 1.4.
 *
 * Plan: findings/cdrom/plan.md 7.1, 7.3 (packet mode), 7.4, 9.
 * Build and run: make -C fw/ctrl_832/test
 *
 * cdrom.c is linked as it is built for the 832, against fakes of what it
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
 * The ISO is synthetic: byte i of sector n is (n * 7 + i) & 0xff, with
 * the sector number in its first four bytes.
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
#include "atapi.h"
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
hdfTYPE hdf[HDD_SLOTS];
unsigned char core_caps = CORE_CAPS_IDE2;

hardfileTYPE *SlotConfig(int slot)
{
	return (slot & 2) ? &config.secondaryhardfile[slot & 1] : &config.hardfile[slot & 1];
}

/* the timer: every poll advances it 1 ms */
static unsigned long now_ms;
unsigned long GetTimer(unsigned long offset) { return (now_ms + offset) << 16; }
unsigned long CheckTimer(unsigned long t) { return ((t - (now_ms << 16)) & 0x80000000) ? 1 : 0; }

/* ---- the ISO and the FAT fakes ---- */

#define ISO_SECTORS 64
static char iso_name[12] = "TESTDISCISO";	/* 8.3 without the dot */
static unsigned long iso_dir = 0x1234;
static unsigned long file_pos512;		/* HardFileSeek / FileReadEx position */
static int fail_read_at = -1;			/* FileReadEx fails on this call */
static int reads;

static uint8_t iso_byte(unsigned long pos)
{
	unsigned long n = pos / ATAPI_SECTOR_SIZE, i = pos % ATAPI_SECTOR_SIZE;
	if (i < 4)
		return (uint8_t)(n >> (24 - 8 * i));
	return (uint8_t)(n * 7 + i);
}

int ValidateDirectory(unsigned long directory) { return directory == iso_dir || directory == 0; }
void ChangeDirectory(unsigned long iStartCluster) { (void)iStartCluster; }

unsigned char FileOpen(fileTYPE *file, const char *name)
{
	if (memcmp(name, iso_name, 11) != 0)
		return 0;
	memcpy(file->name, name, 11);
	file->size = ISO_SECTORS * ATAPI_SECTOR_SIZE;
	file->sector = 0;
	return 1;
}

void BuildHardfileIndex(hdfTYPE *h) { (void)h; }

unsigned char HardFileSeek(hdfTYPE *h, unsigned long lba)
{
	(void)h;
	file_pos512 = lba;
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

void WriteTaskFile(int error, int sector_count, int sector_number, int cylinder_low, int cylinder_high, int drive_head)
{
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
	EXPECT(g.busy, "xfer written while not busy");
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
	now_ms++;
	host_act();
	return (unsigned char)((g.pkt && g.pio_out && g.xfer_done) ? 0x08 : 0x00);
}

void WriteIDEData(const unsigned char *buf, unsigned int bytes)
{
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
	EXPECT(g.pio_out && g.xfer_done, "data read without a complete pio-out phase");
	EXPECT(bytes <= g.fifo_len, "reading %u bytes of %u", bytes, g.fifo_len);
	if (buf)
		memcpy(buf, g.fifo, bytes);
}

unsigned char FileReadEx(fileTYPE *file, unsigned char *pBuffer, unsigned long nSize)
{
	unsigned long i;
	(void)file;
	if (reads++ == fail_read_at)
		return 0;
	EXPECT(pBuffer == 0, "FileReadEx into a buffer, not the direct transfer");
	EXPECT(g.pio_in, "direct transfer without pio in");
	for (i = 0; i < nSize * 512 && g.fifo_len < sizeof(g.fifo); i++)
		g.fifo[g.fifo_len++] = iso_byte(file_pos512 * 512 + i);
	file_pos512 += nSize;
	return 1;
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
	int dead = h.dead, reset_at = h.reset_at_poll;
	uint8_t out[4096];
	unsigned out_len = h.out_len;
	memcpy(out, h.out, sizeof(out));
	host_reset_model();
	h.dead = dead;
	h.reset_at_poll = reset_at;
	memcpy(h.out, out, sizeof(out));
	h.out_len = out_len;
	memcpy(h.cdb, cdb, 12);
	host_command(tfr, 0, limit, 0xA0);
	ide_port = 1;
	CD_HandleCommand(1, tfr);
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
	reads = 0;
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

int main(void)
{
	t_open();
	t_inquiry();
	t_limit_split();
	t_odd_length();
	t_read_one_block();
	t_read_blocks();
	t_read_limit();
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
	t_reset_flag();

	printf("\n%d cases: %d passed, %d failed (%d failed checks)\n",
	       cases_run, cases_passed, cases_run - cases_passed, total_fails);
	return total_fails ? 1 : 0;
}

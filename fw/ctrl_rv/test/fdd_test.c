/* fdd_test: the floppy emulation's MFM track streams and its track-write
 * decoder (Task 13, plan 7.3).
 *   fdd_test <dir>
 * <dir> holds what gold/mfm.py wrote (the Makefile runs it first): disk.adf,
 * the read streams of every track, the write streams and the ADFs after
 * them, fddcases.h (compiled in).
 *
 * Two copies of fdd.c run on the same mock, one after the other, on the same
 * scenarios: the RV source (../fdd.c) and the 832's (fw/ctrl_832/fdd.c, built
 * -std=gnu17 by the Makefile with its globals renamed *_832: df_832,
 * HandleFDD_832, ...).  fdd.c is byte-level code, so the host build of the
 * 832 source is the 832's behaviour.  Each scenario starts at HandleFDD()
 * with the status bytes the main loop passes, as on the target.
 *   - ReadTrack: a mock paula_floppy on the FPGA chip select answers the six
 *     status bytes of each frame (rtl/minimig/paula_floppy.v spi_tx_data_0..2:
 *     {sel, drives, .., trackwr, trackrd}, track, dsksync, {dmaen, dsklen})
 *     and asks (CMD_RDTRK) for a given number of frames.  The bytes the
 *     firmware sends after the status bytes (SendSector: preamble, sync,
 *     header, label, checksums, odd/even data; SendGap) are taken from the
 *     SPI trace and compared with mfm.py's stream; the whole trace of the RV
 *     source with the 832 source's.  Tracks 0 (cylinder 0 side 0) and 159
 *     (cylinder 79 side 1) first, then every track 0..159 (the track/side
 *     arithmetic: track * 11 sectors, the cluster cache), a read that stops
 *     after 4 sectors and goes on at sector 4 (the same-track path), a track
 *     change in the middle of a read, the sync words of the Copy Lock
 *     workaround (fdd.c ReadTrack: dsksync 0x0000, 0x8914 Wiz'n'Liz, 0xA144
 *     North&South are sent as 0x4489) and one that is passed through
 *     (0x4891, Prince of Persia), and DEBUG on (the UART text RV == 832).
 *   - WriteTrack (FindSync, GetHeader, GetData): a mock write FIFO
 *     (paula_floppy_fifo, 2048 words) that the "Amiga" fills with mfm.py's
 *     write stream (real MFM clock bits), `rate` words per status poll; the
 *     status bytes report {trackwr} and {dmaen & dsklen[14], fifo_cnt} as
 *     paula_floppy's wr_fifo_status, every further word read pops the FIFO.
 *     The ADF afterwards must equal mfm.py's write_<case>.adf (disk.adf with
 *     the written sectors replaced: every other byte unchanged), for three
 *     cases x three rates (2048: the FIFO filled at once, 300, 7: GetHeader
 *     and GetData poll until 25 / 516 words are there); the whole stream
 *     read, never past the FIFO's count.  A write-protected disk (nothing
 *     written, "Disk write protected"), a sector with a bad header checksum
 *     and one with a bad data checksum (that sector not written, FatalError
 *     26 / 29, the others written).
 *   - UpdateDriveStatus and the motor / step drive sounds of HandleFDD.
 * The file layer is a direct ADF mock with FAT semantics: 4-sector clusters
 * in a scattered chain, FileRead/FileWrite address the sector through
 * file.cluster and file.sector & 3 (as fat.c does) and fail the case when
 * the two disagree, FileNextSector follows the chain; the cluster cache is
 * filled as InsertFloppy (menu.c) does.  The test reports with
 * fprintf(stdout) (say); the firmware's printf (rvlibc.c) goes to the mock
 * UART. */
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "errors.h"
#include "hardware.h"
#include "fat.h"
#include "fdd.h"
#include "config.h"
#include "cdrom.h"
#include "drivesounds.h"
#include "mock_hw.h"

#include "fddcases.h"

/* ---- the 832's fdd.c (Makefile: fw/ctrl_832/fdd.c, symbols renamed) ---- */
extern unsigned char DEBUG, DEBUG_832;
extern adfTYPE df_832[4];
void HandleFDD_832(unsigned char c1, unsigned char c2, unsigned char c3, unsigned char c4);
void UpdateDriveStatus_832(void);

static const struct src {
	const char *name;
	adfTYPE *df;
	unsigned char *debug;
	void (*handle)(unsigned char, unsigned char, unsigned char, unsigned char);
	void (*status)(void);
} srcs[2] = {
	{ "RV", df, &DEBUG, HandleFDD, UpdateDriveStatus },
	{ "832", df_832, &DEBUG_832, HandleFDD_832, UpdateDriveStatus_832 },
};

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

static void die(const char *what)
{
	say("FAIL %s\n", what);
	exit(1);
}

/* ---- what fdd.c needs from the rest of the firmware ---- */
fileTYPE file;
unsigned char sector_buffer[1024] __attribute__((aligned(4)));
static int audio_polls;
static char sounds[64];
static size_t nsounds;

void CD_AudioPoll(void) { audio_polls++; }
void drivesounds_queueevent(enum DriveSound_Type type)
{
	if (nsounds + 1 < sizeof sounds) sounds[nsounds++] = (char)('A' + type);
	sounds[nsounds] = 0;
}

/* ---- the ADF behind the file layer ----------------------------------------
 * 1760 sectors in 440 clusters of 4 sectors; cluster k of the file is
 * CL_BASE + (k * 173) mod 440 (173 is prime to 440: a permutation, so the
 * chain jumps around as on a fragmented card) */
#define ADF_SECTORS (MFM_TRACKS * 11)
#define ADF_BYTES (ADF_SECTORS * 512)
#define CL_SECT 4
#define NCL (ADF_SECTORS / CL_SECT)
#define CL_BASE 1000
static uint8_t adf[ADF_BYTES], disk[ADF_BYTES];
static int cl_index[NCL];			/* cluster - CL_BASE -> k */
static const char *what_now = "";		/* the case, for the file layer's FAILs */
static int file_reads, file_writes, file_errs;

static unsigned long cl_of(int k) { return CL_BASE + (unsigned long)((k * 173) % NCL); }
static int index_of(unsigned long cl)
{
	return (cl >= CL_BASE && cl < CL_BASE + NCL) ? cl_index[cl - CL_BASE] : -1;
}

unsigned char FileNextSector(fileTYPE *f)
{
	f->sector++;
	if ((f->sector % CL_SECT) == 0) {
		int k = index_of(f->cluster);
		f->cluster = (k >= 0 && k + 1 < NCL) ? cl_of(k + 1) : 0x0FFFFFFF;
	}
	return 1;
}

/* the ADF sector that file.cluster and file.sector address together */
static long file_lba(const char *op, const fileTYPE *f)
{
	int k = index_of(f->cluster);
	if (k < 0) {
		if (file_errs++ < 4) say("FAIL %s: %s at cluster %lu: not in the ADF's chain\n", what_now, op, (unsigned long)f->cluster);
		return -1;
	}
	long n = (long)k * CL_SECT + (long)(f->sector % CL_SECT);
	if (n != (long)f->sector) {
		if (file_errs++ < 4) say("FAIL %s: %s: cluster %lu holds sector %ld, file.sector is %lu\n",
		                         what_now, op, (unsigned long)f->cluster, n, (unsigned long)f->sector);
		return -1;
	}
	return n;
}

unsigned char FileRead(fileTYPE *f, unsigned char *p)
{
	long n = file_lba("FileRead", f);
	file_reads++;
	if (n < 0) { memset(p, 0, 512); return 0; }
	memcpy(p, adf + n * 512, 512);
	return 1;
}

static int wlog[64], nwlog;
unsigned char FileWrite(fileTYPE *f, unsigned char *p)
{
	long n = file_lba("FileWrite", f);
	file_writes++;
	if (n < 0) return 0;
	if (nwlog < 64) wlog[nwlog++] = (int)n;
	memcpy(adf + n * 512, p, 512);
	return 1;
}

/* a disk in drive 0, as InsertFloppy (menu.c) leaves it */
static void insert(adfTYPE *d, int writable)
{
	fileTYPE f = { 0 };
	memset(d, 0, sizeof *d);
	d->tracks = MFM_TRACKS;
	f.cluster = cl_of(0);
	for (int t = 0; t < MFM_TRACKS; t++) {
		d->cache[t] = f.cluster;
		for (int j = 0; j < 11; j++) FileNextSector(&f);
	}
	d->status = DSK_INSERTED | (writable ? DSK_WRITABLE : 0);
	d->cluster_offset = d->cache[0];
	d->sector_offset = 0;
	d->track = 0;
	d->track_prev = (unsigned char)-1;
}

static uint8_t *slurp(const char *dir, const char *name, size_t *len)
{
	char path[512];
	snprintf(path, sizeof path, "%s/%s", dir, name);
	FILE *f = fopen(path, "rb");
	if (!f) { say("FAIL cannot open %s\n", path); exit(1); }
	fseek(f, 0, SEEK_END);
	long n = ftell(f);
	fseek(f, 0, SEEK_SET);
	uint8_t *p = malloc(n > 0 ? (size_t)n : 1);
	if (!p || fread(p, 1, (size_t)n, f) != (size_t)n) die("read error");
	fclose(f);
	*len = (size_t)n;
	return p;
}

/* ---- the SPI trace -------------------------------------------------------- */
static int nibble(char c) { return c <= '9' ? c - '0' : c - 'a' + 10; }

/* the bytes sent in the FPGA frames after their six status bytes, in
   order; frames counts them, bad the frames whose first six out bytes are
   not 00 (the status reads) or that are shorter */
struct sent { uint8_t *b; size_t n; int frames, bad; };
static struct sent fpga_bytes(const char *t)
{
	struct sent s = { malloc(strlen(t) / 3 + 1), 0, 0, 0 };
	if (!s.b) die("out of memory");
	while (*t) {
		const char *eol = strchr(t, '\n');
		if (!eol) eol = t + strlen(t);
		if (t[0] == '1' && t[1] == '0' && t[2] == ' ') {
			int k = 0;
			s.frames++;
			for (const char *p = t + 3; p + 1 < eol && *p != '/'; p += 3, k++) {
				uint8_t v = (uint8_t)(nibble(p[0]) << 4 | nibble(p[1]));
				if (k < 6) { if (v != 0) s.bad++; }
				else s.b[s.n++] = v;
			}
			if (k < 6) s.bad++;
		}
		t = *eol ? eol + 1 : eol;
	}
	return s;
}

/* the first line where two traces differ (1-based), 0 = equal */
static int trace_diff(const char *a, const char *b)
{
	int line = 1;
	for (; *a && *a == *b; a++, b++)
		if (*a == '\n') line++;
	return *a == *b ? 0 : line;
}

static int check_stream(const char *what, const char *who, const uint8_t *got, size_t ngot,
                        const uint8_t *want, size_t nwant)
{
	cases++;
	size_t i = 0;
	while (i < ngot && i < nwant && got[i] == want[i]) i++;
	if (i == ngot && i == nwant) return 1;
	fails++;
	if (i < ngot && i < nwant)
		say("FAIL %s: %s != mfm.py: byte %zu (sector slot %zu, offset %zu) is %02x, want %02x (%zu bytes, want %zu)\n",
		    what, who, i, i / MFM_SECTOR_BYTES, i % MFM_SECTOR_BYTES, got[i], want[i], ngot, nwant);
	else
		say("FAIL %s: %s != mfm.py: %zu bytes, want %zu (equal up to byte %zu)\n", what, who, ngot, nwant, i);
	return 0;
}

/* ---- the mock paula_floppy: track read -------------------------------------
 * frame k of the command (0 = ReadTrack's first status read, before its
 * loop) asks for data (CMD_RDTRK) while k <= nsend; frame change_at reports
 * the track change_to */
#define SEL 0
#define DRIVES 1			/* status bits 5:4: one drive */
#define DSKLEN_WORDS 0x18BE		/* 6334 words: the 12668-byte track */
static struct rdmodel {
	int frame, pos, k;
	int track, nsend, change_at, change_to;
	unsigned sync;
} rm;

static unsigned char read_miso(void *ctx, unsigned char out)
{
	int f = mock_frames();
	if (f != rm.frame) { rm.frame = f; rm.pos = 0; rm.k++; }
	int pos = rm.pos++;
	switch (pos) {
	case 0: return (unsigned char)(SEL << 6 | DRIVES << 4 | (rm.k <= rm.nsend ? CMD_RDTRK : 0));
	case 1: return (unsigned char)(rm.k == rm.change_at ? rm.change_to : rm.track);
	case 2: return (unsigned char)(rm.sync >> 8);
	case 3: return (unsigned char)rm.sync;
	default: return (pos & 1) ? DSKLEN_WORDS & 0xFF : 0x80 | DSKLEN_WORDS >> 8;	/* {dmaen, dsklen} */
	}
}

struct run { char *trace; struct sent s; int reads, polls, errmask; char *uart; };

static void run_free(struct run *r) { free(r->trace); free(r->s.b); free(r->uart); }

static struct run read_run(const struct src *S, int track, int nsend, unsigned sync, int change_at, int change_to)
{
	struct run r;
	mock_reset();
	mock_script_fn(0x10, read_miso, NULL);
	rm = (struct rdmodel){ .frame = -1, .k = -1, .track = track, .nsend = nsend,
	                       .change_at = change_at, .change_to = change_to, .sync = sync };
	file_reads = 0; audio_polls = 0; ClearError(ERROR_ALL);
	S->handle((unsigned char)(SEL << 6 | DRIVES << 4 | CMD_RDTRK), (unsigned char)track, 0, 0);
	r.trace = strdup(mock_trace());
	r.s = fpga_bytes(r.trace);
	r.reads = file_reads;
	r.polls = audio_polls;
	r.errmask = ErrorMask;
	r.uart = strdup(mock_uart());
	return r;
}

static uint8_t *tracks;		/* read_4489.bin: track t at t * MFM_TRACK_BYTES */

/* one read scenario on both sources: RV trace == 832 trace, each stream ==
   want; sources whose drive state is set up by the caller (insert) */
static void read_case(const char *what, int track, int nsend, unsigned sync, int change_at, int change_to,
                      const uint8_t *want, size_t nwant, int nframes)
{
	struct run r[2];
	char w[256];
	what_now = what;
	file_errs = 0;
	for (int i = 0; i < 2; i++) r[i] = read_run(&srcs[i], track, nsend, sync, change_at, change_to);
	int line = trace_diff(r[0].trace, r[1].trace);
	cases++;
	if (line) { fails++; say("FAIL %s: RV != 832 (SPI trace line %d)\n", what, line); }
	for (int i = 0; i < 2; i++) {
		check_stream(what, srcs[i].name, r[i].s.b, r[i].s.n, want, nwant);
		snprintf(w, sizeof w, "%s: %s FPGA frames", what, srcs[i].name);
		check(w, r[i].s.frames, nframes);
		snprintf(w, sizeof w, "%s: %s status bytes (6 x 00 out, every frame)", what, srcs[i].name);
		check(w, r[i].s.bad, 0);
		snprintf(w, sizeof w, "%s: %s errors", what, srcs[i].name);
		check(w, r[i].errmask, 0);
	}
	snprintf(w, sizeof w, "%s: FileRead calls RV == 832", what);
	check(w, r[0].reads, r[1].reads);
	snprintf(w, sizeof w, "%s: CD_AudioPoll calls (one per FileRead)", what);
	check(w, r[0].polls, r[0].reads);
	snprintf(w, sizeof w, "%s: UART RV == 832", what);
	check(w, strcmp(r[0].uart, r[1].uart), 0);
	snprintf(w, sizeof w, "%s: file layer (cluster and sector agree)", what);
	check(w, file_errs, 0);
	for (int i = 0; i < 2; i++) run_free(&r[i]);
}

static void insert_both(int writable)
{
	for (int i = 0; i < 2; i++) insert(&srcs[i].df[SEL], writable);
}

/* a full track: frame 0, 11 sectors, the frame that stops */
static void read_track_case(const char *what, int t, unsigned sync, const uint8_t *want)
{
	insert_both(1);
	read_case(what, t, 11, sync, -1, 0, want, MFM_TRACK_BYTES, 13);
}

/* ---- the mock write FIFO (paula_floppy_fifo, 2048 words) -------------------
 * at the start of every FPGA frame the Amiga's DMA adds up to `rate` words
 * of its stream; the status bytes: trackwr while the DMA has words left or
 * the FIFO holds some, the FIFO count of that moment ({dmaen & dsklen[14],
 * 000, cnt[11:0]}); from byte 6 on every word read pops the FIFO */
#define FIFO_WORDS 2048
#define MAX_POLLS 200000
static struct wrmodel {
	int frame, pos, polls;
	int track;
	const uint8_t *w;
	size_t nwords, pushed, popped;
	unsigned rate, cnt, cur, overread;
	int active;
} wm;

static unsigned char write_miso(void *ctx, unsigned char out)
{
	int f = mock_frames();
	if (f != wm.frame) {
		size_t fifo = wm.pushed - wm.popped, add = wm.nwords - wm.pushed;
		wm.frame = f; wm.pos = 0; wm.polls++;
		if (add > wm.rate) add = wm.rate;
		if (add > FIFO_WORDS - fifo) add = FIFO_WORDS - fifo;
		wm.pushed += add;
		wm.cnt = (unsigned)(wm.pushed - wm.popped);
		/* a firmware that never stops polling: the "Amiga" gives up */
		wm.active = wm.polls < MAX_POLLS && (wm.pushed < wm.nwords || wm.cnt > 0);
	}
	int pos = wm.pos++;
	switch (pos) {
	case 0: return (unsigned char)(SEL << 6 | DRIVES << 4 | (wm.active ? CMD_WRTRK : 0));
	case 1: return (unsigned char)wm.track;
	case 2: return 0x44;
	case 3: return 0x89;
	case 4: return (unsigned char)((wm.active ? 0x80 : 0) | ((wm.cnt >> 8) & 0x0F));
	case 5: return (unsigned char)wm.cnt;
	default:
		if (!(pos & 1)) {
			if (wm.popped >= wm.pushed) { wm.overread++; wm.cur = 0; }
			else { wm.cur = (unsigned)wm.w[2 * wm.popped] << 8 | wm.w[2 * wm.popped + 1]; wm.popped++; }
			return (unsigned char)(wm.cur >> 8);
		}
		return (unsigned char)wm.cur;
	}
}

struct wres { uint8_t *adf; char *trace; int writes, errmask, erra; const char *errstr; int prev; size_t popped; unsigned overread; int polls; };

static struct wres write_run(const struct src *S, int track, const uint8_t *stream, size_t nbytes, unsigned rate, int writable)
{
	struct wres r;
	memcpy(adf, disk, ADF_BYTES);
	insert(&S->df[SEL], writable);
	mock_reset();
	mock_script_fn(0x10, write_miso, NULL);
	wm = (struct wrmodel){ .frame = -1, .track = track, .w = stream, .nwords = nbytes / 2, .rate = rate };
	file_writes = 0; nwlog = 0; ClearError(ERROR_ALL);
	S->handle((unsigned char)(SEL << 6 | DRIVES << 4 | CMD_WRTRK), (unsigned char)track, 0, 0);
	r.adf = malloc(ADF_BYTES);
	if (!r.adf) die("out of memory");
	memcpy(r.adf, adf, ADF_BYTES);
	r.trace = strdup(mock_trace());
	r.writes = file_writes;
	r.errmask = ErrorMask;
	r.erra = Errors[ERROR_FDD].a;
	r.errstr = Errors[ERROR_FDD].string;
	r.prev = S->df[SEL].track_prev;
	r.popped = wm.popped;
	r.overread = wm.overread;
	r.polls = wm.polls;
	return r;
}

/* the sectors where two ADFs differ, as text */
static void adf_diff(char *out, size_t n, const uint8_t *a, const uint8_t *b)
{
	size_t o = 0;
	int k = 0;
	out[0] = 0;
	for (int s = 0; s < ADF_SECTORS; s++)
		if (memcmp(a + s * 512, b + s * 512, 512)) {
			if (k++ < 8 && o + 16 < n) o += (size_t)snprintf(out + o, n - o, " %d (t%d s%d)", s, s / 11, s % 11);
		}
	if (k > 8 && o + 8 < n) snprintf(out + o, n - o, " ...");
}

/* one write scenario on both sources: the ADF afterwards == want, the RV
   trace == the 832's; errmask/erra: the ERROR_FDD state expected after it */
static void write_case(const char *what, int track, const uint8_t *stream, size_t nbytes, unsigned rate, int writable,
                       const uint8_t *want, int nwrites, int errmask, int erra, const char *errstr)
{
	struct wres r[2];
	char w[300], d[200];
	what_now = what;
	file_errs = 0;
	for (int i = 0; i < 2; i++) r[i] = write_run(&srcs[i], track, stream, nbytes, rate, writable);
	int line = trace_diff(r[0].trace, r[1].trace);
	cases++;
	if (line) { fails++; say("FAIL %s: RV != 832 (SPI trace line %d)\n", what, line); }
	for (int i = 0; i < 2; i++) {
		cases++;
		if (memcmp(r[i].adf, want, ADF_BYTES)) {
			fails++;
			adf_diff(d, sizeof d, r[i].adf, want);
			say("FAIL %s: %s: the ADF differs from mfm.py's in sectors%s\n", what, srcs[i].name, d);
		}
		snprintf(w, sizeof w, "%s: %s FileWrite calls", what, srcs[i].name);
		check(w, r[i].writes, nwrites);
		snprintf(w, sizeof w, "%s: %s words read (the whole stream)", what, srcs[i].name);
		check(w, (long)r[i].popped, (long)(nbytes / 2));
		snprintf(w, sizeof w, "%s: %s reads past the FIFO count", what, srcs[i].name);
		check(w, r[i].overread, 0);
		snprintf(w, sizeof w, "%s: %s polls below the model's limit", what, srcs[i].name);
		check(w, r[i].polls < MAX_POLLS, 1);
		snprintf(w, sizeof w, "%s: %s errors", what, srcs[i].name);
		check(w, r[i].errmask, errmask);
		if (errmask) {
			snprintf(w, sizeof w, "%s: %s error value", what, srcs[i].name);
			check(w, r[i].erra, erra);
			snprintf(w, sizeof w, "%s: %s error text \"%s\"", what, srcs[i].name, errstr);
			check(w, r[i].errstr && !strcmp(r[i].errstr, errstr), 1);
		}
		snprintf(w, sizeof w, "%s: %s track_prev -1 (the next read starts the track over)", what, srcs[i].name);
		check(w, r[i].prev, 0xFF);
	}
	snprintf(w, sizeof w, "%s: file layer (cluster and sector agree)", what);
	check(w, file_errs, 0);
	for (int i = 0; i < 2; i++) { free(r[i].adf); free(r[i].trace); }
}

/* byte offset of sector slot k of a write stream */
static size_t wsector(int k) { return MFM_WRITE_GAP_HEAD * 2 + (size_t)k * MFM_SECTOR_BYTES; }

int main(int argc, char **argv)
{
	char w[256];
	size_t n;
	if (argc != 2) { fprintf(stderr, "usage: fdd_test <dir>\n"); return 2; }
	const char *dir = argv[1];

	for (int k = 0; k < NCL; k++) cl_index[cl_of(k) - CL_BASE] = k;
	uint8_t *p = slurp(dir, "disk.adf", &n);
	if (n != ADF_BYTES) die("disk.adf: not 901120 bytes");
	memcpy(disk, p, ADF_BYTES);
	memcpy(adf, disk, ADF_BYTES);
	free(p);
	tracks = slurp(dir, "read_4489.bin", &n);
	if (n != (size_t)MFM_TRACKS * MFM_TRACK_BYTES) die("read_4489.bin: not 160 tracks");
	size_t n4891;
	uint8_t *t4891 = slurp(dir, "read_4891_t000.bin", &n4891);
	if (n4891 != MFM_TRACK_BYTES) die("read_4891_t000.bin: not one track");

	/* ---- ReadTrack: the two tracks of the golden files, then all 160 ---- */
	read_track_case("ReadTrack track 0 side 0", 0, 0x4489, tracks);
	read_track_case("ReadTrack track 79 side 1", 159, 0x4489, tracks + (size_t)159 * MFM_TRACK_BYTES);
	insert_both(1);
	for (int t = 0; t < MFM_TRACKS; t++) {
		snprintf(w, sizeof w, "ReadTrack track %d (cylinder %d side %d)", t, t / 2, t % 2);
		/* one drive stepping through the disk: the track changes every time */
		read_case(w, t, 11, 0x4489, -1, 0, tracks + (size_t)t * MFM_TRACK_BYTES, MFM_TRACK_BYTES, 13);
	}

	/* the same track again: ReadTrack goes on where it stopped (sector_offset) */
	{
		const uint8_t *t5 = tracks + (size_t)5 * MFM_TRACK_BYTES;
		uint8_t *rot = malloc(MFM_TRACK_BYTES);
		if (!rot) die("out of memory");
		size_t cut = 4 * MFM_SECTOR_BYTES;
		memcpy(rot, t5 + cut, MFM_TRACK_BYTES - cut);
		memcpy(rot + MFM_TRACK_BYTES - cut, t5, cut);
		insert_both(1);
		read_case("ReadTrack track 5, 4 sectors", 5, 4, 0x4489, -1, 0, t5, cut, 6);
		read_case("ReadTrack track 5 again: sectors 4..10, gap, 0..3", 5, 11, 0x4489, -1, 0, rot, MFM_TRACK_BYTES, 13);
		free(rot);
	}
	/* the Amiga steps away in the middle: frame 3 reports track 8, the sector is not sent */
	insert_both(1);
	read_case("ReadTrack track 7, track change after 2 sectors", 7, 11, 0x4489, 3, 8,
	          tracks + (size_t)7 * MFM_TRACK_BYTES, 2 * MFM_SECTOR_BYTES, 4);
	for (int i = 0; i < 2; i++) {
		snprintf(w, sizeof w, "ReadTrack track 7, track change: %s track_prev", srcs[i].name);
		check(w, srcs[i].df[SEL].track_prev, 7);
	}

	/* the Copy Lock workaround (fdd.c ReadTrack, "workaround for Copy Lock in
	   Wiz'n'Liz and North&South"): paula_floppy reports the DSKSYNC the Amiga
	   set; 0x0000, 0x8914 and 0xA144 are sent as 0x4489, any other as it is */
	read_track_case("ReadTrack copy lock dsksync 8914", 0, 0x8914, tracks);
	read_track_case("ReadTrack copy lock dsksync A144", 0, 0xA144, tracks);
	read_track_case("ReadTrack copy lock dsksync 0000", 0, 0x0000, tracks);
	read_track_case("ReadTrack dsksync 4891 (passed through)", 0, 0x4891, t4891);

	/* DEBUG on: the track and sector messages, RV == 832 on the UART */
	for (int i = 0; i < 2; i++) *srcs[i].debug = 1;
	read_track_case("ReadTrack track 3, DEBUG", 3, 0x4489, tracks + (size_t)3 * MFM_TRACK_BYTES);
	for (int i = 0; i < 2; i++) *srcs[i].debug = 0;

	/* ---- WriteTrack: the cases of mfm.py, each at three FIFO fill rates ---- */
	static const unsigned rates[] = { FIFO_WORDS, 300, 7 };
	const size_t ncases = sizeof fdd_wcases / sizeof fdd_wcases[0];
	for (size_t c = 0; c < ncases; c++) {
		const struct fdd_wcase *wc = &fdd_wcases[c];
		char name[64];
		size_t ns, na;
		snprintf(name, sizeof name, "write_%s.bin", wc->name);
		uint8_t *stream = slurp(dir, name, &ns);
		snprintf(name, sizeof name, "write_%s.adf", wc->name);
		uint8_t *want = slurp(dir, name, &na);
		if (na != ADF_BYTES) die("write ADF: not 901120 bytes");
		for (size_t r = 0; r < sizeof rates / sizeof rates[0]; r++) {
			snprintf(w, sizeof w, "WriteTrack %s (track %d, %d sectors), FIFO +%u words per poll",
			         wc->name, wc->track, wc->nsec, rates[r]);
			write_case(w, wc->track, stream, ns, rates[r], 1, want, wc->nsec, 0, 0, NULL);
		}
		if (c == 0) {
			/* the same stream on a write-protected disk: nothing written */
			snprintf(w, sizeof w, "WriteTrack %s, write-protected", wc->name);
			write_case(w, wc->track, stream, ns, 300, 0, disk, 0, 1 << ERROR_FDD, 0, "Disk write protected");
		}
		if (!strcmp(wc->name, "subset1")) {
			/* a flipped data bit in the header checksum (its even long, bit
			   0) of the first sector, and in the data checksum of the
			   second: those sectors are dropped, the others written */
			uint8_t *bad = malloc(ns), *exp = malloc(ADF_BYTES);
			if (!bad || !exp) die("out of memory");
			for (int k = 0; k < 2; k++) {
				int s = wc->order[k];
				long lba = (long)wc->track * 11 + s;
				memcpy(bad, stream, ns);
				memcpy(exp, want, ADF_BYTES);
				memcpy(exp + lba * 512, disk + lba * 512, 512);
				/* sector: 4 preamble, 4 sync, 8 info, 32 label, 8 header checksum, 8 data checksum */
				bad[wsector(k) + (k == 0 ? 4 + 4 + 8 + 32 + 4 + 3 : 4 + 4 + 8 + 32 + 8 + 4 + 3)] ^= 0x01;
				snprintf(w, sizeof w, "WriteTrack %s bad %s checksum (sector %d)", wc->name, k == 0 ? "header" : "data", s);
				write_case(w, wc->track, bad, ns, 300, 1, exp, wc->nsec - 1, 1 << ERROR_FDD, k == 0 ? 26 : 29, "Bad checksum");
			}
			free(bad); free(exp);
		}
		free(stream); free(want);
	}

	/* ---- UpdateDriveStatus and the drive sounds of HandleFDD ---- */
	{
		char *keep[2];
		char snd[2][64];
		for (int i = 0; i < 2; i++) {
			adfTYPE *d = srcs[i].df;
			memset(d, 0, 4 * sizeof *d);
			d[0].status = DSK_INSERTED | DSK_WRITABLE;
			d[2].status = DSK_INSERTED;
			mock_reset();
			srcs[i].status();
			nsounds = 0; sounds[0] = 0;
			srcs[i].handle(0x10, 0, 0, 0x01);	/* drives 1, motor DF0 on */
			srcs[i].handle(0x10, 4, 0, 0x01);	/* DF0 steps to cylinder 2 */
			srcs[i].handle(0x10, 5, 0, 0x01);	/* the other head: no step */
			srcs[i].handle(0x10, 5, 0, 0x00);	/* motor off */
			keep[i] = strdup(mock_trace());
			memcpy(snd[i], sounds, sizeof sounds);
		}
		/* 0x10, then df[0..3].status bits 0 and 4 shifted by the drive number */
		check("UpdateDriveStatus RV trace", strcmp(keep[0], "10 10 15 / ff ff\n"), 0);
		check("UpdateDriveStatus RV == 832", strcmp(keep[0], keep[1]), 0);
		snprintf(w, sizeof w, "HandleFDD drive sounds RV (%s)", snd[0]);
		check(w, strcmp(snd[0], (char[]){ 'A' + DRIVESOUND_MOTORSTART, 'A' + DRIVESOUND_STEP, 'A' + DRIVESOUND_MOTORSTOP, 0 }), 0);
		check("HandleFDD drive sounds RV == 832", strcmp(snd[0], snd[1]), 0);
		free(keep[0]); free(keep[1]);
	}

	free(tracks); free(t4891);
	say("%s: %d checks, %d failed\n", fails ? "FAIL" : "PASS", cases, fails);
	return fails ? 1 : 0;
}

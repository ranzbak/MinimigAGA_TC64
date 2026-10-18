/*
 * CD audio player -- see cdaudio.h and findings/cdrom/plan.md 13.7.
 *
 * A run = CLEAR, both halves filled from frame `base` of the range, ENA;
 * then the hardware plays half 0, half 1, half 0 ... and `halves` counts
 * the halves it has entered.  Range frame f of the run sits in the ring at
 * byte ((f - base) * 4) mod 64 KB.  TIMER says how far the run has played
 * (`played`, in 256-frame units); AUDIO bit 0 says which half plays now.
 */

#include <string.h>
#include "cdaudio.h"

static struct {
	const struct cd_disc *disc;
	int32_t  state;
	uint32_t start, end;	/* the range: LBAs start .. end - 1 */
	uint32_t total;		/* frames in the range */
	uint32_t base;		/* range frame at ring byte 0 of this run */
	uint32_t cursor;	/* next range frame to fill */
	uint32_t played;	/* TIMER units since this run's ENA */
	uint32_t timer;		/* TIMER at the last look */
	uint32_t halves;	/* halves the hardware has entered since ENA */
	uint32_t pos;		/* range frame where it paused / stopped / ended */
	int32_t  yielded;	/* the Amiga owns the stream (AUDIOF_AMIGA) */
	uint32_t vol[2];
	uint32_t underruns;
	int32_t  blk_file;	/* file and block in blk, -1 = none */
	uint32_t blk_no;
	uint8_t  blk[512];
} cda;

void cda_init(void)
{
	memset(&cda, 0, sizeof(cda));
	cda.state = CDA_IDLE;
	cda.vol[0] = 255;
	cda.vol[1] = 255;
	cda.blk_file = -1;
}

static void zero(uint8_t *p, uint32_t bytes)
{
	uint32_t i;
	for (i = 0; i < bytes; i++)
		p[i] = 0;
}

/* TIMER units since the last look. */
static void tick(void)
{
	uint32_t now = cda_port_timer() & 0xFFFF;
	cda.played += (now - cda.timer) & 0xFFFF;
	cda.timer = now;
}

/* Range frames played by TIMER, at most the range. */
static uint32_t frames_played(void)
{
	uint32_t f = cda.base + cda.played * 256;
	return f < cda.total ? f : cda.total;
}

/* bytes from byte offset `offset` of file `file` into dst, through blk. */
static int32_t copy(int32_t file, uint32_t offset, uint8_t *dst, uint32_t bytes)
{
	uint32_t done = 0;
	while (done < bytes) {
		uint32_t o = offset + done, no = o >> 9, in = o & 511, n = 512 - in, i;
		if (n > bytes - done)
			n = bytes - done;
		if (cda.blk_file != file || cda.blk_no != no) {
			cda.blk_file = -1;
			if (!cda_port_read(file, no, cda.blk))
				return 0;
			cda.blk_file = file;
			cda.blk_no = no;
		}
		for (i = 0; i < n; i++)
			dst[done + i] = cda.blk[in + i];
		done += n;
	}
	return 1;
}

/* Volume: each 16-bit LE sample times vol / 256 (rounded toward zero). */
static void scale(uint8_t *p, uint32_t frames)
{
	uint32_t i;
	for (i = 0; i < frames * 4; i += 2) {
		uint32_t v = cda.vol[(i >> 1) & 1];
		int32_t s = (int32_t)(p[i] | (p[i + 1] << 8));
		if (s & 0x8000)
			s -= 0x10000;
		if (s < 0)
			s = -(int32_t)(((uint32_t)-s * v) >> 8);
		else
			s = (int32_t)(((uint32_t)s * v) >> 8);
		p[i] = (uint8_t)s;
		p[i + 1] = (uint8_t)(s >> 8);
	}
}

/* n frames of the range from frame f into dst: file bytes of audio
   sectors, silence for gaps, data sectors, the tail of a WAV's last sector
   and anything past the range. */
static int32_t produce(uint8_t *dst, uint32_t f, uint32_t n)
{
	uint32_t done = 0;
	while (done < n) {
		uint32_t at = f + done, k = n - done;
		struct cue_loc l;
		if (at >= cda.total || !cue_locate(cda.disc, cda.start + at / CD_FRAMES_PER_SECTOR, &l)) {
			zero(dst + done * 4, k * 4);
			break;
		}
		{
			uint32_t within = at % CD_FRAMES_PER_SECTOR;
			uint32_t run = l.run * CD_FRAMES_PER_SECTOR - within;
			if (run > cda.total - at)
				run = cda.total - at;
			if (k > run)
				k = run;
		}
		if (l.silent || cda.disc->track[l.track].type != CD_AUDIO) {
			zero(dst + done * 4, k * 4);
		} else {
			const struct cd_file *file = &cda.disc->file[l.file];
			uint32_t off = l.offset + (at % CD_FRAMES_PER_SECTOR) * 4;
			uint32_t data_end = file->data_offset + file->data_bytes;
			uint32_t bytes = k * 4, have = off < data_end ? data_end - off : 0;
			if (have > bytes)
				have = bytes;
			if (have && !copy(l.file, off, dst + done * 4, have))
				return 0;
			zero(dst + done * 4 + have, bytes - have);
		}
		done += k;
	}
	return 1;
}

/* The next 32 KB of the range into half h. */
static int32_t fill(uint32_t h)
{
	uint8_t *dst = cda_port_ring() + h * CDA_HALF_BYTES;
	if (!produce(dst, cda.cursor, CDA_HALF_FRAMES))
		return 0;
	if (cda.vol[0] != 255 || cda.vol[1] != 255)
		scale(dst, CDA_HALF_FRAMES);
	cda.cursor += CDA_HALF_FRAMES;
	return 1;
}

/* The ring goes back to the drive sounds: stopped and silent, so they do
   not start on a remnant of the music.  Not while the Amiga owns it. */
static void release(void)
{
	if (cda_port_audio() & CDA_REG_AMIGA)
		return;
	cda_port_control(CDA_CLEAR);
	zero(cda_port_ring(), 2 * CDA_HALF_BYTES);
}

static void fail(void)
{
	release();
	cda.state = CDA_ERROR;
}

/* A run from range frame `frame`: CLEAR, both halves, ENA.  While the
   Amiga owns the stream nothing is written; the position runs on TIMER. */
static void run(uint32_t frame)
{
	cda.base = frame;
	cda.cursor = frame;
	cda.played = 0;
	cda.halves = 0;
	cda.timer = cda_port_timer() & 0xFFFF;
	if (cda_port_audio() & CDA_REG_AMIGA) {
		cda.yielded = 1;
		return;
	}
	cda.yielded = 0;
	cda_port_claim();
	cda_port_control(CDA_CLEAR);
	if (!fill(0) || !fill(1)) {
		fail();
		return;
	}
	cda.timer = cda_port_timer() & 0xFFFF;	/* the run's clock starts at ENA */
	cda_port_control(CDA_ENA);
}

/* The last real sample has played: silence went out after it.  One TIMER
   unit of margin: the run started anywhere inside a unit. */
static int32_t ended(void)
{
	if (cda.base + cda.played * 256 < cda.total + 256)
		return 0;
	cda.pos = cda.total;
	release();
	cda.state = CDA_COMPLETED;
	return 1;
}

void cda_play(const struct cd_disc *d, uint32_t start, uint32_t end)
{
	cda_stop();
	cda.disc = d;
	cda.start = start;
	cda.end = end;
	cda.total = (end - start) * CD_FRAMES_PER_SECTOR;
	cda.pos = 0;
	cda.blk_file = -1;
	cda.state = CDA_PLAYING;
	run(0);
}

void cda_poll(void)
{
	uint32_t reg, h, ht;
	if (cda.state != CDA_PLAYING)
		return;
	tick();
	reg = cda_port_audio();
	if (reg & CDA_REG_AMIGA) {
		cda.yielded = 1;
		ended();
		return;
	}
	if (cda.yielded) {	/* the Amiga let go: a new run from the position */
		if (!ended())
			run(frames_played());
		return;
	}
	if (ended())
		return;
	h = reg & CDA_REG_HALF;
	ht = cda.played / CDA_HALF_UNITS;	/* halves entered, by TIMER */
	if ((ht & 1) != h)	/* TIMER and the play pointer are a unit apart at a flip */
		ht = (cda.played % CDA_HALF_UNITS >= CDA_HALF_UNITS / 2) ? ht + 1 : (ht ? ht - 1 : ht + 1);
	if (ht <= cda.halves)
		return;
	if (ht > cda.halves + 1) {
		/* late: the hardware went round with stale halves.  The half it
		   plays now is stale too: silence; the stream skips to where the
		   hardware is. */
		cda.underruns++;
		zero(cda_port_ring() + h * CDA_HALF_BYTES, CDA_HALF_BYTES);
		cda.cursor = cda.base + (ht + 1) * CDA_HALF_FRAMES;
	}
	cda.halves = ht;
	if (!fill(h ^ 1))
		fail();
}

void cda_pause(void)
{
	if (cda.state != CDA_PLAYING)
		return;
	tick();
	cda.pos = frames_played();
	if (!cda.yielded && !(cda_port_audio() & CDA_REG_AMIGA))
		cda_port_control(0);
	cda.state = CDA_PAUSED;
}

void cda_resume(void)
{
	if (cda.state != CDA_PAUSED)
		return;
	cda.state = CDA_PLAYING;
	run(cda.pos);
}

void cda_stop(void)
{
	if (cda.state == CDA_PLAYING) {
		tick();
		cda.pos = frames_played();
	}
	if (cda.state == CDA_PLAYING || cda.state == CDA_PAUSED)
		release();
	cda.state = CDA_IDLE;
}

void cda_volume(uint32_t left, uint32_t right)
{
	cda.vol[0] = left > 255 ? 255 : left;
	cda.vol[1] = right > 255 ? 255 : right;
}

int32_t cda_status(void)
{
	return cda.state;
}

uint32_t cda_position(void)
{
	uint32_t f = cda.state == CDA_PLAYING ? frames_played() : cda.pos;
	if (cda.total && f >= cda.total)
		f = cda.total - 1;
	return cda.start + f / CD_FRAMES_PER_SECTOR;
}

int32_t cda_busy(void)
{
	return cda.state == CDA_PLAYING || cda.state == CDA_PAUSED;
}

uint32_t cda_underruns(void)
{
	return cda.underruns;
}

/*
 * Host test for the CD audio player (fw/ctrl_832/cdaudio.c).
 *
 * Plan: findings/cdrom/plan.md 13.2, 13.7; findings/cdrom/phase3-plan.md task 7.
 * Build and run: make -C fw/ctrl_832/test
 *
 * The port is a model of the audio hardware (rtl/host/cfide.vhd, 13.2): a
 * 64 KB ring, a play pointer that moves one frame per aud_tick while ENA is
 * set, CLEAR resetting it, AUDIO bit 0 = the half being played, TIMER =
 * aud_ticks / 256.  advance(n) runs n aud_ticks and records every frame the
 * hardware plays in heard[], so a test compares what came out of the
 * speaker with what the disc holds.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "cue.h"
#include "cdaudio.h"

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

/* ---- the disc: data track, audio track with a silent PREGAP, audio track
   with INDEX 00 in its WAV and a partial last sector ---- */

static struct cd_disc D;

static int32_t fake_open(void *ctx, const char *name, struct cd_file *f)
{
	(void)ctx;
	if (strcmp(name, "data.iso") == 0) {
		f->data_bytes = 10 * 2048;
	} else if (strcmp(name, "t2.wav") == 0) {
		f->data_offset = 44;
		f->data_bytes = 60 * 2352;
	} else if (strcmp(name, "t3.wav") == 0) {
		f->data_offset = 44;
		f->data_bytes = 40 * 2352 + 1000;
	} else {
		return CUE_E_NOFILE;
	}
	memcpy(f->shortname, name, 4);
	return CUE_OK;
}

/* LBAs: track 1 0-9 data; 10-11 silent PREGAP; track 2 12-71 (t2.wav);
   track 3 INDEX 00 72-73, INDEX 01 74-112 (t3.wav, 41 sectors, the last
   one 1000 bytes); lead-out 113.  12..112 is 59388 frames: 7 halves. */
static void make_disc(void)
{
	static const char cue[] =
		"FILE \"data.iso\" BINARY\n TRACK 01 MODE1/2048\n INDEX 01 00:00:00\n"
		"FILE \"t2.wav\" WAVE\n TRACK 02 AUDIO\n PREGAP 00:00:02\n INDEX 01 00:00:00\n"
		"FILE \"t3.wav\" WAVE\n TRACK 03 AUDIO\n INDEX 00 00:00:00\n INDEX 01 00:00:02\n";
	static struct cue_parser p;
	cue_begin(&p, &D, fake_open, 0);
	cue_feed(&p, cue, sizeof(cue) - 1);
	if (cue_end(&p) != CUE_OK || D.leadout != 113 || D.track[2].lba != 74) {
		printf("the test disc did not parse: error %d line %d lead-out %u\n", p.error, p.error_line, D.leadout);
		exit(1);
	}
}

/* File bytes: different in every 512-byte block, many with the top bit set
   (negative samples). */
static uint8_t file_byte(int32_t file, uint32_t off)
{
	return (uint8_t)(off * 7 + (uint32_t)file * 31 + (off >> 9) * 3);
}

/* What range frame f of a play from LBA start sounds like: 4 bytes. */
static void expected(uint32_t start, uint32_t f, uint8_t *out)
{
	struct cue_loc l;
	int b;
	memset(out, 0, 4);
	if (!cue_locate(&D, start + f / 588, &l) || l.silent || D.track[l.track].type != CD_AUDIO)
		return;
	for (b = 0; b < 4; b++) {
		uint32_t off = l.offset + (f % 588) * 4 + (uint32_t)b;
		if (off < D.file[l.file].data_offset + D.file[l.file].data_bytes)
			out[b] = file_byte(l.file, off);
	}
}

/* ---- the hardware model ---- */

#define HEARD_MAX (64 * 8192)

static struct {
	uint8_t  ring[0x10000];
	uint32_t p;		/* play pointer, frames 0..16383 */
	int      ena, amiga;
	uint32_t ticks;		/* aud_ticks since power on: TIMER = ticks / 256 */
	int      controls;	/* AUDIO writes */
	uint32_t last_control;
	int      claims;
	int      reads, fail_read_at;	/* cda_port_read fails on call number fail_read_at (0 = never) */
	uint8_t  heard[HEARD_MAX * 4];
	uint32_t heard_n;	/* frames played since the test started listening */
} hw;

int32_t cda_port_read(int32_t file, uint32_t block, uint8_t *dst)
{
	uint32_t i;
	if (++hw.reads == hw.fail_read_at)
		return 0;
	for (i = 0; i < 512; i++)
		dst[i] = file_byte(file, block * 512 + i);
	return 1;
}

uint32_t cda_port_audio(void)
{
	return (hw.p >= 8192 ? CDA_REG_HALF : 0) | (hw.amiga ? CDA_REG_AMIGA : 0);
}

void cda_port_control(uint32_t v)
{
	hw.controls++;
	hw.last_control = v;
	if (v & CDA_CLEAR)
		hw.p = 0;
	hw.ena = (v & CDA_ENA) ? 1 : 0;
}

uint32_t cda_port_timer(void)
{
	return (hw.ticks >> 8) & 0xFFFF;
}

uint8_t *cda_port_ring(void)
{
	return hw.ring;
}

void cda_port_claim(void)
{
	hw.claims++;
}

static void advance(uint32_t ticks)
{
	while (ticks--) {
		if (hw.ena) {
			if (hw.heard_n < HEARD_MAX)
				memcpy(hw.heard + hw.heard_n * 4, hw.ring + hw.p * 4, 4);
			hw.heard_n++;
			hw.p = (hw.p + 1) & 16383;
		}
		hw.ticks++;
	}
}

/* advance + poll, every `step` ticks, n times */
static void run_for(uint32_t step, int n)
{
	while (n--) {
		advance(step);
		cda_poll();
	}
}

static void reset_model(void)
{
	memset(&hw, 0, sizeof(hw));
	hw.ticks = 12345;	/* TIMER is free running: not 0 at the start */
	cda_init();
}

/* heard frames [from, from + n) == range frames [f, f + n) of a play from start */
static int heard_matches(uint32_t from, uint32_t start, uint32_t f, uint32_t n)
{
	uint32_t i;
	uint8_t e[4];
	for (i = 0; i < n; i++) {
		expected(start, f + i, e);
		if (memcmp(hw.heard + (from + i) * 4, e, 4) != 0) {
			printf("  heard frame %u (range frame %u): %02X %02X %02X %02X, want %02X %02X %02X %02X\n",
			       from + i, f + i, hw.heard[(from + i) * 4], hw.heard[(from + i) * 4 + 1],
			       hw.heard[(from + i) * 4 + 2], hw.heard[(from + i) * 4 + 3], e[0], e[1], e[2], e[3]);
			return 0;
		}
	}
	return 1;
}

static int ring_matches(uint32_t half, uint32_t start, uint32_t f)
{
	uint32_t i;
	uint8_t e[4];
	for (i = 0; i < 8192; i++) {
		expected(start, f + i, e);
		if (memcmp(hw.ring + half * 0x8000 + i * 4, e, 4) != 0)
			return 0;
	}
	return 1;
}

static int silent(const uint8_t *p, uint32_t frames)
{
	uint32_t i;
	for (i = 0; i < frames * 4; i++)
		if (p[i])
			return 0;
	return 1;
}

/* ---- cases ---- */

static void t_start(void)
{
	begin("play: claim, CLEAR, both halves from the start, then ENA");
	reset_model();
	cda_play(&D, 10, 113);
	EXPECT(hw.claims == 1, "claims %d", hw.claims);
	EXPECT(hw.controls == 2 && hw.last_control == CDA_ENA && hw.ena && hw.p == 0, "controls %d last %u",
	       hw.controls, hw.last_control);
	EXPECT(cda_status() == CDA_PLAYING && cda_busy(), "status %02X", (unsigned)cda_status());
	EXPECT(ring_matches(0, 10, 0), "half 0 is not range frames 0..8191");
	EXPECT(ring_matches(1, 10, 8192), "half 1 is not range frames 8192..16383");
	EXPECT(silent(hw.ring, 2 * 588), "the silent PREGAP (LBA 10-11) is not silent");
	EXPECT(cda_position() == 10, "position %u", cda_position());
	end();
}

static void t_stream(void)
{
	uint32_t total = 103 * 588, done_at = 0;
	int i;
	begin("a whole range: gap, track 2, track 3 (INDEX 00 in its WAV, short last sector), silence, completed by TIMER");
	reset_model();
	cda_play(&D, 10, 113);
	for (i = 0; i < 60 && cda_status() == CDA_PLAYING; i++) {
		advance(1500);
		cda_poll();
		if (cda_status() == CDA_COMPLETED && !done_at)
			done_at = hw.heard_n;
	}
	EXPECT(cda_status() == CDA_COMPLETED, "status %02X", (unsigned)cda_status());
	EXPECT(hw.heard_n >= total && heard_matches(0, 10, 0, total), "what played differs from the disc");
	EXPECT(silent(hw.heard + (112 * 588 - 10 * 588 + 250) * 4, 588 - 250), "the tail of t3.wav's short last sector is not silence");
	EXPECT(done_at >= total && done_at < total + 1500 + 512, "completed after %u frames (range %u)", done_at, total);
	EXPECT(silent(hw.heard + total * 4, hw.heard_n - total), "something after the range");
	EXPECT(!hw.ena && hw.last_control == CDA_CLEAR, "the ring still plays after the end");
	EXPECT(silent(hw.ring, 16384), "music left in the ring for the drive sounds");
	EXPECT(!cda_busy() && cda_underruns() == 0, "busy %d underruns %u", (int)cda_busy(), cda_underruns());
	EXPECT(cda_position() == 112, "position %u at the end", cda_position());
	end();
}

static void t_late(void)
{
	uint32_t late_at, next;
	begin("a late poll: underrun counted, the stale half silenced, the stream follows the hardware");
	reset_model();
	cda_play(&D, 12, 113);
	run_for(2000, 3);	/* 6000 frames: still in half 0 */
	advance(2 * 8192 + 4000);	/* 26384 frames in: three flips, the last poll saw none */
	late_at = hw.heard_n;	/* half 1, 1808 frames in */
	cda_poll();
	EXPECT(cda_underruns() == 1, "underruns %u", cda_underruns());
	EXPECT(silent(hw.ring + (late_at % 16384) * 4, 8192 - late_at % 8192), "the rest of the stale half is not silent");
	next = (late_at / 8192 + 1) * 8192;	/* the next half: range frames as the hardware reaches them */
	run_for(1000, 16);
	EXPECT(hw.heard_n > next + 8192 && heard_matches(next, 12, next, 8192), "after the resync");
	EXPECT(cda_status() == CDA_PLAYING, "status %02X", (unsigned)cda_status());
	end();
}

static void t_pause_resume(void)
{
	uint32_t t_ena, units, pos, n;
	begin("pause: ENA off, position kept; resume: CLEAR, refill from the position, ENA");
	reset_model();
	cda_play(&D, 12, 113);
	t_ena = hw.ticks >> 8;
	run_for(1000, 5);
	units = (hw.ticks >> 8) - t_ena;
	pos = units * 256;
	cda_pause();
	EXPECT(cda_status() == CDA_PAUSED && cda_busy(), "status %02X", (unsigned)cda_status());
	EXPECT(!hw.ena && hw.last_control == 0, "ENA still on (last %u)", hw.last_control);
	EXPECT(cda_position() == 12 + pos / 588, "paused at %u, want %u", cda_position(), 12 + pos / 588);
	n = hw.heard_n;
	run_for(1000, 5);
	EXPECT(hw.heard_n == n && cda_position() == 12 + pos / 588, "it played on while paused");
	cda_resume();
	EXPECT(cda_status() == CDA_PLAYING && hw.ena && hw.p == 0, "resume: status %02X ena %d", (unsigned)cda_status(), hw.ena);
	EXPECT(ring_matches(0, 12, pos), "half 0 after the resume is not the range from frame %u", pos);
	EXPECT(hw.claims == 2, "claims %d", hw.claims);
	end();
}

static void t_amiga(void)
{
	static uint8_t before[0x10000];
	uint32_t t0, units;
	int controls;
	begin("AUDIOF_AMIGA: no writes, the position runs on TIMER; a new run when the Amiga lets go");
	reset_model();
	cda_play(&D, 12, 113);
	run_for(1000, 3);
	hw.amiga = 1;
	t0 = hw.ticks >> 8;
	memcpy(before, hw.ring, sizeof(before));
	controls = hw.controls;
	run_for(1500, 12);	/* 18000 frames: past two flips */
	EXPECT(memcmp(before, hw.ring, sizeof(before)) == 0, "the ring was written while the Amiga owned it");
	EXPECT(hw.controls == controls, "AUDIO written while the Amiga owned it");
	EXPECT(cda_status() == CDA_PLAYING, "status %02X", (unsigned)cda_status());
	units = (hw.ticks >> 8) - t0 + 3000 / 256;
	EXPECT(cda_position() >= 12 + (units * 256 - 512) / 588 && cda_position() <= 12 + (units * 256 + 512) / 588,
	       "position %u, about %u by TIMER", cda_position(), 12 + units * 256 / 588);
	hw.amiga = 0;
	cda_poll();
	EXPECT(hw.ena && hw.last_control == CDA_ENA && hw.controls == controls + 2, "no new run: controls %d", hw.controls - controls);
	EXPECT(cda_underruns() == 0, "underruns %u", cda_underruns());
	end();
}

static void t_volume(void)
{
	uint32_t i;
	int neg = 0, bad = 0;
	uint8_t e[4];
	begin("volume: 255/255 straight copy, otherwise sample x vol / 256 toward zero, 0 = silence");
	reset_model();
	cda_volume(128, 0);
	cda_play(&D, 12, 113);
	for (i = 0; i < 8192; i++) {
		int32_t s, want;
		expected(12, i, e);
		s = (int32_t)(e[0] | (e[1] << 8));
		if (s & 0x8000)
			s -= 0x10000;
		want = s < 0 ? -((-s * 128) >> 8) : (s * 128) >> 8;
		if (s < -256)
			neg++;
		if (hw.ring[i * 4] != (uint8_t)want || hw.ring[i * 4 + 1] != (uint8_t)(want >> 8) ||
		    hw.ring[i * 4 + 2] || hw.ring[i * 4 + 3])
			bad++;
	}
	EXPECT(!bad && neg > 100, "%d frames wrong (%d negative samples)", bad, neg);
	cda_volume(255, 255);
	cda_play(&D, 12, 113);
	EXPECT(ring_matches(0, 12, 0), "full volume is not a straight copy");
	cda_volume(1000, 300);	/* clamped to 255 */
	cda_play(&D, 12, 113);
	EXPECT(ring_matches(0, 12, 0), "a volume above 255 is not clamped");
	end();
}

static void t_read_error(void)
{
	begin("an SD read error: CLEAR, status error (14), the ring is free");
	reset_model();
	hw.fail_read_at = 3;
	cda_play(&D, 12, 113);
	EXPECT(cda_status() == CDA_ERROR && !cda_busy() && !hw.ena && hw.last_control == CDA_CLEAR,
	       "status %02X ena %d", (unsigned)cda_status(), hw.ena);
	reset_model();
	hw.fail_read_at = 140;	/* in the first refill (a half is about 65 reads) */
	cda_play(&D, 12, 113);
	run_for(2000, 10);
	EXPECT(cda_status() == CDA_ERROR && !hw.ena, "refill error: status %02X", (unsigned)cda_status());
	end();
}

static void t_stop(void)
{
	uint32_t pos;
	begin("stop: CLEAR, idle, the position stays; polls do nothing while idle");
	reset_model();
	cda_poll();
	EXPECT(hw.controls == 0 && cda_status() == CDA_IDLE && !cda_busy(), "an idle poll wrote AUDIO");
	cda_play(&D, 12, 113);
	run_for(1000, 4);
	pos = cda_position();
	cda_stop();
	EXPECT(cda_status() == CDA_IDLE && !cda_busy() && !hw.ena && hw.last_control == CDA_CLEAR, "status %02X",
	       (unsigned)cda_status());
	EXPECT(cda_position() == pos, "position %u, was %u", cda_position(), pos);
	EXPECT(silent(hw.ring, 16384), "music left in the ring after the stop");
	run_for(1000, 4);
	EXPECT(hw.last_control == CDA_CLEAR && !hw.ena, "a poll after the stop restarted something");
	cda_pause();
	cda_resume();
	EXPECT(cda_status() == CDA_IDLE, "pause/resume from idle: %02X", (unsigned)cda_status());
	end();
}

static void t_position(void)
{
	begin("position: start LBA + frames played by TIMER / 588");
	reset_model();
	hw.ticks = 0x10000 * 256 - 3 * 256;	/* TIMER wraps during the play */
	cda_play(&D, 12, 113);
	advance(588 * 5 + 300);
	cda_poll();
	EXPECT(cda_position() == 17, "position %u, want 17", cda_position());
	advance(588 * 10);
	cda_poll();
	EXPECT(cda_position() == 27, "position %u, want 27", cda_position());
	end();
}

static void t_timer_phase(void)
{
	uint32_t total = 101 * 588, done_at = 0;
	int i;
	begin("TIMER a unit ahead of the play pointer: no early refill at a flip, no early end");
	reset_model();
	hw.ticks = 256 * 50 + 200;	/* ENA 200 ticks into a TIMER unit: TIMER leads by up to 200 frames */
	cda_play(&D, 12, 113);
	advance(8192 - 10);	/* TIMER says 32 units (a flip), the hardware is 10 frames before it */
	cda_poll();
	run_for(500, 10);
	EXPECT(heard_matches(0, 12, 0, 8192 + 5000 - 10), "half 1 was refilled before it played");
	run_for(1000, 44);	/* to about 2000 frames before the end */
	for (i = 0; i < 200 && cda_status() == CDA_PLAYING; i++) {
		advance(64);
		cda_poll();
		if (cda_status() == CDA_COMPLETED)
			done_at = hw.heard_n;
	}
	EXPECT(done_at >= total && done_at < total + 512 + 64, "completed after %u frames (range %u)", done_at, total);
	EXPECT(heard_matches(0, 12, 0, total), "what played differs from the disc");
	end();
}

int main(void)
{
	make_disc();
	t_start();
	t_stream();
	t_late();
	t_pause_resume();
	t_amiga();
	t_volume();
	t_read_error();
	t_stop();
	t_position();
	t_timer_phase();

	printf("\n%d cases: %d passed, %d failed (%d failed checks)\n",
	       cases_run, cases_passed, cases_run - cases_passed, total_fails);
	return total_fails ? 1 : 0;
}

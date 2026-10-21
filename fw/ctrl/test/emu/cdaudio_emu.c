/*
 * cdaudio_emu: the CD audio player built with the firmware's RISC-V
 * compiler and flags and run on the L1 bench (sim/rv_l1/prog/Makefile,
 * run.sh units).  cdaudio_test checks the logic with the host gcc; this
 * checks the target code: the int32 state set and returned,
 * the sample scaling (mul, shifts, a negative sample), the position
 * (division by 588), the refill after a flip and the underrun path.  The
 * port is a small model of the ring (as in cdaudio_test).  The last line
 * is "PASS" or "FAIL n".
 */
#include <stdio.h>
#include <string.h>
#include "cdaudio.h"

static int fails;

static void expect(const char *what, unsigned int got, unsigned int want)
{
	if (got != want) {
		printf("FAIL %s: got %u, want %u\n", what, got, want);
		fails++;
	} else
		printf("ok   %s = %u\n", what, got);
}

/* ---- the port ---- */

static uint8_t ring[0x10000];
static uint32_t p, ena, amiga, ticks, last_control, claims, reads;

static uint8_t file_byte(uint32_t off)
{
	return (uint8_t)(off * 7 + (off >> 9) * 3);
}

int32_t cda_port_read(int32_t file, uint32_t block, uint8_t *dst)
{
	uint32_t i;
	reads++;
	for (i = 0; i < 512; i++)
		dst[i] = file_byte(block * 512 + i);
	return 1;
}

uint32_t cda_port_audio(void)
{
	return (p >= 8192 ? CDA_REG_HALF : 0) | (amiga ? CDA_REG_AMIGA : 0);
}

void cda_port_control(uint32_t v)
{
	last_control = v;
	if (v & CDA_CLEAR)
		p = 0;
	ena = v & CDA_ENA;
}

uint32_t cda_port_timer(void)
{
	return (ticks >> 8) & 0xFFFF;
}

uint8_t *cda_port_ring(void)
{
	return ring;
}

void cda_port_claim(void)
{
	claims++;
}

static void advance(uint32_t n)
{
	uint32_t i;
	for (i = 0; i < n; i++) {
		if (ena)
			p = (p + 1) & 16383;
		ticks++;
	}
}

/* ---- the disc: LBA 0-1 silent PREGAP, track 1 audio 2-61 (one WAV) ---- */

static struct cd_disc disc;

static void make_disc(void)
{
	disc.tracks = 1;
	disc.files = 1;
	disc.leadout = 62;
	disc.track[0].number = 1;
	disc.track[0].type = CD_AUDIO;
	disc.track[0].file = 0;
	disc.track[0].file_offset = 44;
	disc.track[0].lba = 2;
	disc.track[0].sectors = 60;
	disc.track[0].pregap_lba = 0;
	disc.track[0].pregap_silent = 1;
	disc.file[0].wave = 1;
	disc.file[0].data_offset = 44;
	disc.file[0].data_bytes = 60 * 2352;
}

/* the left sample of range frame f (from LBA 0), as the ring holds it */
static int32_t sample(uint32_t f)
{
	uint32_t off;
	int32_t s;
	if (f < 2 * 588)
		return 0;
	off = 44 + (f - 2 * 588) * 4;
	s = (int32_t)(file_byte(off) | (file_byte(off + 1) << 8));
	if (s & 0x8000)
		s -= 0x10000;
	return s;
}

static int32_t ring_left(uint32_t frame)
{
	int32_t s = (int32_t)(ring[frame * 4] | (ring[frame * 4 + 1] << 8));
	if (s & 0x8000)
		s -= 0x10000;
	return s;
}

int main(int argc, char **argv)
{
	uint32_t f, bad, neg;

	make_disc();
	cda_init();
	expect("idle status", cda_status(), CDA_IDLE);
	expect("idle busy", cda_busy(), 0);

	ticks = 100 * 256;
	cda_play(&disc, 0, 62);
	expect("play status", cda_status(), CDA_PLAYING);
	expect("play busy", cda_busy(), 1);
	expect("play claims", claims, 1);
	expect("play control", last_control, CDA_ENA);
	expect("silent gap frame 0", ring_left(0), 0);
	expect("silent gap frame 1175", ring_left(1175), 0);
	bad = 0;
	neg = 0;
	for (f = 1176; f < 8192; f++) {
		if (ring_left(f) != sample(f))
			bad++;
		if (sample(f) < 0)
			neg++;
	}
	expect("half 0 samples wrong", bad, 0);
	expect("half 0 has negative samples", neg > 100, 1);

	/* the flip: half 1 plays, half 0 gets range frames 16384.. */
	advance(8192 + 100);
	cda_poll();
	expect("refill underruns", cda_underruns(), 0);
	expect("refill frame 16384", ring_left(0) == sample(16384), 1);
	expect("refill frame 17000", ring_left(616) == sample(17000), 1);
	expect("position after 8292 frames", cda_position(), 13);

	/* late: two more flips without a poll */
	advance(2 * 8192);
	cda_poll();
	expect("late underruns", cda_underruns(), 1);

	/* pause / resume */
	cda_pause();
	expect("pause status", cda_status(), CDA_PAUSED);
	expect("pause control", last_control, 0);
	cda_resume();
	expect("resume status", cda_status(), CDA_PLAYING);
	expect("resume control", last_control, CDA_ENA);

	/* volume 128/0 on a negative sample */
	cda_volume(128, 0);
	cda_play(&disc, 0, 62);
	bad = 0;
	for (f = 1176; f < 8192; f++) {
		int32_t s = sample(f), want = s < 0 ? -((-s * 128) >> 8) : (s * 128) >> 8;
		if (ring_left(f) != want || ring[f * 4 + 2] || ring[f * 4 + 3])
			bad++;
	}
	expect("volume 128/0 frames wrong", bad, 0);
	cda_volume(255, 255);

	/* to the end: completed */
	cda_play(&disc, 60, 62);
	advance(2 * 588 + 600);
	cda_poll();
	expect("end status", cda_status(), CDA_COMPLETED);
	expect("end busy", cda_busy(), 0);
	expect("end control", last_control, CDA_CLEAR);
	expect("end position", cda_position(), 61);

	cda_stop();
	expect("stop status", cda_status(), CDA_IDLE);

	if (fails)
		printf("FAIL %d\n", fails);
	else
		printf("PASS\n");
	return fails;
}

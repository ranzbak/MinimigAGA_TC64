#include <stdio.h>

#include "diskstat.h"
#include "hardware.h"

unsigned diskstat_hist[2][DISKSTAT_BUCKETS];
volatile unsigned dbg_flags;

// the largest sector count of each bucket, and its name in the report
static const unsigned short bucket_top[DISKSTAT_BUCKETS] = { 1, 2, 4, 8, 16, 64, 256 };
static const char *const bucket_name[DISKSTAT_BUCKETS] = {
	"1", "2", "3-4", "5-8", "9-16", "17-64", "65-256"
};

// cumulative since power-on (32 bits: a difference of two reports is right
// across a wrap)
static unsigned cmds[2], sectors[2];
static unsigned busy_polls, busy_blocks, amiga_polls;
// per report period
static unsigned period_passes;
static unsigned short period_start;	// TIMER at the start of the period

void diskstat_cmd(int write, unsigned n)
{
	unsigned b = 0;
	write = write ? 1 : 0;
	while (b < DISKSTAT_BUCKETS - 1 && n > bucket_top[b])
		b++;
	diskstat_hist[write][b]++;
	cmds[write]++;
	sectors[write] += n;
}

void diskstat_busy_polls(unsigned n)
{
	busy_polls += n;
	busy_blocks++;
}

void diskstat_amiga_polls(unsigned n)
{
	amiga_polls += n;
}

void diskstat_loop_pass(void)
{
	period_passes++;
}

void diskstat_period_start(void)
{
	period_start = TIMER;
	period_passes = 0;
}

void diskstat_report(void)
{
	unsigned short now = TIMER;
	unsigned counts = (unsigned short)(now - period_start);	// 16-bit TIMER
	int w, b;

	printf("disk: cmds w %u r %u, sectors w %u r %u\n", cmds[1], cmds[0], sectors[1], sectors[0]);
	for (w = 1; w >= 0; w--)
	{
		printf(w ? "disk: w" : "disk: r");
		for (b = 0; b < DISKSTAT_BUCKETS; b++)
			printf(" %s:%u", bucket_name[b], diskstat_hist[w][b]);
		printf("\n");
	}
	printf("disk: busy polls %u in %u blocks, amiga polls %u\n", busy_polls, busy_blocks, amiga_polls);
	// one TIMER count is 5.804 ms (README "Every TIMER user"); counts < 65536: no overflow
	printf("disk: loop passes %u in %u TIMER counts (%u ms)\n", period_passes, counts, counts * 5804 / 1000);
	period_start = now;
	period_passes = 0;
}

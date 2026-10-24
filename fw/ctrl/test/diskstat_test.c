/* diskstat_test: the disk statistics counters (diskstat.c) for the SD
 * baseline (findings/sdcard-engine, Task 1).  The counters are fed by hand,
 * as hdd.c / mmc.c / main.c feed them; diskstat_report() prints on the mock
 * UART (rvlibc.c's printf), this program reports with fprintf(stdout).
 *   - the histogram buckets 1, 2, 3-4, 5-8, 9-16, 17-64, 65-256 sectors per
 *     command, per direction, each bucket at both of its bounds
 *   - the report: the command and sector totals, the busy and Amiga polls,
 *     the loop passes and the TIMER counts of the period (the mock's TIMER,
 *     one count per read: the report's own read is the period's end)
 *   - totals are cumulative, the period restarts at every report and at
 *     diskstat_period_start()
 *   make -C fw/ctrl/test run-diskstat_test
 */
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "diskstat.h"
#include "hardware.h"
#include "mock_hw.h"

static void say(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void say(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stdout, fmt, ap);
	va_end(ap);
}

static int fails, cases;
static void check(const char *what, long got, long want)
{
	cases++;
	if (got != want) {
		say("FAIL %s: got %ld, want %ld\n", what, got, want);
		fails++;
	} else
		say("ok   %s = %ld\n", what, got);
}
static void check_has(const char *what, const char *text, const char *sub)
{
	cases++;
	if (!strstr(text, sub)) {
		say("FAIL %s: \"%s\" not in\n%s---\n", what, sub, text);
		fails++;
	} else
		say("ok   %s \"%s\"\n", what, sub);
}
static void check_str(const char *what, const char *got, const char *want)
{
	cases++;
	if (strcmp(got, want)) {
		say("FAIL %s:\n--- got\n%s--- want\n%s---\n", what, got, want);
		fails++;
	} else
		say("ok   %s\n", what);
}

static void hist_clear(void)
{
	memset(diskstat_hist, 0, sizeof diskstat_hist);
}

int main(void)
{
	char what[96];
	mock_reset();

	/* the brief's case */
	diskstat_cmd(1, 1);
	diskstat_cmd(1, 1);
	diskstat_cmd(1, 1);
	diskstat_cmd(1, 16);
	diskstat_cmd(0, 256);
	check("w 1 sector x3: hist[1][0]", diskstat_hist[1][0], 3);
	check("w 16 sectors: hist[1][4]", diskstat_hist[1][4], 1);
	check("r 256 sectors: hist[0][6]", diskstat_hist[0][6], 1);
	diskstat_busy_polls(100);
	diskstat_busy_polls(100);
	diskstat_amiga_polls(7);
	diskstat_amiga_polls(5);
	for (int i = 0; i < 3; i++)
		diskstat_loop_pass();
	hosttest_advance(1000);		/* the mock's TIMER reads 1000 (then 1001) */
	mock_uart_clear();
	diskstat_report();
	check_has("report", mock_uart(), "busy polls 200");
	check_has("report", mock_uart(), "cmds w 4 r 1");
	check_str("report, whole text", mock_uart(),
		"disk: cmds w 4 r 1, sectors w 19 r 256\n"
		"disk: w 1:3 2:0 3-4:0 5-8:0 9-16:1 17-64:0 65-256:0\n"
		"disk: r 1:0 2:0 3-4:0 5-8:0 9-16:0 17-64:0 65-256:1\n"
		"disk: busy polls 200 in 2 blocks, amiga polls 12\n"
		"disk: loop passes 3 in 1000 TIMER counts (5804 ms)\n");

	/* the next period: the totals go on, the loop passes and the TIMER
	   counts start again at the last report */
	diskstat_cmd(0, 2);
	diskstat_loop_pass();
	hosttest_advance(9);
	mock_uart_clear();
	diskstat_report();
	check_has("second report: totals", mock_uart(), "disk: cmds w 4 r 2, sectors w 19 r 258\n");
	check_has("second report: hist r", mock_uart(), "disk: r 1:0 2:1 3-4:0");
	check_has("second report: period", mock_uart(), "disk: loop passes 1 in 10 TIMER counts (58 ms)\n");

	/* diskstat_period_start (main.c, before the main loop): a new period */
	diskstat_loop_pass();
	hosttest_advance(500);
	diskstat_period_start();
	diskstat_loop_pass();
	diskstat_loop_pass();
	hosttest_advance(19);
	mock_uart_clear();
	diskstat_report();
	check_has("after period_start", mock_uart(), "disk: loop passes 2 in 20 TIMER counts (116 ms)\n");

	/* the TIMER is 16 bits: a period across its wrap.  The mock's count
	   is 1532 here (1531 read by the report above): period_start reads
	   65526, the report 65556 = 20 after the wrap */
	hosttest_advance(65526 - 1532);
	diskstat_period_start();
	hosttest_advance(29);
	mock_uart_clear();
	diskstat_report();
	check_has("across the TIMER wrap", mock_uart(), "disk: loop passes 0 in 30 TIMER counts (174 ms)\n");

	/* every bucket at both bounds, both directions */
	static const struct { unsigned lo, hi; } b[7] = {
		{ 1, 1 }, { 2, 2 }, { 3, 4 }, { 5, 8 }, { 9, 16 }, { 17, 64 }, { 65, 256 },
	};
	for (int w = 0; w < 2; w++)
		for (int i = 0; i < 7; i++) {
			hist_clear();
			diskstat_cmd(w, b[i].lo);
			diskstat_cmd(w, b[i].hi);
			snprintf(what, sizeof what, "%s %u and %u sectors: hist[%d][%d]",
				 w ? "w" : "r", b[i].lo, b[i].hi, w, i);
			check(what, diskstat_hist[w][i], 2);
			unsigned sum = 0;
			for (int d = 0; d < 2; d++)
				for (int j = 0; j < 7; j++)
					sum += diskstat_hist[d][j];
			snprintf(what, sizeof what, "%s %u and %u sectors: no other bucket",
				 w ? "w" : "r", b[i].lo, b[i].hi);
			check(what, sum, 2);
		}

	if (fails) { say("diskstat_test FAIL (%d of %d)\n", fails, cases); return 1; }
	say("diskstat_test PASS (%d checks)\n", cases);
	return 0;
}

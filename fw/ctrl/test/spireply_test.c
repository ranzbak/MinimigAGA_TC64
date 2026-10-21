/* spireply_test: SPI_reply() (hardware.c) on the mock's HOST_REQ (Phase 4
 * Task 11).  Before each OSD reply byte the RV firmware polls HOST_REQ bit 0
 * (OSD_RDY, cfide 0xFFFFFFB4) until it reads 1, at most 2 TIMER counts
 * (GetTimer(2) / CheckTimer); a wait that runs out is counted in
 * osd_rdy_timeouts and the byte is read all the same.  The expected orders
 * and counts below follow from that rule and the mock's TIMER (one count per
 * read, mock_timer_step), not from a run of the code:
 *   ready at once        "1WR", no TIMER read
 *   ready after n zeros  n zeros, "1WR"; GetTimer + one CheckTimer per zero
 *                        after the first: n TIMER reads
 *   never ready, step s  GetTimer reads T0, the bound is T0 + 2; CheckTimer
 *                        is true at the first read > T0 + 2: with s = 1 the
 *                        reads T0+1, T0+2, T0+3 (4 TIMER reads, 4 polls),
 *                        s = 2: T0+2, T0+4 (3, 3), s = 3: T0+3 (2, 2)
 *   make -C fw/ctrl/test run-spireply_test
 */
#include <stdio.h>
#include <string.h>

#include "hardware.h"
#include "mock_hw.h"

static int fails, cases;
static void check(const char *what, long got, long want)
{
	cases++;
	if (got != want) {
		printf("FAIL %s: got %ld, want %ld\n", what, got, want);
		fails++;
	} else
		printf("ok   %s = %ld\n", what, got);
}
static void check_str(const char *what, const char *got, const char *want)
{
	cases++;
	if (strcmp(got, want)) {
		printf("FAIL %s: got \"%s\", want \"%s\"\n", what, got, want);
		fails++;
	} else
		printf("ok   %s \"%s\"\n", what, got);
}

/* one SPI_reply() with the OSD selected; the OSD answers `reply`; zeros =
   HOST_REQ reads that return 0 first; step = TIMER counts per read */
static unsigned char one_reply(unsigned zeros, unsigned step, unsigned char reply)
{
	mock_reset();
	mock_timer_step(step);
	mock_script_bytes(0x20, &reply, 1);
	mock_host_req(zeros);
	osd_rdy_timeouts = 0;
	EnableOsd();
	mock_order_start();
	return SPI_reply();
}

int main(void)
{
	char what[96];

	/* ready at once: no wait, no TIMER read */
	check("ready: reply byte", one_reply(0, 1, 0x5A), 0x5A);
	check_str("ready: order (HOST_REQ, DATA write, DATA read)", mock_order(), "1WR");
	check("ready: TIMER reads", mock_timer_reads(), 0);
	check("ready: osd_rdy_timeouts", osd_rdy_timeouts, 0);
	check_str("ready: trace", mock_trace(), "20 ff / 5a\n");

	/* ready after n zeros: polls until 1, only then the write */
	static const char *const order_n[] = { "1WR", "01WR", "001WR", "0001WR" };
	for (unsigned n = 1; n <= 3; n++) {
		one_reply(n, 1, 0xA4);
		snprintf(what, sizeof what, "%u zeros: order", n);
		check_str(what, mock_order(), order_n[n]);
		snprintf(what, sizeof what, "%u zeros: TIMER reads", n);
		check(what, mock_timer_reads(), n);
		snprintf(what, sizeof what, "%u zeros: osd_rdy_timeouts", n);
		check(what, osd_rdy_timeouts, 0);
	}

	/* never ready: the wait ends at the TIMER bound (2 counts), counted,
	   and the byte is read after it */
	static const struct { unsigned step; long reads; const char *order; } stuck[] = {
		{ 1, 4, "0000WR" }, { 2, 3, "000WR" }, { 3, 2, "00WR" },
	};
	for (unsigned i = 0; i < sizeof stuck / sizeof stuck[0]; i++) {
		unsigned char r = one_reply(MOCK_HOST_REQ_STUCK, stuck[i].step, 0x7D);
		snprintf(what, sizeof what, "stuck, TIMER step %u: reply byte", stuck[i].step);
		check(what, r, 0x7D);
		snprintf(what, sizeof what, "stuck, TIMER step %u: order", stuck[i].step);
		check_str(what, mock_order(), stuck[i].order);
		snprintf(what, sizeof what, "stuck, TIMER step %u: TIMER reads", stuck[i].step);
		check(what, mock_timer_reads(), stuck[i].reads);
		snprintf(what, sizeof what, "stuck, TIMER step %u: HOST_REQ reads", stuck[i].step);
		check(what, mock_host_req_reads(), stuck[i].reads);
		snprintf(what, sizeof what, "stuck, TIMER step %u: osd_rdy_timeouts", stuck[i].step);
		check(what, osd_rdy_timeouts, 1);
	}

	/* every reply byte waits on its own: a version-style frame of three
	   bytes, the first ready at once, the second after one zero, the third
	   never (the counter adds up across calls) */
	mock_reset();
	static const unsigned char rep3[] = { 0x00, 0x01, 0x1A, 0x0A };	/* 00: the command byte's */
	mock_script_bytes(0x20, rep3, sizeof rep3);
	osd_rdy_timeouts = 0;
	EnableOsd();
	SPI(0x88);
	mock_order_start();
	unsigned char got[3];
	mock_host_req(0);
	got[0] = SPI_reply();
	mock_host_req(1);
	got[1] = SPI_reply();
	mock_host_req(MOCK_HOST_REQ_STUCK);
	got[2] = SPI_reply();
	DisableOsd();
	check_str("frame: order", mock_order(), "1WR01WR0000WR");
	check("frame: osd_rdy_timeouts", osd_rdy_timeouts, 1);
	check("frame: reply bytes", (got[0] << 16) | (got[1] << 8) | got[2], 0x011A0A);
	check_str("frame: trace", mock_trace(), "20 88 ff ff ff / 00 01 1a 0a\n");

	if (fails) { printf("spireply_test FAIL (%d of %d)\n", fails, cases); return 1; }
	printf("spireply_test PASS (%d checks)\n", cases);
	return 0;
}

/* drivesounds_test: the drive sound ring against the 832's (Task 14).
 *   drivesounds_test <dir>
 * <dir> (the Makefile's out/ds) holds what gold/drivesounds.py wrote --
 * dscases.h (compiled in), ring_synth.bin, ring_real.bin, SYNTH.BIN, the
 * bad files -- and
 * card.img (tools/sim/mkcard.sh: DRIVESND.BIN = sw/mkdrivesounds/drivesnd.bin,
 * SYNTH.BIN and the bad files).
 * The real drivesounds.c loads each file through rafile.c + fat.c + mmc.c on
 * the card model into the mock's RAM in front of AUDIO_BUFFER (mock_hw.c),
 * where it lands as on the target (DRIVESND.BIN at 2 mod 4: its header
 * longs are misaligned there; SYNTH.BIN at 0 mod 8).  Then the op list of
 * each case runs with the TIMER standing still (step 0: time is what the
 * "advance" ops say), and the CD audio player's cda_busy() is the test's.
 * Checks, against drivesounds.py (the 832's file format and render
 * arithmetic, independent of the code here):
 *   - drivesounds_init's return value and its UART lines "Audio file - length
 *     <n>" and "Sound <id> at <addr>, length <size>" (the address left out);
 *     a case whose load differs stops there
 *   - after every drivesounds_fill(): its return value, the AUDIO register,
 *     and the whole 64 KB ring, byte for byte, against the snapshot
 *   - five bad files (TRUNC ODDLEN ODDSND NEGSIZE NEGID.BIN, drivesounds.py
 *     bad_files): the load leaves the ring as it was, and its return value,
 *     drivesounds_loaded() and lines are the port's bounds rule (rv_load)
 * The firmware's printf (rvlibc.c) goes to the mock UART; this program
 * reports with fprintf(stdout), line buffered (a mutant that hangs a render
 * loop is stopped by mutants.sh's timeout: the FAIL lines before it stay).
 */
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "hardware.h"
#include "mmc.h"
#include "fat.h"
#include "drivesounds.h"
#include "cdaudio.h"
#include "mock_hw.h"

enum { DS_INIT, DS_ENABLE, DS_DISABLE, DS_ADVANCE, DS_QUEUE, DS_FILL, DS_AUDIO, DS_CDA };
struct ds_op {
	int op;
	int a;              /* mask, ticks, event type, AUDIO value, busy */
	const char *name;   /* DS_INIT: the 8.3 directory name */
	int b;              /* DS_INIT: the TIMER value the case starts at */
	int want_ret;       /* DS_INIT, DS_FILL: the return value */
	int want_audio;     /* DS_FILL: the AUDIO register afterwards */
};
struct ds_bad {             /* a bad file: the RV port's bounded load */
	const char *name;   /* the 8.3 directory name */
	int want_ret;       /* drivesounds_init's return value */
	int want_loaded;    /* drivesounds_loaded() afterwards */
	const char *lines;  /* the load's lines (load_lines) */
};
#include "dscases.h"

#define RING 0x10000

/* the CD audio player (cdaudio.c): busy or not, as the op list says */
static int cda_state;
int32_t cda_busy(void) { return cda_state; }

static int fails, cases;

static void say(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vfprintf(stdout, fmt, ap);
	va_end(ap);
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

static unsigned char *slurp(const char *path, size_t *n)
{
	FILE *f = fopen(path, "rb");
	struct stat st;
	unsigned char *p;
	if (!f || fstat(fileno(f), &st)) { say("FAIL cannot read %s\n", path); exit(1); }
	p = malloc((size_t)st.st_size + 1);
	if (!p || fread(p, 1, (size_t)st.st_size, f) != (size_t)st.st_size) { say("FAIL cannot read %s\n", path); exit(1); }
	fclose(f);
	*n = (size_t)st.st_size;
	return p;
}

/* the load's UART lines as drivesounds.py writes them: "Audio file - length
   <n>", "Sound <id> at <addr>, length <size>" without the address (a host
   address here) and the "Bad ..." lines; the other lines (fat.c's) left out */
static void load_lines(char *out, size_t cap)
{
	const char *u = mock_uart();
	size_t n = 0;
	out[0] = 0;
	while (*u) {
		size_t len = strcspn(u, "\r\n");	/* fat.c ends its "found" line with \r */
		int id, size;
		unsigned addr;
		char line[128];
		snprintf(line, sizeof line, "%.*s", (int)len, u);
		if (sscanf(line, "Sound %d at %X, length %d", &id, &addr, &size) == 3)
			n += (size_t)snprintf(out + n, cap - n, "Sound %d length %d\n", id, size);
		else if (!strncmp(line, "Audio file", 10) || !strncmp(line, "Bad ", 4))
			n += (size_t)snprintf(out + n, cap - n, "%s\n", line);
		if (n >= cap) { say("FAIL load_lines: too long\n"); exit(1); }
		u += len + (u[len] != 0);
	}
}

static void ring_diff(const char *what, const unsigned char *got, const unsigned char *want)
{
	size_t first = RING, nd = 0;
	cases++;
	for (size_t i = 0; i < RING; i++)
		if (got[i] != want[i]) {
			if (first == RING) first = i;
			nd++;
		}
	if (!nd)
		return;
	fails++;
	first &= ~(size_t)3;
	say("FAIL %s: ring differs in %zu bytes, first at frame 0x%zx: %02x %02x %02x %02x, want %02x %02x %02x %02x\n",
	    what, nd, first / 4, got[first], got[first + 1], got[first + 2], got[first + 3],
	    want[first], want[first + 1], want[first + 2], want[first + 3]);
}

static void run_case(const char *dir, const char *name, const struct ds_op *ops, size_t nops,
                     const char *want_lines, unsigned nsnap)
{
	char path[1024], what[160], lines[2048];
	size_t n, snap = 0;
	unsigned char *snaps;
	unsigned char *ring = mock_ring();
	int fails0 = fails;

	snprintf(path, sizeof path, "%s/ring_%s.bin", dir, name);
	snaps = slurp(path, &n);
	if (n != (size_t)nsnap * RING) { say("FAIL %s: %zu bytes, want %u snapshots\n", path, n, nsnap); exit(1); }
	say("---- %s: %zu ops, %u fills\n", name, nops, nsnap);
	for (size_t i = 0; i < nops; i++) {
		const struct ds_op *o = &ops[i];
		switch (o->op) {
		case DS_INIT: {
			unsigned short t;
			mock_timer_step(1);         /* the card's waits need the TIMER to run */
			mock_uart_clear();
			memset(ring, 0, RING);
			snprintf(what, sizeof what, "%s: drivesounds_init(\"%s\")", name, o->name);
			check(what, drivesounds_init(o->name), o->want_ret);
			load_lines(lines, sizeof lines);
			cases++;
			if (strcmp(lines, want_lines)) {
				say("FAIL %s: load, the UART says\n%swant\n%s", name, lines, want_lines);
				fails++;
				free(snaps);
				return;             /* nothing to render on a load that differs */
			}
			mock_timer_step(0);
			t = hosttest_timer();
			hosttest_advance((unsigned)(o->b - t) & 0xFFFF);
			break;
		}
		case DS_ENABLE:  drivesounds_enable(o->a); break;
		case DS_DISABLE: drivesounds_disable(o->a); break;
		case DS_ADVANCE: hosttest_advance((unsigned)o->a); break;
		case DS_QUEUE:   drivesounds_queueevent((enum DriveSound_Type)o->a); break;
		case DS_AUDIO:   mock_audio_set((unsigned char)o->a); break;
		case DS_CDA:     cda_state = o->a; break;
		case DS_FILL: {
			int r = drivesounds_fill();
			unsigned short now = hosttest_timer();
			snprintf(what, sizeof what, "%s fill %zu (op %zu, TIMER %u): return value", name, snap, i, now);
			check(what, r, o->want_ret);
			snprintf(what, sizeof what, "%s fill %zu (op %zu, TIMER %u): AUDIO", name, snap, i, now);
			check(what, *hosttest_audio(), o->want_audio);
			snprintf(what, sizeof what, "%s fill %zu (op %zu, TIMER %u)", name, snap, i, now);
			ring_diff(what, ring, snaps + snap * RING);
			snap++;
			break;
		}
		default:
			say("FAIL %s op %zu: unknown op %d\n", name, i, o->op);
			exit(1);
		}
	}
	check("fills run", (long)snap, (long)nsnap);
	if (fails == fails0)
		say("ok   %s: the load and %zu fills (ring, return value, AUDIO) as the 832's\n", name, snap);
	free(snaps);
}

/* a bad file (drivesounds.py bad_files, rv_load): the load must not write
   into the ring (a pattern that a byte swap changes), and its return value,
   loaded flag and lines are the port's rule */
static void run_bad(const struct ds_bad *c)
{
	char what[160], lines[2048];
	unsigned char *ring = mock_ring();
	size_t nd = 0;
	int fails0 = fails;
	for (size_t i = 0; i < RING; i++)
		ring[i] = (unsigned char)(i * 37 + 11);
	mock_timer_step(1);
	mock_uart_clear();
	snprintf(what, sizeof what, "bad %s: drivesounds_init", c->name);
	check(what, drivesounds_init(c->name), c->want_ret);
	for (size_t i = 0; i < RING; i++)
		nd += ring[i] != (unsigned char)(i * 37 + 11);
	snprintf(what, sizeof what, "bad %s: ring written, bytes", c->name);
	check(what, (long)nd, 0);
	snprintf(what, sizeof what, "bad %s: drivesounds_loaded()", c->name);
	check(what, drivesounds_loaded(), c->want_loaded);
	load_lines(lines, sizeof lines);
	cases++;
	if (strcmp(lines, c->lines)) {
		say("FAIL bad %s: load, the UART says\n%swant\n%s", c->name, lines, c->lines);
		fails++;
	}
	if (fails == fails0)
		say("ok   bad %s: refused as the port's rule says, the ring untouched\n", c->name);
}

int main(int argc, char **argv)
{
	char path[1024];
	struct stat st;
	setvbuf(stdout, NULL, _IOLBF, 0);
	if (argc != 2) {
		say("usage: drivesounds_test <dir>\n");
		return 2;
	}
	snprintf(path, sizeof path, "%s/card.img", argv[1]);
	mock_reset();
	if (stat(path, &st) || st.st_size % 512) { say("FAIL %s: no image of whole sectors\n", path); return 1; }
	if (mock_card_load(path, (unsigned)(st.st_size / 512))) { say("FAIL cannot load %s\n", path); return 1; }
	check("MMC_Init: SDHC", MMC_Init(), CARDTYPE_SDHC);
	check("FindDrive()", FindDrive(), 1);
	ChangeDirectory(DIRECTORY_ROOT);
	run_case(argv[1], "synth", ds_ops_synth, sizeof ds_ops_synth / sizeof ds_ops_synth[0],
	         ds_lines_synth, DS_SNAPS_SYNTH);
	run_case(argv[1], "real", ds_ops_real, sizeof ds_ops_real / sizeof ds_ops_real[0],
	         ds_lines_real, DS_SNAPS_REAL);
	for (size_t i = 0; i < sizeof ds_bad / sizeof ds_bad[0]; i++)
		run_bad(&ds_bad[i]);
	say("%s: %d checks, %d failed\n", fails ? "FAIL" : "PASS", cases, fails);
	return fails != 0;
}

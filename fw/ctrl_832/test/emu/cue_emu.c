/*
 * cue_emu: the CUE parser and disc model compiled by vbcc832 and run in
 * 832e (make -C fw/ctrl_832/test/emu).  cue_test checks the logic with gcc;
 * this checks what vbcc832 makes of it: every narrow field of the reference
 * disc (13.9), the int32 error fields of a refusal (set and returned with
 * the same value: the 12.6 trap) and cue_locate.  The last line is
 * "PASS" or "FAIL n".
 */
#include <stdio.h>
#include <string.h>
#include "cue.h"

static int fails;

static void expect(const char *what, unsigned int got, unsigned int want)
{
	if (got != want) {
		printf("FAIL %s: got %u, want %u\n", what, got, want);
		fails++;
	} else
		printf("ok   %s = %u\n", what, got);
}

/* Not "while (*a && *a == *b) { a++; b++; }": vbcc832 drops those increments. */
static int same(const char *a, const char *b)
{
	int i = 0;
	for (;;) {
		if (a[i] != b[i])
			return 0;
		if (!a[i])
			return 1;
		i++;
	}
}

#define PF "Pinball Fantasies (1993)(21st Century Entertainment)"

static int32_t open_file(void *ctx, const char *name, struct cd_file *f)
{
	static const char *const names[3] = {
		PF "(Track 1 of 3)[!].iso", PF "(Track 2 of 3)[!].wav", PF "(Track 3 of 3)[!].wav"
	};
	static const char *const shorts[3] = { "PINBAL~1ISO", "PINBAL~2WAV", "PINBAL~3WAV" };
	static const uint32_t bytes[3] = { 4521984, 41806800, 50626800 };
	int i, k;
	for (i = 0; i < 3; i++) {
		if (!same(names[i], name))
			continue;
		for (k = 0; k < 11; k++)
			f->shortname[k] = shorts[i][k];
		f->shortname[11] = 0;
		f->data_offset = f->wave ? 44 : 0;
		f->data_bytes = bytes[i];
		return CUE_OK;
	}
	return CUE_E_NOFILE;
}

static const char pinball_cue[] =
	"CATALOG 5012635300313\r\n"
	"FILE \"" PF "(Track 1 of 3)[!].iso\" BINARY\r\n"
	"  TRACK 01 MODE1/2048\r\n"
	"    INDEX 01 00:00:00\r\n"
	"FILE \"" PF "(Track 2 of 3)[!].wav\" WAVE\r\n"
	"  TRACK 02 AUDIO\r\n"
	"    PREGAP 00:02:00\r\n"
	"    INDEX 01 00:00:00\r\n"
	"FILE \"" PF "(Track 3 of 3)[!].wav\" WAVE\r\n"
	"  TRACK 03 AUDIO\r\n"
	"    INDEX 00 00:00:00\r\n"
	"    INDEX 01 00:02:00\r\n";

static const char bad_cue[] =
	"FILE \"" PF "(Track 1 of 3)[!].iso\" BINARY\n"
	"  TRACK 01 MODE1/2048\n"
	"    INDEX 01 00:00:00\n"
	"  FOO\n";

static struct cd_disc disc;
static struct cue_parser parser;

int main(int argc, char **argv)
{
	struct cue_loc loc;
	char msg[24];
	int32_t r;
	int i;

	cue_begin(&parser, &disc, open_file, 0);
	r = cue_feed(&parser, pinball_cue, sizeof(pinball_cue) - 1);
	expect("feed result", r, CUE_OK);
	r = cue_end(&parser);
	expect("end result", r, CUE_OK);
	expect("parser error", parser.error, CUE_OK);
	expect("tracks", disc.tracks, 3);
	expect("files", disc.files, 3);
	expect("lead-out", disc.leadout, 41658);

	expect("t1 number", disc.track[0].number, 1);
	expect("t1 type", disc.track[0].type, CD_DATA2048);
	expect("t1 file", disc.track[0].file, 0);
	expect("t1 file_offset", disc.track[0].file_offset, 0);
	expect("t1 lba", disc.track[0].lba, 0);
	expect("t1 sectors", disc.track[0].sectors, 2208);
	expect("t1 pregap_lba", disc.track[0].pregap_lba, 0);
	expect("t1 pregap_silent", disc.track[0].pregap_silent, 0);

	expect("t2 number", disc.track[1].number, 2);
	expect("t2 type", disc.track[1].type, CD_AUDIO);
	expect("t2 file", disc.track[1].file, 1);
	expect("t2 file_offset", disc.track[1].file_offset, 44);
	expect("t2 lba", disc.track[1].lba, 2358);
	expect("t2 sectors", disc.track[1].sectors, 17775);
	expect("t2 pregap_lba", disc.track[1].pregap_lba, 2208);
	expect("t2 pregap_silent", disc.track[1].pregap_silent, 1);

	expect("t3 number", disc.track[2].number, 3);
	expect("t3 type", disc.track[2].type, CD_AUDIO);
	expect("t3 file", disc.track[2].file, 2);
	expect("t3 file_offset", disc.track[2].file_offset, 44 + 150 * 2352);
	expect("t3 lba", disc.track[2].lba, 20283);
	expect("t3 sectors", disc.track[2].sectors, 21375);
	expect("t3 pregap_lba", disc.track[2].pregap_lba, 20133);
	expect("t3 pregap_silent", disc.track[2].pregap_silent, 0);

	for (i = 0; i < 3; i++) {
		expect("file wave", disc.file[i].wave, i ? 1 : 0);
		expect("file data_offset", disc.file[i].data_offset, i ? 44 : 0);
	}
	expect("file 1 shortname", same(disc.file[1].shortname, "PINBAL~2WAV"), 1);
	expect("file 2 data_bytes", disc.file[2].data_bytes, 50626800);

	expect("locate 2300", cue_locate(&disc, 2300, &loc), 1);
	expect("locate 2300 track", loc.track, 1);
	expect("locate 2300 index", loc.index, 0);
	expect("locate 2300 silent", loc.silent, 1);
	expect("locate 2300 run", loc.run, 58);
	expect("locate 20200", cue_locate(&disc, 20200, &loc), 1);
	expect("locate 20200 track", loc.track, 2);
	expect("locate 20200 index", loc.index, 0);
	expect("locate 20200 silent", loc.silent, 0);
	expect("locate 20200 file", loc.file, 2);
	expect("locate 20200 offset", loc.offset, 44 + 67 * 2352);
	expect("locate lead-out", cue_locate(&disc, 41658, &loc), 0);

	/* a refusal: error and error_line are set and returned (the 12.6 trap) */
	cue_begin(&parser, &disc, open_file, 0);
	r = cue_feed(&parser, bad_cue, sizeof(bad_cue) - 1);
	expect("refusal feed result", r, CUE_E_UNKNOWN);
	expect("refusal error", parser.error, CUE_E_UNKNOWN);
	expect("refusal line", parser.error_line, 4);
	r = cue_end(&parser);
	expect("refusal end result", r, CUE_E_UNKNOWN);
	cue_message(&parser, msg);
	expect("refusal message", same(msg, "line 4: unknown cmd"), 1);

	/* ISO */
	cue_single(&disc, "TESTDISCISO", 2208 * 2048);
	expect("single tracks", disc.tracks, 1);
	expect("single type", disc.track[0].type, CD_DATA2048);
	expect("single number", disc.track[0].number, 1);
	expect("single lead-out", disc.leadout, 2208);

	if (fails)
		printf("FAIL %d\n", fails);
	else
		printf("PASS\n");
	return fails;
}

/*
 * Host test for the CUE parser and disc model (fw/ctrl_832/cue.c).
 *
 * Plan: findings/cdrom/plan.md 13.4, 13.9; findings/cdrom/phase3-plan.md task 1.
 * Build and run: make -C fw/ctrl_832/test
 *
 * The FILE lookups go to a table (fake_open); the reference CUE (Paul's
 * TOSEC Pinball Fantasies set, 13.9) is embedded with its CRLF line ends,
 * so nothing here needs the SD card or the reference disc.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "cue.h"

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

/* ---- the directory behind FILE ---- */

struct fake_file {
	const char *name;	/* as the CUE writes it */
	const char *shortname;	/* 8.3, 11 characters */
	uint32_t    bytes;	/* BINARY: file size; WAVE: data chunk size (data at byte 44) */
	int32_t     result;	/* what the lookup returns */
};

#define PF "Pinball Fantasies (1993)(21st Century Entertainment)"

static const struct fake_file dir[] = {
	{ PF "(Track 1 of 3)[!].iso", "PINBAL~1ISO", 4521984, CUE_OK },
	{ PF "(Track 2 of 3)[!].wav", "PINBAL~2WAV", 41806800, CUE_OK },
	{ PF "(Track 3 of 3)[!].wav", "PINBAL~3WAV", 50626800, CUE_OK },
	{ "game.bin", "GAME    BIN", 300 * 2352, CUE_OK },
	{ "data.iso", "DATA    ISO", 100 * 2048, CUE_OK },
	{ "music.wav", "MUSIC   WAV", 1000 * 2352 + 100, CUE_OK },	/* partial last sector */
	{ "mono.wav", "MONO    WAV", 1000, CUE_E_WAV },
	{ 0, 0, 0, 0 }
};

static int opens;

static int32_t fake_open(void *ctx, const char *name, struct cd_file *f)
{
	const struct fake_file *d;
	(void)ctx;
	opens++;
	for (d = dir; d->name; d++) {
		if (strcmp(d->name, name) != 0)
			continue;
		if (d->result != CUE_OK)
			return d->result;
		memcpy(f->shortname, d->shortname, 11);
		f->shortname[11] = 0;
		f->data_offset = f->wave ? 44 : 0;
		f->data_bytes = d->bytes;
		return CUE_OK;
	}
	return CUE_E_NOFILE;
}

/* 13.9, CRLF as on the SD card */
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

static struct cd_disc D;
static struct cue_parser P;

/* Parse text fed in chunks of chunk bytes; returns cue_end's result. */
static int32_t parse(const char *text, uint32_t chunk)
{
	uint32_t len = (uint32_t)strlen(text), i;
	cue_begin(&P, &D, fake_open, 0);
	for (i = 0; i < len; i += chunk)
		if (cue_feed(&P, text + i, (len - i) < chunk ? len - i : chunk) != CUE_OK)
			break;
	return cue_end(&P);
}

static void expect_track(int line, int i, uint8_t number, uint8_t type, uint8_t file, uint32_t file_offset,
			 uint32_t lba, uint32_t sectors, uint32_t pregap_lba, uint8_t silent)
{
	const struct cd_track *t = &D.track[i];
	if (t->number != number || t->type != type || t->file != file || t->file_offset != file_offset ||
	    t->lba != lba || t->sectors != sectors || t->pregap_lba != pregap_lba || t->pregap_silent != silent) {
		case_fails++;
		printf("  FAIL %s (line %d): track[%d] = n %u type %u file %u off %u lba %u sectors %u gap %u silent %u\n",
		       case_name, line, i, t->number, t->type, t->file, t->file_offset, t->lba, t->sectors,
		       t->pregap_lba, t->pregap_silent);
		printf("       want n %u type %u file %u off %u lba %u sectors %u gap %u silent %u\n",
		       number, type, file, file_offset, lba, sectors, pregap_lba, silent);
	}
}

static void expect_loc(int line, uint32_t lba, int32_t track, int32_t index, int32_t silent, int32_t file,
		       uint32_t offset, uint32_t run)
{
	struct cue_loc l;
	memset(&l, 0xA5, sizeof(l));
	if (!cue_locate(&D, lba, &l)) {
		case_fails++;
		printf("  FAIL %s (line %d): cue_locate(%u) found nothing\n", case_name, line, lba);
		return;
	}
	if (l.track != track || l.index != index || l.silent != silent || (!silent && (l.file != file || l.offset != offset)) ||
	    l.run != run) {
		case_fails++;
		printf("  FAIL %s (line %d): lba %u -> track %d index %d silent %d file %d offset %u run %u,"
		       " want %d %d %d %d %u %u\n", case_name, line, lba, l.track, l.index, l.silent, l.file, l.offset,
		       l.run, track, index, silent, file, offset, run);
	}
}

/* The refusal and its line. */
static void expect_error(int line, const char *text, int32_t err, int32_t at)
{
	int32_t r = parse(text, 1000);
	if (r != err || P.error != err || P.error_line != at) {
		case_fails++;
		printf("  FAIL %s (line %d): result %d error %d at line %d, want %d at line %d\n",
		       case_name, line, r, P.error, P.error_line, err, at);
	}
}

/* ---- cases ---- */

static void t_reference(void)
{
	char msg[24];
	begin("reference CUE (13.9): files, tracks, LBA layout, lead-out 41658");
	opens = 0;
	EXPECT(parse(pinball_cue, 100000) == CUE_OK, "error %d at line %d", P.error, P.error_line);
	EXPECT(opens == 3, "%d FILE lookups", opens);
	EXPECT(D.tracks == 3 && D.files == 3, "tracks %d files %d", D.tracks, D.files);
	EXPECT(strcmp(D.file[0].shortname, "PINBAL~1ISO") == 0 && !D.file[0].wave &&
	       D.file[0].data_offset == 0 && D.file[0].data_bytes == 4521984, "file 0");
	EXPECT(strcmp(D.file[1].shortname, "PINBAL~2WAV") == 0 && D.file[1].wave &&
	       D.file[1].data_offset == 44 && D.file[1].data_bytes == 41806800, "file 1");
	EXPECT(strcmp(D.file[2].shortname, "PINBAL~3WAV") == 0 && D.file[2].wave, "file 2");
	expect_track(__LINE__, 0, 1, CD_DATA2048, 0, 0, 0, 2208, 0, 0);
	expect_track(__LINE__, 1, 2, CD_AUDIO, 1, 44, 2358, 17775, 2208, 1);
	expect_track(__LINE__, 2, 3, CD_AUDIO, 2, 44 + 150 * 2352, 20283, 21375, 20133, 0);
	EXPECT(D.leadout == 41658, "lead-out %u", D.leadout);
	cue_message(&P, msg);
	EXPECT(strcmp(msg, "ok") == 0, "message '%s'", msg);
	end();
}

static void t_reference_locate(void)
{
	struct cue_loc l;
	begin("reference CUE: cue_locate at every boundary");
	parse(pinball_cue, 100000);
	expect_loc(__LINE__, 0, 0, 1, 0, 0, 0, 2208);
	expect_loc(__LINE__, 2207, 0, 1, 0, 0, 2207 * 2048, 1);
	expect_loc(__LINE__, 2208, 1, 0, 1, 0, 0, 150);			/* PREGAP: silent */
	expect_loc(__LINE__, 2357, 1, 0, 1, 0, 0, 1);
	expect_loc(__LINE__, 2358, 1, 1, 0, 1, 44, 17775);
	expect_loc(__LINE__, 20132, 1, 1, 0, 1, 44 + 17774u * 2352, 1);
	expect_loc(__LINE__, 20133, 2, 0, 0, 2, 44, 150);			/* INDEX 00 in the file */
	expect_loc(__LINE__, 20282, 2, 0, 0, 2, 44 + 149 * 2352, 1);
	expect_loc(__LINE__, 20283, 2, 1, 0, 2, 44 + 150 * 2352, 21375);
	expect_loc(__LINE__, 41657, 2, 1, 0, 2, 44 + 21524u * 2352, 1);
	EXPECT(cue_locate(&D, 41658, &l) == 0, "the lead-out located");
	EXPECT(cue_locate(&D, 0xFFFFFFFFu, &l) == 0, "0xFFFFFFFF located");
	end();
}

static void t_chunks(void)
{
	static char lf[sizeof(pinball_cue)];
	uint32_t i, n = 0;
	begin("CRLF or LF, fed 1 or 7 bytes at a time, no final newline: same disc");
	EXPECT(parse(pinball_cue, 1) == CUE_OK && D.leadout == 41658 && D.track[2].lba == 20283, "1-byte chunks");
	EXPECT(parse(pinball_cue, 7) == CUE_OK && D.leadout == 41658 && D.track[1].pregap_lba == 2208, "7-byte chunks");
	for (i = 0; pinball_cue[i]; i++)
		if (pinball_cue[i] != '\r')
			lf[n++] = pinball_cue[i];
	lf[n - 1] = 0;	/* and no newline at the end */
	EXPECT(parse(lf, 5) == CUE_OK && D.leadout == 41658 && D.track[2].sectors == 21375, "LF only");
	end();
}

static void t_bincue(void)
{
	static const char cue[] =
		"FILE \"game.bin\" BINARY\n"
		"  TRACK 01 MODE1/2352\n"
		"    INDEX 01 00:00:00\n"
		"  TRACK 02 AUDIO\n"
		"    INDEX 00 00:01:25\n"	/* sector 100 */
		"    INDEX 01 00:01:27\n"	/* sector 102 */
		"  TRACK 03 AUDIO\n"
		"    INDEX 01 00:02:50\n";	/* sector 200 */
	begin("BIN/CUE: one file, MODE1/2352 + 2 audio tracks, INDEX 00 in the file");
	EXPECT(parse(cue, 1000) == CUE_OK, "error %d at %d", P.error, P.error_line);
	EXPECT(D.files == 1 && D.file[0].data_bytes == 300 * 2352 && strcmp(D.file[0].shortname, "GAME    BIN") == 0, "file");
	expect_track(__LINE__, 0, 1, CD_DATA2352, 0, 0, 0, 102, 0, 0);
	expect_track(__LINE__, 1, 2, CD_AUDIO, 0, 102 * 2352, 102, 98, 100, 0);
	expect_track(__LINE__, 2, 3, CD_AUDIO, 0, 200 * 2352, 200, 100, 200, 0);
	EXPECT(D.leadout == 300, "lead-out %u", D.leadout);
	expect_loc(__LINE__, 99, 0, 1, 0, 0, 99 * 2352, 1);		/* stops at track 2's INDEX 00 */
	expect_loc(__LINE__, 100, 1, 0, 0, 0, 100 * 2352, 2);
	expect_loc(__LINE__, 102, 1, 1, 0, 0, 102 * 2352, 98);
	expect_loc(__LINE__, 299, 2, 1, 0, 0, 299 * 2352, 1);
	end();
}

static void t_pregap_postgap(void)
{
	static const char bin_pregap[] =
		"FILE game.bin BINARY\n"		/* a bare name */
		"TRACK 01 MODE1/2352\n"
		"INDEX 01 00:00:00\n"
		"TRACK 02 AUDIO\n"
		"PREGAP 00:02:00\n"
		"INDEX 01 00:01:25\n"			/* sector 100 */
		"TRACK 03 AUDIO\n"
		"INDEX 01 00:02:50\n";			/* sector 200 */
	static const char postgap[] =
		"FILE \"data.iso\" BINARY\n"
		"TRACK 01 MODE1/2048\n"
		"INDEX 01 00:00:00\n"
		"POSTGAP 00:02:00\n"
		"FILE \"music.wav\" WAVE\n"
		"TRACK 02 AUDIO\n"
		"INDEX 01 00:00:00\n";
	begin("PREGAP (silent, shifts the rest of the file), POSTGAP (silent after the track), partial WAV sector");
	EXPECT(parse(bin_pregap, 1000) == CUE_OK, "pregap: error %d at %d", P.error, P.error_line);
	expect_track(__LINE__, 0, 1, CD_DATA2352, 0, 0, 0, 100, 0, 0);
	expect_track(__LINE__, 1, 2, CD_AUDIO, 0, 100 * 2352, 250, 100, 100, 1);
	expect_track(__LINE__, 2, 3, CD_AUDIO, 0, 200 * 2352, 350, 100, 350, 0);
	EXPECT(D.leadout == 450, "lead-out %u", D.leadout);
	expect_loc(__LINE__, 100, 1, 0, 1, 0, 0, 150);
	expect_loc(__LINE__, 250, 1, 1, 0, 0, 100 * 2352, 100);
	expect_loc(__LINE__, 349, 1, 1, 0, 0, 199 * 2352, 1);

	EXPECT(parse(postgap, 1000) == CUE_OK, "postgap: error %d at %d", P.error, P.error_line);
	expect_track(__LINE__, 0, 1, CD_DATA2048, 0, 0, 0, 100, 0, 0);
	expect_track(__LINE__, 1, 2, CD_AUDIO, 1, 44, 250, 1001, 250, 0);	/* 1000 sectors + 100 bytes */
	EXPECT(D.leadout == 1251, "lead-out %u", D.leadout);
	expect_loc(__LINE__, 99, 0, 1, 0, 0, 99 * 2048, 1);
	expect_loc(__LINE__, 100, 0, 1, 1, 0, 0, 150);			/* POSTGAP */
	expect_loc(__LINE__, 250, 1, 1, 0, 1, 44, 1001);
	end();
}

static void t_implicit_gap(void)
{
	static const char wav_late[] =
		"FILE \"data.iso\" BINARY\n"
		"TRACK 01 MODE1/2048\n"
		"INDEX 01 00:00:00\n"
		"FILE \"music.wav\" WAVE\n"
		"TRACK 02 AUDIO\n"
		"INDEX 01 00:02:00\n";
	static const char audio_first[] =
		"FILE \"game.bin\" BINARY\n"
		"TRACK 01 AUDIO\n"
		"INDEX 00 00:00:00\n"
		"INDEX 01 00:02:00\n"
		"TRACK 02 AUDIO\n"
		"INDEX 01 00:03:00\n";
	begin("a WAV starting before its INDEX 01 (gap in the file); track 1 INDEX 01 at 00:02:00 is LBA 0");
	EXPECT(parse(wav_late, 1000) == CUE_OK, "error %d at %d", P.error, P.error_line);
	expect_track(__LINE__, 1, 2, CD_AUDIO, 1, 44 + 150 * 2352, 250, 851, 100, 0);
	expect_loc(__LINE__, 100, 1, 0, 0, 1, 44, 150);
	EXPECT(parse(audio_first, 1000) == CUE_OK, "error %d at %d", P.error, P.error_line);
	expect_track(__LINE__, 0, 1, CD_AUDIO, 0, 150 * 2352, 0, 75, 0, 0);
	expect_track(__LINE__, 1, 2, CD_AUDIO, 0, 225 * 2352, 75, 75, 75, 0);
	EXPECT(D.leadout == 150, "lead-out %u", D.leadout);
	end();
}

static void t_ignored(void)
{
	static const char cue[] =
		"\xEF\xBB\xBFREM GENRE Game\n"
		"REM SESSION 01\n"
		"CATALOG 5012635300313\n"
		"TITLE \"A disc\"\n"
		"PERFORMER \"Someone\"\n"
		"SONGWRITER \"Someone else\"\n"
		"CDTEXTFILE \"x.cdt\"\n"
		"\n"
		"   \t \n"
		"file \"data.iso\" binary\n"
		"  track 01 mode1/2048\n"
		"    flags DCP\n"
		"    isrc ABCDE1234567\n"
		"    index 01 00:00:00\n";
	begin("ignored commands, a byte order mark, blank lines, lower case keywords");
	EXPECT(parse(cue, 1000) == CUE_OK, "error %d at %d", P.error, P.error_line);
	EXPECT(D.tracks == 1 && D.leadout == 100, "tracks %d lead-out %u", D.tracks, D.leadout);
	end();
}

static void t_refusals(void)
{
	static char longline[400];
	static char many_tracks[100 * 40 + 64];
	static char many_files[100 * 40];
	char msg[24];
	int i, n;

	begin("every refusal, with its line");
	expect_error(__LINE__, "FILE \"data.iso\" BINARY\nTRACK 01 MODE1/2048\nINDEX 01 00:00:00\nFOO BAR\n", CUE_E_UNKNOWN, 4);
	cue_message(&P, msg);
	EXPECT(strcmp(msg, "line 4: unknown cmd") == 0, "message '%s'", msg);
	expect_error(__LINE__, "FILE \"game.bin\" BINARY\nTRACK 01 MODE2/2352\n", CUE_E_MODE, 2);
	expect_error(__LINE__, "FILE \"game.bin\" BINARY\nTRACK 01 CDG\n", CUE_E_MODE, 2);
	expect_error(__LINE__, "FILE \"game.bin\" BINARY\nTRACK 01 MODE1/2336\n", CUE_E_MODE, 2);
	expect_error(__LINE__, "FILE \"x.mp3\" MP3\n", CUE_E_FILETYPE, 1);
	expect_error(__LINE__, "REM\nFILE \"nothere.iso\" BINARY\n", CUE_E_NOFILE, 2);
	cue_message(&P, msg);
	EXPECT(strcmp(msg, "line 2: file missing") == 0, "message '%s'", msg);
	expect_error(__LINE__, "FILE \"mono.wav\" WAVE\n", CUE_E_WAV, 1);
	expect_error(__LINE__, "REM SESSION 02\n", CUE_E_SESSION, 1);
	expect_error(__LINE__, "FILE \"game.bin\" BINARY\nTRACK 02 AUDIO\n", CUE_E_ORDER, 2);
	expect_error(__LINE__, "FILE \"game.bin\" BINARY\nTRACK 01 AUDIO\nINDEX 01 00:00:00\nTRACK 03 AUDIO\n", CUE_E_ORDER, 4);
	expect_error(__LINE__, "FILE \"game.bin\" BINARY\nTRACK 01 AUDIO\nINDEX 01 00:00:00\nINDEX 02 00:01:00\n", CUE_E_INDEX, 4);
	expect_error(__LINE__, "FILE \"game.bin\" BINARY\nTRACK 01 AUDIO\nINDEX 01 00:00:00\nINDEX 00 00:00:00\n", CUE_E_INDEX, 4);
	expect_error(__LINE__, "FILE \"game.bin\" BINARY\nTRACK 01 AUDIO\nINDEX 01 00:00:00\nINDEX 01 00:00:00\n", CUE_E_INDEX, 4);
	expect_error(__LINE__, "FILE \"game.bin\" BINARY\nTRACK 01 AUDIO\nINDEX 00 00:02:00\nINDEX 01 00:01:00\n", CUE_E_INDEX, 4);
	expect_error(__LINE__, "FILE \"game.bin\" BINARY\nTRACK 01 AUDIO\nINDEX 01 00:00:00\nTRACK 02 AUDIO\n", CUE_E_INDEX, 4);
	expect_error(__LINE__, "FILE \"game.bin\" BINARY\nTRACK 01 AUDIO\nINDEX 01 00:02:00\nTRACK 02 AUDIO\nINDEX 01 00:01:00\n",
		     CUE_E_INDEX, 4);
	expect_error(__LINE__, "FILE \"game.bin\" BINARY\nTRACK 01 AUDIO\nINDEX 01 00:00:00\nTRACK 02 AUDIO\nINDEX 00 00:01:00\n"
		     "FILE \"music.wav\" WAVE\nINDEX 01 00:00:00\n", CUE_E_INDEX, 7);	/* EAC "gaps appended" */
	expect_error(__LINE__, "FILE \"game.bin\" BINARY\nTRACK 01 AUDIO\nPREGAP 00:02:00\nINDEX 00 00:00:00\n", CUE_E_GAP, 4);
	expect_error(__LINE__, "FILE \"game.bin\" BINARY\nTRACK 01 AUDIO\nINDEX 00 00:00:00\nPREGAP 00:02:00\n", CUE_E_GAP, 4);
	expect_error(__LINE__, "TRACK 01 AUDIO\n", CUE_E_SYNTAX, 1);
	expect_error(__LINE__, "FILE \"game.bin\" BINARY\nTRACK 01 AUDIO\nINDEX 01 00:60:00\n", CUE_E_SYNTAX, 3);
	expect_error(__LINE__, "FILE \"game.bin\" BINARY\nTRACK 01 AUDIO\nINDEX 01 00:00:75\n", CUE_E_SYNTAX, 3);
	expect_error(__LINE__, "FILE \"game.bin\" BINARY\nTRACK 01 AUDIO\nINDEX 01 1:2\n", CUE_E_SYNTAX, 3);
	expect_error(__LINE__, "FILE \"game.bin\" BINARY\nTRACK 01 AUDIO\nINDEX 01 00:00:00 extra\n", CUE_E_SYNTAX, 3);
	expect_error(__LINE__, "FILE \"game.bin BINARY\n", CUE_E_SYNTAX, 1);
	expect_error(__LINE__, "FILE game bin.bin BINARY\n", CUE_E_SYNTAX, 1);
	expect_error(__LINE__, "FILE \"music.wav\" WAVE\nTRACK 01 MODE1/2048\n", CUE_E_MIXED, 2);
	expect_error(__LINE__, "FILE \"game.bin\" BINARY\nTRACK 01 MODE1/2048\nINDEX 01 00:00:00\nTRACK 02 AUDIO\n", CUE_E_MIXED, 4);
	expect_error(__LINE__, "FILE \"data.iso\" BINARY\nTRACK 01 MODE1/2048\nINDEX 01 00:02:00\n", CUE_E_END, 2);
	expect_error(__LINE__, "REM nothing\n", CUE_E_EMPTY, 0);
	cue_message(&P, msg);
	EXPECT(strcmp(msg, "no tracks") == 0, "message '%s'", msg);
	expect_error(__LINE__, "", CUE_E_EMPTY, 0);

	memset(longline, 'x', sizeof(longline) - 1);
	memcpy(longline, "REM ", 4);
	expect_error(__LINE__, longline, CUE_E_LINE, 1);

	n = sprintf(many_tracks, "FILE \"game.bin\" BINARY\n");
	for (i = 1; i <= 100; i++)
		n += sprintf(many_tracks + n, "TRACK %02d AUDIO\nINDEX 01 00:00:%02d\n", i, (i - 1) % 75);
	expect_error(__LINE__, many_tracks, CUE_E_TOOMANY, 1 + 99 * 2 + 1);
	n = 0;
	for (i = 0; i < 100; i++)
		n += sprintf(many_files + n, "FILE \"data.iso\" BINARY\n");
	expect_error(__LINE__, many_files, CUE_E_TOOMANY, 100);
	end();
}

static void t_message(void)
{
	char msg[24];
	begin("cue_message: at most 23 characters");
	P.error = CUE_E_GAP;
	P.error_line = 12345;
	cue_message(&P, msg);
	EXPECT(strlen(msg) <= 23 && strncmp(msg, "line 9999: PREGAP", 17) == 0, "message '%s'", msg);
	end();
}

static void t_single(void)
{
	begin("cue_single: an ISO is one DATA2048 track over the whole file");
	memset(&D, 0xA5, sizeof(D));
	cue_single(&D, "TESTDISCISO", 4521984 + 100);
	EXPECT(D.tracks == 1 && D.files == 1 && D.leadout == 2208, "tracks %d files %d lead-out %u", D.tracks, D.files, D.leadout);
	expect_track(__LINE__, 0, 1, CD_DATA2048, 0, 0, 0, 2208, 0, 0);
	EXPECT(strcmp(D.file[0].shortname, "TESTDISCISO") == 0 && !D.file[0].wave && D.file[0].data_offset == 0, "file");
	expect_loc(__LINE__, 16, 0, 1, 0, 0, 16 * 2048, 2192);
	end();
}

int main(void)
{
	t_reference();
	t_reference_locate();
	t_chunks();
	t_bincue();
	t_pregap_postgap();
	t_implicit_gap();
	t_ignored();
	t_refusals();
	t_message();
	t_single();

	printf("\n%d cases: %d passed, %d failed (%d failed checks)\n",
	       cases_run, cases_passed, cases_run - cases_passed, total_fails);
	return total_fails ? 1 : 0;
}

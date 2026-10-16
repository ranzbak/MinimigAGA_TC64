# CD-ROM Phase 3 (CUE sheets, CD audio) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The CD-ROM drive takes CUE sheets -- ISO + one WAV per audio track (TOSEC) and single-file BIN/CUE (raw 2352-byte sectors) -- with a multi-track TOC, and plays CD audio through the 64 KB audio ring; READ CD, the page 0E volume and an OSD play mark complete it.

**Architecture:** Three pure units, each host-tested with gcc and run in 832e as vbcc832 builds it: `cue.c` (CUE text -> disc model, LBA layout, sector lookup, WAV header walk), `atapi.c` (every command from the disc model; PLAY commands return a play request), `cdaudio.c` (the player behind a six-function port).  `cdrom.c` stays the board glue: it reads the CUE, opens the files (two at most: data and audio), streams the reads, implements the player's port, and carries the play requests; `CD_AudioPoll()` is called from the main loop and between the blocks of every SD transfer loop.

**Tech Stack:** C99 for the 832 (vbcc832), gcc host tests with ASan/UBSan, 832e emulator tests

**Spec:** findings/cdrom/plan.md section 13

Worktree: `/tmp/claude-1000/-home-paul-work-fpga-Xilinx-artix7-MinimigAGA-TC64/7a74dad0-cd96-4d4d-94c2-f7d9a512b738/scratchpad/cdrom_wt`, branch `cdrom`, plan written against head c8639ed.  Every command below runs from the worktree root.  `832DIR=/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64/EightThirtyTwo` (the worktree's own `EightThirtyTwo` has no built vbcc).

How this plan was made: every task's code was written and run in a scratch copy of `fw/ctrl_832` (c8639ed): each task's tests were seen failing first (the outputs in step 2 are copied from those runs), then passing; the firmware was built with vbcc832 after tasks 4, 5, 8, 9 and 12, and the emu tests passed after tasks 1, 2, 3, 7, 8, 11 and 12.  The diffs below are those files, `diff -u` against the previous task.  Hand mutants were run against the new tests (CD-DA offset, 8.3 lookup, directory restore, the silent-gap branch, the underrun silence and resync, the end-of-play margin, the TIMER/pointer phase fix, the AUDIOF_AMIGA restart, the one-shot status, the play/stop wiring); each one fails at least one test.

## Spec issues

1. **The config has no room for the CUE's extension (13.5: "short name + extension now kept").**  `hardfileTYPE.name` is `char name[8]` (config.h) and `configTYPE` is pinned at 212 bytes (config.c, `config_size_is_212`), so "NAME    CUE" cannot be stored as written.  Resolution this plan implements, **for Paul to confirm**: the CD slot's `present` byte (rewritten by `CD_Open` on every load, so its saved value is free) says which disc the 8 characters name: `CD_PRESENT_ISO` 1 (what phase-1 configs already hold), `CD_PRESENT_CUE` 2.  Old firmware reading a new config opens `NAME.ISO` and leaves the drive empty if that is not there; new firmware reads old configs unchanged.  Cost if wrong: one byte of meaning in the config.  The alternative (try `NAME.CUE`, then `NAME.ISO`) opens the wrong disc when both exist and the user chose the ISO -- `game.cue` next to the `game.iso` it references is a common ISO+WAV layout.

## Clarifications and additions (no design change)

- **13.4 `sectors` "to the next track's INDEX 01":** kept literally.  In one file with an INDEX 00, track N's sectors then overlap track N+1's gap; `cue_locate` gives a sector to the last track whose gap has started (the INDEX 00 owns it, as on a real disc).  TOC and lengths are the same either way.
- **What the CUE parser refuses beyond 13.1's list** (13.4: "a CUE we misread is worse than one we refuse"): PREGAP and INDEX 00 on one track (the model has one gap per track), INDEX 02 and up (13.4 accepts 00/01), an INDEX in a later FILE than its TRACK (EAC "gaps appended" sheets), MODE1/2048 inside a WAVE file or mixed 2048/2352 tracks in one BINARY, INDEX 01 past the end of its file, a line over 300 characters, non-consecutive TRACK numbers, `REM SESSION 02` (the 13.1 "several sessions").  Each has its own message.
- **Layout corner cases:** track 1's INDEX 01 is LBA 0 even when it is not at 00:00:00 (an audio CD's INDEX 00 at 00:00:00 / INDEX 01 at 00:02:00): the file bytes before it are the lead-in, not addressable.  A FILE whose first track has INDEX 01 after 00:00:00 and no INDEX 00 gets an implicit INDEX 00 at 00:00:00 (the bytes are on the disc).
- **FILE lookup:** `FileOpen`'s long-name match is a prefix match, and a lower-case 8.3 name ("game.bin") has no long-name entry on a FAT card, so `cdrom.c` tries the 8.3 form first, then the long name.  Lookups save and restore fat.c's `iCurrentDirectory`/`iPreviousDirectory` (the OSD file browser's state) and clear the `ERROR_FILESYSTEM` a failed lookup sets (the refusal is the OSD message, not the error page).
- **"read line by line (RARead)":** the CUE is read through `RARead` in 512-byte pieces and `cue_feed` assembles the lines, so no buffer holds the whole sheet (a 99-file CUE is ~14 KB).
- **13.10 memory:** measured, `.bss` ends at 0x28024 after 3a, 0x2a220 after 3b, 0x2a920 after 3c (from 0x24698): the second open file (`hdfTYPE`, 4.4 KB with its cluster index), two `RAFile`s (1.6 KB), the parser (2.6 KB) and the model (4.8 KB) come on top of 13.10's estimate; `struct cdimage cd` (2.4 KB) goes.  The drive-sound sample space shrinks by ~25 KB (of ~300 KB).
- **READ CAPACITY, READ DISC/TRACK INFORMATION** follow the model (last LBA = lead-out - 1; tracks and their sizes) although 13.6 does not list them; **PLAY CD (BC)** stays a no-op GOOD (not in 13.6).
- **READ CD (13.6)** accepts selection byte 0x10 only (user data / CD-DA); 0xF8 (sync + headers + EDC, what rippers often send) is "other selections" -> 05/24/00 as specified.  Expected-sector-type Mode 2 values give 05/64/00 (no such track), reserved ones 05/24/00.
- **The page-2A audio bit and feature 0103h** come with the PLAY commands (step 3b, task 8): a CD player program may look at them before it offers play.  13.8 names no step for them.
- **The player gives the ring back silent:** on stop / end / error it CLEARs and zeroes the 64 KB, so the drive sounds do not start on a remnant of the music.  The end is declared one TIMER unit after the last real sample (TIMER can lead the play pointer by up to 255 frames).
- **lib832's printf has no precision:** main page line 6's `" CD-ROM: %.21s"` (phase 1) prints "21s"; task 5 builds the line with `strncat`.  New prints use plain `%d` / `%x` / `%s` only.

## Global Constraints

- Firmware only: no RTL change, no bitstream; the board tests run the image of 12.6 (stage_cdscaler2) with a new `832OSDAD.BIN` on the SD card.
- Audio format (13.2): 44.1 kHz, 16-bit little-endian, interleaved stereo; ring 2 x 32 KB at 832 address `AUDIO_BUFFER` 0x70000; `AUDIO` 0x0fffffb3 write bit 0 ENA, bit 1 CLEAR, read bit 0 = half playing, bit 1 = `AUDIOF_AMIGA`; `TIMER` 0x0fffffd2 = 256 frames a unit; a CD sector = 588 frames, a half = 8192 frames.
- WAV data and BIN audio are copied without byte swapping; volume 255/255 is a straight copy, otherwise sample x vol / 256, 0 = silence.
- CD audio wins the ring over the drive sounds while playing or paused; `AUDIOF_AMIGA` set: the player writes neither ring nor register, the position runs on TIMER.
- `CD_AudioPoll()` only between SD operations: main loop, `cd_wait`, between `cd_send_sectors` blocks, the HDD read/write block waits, between floppy sectors; never inside `FileReadEx`/`MMC_ReadMultiple`.
- Unknown CUE command = refusal with an OSD message naming the line; no half-mounted disc (the drive is empty after any refusal but "locked").
- At most 99 tracks and 99 files; at most two disc files open (data file `cdrom.hdf`, audio file `cd_audio`).
- vbcc832 (12.6): a field set and returned with the same constant is `int32_t` (`kind`, `audio`, `error`, `state`, `audio_status`, `audio_seen`); every new unit has an 832e test.
- vbcc832 -O=1343 drops the increment in `while (*s && *s != c) s++;` (found by `cue_emu`, it never returned): scanning loops in new code are `for (;;) { c = s[i]; if (stop) break; i++; }` or counted.
- 832e (EightThirtyTwo d1cd671) has no `mul` (and the known `ldt` flag gap): the emu harness patches both into `832e_fix`; every emu program runs under `timeout 60`.
- lib832 printf: no width or precision (`%02X` prints garbage, `%.21s` prints "21s"): `%d`, `%x`, `%s` only in new code.
- Paul's commit rules: coherent buildable commits, stage only the task's files (never `fw/ctrl_832/version.h`, which every firmware build rewrites), commit on branch `cdrom`, message ends with the `Co-Authored-By` line.
- Header changes: fw/ctrl_832/Makefile has no header dependencies -- `make -C fw/ctrl_832 clean` before every firmware build in this plan.
- After every firmware build: no duplicate globals (832l links duplicates silently, 12.3): `awk '$1 ~ /^0x/ && NF==2 && $2 ~ /^_/ {print $2}' fw/ctrl_832/832OSDAD.map | sort | uniq -d` prints `_STACKTOP` only.

## Review Focus

1. **vbcc832 code generation on the new units** (narrow fields, pointer-increment loops, `mul`, `/ 588`): only the 832e runs see it -- `cue_emu` (tasks 1, 2), `atapi_emu` (tasks 3, 8, 11), `cdaudio_emu` (task 7), each checking every narrow field and the int32 set-and-returned ones.  A hang is a failure (`timeout 60`).
2. **TIMER against the play pointer at a half flip:** TIMER can be a unit ahead of AUDIO bit 0, which without the parity fix refilled the half that had not played yet, and without the end margin cut the last samples -- `t_timer_phase` in `cdaudio_test` (task 7).
3. **A late refill** (a long SD transfer between polls): the stale half silenced and the stream re-synchronised to where the hardware is, counted once -- `t_late` (task 7); on the board the "CDA: underrun" count during a hard-disk copy (task 10).
4. **CUE names on a real card:** a lower-case 8.3 name without a long-name entry, long-name prefix matches, the OSD browser's directory state, the filesystem error a failed lookup leaves -- `t_cue_names`, `t_cue_refusals` in `cdrom_test` (task 4).
5. **Reads that cross track or file boundaries** (ISO direct path -> POSTGAP zeros -> another file's raw 2352 sectors, and back; READ CD mixing a silent gap with CD-DA) -- `t_cue_split` (task 4), `t_read_cd` (task 11); the partial last WAV sector is silence, not the next block (`t_stream`, task 7).

## Decomposition notes

- The WAV header walk is `cue_wav` in `cue.c` (pure, read callback), not in `cdrom.c`, so it is host- and emu-tested (task 2).
- `atapi_result` is not extended with file / offset / sector size (suggested task 3): READ keeps `lba`/`count` and `cdrom.c` splits the range with `cue_locate` (it must anyway: one READ can cross several tracks and files).  `atapi.c` only decides whether the range may be read (`touches()`).
- A firmware build is the check of task 5 (OSD, FAT and main loop code has no host harness); each step ends with its own build + staging + board task (6, 10, 13).

## File Structure

| File | Responsibility | Tasks |
|---|---|---|
| `fw/ctrl_832/cue.h`, `cue.c` (new) | Disc model (`struct cd_disc`), CUE parser (`cue_begin/feed/end`), LBA layout, `cue_locate` (sector -> track, index, file offset), `cue_single` (ISO), `cue_wav`, `cue_message` | 1, 2 |
| `fw/ctrl_832/cdaudio.h`, `cdaudio.c` (new) | The player: states, run (CLEAR / fill / ENA), refill on a half flip, underrun resync, position by TIMER, volume, `AUDIOF_AMIGA`; the `cda_port_*` interface | 7 |
| `fw/ctrl_832/atapi.h`, `atapi.c` | Commands from the disc model: TOC, capacity, disc/track info, READ range check, PLAY/PAUSE/STOP requests, SUB-CHANNEL from the player's status, READ CD, MODE SELECT volume | 3, 8, 11 |
| `fw/ctrl_832/cdrom.h`, `cdrom.c` | Insert (ISO / CUE), FILE lookup, the two open files, READ / READ CD data paths, the player's port, play requests, `CD_AudioPoll`, `CD_Message`, `CD_PlayingTrack` | 3, 4, 9, 11, 12 |
| `fw/ctrl_832/hdd.c`, `fdd.c`, `main.c` | `CD_AudioPoll()` between blocks / sectors and in the main loop | 9 |
| `fw/ctrl_832/drivesounds.c`, `.h` | Silent while the player owns the ring (`cda_busy`), `drivesounds_yield` | 9 |
| `fw/ctrl_832/menu.c`, `fat.c`, `charrom.h` | ISO+CUE picker (`ExtensionMatch`), refusal messages, CD line without `%.21s`, play mark (note glyph 0x19), IDE port 2 line | 5, 12 |
| `fw/ctrl_832/main.c`, `Makefile`; `bincue.c/.h`, `audiotrack.c/.h` (deleted) | The 2020 leftovers out; `cue.o`, `cdaudio.o` in | 3, 5, 9 |
| `fw/ctrl_832/test/cue_test.c`, `cdaudio_test.c` (new); `atapi_test.c`, `cdrom_test.c`, `Makefile`, `.gitignore` | Host tests | 1-4, 7-9, 11, 12 |
| `fw/ctrl_832/test/emu/cue_emu.c`, `cdaudio_emu.c` (new); `atapi_emu.c`, `Makefile`, `.gitignore` | 832e tests, emulator fixes | 1-3, 7, 8, 11 |

Expected host-test summary lines with the OS 3.9 ISO at `~/work/amiga/AmigaOS3.9.iso`; without it `atapi_test` prints `N cases: N-1 passed, 0 failed, 1 skipped` and exits 0.

How to apply a diff block: save it verbatim to a file and run `git apply --check <file> && git apply <file>` from the worktree root (the sources indent with tabs; the blocks keep them).  If a block does not apply, make the same edits by hand: the `-` lines go, the `+` lines come, the unmarked lines are context.

## Step 3a -- CUE sheets, files, TOC, data (13.8)

### Task 1: CUE parser, disc model, LBA layout (`cue.c`)

**Files:**
- Create: `fw/ctrl_832/cue.h`, `fw/ctrl_832/cue.c`
- Create: `fw/ctrl_832/test/cue_test.c`, `fw/ctrl_832/test/emu/cue_emu.c`
- Modify: `fw/ctrl_832/test/Makefile` (cue_test target, run line), `fw/ctrl_832/test/.gitignore`
- Modify: `fw/ctrl_832/test/emu/Makefile` (whole file: several programs, `832e_fix` with `mul`, `timeout 60`), `fw/ctrl_832/test/emu/.gitignore`

**Interfaces:**
- Consumes: nothing new (`memset` from lib832).
- Produces (cue.h): `CD_MAX_TRACKS` 99, `CD_MAX_FILES` 99, `CUE_LINE_MAX` 300, `CD_DATA2048` 1, `CD_DATA2352` 2, `CD_AUDIO` 3, `CD_FRAMES_PER_SECTOR` 588; `struct cd_track` (exactly 13.4's fields), `struct cd_file` (13.4), `struct cd_disc { int32_t tracks, files; uint32_t leadout; struct cd_track track[99]; struct cd_file file[99]; }`; errors `CUE_OK` 0 .. `CUE_E_READ` 16; `typedef int32_t (*cue_open_fn)(void *ctx, const char *name, struct cd_file *f)`; `struct cue_parser`; `void cue_begin(struct cue_parser *, struct cd_disc *, cue_open_fn, void *ctx)`, `int32_t cue_feed(struct cue_parser *, const char *text, uint32_t len)`, `int32_t cue_end(struct cue_parser *)`, `void cue_message(const struct cue_parser *, char buf[24])`, `void cue_single(struct cd_disc *, const char *shortname, uint32_t bytes)`, `struct cue_loc { int32_t track, index, silent, file; uint32_t offset, run; }`, `int32_t cue_locate(const struct cd_disc *, uint32_t lba, struct cue_loc *)`, `uint32_t cue_sector_size(int32_t type)`.
- Produces (emu harness): `PROGS`, `UNIT_ASM` lists in `test/emu/Makefile`; later tasks add `cdaudio`.

- [ ] **Step 1: Write the failing tests**

Create `fw/ctrl_832/test/cue_test.c`:

```c
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
```

Host Makefile and ignore list:

```diff
--- a/fw/ctrl_832/test/Makefile
+++ b/fw/ctrl_832/test/Makefile
@@ -1,6 +1,7 @@
 # Host tests for the CD-ROM (findings/cdrom/plan.md): atapi_test, the ATAPI
 # command layer (task 0.1); cdrom_test, the board glue against a model of
-# the Gayle port and an ATAPI host (task 1.4).
+# the Gayle port and an ATAPI host (task 1.4); cue_test, the CUE parser and
+# disc model (phase 3, findings/cdrom/phase3-plan.md task 1).
 #   make -C fw/ctrl_832/test            build and run both (exit status = result)
 #   make -C fw/ctrl_832/test ISO=<path> use another ISO for the ISO-backed cases
 # Without the ISO those cases are skipped, not failed.
@@ -15,14 +16,18 @@
 atapi_test: atapi_test.c ../atapi.c ../atapi.h
 	$(HOSTCC) $(CFLAGS) -o $@ atapi_test.c ../atapi.c
 
+cue_test: cue_test.c ../cue.c ../cue.h
+	$(HOSTCC) $(CFLAGS) -o $@ cue_test.c ../cue.c
+
 cdrom_test: cdrom_test.c ../cdrom.c ../cdrom.h ../atapi.c ../atapi.h ../hdd.h
 	$(HOSTCC) $(CFLAGS) -o $@ cdrom_test.c ../cdrom.c ../atapi.c
 
-run: atapi_test cdrom_test
+run: cue_test atapi_test cdrom_test
+	./cue_test
 	./atapi_test "$(ISO)"
 	./cdrom_test
 
 clean:
-	rm -f atapi_test cdrom_test
+	rm -f cue_test atapi_test cdrom_test
 
 .PHONY: all run clean
--- a/fw/ctrl_832/test/.gitignore
+++ b/fw/ctrl_832/test/.gitignore
@@ -1,2 +1,3 @@
 atapi_test
 cdrom_test
+cue_test
```

The emu harness: several programs, a patched 832e (`ldt` flags as before, plus the missing `mul`), every program under `timeout 60` (a vbcc832 miscompile that never returns must fail, not hang the make):

```diff
--- a/fw/ctrl_832/test/emu/Makefile
+++ b/fw/ctrl_832/test/emu/Makefile
@@ -1,48 +1,67 @@
-# atapi_emu: atapi.c built by vbcc832 and run in 832e, the EightThirtyTwo
-# emulator (see atapi_emu.c).  Little-endian: 832e's big-endian mode mixes
-# swapped (stmpdec) and raw (stbinc) byte writes; the size bug this test is
-# for shows either way (a 32-bit store clobbers the bytes after a uint8_t).
-# Exit status 0 = PASS.
+# Firmware units built by vbcc832 and run in 832e, the EightThirtyTwo
+# emulator: atapi_emu (atapi.c), cue_emu (cue.c).  Little-endian: 832e's
+# big-endian mode mixes swapped (stmpdec) and raw (stbinc) byte writes; the
+# size bug these tests are for shows either way (a 32-bit store clobbers
+# the bytes after a uint8_t).  Exit status 0 = every program printed PASS.
 
 832DIR ?= ../../../../EightThirtyTwo
 CC      = $(832DIR)/vbcc/bin/vbcc832
 AS      = $(832DIR)/832a/832a
 LD      = $(832DIR)/832a/832l
-# 832e as of EightThirtyTwo d1cd671 does not set the Z/C flags on ldt, which
-# every other load and the CPU (RTL/eightthirtytwo_cpu.vhd: any load sets Z
-# and C) do; vbcc832 tests "if (u->ua_asc)" with byt ldt + cond.  The test
-# builds its own copy with that one line added (832e_ldt).
-EMU     = ./832e_ldt
+# 832e as of EightThirtyTwo d1cd671 differs from the CPU in two places the
+# tests reach, and the tests build their own copy with both fixed (832e_fix):
+#  - it does not set the Z/C flags on ldt, which every other load and the CPU
+#    (RTL/eightthirtytwo_cpu.vhd: any load sets Z and C) do; vbcc832 tests
+#    "if (u->ua_asc)" with byt ldt + cond.
+#  - it has no mul at all (opc_mul 0x90 is decoded as nothing, so "n * 10"
+#    leaves n unchanged); README.md: mul r<n> = 32x32 -> 64, low half to
+#    r<n>, high half to tmp, signed when sgn is set.
+EMU     = ./832e_fix
 EMUSRC  = $(832DIR)/832emu
 LIBDIR  = $(832DIR)/lib832
 # the firmware's code generator options (fw/ctrl_832/Makefile)
 CFLAGS  = -+ -c99 -O=1343 -unsigned-char -D__geta4= -DNULL=0 -I../.. -I$(832DIR)/include/ -I$(LIBDIR)
 
+PROGS    = atapi_emu cue_emu
+UNIT_ASM = atapi.asm cue.asm
+TEST_ASM = $(PROGS:=.asm)
+
 all: run
 
-atapi.asm: ../../atapi.c ../../atapi.h
-	$(CC) $(CFLAGS) -o=$@ ../../atapi.c
+$(UNIT_ASM): %.asm: ../../%.c
+	$(CC) $(CFLAGS) -o=$@ $<
+
+$(TEST_ASM): %.asm: %.c
+	$(CC) $(CFLAGS) -o=$@ $<
 
-atapi_emu.asm: atapi_emu.c ../../atapi.h
-	$(CC) $(CFLAGS) -o=$@ atapi_emu.c
+atapi.asm: ../../atapi.h
+cue.asm: ../../cue.h
+atapi_emu.asm: ../../atapi.h
+cue_emu.asm: ../../cue.h
 
 %.o: %.asm
 	$(AS) -o $@ $<
 
-832e_ldt: $(EMUSRC)/832e.cpp
+832e_fix: $(EMUSRC)/832e.cpp
 	rm -rf emusrc && cp -r $(EMUSRC) emusrc && rm -rf emusrc/.obj emusrc/832e
 	sed -i 's|^\(\t*\)temp=prg.Read(temp,endian,sizemod);$$|&\n\1zero=(temp==0);\n\1carry=(temp\&0x80000000)!=0;|' emusrc/832e.cpp
 	grep -A2 'temp=prg.Read(temp,endian,sizemod);' emusrc/832e.cpp | grep -q 'zero=(temp==0);'
+	sed -i '0,/^\(\t*\)case opc_add: \/\/ add$$/s//\1case opc_mul: \/\/ mul\n\1\tif(sign_mod) t2=(long long)(int)regfile[operand]*(long long)(int)temp;\n\1\telse t2=(long long)((unsigned long long)regfile[operand]*(unsigned long long)temp);\n\1\tregfile[operand]=(unsigned int)t2;\n\1\ttemp=(unsigned int)((unsigned long long)t2>>32);\n\1\tzero=regfile[operand]==0;\n\1\tcarry=0;\n\1\tsign_mod=false;\n\1\tmnem << ("mul ") << operand;\n\1\tbreak;\n\n&/' emusrc/832e.cpp
+	grep -q 'case opc_mul: // mul' emusrc/832e.cpp
 	$(MAKE) -C emusrc
 	cp emusrc/832e $@
 
 atapi_emu: atapi_emu.o atapi.o
-	$(LD) -o $@ $(LIBDIR)/crt0.a $(LIBDIR)/lib832.a atapi_emu.o atapi.o
+	$(LD) -o $@ $(LIBDIR)/crt0.a $(LIBDIR)/lib832.a $^
+
+cue_emu: cue_emu.o cue.o
+	$(LD) -o $@ $(LIBDIR)/crt0.a $(LIBDIR)/lib832.a $^
 
-run: atapi_emu 832e_ldt
-	$(EMU) atapi_emu | tee atapi_emu.log; ! grep -q "^FAIL" atapi_emu.log && grep -qx PASS atapi_emu.log
+run: $(PROGS) 832e_fix
+	timeout 60 $(EMU) atapi_emu | tee atapi_emu.log; ! grep -q "^FAIL" atapi_emu.log && grep -qx PASS atapi_emu.log
+	timeout 60 $(EMU) cue_emu | tee cue_emu.log; ! grep -q "^FAIL" cue_emu.log && grep -qx PASS cue_emu.log
 
 clean:
-	rm -rf *.asm *.o atapi_emu atapi_emu.log 832e_ldt emusrc
+	rm -rf *.asm *.o $(PROGS) *.log 832e_fix emusrc
 
 .PHONY: all run clean
--- a/fw/ctrl_832/test/emu/.gitignore
+++ b/fw/ctrl_832/test/emu/.gitignore
@@ -1,7 +1,7 @@
 # built by make (see Makefile)
 *.asm
 *.o
-atapi_emu
-atapi_emu.log
-832e_ldt
+*_emu
+*_emu.log
+832e_fix
 emusrc/
```

Create `fw/ctrl_832/test/emu/cue_emu.c`:

```c
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
```

- [ ] **Step 2: Run, expected FAIL**

```bash
make -C fw/ctrl_832/test
```

Expected:

```
make: *** No rule to make target '../cue.c', needed by 'cue_test'.  Stop.
```

- [ ] **Step 3: Implementation**

Create `fw/ctrl_832/cue.h`:

```c
#ifndef CUE_H
#define CUE_H

/*
 * CD disc model and CUE sheet parser (findings/cdrom/plan.md 13.4).
 *
 * Pure C, no hardware or SD access: the caller feeds the CUE text in any
 * chunks and opens each FILE through a callback (cdrom.c on the board, a
 * table in the tests).  Builds for the 832 (vbcc832) and the host
 * (fw/ctrl_832/test/cue_test.c, test/emu/cue_emu.c).
 *
 * vbcc832 rule (12.6): a field that is set and then returned with the same
 * constant ("p->error = E; return E;") must be 32 bits wide -- vbcc832
 * stores it with a 32-bit store whatever its type.  The parser's result
 * fields are int32_t for that reason; the disc model's narrow fields are
 * never set that way, and test/emu/cue_emu.c checks every one of them.
 */

#include <stdint.h>

#define CD_MAX_TRACKS 99
#define CD_MAX_FILES  99
#define CUE_LINE_MAX  300	/* FILE "<255 characters>" BINARY fits */

/* track types */
#define CD_DATA2048 1	/* 2048 bytes of file per sector (ISO, MODE1/2048) */
#define CD_DATA2352 2	/* raw MODE1/2352: user data at byte 16 */
#define CD_AUDIO    3	/* 2352 bytes = 588 stereo frames of 16-bit LE PCM */

#define CD_FRAMES_PER_SECTOR 588

struct cd_track {		/* one per TRACK, up to 99; track[i].number == i + 1 */
	uint8_t  number;
	uint8_t  type;		/* CD_DATA2048, CD_DATA2352, CD_AUDIO */
	uint8_t  file;		/* index into file[] */
	uint32_t file_offset;	/* bytes into the file where INDEX 01 starts */
	uint32_t lba;		/* disc address of INDEX 01 */
	uint32_t sectors;	/* to the next track's INDEX 01 in the same file / end of file */
	uint32_t pregap_lba;	/* first sector of its gap (INDEX 00 or PREGAP), == lba if none */
	uint8_t  pregap_silent;	/* gap not in the file (PREGAP) */
};

struct cd_file {
	char     shortname[12];	/* 8.3 name as FileOpen wants it (11 characters, no dot) + NUL */
	uint8_t  wave;		/* FILE ... WAVE */
	uint32_t data_offset;	/* WAVE: first byte of the data chunk; BINARY: 0 */
	uint32_t data_bytes;	/* WAVE: data chunk size; BINARY: file size */
};

struct cd_disc {
	int32_t  tracks;
	int32_t  files;
	uint32_t leadout;	/* LBA of the lead-out = disc size in sectors */
	struct cd_track track[CD_MAX_TRACKS];
	struct cd_file  file[CD_MAX_FILES];
};

/* Errors: the parser's result and cue_message()'s text */
#define CUE_OK          0
#define CUE_E_SYNTAX    1	/* "syntax" */
#define CUE_E_UNKNOWN   2	/* "unknown cmd": a command we do not know is refused */
#define CUE_E_LINE      3	/* "line too long" */
#define CUE_E_FILETYPE  4	/* "file type": FILE type other than BINARY / WAVE */
#define CUE_E_MODE      5	/* "track mode": MODE2, CDG, CDI, MODE1/2336 */
#define CUE_E_TOOMANY   6	/* "too many": more than 99 tracks or files */
#define CUE_E_ORDER     7	/* "track order": TRACK numbers not 1, 2, 3 ... */
#define CUE_E_INDEX     8	/* "bad INDEX": INDEX 02+, 00 after 01, twice, missing 01, going back */
#define CUE_E_GAP       9	/* "PREGAP+INDEX0": both on one track */
#define CUE_E_SESSION  10	/* "2nd session": REM SESSION 02 or later */
#define CUE_E_NOFILE   11	/* "file missing" */
#define CUE_E_WAV      12	/* "WAV format": not PCM 44.1 kHz 16-bit stereo, or no data chunk */
#define CUE_E_MIXED    13	/* "sector sizes": 2048 and 2352 in one FILE, or data in a WAVE */
#define CUE_E_END      14	/* "past file end": INDEX 01 beyond the end of its FILE */
#define CUE_E_EMPTY    15	/* "no tracks" */
#define CUE_E_READ     16	/* "read error": the glue could not read the CUE */

/* Open the FILE named name (as written in the CUE, quotes removed) for f:
   f->wave is set before the call; fill f->shortname, f->data_offset and
   f->data_bytes.  Return CUE_OK, CUE_E_NOFILE or CUE_E_WAV. */
typedef int32_t (*cue_open_fn)(void *ctx, const char *name, struct cd_file *f);

struct cue_parser {
	struct cd_disc *disc;
	cue_open_fn     open;
	void           *ctx;
	int32_t  error;		/* CUE_OK or the first error */
	int32_t  error_line;	/* its line (1 = first), 0 = not tied to a line */
	int32_t  line;		/* number of the line being collected */
	int32_t  len;		/* characters in buf */
	int32_t  overflow;	/* the line is longer than CUE_LINE_MAX */
	int32_t  cur_file;	/* last FILE, -1 = none yet */
	int32_t  idx0[CD_MAX_TRACKS];	/* INDEX 00 in sectors of its file, -1 = none */
	int32_t  idx1[CD_MAX_TRACKS];	/* INDEX 01, -1 = none yet */
	int32_t  pregap[CD_MAX_TRACKS];	/* PREGAP sectors */
	int32_t  postgap[CD_MAX_TRACKS];	/* POSTGAP sectors */
	int32_t  tline[CD_MAX_TRACKS];	/* line of each TRACK */
	char     buf[CUE_LINE_MAX + 1];
};

/* Start parsing into d (cleared).  open is called once per FILE line. */
void cue_begin(struct cue_parser *p, struct cd_disc *d, cue_open_fn open, void *ctx);

/* The next len bytes of the CUE text, cut anywhere.  CRLF or LF.
   Returns p->error (parsing stops at the first error). */
int32_t cue_feed(struct cue_parser *p, const char *text, uint32_t len);

/* End of the text: the last line, the checks and the LBA layout (13.4).
   Returns CUE_OK or the first error; on CUE_OK d is a complete disc. */
int32_t cue_end(struct cue_parser *p);

/* "line N: <cause>" (or "<cause>"), at most 23 characters: buf[24]. */
void cue_message(const struct cue_parser *p, char *buf);

/* An ISO: one DATA2048 track over the whole file (bytes / 2048 sectors). */
void cue_single(struct cd_disc *d, const char *shortname, uint32_t bytes);

/* Where disc sector lba lives. */
struct cue_loc {
	int32_t  track;		/* index into track[] */
	int32_t  index;		/* 0 = in the gap before INDEX 01, 1 = from INDEX 01 on */
	int32_t  silent;	/* no file bytes: PREGAP or POSTGAP */
	int32_t  file;		/* index into file[] when !silent */
	uint32_t offset;	/* when !silent: byte offset in the file of the sector's first byte */
	uint32_t run;		/* sectors from lba on with the same track, index, silent and contiguous bytes */
};

/* 1 and *loc filled, or 0 when lba is at or past the lead-out. */
int32_t cue_locate(const struct cd_disc *d, uint32_t lba, struct cue_loc *loc);

/* Bytes of file per sector of a track type: 2048 or 2352. */
uint32_t cue_sector_size(int32_t type);

#endif
```

Create `fw/ctrl_832/cue.c`:

```c
/*
 * CD disc model and CUE sheet parser -- see cue.h and
 * findings/cdrom/plan.md 13.4.
 *
 * No library call but memset, no malloc, nothing big on the stack.
 */

#include <string.h>
#include "cue.h"

static const char *const cue_text[] = {
	"ok", "syntax", "unknown cmd", "line too long", "file type", "track mode",
	"too many", "track order", "bad INDEX", "PREGAP+INDEX0", "2nd session",
	"file missing", "WAV format", "sector sizes", "past file end", "no tracks",
	"read error"
};

uint32_t cue_sector_size(int32_t type)
{
	return type == CD_DATA2048 ? 2048 : 2352;
}

static int32_t fail_at(struct cue_parser *p, int32_t e, int32_t line)
{
	p->error = e;
	p->error_line = line;
	return e;
}

static int32_t fail(struct cue_parser *p, int32_t e)
{
	return fail_at(p, e, p->line);
}

/* Keyword match, any case.  Loops here and below are written
   "for (;;) { c = s[i]; if (stop) break; i++; }": vbcc832 -O=1343 drops
   the increment of "while (*s && *s != ' ') s++;" (the loop never ends;
   test/emu/cue_emu.c hung on it). */
static int32_t kw(const char *s, const char *k)
{
	int32_t i = 0;
	for (;;) {
		char c = s[i], w = k[i];
		if (!w)
			return c == 0;
		if (c >= 'a' && c <= 'z')
			c = (char)(c - 32);
		if (c != w)
			return 0;
		i++;
	}
}

/* Decimal, 1 to 6 digits, up to the end of s. */
static int32_t num(const char *s, int32_t *v)
{
	int32_t n = 0, i = 0;
	for (;;) {
		char c = s[i];
		if (c < '0' || c > '9')
			break;
		if (i == 6)
			return 0;
		n = n * 10 + (c - '0');
		i++;
	}
	if (!i || s[i])
		return 0;
	*v = n;
	return 1;
}

/* Index of the next ':' in s (cut there), -1 if none. */
static int32_t cut_colon(char *s)
{
	int32_t i = 0;
	for (;;) {
		char c = s[i];
		if (!c)
			return -1;
		if (c == ':') {
			s[i] = 0;
			return i;
		}
		i++;
	}
}

/* mm:ss:ff -> sectors (75 per second). */
static int32_t msf(char *s, int32_t *v)
{
	int32_t m, sec, f, a, b;
	a = cut_colon(s);
	if (a < 0)
		return 0;
	b = cut_colon(s + a + 1);
	if (b < 0)
		return 0;
	if (!num(s, &m) || !num(s + a + 1, &sec) || !num(s + a + b + 2, &f) || sec > 59 || f > 74)
		return 0;
	*v = (m * 60 + sec) * 75 + f;
	return 1;
}

void cue_begin(struct cue_parser *p, struct cd_disc *d, cue_open_fn open, void *ctx)
{
	memset(p, 0, sizeof(*p));
	memset(d, 0, sizeof(*d));
	p->disc = d;
	p->open = open;
	p->ctx = ctx;
	p->line = 1;
	p->cur_file = -1;
}

static int32_t do_file(struct cue_parser *p, char **tok, int32_t n)
{
	struct cd_disc *d = p->disc;
	struct cd_file *f;
	int32_t wave, r;
	if (n != 3)
		return fail(p, CUE_E_SYNTAX);
	if (kw(tok[2], "BINARY"))
		wave = 0;
	else if (kw(tok[2], "WAVE"))
		wave = 1;
	else
		return fail(p, CUE_E_FILETYPE);
	if (d->files >= CD_MAX_FILES)
		return fail(p, CUE_E_TOOMANY);
	f = &d->file[d->files];
	memset(f, 0, sizeof(*f));
	f->wave = (uint8_t)wave;
	r = p->open(p->ctx, tok[1], f);
	if (r != CUE_OK)
		return fail(p, r);
	p->cur_file = d->files;
	d->files++;
	return CUE_OK;
}

static int32_t do_track(struct cue_parser *p, char **tok, int32_t n)
{
	struct cd_disc *d = p->disc;
	struct cd_track *t;
	int32_t i = d->tracks, v, type;
	if (n != 3 || p->cur_file < 0 || !num(tok[1], &v))
		return fail(p, CUE_E_SYNTAX);
	if (i >= CD_MAX_TRACKS)
		return fail(p, CUE_E_TOOMANY);
	if (v != i + 1)
		return fail(p, CUE_E_ORDER);
	if (kw(tok[2], "MODE1/2048"))
		type = CD_DATA2048;
	else if (kw(tok[2], "MODE1/2352"))
		type = CD_DATA2352;
	else if (kw(tok[2], "AUDIO"))
		type = CD_AUDIO;
	else
		return fail(p, CUE_E_MODE);
	if (d->file[p->cur_file].wave && type != CD_AUDIO)
		return fail(p, CUE_E_MIXED);
	if (i && d->track[i - 1].file == p->cur_file &&
	    cue_sector_size(d->track[i - 1].type) != cue_sector_size(type))
		return fail(p, CUE_E_MIXED);
	t = &d->track[i];
	t->number = (uint8_t)v;
	t->type = (uint8_t)type;
	t->file = (uint8_t)p->cur_file;
	p->idx0[i] = -1;
	p->idx1[i] = -1;
	p->pregap[i] = 0;
	p->postgap[i] = 0;
	p->tline[i] = p->line;
	d->tracks++;
	return CUE_OK;
}

static int32_t do_index(struct cue_parser *p, char **tok, int32_t n)
{
	struct cd_disc *d = p->disc;
	int32_t t = d->tracks - 1, i, fr;
	if (n != 3 || t < 0 || !num(tok[1], &i) || !msf(tok[2], &fr))
		return fail(p, CUE_E_SYNTAX);
	if (d->track[t].file != p->cur_file)	/* INDEX in a later FILE than its TRACK */
		return fail(p, CUE_E_INDEX);
	if (i == 0) {
		if (p->idx0[t] >= 0 || p->idx1[t] >= 0)
			return fail(p, CUE_E_INDEX);
		if (p->pregap[t])
			return fail(p, CUE_E_GAP);
		p->idx0[t] = fr;
	} else if (i == 1) {
		if (p->idx1[t] >= 0 || (p->idx0[t] >= 0 && fr < p->idx0[t]))
			return fail(p, CUE_E_INDEX);
		p->idx1[t] = fr;
	} else {
		return fail(p, CUE_E_INDEX);
	}
	return CUE_OK;
}

static int32_t do_gap(struct cue_parser *p, char **tok, int32_t n, int32_t post)
{
	int32_t t = p->disc->tracks - 1, fr;
	if (n != 2 || t < 0 || !msf(tok[1], &fr))
		return fail(p, CUE_E_SYNTAX);
	if (post) {
		p->postgap[t] = fr;
	} else {
		if (p->idx0[t] >= 0)
			return fail(p, CUE_E_GAP);
		p->pregap[t] = fr;
	}
	return CUE_OK;
}

static int32_t is_blank(char c)
{
	return c == ' ' || c == '\t' || c == '\r';
}

static int32_t do_line(struct cue_parser *p)
{
	char *tok[5];
	char *b = p->buf;
	int32_t n = 0, i = 0, v;

	if (p->line == 1 && (uint8_t)b[0] == 0xEF && (uint8_t)b[1] == 0xBB && (uint8_t)b[2] == 0xBF)
		i = 3;	/* UTF-8 byte order mark */
	while (n < 5) {
		char c;
		for (;;) {
			c = b[i];
			if (!is_blank(c))
				break;
			i++;
		}
		if (!c)
			break;
		if (c == '"') {
			i++;
			tok[n++] = b + i;
			for (;;) {
				c = b[i];
				if (!c || c == '"')
					break;
				i++;
			}
			if (!c)
				return fail(p, CUE_E_SYNTAX);
			b[i++] = 0;
		} else {
			tok[n++] = b + i;
			for (;;) {
				c = b[i];
				if (!c || is_blank(c))
					break;
				i++;
			}
			if (c)
				b[i++] = 0;
		}
	}
	if (!n)
		return CUE_OK;
	if (kw(tok[0], "REM")) {
		if (n >= 3 && kw(tok[1], "SESSION")) {
			if (!num(tok[2], &v))
				return fail(p, CUE_E_SYNTAX);
			if (v > 1)
				return fail(p, CUE_E_SESSION);
		}
		return CUE_OK;
	}
	if (kw(tok[0], "CATALOG") || kw(tok[0], "TITLE") || kw(tok[0], "PERFORMER") ||
	    kw(tok[0], "SONGWRITER") || kw(tok[0], "FLAGS") || kw(tok[0], "ISRC") ||
	    kw(tok[0], "CDTEXTFILE"))
		return CUE_OK;
	if (kw(tok[0], "FILE"))
		return do_file(p, tok, n);
	if (kw(tok[0], "TRACK"))
		return do_track(p, tok, n);
	if (kw(tok[0], "INDEX"))
		return do_index(p, tok, n);
	if (kw(tok[0], "PREGAP"))
		return do_gap(p, tok, n, 0);
	if (kw(tok[0], "POSTGAP"))
		return do_gap(p, tok, n, 1);
	return fail(p, CUE_E_UNKNOWN);
}

static int32_t end_line(struct cue_parser *p)
{
	int32_t r = CUE_OK;
	if (p->overflow)
		r = fail(p, CUE_E_LINE);
	else {
		p->buf[p->len] = 0;
		r = do_line(p);
	}
	p->len = 0;
	p->overflow = 0;
	p->line++;
	return r;
}

int32_t cue_feed(struct cue_parser *p, const char *text, uint32_t len)
{
	uint32_t i;
	for (i = 0; i < len && p->error == CUE_OK; i++) {
		char c = text[i];
		if (c == '\n')
			end_line(p);
		else if (p->len < CUE_LINE_MAX)
			p->buf[p->len++] = c;
		else
			p->overflow = 1;
	}
	return p->error;
}

/* Sectors of a file: a partial last sector counts for audio (padded with
   silence), not for data (12.2: the ISO's tail is ignored). */
static uint32_t file_sectors(const struct cd_disc *d, int32_t file)
{
	int32_t i, type = CD_DATA2048;
	uint32_t bytes = d->file[file].data_bytes, size;
	for (i = 0; i < d->tracks; i++)
		if (d->track[i].file == file)
			type = d->track[i].type;
	size = cue_sector_size(type);
	return bytes / size + ((type == CD_AUDIO && bytes % size) ? 1 : 0);
}

static int32_t layout(struct cue_parser *p)
{
	struct cd_disc *d = p->disc;
	int32_t i, base = 0, end = 0;

	if (!d->tracks)
		return fail_at(p, CUE_E_EMPTY, 0);
	for (i = 0; i < d->tracks; i++) {
		struct cd_track *t = &d->track[i];
		int32_t first = i == 0 || d->track[i - 1].file != t->file;
		int32_t last = i + 1 == d->tracks || d->track[i + 1].file != t->file;
		int32_t fsec = (int32_t)file_sectors(d, t->file);
		int32_t i1 = p->idx1[i];

		if (i1 < 0)
			return fail_at(p, CUE_E_INDEX, p->tline[i]);
		if (first) {
			base = i == 0 ? -i1 : end + p->pregap[i];	/* track 1 INDEX 01 is LBA 0 */
		} else {
			if (i1 <= p->idx1[i - 1] || (p->idx0[i] >= 0 && p->idx0[i] < p->idx1[i - 1]))
				return fail_at(p, CUE_E_INDEX, p->tline[i]);
			base += p->postgap[i - 1] + p->pregap[i];
		}
		if (i1 >= fsec)
			return fail_at(p, CUE_E_END, p->tline[i]);
		t->lba = (uint32_t)(base + i1);
		t->file_offset = d->file[t->file].data_offset + (uint32_t)i1 * cue_sector_size(t->type);
		t->pregap_silent = 0;
		if (i == 0)
			t->pregap_lba = 0;
		else if (p->pregap[i]) {
			t->pregap_lba = t->lba - (uint32_t)p->pregap[i];
			t->pregap_silent = 1;
		} else if (p->idx0[i] >= 0)
			t->pregap_lba = (uint32_t)(base + p->idx0[i]);
		else if (first)
			t->pregap_lba = (uint32_t)base;	/* file bytes before INDEX 01: an implicit INDEX 00 at 0 */
		else
			t->pregap_lba = t->lba;
		t->sectors = (uint32_t)(last ? fsec - i1 : p->idx1[i + 1] - i1);
		if (last)
			end = base + fsec + p->postgap[i];
	}
	d->leadout = (uint32_t)end;
	return CUE_OK;
}

int32_t cue_end(struct cue_parser *p)
{
	if (p->error == CUE_OK && (p->len || p->overflow))
		end_line(p);	/* no newline after the last line */
	if (p->error != CUE_OK)
		return p->error;
	return layout(p);
}

void cue_message(const struct cue_parser *p, char *buf)
{
	const char *t = cue_text[(p->error >= 0 && p->error <= CUE_E_READ) ? p->error : CUE_E_SYNTAX];
	char digits[8];
	int32_t n = 0, v = p->error_line, k = 0, i = 0;
	if (v > 0) {
		buf[0] = 'l';
		buf[1] = 'i';
		buf[2] = 'n';
		buf[3] = 'e';
		buf[4] = ' ';
		n = 5;
		if (v > 9999)
			v = 9999;
		while (v) {
			digits[k++] = (char)('0' + v % 10);
			v /= 10;
		}
		while (k)
			buf[n++] = digits[--k];
		buf[n++] = ':';
		buf[n++] = ' ';
	}
	for (;;) {
		char c = t[i];
		if (!c || n == 23)
			break;
		buf[n++] = c;
		i++;
	}
	buf[n] = 0;
}

void cue_single(struct cd_disc *d, const char *shortname, uint32_t bytes)
{
	int32_t i;
	memset(d, 0, sizeof(*d));
	for (i = 0; i < 11 && shortname[i]; i++)
		d->file[0].shortname[i] = shortname[i];
	d->file[0].data_bytes = bytes;
	d->files = 1;
	d->track[0].number = 1;
	d->track[0].type = CD_DATA2048;
	d->track[0].sectors = bytes / 2048;
	d->tracks = 1;
	d->leadout = bytes / 2048;
}

int32_t cue_locate(const struct cd_disc *d, uint32_t lba, struct cue_loc *loc)
{
	int32_t i;
	const struct cd_track *t;
	uint32_t end, size;
	if (lba >= d->leadout || !d->tracks)
		return 0;
	i = d->tracks - 1;
	for (;;) {
		if (i == 0 || d->track[i].pregap_lba <= lba)
			break;
		i--;
	}
	t = &d->track[i];
	end = i + 1 < d->tracks ? d->track[i + 1].pregap_lba : d->leadout;
	size = cue_sector_size(t->type);
	loc->track = i;
	loc->file = t->file;
	loc->silent = 0;
	loc->offset = 0;
	if (lba < t->lba) {
		loc->index = 0;
		loc->run = t->lba - lba;
		if (t->pregap_silent)
			loc->silent = 1;
		else
			loc->offset = t->file_offset - (t->lba - lba) * size;
	} else {
		loc->index = 1;
		if (lba - t->lba < t->sectors) {
			uint32_t stop = t->lba + t->sectors;
			loc->offset = t->file_offset + (lba - t->lba) * size;
			loc->run = (stop < end ? stop : end) - lba;
		} else {
			loc->silent = 1;	/* POSTGAP */
			loc->run = end - lba;
		}
	}
	return 1;
}
```

- [ ] **Step 4: Run, expected PASS**

```bash
make -C fw/ctrl_832/test
make -C fw/ctrl_832/test/emu 832DIR=/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64/EightThirtyTwo
```

Expected (host): `10 cases: 10 passed, 0 failed (0 failed checks)` (cue_test), `18 cases: 18 passed, 0 failed, 0 skipped` (atapi_test), `20 cases: 20 passed, 0 failed` (cdrom_test).  Emu: the first run builds `832e_fix` (a minute or two), then `atapi_emu` and `cue_emu` each end with a line `PASS` and make exits 0.  If `cue_emu` times out, a loop in cue.c is in the form vbcc832 miscompiles (Global Constraints).

- [ ] **Step 5: Commit**

```bash
git add fw/ctrl_832/cue.h fw/ctrl_832/cue.c fw/ctrl_832/test/cue_test.c fw/ctrl_832/test/Makefile \
        fw/ctrl_832/test/.gitignore fw/ctrl_832/test/emu/cue_emu.c fw/ctrl_832/test/emu/Makefile \
        fw/ctrl_832/test/emu/.gitignore
git commit -F- <<'EOF'
fw/ctrl_832: CUE parser and CD disc model (cue.c), host and 832e tests

findings/cdrom/plan.md 13.4: CUE text -> disc model and LBA layout,
cue_locate (sector -> track, index, file offset), cue_single for an ISO.
Every refusal names its line.  test/emu runs every program under a
timeout and patches the missing mul into 832e (832e_fix).

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
EOF
```

### Task 2: WAV header walk (`cue_wav`)

**Files:**
- Modify: `fw/ctrl_832/cue.h` (`cue_read_fn`, `cue_wav`), `fw/ctrl_832/cue.c` (append `le16`, `le32`, `id4`, `cue_wav`; header comment)
- Test: `fw/ctrl_832/test/cue_test.c` (`t_wav`), `fw/ctrl_832/test/emu/cue_emu.c` (WAV block)

**Interfaces:**
- Consumes: `struct cd_file`, `CUE_OK`, `CUE_E_WAV` (task 1).
- Produces: `typedef int32_t (*cue_read_fn)(void *ctx, uint32_t offset, uint8_t *dst, uint32_t len)` (1 = all read); `int32_t cue_wav(cue_read_fn read, void *ctx, uint32_t size, struct cd_file *f)` -- fills `f->data_offset`, `f->data_bytes` (clipped to the file), returns `CUE_OK` or `CUE_E_WAV`.  Task 4's `cd_cue_open` calls it.

- [ ] **Step 1: Write the failing tests**

```diff
--- a/fw/ctrl_832/test/cue_test.c
+++ b/fw/ctrl_832/test/cue_test.c
@@ -423,6 +423,99 @@
 	end();
 }
 
+/* ---- WAV headers ---- */
+
+static uint8_t wav[512];
+static uint32_t wav_size;
+
+static int32_t mem_read(void *ctx, uint32_t offset, uint8_t *dst, uint32_t len)
+{
+	(void)ctx;
+	if (offset > wav_size || len > wav_size - offset)
+		return 0;
+	memcpy(dst, wav + offset, len);
+	return 1;
+}
+
+static void put_le(uint8_t *p, uint32_t v, int n)
+{
+	int i;
+	for (i = 0; i < n; i++)
+		p[i] = (uint8_t)(v >> (8 * i));
+}
+
+/* A WAV: RIFF header, optional LIST chunk (odd size, padded), fmt, data. */
+static void make_wav(uint16_t format, uint16_t channels, uint32_t rate, uint16_t bits, uint32_t data_len, int list, int data_first)
+{
+	uint32_t p = 12;
+	memset(wav, 0, sizeof(wav));
+	memcpy(wav, "RIFF", 4);
+	memcpy(wav + 8, "WAVE", 4);
+	if (list) {
+		memcpy(wav + p, "LIST", 4);
+		put_le(wav + p + 4, 5, 4);
+		p += 8 + 6;	/* 5 bytes + pad */
+	}
+	if (data_first) {
+		memcpy(wav + p, "data", 4);
+		put_le(wav + p + 4, 8, 4);
+		p += 16;
+	}
+	memcpy(wav + p, "fmt ", 4);
+	put_le(wav + p + 4, 16, 4);
+	put_le(wav + p + 8, format, 2);
+	put_le(wav + p + 10, channels, 2);
+	put_le(wav + p + 12, rate, 4);
+	put_le(wav + p + 16, rate * channels * bits / 8, 4);
+	put_le(wav + p + 20, channels * bits / 8, 2);
+	put_le(wav + p + 22, bits, 2);
+	p += 24;
+	if (!data_first) {
+		memcpy(wav + p, "data", 4);
+		put_le(wav + p + 4, data_len, 4);
+		p += 8;
+	}
+	wav_size = p + 200;	/* 200 bytes of samples follow */
+	put_le(wav + 4, wav_size - 8, 4);
+}
+
+static void t_wav(void)
+{
+	struct cd_file f;
+	begin("cue_wav: RIFF chunk walk; PCM 44.1 kHz 16-bit stereo only");
+	make_wav(1, 2, 44100, 16, 200, 0, 0);
+	memset(&f, 0, sizeof(f));
+	EXPECT(cue_wav(mem_read, 0, wav_size, &f) == CUE_OK && f.data_offset == 44 && f.data_bytes == 200,
+	       "plain: offset %u bytes %u", f.data_offset, f.data_bytes);
+	make_wav(1, 2, 44100, 16, 200, 1, 0);
+	EXPECT(cue_wav(mem_read, 0, wav_size, &f) == CUE_OK && f.data_offset == 44 + 14 && f.data_bytes == 200,
+	       "LIST first (odd size, padded): offset %u", f.data_offset);
+	make_wav(1, 2, 44100, 16, 0x7FFFFFF0u, 0, 0);
+	EXPECT(cue_wav(mem_read, 0, wav_size, &f) == CUE_OK && f.data_bytes == 200,
+	       "data length past the end of the file: clipped to %u", f.data_bytes);
+	make_wav(1, 1, 44100, 16, 200, 0, 0);
+	EXPECT(cue_wav(mem_read, 0, wav_size, &f) == CUE_E_WAV, "mono accepted");
+	make_wav(1, 2, 48000, 16, 200, 0, 0);
+	EXPECT(cue_wav(mem_read, 0, wav_size, &f) == CUE_E_WAV, "48 kHz accepted");
+	make_wav(1, 2, 44100, 8, 200, 0, 0);
+	EXPECT(cue_wav(mem_read, 0, wav_size, &f) == CUE_E_WAV, "8-bit accepted");
+	make_wav(3, 2, 44100, 16, 200, 0, 0);
+	EXPECT(cue_wav(mem_read, 0, wav_size, &f) == CUE_E_WAV, "format 3 (float) accepted");
+	make_wav(0xFFFE, 2, 44100, 16, 200, 0, 0);
+	EXPECT(cue_wav(mem_read, 0, wav_size, &f) == CUE_E_WAV, "extensible accepted");
+	make_wav(1, 2, 44100, 16, 200, 0, 1);
+	EXPECT(cue_wav(mem_read, 0, wav_size, &f) == CUE_E_WAV, "data before fmt accepted");
+	make_wav(1, 2, 44100, 16, 200, 0, 0);
+	memcpy(wav, "RIFX", 4);
+	EXPECT(cue_wav(mem_read, 0, wav_size, &f) == CUE_E_WAV, "not RIFF accepted");
+	make_wav(1, 2, 44100, 16, 200, 0, 0);
+	memcpy(wav + 36, "junk", 4);	/* no data chunk: the walk runs off the end */
+	put_le(wav + 40, 0xFFFFFFF0u, 4);
+	EXPECT(cue_wav(mem_read, 0, wav_size, &f) == CUE_E_WAV, "no data chunk accepted");
+	EXPECT(cue_wav(mem_read, 0, 8, &f) == CUE_E_WAV, "8-byte file accepted");
+	end();
+}
+
 int main(void)
 {
 	t_reference();
@@ -435,6 +528,7 @@
 	t_refusals();
 	t_message();
 	t_single();
+	t_wav();
 
 	printf("\n%d cases: %d passed, %d failed (%d failed checks)\n",
 	       cases_run, cases_passed, cases_run - cases_passed, total_fails);
--- a/fw/ctrl_832/test/emu/cue_emu.c
+++ b/fw/ctrl_832/test/emu/cue_emu.c
@@ -3,7 +3,7 @@
  * 832e (make -C fw/ctrl_832/test/emu).  cue_test checks the logic with gcc;
  * this checks what vbcc832 makes of it: every narrow field of the reference
  * disc (13.9), the int32 error fields of a refusal (set and returned with
- * the same value: the 12.6 trap) and cue_locate.  The last line is
+ * the same value: the 12.6 trap), cue_locate and cue_wav.  The last line is
  * "PASS" or "FAIL n".
  */
 #include <stdio.h>
@@ -79,10 +79,29 @@
 
 static struct cd_disc disc;
 static struct cue_parser parser;
+static uint8_t wav[64];
+
+static int32_t wav_read(void *ctx, uint32_t offset, uint8_t *dst, uint32_t len)
+{
+	uint32_t i;
+	if (offset + len > sizeof(wav))
+		return 0;
+	for (i = 0; i < len; i++)
+		dst[i] = wav[offset + i];
+	return 1;
+}
+
+static void put_le(uint8_t *p, uint32_t v, int n)
+{
+	int i;
+	for (i = 0; i < n; i++)
+		p[i] = (uint8_t)(v >> (8 * i));
+}
 
 int main(int argc, char **argv)
 {
 	struct cue_loc loc;
+	struct cd_file f;
 	char msg[24];
 	int32_t r;
 	int i;
@@ -162,6 +181,29 @@
 	expect("single number", disc.track[0].number, 1);
 	expect("single lead-out", disc.leadout, 2208);
 
+	/* WAV header: RIFF, fmt (PCM 2 x 44100 x 16), data of 20 bytes at 44 */
+	for (i = 0; i < 64; i++)
+		wav[i] = 0;
+	wav[0] = 'R'; wav[1] = 'I'; wav[2] = 'F'; wav[3] = 'F';
+	wav[8] = 'W'; wav[9] = 'A'; wav[10] = 'V'; wav[11] = 'E';
+	wav[12] = 'f'; wav[13] = 'm'; wav[14] = 't'; wav[15] = ' ';
+	put_le(wav + 16, 16, 4);
+	put_le(wav + 20, 1, 2);
+	put_le(wav + 22, 2, 2);
+	put_le(wav + 24, 44100, 4);
+	put_le(wav + 28, 176400, 4);
+	put_le(wav + 32, 4, 2);
+	put_le(wav + 34, 16, 2);
+	wav[36] = 'd'; wav[37] = 'a'; wav[38] = 't'; wav[39] = 'a';
+	put_le(wav + 40, 20, 4);
+	f.data_offset = 0;
+	f.data_bytes = 0;
+	expect("wav result", cue_wav(wav_read, 0, sizeof(wav), &f), CUE_OK);
+	expect("wav data_offset", f.data_offset, 44);
+	expect("wav data_bytes", f.data_bytes, 20);
+	put_le(wav + 22, 1, 2);
+	expect("wav mono result", cue_wav(wav_read, 0, sizeof(wav), &f), CUE_E_WAV);
+
 	if (fails)
 		printf("FAIL %d\n", fails);
 	else
```

- [ ] **Step 2: Run, expected FAIL**

```bash
make -C fw/ctrl_832/test
```

Expected:

```
cue_test.c:488:16: error: implicit declaration of function ‘cue_wav’; did you mean ‘t_wav’? [-Werror=implicit-function-declaration]
cc1: all warnings being treated as errors
make: *** [Makefile:20: cue_test] Error 1
```

- [ ] **Step 3: Implementation**

```diff
--- a/fw/ctrl_832/cue.h
+++ b/fw/ctrl_832/cue.h
@@ -79,6 +79,9 @@
    f->data_bytes.  Return CUE_OK, CUE_E_NOFILE or CUE_E_WAV. */
 typedef int32_t (*cue_open_fn)(void *ctx, const char *name, struct cd_file *f);
 
+/* Read len bytes at offset of a file into dst: 1 = all read, 0 = not. */
+typedef int32_t (*cue_read_fn)(void *ctx, uint32_t offset, uint8_t *dst, uint32_t len);
+
 struct cue_parser {
 	struct cd_disc *disc;
 	cue_open_fn     open;
@@ -114,6 +117,11 @@
 /* An ISO: one DATA2048 track over the whole file (bytes / 2048 sectors). */
 void cue_single(struct cd_disc *d, const char *shortname, uint32_t bytes);
 
+/* WAV header (13.4): walk the RIFF chunks to "fmt " (PCM, 2 channels,
+   44100, 16 bits, block align 4) and "data"; fill f->data_offset and
+   f->data_bytes (clipped to the file).  CUE_OK or CUE_E_WAV. */
+int32_t cue_wav(cue_read_fn read, void *ctx, uint32_t size, struct cd_file *f);
+
 /* Where disc sector lba lives. */
 struct cue_loc {
 	int32_t  track;		/* index into track[] */
--- a/fw/ctrl_832/cue.c
+++ b/fw/ctrl_832/cue.c
@@ -437,6 +437,55 @@
 	d->leadout = bytes / 2048;
 }
 
+static uint32_t le16(const uint8_t *b)
+{
+	return (uint32_t)b[0] | ((uint32_t)b[1] << 8);
+}
+
+static uint32_t le32(const uint8_t *b)
+{
+	return le16(b) | (le16(b + 2) << 16);
+}
+
+static int32_t id4(const uint8_t *b, const char *id)
+{
+	return b[0] == (uint8_t)id[0] && b[1] == (uint8_t)id[1] && b[2] == (uint8_t)id[2] && b[3] == (uint8_t)id[3];
+}
+
+int32_t cue_wav(cue_read_fn read, void *ctx, uint32_t size, struct cd_file *f)
+{
+	uint8_t h[16];
+	uint32_t pos = 12, len;
+	int32_t fmt = 0;
+	if (size < 12 || !read(ctx, 0, h, 12) || !id4(h, "RIFF") || !id4(h + 8, "WAVE"))
+		return CUE_E_WAV;
+	while (size - pos >= 8) {
+		if (!read(ctx, pos, h, 8))
+			return CUE_E_WAV;
+		len = le32(h + 4);
+		if (id4(h, "fmt ")) {
+			if (len < 16 || size - pos - 8 < 16 || !read(ctx, pos + 8, h, 16))
+				return CUE_E_WAV;
+			if (le16(h) != 1 || le16(h + 2) != 2 || le32(h + 4) != 44100 ||
+			    le16(h + 12) != 4 || le16(h + 14) != 16)
+				return CUE_E_WAV;
+			fmt = 1;
+		} else if (id4(h, "data")) {
+			if (!fmt)
+				return CUE_E_WAV;
+			f->data_offset = pos + 8;
+			f->data_bytes = len < size - pos - 8 ? len : size - pos - 8;
+			return CUE_OK;
+		}
+		if (len > size - pos - 8)
+			break;
+		pos += 8 + len + (len & 1);
+		if (pos > size)
+			break;
+	}
+	return CUE_E_WAV;
+}
+
 int32_t cue_locate(const struct cd_disc *d, uint32_t lba, struct cue_loc *loc)
 {
 	int32_t i;
```

- [ ] **Step 4: Run, expected PASS**

```bash
make -C fw/ctrl_832/test
make -C fw/ctrl_832/test/emu 832DIR=/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64/EightThirtyTwo
```

Expected: `11 cases: 11 passed, 0 failed (0 failed checks)` from cue_test, atapi_test and cdrom_test as in task 1; emu `PASS` twice.

- [ ] **Step 5: Commit**

```bash
git add fw/ctrl_832/cue.h fw/ctrl_832/cue.c fw/ctrl_832/test/cue_test.c fw/ctrl_832/test/emu/cue_emu.c
git commit -F- <<'EOF'
fw/ctrl_832: WAV header check for CUE sheets (cue_wav)

findings/cdrom/plan.md 13.4: walk the RIFF chunks to "fmt " (PCM, 2
channels, 44100, 16 bits, block align 4) and "data"; no fixed 44-byte
header.  A data length past the end of the file is clipped.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
EOF
```

### Task 3: ATAPI commands from the disc model

**Files:**
- Modify: `fw/ctrl_832/atapi.h` (`#include "cue.h"`, `atapi_unit.disc`, `atapi_insert` signature), `fw/ctrl_832/atapi.c` (`adr_ctrl`, `touches`, `atapi_insert/eject`, `read_toc`, `disc_information`, `track_information`, `read_sectors`)
- Modify: `fw/ctrl_832/cdrom.c` (`cd_disc` + `cue_single` in `CD_Insert`), `fw/ctrl_832/Makefile` (`cue.o`)
- Test: `fw/ctrl_832/test/atapi_test.c`, `fw/ctrl_832/test/Makefile` (link cue.c), `fw/ctrl_832/test/emu/atapi_emu.c`, `fw/ctrl_832/test/emu/Makefile` (atapi_emu links cue.o)

**Interfaces:**
- Consumes: `struct cd_disc`, `struct cue_loc`, `cue_locate`, `cue_single`, `CD_AUDIO` (task 1).
- Produces: `int atapi_insert(struct atapi_unit *u, const struct cd_disc *disc, const char *name)` (the model is kept by pointer until the eject; `u->sectors` = `disc->leadout`); `struct atapi_unit` member `const struct cd_disc *disc`; READ(10)/(12) of any audio sector (or its gap) -> CHECK 05/64/00; READ TOC format 0 lists every track (control 0x14 data / 0x10 audio), starting track 1..n or 0xAA, lead-out control = the last track's; static `touches(d, lba, count, audio)` (task 11 uses it with `audio` = 0).

- [ ] **Step 1: Write the failing tests**

`atapi_test` now inserts disc models: `iso(n)` builds the ISO model `cdrom.c` will build, `iso_other(n)` a second one for swaps (a refused swap must not touch the disc in the drive), `pinball()` parses the reference CUE.

```diff
--- a/fw/ctrl_832/test/atapi_test.c
+++ b/fw/ctrl_832/test/atapi_test.c
@@ -85,6 +85,56 @@
 static struct atapi_unit U;
 static struct atapi_result R;
 
+/* An ISO of this many sectors as the disc model cdrom.c builds (cue_single).
+   One model at a time: a later call changes the disc U points to. */
+static struct cd_disc D;
+
+static const struct cd_disc *iso(uint32_t sectors)
+{
+	cue_single(&D, "TESTDISCISO", sectors * ATAPI_SECTOR_SIZE);
+	return &D;
+}
+
+/* A second disc, for swaps: the refused one must not touch the disc in. */
+static struct cd_disc D2;
+
+static const struct cd_disc *iso_other(uint32_t sectors)
+{
+	cue_single(&D2, "OTHERDSCISO", sectors * ATAPI_SECTOR_SIZE);
+	return &D2;
+}
+
+/* The reference disc (findings/cdrom/plan.md 13.9) through the CUE parser:
+   track 1 data LBA 0, track 2 audio 2358 (silent PREGAP from 2208), track
+   3 audio 20283 (INDEX 00 at 20133), lead-out 41658. */
+static int32_t pinball_open(void *ctx, const char *name, struct cd_file *f)
+{
+	static const uint32_t bytes[3] = { 4521984, 41806800, 50626800 };
+	int i = name[0] - '1';
+	(void)ctx;
+	if (i < 0 || i > 2)
+		return CUE_E_NOFILE;
+	memcpy(f->shortname, "PINBALL1ISO", 12);
+	f->shortname[6] = name[0];
+	f->data_offset = f->wave ? 44 : 0;
+	f->data_bytes = bytes[i];
+	return CUE_OK;
+}
+
+static const struct cd_disc *pinball(void)
+{
+	static const char cue[] =
+		"FILE \"1.iso\" BINARY\n TRACK 01 MODE1/2048\n INDEX 01 00:00:00\n"
+		"FILE \"2.wav\" WAVE\n TRACK 02 AUDIO\n PREGAP 00:02:00\n INDEX 01 00:00:00\n"
+		"FILE \"3.wav\" WAVE\n TRACK 03 AUDIO\n INDEX 00 00:00:00\n INDEX 01 00:02:00\n";
+	static struct cue_parser p;
+	cue_begin(&p, &D, pinball_open, 0);
+	cue_feed(&p, cue, sizeof(cue) - 1);
+	if (cue_end(&p) != CUE_OK)
+		printf("  note: the reference CUE did not parse (error %d line %d)\n", p.error, p.error_line);
+	return &D;
+}
+
 static int run(const uint8_t *cdb)
 {
 	int k;
@@ -185,17 +235,23 @@
 	}
 }
 
-/* Fresh unit with the OS 3.9 image in and its insert UNIT ATTENTION consumed. */
-static void ready_unit(uint32_t sectors, const char *name)
+/* Fresh unit with a disc in and its insert UNIT ATTENTION consumed. */
+static void ready_disc(const struct cd_disc *d, const char *name)
 {
 	uint8_t c[12];
 	atapi_init(&U);
-	atapi_insert(&U, sectors, name);
+	atapi_insert(&U, d, name);
 	cdb0(c, 0x00);
 	run(c);	/* 06/28/00 */
 	run(c);	/* GOOD */
 }
 
+/* Fresh unit with an ISO of this many sectors in (the OS 3.9 image). */
+static void ready_unit(uint32_t sectors, const char *name)
+{
+	ready_disc(iso(sectors), name);
+}
+
 static void tur(uint8_t *c) { cdb0(c, 0x00); }
 
 static void inquiry(uint8_t *c, uint8_t alloc)
@@ -282,13 +338,13 @@
 
 	/* longer names: first 16 characters */
 	atapi_init(&U);
-	atapi_insert(&U, 275806, "ClassicInstallCD-53.71.iso");
+	atapi_insert(&U, iso(275806), "ClassicInstallCD-53.71.iso");
 	expect_response(__LINE__, c, 36);
 	expect_bytes(__LINE__, (const uint8_t *)"ClassicInstallCD", 16, 16);
 
 	/* characters outside printable ASCII never reach the host */
 	atapi_init(&U);
-	atapi_insert(&U, 100, "a\tb\x80\x7f");
+	atapi_insert(&U, iso(100), "a\tb\x80\x7f");
 	expect_response(__LINE__, c, 36);
 	{
 		int i, ok = 1;
@@ -312,7 +368,7 @@
 	expect_bytes(__LINE__, (const uint8_t *)"CD-ROM (empty)  ", 16, 16);
 
 	/* after an eject too */
-	atapi_insert(&U, OS39_SECTORS, OS39_NAME);
+	atapi_insert(&U, iso(OS39_SECTORS), OS39_NAME);
 	EXPECT(atapi_eject(&U) == ATAPI_OK, "eject refused");
 	expect_response(__LINE__, c, 36);
 	expect_bytes(__LINE__, (const uint8_t *)"CD-ROM (empty)  ", 16, 16);
@@ -377,7 +433,7 @@
 	int i, nonzero = 0;
 	begin("IDENTIFY PACKET DEVICE: words 0/49/82 and the model string");
 	atapi_init(&U);
-	atapi_insert(&U, OS39_SECTORS, OS39_NAME);
+	atapi_insert(&U, iso(OS39_SECTORS), OS39_NAME);
 	memset(id, 0xEE, sizeof(id));
 	atapi_identify(id, &U);
 	EXPECT(id[0] == 0x8580, "word 0 = %04X", id[0]);
@@ -404,7 +460,7 @@
 	expect_ata_string(__LINE__, id, 27, "CD-ROM (empty)", 40);
 
 	/* 40-character limit */
-	atapi_insert(&U, 100, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz.iso");
+	atapi_insert(&U, iso(100), "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz.iso");
 	atapi_identify(id, &U);
 	expect_ata_string(__LINE__, id, 27, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmn", 40);
 	EXPECT(id[47] == 0, "word 47 = %04X (model overran)", id[47]);
@@ -586,7 +642,7 @@
 	uint8_t c[12];
 	begin("insert: one-shot UNIT ATTENTION 06/28/00, exempt commands keep it pending");
 	atapi_init(&U);
-	atapi_insert(&U, OS39_SECTORS, OS39_NAME);
+	atapi_insert(&U, iso(OS39_SECTORS), OS39_NAME);
 	inquiry(c, 36);
 	expect_response(__LINE__, c, 36);
 	gesn(c, 1, 0x10, 8);
@@ -599,14 +655,14 @@
 
 	/* REQUEST SENSE as the first command reports the pending UA and clears it */
 	atapi_init(&U);
-	atapi_insert(&U, OS39_SECTORS, OS39_NAME);
+	atapi_insert(&U, iso(OS39_SECTORS), OS39_NAME);
 	expect_sense(__LINE__, 0x06, 0x28, 0x00);
 	tur(c);
 	expect_good(__LINE__, c);
 
 	/* any non-exempt command takes the UA, not only TEST UNIT READY */
 	atapi_init(&U);
-	atapi_insert(&U, OS39_SECTORS, OS39_NAME);
+	atapi_insert(&U, iso(OS39_SECTORS), OS39_NAME);
 	read10(c, 16, 1);
 	expect_check(__LINE__, c, 0x06, 0x28, 0x00);
 	EXPECT(run(c) == ATAPI_READ, "READ after the UA: kind %d", R.kind);
@@ -642,7 +698,7 @@
 	static const uint8_t no_class[4]  = { 0x00, 0x02, 0x80, 0x10 };
 	begin("GET EVENT STATUS NOTIFICATION: new media / removed, one-shot");
 	atapi_init(&U);
-	atapi_insert(&U, OS39_SECTORS, OS39_NAME);
+	atapi_insert(&U, iso(OS39_SECTORS), OS39_NAME);
 	gesn(c, 1, 0x10, 8);
 	expect_response(__LINE__, c, 8);
 	expect_bytes(__LINE__, new_media, 0, 8);
@@ -674,7 +730,7 @@
 	EXPECT(U.media, "disc gone after a refused eject");
 	EXPECT(atapi_eject(&U) == ATAPI_LOCKED, "OSD eject not refused while locked");
 	EXPECT(U.media, "disc gone after a refused OSD eject");
-	EXPECT(atapi_insert(&U, 275806, "ClassicInstallCD-53.71.iso") == ATAPI_LOCKED,
+	EXPECT(atapi_insert(&U, iso_other(275806), "ClassicInstallCD-53.71.iso") == ATAPI_LOCKED,
 	       "swap not refused while locked");
 	inquiry(c, 36);
 	expect_response(__LINE__, c, 36);
@@ -713,7 +769,7 @@
 	EXPECT(U.media, "disc gone after start/stop/load");
 
 	/* swap while unlocked: new disc in, UNIT ATTENTION again */
-	EXPECT(atapi_insert(&U, 275806, "ClassicInstallCD-53.71.iso") == ATAPI_OK, "swap refused");
+	EXPECT(atapi_insert(&U, iso_other(275806), "ClassicInstallCD-53.71.iso") == ATAPI_OK, "swap refused");
 	tur(c);
 	expect_check(__LINE__, c, 0x06, 0x28, 0x00);
 	cdb0(c, 0x25);
@@ -826,6 +882,114 @@
 	end();
 }
 
+static void t_toc_tracks(void)
+{
+	/* LBA: 2358 = 0x936, 20283 = 0x4F3B, 41658 = 0xA2BA */
+	static const uint8_t lba[36] = {
+		0x00, 0x22, 0x01, 0x03,
+		0x00, 0x14, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
+		0x00, 0x10, 0x02, 0x00, 0x00, 0x00, 0x09, 0x36,
+		0x00, 0x10, 0x03, 0x00, 0x00, 0x00, 0x4F, 0x3B,
+		0x00, 0x10, 0xAA, 0x00, 0x00, 0x00, 0xA2, 0xBA
+	};
+	/* MSF = LBA + 150 frames: 00:33:33, 04:32:33, 09:17:33 */
+	static const uint8_t msf[36] = {
+		0x00, 0x22, 0x01, 0x03,
+		0x00, 0x14, 0x01, 0x00, 0x00, 0, 2, 0,
+		0x00, 0x10, 0x02, 0x00, 0x00, 0, 33, 33,
+		0x00, 0x10, 0x03, 0x00, 0x00, 4, 32, 33,
+		0x00, 0x10, 0xAA, 0x00, 0x00, 9, 17, 33
+	};
+	static const uint8_t from3[20] = {
+		0x00, 0x12, 0x01, 0x03,
+		0x00, 0x10, 0x03, 0x00, 0x00, 0x00, 0x4F, 0x3B,
+		0x00, 0x10, 0xAA, 0x00, 0x00, 0x00, 0xA2, 0xBA
+	};
+	static const uint8_t session[12] = {
+		0x00, 0x0A, 0x01, 0x01, 0x00, 0x14, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00
+	};
+	uint8_t c[12];
+	begin("READ TOC of the reference disc: 3 tracks, audio control 0x10, starting track, lead-out");
+	ready_disc(pinball(), "Pinball Fantasies");
+	toc(c, 0, 0, 0, 0xFFFF);
+	expect_response(__LINE__, c, 36);
+	expect_bytes(__LINE__, lba, 0, 36);
+	toc(c, 1, 0, 1, 0xFFFF);
+	expect_response(__LINE__, c, 36);
+	expect_bytes(__LINE__, msf, 0, 36);
+	toc(c, 0, 0, 3, 0xFFFF);
+	expect_response(__LINE__, c, 20);
+	expect_bytes(__LINE__, from3, 0, 20);
+	toc(c, 0, 0, 0xAA, 0xFFFF);
+	expect_response(__LINE__, c, 12);
+	expect_bytes(__LINE__, from3 + 12, 4, 8);
+	toc(c, 0, 0, 4, 0xFFFF);
+	expect_check(__LINE__, c, 0x05, 0x24, 0x00);
+	toc(c, 0, 1, 0, 0xFFFF);
+	expect_response(__LINE__, c, 12);
+	expect_bytes(__LINE__, session, 0, 12);
+	toc(c, 0, 0, 0, 12);	/* allocation length cuts, the length field stays (12.2) */
+	expect_response(__LINE__, c, 12);
+	EXPECT(be16(atapi_buf) == 34, "TOC length %u", be16(atapi_buf));
+	end();
+}
+
+static void t_tracks_info(void)
+{
+	static const uint8_t cap[8] = { 0x00, 0x00, 0xA2, 0xB9, 0x00, 0x00, 0x08, 0x00 };
+	uint8_t c[12];
+	begin("reference disc: READ CAPACITY to the lead-out, DISC / TRACK INFORMATION per track");
+	ready_disc(pinball(), "Pinball Fantasies");
+	cdb0(c, 0x25);
+	expect_response(__LINE__, c, 8);
+	expect_bytes(__LINE__, cap, 0, 8);
+	cdb0(c, 0x51);
+	c[8] = 0xFF;
+	expect_response(__LINE__, c, 34);
+	EXPECT(atapi_buf[3] == 1 && atapi_buf[5] == 1 && atapi_buf[6] == 3, "disc info first %u last %u",
+	       atapi_buf[5], atapi_buf[6]);
+	cdb0(c, 0x52);
+	c[1] = 0x01;
+	c[5] = 0x02;
+	c[8] = 0xFF;
+	expect_response(__LINE__, c, 28);
+	EXPECT(atapi_buf[2] == 2 && atapi_buf[5] == 0x00 && be32(atapi_buf + 8) == 2358 && be32(atapi_buf + 24) == 17925,
+	       "track 2: number %u mode %02X start %u size %u", atapi_buf[2], atapi_buf[5], be32(atapi_buf + 8),
+	       be32(atapi_buf + 24));
+	cdb0(c, 0x52);
+	put_be32(c + 2, 30000);	/* type 0: the track holding LBA 30000 */
+	c[8] = 0xFF;
+	expect_response(__LINE__, c, 28);
+	EXPECT(atapi_buf[2] == 3 && be32(atapi_buf + 8) == 20283 && be32(atapi_buf + 24) == 21375,
+	       "LBA 30000: track %u start %u size %u", atapi_buf[2], be32(atapi_buf + 8), be32(atapi_buf + 24));
+	cdb0(c, 0x52);
+	c[1] = 0x01;
+	c[5] = 0x04;
+	c[8] = 0xFF;
+	expect_check(__LINE__, c, 0x05, 0x24, 0x00);
+	end();
+}
+
+static void t_read_audio(void)
+{
+	uint8_t c[12];
+	begin("READ(10)/(12) of audio sectors (or their gap): 05/64/00; data up to the boundary reads");
+	ready_disc(pinball(), "Pinball Fantasies");
+	read10(c, 2200, 8);	/* the last 8 data sectors */
+	EXPECT(run(c) == ATAPI_READ && R.lba == 2200 && R.count == 8, "kind %d lba %u count %u", R.kind, R.lba, R.count);
+	read10(c, 2200, 9);	/* one into track 2's PREGAP */
+	expect_check(__LINE__, c, 0x05, 0x64, 0x00);
+	read10(c, 2208, 1);
+	expect_check(__LINE__, c, 0x05, 0x64, 0x00);
+	read10(c, 2358, 1);
+	expect_check(__LINE__, c, 0x05, 0x64, 0x00);
+	read12(c, 30000, 2);
+	expect_check(__LINE__, c, 0x05, 0x64, 0x00);
+	read10(c, 41657, 2);	/* past the lead-out: the range check comes first */
+	expect_check(__LINE__, c, 0x05, 0x21, 0x00);
+	end();
+}
+
 static void t_iso_read(const char *path)
 {
 	uint8_t c[12];
@@ -912,6 +1076,9 @@
 	t_invalid();
 	t_read();
 	t_misc();
+	t_toc_tracks();
+	t_tracks_info();
+	t_read_audio();
 	t_iso_read(path);
 
 	if (iso_fd >= 0)
--- a/fw/ctrl_832/test/Makefile
+++ b/fw/ctrl_832/test/Makefile
@@ -13,14 +13,14 @@
 
 all: run
 
-atapi_test: atapi_test.c ../atapi.c ../atapi.h
-	$(HOSTCC) $(CFLAGS) -o $@ atapi_test.c ../atapi.c
+atapi_test: atapi_test.c ../atapi.c ../atapi.h ../cue.c ../cue.h
+	$(HOSTCC) $(CFLAGS) -o $@ atapi_test.c ../atapi.c ../cue.c
 
 cue_test: cue_test.c ../cue.c ../cue.h
 	$(HOSTCC) $(CFLAGS) -o $@ cue_test.c ../cue.c
 
-cdrom_test: cdrom_test.c ../cdrom.c ../cdrom.h ../atapi.c ../atapi.h ../hdd.h
-	$(HOSTCC) $(CFLAGS) -o $@ cdrom_test.c ../cdrom.c ../atapi.c
+cdrom_test: cdrom_test.c ../cdrom.c ../cdrom.h ../atapi.c ../atapi.h ../cue.c ../cue.h ../hdd.h
+	$(HOSTCC) $(CFLAGS) -o $@ cdrom_test.c ../cdrom.c ../atapi.c ../cue.c
 
 run: cue_test atapi_test cdrom_test
 	./cue_test
```

```diff
--- a/fw/ctrl_832/test/emu/atapi_emu.c
+++ b/fw/ctrl_832/test/emu/atapi_emu.c
@@ -28,6 +28,33 @@
 static struct atapi_unit unit;
 static struct atapi_result res;
 static uint8_t cdb[12];
+static struct cd_disc iso, pinball;
+
+/* The reference disc (13.9) as cue.c lays it out (cue_emu checks that). */
+static void make_pinball(void)
+{
+	struct cd_track *t = pinball.track;
+	pinball.tracks = 3;
+	pinball.files = 3;
+	pinball.leadout = 41658;
+	t[0].number = 1; t[0].type = CD_DATA2048; t[0].file = 0; t[0].file_offset = 0;
+	t[0].lba = 0; t[0].sectors = 2208; t[0].pregap_lba = 0; t[0].pregap_silent = 0;
+	t[1].number = 2; t[1].type = CD_AUDIO; t[1].file = 1; t[1].file_offset = 44;
+	t[1].lba = 2358; t[1].sectors = 17775; t[1].pregap_lba = 2208; t[1].pregap_silent = 1;
+	t[2].number = 3; t[2].type = CD_AUDIO; t[2].file = 2; t[2].file_offset = 44 + 150 * 2352;
+	t[2].lba = 20283; t[2].sectors = 21375; t[2].pregap_lba = 20133; t[2].pregap_silent = 0;
+	pinball.file[1].wave = 1;
+	pinball.file[1].data_offset = 44;
+	pinball.file[1].data_bytes = 41806800;
+	pinball.file[2].wave = 1;
+	pinball.file[2].data_offset = 44;
+	pinball.file[2].data_bytes = 50626800;
+}
+
+static unsigned int be32(const uint8_t *p)
+{
+	return ((unsigned int)p[0] << 24) | ((unsigned int)p[1] << 16) | ((unsigned int)p[2] << 8) | p[3];
+}
 
 static int packet(uint8_t op, uint8_t b2, uint8_t b4, uint8_t b8)
 {
@@ -67,7 +94,9 @@
 	expect("TUR no disc ascq", res.ascq, 0x00);
 
 	/* a disc of 2208 sectors (the Pinball Fantasies data track) */
-	expect("insert", atapi_insert(&unit, 2208, "Pinball Fantasies"), ATAPI_OK);
+	cue_single(&iso, "PINBALL ISO", 2208 * 2048);
+	expect("insert", atapi_insert(&unit, &iso, "Pinball Fantasies"), ATAPI_OK);
+	expect("insert sectors", unit.sectors, 2208);
 	k = packet(0x00, 0, 0, 0);	/* the insert's UNIT ATTENTION */
 	expect("TUR after insert kind", res.kind, ATAPI_CHECK);
 	expect("TUR after insert sense key", res.sense_key, 0x06);
@@ -103,6 +132,45 @@
 	expect("eject kind", res.kind, ATAPI_DONE);
 	expect("eject ejected", res.ejected, 1);
 
+	/* the reference disc: TOC of 3 tracks, audio sectors are not READ data */
+	make_pinball();
+	expect("insert pinball", atapi_insert(&unit, &pinball, "Pinball Fantasies"), ATAPI_OK);
+	expect("pinball sectors", unit.sectors, 41658);
+	packet(0x00, 0, 0, 0);	/* UNIT ATTENTION */
+	memset(cdb, 0, sizeof(cdb));
+	cdb[0] = 0x43;
+	cdb[7] = 0xFF;
+	cdb[8] = 0xFF;
+	k = atapi_packet(&unit, cdb, 0xFFFE, &res);
+	expect("TOC kind", res.kind, ATAPI_RESPONSE);
+	expect("TOC length", res.length, 36);
+	expect("TOC data length", (atapi_buf[0] << 8) | atapi_buf[1], 34);
+	expect("TOC last track", atapi_buf[3], 3);
+	expect("TOC track 1 control", atapi_buf[5], 0x14);
+	expect("TOC track 2 control", atapi_buf[13], 0x10);
+	expect("TOC track 2 number", atapi_buf[14], 2);
+	expect("TOC track 2 LBA", be32(atapi_buf + 16), 2358);
+	expect("TOC track 3 LBA", be32(atapi_buf + 24), 20283);
+	expect("TOC lead-out number", atapi_buf[30], 0xAA);
+	expect("TOC lead-out LBA", be32(atapi_buf + 32), 41658);
+	memset(cdb, 0, sizeof(cdb));
+	cdb[0] = 0x28;
+	cdb[4] = 0x09;	/* LBA 2358 = 0x936 */
+	cdb[5] = 0x36;
+	cdb[8] = 1;
+	k = atapi_packet(&unit, cdb, 0xFFFE, &res);
+	expect("READ audio return", k, ATAPI_CHECK);
+	expect("READ audio kind", res.kind, ATAPI_CHECK);
+	expect("READ audio sense key", res.sense_key, 0x05);
+	expect("READ audio asc", res.asc, 0x64);
+	cdb[4] = 0x08;	/* LBA 2200 = 0x898, 8 sectors: the end of the data track */
+	cdb[5] = 0x98;
+	cdb[8] = 8;
+	k = atapi_packet(&unit, cdb, 0xFFFE, &res);
+	expect("READ data kind", res.kind, ATAPI_READ);
+	expect("READ data lba", res.lba, 2200);
+	expect("READ data count", res.count, 8);
+
 	if (fails)
 		printf("FAIL %d\n", fails);
 	else
--- a/fw/ctrl_832/test/emu/Makefile
+++ b/fw/ctrl_832/test/emu/Makefile
@@ -34,9 +34,9 @@
 $(TEST_ASM): %.asm: %.c
 	$(CC) $(CFLAGS) -o=$@ $<
 
-atapi.asm: ../../atapi.h
+atapi.asm: ../../atapi.h ../../cue.h
 cue.asm: ../../cue.h
-atapi_emu.asm: ../../atapi.h
+atapi_emu.asm: ../../atapi.h ../../cue.h
 cue_emu.asm: ../../cue.h
 
 %.o: %.asm
@@ -51,7 +51,7 @@
 	$(MAKE) -C emusrc
 	cp emusrc/832e $@
 
-atapi_emu: atapi_emu.o atapi.o
+atapi_emu: atapi_emu.o atapi.o cue.o
 	$(LD) -o $@ $(LIBDIR)/crt0.a $(LIBDIR)/lib832.a $^
 
 cue_emu: cue_emu.o cue.o
```

- [ ] **Step 2: Run, expected FAIL**

```bash
make -C fw/ctrl_832/test
```

Expected (first lines; atapi.h does not include cue.h yet):

```
atapi_test.c:94:9: error: implicit declaration of function ‘cue_single’ [-Werror=implicit-function-declaration]
atapi_test.c:110:65: error: ‘struct cd_file’ declared inside parameter list will not be visible outside of this definition or declaration [-Werror]
atapi_test.c:116:24: error: ‘CUE_E_NOFILE’ undeclared (first use in this function)
```

- [ ] **Step 3: Implementation**

```diff
--- a/fw/ctrl_832/atapi.h
+++ b/fw/ctrl_832/atapi.h
@@ -20,6 +20,7 @@
  */
 
 #include <stdint.h>
+#include "cue.h"
 
 #define ATAPI_SECTOR_SIZE 2048
 #define ATAPI_BUF_SIZE    2048
@@ -50,8 +51,9 @@
 	uint8_t  sense_key;	/* sense of the last command, for REQUEST SENSE */
 	uint8_t  asc;
 	uint8_t  ascq;
-	uint32_t sectors;	/* disc size in 2048-byte sectors */
-	char     name[ATAPI_NAME_LEN + 1];	/* ISO long name, printable ASCII */
+	uint32_t sectors;	/* disc size in sectors: the lead-out LBA */
+	const struct cd_disc *disc;	/* the disc in the drive (cue.h), 0 = none */
+	char     name[ATAPI_NAME_LEN + 1];	/* ISO / CUE long name, printable ASCII */
 };
 
 struct atapi_result
@@ -81,8 +83,10 @@
 
 /* Put a disc in (OSD insert or swap).  Refused with ATAPI_LOCKED when a disc
    is in and locked; otherwise any disc in is replaced, UNIT ATTENTION
-   06/28/00 and a NEW_MEDIA event are armed.  name: the ISO long name. */
-int atapi_insert(struct atapi_unit *u, uint32_t sectors, const char *name);
+   06/28/00 and a NEW_MEDIA event are armed.  disc: the disc model (an ISO
+   is one DATA2048 track, cue_single), kept by pointer until the eject;
+   name: the ISO / CUE long name. */
+int atapi_insert(struct atapi_unit *u, const struct cd_disc *disc, const char *name);
 
 /* Take the disc out (OSD eject).  ATAPI_LOCKED while locked, nothing changes;
    otherwise ATAPI_OK and, if a disc was in, a REMOVED event is armed.
--- a/fw/ctrl_832/atapi.c
+++ b/fw/ctrl_832/atapi.c
@@ -13,8 +13,9 @@
 /* Every response here fits in this many bytes (MODE SENSE(10) 3F: 52). */
 #define RESP_MAX 64
 
-#define LEADOUT_TRACK 0xAA
-#define ADR_CTRL_DATA 0x14	/* ADR 1 (position), control 4 (data track) */
+#define LEADOUT_TRACK  0xAA
+#define ADR_CTRL_DATA  0x14	/* ADR 1 (position), control 4 (data track) */
+#define ADR_CTRL_AUDIO 0x10	/* ADR 1, control 0 (2-channel audio, no pre-emphasis) */
 
 static const char empty_name[] = "CD-ROM (empty)";
 
@@ -56,6 +57,29 @@
 	}
 }
 
+static uint8_t adr_ctrl(const struct cd_track *t)
+{
+	return t->type == CD_AUDIO ? ADR_CTRL_AUDIO : ADR_CTRL_DATA;
+}
+
+/* Does [lba, lba + count) touch an audio track (audio = 1) or a data track
+   (audio = 0), gaps included?  The range is inside the disc. */
+static int touches(const struct cd_disc *d, uint32_t lba, uint32_t count, int audio)
+{
+	struct cue_loc l;
+	while (count) {
+		uint32_t n;
+		if (!cue_locate(d, lba, &l))
+			return 0;
+		if ((d->track[l.track].type == CD_AUDIO) == audio)
+			return 1;
+		n = l.run < count ? l.run : count;
+		lba += n;
+		count -= n;
+	}
+	return 0;
+}
+
 static const char *disc_name(const struct atapi_unit *u)
 {
 	if (!u->media)
@@ -136,7 +160,7 @@
 	set_sense(u, 0, 0, 0);
 }
 
-int atapi_insert(struct atapi_unit *u, uint32_t sectors, const char *name)
+int atapi_insert(struct atapi_unit *u, const struct cd_disc *disc, const char *name)
 {
 	unsigned i;
 	if (u->media && u->locked)
@@ -146,7 +170,8 @@
 		u->name[i] = (c < 0x20 || c > 0x7E) ? '_' : (char)c;
 	}
 	u->name[i] = 0;
-	u->sectors = sectors;
+	u->disc = disc;
+	u->sectors = disc->leadout;
 	u->media = 1;
 	u->ua_asc = 0x28;
 	u->event = ATAPI_EVENT_NEW_MEDIA;
@@ -160,6 +185,7 @@
 	if (u->media) {
 		u->media = 0;
 		u->sectors = 0;
+		u->disc = 0;
 		u->name[0] = 0;
 		u->event = ATAPI_EVENT_REMOVED;
 	}
@@ -292,36 +318,46 @@
 	return respond(u, r, total, get16(cdb + 7));
 }
 
-static void toc_entry(uint8_t *p, uint8_t track, uint32_t lba, int msf)
+static void toc_entry(uint8_t *p, uint8_t ctrl, uint8_t track, uint32_t lba, int msf)
 {
-	p[1] = ADR_CTRL_DATA;
+	p[1] = ctrl;
 	p[2] = track;
 	put_addr(p + 4, lba, msf);
 }
 
 static int read_toc(struct atapi_unit *u, const uint8_t *cdb, struct atapi_result *r)
 {
+	const struct cd_disc *d = u->disc;
 	uint8_t *b = atapi_buf;
 	uint8_t *p = b + 4;
 	int msf = cdb[1] & 0x02;
 	uint8_t format = cdb[2] & 0x0F;
 	uint8_t track = cdb[6];
+	int32_t i, first;
 
+	memset(b, 0, 4 + 8 * (CD_MAX_TRACKS + 1));	/* 99 tracks + lead-out: 804 bytes */
 	if (!format)
 		format = cdb[9] >> 6;	/* SFF-8020 drivers put the format here */
 	b[2] = 1;	/* first track / session */
-	b[3] = 1;	/* last track / session */
+	b[3] = 1;	/* last session */
 	if (format == 0) {
-		if (track <= 1) {
-			toc_entry(p, 1, 0, msf);
-			p += 8;
-		} else if (track != LEADOUT_TRACK) {
+		b[3] = (uint8_t)d->tracks;	/* last track */
+		if (track == LEADOUT_TRACK)
+			first = d->tracks;	/* the lead-out only */
+		else if (track <= 1)
+			first = 0;
+		else if (track <= d->tracks)
+			first = track - 1;
+		else
 			return ILLEGAL_FIELD(u, r);
+		for (i = first; i < d->tracks; i++) {
+			toc_entry(p, adr_ctrl(&d->track[i]), d->track[i].number, d->track[i].lba, msf);
+			p += 8;
 		}
-		toc_entry(p, LEADOUT_TRACK, u->sectors, msf);
+		toc_entry(p, adr_ctrl(&d->track[d->tracks - 1]), LEADOUT_TRACK, d->leadout, msf);
 		p += 8;
 	} else if (format == 1) {
-		toc_entry(p, 1, 0, msf);	/* first track of the last session */
+		toc_entry(p, adr_ctrl(&d->track[0]), 1, d->track[0].lba, msf);	/* first track of the last session */
 		p += 8;
 	} else {
 		return ILLEGAL_FIELD(u, r);
@@ -403,7 +439,7 @@
 	b[3] = 1;		/* first track */
 	b[4] = 1;		/* sessions */
 	b[5] = 1;		/* first track in last session */
-	b[6] = 1;		/* last track in last session */
+	b[6] = (uint8_t)u->disc->tracks;	/* last track in last session */
 	b[7] = 0x20;		/* unrestricted use */
 	memset(b + 16, 0xFF, 8);	/* lead-in / last lead-out start: complete disc */
 	return respond(u, r, 34, get16(cdb + 7));
@@ -411,17 +447,30 @@
 
 static int track_information(struct atapi_unit *u, const uint8_t *cdb, struct atapi_result *r)
 {
+	const struct cd_disc *d = u->disc;
+	const struct cd_track *t;
 	uint8_t *b = atapi_buf;
-	uint32_t n = get32(cdb + 2);
+	uint32_t n = get32(cdb + 2), end;
 	uint8_t type = cdb[1] & 0x03;
-	if (!((type == 0 && n < u->sectors) || (type != 0 && n == 1)))
+	struct cue_loc l;
+	int32_t i;
+	if (type == 0 && cue_locate(d, n, &l))
+		i = l.track;				/* the track holding LBA n */
+	else if (type == 1 && n >= 1 && n <= (uint32_t)d->tracks)
+		i = (int32_t)n - 1;			/* track n */
+	else if (type == 2 && n == 1)
+		i = 0;					/* session 1: its first track */
+	else
 		return ILLEGAL_FIELD(u, r);
+	t = &d->track[i];
+	end = i + 1 < d->tracks ? d->track[i + 1].lba : d->leadout;
 	put16(b, 28 - 2);
-	b[2] = 1;		/* track */
+	b[2] = t->number;	/* track */
 	b[3] = 1;		/* session */
-	b[5] = 0x04;		/* track mode: data */
-	b[6] = 0x01;		/* data mode 1 */
-	put32(b + 24, u->sectors);	/* track size; start (8..11) is 0 */
+	b[5] = t->type == CD_AUDIO ? 0x00 : 0x04;	/* track mode: the control nibble */
+	b[6] = t->type == CD_AUDIO ? 0x0F : 0x01;	/* data mode: unknown (audio) / mode 1 */
+	put32(b + 8, t->lba);	/* track start */
+	put32(b + 24, end - t->lba);	/* track size */
 	return respond(u, r, 28, get16(cdb + 7));
 }
 
@@ -433,6 +482,8 @@
 		return good(u, r);
 	if (lba >= u->sectors || count > u->sectors - lba)
 		return check(u, r, 0x05, 0x21, 0x00);
+	if (touches(u->disc, lba, count, 1))	/* audio sectors are not READ(10) data */
+		return check(u, r, 0x05, 0x64, 0x00);
 	set_sense(u, 0, 0, 0);
 	r->lba = lba;
 	r->count = count;
```

`cdrom.c` builds the one-track model for the ISO it opens (the full CUE insert is task 4), and the firmware links `cue.o`:

```diff
--- a/fw/ctrl_832/cdrom.c
+++ b/fw/ctrl_832/cdrom.c
@@ -34,6 +34,7 @@
 
 cdromTYPE cdrom;
 
+static struct cd_disc cd_disc;		/* the disc in the drive (an ISO: one track) */
 static char cd_filename[12];
 static unsigned short cd_id[256];	/* IDENTIFY PACKET DEVICE words */
 static unsigned char cd_cdb[12];
@@ -120,7 +121,8 @@
 	cdrom.hdf.offset = 0;
 	BuildHardfileIndex(&cdrom.hdf);
 
-	atapi_insert(&cdrom.unit, cdrom.hdf.file.size / ATAPI_SECTOR_SIZE, long_name ? longname : shortname);
+	cue_single(&cd_disc, cd_filename, cdrom.hdf.file.size);
+	atapi_insert(&cdrom.unit, &cd_disc, long_name ? longname : shortname);
 	cd_config(shortname, long_name ? longname : 0, dir);
 	if (DebugMode)
 		printf("CD: insert %s (%s), %lu sectors\r\n", cd_filename, cdrom.unit.name, (unsigned long)cdrom.unit.sectors);
--- a/fw/ctrl_832/Makefile
+++ b/fw/ctrl_832/Makefile
@@ -59,7 +59,7 @@
 	$(BUILD_DIR)/osd.o $(BUILD_DIR)/rafile.o $(BUILD_DIR)/swap.o $(BUILD_DIR)/hexdump.o $(BUILD_DIR)/uart.o $(BUILD_DIR)/errors.o \
 	$(BUILD_DIR)/audiotrack.o $(BUILD_DIR)/bincue.o $(BUILD_DIR)/interrupts.o $(BUILD_DIR)/c64keys.o $(BUILD_DIR)/akiko.o \
 	$(BUILD_DIR)/audio.o $(BUILD_DIR)/drivesounds.o $(BUILD_DIR)/rtc.o $(BUILD_DIR)/i2c.o $(BUILD_DIR)/adv7511.o \
-	$(BUILD_DIR)/atapi.o $(BUILD_DIR)/cdrom.o
+	$(BUILD_DIR)/atapi.o $(BUILD_DIR)/cdrom.o $(BUILD_DIR)/cue.o
 
 
 # all sources
```

- [ ] **Step 4: Run, expected PASS**

```bash
make -C fw/ctrl_832/test
make -C fw/ctrl_832/test/emu 832DIR=/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64/EightThirtyTwo
```

Expected: `11 cases: 11 passed` (cue_test), `21 cases: 21 passed, 0 failed, 0 skipped` (atapi_test), `20 cases: 20 passed` (cdrom_test); emu `PASS` twice (atapi_emu now checks the reference TOC bytes and the 05/64/00 on LBA 2358 as vbcc832 builds them).

- [ ] **Step 5: Commit**

```bash
git add fw/ctrl_832/atapi.h fw/ctrl_832/atapi.c fw/ctrl_832/cdrom.c fw/ctrl_832/Makefile \
        fw/ctrl_832/test/atapi_test.c fw/ctrl_832/test/Makefile fw/ctrl_832/test/emu/atapi_emu.c \
        fw/ctrl_832/test/emu/Makefile
git commit -F- <<'EOF'
fw/ctrl_832: ATAPI commands from the disc model: multi-track TOC, audio sectors refused

findings/cdrom/plan.md 13.6: atapi_insert takes a disc model (an ISO is
one DATA2048 track, cue_single).  READ TOC lists every track (control
0x14 data / 0x10 audio); READ CAPACITY, DISC and TRACK INFORMATION follow
the model; READ(10)/(12) of an audio sector or its gap is 05/64/00.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
EOF
```

### Task 4: CUE insert, FILE lookup, data reads across tracks (`cdrom.c`)

**Files:**
- Modify: `fw/ctrl_832/cdrom.h` (`CD_BADCUE`, `CD_PRESENT_ISO/CUE`, `CD_PRESENT()`, `CD_Insert` takes an 11-character 8.3 name, `CD_Message`), `fw/ctrl_832/cdrom.c` (state, `CD_Open`, `cd_raopen`, `cd_name83`, `cd_lookup_read`, `cd_cue_open`, `cd_parse_cue`, `cd_data_open`, `CD_Message`, `CD_Insert`, `cd_drop_file`, `cd_read_error`, `cd_send_sectors`, `cd_file_read`, `cd_send_raw`, `cd_send_zero`, `cd_read`)
- Test: `fw/ctrl_832/test/cdrom_test.c` (a fake card of ISO, BIN, WAV and CUE files; FileOpen/FileRead/RAOpen/RARead/RASeek fakes; 6 new cases)

**Interfaces:**
- Consumes: everything of tasks 1-3; fat.c `FileOpen`, `FileRead`, `FileReadEx`, `ChangeDirectory`, `ValidateDirectory`, globals `iCurrentDirectory`, `iPreviousDirectory`; rafile.c `RAOpen`, `RARead`, `RASeek`; hdd.c `HardFileSeek`, `BuildHardfileIndex`; errors.c `ClearError`.
- Produces: `#define CD_BADCUE 3`, `CD_PRESENT_ISO 1`, `CD_PRESENT_CUE 2`, `CD_PRESENT(name83)`; `int CD_Insert(const char *name83, const char *long_name, unsigned long dir)` (name = `fileTYPE.name`, 11 characters, no dot); `const char *CD_Message(void)` (at most 23 characters, "" when the last insert was not refused); static `cd_disc`, `cd_dir`, `cd_data_file`, `cd_block[512]`, `cd_data_open(f)`, `cd_file_read(off, dst, len)`, `cd_read(port, tfr, lba, count, limit)` (tasks 9 and 11 build on them).

- [ ] **Step 1: Write the failing tests**

```diff
--- a/fw/ctrl_832/test/cdrom_test.c
+++ b/fw/ctrl_832/test/cdrom_test.c
@@ -19,8 +19,10 @@
  *   status         reason 3 (IO|CoD), END + IRQ, ERR and the error
  *                  register from the sense
  *
- * The ISO is synthetic: byte i of sector n is (n * 7 + i) & 0xff, with
- * the sector number in its first four bytes.
+ * The SD card is a table of fake files (fake_dir): the ISO is synthetic,
+ * byte i of sector n is (n * 7 + i) & 0xff with the sector number in its
+ * first four bytes; a BIN carries the same user data in raw 2352-byte
+ * MODE1 sectors, then audio; CUE sheets are text (phase 3, task 4).
  */
 
 #include <stdio.h>
@@ -33,7 +35,10 @@
 #include "hdd.h"
 #include "config.h"
 #include "fpga.h"
+#include "errors.h"
+#include "rafile.h"
 #include "atapi.h"
+#include "cue.h"
 #include "cdrom.h"
 
 /* ---- bookkeeping ---- */
@@ -86,14 +91,17 @@
 unsigned long GetTimer(unsigned long offset) { return (now_ms + offset) << 16; }
 unsigned long CheckTimer(unsigned long t) { return ((t - (now_ms << 16)) & 0x80000000) ? 1 : 0; }
 
-/* ---- the ISO and the FAT fakes ---- */
+/* ---- the SD card: fake files and the FAT fakes ---- */
 
 #define ISO_SECTORS 64
+#define BIN_SECTORS 40		/* Game.bin: 20 MODE1/2352 data sectors, then audio */
+#define WAV_SECTORS 10
 static char iso_name[12] = "TESTDISCISO";	/* 8.3 without the dot */
 static unsigned long iso_dir = 0x1234;
-static unsigned long file_pos512;		/* HardFileSeek / FileReadEx position */
 static int fail_read_at = -1;			/* FileReadEx fails on this call */
 static int reads;
+unsigned long iCurrentDirectory, iPreviousDirectory;
+static int clear_errors;			/* ClearError(ERROR_FILESYSTEM) calls */
 
 static uint8_t iso_byte(unsigned long pos)
 {
@@ -103,25 +111,195 @@
 	return (uint8_t)(n * 7 + i);
 }
 
+/* Raw sectors: 0..19 MODE1 (16-byte header, the ISO's user data for that
+   sector number, 288 bytes of EDC/ECC 0xEE), 20.. audio bytes. */
+static uint8_t bin_byte(unsigned long pos)
+{
+	unsigned long n = pos / 2352, i = pos % 2352;
+	if (n >= 20)
+		return (uint8_t)(pos * 3 + 1);
+	if (i < 16)
+		return (uint8_t)((i >= 1 && i <= 10) ? 0xFF : (i == 15 ? 0x01 : 0x00));
+	if (i < 16 + 2048)
+		return iso_byte(n * ATAPI_SECTOR_SIZE + i - 16);
+	return 0xEE;
+}
+
+/* WAV files: a 44-byte header (PCM, channels x 44100 x 16), then samples. */
+static uint8_t wav_header[44], mono_header[44];
+
+static void make_wav_header(uint8_t *h, uint32_t data_bytes, uint16_t channels)
+{
+	static const uint8_t fmt[16] = { 1, 0, 2, 0, 0x44, 0xAC, 0, 0, 0x10, 0xB1, 2, 0, 4, 0, 16, 0 };
+	uint32_t riff = data_bytes + 36;
+	int i;
+	memcpy(h, "RIFF", 4);
+	for (i = 0; i < 4; i++) {
+		h[4 + i] = (uint8_t)(riff >> (8 * i));
+		h[40 + i] = (uint8_t)(data_bytes >> (8 * i));
+	}
+	memcpy(h + 8, "WAVEfmt ", 8);
+	h[16] = 16;
+	h[17] = h[18] = h[19] = 0;
+	memcpy(h + 20, fmt, 16);
+	h[22] = (uint8_t)channels;
+	memcpy(h + 36, "data", 4);
+}
+
+static uint8_t wav_byte(unsigned long pos)
+{
+	return pos < 44 ? wav_header[pos] : (uint8_t)((pos - 44) * 5);
+}
+
+static uint8_t mono_byte(unsigned long pos)
+{
+	return pos < 44 ? mono_header[pos] : 0;
+}
+
+static const char game_cue[] =
+	"FILE \"Game.bin\" BINARY\r\n"
+	"  TRACK 01 MODE1/2352\r\n"
+	"    INDEX 01 00:00:00\r\n"
+	"  TRACK 02 AUDIO\r\n"
+	"    INDEX 00 00:00:20\r\n"
+	"    INDEX 01 00:00:22\r\n";
+static const char mixed_cue[] =
+	"FILE \"Mixed (Track 1).iso\" BINARY\n"
+	"  TRACK 01 MODE1/2048\n"
+	"    INDEX 01 00:00:00\n"
+	"FILE \"Mixed (Track 2).wav\" WAVE\n"
+	"  TRACK 02 AUDIO\n"
+	"    PREGAP 00:02:00\n"
+	"    INDEX 01 00:00:00\n";
+static const char twodata_cue[] =	/* a data read crosses a POSTGAP into another file */
+	"FILE \"Mixed (Track 1).iso\" BINARY\n"
+	"  TRACK 01 MODE1/2048\n"
+	"    INDEX 01 00:00:00\n"
+	"    POSTGAP 00:00:02\n"
+	"FILE \"Game.bin\" BINARY\n"
+	"  TRACK 02 MODE1/2352\n"
+	"    INDEX 01 00:00:00\n";
+static const char lower_cue[] = "FILE \"lower.bin\" BINARY\n TRACK 01 MODE1/2352\n INDEX 01 00:00:00\n";
+static const char broken_cue[] = "FILE \"Nothere.wav\" WAVE\n TRACK 01 AUDIO\n INDEX 01 00:00:00\n";
+static const char badcmd_cue[] = "FILE \"Game.bin\" BINARY\n TRACK 01 MODE1/2352\n INDEX 01 00:00:00\nBOGUS 1\n";
+static const char mono_cue[] = "FILE \"Mono.wav\" WAVE\n TRACK 01 AUDIO\n INDEX 01 00:00:00\n";
+
+struct fake_file {
+	const char *short11;		/* 8.3 without the dot */
+	const char *long_name;		/* LFN, 0 = none (an 8.3 name written in lower case) */
+	unsigned long size;		/* ignored for text files */
+	uint8_t (*byte)(unsigned long pos);
+	const char *text;		/* a CUE sheet */
+};
+
+static const struct fake_file fake_dir[] = {
+	{ "TESTDISCISO", "Test Disc.iso", ISO_SECTORS * ATAPI_SECTOR_SIZE, iso_byte, 0 },
+	{ "GAME    CUE", "Game.cue", 0, 0, game_cue },
+	{ "GAME    BIN", "Game.bin", BIN_SECTORS * 2352, bin_byte, 0 },
+	{ "MIXED   CUE", "Mixed.cue", 0, 0, mixed_cue },
+	{ "MIXED~1 ISO", "Mixed (Track 1).iso", ISO_SECTORS * ATAPI_SECTOR_SIZE, iso_byte, 0 },
+	{ "MIXED~2 WAV", "Mixed (Track 2).wav", 44 + WAV_SECTORS * 2352, wav_byte, 0 },
+	{ "TWODATA CUE", "Twodata.cue", 0, 0, twodata_cue },
+	{ "LOWER   CUE", 0, 0, 0, lower_cue },
+	{ "LOWER   BIN", 0, 4 * 2352, bin_byte, 0 },
+	{ "BROKEN  CUE", "Broken.cue", 0, 0, broken_cue },
+	{ "BADCMD  CUE", "Badcmd.cue", 0, 0, badcmd_cue },
+	{ "MONOCUE CUE", "Monocue.cue", 0, 0, mono_cue },
+	{ "MONO    WAV", "Mono.wav", 44 + 2352, mono_byte, 0 },
+	{ 0, 0, 0, 0, 0 }
+};
+
+static unsigned long fake_size(const struct fake_file *f)
+{
+	return f->text ? strlen(f->text) : f->size;
+}
+
+/* fileTYPE.start_cluster = index + 1 of the fake file (0 = none). */
+static const struct fake_file *fake_of(const fileTYPE *file)
+{
+	return file->start_cluster ? &fake_dir[file->start_cluster - 1] : 0;
+}
+
+static uint8_t fake_byte(const struct fake_file *f, unsigned long pos)
+{
+	if (pos >= fake_size(f))
+		return 0;
+	return f->text ? (uint8_t)f->text[pos] : f->byte(pos);
+}
+
+static void fake_read(const fileTYPE *file, unsigned long pos, uint8_t *dst, unsigned long len)
+{
+	const struct fake_file *f = fake_of(file);
+	unsigned long i;
+	for (i = 0; i < len; i++)
+		dst[i] = f ? fake_byte(f, pos + i) : 0;
+}
+
 int ValidateDirectory(unsigned long directory) { return directory == iso_dir || directory == 0; }
-void ChangeDirectory(unsigned long iStartCluster) { (void)iStartCluster; }
 
+void ChangeDirectory(unsigned long iStartCluster)
+{
+	iPreviousDirectory = iCurrentDirectory;
+	iCurrentDirectory = iStartCluster;
+}
+
+void ClearError(int category)
+{
+	if (category == ERROR_FILESYSTEM)
+		clear_errors++;
+}
+
+/* As fat.c: a long name matches on its first strlen(name) characters, the
+   8.3 name on 11. */
 unsigned char FileOpen(fileTYPE *file, const char *name)
 {
-	if (memcmp(name, iso_name, 11) != 0)
-		return 0;
-	memcpy(file->name, name, 11);
-	file->size = ISO_SECTORS * ATAPI_SECTOR_SIZE;
-	file->sector = 0;
-	return 1;
+	int i;
+	EXPECT(iCurrentDirectory == iso_dir, "FileOpen(%s) outside the disc's directory (%lx)", name, iCurrentDirectory);
+	memset(file, 0, sizeof(*file));
+	for (i = 0; fake_dir[i].short11; i++) {
+		const struct fake_file *f = &fake_dir[i];
+		if ((f->long_name && strncmp(f->long_name, name, strlen(name)) == 0) || strncmp(f->short11, name, 11) == 0) {
+			memcpy(file->name, f->short11, 11);
+			file->size = fake_size(f);
+			file->start_cluster = (unsigned long)i + 1;
+			return 1;
+		}
+	}
+	return 0;
 }
 
 void BuildHardfileIndex(hdfTYPE *h) { (void)h; }
 
 unsigned char HardFileSeek(hdfTYPE *h, unsigned long lba)
 {
-	(void)h;
-	file_pos512 = lba;
+	h->file.sector = lba;
+	return 1;
+}
+
+unsigned char FileRead(fileTYPE *file, unsigned char *pBuffer)
+{
+	fake_read(file, file->sector * 512, pBuffer, 512);
+	return 1;
+}
+
+int RAOpen(RAFile *f, const char *name)
+{
+	int ok = FileOpen(&f->file, name);
+	f->size = f->file.size;
+	f->ptr = 0;
+	return ok;
+}
+
+int RASeek(RAFile *f, unsigned long offset, unsigned long origin)
+{
+	f->ptr = origin == SEEK_CUR ? f->ptr + offset : offset;
+	return 1;
+}
+
+int RARead(RAFile *f, unsigned char *pBuffer, unsigned long bytes)
+{
+	fake_read(&f->file, f->ptr, pBuffer, bytes);
+	f->ptr += bytes;
 	return 1;
 }
 
@@ -343,15 +521,16 @@
 
 unsigned char FileReadEx(fileTYPE *file, unsigned char *pBuffer, unsigned long nSize)
 {
+	const struct fake_file *f = fake_of(file);
 	unsigned long i;
-	(void)file;
 	if (reads++ == fail_read_at)
 		return 0;
 	EXPECT(pBuffer == 0, "FileReadEx into a buffer, not the direct transfer");
 	EXPECT(g.pio_in, "direct transfer without pio in");
+	EXPECT(f && f->byte == iso_byte, "direct transfer from %s, not a 2048-byte-sector file", f ? f->short11 : "nothing");
 	for (i = 0; i < nSize * 512 && g.fifo_len < sizeof(g.fifo); i++)
-		g.fifo[g.fifo_len++] = iso_byte(file_pos512 * 512 + i);
-	file_pos512 += nSize;
+		g.fifo[g.fifo_len++] = f ? fake_byte(f, file->sector * 512 + i) : 0;
+	file->sector += nSize;
 	return 1;
 }
 
@@ -782,8 +961,166 @@
 	end();
 }
 
+/* ---- phase 3: CUE sheets ---- */
+
+/* An empty drive, then this disc from the fake card; its UNIT ATTENTION
+   consumed when it went in. */
+static int insert_disc(const char *name11, const char *long_name)
+{
+	uint8_t c[12];
+	int r;
+	fresh_drive(0);
+	r = CD_Insert(name11, long_name, iso_dir);
+	if (r == CD_OK) {
+		cdb6(c, 0x00, 0);
+		packet(c, 0xFFFE);
+		host_reset_model();
+	}
+	return r;
+}
+
+static void t_cue_bincue(void)
+{
+	uint8_t c[12];
+	begin("CUE + BIN (MODE1/2352, audio): user data from byte 16, a block per sector; audio 05/64/00");
+	EXPECT(insert_disc("GAME    CUE", "Game") == CD_OK, "insert refused: '%s'", CD_Message());
+	EXPECT(cdrom.unit.media && cdrom.unit.sectors == BIN_SECTORS, "sectors %u", (unsigned)cdrom.unit.sectors);
+	EXPECT(strcmp(cdrom.unit.name, "Game") == 0, "name '%s'", cdrom.unit.name);
+	EXPECT(memcmp(config.secondaryhardfile[0].name, "GAME    ", 8) == 0 &&
+	       config.secondaryhardfile[0].present == CD_PRESENT_CUE, "config: '%.8s' present %u",
+	       config.secondaryhardfile[0].name, config.secondaryhardfile[0].present);
+	EXPECT(memcmp(cdrom.hdf.file.name, "GAME    BIN", 11) == 0, "data file '%.11s'", cdrom.hdf.file.name);
+	read10(c, 0, 3);
+	packet(c, 0xFFFE);
+	EXPECT(h.phase_errors == 0, "phase errors");
+	EXPECT(h.blocks == 3 && h.block_bytes[0] == 2048 && h.block_bytes[2] == 2048, "blocks %d", h.blocks);
+	EXPECT(h.in_len == 3 * 2048 && iso_matches(0, 3 * 2048), "user data of sectors 0-2");
+	EXPECT(good_end(), "status phase");
+	read10(c, 18, 2);
+	packet(c, 0xFFFE);
+	EXPECT(h.in_len == 2 * 2048 && iso_matches(18, 2 * 2048) && good_end(), "sectors 18-19");
+	read10(c, 5, 1);
+	packet(c, 0x0400);
+	EXPECT(h.phase_errors == 0 && h.blocks == 2 && h.block_bytes[1] == 1024 && iso_matches(5, 2048) && good_end(),
+	       "a 1 KB limit: blocks %d", h.blocks);
+	read10(c, 19, 2);	/* sector 20 is track 2's INDEX 00 */
+	packet(c, 0xFFFE);
+	EXPECT(h.blocks == 0 && check_end(0x54), "into the audio track: blocks %d error %02X", h.blocks, g.reg[1]);
+	end();
+}
+
+static void t_cue_mixed(void)
+{
+	static const uint8_t toc[28] = {
+		0x00, 0x1A, 0x01, 0x02,
+		0x00, 0x14, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
+		0x00, 0x10, 0x02, 0x00, 0x00, 0x00, 0x00, 214,
+		0x00, 0x10, 0xAA, 0x00, 0x00, 0x00, 0x00, 224
+	};
+	uint8_t c[12];
+	begin("CUE + ISO + WAV by long name: ISO sectors on the direct path, TOC with the audio track");
+	EXPECT(insert_disc("MIXED   CUE", "Mixed") == CD_OK, "insert refused: '%s'", CD_Message());
+	EXPECT(cdrom.unit.sectors == ISO_SECTORS + 150 + WAV_SECTORS, "sectors %u", (unsigned)cdrom.unit.sectors);
+	read10(c, 60, 4);
+	packet(c, 0xFFFE);
+	EXPECT(h.phase_errors == 0 && h.blocks == 1 && h.block_bytes[0] == 8192, "blocks %d first %u", h.blocks, h.block_bytes[0]);
+	EXPECT(h.in_len == 8192 && iso_matches(60, 8192) && good_end(), "sectors 60-63");
+	memset(c, 0, 12);
+	c[0] = 0x43;
+	c[7] = 0x00;
+	c[8] = 0xFF;
+	packet(c, 0xFFFE);
+	EXPECT(h.in_len == 28 && memcmp(h.in, toc, 28) == 0 && good_end(), "TOC: %u bytes, track 2 %02X/%u",
+	       h.in_len, h.in[13], h.in[19]);
+	read10(c, 64, 1);	/* track 2's PREGAP */
+	packet(c, 0xFFFE);
+	EXPECT(check_end(0x54), "audio gap read: error %02X", g.reg[1]);
+	end();
+}
+
+static void t_cue_split(void)
+{
+	uint8_t c[12];
+	unsigned i;
+	int zeros = 1, raw = 1;
+	begin("a READ across a POSTGAP into another file: ISO direct, zeros, BIN user data; the data file follows");
+	EXPECT(insert_disc("TWODATA CUE", "Two") == CD_OK, "insert refused: '%s'", CD_Message());
+	EXPECT(cdrom.unit.sectors == ISO_SECTORS + 2 + BIN_SECTORS, "sectors %u", (unsigned)cdrom.unit.sectors);
+	read10(c, 62, 6);
+	packet(c, 0xFFFE);
+	EXPECT(h.phase_errors == 0, "phase errors");
+	EXPECT(h.blocks == 5 && h.block_bytes[0] == 4096 && h.block_bytes[1] == 2048 && h.block_bytes[4] == 2048,
+	       "blocks %d: %u %u", h.blocks, h.block_bytes[0], h.block_bytes[1]);
+	EXPECT(h.in_len == 6 * 2048 && iso_matches(62, 4096), "ISO sectors 62-63");
+	for (i = 0; i < 4096; i++) {
+		if (h.in[4096 + i])
+			zeros = 0;
+		if (h.in[8192 + i] != iso_byte(i))
+			raw = 0;
+	}
+	EXPECT(zeros, "POSTGAP sectors not zero");
+	EXPECT(raw, "BIN sectors 0-1 user data");
+	EXPECT(good_end(), "status phase");
+	EXPECT(memcmp(cdrom.hdf.file.name, "GAME    BIN", 11) == 0, "data file '%.11s'", cdrom.hdf.file.name);
+	read10(c, 1, 1);
+	packet(c, 0xFFFE);
+	EXPECT(memcmp(cdrom.hdf.file.name, "MIXED~1 ISO", 11) == 0 && iso_matches(1, 2048) && good_end(),
+	       "back to the ISO: '%.11s'", cdrom.hdf.file.name);
+	end();
+}
+
+static void t_cue_names(void)
+{
+	begin("CUE FILE names: an 8.3 name in lower case (no long name entry) is found");
+	EXPECT(insert_disc("LOWER   CUE", 0) == CD_OK, "insert refused: '%s'", CD_Message());
+	EXPECT(cdrom.unit.sectors == 4, "sectors %u", (unsigned)cdrom.unit.sectors);
+	EXPECT(strcmp(cdrom.unit.name, "LOWER   ") == 0, "name '%s'", cdrom.unit.name);
+	EXPECT(memcmp(cdrom.hdf.file.name, "LOWER   BIN", 11) == 0, "data file '%.11s'", cdrom.hdf.file.name);
+	end();
+}
+
+static void t_cue_refusals(void)
+{
+	begin("refused CUEs: the cause for the OSD, an empty drive, no config, the OSD's directory untouched");
+	clear_errors = 0;
+	iCurrentDirectory = 0x777;
+	iPreviousDirectory = 0x666;
+	EXPECT(insert_disc("BROKEN  CUE", "Broken") == CD_BADCUE, "a missing FILE accepted");
+	EXPECT(strcmp(CD_Message(), "line 1: file missing") == 0, "message '%s'", CD_Message());
+	EXPECT(!cdrom.unit.media && cdrom.hdf.type == HDF_DISABLED, "half a disc in the drive");
+	EXPECT(config.secondaryhardfile[0].name[0] == 0 && !config.secondaryhardfile[0].present, "config names the refused disc");
+	EXPECT(clear_errors > 0, "the failed lookup left a filesystem error for the OSD");
+	EXPECT(iCurrentDirectory == 0x777 && iPreviousDirectory == 0x666, "directory state %lx %lx",
+	       iCurrentDirectory, iPreviousDirectory);
+	EXPECT(insert_disc("BADCMD  CUE", "Badcmd") == CD_BADCUE && strcmp(CD_Message(), "line 4: unknown cmd") == 0,
+	       "unknown command: '%s'", CD_Message());
+	EXPECT(insert_disc("MONOCUE CUE", "Mono") == CD_BADCUE && strcmp(CD_Message(), "line 1: WAV format") == 0,
+	       "mono WAV: '%s'", CD_Message());
+	EXPECT(insert_disc("NOSUCH  CUE", "Nope") == CD_NOFILE && CD_Message()[0] == 0, "missing CUE: '%s'", CD_Message());
+	EXPECT(insert_disc("GAME    CUE", "Game") == CD_OK && CD_Message()[0] == 0, "a good CUE after: '%s'", CD_Message());
+	end();
+}
+
+static void t_cue_config(void)
+{
+	begin("CD_Open from the config: present = CD_PRESENT_CUE opens NAME.CUE");
+	memset(&config, 0, sizeof(config));
+	config.secondaryhardfile[0].enabled = HDF_CDROM;
+	memcpy(config.secondaryhardfile[0].name, "GAME    ", 8);
+	strcpy(config.secondaryhardfile[0].long_name, "Game");
+	config.secondaryhardfile[0].present = CD_PRESENT_CUE;
+	config.hdfdir[2] = iso_dir;
+	EXPECT(CD_Open(2) == CD_OK, "CD_Open refused: '%s'", CD_Message());
+	EXPECT(cdrom.unit.media && cdrom.unit.sectors == BIN_SECTORS, "sectors %u", (unsigned)cdrom.unit.sectors);
+	EXPECT(config.secondaryhardfile[0].present == CD_PRESENT_CUE, "present %u", config.secondaryhardfile[0].present);
+	end();
+}
+
 int main(void)
 {
+	make_wav_header(wav_header, WAV_SECTORS * 2352, 2);
+	make_wav_header(mono_header, 2352, 1);
+
 	t_open();
 	t_inquiry();
 	t_limit_split();
@@ -804,6 +1141,12 @@
 	t_timeout();
 	t_read_error();
 	t_reset_flag();
+	t_cue_bincue();
+	t_cue_mixed();
+	t_cue_split();
+	t_cue_names();
+	t_cue_refusals();
+	t_cue_config();
 
 	printf("\n%d cases: %d passed, %d failed (%d failed checks)\n",
 	       cases_run, cases_passed, cases_run - cases_passed, total_fails);
```

- [ ] **Step 2: Run, expected FAIL**

```bash
make -C fw/ctrl_832/test
```

Expected (first lines):

```
cdrom_test.c:986:85: error: implicit declaration of function ‘CD_Message’; did you mean ‘cue_message’? [-Werror=implicit-function-declaration]
cdrom_test.c:990:55: error: ‘CD_PRESENT_CUE’ undeclared (first use in this function)
cdrom_test.c:1088:56: error: ‘CD_BADCUE’ undeclared (first use in this function)
```

- [ ] **Step 3: Implementation**

```diff
--- a/fw/ctrl_832/cdrom.h
+++ b/fw/ctrl_832/cdrom.h
@@ -2,14 +2,12 @@
 #define CDROM_H
 
 /*
- * CD-ROM board glue (findings/cdrom/plan.md 7.4): the ISO file behind the
- * ATAPI unit of atapi.c, and the Gayle side of the commands.
- *
- * Phase 0: compiled and linked, not called from anywhere.
- * CD_HandleCommand is a stub until task 1.4 (it needs the two-port Gayle
- * with packet mode of phase 1).
+ * CD-ROM board glue (findings/cdrom/plan.md 7.4, 13.5): the disc behind the
+ * ATAPI unit of atapi.c -- an ISO, or a CUE sheet with its BIN / ISO / WAV
+ * files -- and the Gayle side of the commands.
  */
 
+#include <string.h>
 #include "fat.h"
 #include "hdd.h"
 #include "atapi.h"
@@ -18,16 +16,24 @@
 #define CD_OK      ATAPI_OK
 #define CD_LOCKED  ATAPI_LOCKED	/* the Amiga locked the drive (D5) */
 #define CD_NOFILE  2		/* bad directory or file not found */
+#define CD_BADCUE  3		/* the CUE sheet was refused: CD_Message() says why */
+
+/* hardfileTYPE.present of the CD slot: which disc the 8-character config
+   name is (the config has no room for the extension, phase3-plan.md spec
+   issue 1).  0 = no disc. */
+#define CD_PRESENT_ISO 1
+#define CD_PRESENT_CUE 2
+#define CD_PRESENT(name83) (memcmp((name83) + 8, "CUE", 3) == 0 ? CD_PRESENT_CUE : CD_PRESENT_ISO)
 
 typedef struct
 {
-	hdfTYPE           hdf;	/* the ISO: file + cluster index; sector n = HardFileSeek(&hdf, 4*n) */
+	hdfTYPE           hdf;	/* the disc file being read (a CUE's data track's file): file + cluster index */
 	struct atapi_unit unit;
 	int               slot;	/* IDE slot (port << 1 | slave), valid while active */
 	unsigned char     active;	/* a CD drive is configured (BSS zero: none) */
 } cdromTYPE;
 
-extern cdromTYPE cdrom;	/* not "cd": main.c has a struct cdimage cd (bincue) */
+extern cdromTYPE cdrom;
 
 /* The CD drive's IDE slot, -1 when there is none. */
 #define CD_SLOT() (cdrom.active ? cdrom.slot : -1)
@@ -36,11 +42,17 @@
    slot -1: no CD drive.  Returns CD_OK or CD_NOFILE. */
 int CD_Open(int slot);
 
-/* OSD insert or swap.  name: 8-character short name without extension, as
-   in hardfileTYPE; long_name: the ISO's long name (IDENTIFY / INQUIRY, D7),
-   may be NULL.  Refused with CD_LOCKED while the Amiga holds the lock. */
+/* OSD insert or swap.  name: the 8.3 name as in fileTYPE.name (11
+   characters, no dot): "xxxxxxxxISO" or "xxxxxxxxCUE"; long_name: the long
+   name without extension (IDENTIFY / INQUIRY, D7), may be NULL.  Refused
+   with CD_LOCKED while the Amiga holds the lock; CD_NOFILE when the ISO /
+   CUE is not there; CD_BADCUE when the CUE or one of its files is refused
+   (CD_Message()).  The drive is empty after any refusal but CD_LOCKED. */
 int CD_Insert(const char *name, const char *long_name, unsigned long dir);
 
+/* Why the last CD_Insert was refused, at most 23 characters ("" if it was not). */
+const char *CD_Message(void);
+
 /* OSD eject.  CD_LOCKED while the Amiga holds the lock, nothing changes. */
 int CD_Eject(void);
 
--- a/fw/ctrl_832/cdrom.c
+++ b/fw/ctrl_832/cdrom.c
@@ -1,7 +1,9 @@
 /*
- * CD-ROM board glue -- see cdrom.h and findings/cdrom/plan.md 7.1, 7.4, 9.
+ * CD-ROM board glue -- see cdrom.h and findings/cdrom/plan.md 7.1, 7.4, 9, 13.5.
  *
  * The ATAPI unit of atapi.c on one IDE slot of the two-port Gayle.  The
+ * disc is a model (cue.h): an ISO is one DATA2048 track, a CUE sheet is
+ * parsed at insert and each of its FILEs looked up in the CUE's directory.  The
  * Gayle port runs in packet mode (gayle_port.v): each data phase is set up
  * with WriteXfer (length in words), the task file (interrupt reason, byte
  * count) and a status write for the direction; the port raises DRQ and the
@@ -29,13 +31,26 @@
 #include "fat.h"
 #include "hdd.h"
 #include "config.h"
+#include "errors.h"
+#include "rafile.h"
 #include "atapi.h"
+#include "cue.h"
 #include "cdrom.h"
 
+/* fat.c's directory state: lookups in the disc's directory put it back, so
+   the OSD file browser does not move (or lose its ".." position). */
+extern unsigned long iCurrentDirectory, iPreviousDirectory;
+
 cdromTYPE cdrom;
 
-static struct cd_disc cd_disc;		/* the disc in the drive (an ISO: one track) */
-static char cd_filename[12];
+static struct cd_disc cd_disc;		/* the disc in the drive */
+static struct cue_parser cd_cue;	/* 2.5 KB: static, the 832 stack is small */
+static RAFile cd_cuefile;		/* the CUE text */
+static RAFile cd_lookup;		/* each FILE of the CUE: its size, a WAV's header */
+static unsigned long cd_dir;		/* the directory of the disc's files */
+static int cd_data_file = -1;		/* the disc file open in cdrom.hdf, -1 = none */
+static unsigned char cd_block[512];	/* one FAT sector: the raw-sector paths */
+static char cd_msg[24];			/* why the last insert was refused */
 static unsigned short cd_id[256];	/* IDENTIFY PACKET DEVICE words */
 static unsigned char cd_cdb[12];
 
@@ -57,9 +72,9 @@
 	hf = SlotConfig(cdrom.slot);
 	memset(hf->name, 0, sizeof(hf->name));
 	memset(hf->long_name, 0, sizeof(hf->long_name));
-	hf->present = name ? 1 : 0;
+	hf->present = name ? CD_PRESENT(name) : 0;
 	if (name) {
-		memcpy(hf->name, name, sizeof(hf->name));
+		memcpy(hf->name, name, sizeof(hf->name));	/* 8 characters: the extension is in present */
 		if (long_name)
 			strncpy(hf->long_name, long_name, sizeof(hf->long_name));
 		config.hdfdir[cdrom.slot] = dir;
@@ -71,37 +86,174 @@
 int CD_Open(int slot)
 {
 	hardfileTYPE *hf;
-	char name[9];
+	char name[12];
 	char long_name[sizeof(hf->long_name) + 1];
 
 	cdrom.hdf.type = HDF_DISABLED;
+	cd_data_file = -1;
 	cdrom.slot = slot;
 	cdrom.active = slot >= 0 && slot < HDD_SLOTS;
 	atapi_init(&cdrom.unit);
 	if (!cdrom.active)
 		return CD_OK;
 	hf = SlotConfig(slot);
+	/* config names are fixed-width, not always terminated; present says
+	   whether the 8 characters name an ISO or a CUE */
+	memcpy(name, hf->name, 8);
+	memcpy(name + 8, hf->present == CD_PRESENT_CUE ? "CUE" : "ISO", 3);
+	name[11] = 0;
 	hf->present = 0;
 	if (!hf->name[0])
 		return CD_OK;	/* CD slot, no disc */
-	/* config names are fixed-width, not always terminated */
-	memcpy(name, hf->name, 8);
-	name[8] = 0;
 	memcpy(long_name, hf->long_name, sizeof(hf->long_name));
 	long_name[sizeof(hf->long_name)] = 0;
 	return CD_Insert(name, long_name[0] ? long_name : 0, config.hdfdir[slot]);
 }
 
+/* ---- the disc's files ---- */
+
+/* RAOpen in the disc's directory, leaving fat.c's directory state alone.
+   A failed lookup is the insert's refusal, not a filesystem error for the
+   OSD's error page. */
+static int cd_raopen(RAFile *f, const char *name)
+{
+	unsigned long cur = iCurrentDirectory, prev = iPreviousDirectory;
+	int ok;
+	ChangeDirectory(cd_dir);
+	ok = RAOpen(f, name);
+	iCurrentDirectory = cur;
+	iPreviousDirectory = prev;
+	if (!ok)
+		ClearError(ERROR_FILESYSTEM);
+	return ok;
+}
+
+/* name as an 8.3 directory name ("game.bin" -> "GAME    BIN"), 0 when it
+   is not one (a long name).  An 8.3 name written in lower case has no long
+   name entry on a FAT card (Linux, Windows), so FileOpen's long-name match
+   cannot find it.  Loops in the "for (;;) / break" form (cue.c). */
+static int cd_name83(const char *name, char *out)
+{
+	int i = 0, n = 0, dot = 0;
+	memset(out, ' ', 11);
+	out[11] = 0;
+	for (;;) {
+		char c = name[i];
+		if (!c)
+			break;
+		if (c == '.') {
+			if (dot || i == 0)
+				return 0;
+			dot = 1;
+			n = 8;
+		} else {
+			if (c >= 'a' && c <= 'z')
+				c = (char)(c - 32);
+			if (!((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '~' ||
+			      c == '!' || c == '#' || c == '$' || c == '%' || c == '&' || c == '(' || c == ')'))
+				return 0;
+			if (n == (dot ? 11 : 8))
+				return 0;
+			out[n++] = c;
+		}
+		i++;
+	}
+	return i > 0;
+}
+
+/* cue_wav's reader: the WAV opened in cd_lookup. */
+static int32_t cd_lookup_read(void *ctx, uint32_t offset, uint8_t *dst, uint32_t len)
+{
+	if (!RASeek(&cd_lookup, offset, SEEK_SET))
+		return 0;
+	return RARead(&cd_lookup, dst, len) ? 1 : 0;
+}
+
+/* The parser's FILE callback: find the file by its 8.3 or long name,
+   keep the 8.3 name, read a WAV's header. */
+static int32_t cd_cue_open(void *ctx, const char *name, struct cd_file *f)
+{
+	char n83[12];
+	int ok = 0;
+	if (cd_name83(name, n83))
+		ok = cd_raopen(&cd_lookup, n83);
+	if (!ok)
+		ok = cd_raopen(&cd_lookup, name);	/* FileOpen: long-name match */
+	if (!ok)
+		return CUE_E_NOFILE;
+	memcpy(f->shortname, cd_lookup.file.name, 11);
+	f->shortname[11] = 0;
+	if (!f->wave) {
+		f->data_offset = 0;
+		f->data_bytes = cd_lookup.size;
+		return CUE_OK;
+	}
+	return cue_wav(cd_lookup_read, 0, cd_lookup.size, f);
+}
+
+/* Parse the CUE opened in cd_cuefile into cd_disc. */
+static int32_t cd_parse_cue(void)
+{
+	unsigned long left = cd_cuefile.size;
+	cue_begin(&cd_cue, &cd_disc, cd_cue_open, 0);
+	while (left && cd_cue.error == CUE_OK) {
+		unsigned long n = left < sizeof(cd_block) ? left : sizeof(cd_block);
+		if (!RARead(&cd_cuefile, cd_block, n)) {
+			cd_cue.error = CUE_E_READ;
+			cd_cue.error_line = 0;
+			return CUE_E_READ;
+		}
+		cue_feed(&cd_cue, (const char *)cd_block, n);
+		left -= n;
+	}
+	return cue_end(&cd_cue);
+}
+
+/* Disc file f in cdrom.hdf (the data file): reopened with a fresh cluster
+   index when another file is wanted. */
+static int cd_data_open(int f)
+{
+	unsigned long cur, prev;
+	int ok;
+	if (cd_data_file == f && cdrom.hdf.type == HDF_FILE)
+		return 1;
+	cdrom.hdf.type = HDF_DISABLED;
+	cd_data_file = -1;
+	cur = iCurrentDirectory;
+	prev = iPreviousDirectory;
+	ChangeDirectory(cd_dir);
+	ok = FileOpen(&cdrom.hdf.file, cd_disc.file[f].shortname);
+	iCurrentDirectory = cur;
+	iPreviousDirectory = prev;
+	if (!ok) {
+		ClearError(ERROR_FILESYSTEM);
+		return 0;
+	}
+	cdrom.hdf.type = HDF_FILE;
+	cdrom.hdf.offset = 0;
+	BuildHardfileIndex(&cdrom.hdf);
+	cd_data_file = f;
+	return 1;
+}
+
+const char *CD_Message(void)
+{
+	return cd_msg;
+}
+
 int CD_Insert(const char *name, const char *long_name, unsigned long dir)
 {
-	char shortname[9];
+	char shortname[12];
+	char base[9];		/* the drive's name without a long name: 8 characters */
 	char longname[ATAPI_NAME_LEN + 1];
 
 	if (!cdrom.active)
 		return CD_NOFILE;
 	/* copies first: name may be the config entry CD_Eject clears */
-	memcpy(shortname, name, 8);
-	shortname[8] = 0;
+	memcpy(shortname, name, 11);
+	shortname[11] = 0;
+	memcpy(base, name, 8);
+	base[8] = 0;
 	if (long_name) {
 		strncpy(longname, long_name, ATAPI_NAME_LEN);
 		longname[ATAPI_NAME_LEN] = 0;
@@ -109,23 +261,32 @@
 	if (CD_Eject() != CD_OK)
 		return CD_LOCKED;
 
-	memcpy(cd_filename, shortname, 8);
-	strcpy(&cd_filename[8], "ISO");
+	cd_msg[0] = 0;
 	if (!ValidateDirectory(dir))
 		return CD_NOFILE;
-	ChangeDirectory(dir);
-	if (!FileOpen(&cdrom.hdf.file, cd_filename))
+	cd_dir = dir;
+	if (memcmp(shortname + 8, "CUE", 3) == 0) {
+		if (!cd_raopen(&cd_cuefile, shortname))
+			return CD_NOFILE;
+		if (cd_parse_cue() != CUE_OK) {
+			cue_message(&cd_cue, cd_msg);
+			if (DebugMode)
+				printf("CD: %s refused: %s\r\n", shortname, cd_msg);
+			return CD_BADCUE;
+		}
+	} else {
+		if (!cd_raopen(&cd_lookup, shortname))
+			return CD_NOFILE;
+		cue_single(&cd_disc, shortname, cd_lookup.size);
+	}
+	if (!cd_data_open(cd_disc.track[0].file))
 		return CD_NOFILE;
 
-	cdrom.hdf.type = HDF_FILE;
-	cdrom.hdf.offset = 0;
-	BuildHardfileIndex(&cdrom.hdf);
-
-	cue_single(&cd_disc, cd_filename, cdrom.hdf.file.size);
-	atapi_insert(&cdrom.unit, &cd_disc, long_name ? longname : shortname);
+	atapi_insert(&cdrom.unit, &cd_disc, long_name ? longname : base);
 	cd_config(shortname, long_name ? longname : 0, dir);
 	if (DebugMode)
-		printf("CD: insert %s (%s), %lu sectors\r\n", cd_filename, cdrom.unit.name, (unsigned long)cdrom.unit.sectors);
+		printf("CD: insert %s (%s), %d tracks, %d sectors\r\n", shortname, cdrom.unit.name,
+		       (int)cd_disc.tracks, (int)cd_disc.leadout);
 	return CD_OK;
 }
 
@@ -133,6 +294,7 @@
 static void cd_drop_file(void)
 {
 	cdrom.hdf.type = HDF_DISABLED;	/* FAT files need no close */
+	cd_data_file = -1;
 	cd_config(0, 0, 0);
 }
 
@@ -240,9 +402,19 @@
 	return CD_DONE;
 }
 
-/* Data in from the ISO: SD card -> FIFO, 512-byte FAT sectors, four per CD
-   sector, blocks of at most the limit and 8 KB. */
-static int cd_send_sectors(int port, unsigned char *tfr, unsigned long lba, unsigned long count, unsigned int limit)
+/* MEDIUM ERROR 03/11/00 for a read that failed on the SD card. */
+static int cd_read_error(unsigned long block)
+{
+	if (DebugMode)
+		printf("CD: SD read error at %d\r\n", (int)block);
+	WriteXfer(0, 1);	/* drop the transfer: no DRQ, no stall */
+	atapi_set_sense(&cdrom.unit, 0x03, 0x11, 0x00);
+	return CD_FAILED;
+}
+
+/* Data in from a DATA2048 file: SD card -> FIFO, 512-byte FAT sectors from
+   block on, four per CD sector, blocks of at most the limit and 8 KB. */
+static int cd_send_sectors(int port, unsigned char *tfr, unsigned long block, unsigned long count, unsigned int limit)
 {
 	unsigned long left = count * 4;
 	unsigned int per = limit >> 9;
@@ -251,17 +423,12 @@
 		per = CD_FIFO_512;
 	if (!per)
 		per = 1;	/* a limit below 512 bytes: blocks of 512 anyway */
-	HardFileSeek(&cdrom.hdf, lba * 4);
+	HardFileSeek(&cdrom.hdf, block);
 	while (left) {
 		unsigned int n = left < per ? (unsigned int)left : per;
 		cd_phase(tfr, n << 9, 0x02, IDE_STATUS_RDY);
-		if (!FileReadEx(&cdrom.hdf.file, 0, n)) {
-			if (DebugMode)
-				printf("CD: SD read error at %lu\r\n", lba * 4 + count * 4 - left);
-			WriteXfer(0, 1);
-			atapi_set_sense(&cdrom.unit, 0x03, 0x11, 0x00);
-			return CD_FAILED;
-		}
+		if (!FileReadEx(&cdrom.hdf.file, 0, n))
+			return cd_read_error(block + count * 4 - left);
 		if ((r = cd_wait(port)) != CD_DONE)
 			return r;
 		left -= n;
@@ -269,6 +436,79 @@
 	return CD_DONE;
 }
 
+/* len bytes at byte offset off of the data file into dst, through cd_block. */
+static int cd_file_read(unsigned long off, unsigned char *dst, unsigned long len)
+{
+	unsigned long done = 0;
+	while (done < len) {
+		unsigned long in = (off + done) & 511, n = 512 - in;
+		if (n > len - done)
+			n = len - done;
+		if (!HardFileSeek(&cdrom.hdf, (off + done) >> 9) || !FileRead(&cdrom.hdf.file, cd_block))
+			return 0;
+		memcpy(dst + done, cd_block + in, n);
+		done += n;
+	}
+	return 1;
+}
+
+/* Data in of count sectors from a DATA2352 file at byte offset off: the
+   2048 user bytes of each (from byte 16), one sector per DRQ block (split
+   by the limit). */
+static int cd_send_raw(int port, unsigned char *tfr, unsigned long off, unsigned long count, unsigned int limit)
+{
+	int r;
+	while (count) {
+		if (!cd_file_read(off + 16, atapi_buf, ATAPI_SECTOR_SIZE))
+			return cd_read_error(off >> 9);
+		if ((r = cd_send_buffer(port, tfr, atapi_buf, ATAPI_SECTOR_SIZE, limit)) != CD_DONE)
+			return r;
+		off += 2352;
+		count--;
+	}
+	return CD_DONE;
+}
+
+/* Data in of count sectors of zeros: a data track's PREGAP / POSTGAP. */
+static int cd_send_zero(int port, unsigned char *tfr, unsigned long count, unsigned int limit)
+{
+	int r;
+	memset(atapi_buf, 0, ATAPI_SECTOR_SIZE);
+	while (count) {
+		if ((r = cd_send_buffer(port, tfr, atapi_buf, ATAPI_SECTOR_SIZE, limit)) != CD_DONE)
+			return r;
+		count--;
+	}
+	return CD_DONE;
+}
+
+/* READ(10)/(12): lba .. lba + count - 1, split where the track, its file
+   or its sector size changes (atapi.c has refused audio sectors). */
+static int cd_read(int port, unsigned char *tfr, unsigned long lba, unsigned long count, unsigned int limit)
+{
+	struct cue_loc l;
+	int r;
+	while (count) {
+		unsigned long n;
+		if (!cue_locate(&cd_disc, lba, &l))
+			return cd_read_error(lba);
+		n = l.run < count ? l.run : count;
+		if (l.silent)
+			r = cd_send_zero(port, tfr, n, limit);
+		else if (!cd_data_open(l.file))
+			r = cd_read_error(lba);
+		else if (cd_disc.track[l.track].type == CD_DATA2048)
+			r = cd_send_sectors(port, tfr, l.offset >> 9, n, limit);
+		else
+			r = cd_send_raw(port, tfr, l.offset, n, limit);
+		if (r != CD_DONE)
+			return r;
+		lba += n;
+		count -= n;
+	}
+	return CD_DONE;
+}
+
 /* Data out (MODE SELECT): taken and dropped, in blocks of at most the limit. */
 static int cd_receive(int port, unsigned char *tfr, unsigned int len, unsigned int limit)
 {
@@ -341,7 +581,7 @@
 		done = cd_send_buffer(port, tfr, atapi_buf, r.length, limit);
 		break;
 	case ATAPI_READ:
-		done = cd_send_sectors(port, tfr, r.lba, r.count, limit);
+		done = cd_read(port, tfr, r.lba, r.count, limit);
 		break;
 	case ATAPI_RECEIVE:
 		done = cd_receive(port, tfr, r.length, limit);
```

- [ ] **Step 4: Run, expected PASS**

```bash
make -C fw/ctrl_832/test
make -C fw/ctrl_832 clean
make -C fw/ctrl_832 832DIR=/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64/EightThirtyTwo
```

Expected: `26 cases: 26 passed, 0 failed (0 failed checks)` from cdrom_test (cue_test 11, atapi_test 21 as before).  The firmware builds (`832OSDAD.bin` written, no `unresolved symbol`); `menu.c` still passes `file.name`, which already is the 11-character name.  Do not stage `fw/ctrl_832/version.h`.

- [ ] **Step 5: Commit**

```bash
git add fw/ctrl_832/cdrom.h fw/ctrl_832/cdrom.c fw/ctrl_832/test/cdrom_test.c
git commit -F- <<'EOF'
fw/ctrl_832: CUE sheets in the CD-ROM drive: insert, refusals, raw and split reads

findings/cdrom/plan.md 13.5: the CUE is read through RARead and parsed,
every FILE looked up in the CUE's directory (8.3 form first: a lower-case
8.3 name has no long name entry), WAV headers checked; any refusal leaves
the drive empty and CD_Message() names the cause.  READ splits at track
and file boundaries: DATA2048 straight from the SD card, DATA2352 user
data through a buffer, silent data gaps as zeros.  The CD slot's
config `present` byte says ISO (1) or CUE (2): the name has no room for
the extension (phase3-plan.md spec issue 1).

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
EOF
```

### Task 5: Picker with ISO + CUE, refusal messages, leftovers out (`menu.c`, `fat.c`, `main.c`)

**Files:**
- Modify: `fw/ctrl_832/fat.c` (`ExtensionMatch`, used by `ScanDirectory`), `fw/ctrl_832/menu.c` (`SelectFile` compares whole lists, `"ISOCUE"` for the CD, `cd_show_msg` / `cd_insert_msg`, harddisk-page message line, CD line without `%.21s`, `CD_PRESENT` for a not-live CD slot, help text), `fw/ctrl_832/main.c` (no `bincue.h`, no `struct cdimage cd`, no dead comments), `fw/ctrl_832/Makefile` (no `audiotrack.o`, `bincue.o`)
- Delete: `fw/ctrl_832/bincue.c`, `fw/ctrl_832/bincue.h`, `fw/ctrl_832/audiotrack.c`, `fw/ctrl_832/audiotrack.h`

**Interfaces:**
- Consumes: `CD_Insert`, `CD_Message`, `CD_BADCUE`, `CD_NOFILE`, `CD_LOCKED`, `CD_PRESENT` (task 4).
- Produces: `ScanDirectory`'s `extension` may be a run of 3-character extensions (`"ISOCUE"`) or `"*"`; menu.c statics `cd_msg_text`, `cd_show_msg(text)`, `cd_insert_msg(result)` (task 12 builds on the CD line).

- [ ] **Step 1: The failing check**

menu.c, fat.c and main.c have no host harness (OSD, SD and main-loop code are board-tested, 13.3).  The check is the build plus these greps, which must print nothing when the task is done:

```bash
grep -n 'bincue\|audiotrack\|cdimage' fw/ctrl_832/Makefile fw/ctrl_832/main.c
grep -n '"ISO"\|%\.21s' fw/ctrl_832/menu.c
```

- [ ] **Step 2: Run, expected FAIL**

Expected now:

```
fw/ctrl_832/Makefile:60:	$(BUILD_DIR)/audiotrack.o $(BUILD_DIR)/bincue.o $(BUILD_DIR)/interrupts.o $(BUILD_DIR)/c64keys.o $(BUILD_DIR)/akiko.o \
fw/ctrl_832/main.c:56:#include "bincue.h"
fw/ctrl_832/main.c:245:struct cdimage cd;
fw/ctrl_832/menu.c:347:    SelectFile(t_hardfile[slot].enabled == HDF_CDROM ? "ISO" : "HDF", SCAN_DIR | SCAN_LFN, MENU_HARDFILE_SELECTED, hdf_page(slot));
fw/ctrl_832/menu.c:728:                sprintf(s, " CD-ROM: %.21s", cdrom.unit.name);
fw/ctrl_832/menu.c:799:                    SelectFile("ISO", SCAN_DIR | SCAN_LFN, MENU_CDROM_SELECTED, MENU_MAIN1);
```

- [ ] **Step 3: Implementation**

`fat.c` has CRLF line endings, which a patch block in this document cannot carry: make its two edits with the Edit tool (it keeps CRLF) or by hand.

Edit `fw/ctrl_832/fat.c` (CRLF), replace:

```c
    return(rc);
}

char ScanDirectory(unsigned long mode, char *extension, unsigned char options)
{
```

with:

```c
    return(rc);
}

// extension: "*", or one or more 3-character extensions in a row ("ISOCUE").
static int ExtensionMatch(const unsigned char *ext, const char *list)
{
    int i = 0;
    if (list[0] == '*')
        return 1;
    for (;;)
    {
        if (!list[i] || !list[i + 1] || !list[i + 2])
            return 0;
        if (ext[0] == list[i] && ext[1] == list[i + 1] && ext[2] == list[i + 2])
            return 1;
        i += 3;
    }
}

char ScanDirectory(unsigned long mode, char *extension, unsigned char options)
{
```

Edit `fw/ctrl_832/fat.c` (CRLF), replace:

```c
                        if ((extension[0] == '*') || (strncmp((const char*)&pEntry->Name[8], extension, 3) == 0)
```

with:

```c
                        if (ExtensionMatch(&pEntry->Name[8], extension)
```

`menu.c`, `main.c` and the Makefile:

```diff
--- a/fw/ctrl_832/menu.c
+++ b/fw/ctrl_832/menu.c
@@ -127,7 +127,7 @@
 #endif
     "                                Minimig's video features include a blur filter, to simulate the poorer picture quality on older monitors, and also scanline generation to simulate the appearance of a screen with low vertical resolution.  On HDMI, CRT Mask adds a phosphor mask (grille: red, green and blue stripes; shadow: magenta and green) and Bloom lets bright pixels fill their scanline gaps; bloom needs scanlines or a vertical filter.  Beam width gives each pixel the soft spot of a CRT's beam, so dithered patterns blend as on a monitor; with it on, Bloom also widens the spot of bright pixels.  Video Pos moves the HDMI picture: Hpos in HD pixels (+ right), Vpos in Amiga lines (+ down).  Scaling (HDMI): Sharp and Area scale the picture exactly 2.5 times (PAL) or 3 times (NTSC) vertically, every line the same height; Sharp keeps edges crisp, Area is the most even.  Line rate is the older, slightly smaller picture.  Sharp and Area need the 15 kHz picture: the core turns the scandoubler off for them.",
     "                                The clock delay sets where the HDMI transmitter samples each pixel.  Too early or too late shows as sparkling colours, light yellows first.  Step through the values, note where the picture is clean, and settle in the middle of that range.  Save the configuration to keep it.",
-    "                                CD-ROM drive.  Insert an ISO image from the SD card.  On IDE port 2 the Amiga needs AtapiMagic (3.1.4/3.2) or IDEfix97 (3.1).  The Amiga cannot boot from it.",
+    "                                CD-ROM drive.  Insert an ISO image or a CUE sheet (BIN, or ISO + WAV tracks) from the SD card.  On IDE port 2 the Amiga needs AtapiMagic (3.1.4/3.2) or IDEfix97 (3.1).  The Amiga cannot boot from it.",
     0};
 
 void SanityCheck();
@@ -165,7 +165,7 @@
 {
     // this function displays file selection menu
 
-    if (strncmp(pFileExt, fs_pFileExt, 3) != 0) // check desired file extension
+    if (!fs_pFileExt || strcmp(pFileExt, fs_pFileExt) != 0) // check desired file extension(s)
     {                                           // if different from the current one go to the root directory and init entry buffer
         ChangeDirectory(DIRECTORY_ROOT);
         ScanDirectory(SCAN_INIT, pFileExt, Options);
@@ -231,17 +231,36 @@
 static unsigned long t_hdfdir[HDD_SLOTS];
 static int hdf_select_slot;	// the slot whose file selector is open
 
-// "locked by the Amiga" in place of a CD line, for 2 s (D5)
-#define CD_MSG_DELAY 2000
+// A message in place of a CD line, for 4 s: "locked by the Amiga" (D5),
+// or why an insert was refused (13.1: the cause, at most 23 characters).
+#define CD_MSG_DELAY 4000
 static unsigned long cd_msg_timer;
 static char cd_msg_on;
+static const char *cd_msg_text;
 
-static void cd_locked_msg(void)
+static void cd_show_msg(const char *text)
 {
+    cd_msg_text = text;
     cd_msg_on = 1;
     cd_msg_timer = GetTimer(CD_MSG_DELAY);
 }
 
+static void cd_locked_msg(void)
+{
+    cd_show_msg("locked by the Amiga");
+}
+
+// The OSD's answer to CD_Insert: nothing when the disc went in.
+static void cd_insert_msg(int r)
+{
+    if (r == CD_LOCKED)
+        cd_locked_msg();
+    else if (r == CD_BADCUE)
+        cd_show_msg(CD_Message());
+    else if (r == CD_NOFILE)
+        cd_show_msg("file not found");
+}
+
 // The message is over: redraw.
 static int cd_msg_expired(void)
 {
@@ -315,7 +334,10 @@
         mask |= 1 << row;
 
     if (t->enabled == HDF_CDROM && cd_msg_on && cd_live(slot))
-        strcpy(s, "       locked by the Amiga");
+    {
+        strcpy(s, "       ");
+        strcat(s, cd_msg_text);
+    }
     else if (t->enabled == HDF_CDROM && !t->name[0])
         strcpy(s, "              * no disc *");
     else if (t->present)
@@ -344,7 +366,7 @@
 static void hdf_select(int slot)
 {
     hdf_select_slot = slot;
-    SelectFile(t_hardfile[slot].enabled == HDF_CDROM ? "ISO" : "HDF", SCAN_DIR | SCAN_LFN, MENU_HARDFILE_SELECTED, hdf_page(slot));
+    SelectFile(t_hardfile[slot].enabled == HDF_CDROM ? "ISOCUE" : "HDF", SCAN_DIR | SCAN_LFN, MENU_HARDFILE_SELECTED, hdf_page(slot));
 }
 
 // The help text for a Harddisks page: the CD's when the cursor is on a CD slot.
@@ -720,12 +742,14 @@
         {
             menumask |= 0x40;
             if (cd_msg_on)
-                strcpy(s, " CD-ROM: locked by the Amiga");
+                sprintf(s, " CD-ROM: %s", cd_msg_text);
             else if (!cdrom.unit.media)
                 strcpy(s, " CD-ROM: * no disc *");
             else
             {
-                sprintf(s, " CD-ROM: %.21s", cdrom.unit.name);
+                // strncat: lib832's printf has no precision (it printed "21s" here)
+                strcpy(s, " CD-ROM: ");
+                strncat(s, cdrom.unit.name, 21);
                 if (CD_Locked())
                 {   // the lock mark at column 31
                     len = strlen(s);
@@ -796,7 +820,7 @@
             else if (menusub == 6) // CD-ROM: insert or eject
             {
                 if (!cdrom.unit.media)
-                    SelectFile("ISO", SCAN_DIR | SCAN_LFN, MENU_CDROM_SELECTED, MENU_MAIN1);
+                    SelectFile("ISOCUE", SCAN_DIR | SCAN_LFN, MENU_CDROM_SELECTED, MENU_MAIN1);
                 else
                 {
                     if (CD_Eject() == CD_LOCKED) // refused while the Amiga holds the lock (D5)
@@ -887,9 +911,8 @@
 
         break;
 
-    case MENU_CDROM_SELECTED: // an ISO for the CD-ROM drive, from the main page
-        if (CD_Insert(file.name, file.long_name[0] ? file.long_name : 0, CurrentDirectory()) == CD_LOCKED)
-            cd_locked_msg();
+    case MENU_CDROM_SELECTED: // an ISO or CUE for the CD-ROM drive, from the main page
+        cd_insert_msg(CD_Insert(file.name, file.long_name[0] ? file.long_name : 0, CurrentDirectory()));
         menustate = MENU_MAIN1;
         menusub = 6;
         break;
@@ -1998,8 +2021,7 @@
         {
             if (cd_live(slot))
             {   // a disc change in the live drive: now, no reset (refused while locked, D5)
-                if (CD_Insert(file.name, file.long_name[0] ? file.long_name : 0, CurrentDirectory()) == CD_LOCKED)
-                    cd_locked_msg();
+                cd_insert_msg(CD_Insert(file.name, file.long_name[0] ? file.long_name : 0, CurrentDirectory()));
                 *t = *SlotConfig(slot);
                 t_hdfdir[slot] = config.hdfdir[slot];
             }
@@ -2007,7 +2029,7 @@
             {   // the disc for a CD slot that is not live yet
                 memcpy((void *)t->name, (void *)file.name, sizeof(t->name));
                 memcpy((void *)t->long_name, (void *)file.long_name, sizeof(t->long_name));
-                t->present = 1;
+                t->present = CD_PRESENT(file.name); // ISO or CUE: the config's name has no extension
                 t_hdfdir[slot] = CurrentDirectory();
             }
             break;
--- a/fw/ctrl_832/main.c
+++ b/fw/ctrl_832/main.c
@@ -53,7 +53,6 @@
 #include "firmware.h"
 #include "menu.h"
 #include "config.h"
-#include "bincue.h"
 #include "c64keys.h"
 #include "akiko.h"
 #include "interrupts.h"
@@ -242,8 +241,6 @@
 	return(result);
 }
 
-struct cdimage cd;
-
 void setstack();
 #ifdef __GNUC__
 void c_entry(void)
@@ -281,9 +278,6 @@
 	if(!ColdBoot())
 		BootPrintEx("ROM loading failed");
 
-//	cd_setcuefile(&cd,"EXODUS_THELASTWAR.CUE");
-//	cd_playaudio(&cd,4);
-
     adv_timer = GetTimer(250);
     while(1)
     {
@@ -294,7 +288,6 @@
 		if(rtc)
 			HandleRTC();
 
-//		cd_continueaudio(&cd);
         HandleFpga();
         HandleUI();
 		// The HDMI transmitter forgets its configuration when the monitor goes
--- a/fw/ctrl_832/Makefile
+++ b/fw/ctrl_832/Makefile
@@ -57,7 +57,7 @@
 COMMON_SOURCES=$(BUILD_DIR)/hardware.o $(BUILD_DIR)/config.o $(BUILD_DIR)/fat.o $(BUILD_DIR)/fdd.o $(BUILD_DIR)/fpga.o \
 	$(BUILD_DIR)/boot.o $(BUILD_DIR)/hdd.o $(BUILD_DIR)/main.o $(BUILD_DIR)/menu.o $(BUILD_DIR)/mmc.o $(BUILD_DIR)/spi.o \
 	$(BUILD_DIR)/osd.o $(BUILD_DIR)/rafile.o $(BUILD_DIR)/swap.o $(BUILD_DIR)/hexdump.o $(BUILD_DIR)/uart.o $(BUILD_DIR)/errors.o \
-	$(BUILD_DIR)/audiotrack.o $(BUILD_DIR)/bincue.o $(BUILD_DIR)/interrupts.o $(BUILD_DIR)/c64keys.o $(BUILD_DIR)/akiko.o \
+	$(BUILD_DIR)/interrupts.o $(BUILD_DIR)/c64keys.o $(BUILD_DIR)/akiko.o \
 	$(BUILD_DIR)/audio.o $(BUILD_DIR)/drivesounds.o $(BUILD_DIR)/rtc.o $(BUILD_DIR)/i2c.o $(BUILD_DIR)/adv7511.o \
 	$(BUILD_DIR)/atapi.o $(BUILD_DIR)/cdrom.o $(BUILD_DIR)/cue.o
 
```

```bash
git rm -q fw/ctrl_832/bincue.c fw/ctrl_832/bincue.h fw/ctrl_832/audiotrack.c fw/ctrl_832/audiotrack.h
```

- [ ] **Step 4: Run, expected PASS**

```bash
grep -n 'bincue\|audiotrack\|cdimage' fw/ctrl_832/Makefile fw/ctrl_832/main.c
grep -n '"ISO"\|%\.21s' fw/ctrl_832/menu.c
make -C fw/ctrl_832/test
make -C fw/ctrl_832 clean
make -C fw/ctrl_832 832DIR=/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64/EightThirtyTwo
grep -n '__bss_end__' fw/ctrl_832/832OSDAD.map | head -1
awk '$1 ~ /^0x/ && NF==2 && $2 ~ /^_/ {print $2}' fw/ctrl_832/832OSDAD.map | sort | uniq -d
```

Expected: both greps print nothing; host tests as in task 4; the build ends with `Writing map file 832OSDAD.map` and no `unresolved symbol`; `__bss_end__` at `0x00028024`; the duplicate check prints `_STACKTOP` only.

- [ ] **Step 5: Commit**

```bash
git add fw/ctrl_832/fat.c fw/ctrl_832/menu.c fw/ctrl_832/main.c fw/ctrl_832/Makefile
git commit -F- <<'EOF'
fw/ctrl_832: ISO + CUE picker, refusal messages on the OSD; bincue.c / audiotrack.c removed

findings/cdrom/plan.md 13.1, 13.5: ScanDirectory takes a run of
3-character extensions ("ISOCUE"); a refused insert shows its cause in
place of the CD line for 4 s.  Main page line 6 is built with strncat:
lib832's printf has no precision and printed "21s" for "%.21s".  The
2020 bincue.c / audiotrack.c and main.c's unused struct cdimage go.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
EOF
```

(`git rm` in step 3 already staged the four deletions.)

### Task 6: Build, stage, board test 3a (Paul)

**Files:** none changed.  Output: `/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64/build/cdfw_phase3a/832OSDAD.BIN`.

- [ ] **Step 1: Build and stage**

```bash
make -C fw/ctrl_832 clean
make -C fw/ctrl_832 832DIR=/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64/EightThirtyTwo
mkdir -p /home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64/build/cdfw_phase3a
cp fw/ctrl_832/832OSDAD.bin /home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64/build/cdfw_phase3a/832OSDAD.BIN
git log --oneline -1 > /home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64/build/cdfw_phase3a/COMMIT
git status --short fw/ctrl_832   # only version.h modified: leave it unstaged
```

- [ ] **Step 2: Board checklist 3a (Paul)**

Bitstream: the stage_cdscaler2 image of 12.6 (no RTL change).  SD card: `832OSDAD.BIN` from `build/cdfw_phase3a`, the Pinball Fantasies folder (13.9), one BIN/CUE game, the AmigaOS 3.9 ISO.  Serial console on ttyUSB1 at 57600; DebugMode on (Ctrl + LAlt + OSD key) for the `CD:` lines.

1. Boot.  Main page line 6 reads ` CD-ROM: <name>` or ` CD-ROM: * no disc *` -- the name, not "21s".
2. Select line 6: the picker lists `.CUE` and `.ISO` files (and directories), nothing else.  Pick the Pinball Fantasies CUE: the line shows its long name; serial: `CD: insert PINBAL~?CUE (Pinball Fantasies ...), 3 tracks, 41658 sectors`.
3. On the Amiga (IDEfix97 or AtapiMagic, CD0 on `atapi.device` unit 2): the game starts from the CD.
4. A CD player program lists 3 tracks: 1 data (00:29), 2 audio (03:59), 3 audio (04:45); total 09:15.  Pressing play: no sound yet and no crash (the player is step 3b; PLAY answers GOOD).
5. Insert the BIN/CUE game: it mounts and starts.  Insert the AmigaOS 3.9 ISO: still mounts (single-track path).
6. Refusals (copies of the Pinball CUE on the card, edited on the PC): a line `FOO` added -> the CD line shows `line N: unknown cmd` for 4 s, the drive is empty, no OSD error page; a WAV renamed -> `line N: file missing`; a `TRACK 02 MODE2/2352` line -> `line N: track mode`.
7. Save the config with the Pinball CUE in the drive, power-cycle: the CUE comes back (config `present` = 2).  A config saved by the phase-1 firmware with an ISO still loads its ISO.
8. Harddisks page -> IDE port 2 page -> the CD slot's file line: the picker shows `.CUE` and `.ISO`; a CUE chosen for a slot that is not live yet comes up at the next reset.
9. Write down: which CUE files worked, any refusal message that looked wrong, and the `CD: insert` lines.

## Step 3b -- the player (13.8)

### Task 7: The player (`cdaudio.c`) against a model of the ring

**Files:**
- Create: `fw/ctrl_832/cdaudio.h`, `fw/ctrl_832/cdaudio.c`
- Create: `fw/ctrl_832/test/cdaudio_test.c`, `fw/ctrl_832/test/emu/cdaudio_emu.c`
- Modify: `fw/ctrl_832/test/Makefile` (cdaudio_test), `fw/ctrl_832/test/.gitignore`, `fw/ctrl_832/test/emu/Makefile` (cdaudio_emu)

**Interfaces:**
- Consumes: `struct cd_disc`, `struct cue_loc`, `cue_locate`, `CD_AUDIO`, `CD_FRAMES_PER_SECTOR` (task 1).
- Produces (cdaudio.h): status codes `CDA_PLAYING` 0x11, `CDA_PAUSED` 0x12, `CDA_COMPLETED` 0x13, `CDA_ERROR` 0x14, `CDA_IDLE` 0x15 (= READ SUB-CHANNEL codes); `CDA_ENA` 1, `CDA_CLEAR` 2, `CDA_REG_HALF` 1, `CDA_REG_AMIGA` 2; `CDA_HALF_BYTES` 0x8000, `CDA_HALF_FRAMES` 8192, `CDA_HALF_UNITS` 32.  The port, implemented by the board glue (task 9) and by the tests: `int32_t cda_port_read(int32_t file, uint32_t block, uint8_t *dst)`, `uint32_t cda_port_audio(void)`, `void cda_port_control(uint32_t v)`, `uint32_t cda_port_timer(void)`, `uint8_t *cda_port_ring(void)`, `void cda_port_claim(void)`.  The player: `void cda_init(void)`, `void cda_play(const struct cd_disc *d, uint32_t start, uint32_t end)`, `void cda_pause(void)`, `void cda_resume(void)`, `void cda_stop(void)`, `void cda_volume(uint32_t left, uint32_t right)`, `void cda_poll(void)`, `int32_t cda_status(void)`, `uint32_t cda_position(void)`, `int32_t cda_busy(void)`, `uint32_t cda_underruns(void)`.

How the player works (13.7): a run is CLEAR, both halves filled from frame `base` of the play range, ENA.  `played` counts TIMER units since ENA; `halves` counts the halves the hardware has entered.  A poll that sees a new half by TIMER (reconciled with AUDIO bit 0: TIMER can lead the pointer by up to a unit at a flip) fills the other half from the stream cursor; two or more halves late it counts an underrun, silences the half playing now (stale) and moves the cursor to where the hardware is.  The stream is file bytes through a 512-byte block buffer, silence for silent gaps, data sectors and the tail of a WAV's last sector, silence after the range; the end is declared one TIMER unit after the last real sample, then the ring is given back stopped and silent.  `AUDIOF_AMIGA`: no writes, the position runs on TIMER, a new run from that position when the Amiga lets go.

- [ ] **Step 1: Write the failing tests**

Create `fw/ctrl_832/test/cdaudio_test.c` (the hardware model: `advance(n)` runs n aud_ticks and records every frame played in `heard[]`):

```c
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
```

Create `fw/ctrl_832/test/emu/cdaudio_emu.c`:

```c
/*
 * cdaudio_emu: the CD audio player compiled by vbcc832 and run in 832e
 * (make -C fw/ctrl_832/test/emu).  cdaudio_test checks the logic with gcc;
 * this checks what vbcc832 makes of it: the int32 state set and returned,
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
```

```diff
--- a/fw/ctrl_832/test/Makefile
+++ b/fw/ctrl_832/test/Makefile
@@ -1,8 +1,9 @@
 # Host tests for the CD-ROM (findings/cdrom/plan.md): atapi_test, the ATAPI
 # command layer (task 0.1); cdrom_test, the board glue against a model of
-# the Gayle port and an ATAPI host (task 1.4); cue_test, the CUE parser and
-# disc model (phase 3, findings/cdrom/phase3-plan.md task 1).
-#   make -C fw/ctrl_832/test            build and run both (exit status = result)
+# the Gayle port and an ATAPI host (task 1.4); phase 3
+# (findings/cdrom/phase3-plan.md): cue_test, the CUE parser and disc model;
+# cdaudio_test, the CD audio player against a model of the audio ring.
+#   make -C fw/ctrl_832/test            build and run them all (exit status = result)
 #   make -C fw/ctrl_832/test ISO=<path> use another ISO for the ISO-backed cases
 # Without the ISO those cases are skipped, not failed.
 
@@ -19,15 +20,19 @@
 cue_test: cue_test.c ../cue.c ../cue.h
 	$(HOSTCC) $(CFLAGS) -o $@ cue_test.c ../cue.c
 
+cdaudio_test: cdaudio_test.c ../cdaudio.c ../cdaudio.h ../cue.c ../cue.h
+	$(HOSTCC) $(CFLAGS) -o $@ cdaudio_test.c ../cdaudio.c ../cue.c
+
 cdrom_test: cdrom_test.c ../cdrom.c ../cdrom.h ../atapi.c ../atapi.h ../cue.c ../cue.h ../hdd.h
 	$(HOSTCC) $(CFLAGS) -o $@ cdrom_test.c ../cdrom.c ../atapi.c ../cue.c
 
-run: cue_test atapi_test cdrom_test
+run: cue_test cdaudio_test atapi_test cdrom_test
 	./cue_test
+	./cdaudio_test
 	./atapi_test "$(ISO)"
 	./cdrom_test
 
 clean:
-	rm -f cue_test atapi_test cdrom_test
+	rm -f cue_test cdaudio_test atapi_test cdrom_test
 
 .PHONY: all run clean
--- a/fw/ctrl_832/test/.gitignore
+++ b/fw/ctrl_832/test/.gitignore
@@ -1,3 +1,4 @@
 atapi_test
 cdrom_test
 cue_test
+cdaudio_test
--- a/fw/ctrl_832/test/emu/Makefile
+++ b/fw/ctrl_832/test/emu/Makefile
@@ -1,5 +1,5 @@
 # Firmware units built by vbcc832 and run in 832e, the EightThirtyTwo
-# emulator: atapi_emu (atapi.c), cue_emu (cue.c).  Little-endian: 832e's
+# emulator: atapi_emu (atapi.c), cue_emu (cue.c), cdaudio_emu (cdaudio.c).  Little-endian: 832e's
 # big-endian mode mixes swapped (stmpdec) and raw (stbinc) byte writes; the
 # size bug these tests are for shows either way (a 32-bit store clobbers
 # the bytes after a uint8_t).  Exit status 0 = every program printed PASS.
@@ -22,8 +22,8 @@
 # the firmware's code generator options (fw/ctrl_832/Makefile)
 CFLAGS  = -+ -c99 -O=1343 -unsigned-char -D__geta4= -DNULL=0 -I../.. -I$(832DIR)/include/ -I$(LIBDIR)
 
-PROGS    = atapi_emu cue_emu
-UNIT_ASM = atapi.asm cue.asm
+PROGS    = atapi_emu cue_emu cdaudio_emu
+UNIT_ASM = atapi.asm cue.asm cdaudio.asm
 TEST_ASM = $(PROGS:=.asm)
 
 all: run
@@ -38,6 +38,8 @@
 cue.asm: ../../cue.h
 atapi_emu.asm: ../../atapi.h ../../cue.h
 cue_emu.asm: ../../cue.h
+cdaudio.asm: ../../cdaudio.h ../../cue.h
+cdaudio_emu.asm: ../../cdaudio.h ../../cue.h
 
 %.o: %.asm
 	$(AS) -o $@ $<
@@ -57,9 +59,13 @@
 cue_emu: cue_emu.o cue.o
 	$(LD) -o $@ $(LIBDIR)/crt0.a $(LIBDIR)/lib832.a $^
 
+cdaudio_emu: cdaudio_emu.o cdaudio.o cue.o
+	$(LD) -o $@ $(LIBDIR)/crt0.a $(LIBDIR)/lib832.a $^
+
 run: $(PROGS) 832e_fix
 	timeout 60 $(EMU) atapi_emu | tee atapi_emu.log; ! grep -q "^FAIL" atapi_emu.log && grep -qx PASS atapi_emu.log
 	timeout 60 $(EMU) cue_emu | tee cue_emu.log; ! grep -q "^FAIL" cue_emu.log && grep -qx PASS cue_emu.log
+	timeout 60 $(EMU) cdaudio_emu | tee cdaudio_emu.log; ! grep -q "^FAIL" cdaudio_emu.log && grep -qx PASS cdaudio_emu.log
 
 clean:
 	rm -rf *.asm *.o $(PROGS) *.log 832e_fix emusrc
```

- [ ] **Step 2: Run, expected FAIL**

```bash
make -C fw/ctrl_832/test
```

Expected:

```
make: *** No rule to make target '../cdaudio.c', needed by 'cdaudio_test'.  Stop.
```

- [ ] **Step 3: Implementation**

Create `fw/ctrl_832/cdaudio.h`:

```c
#ifndef CDAUDIO_H
#define CDAUDIO_H

/*
 * CD audio player (findings/cdrom/plan.md 13.2, 13.7): plays a range of
 * disc sectors into the 64 KB audio ring (two 32 KB halves, 44.1 kHz
 * 16-bit LE stereo, red book as it is).  Pure C: the hardware and the SD
 * card are behind the cda_port_* functions, implemented by cdrom.c on the
 * board and by the tests (test/cdaudio_test.c, test/emu/cdaudio_emu.c).
 *
 * Refill by polling (13.1): cda_poll() is called from the main loop and
 * between the blocks of every SD transfer loop; when the half being played
 * has changed it fills the other one.  The position comes from TIMER
 * (256 frames a unit), not from the read-ahead.
 *
 * vbcc832 (12.6): every state field is 32 bits.
 */

#include <stdint.h>
#include "cue.h"

/* Audio status = the READ SUB-CHANNEL codes (13.6) */
#define CDA_PLAYING   0x11
#define CDA_PAUSED    0x12
#define CDA_COMPLETED 0x13
#define CDA_ERROR     0x14
#define CDA_IDLE      0x15

/* AUDIO register (hardware.h): write bit 0 ENA, bit 1 CLEAR; read bit 0 =
   the half being played, bit 1 = the Amiga owns the stream. */
#define CDA_ENA        1
#define CDA_CLEAR      2
#define CDA_REG_HALF   1
#define CDA_REG_AMIGA  2

#define CDA_HALF_BYTES  0x8000	/* AUDIO_BUFFER_SIZE */
#define CDA_HALF_FRAMES 8192
#define CDA_HALF_UNITS  32	/* TIMER units (256 frames) in one half */

/* ---- the port ---- */

/* 512-byte block `block` (byte offset block * 512) of disc file `file`
   into dst; 1 = read, 0 = SD error. */
int32_t  cda_port_read(int32_t file, uint32_t block, uint8_t *dst);
uint32_t cda_port_audio(void);		/* read the AUDIO register */
void     cda_port_control(uint32_t v);	/* write the AUDIO register: CDA_ENA, CDA_CLEAR or 0 */
uint32_t cda_port_timer(void);		/* TIMER (16 bits) */
uint8_t *cda_port_ring(void);		/* the ring: half h at h * CDA_HALF_BYTES */
void     cda_port_claim(void);		/* the player takes the ring: the drive sounds stop */

/* ---- the player ---- */

void     cda_init(void);			/* idle, volume 255/255 */
/* Play sectors start .. end - 1 of disc d (end > start, end <= lead-out).
   Silent gaps and data sectors play as silence; any play in progress
   stops first. */
void     cda_play(const struct cd_disc *d, uint32_t start, uint32_t end);
void     cda_pause(void);			/* playing -> paused, position kept */
void     cda_resume(void);			/* paused -> playing from the position */
void     cda_stop(void);			/* -> idle */
void     cda_volume(uint32_t left, uint32_t right);	/* 0..255 per channel */
void     cda_poll(void);
int32_t  cda_status(void);		/* CDA_PLAYING .. CDA_IDLE */
uint32_t cda_position(void);		/* LBA of the sector playing (paused at, last played) */
int32_t  cda_busy(void);		/* playing or paused: the ring is the player's */
uint32_t cda_underruns(void);		/* late refills since power on */

#endif
```

Create `fw/ctrl_832/cdaudio.c`:

```c
/*
 * CD audio player -- see cdaudio.h and findings/cdrom/plan.md 13.7.
 *
 * A run = CLEAR, both halves filled from frame `base` of the range, ENA;
 * then the hardware plays half 0, half 1, half 0 ... and `halves` counts
 * the halves it has entered.  Range frame f of the run sits in the ring at
 * byte ((f - base) * 4) mod 64 KB.  TIMER says how far the run has played
 * (`played`, in 256-frame units); AUDIO bit 0 says which half plays now.
 *
 * Loops are "for (;;) / break" or counted (cue.c: vbcc832 drops the
 * increment of "while (*p ...) p++;").
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
```

- [ ] **Step 4: Run, expected PASS**

```bash
make -C fw/ctrl_832/test
make -C fw/ctrl_832/test/emu 832DIR=/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64/EightThirtyTwo
```

Expected: `10 cases: 10 passed, 0 failed (0 failed checks)` from cdaudio_test (cue_test 11, atapi_test 21, cdrom_test 26 unchanged); emu `PASS` three times (atapi_emu, cue_emu, cdaudio_emu).  `cdaudio.o` joins the firmware in task 9, with its first caller.

- [ ] **Step 5: Commit**

```bash
git add fw/ctrl_832/cdaudio.h fw/ctrl_832/cdaudio.c fw/ctrl_832/test/cdaudio_test.c fw/ctrl_832/test/Makefile \
        fw/ctrl_832/test/.gitignore fw/ctrl_832/test/emu/cdaudio_emu.c fw/ctrl_832/test/emu/Makefile
git commit -F- <<'EOF'
fw/ctrl_832: CD audio player (cdaudio.c) against a model of the audio ring

findings/cdrom/plan.md 13.7: a run is CLEAR, both 32 KB halves, ENA; a
poll that sees a new half fills the other one from the stream (file
bytes, silence for gaps and data sectors).  Position by TIMER; a late
refill silences the stale half and resynchronises; the end is declared a
TIMER unit after the last sample and the ring goes back silent.
AUDIOF_AMIGA: no writes.  Volume = sample x vol / 256.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
EOF
```

### Task 8: PLAY AUDIO, PAUSE/RESUME, STOP, READ SUB-CHANNEL (`atapi.c`)

**Files:**
- Modify: `fw/ctrl_832/atapi.h` (`ATAPI_PLAY`, `ATAPI_AUDIO_*` requests and statuses, `atapi_unit.audio_status/audio_lba/audio_seen`, `atapi_result.audio`, `atapi_audio_status`), `fw/ctrl_832/atapi.c` (`atapi_init`, `atapi_audio_status`, page 2A audio bit, `put_rel`, `read_subchannel`, `get_configuration` with feature 0103h, `start_stop`, `play`, `play_lba`, `msf_lba`, `play_msf`, `play_track`, `audio_request`, the opcode switch)
- Test: `fw/ctrl_832/test/atapi_test.c` (3 new cases; GET CONFIGURATION is 24 bytes now, page 2A claims audio, 4B / 4E are requests), `fw/ctrl_832/test/emu/atapi_emu.c`

**Interfaces:**
- Consumes: `touches`, `adr_ctrl`, `cue_locate` (task 3).
- Produces: `#define ATAPI_PLAY 5`; `ATAPI_AUDIO_PLAY` 1, `ATAPI_AUDIO_PAUSE` 2, `ATAPI_AUDIO_RESUME` 3, `ATAPI_AUDIO_STOP` 4 (`atapi_result.audio`, `int32_t`); `ATAPI_AUDIO_PLAYING` 0x11 .. `ATAPI_AUDIO_NONE` 0x15; `void atapi_audio_status(struct atapi_unit *u, int32_t status, uint32_t lba)`.  PLAY requests carry `r->lba` (start) and `r->count` (sectors); START STOP UNIT stop or eject carries `ATAPI_AUDIO_STOP` with kind `ATAPI_DONE`.  Task 9's `cd_packet` calls `atapi_audio_status(&unit, cda_status(), cda_position())` before every packet and hands `r.audio` to the player.

- [ ] **Step 1: Write the failing tests**

```diff
--- a/fw/ctrl_832/test/atapi_test.c
+++ b/fw/ctrl_832/test/atapi_test.c
@@ -566,7 +566,7 @@
 	expect_response(__LINE__, c, 28);
 	EXPECT(be16(atapi_buf) == 26, "mode data length %u", be16(atapi_buf));
 	EXPECT(atapi_buf[8] == 0x2A && atapi_buf[9] == 0x12, "page 2A header %02X %02X", atapi_buf[8], atapi_buf[9]);
-	EXPECT((atapi_buf[8 + 4] & 0x01) == 0, "audio play claimed before phase 3");
+	EXPECT((atapi_buf[8 + 4] & 0x01) != 0, "audio play not advertised (13.6)");
 	EXPECT((atapi_buf[8 + 6] & 0x02) == 0, "lock state set while unlocked");
 
 	mode_sense10(c, 0x3F, 0xFFFF);
@@ -625,8 +625,10 @@
 	expect_response(__LINE__, c, 36);
 	cdb0(c, 0x46);
 	c[8] = 0xFF;
-	expect_response(__LINE__, c, 16);
+	expect_response(__LINE__, c, 24);	/* profile list + feature 0103h */
 	EXPECT(be16(atapi_buf + 6) == 0x0008, "current profile %04X", be16(atapi_buf + 6));
+	EXPECT(be16(atapi_buf + 16) == 0x0103 && atapi_buf[18] == 0x00, "feature %04X flags %02X with no disc",
+	       be16(atapi_buf + 16), atapi_buf[18]);
 	gesn(c, 1, 0x10, 8);
 	expect_response(__LINE__, c, 8);
 	EXPECT(atapi_buf[5] == 0x00, "media status %02X with no disc", atapi_buf[5]);
@@ -839,9 +841,9 @@
 static void t_misc(void)
 {
 	uint8_t c[12];
-	static const uint8_t nodata[] = { 0x2B, 0x35, 0x45, 0x47, 0x4B, 0x4E, 0xBC };
+	static const uint8_t nodata[] = { 0x2B, 0x35, 0x45, 0x47, 0xBC };	/* 45 / 47 of length 0 */
 	unsigned i;
-	begin("SEEK, SYNC CACHE, audio no-ops, MODE SELECT, sub-channel, disc/track info");
+	begin("SEEK, SYNC CACHE, empty plays, MODE SELECT, sub-channel, disc/track info");
 	ready_unit(OS39_SECTORS, OS39_NAME);
 	for (i = 0; i < sizeof(nodata); i++) {
 		cdb0(c, nodata[i]);
@@ -990,6 +992,198 @@
 	end();
 }
 
+/* The command must end in ATAPI_PLAY (or DONE for kind) with this request. */
+static void expect_play(int line, const uint8_t *c, int kind, int32_t audio, uint32_t lba, uint32_t count)
+{
+	int k = run(c);
+	if (k != kind || R.audio != audio || (audio == ATAPI_AUDIO_PLAY && (R.lba != lba || R.count != count))) {
+		case_fails++;
+		printf("  FAIL %s (line %d): CDB %02X kind %d audio %d lba %u count %u (sense %02X/%02X/%02X),"
+		       " want kind %d audio %d lba %u count %u\n", case_name, line, c[0], k, R.audio, R.lba, R.count,
+		       R.sense_key, R.asc, R.ascq, kind, audio, lba, count);
+	}
+}
+
+static void play10(uint8_t *c, uint32_t lba, uint16_t len)
+{
+	cdb0(c, 0x45);
+	put_be32(c + 2, lba);
+	c[7] = (uint8_t)(len >> 8);
+	c[8] = (uint8_t)len;
+}
+
+static void play_msf(uint8_t *c, uint8_t m0, uint8_t s0, uint8_t f0, uint8_t m1, uint8_t s1, uint8_t f1)
+{
+	cdb0(c, 0x47);
+	c[3] = m0; c[4] = s0; c[5] = f0;
+	c[6] = m1; c[7] = s1; c[8] = f1;
+}
+
+static void play_ti(uint8_t *c, uint8_t st, uint8_t si, uint8_t et, uint8_t ei)
+{
+	cdb0(c, 0x48);
+	c[4] = st; c[5] = si;
+	c[7] = et; c[8] = ei;
+}
+
+static void t_play(void)
+{
+	uint8_t c[12];
+	begin("PLAY AUDIO 45/A5/47/48, PAUSE/RESUME, STOP, START STOP: play requests for the glue");
+	ready_disc(pinball(), "Pinball Fantasies");
+	play10(c, 2358, 100);
+	expect_play(__LINE__, c, ATAPI_PLAY, ATAPI_AUDIO_PLAY, 2358, 100);
+	play10(c, 2208, 10);	/* track 2's silent PREGAP is audio track 2 */
+	expect_play(__LINE__, c, ATAPI_PLAY, ATAPI_AUDIO_PLAY, 2208, 10);
+	play10(c, 2358, 0);
+	expect_play(__LINE__, c, ATAPI_DONE, 0, 0, 0);
+	play10(c, 0, 10);
+	expect_check(__LINE__, c, 0x05, 0x64, 0x00);	/* starts in the data track */
+	play10(c, 41650, 10);
+	expect_check(__LINE__, c, 0x05, 0x21, 0x00);
+	cdb0(c, 0xA5);
+	put_be32(c + 2, 20283);
+	put_be32(c + 6, 21375);
+	expect_play(__LINE__, c, ATAPI_PLAY, ATAPI_AUDIO_PLAY, 20283, 21375);
+
+	play_msf(c, 0, 33, 33, 4, 32, 33);	/* 2358 .. 20283 */
+	expect_play(__LINE__, c, ATAPI_PLAY, ATAPI_AUDIO_PLAY, 2358, 17925);
+	play_msf(c, 0, 33, 33, 0, 33, 33);
+	expect_play(__LINE__, c, ATAPI_DONE, 0, 0, 0);
+	play_msf(c, 4, 32, 33, 0, 33, 33);
+	expect_check(__LINE__, c, 0x05, 0x24, 0x00);
+	play_msf(c, 0, 0, 0, 0, 2, 10);	/* the lead-in counts as LBA 0: data */
+	expect_check(__LINE__, c, 0x05, 0x64, 0x00);
+
+	play_ti(c, 2, 1, 2, 1);
+	expect_play(__LINE__, c, ATAPI_PLAY, ATAPI_AUDIO_PLAY, 2358, 17775);	/* to track 3's INDEX 00 */
+	play_ti(c, 2, 0, 3, 1);
+	expect_play(__LINE__, c, ATAPI_PLAY, ATAPI_AUDIO_PLAY, 2208, 41658 - 2208);
+	play_ti(c, 3, 1, 99, 1);
+	expect_play(__LINE__, c, ATAPI_PLAY, ATAPI_AUDIO_PLAY, 20283, 21375);
+	play_ti(c, 3, 0, 3, 0);
+	expect_play(__LINE__, c, ATAPI_PLAY, ATAPI_AUDIO_PLAY, 20133, 150);
+	play_ti(c, 1, 1, 1, 1);
+	expect_check(__LINE__, c, 0x05, 0x64, 0x00);
+	play_ti(c, 4, 1, 4, 1);
+	expect_check(__LINE__, c, 0x05, 0x24, 0x00);
+	play_ti(c, 3, 1, 2, 1);
+	expect_check(__LINE__, c, 0x05, 0x24, 0x00);
+
+	cdb0(c, 0x4B);
+	expect_play(__LINE__, c, ATAPI_PLAY, ATAPI_AUDIO_PAUSE, 0, 0);
+	c[8] = 0x01;
+	expect_play(__LINE__, c, ATAPI_PLAY, ATAPI_AUDIO_RESUME, 0, 0);
+	cdb0(c, 0x4E);
+	expect_play(__LINE__, c, ATAPI_PLAY, ATAPI_AUDIO_STOP, 0, 0);
+	start_stop(c, 0, 1);
+	expect_play(__LINE__, c, ATAPI_DONE, 0, 0, 0);
+	start_stop(c, 0, 0);
+	expect_play(__LINE__, c, ATAPI_DONE, ATAPI_AUDIO_STOP, 0, 0);
+	start_stop(c, 1, 0);
+	expect_play(__LINE__, c, ATAPI_DONE, ATAPI_AUDIO_STOP, 0, 0);
+	EXPECT(R.ejected == 1 && !U.media, "eject: ejected %d media %d", R.ejected, U.media);
+	end();
+}
+
+static void subq(uint8_t *c, int msf)
+{
+	cdb0(c, 0x42);
+	c[1] = msf ? 0x02 : 0x00;
+	c[2] = 0x40;
+	c[3] = 0x01;
+	c[8] = 0xFF;
+}
+
+static void t_subchannel(void)
+{
+	static const uint8_t playing[16] = {
+		0x00, 0x11, 0x00, 0x0C, 0x01, 0x10, 0x02, 0x01,
+		0x00, 0x00, 0x09, 0x60, 0x00, 0x00, 0x00, 0x2A	/* LBA 2400, relative 42 */
+	};
+	static const uint8_t playing_msf[16] = {
+		0x00, 0x11, 0x00, 0x0C, 0x01, 0x10, 0x02, 0x01,
+		0x00, 0, 34, 0, 0x00, 0, 0, 42			/* 00:34:00, relative 00:00:42 */
+	};
+	static const uint8_t gap[16] = {
+		0x00, 0x12, 0x00, 0x0C, 0x01, 0x10, 0x02, 0x00,
+		0x00, 0x00, 0x08, 0xFC, 0xFF, 0xFF, 0xFF, 0xC6	/* LBA 2300, index 0, relative -58 */
+	};
+	uint8_t c[12];
+	begin("READ SUB-CHANNEL: the player's status and position; 13/14 once, then 15");
+	ready_disc(pinball(), "Pinball Fantasies");
+	subq(c, 0);
+	expect_response(__LINE__, c, 16);
+	EXPECT(atapi_buf[1] == 0x15 && atapi_buf[6] == 1 && atapi_buf[5] == 0x14, "idle: status %02X track %u",
+	       atapi_buf[1], atapi_buf[6]);
+	atapi_audio_status(&U, ATAPI_AUDIO_PLAYING, 2400);
+	expect_response(__LINE__, c, 16);
+	expect_bytes(__LINE__, playing, 0, 16);
+	subq(c, 1);
+	expect_response(__LINE__, c, 16);
+	expect_bytes(__LINE__, playing_msf, 0, 16);
+	atapi_audio_status(&U, ATAPI_AUDIO_PAUSED, 2300);
+	subq(c, 0);
+	expect_response(__LINE__, c, 16);
+	expect_bytes(__LINE__, gap, 0, 16);
+	subq(c, 1);
+	expect_response(__LINE__, c, 16);
+	EXPECT(atapi_buf[13] == 0 && atapi_buf[14] == 0 && atapi_buf[15] == 58, "gap relative MSF %u:%u:%u",
+	       atapi_buf[13], atapi_buf[14], atapi_buf[15]);
+
+	atapi_audio_status(&U, ATAPI_AUDIO_COMPLETED, 41657);
+	subq(c, 0);
+	expect_response(__LINE__, c, 16);
+	EXPECT(atapi_buf[1] == 0x13 && atapi_buf[6] == 3, "completed: %02X track %u", atapi_buf[1], atapi_buf[6]);
+	atapi_audio_status(&U, ATAPI_AUDIO_COMPLETED, 41657);
+	cdb0(c, 0x42);	/* header only (SubQ 0) */
+	c[8] = 0xFF;
+	expect_response(__LINE__, c, 4);
+	EXPECT(atapi_buf[1] == 0x15, "completed reported twice: %02X", atapi_buf[1]);
+	play10(c, 2358, 10);	/* a new play: its end is news again */
+	run(c);
+	atapi_audio_status(&U, ATAPI_AUDIO_COMPLETED, 2367);
+	subq(c, 0);
+	expect_response(__LINE__, c, 16);
+	EXPECT(atapi_buf[1] == 0x13, "the next completion: %02X", atapi_buf[1]);
+	atapi_audio_status(&U, ATAPI_AUDIO_ERROR, 2367);
+	expect_response(__LINE__, c, 16);
+	EXPECT(atapi_buf[1] == 0x14, "error: %02X", atapi_buf[1]);
+	atapi_audio_status(&U, ATAPI_AUDIO_ERROR, 2367);
+	expect_response(__LINE__, c, 16);
+	EXPECT(atapi_buf[1] == 0x15, "error reported twice: %02X", atapi_buf[1]);
+	end();
+}
+
+static void t_audio_caps(void)
+{
+	uint8_t c[12];
+	begin("audio advertised: MODE SENSE 2A byte 4 bit 0, GET CONFIGURATION feature 0103h");
+	ready_disc(pinball(), "Pinball Fantasies");
+	mode_sense10(c, 0x2A, 0xFFFF);
+	expect_response(__LINE__, c, 28);
+	EXPECT(atapi_buf[8 + 4] & 0x01, "page 2A byte 4 = %02X", atapi_buf[8 + 4]);
+	cdb0(c, 0x46);
+	c[8] = 0xFF;
+	expect_response(__LINE__, c, 24);
+	EXPECT(be32(atapi_buf) == 20 && be16(atapi_buf + 8) == 0x0000 && be16(atapi_buf + 16) == 0x0103 &&
+	       atapi_buf[18] == 0x01 && atapi_buf[19] == 4 && atapi_buf[20] == 0x03 && be16(atapi_buf + 22) == 256,
+	       "features %04X %04X flags %02X", be16(atapi_buf + 8), be16(atapi_buf + 16), atapi_buf[18]);
+	cdb0(c, 0x46);
+	c[1] = 0x02;	/* RT 2: that feature alone */
+	c[2] = 0x01;
+	c[3] = 0x03;
+	c[8] = 0xFF;
+	expect_response(__LINE__, c, 16);
+	EXPECT(be16(atapi_buf + 8) == 0x0103, "feature %04X", be16(atapi_buf + 8));
+	cdb0(c, 0x46);
+	c[2] = 0x01;
+	c[3] = 0x04;
+	c[8] = 0xFF;
+	expect_response(__LINE__, c, 8);
+	end();
+}
+
 static void t_iso_read(const char *path)
 {
 	uint8_t c[12];
@@ -1079,6 +1273,9 @@
 	t_toc_tracks();
 	t_tracks_info();
 	t_read_audio();
+	t_play();
+	t_subchannel();
+	t_audio_caps();
 	t_iso_read(path);
 
 	if (iso_fd >= 0)
--- a/fw/ctrl_832/test/emu/atapi_emu.c
+++ b/fw/ctrl_832/test/emu/atapi_emu.c
@@ -171,6 +171,48 @@
 	expect("READ data lba", res.lba, 2200);
 	expect("READ data count", res.count, 8);
 
+	/* PLAY AUDIO(10) 2358 + 100: a play request (int32 kind and audio) */
+	memset(cdb, 0, sizeof(cdb));
+	cdb[0] = 0x45;
+	cdb[4] = 0x09;
+	cdb[5] = 0x36;
+	cdb[8] = 100;
+	k = atapi_packet(&unit, cdb, 0xFFFE, &res);
+	expect("PLAY return", k, ATAPI_PLAY);
+	expect("PLAY kind", res.kind, ATAPI_PLAY);
+	expect("PLAY audio", res.audio, ATAPI_AUDIO_PLAY);
+	expect("PLAY lba", res.lba, 2358);
+	expect("PLAY count", res.count, 100);
+	expect("PLAY seen", unit.audio_seen, 0);
+	/* PAUSE */
+	memset(cdb, 0, sizeof(cdb));
+	cdb[0] = 0x4B;
+	k = atapi_packet(&unit, cdb, 0xFFFE, &res);
+	expect("PAUSE kind", res.kind, ATAPI_PLAY);
+	expect("PAUSE audio", res.audio, ATAPI_AUDIO_PAUSE);
+	/* START STOP UNIT stop: DONE with a stop request */
+	k = packet(0x1B, 0, 0x00, 0);
+	expect("STOP UNIT kind", res.kind, ATAPI_DONE);
+	expect("STOP UNIT audio", res.audio, ATAPI_AUDIO_STOP);
+	expect("STOP UNIT ejected", res.ejected, 0);
+	/* SUB-CHANNEL: completed once, then none */
+	atapi_audio_status(&unit, ATAPI_AUDIO_COMPLETED, 2457);
+	expect("status after set", unit.audio_status, ATAPI_AUDIO_COMPLETED);
+	expect("lba after set", unit.audio_lba, 2457);
+	memset(cdb, 0, sizeof(cdb));
+	cdb[0] = 0x42;
+	cdb[2] = 0x40;
+	cdb[3] = 0x01;
+	cdb[8] = 16;
+	k = atapi_packet(&unit, cdb, 0xFFFE, &res);
+	expect("SUB-CHANNEL length", res.length, 16);
+	expect("SUB-CHANNEL status", atapi_buf[1], 0x13);
+	expect("SUB-CHANNEL track", atapi_buf[6], 2);
+	expect("SUB-CHANNEL relative", be32(atapi_buf + 12), 99);
+	expect("seen after report", unit.audio_seen, ATAPI_AUDIO_COMPLETED);
+	atapi_audio_status(&unit, ATAPI_AUDIO_COMPLETED, 2457);
+	expect("status reported once", unit.audio_status, ATAPI_AUDIO_NONE);
+
 	if (fails)
 		printf("FAIL %d\n", fails);
 	else
```

- [ ] **Step 2: Run, expected FAIL**

```bash
make -C fw/ctrl_832/test
```

Expected (first lines):

```
atapi_test.c:999:27: error: ‘struct atapi_result’ has no member named ‘audio’
atapi_test.c:999:56: error: ‘ATAPI_AUDIO_PLAY’ undeclared (first use in this function)
```

- [ ] **Step 3: Implementation**

```diff
--- a/fw/ctrl_832/atapi.h
+++ b/fw/ctrl_832/atapi.h
@@ -32,6 +32,22 @@
 #define ATAPI_READ     2	/* data in: count sectors from lba */
 #define ATAPI_RECEIVE  3	/* data out: accept length bytes, then GOOD */
 #define ATAPI_CHECK    4	/* CHECK CONDITION, sense in the result and the unit */
+#define ATAPI_PLAY     5	/* GOOD, no data phase, a request for the player in r->audio */
+
+/* atapi_result.audio: what the glue asks of the player (cdaudio.c); 0 = nothing.
+   ATAPI_PLAY carries one; START STOP UNIT (stop, eject) carries STOP with
+   kind ATAPI_DONE. */
+#define ATAPI_AUDIO_PLAY   1	/* play r->count sectors from r->lba */
+#define ATAPI_AUDIO_PAUSE  2
+#define ATAPI_AUDIO_RESUME 3
+#define ATAPI_AUDIO_STOP   4
+
+/* READ SUB-CHANNEL audio status (cdaudio.h CDA_*) */
+#define ATAPI_AUDIO_PLAYING   0x11
+#define ATAPI_AUDIO_PAUSED    0x12
+#define ATAPI_AUDIO_COMPLETED 0x13
+#define ATAPI_AUDIO_ERROR     0x14
+#define ATAPI_AUDIO_NONE      0x15
 
 /* atapi_eject() / atapi_insert() status */
 #define ATAPI_OK       0
@@ -53,6 +69,9 @@
 	uint8_t  ascq;
 	uint32_t sectors;	/* disc size in sectors: the lead-out LBA */
 	const struct cd_disc *disc;	/* the disc in the drive (cue.h), 0 = none */
+	int32_t  audio_status;	/* the player's, ATAPI_AUDIO_PLAYING .. NONE (atapi_audio_status) */
+	uint32_t audio_lba;	/* the player's position */
+	int32_t  audio_seen;	/* COMPLETED / ERROR already reported by READ SUB-CHANNEL, 0 = not */
 	char     name[ATAPI_NAME_LEN + 1];	/* ISO / CUE long name, printable ASCII */
 };
 
@@ -62,14 +81,15 @@
 	   32-bit store whatever the field's type, and with a uint8_t kind the
 	   big-endian 832 wrote 0 into it and X over the next three bytes (every
 	   packet ended as GOOD without data; test/emu/atapi_emu.c). */
-	int32_t  kind;		/* ATAPI_DONE .. ATAPI_CHECK, also the return value */
+	int32_t  kind;		/* ATAPI_DONE .. ATAPI_PLAY, also the return value */
 	uint8_t  ejected;	/* START STOP UNIT ejected the disc: close the file */
 	uint8_t  sense_key;	/* ATAPI_CHECK: error register = sense_key << 4 */
 	uint8_t  asc;
 	uint8_t  ascq;
 	uint16_t length;	/* RESPONSE: bytes in atapi_buf (allocation length applied); RECEIVE: bytes */
-	uint32_t lba;		/* READ */
-	uint32_t count;		/* READ: sectors, never 0 */
+	uint32_t lba;		/* READ, ATAPI_AUDIO_PLAY */
+	uint32_t count;		/* READ, ATAPI_AUDIO_PLAY: sectors, never 0 */
+	int32_t  audio;		/* ATAPI_AUDIO_*: a request for the player, 0 = none */
 };
 
 /* Response buffer shared by all units (one command at a time). */
@@ -99,6 +119,11 @@
    REQUEST SENSE reports for the command that failed. */
 void atapi_set_sense(struct atapi_unit *u, uint8_t key, uint8_t asc, uint8_t ascq);
 
+/* The player's state for READ SUB-CHANNEL, given by the glue before each
+   packet: status ATAPI_AUDIO_PLAYING .. NONE, lba its position.  COMPLETED
+   and ERROR are reported once, then NONE (13.6). */
+void atapi_audio_status(struct atapi_unit *u, int32_t status, uint32_t lba);
+
 /* IDENTIFY PACKET DEVICE (0xA1): 256 words. */
 void atapi_identify(uint16_t *id, const struct atapi_unit *u);
 
--- a/fw/ctrl_832/atapi.c
+++ b/fw/ctrl_832/atapi.c
@@ -151,6 +151,19 @@
 void atapi_init(struct atapi_unit *u)
 {
 	memset(u, 0, sizeof(*u));
+	u->audio_status = ATAPI_AUDIO_NONE;
+}
+
+void atapi_audio_status(struct atapi_unit *u, int32_t status, uint32_t lba)
+{
+	if (status == ATAPI_AUDIO_COMPLETED || status == ATAPI_AUDIO_ERROR) {
+		if (u->audio_seen == status)
+			status = ATAPI_AUDIO_NONE;	/* reported once already */
+	} else {
+		u->audio_seen = 0;
+	}
+	u->audio_status = status;
+	u->audio_lba = lba;
 }
 
 void atapi_reset(struct atapi_unit *u)
@@ -278,9 +291,10 @@
 		p[10] = 0x02;	/* port 1: channel 1, full volume */
 		p[11] = 0xFF;
 		return p + 16;
-	case 0x2A:		/* capabilities: CD-ROM read, no audio play until phase 3 */
+	case 0x2A:		/* capabilities: CD-ROM read, audio play (13.6) */
 		p[0] = 0x2A;
 		p[1] = 0x12;
+		p[4] = 0x01;	/* audio play */
 		p[6] = (uint8_t)(0x29 | (u->locked ? 0x02 : 0));	/* tray, eject, lock (+ state) */
 		put16(p + 8, 706);	/* max read speed, KB/s (4x) */
 		put16(p + 10, 256);	/* volume levels */
@@ -366,20 +380,44 @@
 	return respond(u, r, (uint32_t)(p - b), get16(cdb + 7));
 }
 
+/* Relative address in a track: LBA (negative in the gap before INDEX 01),
+   or MSF counting away from INDEX 01 without the 150-frame offset. */
+static void put_rel(uint8_t *p, int32_t rel, int msf)
+{
+	if (msf) {
+		uint32_t a = (uint32_t)(rel < 0 ? -rel : rel);
+		p[0] = 0;
+		p[1] = (uint8_t)(a / (75 * 60));
+		p[2] = (uint8_t)((a / 75) % 60);
+		p[3] = (uint8_t)(a % 75);
+	} else {
+		put32(p, (uint32_t)rel);
+	}
+}
+
 static int read_subchannel(struct atapi_unit *u, const uint8_t *cdb, struct atapi_result *r)
 {
+	const struct cd_disc *d = u->disc;
 	uint8_t *b = atapi_buf;
 	uint32_t n = 0;
-	b[1] = 0x15;		/* audio status: none */
+	int32_t status = u->audio_status;
+	b[1] = (uint8_t)status;	/* audio status: the player's */
 	if (cdb[2] & 0x40) {	/* SubQ */
 		uint8_t format = cdb[3];
 		b[4] = format;
-		if (format == 1) {	/* current position: start of track 1 */
-			b[5] = ADR_CTRL_DATA;
-			b[6] = 1;
-			b[7] = 1;
-			put_addr(b + 8, 0, cdb[1] & 0x02);
-			n = 12;	/* relative address 0 in either format */
+		if (format == 1) {	/* current position: where the player is */
+			const struct cd_track *t;
+			struct cue_loc l;
+			uint32_t lba = u->audio_lba < u->sectors ? u->audio_lba : 0;
+			int msf = cdb[1] & 0x02;
+			cue_locate(d, lba, &l);
+			t = &d->track[l.track];
+			b[5] = adr_ctrl(t);
+			b[6] = t->number;
+			b[7] = (uint8_t)l.index;
+			put_addr(b + 8, lba, msf);
+			put_rel(b + 12, (int32_t)lba - (int32_t)t->lba, msf);
+			n = 12;
 		} else if (format == 2 || format == 3) {	/* MCN / ISRC: not valid */
 			if (format == 3)
 				b[6] = cdb[6];
@@ -388,6 +426,8 @@
 			return ILLEGAL_FIELD(u, r);
 		}
 	}
+	if (status == ATAPI_AUDIO_COMPLETED || status == ATAPI_AUDIO_ERROR)
+		u->audio_seen = status;	/* then NONE (atapi_audio_status) */
 	put16(b + 2, n);
 	return respond(u, r, 4 + n, get16(cdb + 7));
 }
@@ -395,17 +435,27 @@
 static int get_configuration(struct atapi_unit *u, const uint8_t *cdb, struct atapi_result *r)
 {
 	uint8_t *b = atapi_buf;
-	uint32_t total = 8;
+	uint8_t *p = b + 8;
+	uint32_t start = get16(cdb + 2);
+	int only = (cdb[1] & 0x03) == 0x02;	/* RT 2: the starting feature alone */
 	put16(b + 6, 0x0008);	/* current profile: CD-ROM */
-	if (get16(cdb + 2) == 0) {	/* starting feature 0: the profile list */
-		b[10] = 0x03;	/* persistent, current */
-		b[11] = 4;
-		put16(b + 12, 0x0008);
-		b[14] = 0x01;	/* current */
-		total = 16;
+	if (start == 0) {	/* the profile list */
+		p[2] = 0x03;	/* persistent, current */
+		p[3] = 4;
+		put16(p + 4, 0x0008);
+		p[6] = 0x01;	/* current */
+		p += 8;
 	}
-	put32(b, total - 4);
-	return respond(u, r, total, get16(cdb + 7));
+	if (only ? start == 0x0103 : start <= 0x0103) {	/* CD audio external play */
+		put16(p, 0x0103);
+		p[2] = u->media ? 0x01 : 0x00;	/* current with a disc in */
+		p[3] = 4;
+		p[4] = 0x03;	/* separate channel mute, separate volume */
+		put16(p + 6, 256);	/* volume levels */
+		p += 8;
+	}
+	put32(b, (uint32_t)(p - b) - 4);
+	return respond(u, r, (uint32_t)(p - b), get16(cdb + 7));
 }
 
 static int event_status(struct atapi_unit *u, const uint8_t *cdb, struct atapi_result *r)
@@ -498,9 +548,94 @@
 			return check(u, r, 0x05, 0x53, 0x02);
 		r->ejected = 1;
 	}
+	if (!(cdb[4] & 0x01))	/* stop or eject: playback ends */
+		r->audio = ATAPI_AUDIO_STOP;
 	return good(u, r);
 }
 
+/* ---- audio (13.6) ---- */
+
+/* A play request for sectors start .. end - 1 (end > start). */
+static int play(struct atapi_unit *u, struct atapi_result *r, uint32_t start, uint32_t end)
+{
+	const struct cd_disc *d = u->disc;
+	struct cue_loc l;
+	if (start >= u->sectors || end > u->sectors)
+		return check(u, r, 0x05, 0x21, 0x00);
+	cue_locate(d, start, &l);
+	if (d->track[l.track].type != CD_AUDIO)	/* starts in a data track */
+		return check(u, r, 0x05, 0x64, 0x00);
+	set_sense(u, 0, 0, 0);
+	u->audio_seen = 0;
+	r->audio = ATAPI_AUDIO_PLAY;
+	r->lba = start;
+	r->count = end - start;
+	r->kind = ATAPI_PLAY;
+	return ATAPI_PLAY;
+}
+
+/* PLAY AUDIO(10) 45 / (12) A5: LBA + length; length 0 does nothing. */
+static int play_lba(struct atapi_unit *u, const uint8_t *cdb, struct atapi_result *r)
+{
+	uint32_t lba = get32(cdb + 2);
+	uint32_t len = cdb[0] == 0x45 ? get16(cdb + 7) : get32(cdb + 6);
+	if (!len)
+		return good(u, r);
+	if (lba >= u->sectors || len > u->sectors - lba)
+		return check(u, r, 0x05, 0x21, 0x00);
+	return play(u, r, lba, lba + len);
+}
+
+/* MSF -> LBA; addresses in the first 2 seconds (the lead-in pregap) are LBA 0. */
+static uint32_t msf_lba(const uint8_t *p)
+{
+	uint32_t f = ((uint32_t)p[0] * 60 + p[1]) * 75 + p[2];
+	return f < 150 ? 0 : f - 150;
+}
+
+/* PLAY AUDIO MSF 47: start MSF (3-5) .. end MSF (6-8). */
+static int play_msf(struct atapi_unit *u, const uint8_t *cdb, struct atapi_result *r)
+{
+	uint32_t start = msf_lba(cdb + 3), end = msf_lba(cdb + 6);
+	if (start == end)
+		return good(u, r);
+	if (start > end)
+		return ILLEGAL_FIELD(u, r);
+	return play(u, r, start, end);
+}
+
+/* PLAY AUDIO TRACK/INDEX 48: from track cdb[4] index cdb[5] through track
+   cdb[7] index cdb[8].  Index 0 = the gap before INDEX 01; 1 and up = the
+   track (there are no higher indexes); an end track past the last plays
+   to the end of the disc. */
+static int play_track(struct atapi_unit *u, const uint8_t *cdb, struct atapi_result *r)
+{
+	const struct cd_disc *d = u->disc;
+	int32_t st = cdb[4], et = cdb[7];
+	uint32_t start, end;
+	if (st < 1 || st > d->tracks || et < st)
+		return ILLEGAL_FIELD(u, r);
+	if (et > d->tracks)
+		et = d->tracks;
+	start = cdb[5] ? d->track[st - 1].lba : d->track[st - 1].pregap_lba;
+	if (!cdb[8])
+		end = d->track[et - 1].lba;
+	else
+		end = et < d->tracks ? d->track[et].pregap_lba : d->leadout;
+	if (end <= start)
+		return ILLEGAL_FIELD(u, r);
+	return play(u, r, start, end);
+}
+
+/* PAUSE/RESUME 4B, STOP PLAY/SCAN 4E: a request for the player. */
+static int audio_request(struct atapi_unit *u, struct atapi_result *r, int32_t what)
+{
+	set_sense(u, 0, 0, 0);
+	r->audio = what;
+	r->kind = ATAPI_PLAY;
+	return ATAPI_PLAY;
+}
+
 int atapi_packet(struct atapi_unit *u, const uint8_t *cdb, uint16_t limit, struct atapi_result *r)
 {
 	uint8_t op = cdb[0];
@@ -531,12 +666,19 @@
 	case 0x00:	/* TEST UNIT READY */
 	case 0x2B:	/* SEEK(10) */
 	case 0x35:	/* SYNCHRONIZE CACHE */
-	case 0x45:	/* PLAY AUDIO(10)    -- phase 3 */
-	case 0x47:	/* PLAY AUDIO MSF    -- phase 3 */
-	case 0x4B:	/* PAUSE / RESUME    -- phase 3 */
-	case 0x4E:	/* STOP PLAY / SCAN  -- phase 3 */
-	case 0xBC:	/* PLAY CD           -- phase 3 */
+	case 0xBC:	/* PLAY CD: not in 13.6 */
 		return good(u, r);
+	case 0x45:	/* PLAY AUDIO(10) */
+	case 0xA5:	/* PLAY AUDIO(12) */
+		return play_lba(u, cdb, r);
+	case 0x47:
+		return play_msf(u, cdb, r);
+	case 0x48:
+		return play_track(u, cdb, r);
+	case 0x4B:	/* PAUSE / RESUME: byte 8 bit 0 */
+		return audio_request(u, r, (cdb[8] & 0x01) ? ATAPI_AUDIO_RESUME : ATAPI_AUDIO_PAUSE);
+	case 0x4E:	/* STOP PLAY / SCAN */
+		return audio_request(u, r, ATAPI_AUDIO_STOP);
 	case 0x1A:
 	case 0x5A:
 		return mode_sense(u, cdb, r);
```

- [ ] **Step 4: Run, expected PASS**

```bash
make -C fw/ctrl_832/test
make -C fw/ctrl_832/test/emu 832DIR=/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64/EightThirtyTwo
```

Expected: `24 cases: 24 passed, 0 failed, 0 skipped` from atapi_test (cdrom_test still 26: `cd_packet` treats `ATAPI_PLAY` as no data phase until task 9); emu `PASS` three times (atapi_emu checks `kind`, `audio`, `audio_status`, `audio_seen` as vbcc832 stores them).

- [ ] **Step 5: Commit**

```bash
git add fw/ctrl_832/atapi.h fw/ctrl_832/atapi.c fw/ctrl_832/test/atapi_test.c fw/ctrl_832/test/emu/atapi_emu.c
git commit -F- <<'EOF'
fw/ctrl_832: ATAPI PLAY AUDIO, PAUSE/RESUME, STOP, READ SUB-CHANNEL position

findings/cdrom/plan.md 13.6: 45/A5/47/48 return a play request
(ATAPI_PLAY, start and length; a start in a data track is 05/64/00,
length 0 does nothing); 4B/4E and START STOP stop/eject ask the player
to pause, resume or stop.  READ SUB-CHANNEL reports the player's status
and position (13/14 once, then 15).  Page 2A and feature 0103h advertise
audio play.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
EOF
```

### Task 9: The player wired in: port, requests, refill polls, drive sounds

**Files:**
- Modify: `fw/ctrl_832/cdrom.h` (`CD_AudioPoll`), `fw/ctrl_832/cdrom.c` (`cd_audio` second file, `CD_Open` resets the player, `cd_hdf_open` shared by both files, `cd_drop_file` / `CD_Reset` stop the music, `cda_port_*` (hardware ones under `#ifndef HOSTTEST`), `CD_AudioPoll`, `cd_audio_request`, polls in `cd_wait` and `cd_send_sectors`, `atapi_audio_status` before each packet, the `ATAPI_PLAY` log line)
- Modify: `fw/ctrl_832/hdd.c` (polls in the ATA read/write block waits), `fw/ctrl_832/fdd.c` (poll between sectors of `ReadTrack`), `fw/ctrl_832/main.c` (main loop and error-page loop), `fw/ctrl_832/drivesounds.c` (`cda_busy` guard in `drivesounds_fill` and `drivesounds_disable`, `drivesounds_yield`), `fw/ctrl_832/drivesounds.h`, `fw/ctrl_832/Makefile` (`cdaudio.o`)
- Test: `fw/ctrl_832/test/cdrom_test.c` (audio hardware model, 3 new cases), `fw/ctrl_832/test/Makefile` (cdrom_test links cdaudio.c)

**Interfaces:**
- Consumes: the player and its port (task 7), the requests and `atapi_audio_status` (task 8), `cd_disc`, `cd_dir`, `cd_data_open` (task 4); hardware.h `AUDIO`, `TIMER`, `AUDIO_BUFFER`.
- Produces: `void CD_AudioPoll(void)`; `void drivesounds_yield()`; static `cd_hdf_open(hdfTYPE *h, int *open, int f)`, `cd_audio`, `cd_audio_file` (task 11 reads audio sectors through `cd_data_open`, task 12 uses `cda_busy`/`cda_position`).

- [ ] **Step 1: Write the failing tests**

```diff
--- a/fw/ctrl_832/test/cdrom_test.c
+++ b/fw/ctrl_832/test/cdrom_test.c
@@ -39,6 +39,7 @@
 #include "rafile.h"
 #include "atapi.h"
 #include "cue.h"
+#include "cdaudio.h"
 #include "cdrom.h"
 
 /* ---- bookkeeping ---- */
@@ -276,12 +277,44 @@
 	return 1;
 }
 
+static int file_reads[16];	/* FileRead calls per fake_dir entry */
+
 unsigned char FileRead(fileTYPE *file, unsigned char *pBuffer)
 {
+	if (file->start_cluster && file->start_cluster <= 16)
+		file_reads[file->start_cluster - 1]++;
 	fake_read(file, file->sector * 512, pBuffer, 512);
 	return 1;
 }
 
+/* ---- the audio hardware for the player (cdaudio.c through cdrom.c) ----
+   44 frames per ms of now_ms; the play pointer runs while ENA is set. */
+
+static uint8_t ring[0x10000];
+static unsigned long ena_ms;
+static int audio_ena, audio_claims;
+static uint32_t audio_last;
+
+static uint32_t frames_now(void) { return (uint32_t)(now_ms * 44); }
+
+uint32_t cda_port_audio(void)
+{
+	uint32_t p = audio_ena ? (uint32_t)((now_ms - ena_ms) * 44) & 16383 : 0;
+	return p >= 8192 ? CDA_REG_HALF : 0;
+}
+
+void cda_port_control(uint32_t v)
+{
+	audio_last = v;
+	audio_ena = (v & CDA_ENA) ? 1 : 0;
+	if (audio_ena)
+		ena_ms = now_ms;
+}
+
+uint32_t cda_port_timer(void) { return (frames_now() >> 8) & 0xFFFF; }
+uint8_t *cda_port_ring(void) { return ring; }
+void cda_port_claim(void) { audio_claims++; }
+
 int RAOpen(RAFile *f, const char *name)
 {
 	int ok = FileOpen(&f->file, name);
@@ -1116,6 +1149,109 @@
 	end();
 }
 
+/* ---- phase 3: CD audio through the glue ---- */
+
+#define WAV_FILE 5	/* "MIXED~2 WAV" in fake_dir */
+#define ISO2_FILE 4	/* "MIXED~1 ISO" */
+
+static void play10(uint8_t *c, uint32_t lba, uint16_t len)
+{
+	memset(c, 0, 12);
+	c[0] = 0x45;
+	c[2] = (uint8_t)(lba >> 24); c[3] = (uint8_t)(lba >> 16); c[4] = (uint8_t)(lba >> 8); c[5] = (uint8_t)lba;
+	c[7] = (uint8_t)(len >> 8); c[8] = (uint8_t)len;
+}
+
+/* The mixed disc in, track 2 (LBA 214, 10 sectors of WAV) playing. */
+static void playing_mixed(void)
+{
+	uint8_t c[12];
+	EXPECT(insert_disc("MIXED   CUE", "Mixed") == CD_OK, "insert refused: '%s'", CD_Message());
+	memset(file_reads, 0, sizeof(file_reads));
+	audio_claims = 0;
+	play10(c, 214, 10);
+	packet(c, 0xFFFE);
+}
+
+static void t_play(void)
+{
+	uint8_t c[12];
+	int wav_reads;
+	begin("PLAY AUDIO: GOOD, the player runs from the WAV (second file); READ SUB-CHANNEL sees it");
+	playing_mixed();
+	EXPECT(good_end(), "status: %02X error %02X", g.end_status, g.reg[1]);
+	EXPECT(cda_status() == CDA_PLAYING && audio_claims == 1 && audio_ena, "player: status %02X claims %d ena %d",
+	       (unsigned)cda_status(), audio_claims, audio_ena);
+	EXPECT(file_reads[WAV_FILE] > 0, "nothing read from the WAV");
+	EXPECT(memcmp(cdrom.hdf.file.name, "MIXED~1 ISO", 11) == 0, "the data file moved to '%.11s'", cdrom.hdf.file.name);
+	memset(c, 0, 12);
+	c[0] = 0x42;
+	c[2] = 0x40;
+	c[3] = 0x01;
+	c[8] = 16;
+	packet(c, 0xFFFE);
+	EXPECT(h.in_len == 16 && h.in[1] == 0x11 && h.in[5] == 0x10 && h.in[6] == 2 && good_end(),
+	       "sub-channel: status %02X control %02X track %u", h.in[1], h.in[5], h.in[6]);
+	wav_reads = file_reads[WAV_FILE];
+	read10(c, 0, 8);	/* data while the music plays: cd_wait polls the player */
+	packet(c, 0x0800);
+	EXPECT(h.in_len == 8 * 2048 && iso_matches(0, 8 * 2048) && good_end(), "data read while playing");
+	EXPECT(file_reads[WAV_FILE] >= wav_reads, "WAV reads went backwards");
+	EXPECT(cda_status() == CDA_PLAYING || cda_status() == CDA_COMPLETED, "player: %02X", (unsigned)cda_status());
+	end();
+}
+
+static void t_play_refused(void)
+{
+	uint8_t c[12];
+	begin("PLAY AUDIO of a data track: CHECK 05/64/00, the player stays idle");
+	EXPECT(insert_disc("MIXED   CUE", "Mixed") == CD_OK, "insert refused: '%s'", CD_Message());
+	audio_claims = 0;
+	play10(c, 10, 10);
+	packet(c, 0xFFFE);
+	EXPECT(check_end(0x54), "status %02X error %02X", g.end_status, g.reg[1]);
+	EXPECT(cda_status() == CDA_IDLE && audio_claims == 0, "player %02X claims %d", (unsigned)cda_status(), audio_claims);
+	end();
+}
+
+static void t_play_stops(void)
+{
+	uint8_t c[12];
+	begin("the music stops on STOP PLAY, START STOP stop, eject, Amiga reset, a new disc");
+	playing_mixed();
+	memset(c, 0, 12);
+	c[0] = 0x4E;
+	packet(c, 0xFFFE);
+	EXPECT(good_end() && cda_status() == CDA_IDLE && !audio_ena && audio_last == CDA_CLEAR, "STOP PLAY: %02X",
+	       (unsigned)cda_status());
+
+	playing_mixed();
+	memset(c, 0, 12);
+	c[0] = 0x4B;	/* PAUSE */
+	packet(c, 0xFFFE);
+	EXPECT(good_end() && cda_status() == CDA_PAUSED && !audio_ena, "PAUSE: %02X", (unsigned)cda_status());
+	c[8] = 0x01;	/* RESUME */
+	packet(c, 0xFFFE);
+	EXPECT(good_end() && cda_status() == CDA_PLAYING && audio_ena, "RESUME: %02X", (unsigned)cda_status());
+	cdb6(c, 0x1B, 0x00);	/* START STOP UNIT: stop */
+	packet(c, 0xFFFE);
+	EXPECT(good_end() && cda_status() == CDA_IDLE && cdrom.unit.media, "START STOP stop: %02X", (unsigned)cda_status());
+
+	playing_mixed();
+	cdb6(c, 0x1B, 0x02);	/* eject */
+	packet(c, 0xFFFE);
+	EXPECT(good_end() && cda_status() == CDA_IDLE && !cdrom.unit.media, "eject: %02X", (unsigned)cda_status());
+
+	playing_mixed();
+	CD_Flags(1, IDEF_RST_SEEN);
+	EXPECT(cda_status() == CDA_IDLE, "Amiga reset: %02X", (unsigned)cda_status());
+
+	playing_mixed();
+	EXPECT(CD_Insert("GAME    CUE", "Game", iso_dir) == CD_OK && cda_status() == CDA_IDLE, "new disc: %02X",
+	       (unsigned)cda_status());
+	end();
+}
+
 int main(void)
 {
 	make_wav_header(wav_header, WAV_SECTORS * 2352, 2);
@@ -1147,6 +1283,9 @@
 	t_cue_names();
 	t_cue_refusals();
 	t_cue_config();
+	t_play();
+	t_play_refused();
+	t_play_stops();
 
 	printf("\n%d cases: %d passed, %d failed (%d failed checks)\n",
 	       cases_run, cases_passed, cases_run - cases_passed, total_fails);
--- a/fw/ctrl_832/test/Makefile
+++ b/fw/ctrl_832/test/Makefile
@@ -23,8 +23,8 @@
 cdaudio_test: cdaudio_test.c ../cdaudio.c ../cdaudio.h ../cue.c ../cue.h
 	$(HOSTCC) $(CFLAGS) -o $@ cdaudio_test.c ../cdaudio.c ../cue.c
 
-cdrom_test: cdrom_test.c ../cdrom.c ../cdrom.h ../atapi.c ../atapi.h ../cue.c ../cue.h ../hdd.h
-	$(HOSTCC) $(CFLAGS) -o $@ cdrom_test.c ../cdrom.c ../atapi.c ../cue.c
+cdrom_test: cdrom_test.c ../cdrom.c ../cdrom.h ../atapi.c ../atapi.h ../cue.c ../cue.h ../cdaudio.c ../cdaudio.h ../hdd.h
+	$(HOSTCC) $(CFLAGS) -o $@ cdrom_test.c ../cdrom.c ../atapi.c ../cue.c ../cdaudio.c
 
 run: cue_test cdaudio_test atapi_test cdrom_test
 	./cue_test
```

- [ ] **Step 2: Run, expected FAIL**

```bash
make -C fw/ctrl_832/test
```

Expected (the board glue does not implement the player's port yet; the path and the offset will differ):

```
../cdaudio.c:77:(.text+0x891): undefined reference to `cda_port_read'
collect2: error: ld returned 1 exit status
make: *** [Makefile:27: cdrom_test] Error 1
```

- [ ] **Step 3: Implementation**

```diff
--- a/fw/ctrl_832/cdrom.h
+++ b/fw/ctrl_832/cdrom.h
@@ -69,4 +69,9 @@
 /* A command for the CD unit; tfr = the 8 task file registers. */
 void CD_HandleCommand(int port, unsigned char *tfr);
 
+/* CD audio refill (13.1, 13.5): call from the main loop and between the
+   blocks of every SD transfer loop, never inside an SD multi-block read
+   or write.  Prints "CDA: underrun n" in DebugMode. */
+void CD_AudioPoll(void);
+
 #endif
--- a/fw/ctrl_832/cdrom.c
+++ b/fw/ctrl_832/cdrom.c
@@ -35,7 +35,11 @@
 #include "rafile.h"
 #include "atapi.h"
 #include "cue.h"
+#include "cdaudio.h"
 #include "cdrom.h"
+#ifndef HOSTTEST
+#include "drivesounds.h"
+#endif
 
 /* fat.c's directory state: lookups in the disc's directory put it back, so
    the OSD file browser does not move (or lose its ".." position). */
@@ -43,6 +47,9 @@
 
 cdromTYPE cdrom;
 
+static hdfTYPE cd_audio;		/* the disc file being played (13.5: the second open file) */
+static int cd_audio_file = -1;		/* its index in cd_disc.file[], -1 = none */
+static uint32_t cd_underruns;		/* cda_underruns() at the last report */
 static struct cd_disc cd_disc;		/* the disc in the drive */
 static struct cue_parser cd_cue;	/* 2.5 KB: static, the 832 stack is small */
 static RAFile cd_cuefile;		/* the CUE text */
@@ -89,6 +96,10 @@
 	char name[12];
 	char long_name[sizeof(hf->long_name) + 1];
 
+	cda_stop();
+	cda_init();
+	cd_audio.type = HDF_DISABLED;
+	cd_audio_file = -1;
 	cdrom.hdf.type = HDF_DISABLED;
 	cd_data_file = -1;
 	cdrom.slot = slot;
@@ -209,33 +220,39 @@
 	return cue_end(&cd_cue);
 }
 
-/* Disc file f in cdrom.hdf (the data file): reopened with a fresh cluster
-   index when another file is wanted. */
-static int cd_data_open(int f)
+/* Disc file f in h -- cdrom.hdf for reads, cd_audio for the player (13.5:
+   two open files) -- opened in the disc's directory with a fresh cluster
+   index when h holds another file; *open says which file h holds. */
+static int cd_hdf_open(hdfTYPE *h, int *open, int f)
 {
 	unsigned long cur, prev;
 	int ok;
-	if (cd_data_file == f && cdrom.hdf.type == HDF_FILE)
+	if (*open == f && h->type == HDF_FILE)
 		return 1;
-	cdrom.hdf.type = HDF_DISABLED;
-	cd_data_file = -1;
+	h->type = HDF_DISABLED;
+	*open = -1;
 	cur = iCurrentDirectory;
 	prev = iPreviousDirectory;
 	ChangeDirectory(cd_dir);
-	ok = FileOpen(&cdrom.hdf.file, cd_disc.file[f].shortname);
+	ok = FileOpen(&h->file, cd_disc.file[f].shortname);
 	iCurrentDirectory = cur;
 	iPreviousDirectory = prev;
 	if (!ok) {
 		ClearError(ERROR_FILESYSTEM);
 		return 0;
 	}
-	cdrom.hdf.type = HDF_FILE;
-	cdrom.hdf.offset = 0;
-	BuildHardfileIndex(&cdrom.hdf);
-	cd_data_file = f;
+	h->type = HDF_FILE;
+	h->offset = 0;
+	BuildHardfileIndex(h);
+	*open = f;
 	return 1;
 }
 
+static int cd_data_open(int f)
+{
+	return cd_hdf_open(&cdrom.hdf, &cd_data_file, f);
+}
+
 const char *CD_Message(void)
 {
 	return cd_msg;
@@ -290,9 +307,13 @@
 	return CD_OK;
 }
 
-/* The disc is out (OSD or Amiga eject): close the file, forget the name. */
+/* The disc is out (OSD or Amiga eject, or a new disc): the music stops,
+   the files close, the name is forgotten. */
 static void cd_drop_file(void)
 {
+	cda_stop();
+	cd_audio.type = HDF_DISABLED;
+	cd_audio_file = -1;
 	cdrom.hdf.type = HDF_DISABLED;	/* FAT files need no close */
 	cd_data_file = -1;
 	cd_config(0, 0, 0);
@@ -311,6 +332,7 @@
 {
 	if (DebugMode)
 		printf("CD: Amiga reset\r\n");
+	cda_stop();	/* 13.7: a reset stops the music */
 	atapi_reset(&cdrom.unit);
 }
 
@@ -332,6 +354,75 @@
 	return atapi_locked(&cdrom.unit);
 }
 
+/* ---- CD audio (13.5, 13.7): the player's port and its requests ---- */
+
+/* The player reads through the second open file. */
+int32_t cda_port_read(int32_t file, uint32_t block, uint8_t *dst)
+{
+	if (!cd_hdf_open(&cd_audio, &cd_audio_file, file))
+		return 0;
+	if (!HardFileSeek(&cd_audio, block))
+		return 0;
+	return FileRead(&cd_audio.file, dst) ? 1 : 0;
+}
+
+#ifndef HOSTTEST
+uint32_t cda_port_audio(void)
+{
+	return AUDIO;
+}
+
+void cda_port_control(uint32_t v)
+{
+	AUDIO = (unsigned char)v;
+}
+
+uint32_t cda_port_timer(void)
+{
+	return TIMER;
+}
+
+uint8_t *cda_port_ring(void)
+{
+	return (uint8_t *)AUDIO_BUFFER;
+}
+
+void cda_port_claim(void)
+{
+	drivesounds_yield();	/* 13.1: CD audio wins the buffer */
+}
+#endif
+
+void CD_AudioPoll(void)
+{
+	uint32_t n;
+	cda_poll();
+	n = cda_underruns();
+	if (n != cd_underruns) {
+		cd_underruns = n;
+		if (DebugMode)
+			printf("CDA: underrun %d\r\n", (int)n);
+	}
+}
+
+static void cd_audio_request(const struct atapi_result *r)
+{
+	switch (r->audio) {
+	case ATAPI_AUDIO_PLAY:
+		cda_play(&cd_disc, r->lba, r->lba + r->count);
+		break;
+	case ATAPI_AUDIO_PAUSE:
+		cda_pause();
+		break;
+	case ATAPI_AUDIO_RESUME:
+		cda_resume();
+		break;
+	case ATAPI_AUDIO_STOP:
+		cda_stop();
+		break;
+	}
+}
+
 /* ---- the Gayle side ---- */
 
 static unsigned char cd_error(void)
@@ -360,6 +451,7 @@
 	unsigned long timeout = GetTimer(CD_TIMEOUT);
 	unsigned char flags;
 	for (;;) {
+		CD_AudioPoll();	/* no SD transfer in flight here (13.5) */
 		flags = ReadIDEFlags(port);
 		CD_Flags(port, flags);
 		if (flags & IDEF_RST_SEEN)
@@ -426,6 +518,7 @@
 	HardFileSeek(&cdrom.hdf, block);
 	while (left) {
 		unsigned int n = left < per ? (unsigned int)left : per;
+		CD_AudioPoll();	/* between blocks, never inside FileReadEx (13.5) */
 		cd_phase(tfr, n << 9, 0x02, IDE_STATUS_RDY);
 		if (!FileReadEx(&cdrom.hdf.file, 0, n))
 			return cd_read_error(block + count * 4 - left);
@@ -537,6 +630,7 @@
 	case ATAPI_READ:     printf(" > read %lu+%lu", (unsigned long)r->lba, (unsigned long)r->count); break;
 	case ATAPI_RECEIVE:  printf(" < %u bytes", (unsigned)r->length); break;
 	case ATAPI_CHECK:    printf(" CHECK %02X/%02X/%02X", r->sense_key, r->asc, r->ascq); break;
+	case ATAPI_PLAY:     printf(" > audio %d", (int)r->audio); break;
 	default:             printf(" GOOD"); break;
 	}
 	printf("\r\n");
@@ -570,11 +664,14 @@
 	}
 	ReadIDEData(cd_cdb, 12);
 
+	atapi_audio_status(&cdrom.unit, cda_status(), cda_position());
 	atapi_packet(&cdrom.unit, cd_cdb, (uint16_t)limit, &r);
 	if (DebugMode)
 		cd_log_cdb(port, &r);
 	if (r.ejected)
 		cd_drop_file();
+	else if (r.audio)
+		cd_audio_request(&r);
 
 	switch (r.kind) {
 	case ATAPI_RESPONSE:
```

The poll points outside the CD glue, the drive sounds and the Makefile:

```diff
--- a/fw/ctrl_832/hdd.c
+++ b/fw/ctrl_832/hdd.c
@@ -504,7 +504,8 @@
 			block_count = hdf[unit].sectors_per_block;
 
 		WriteStatus(IDE_STATUS_RDY); // pio in (class 1) command type
-		while (!(GetFPGAStatus() & CMD_IDECMD)); // wait for empty sector buffer
+		while (!(GetFPGAStatus() & CMD_IDECMD)) // wait for empty sector buffer
+			CD_AudioPoll(); // CD audio refill between blocks (findings/cdrom/plan.md 13.5)
 
 		switch(hdf[unit].type)
 		{
@@ -616,7 +617,8 @@
 
 		while(block_count--)
 		{
-			while (!(GetFPGAStatus() & CMD_IDEDAT)); // wait for full write buffer
+			while (!(GetFPGAStatus() & CMD_IDEDAT)) // wait for full write buffer
+				CD_AudioPoll(); // CD audio refill between blocks (13.5)
 			EnableFpga();
 			SPI(CMD_IDE_DATA_RD | ide_port); // read data command
 			SPI(0x00); SPI(0x00); SPI(0x00); SPI(0x00); SPI(0x00);
--- a/fw/ctrl_832/fdd.c
+++ b/fw/ctrl_832/fdd.c
@@ -34,6 +34,7 @@
 #include "config.h"
 
 #include "drivesounds.h"
+#include "cdrom.h"
 
 #include <stdio.h>
 
@@ -222,6 +223,7 @@
 
     while (1)
     {
+        CD_AudioPoll(); // CD audio refill between sectors (findings/cdrom/plan.md 13.5)
         FileRead(&file, sector_buffer);
 
         EnableFpga();
--- a/fw/ctrl_832/main.c
+++ b/fw/ctrl_832/main.c
@@ -57,6 +57,7 @@
 #include "akiko.h"
 #include "interrupts.h"
 #include "drivesounds.h"
+#include "cdrom.h"
 #include "audio.h"
 #include "rtc.h"
 #include "version.h"
@@ -282,6 +283,7 @@
     while(1)
     {
 		drivesounds_fill();
+		CD_AudioPoll();	// CD audio refill (findings/cdrom/plan.md 13.1)
 		//if(c64keyboard_checkreset())
 		//	OsdDoReset(SPI_RST_USR | SPI_RST_CPU,0);
 
@@ -333,6 +335,7 @@
 				if(!ErrorFatal)
 					HandleFpga();
 		        HandleUI();
+				CD_AudioPoll();	// the music goes on behind an error page
             }
 		}
     }
--- a/fw/ctrl_832/drivesounds.h
+++ b/fw/ctrl_832/drivesounds.h
@@ -17,6 +17,7 @@
 void drivesounds_off();
 void drivesounds_queueevent(enum DriveSound_Type type);
 void drivesounds_stop();
+void drivesounds_yield();	/* the CD audio player takes the ring */
 void drivesounds_start();
 int drivesounds_fill();
 int drivesounds_init(const char *filename);
--- a/fw/ctrl_832/drivesounds.c
+++ b/fw/ctrl_832/drivesounds.c
@@ -6,6 +6,7 @@
 #include "rafile.h"
 
 #include "drivesounds.h"
+#include "cdaudio.h"
 
 extern char _bss_end__;
 
@@ -53,10 +54,19 @@
 void drivesounds_disable(int type)
 {
 	drivesounds.enabled&=~type;
-	if(!drivesounds.enabled)
+	if(!drivesounds.enabled && !cda_busy())	/* not the CD audio player's stream */
 		audio_stop();
 }
 
+/* The CD audio player takes the ring (findings/cdrom/plan.md 13.1): drop
+   what was playing and queued, without touching the AUDIO register. */
+void drivesounds_yield()
+{
+	drivesounds.active=0;
+	drivesounds.playing=0;
+	drivesounds.out=drivesounds.in;
+}
+
 
 void drivesounds_queueevent(enum DriveSound_Type type)
 {
@@ -345,6 +355,11 @@
 int drivesounds_fill()
 {
 	struct dsevent *dse;
+	if(cda_busy())	/* CD audio playing or paused: the drive sounds are silent (13.1) */
+	{
+		drivesounds.out=drivesounds.in;
+		return(0);
+	}
 	if(drivesounds.enabled && drivesounds.active)
 	{
 		while(dse=drivesounds_nextevent())
--- a/fw/ctrl_832/Makefile
+++ b/fw/ctrl_832/Makefile
@@ -59,7 +59,7 @@
 	$(BUILD_DIR)/osd.o $(BUILD_DIR)/rafile.o $(BUILD_DIR)/swap.o $(BUILD_DIR)/hexdump.o $(BUILD_DIR)/uart.o $(BUILD_DIR)/errors.o \
 	$(BUILD_DIR)/interrupts.o $(BUILD_DIR)/c64keys.o $(BUILD_DIR)/akiko.o \
 	$(BUILD_DIR)/audio.o $(BUILD_DIR)/drivesounds.o $(BUILD_DIR)/rtc.o $(BUILD_DIR)/i2c.o $(BUILD_DIR)/adv7511.o \
-	$(BUILD_DIR)/atapi.o $(BUILD_DIR)/cdrom.o $(BUILD_DIR)/cue.o
+	$(BUILD_DIR)/atapi.o $(BUILD_DIR)/cdrom.o $(BUILD_DIR)/cue.o $(BUILD_DIR)/cdaudio.o
 
 
 # all sources
```

- [ ] **Step 4: Run, expected PASS**

```bash
make -C fw/ctrl_832/test
make -C fw/ctrl_832 clean
make -C fw/ctrl_832 832DIR=/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64/EightThirtyTwo
grep -n '__bss_end__' fw/ctrl_832/832OSDAD.map | head -1
awk '$1 ~ /^0x/ && NF==2 && $2 ~ /^_/ {print $2}' fw/ctrl_832/832OSDAD.map | sort | uniq -d
```

Expected: `29 cases: 29 passed, 0 failed (0 failed checks)` from cdrom_test (the others unchanged); the firmware links (`_cda_poll`, `_CD_AudioPoll`, `_drivesounds_yield` in the map), `__bss_end__` at `0x0002a220`, duplicates: `_STACKTOP` only.

- [ ] **Step 5: Commit**

```bash
git add fw/ctrl_832/cdrom.h fw/ctrl_832/cdrom.c fw/ctrl_832/hdd.c fw/ctrl_832/fdd.c fw/ctrl_832/main.c \
        fw/ctrl_832/drivesounds.h fw/ctrl_832/drivesounds.c fw/ctrl_832/Makefile \
        fw/ctrl_832/test/cdrom_test.c fw/ctrl_832/test/Makefile
git commit -F- <<'EOF'
fw/ctrl_832: CD audio wired in: refill polls, play requests, drive sounds yield

findings/cdrom/plan.md 13.1, 13.5, 13.7: CD_AudioPoll() from the main
loop and between the blocks of the CD, hard disk and floppy transfers;
the player reads through the second open file; PLAY / PAUSE / RESUME /
STOP requests reach it, eject, Amiga reset and a new disc stop it.  The
drive sounds stay silent while the player owns the ring ("CDA: underrun
n" in DebugMode).

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
EOF
```

### Task 10: Build, stage, board test 3b (Paul)

**Files:** none changed.  Output: `/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64/build/cdfw_phase3b/832OSDAD.BIN`.

- [ ] **Step 1: Build and stage**

```bash
make -C fw/ctrl_832 clean
make -C fw/ctrl_832 832DIR=/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64/EightThirtyTwo
mkdir -p /home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64/build/cdfw_phase3b
cp fw/ctrl_832/832OSDAD.bin /home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64/build/cdfw_phase3b/832OSDAD.BIN
git log --oneline -1 > /home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64/build/cdfw_phase3b/COMMIT
git status --short fw/ctrl_832   # only version.h modified: leave it unstaged
```

- [ ] **Step 2: Board checklist 3b (Paul)**

Same bitstream and SD card as 3a, `832OSDAD.BIN` from `build/cdfw_phase3b`; DebugMode on, serial at 57600.

1. Pinball Fantasies from the CUE: the in-game music plays (track 2 / 3), no clicks at the half flips (every 186 ms), no `CDA: underrun` lines while nothing else runs.
2. A CD player program: play track 2, then skip to track 3 -- the elapsed time counts up, the track number changes at the boundary (track 3 starts with its 2 s INDEX 00 gap in the WAV); pause keeps the time and is silent, resume continues from there; stop.
3. Drive sounds (floppy and HDD sounds on): silent while a track plays or is paused, back after stop or at the end of the track.
4. Large hard-disk copy while music plays (e.g. 50 MB DH0: -> DH1: or RAM:): count the `CDA: underrun` lines; note the copy time with and without music (13.11: ~176 KB/s of SD bandwidth go to the music).
5. Load a floppy while music plays: count underruns; the floppy loads.
6. OSD eject while playing: the music stops at once; Amiga reset (Ctrl-A-A) while playing: stops; insert another disc while playing: stops.
7. Browse the OSD file picker in a subdirectory while a play crosses from track 2 to track 3 (the player opens the next WAV): the picker's position stays, ".." still returns to the directory you came from.
8. If an AHI / Akiko program can take the audio stream (`AUDIOF_AMIGA`): start it while music plays -- CD audio stops writing; when it ends, the music resumes near the position TIMER says (not from where it stopped).
9. Write down: underrun counts (idle, HDD copy, floppy), anything audible at track changes, the player program used.

## Step 3c -- READ CD, volume, OSD (13.8)

### Task 11: READ CD and the page 0E volume

**Files:**
- Modify: `fw/ctrl_832/atapi.h` (`ATAPI_BUF_SIZE` 2352, `ATAPI_READ_CD`, `atapi_unit.volume[2]`, `atapi_mode_select`), `fw/ctrl_832/atapi.c` (power-on volume, page 0E reports it, `read_cd`, MODE SELECT(6) 0x15 accepted, `atapi_mode_select`)
- Modify: `fw/ctrl_832/cdrom.c` (`cd_send_cdda`, `cd_read` sends audio sectors as CD-DA, `ATAPI_READ_CD` dispatch and log, `cd_receive` keeps the data and applies the volume)
- Test: `fw/ctrl_832/test/atapi_test.c` (`t_read_cd`, `t_volume`; BE and 15 leave the invalid list), `fw/ctrl_832/test/cdrom_test.c` (`t_read_cd`, `t_volume_select`), `fw/ctrl_832/test/emu/atapi_emu.c`

**Interfaces:**
- Consumes: `touches` (task 3), `cd_read`, `cd_data_open`, `cd_file_read`, `cd_send_buffer` (task 4), `cda_volume` (task 7).
- Produces: `#define ATAPI_READ_CD 6` (data in: `r->count` sectors from `r->lba`, 2048 bytes per data sector, 2352 per audio sector); `uint8_t atapi_unit.volume[2]` (0xFF at power-on); `void atapi_mode_select(struct atapi_unit *u, const uint8_t *cdb, const uint8_t *data, uint32_t len)`.

- [ ] **Step 1: Write the failing tests**

```diff
--- a/fw/ctrl_832/test/atapi_test.c
+++ b/fw/ctrl_832/test/atapi_test.c
@@ -795,10 +795,10 @@
 
 static void t_invalid(void)
 {
-	static const uint8_t ops[] = { 0xFF, 0x15, 0xBE, 0xB9, 0xD8, 0xD9, 0x04 };
+	static const uint8_t ops[] = { 0xFF, 0xB9, 0xD8, 0xD9, 0x04 };	/* BE and 15: phase 3 */
 	uint8_t c[12];
 	unsigned i;
-	begin("invalid opcodes and READ CD: 05/20/00");
+	begin("invalid opcodes, READ CD MSF and vendor reads: 05/20/00");
 	ready_unit(OS39_SECTORS, OS39_NAME);
 	for (i = 0; i < sizeof(ops); i++) {
 		cdb0(c, ops[i]);
@@ -1184,6 +1184,89 @@
 	end();
 }
 
+static void read_cd(uint8_t *c, uint8_t type, uint32_t lba, uint32_t count, uint8_t flags, uint8_t sub)
+{
+	cdb0(c, 0xBE);
+	c[1] = (uint8_t)(type << 2);
+	put_be32(c + 2, lba);
+	c[6] = (uint8_t)(count >> 16);
+	c[7] = (uint8_t)(count >> 8);
+	c[8] = (uint8_t)count;
+	c[9] = flags;
+	c[10] = sub;
+}
+
+static void t_read_cd(void)
+{
+	uint8_t c[12];
+	begin("READ CD: user data / CD-DA only, expected sector type checked, other selections 05/24/00");
+	ready_disc(pinball(), "Pinball Fantasies");
+	read_cd(c, 0, 2358, 2, 0x10, 0);
+	EXPECT(run(c) == ATAPI_READ_CD && R.lba == 2358 && R.count == 2, "CD-DA: kind %d lba %u count %u", R.kind, R.lba, R.count);
+	read_cd(c, 0, 2200, 200, 0x10, 0);	/* data and audio in one transfer */
+	EXPECT(run(c) == ATAPI_READ_CD && R.count == 200, "mixed: kind %d", R.kind);
+	read_cd(c, 1, 20000, 10, 0x10, 0);
+	EXPECT(run(c) == ATAPI_READ_CD, "type CD-DA on audio: kind %d", R.kind);
+	read_cd(c, 1, 2200, 10, 0x10, 0);
+	expect_check(__LINE__, c, 0x05, 0x64, 0x00);	/* CD-DA expected, data found */
+	read_cd(c, 2, 2200, 8, 0x10, 0);
+	EXPECT(run(c) == ATAPI_READ_CD, "type Mode 1 on data: kind %d", R.kind);
+	read_cd(c, 2, 2200, 9, 0x10, 0);
+	expect_check(__LINE__, c, 0x05, 0x64, 0x00);	/* Mode 1 expected, audio found */
+	read_cd(c, 4, 16, 1, 0x10, 0);
+	expect_check(__LINE__, c, 0x05, 0x64, 0x00);	/* Mode 2 form 1: no such track */
+	read_cd(c, 6, 16, 1, 0x10, 0);
+	expect_check(__LINE__, c, 0x05, 0x24, 0x00);
+	read_cd(c, 0, 2358, 1, 0xF8, 0);	/* sync + headers + user data + EDC */
+	expect_check(__LINE__, c, 0x05, 0x24, 0x00);
+	read_cd(c, 0, 2358, 1, 0x10, 0x01);	/* raw subchannel */
+	expect_check(__LINE__, c, 0x05, 0x24, 0x00);
+	read_cd(c, 0, 2358, 1, 0x00, 0);
+	expect_check(__LINE__, c, 0x05, 0x24, 0x00);
+	read_cd(c, 0, 2358, 0, 0x10, 0);
+	expect_good(__LINE__, c);
+	read_cd(c, 0, 41657, 2, 0x10, 0);
+	expect_check(__LINE__, c, 0x05, 0x21, 0x00);
+	end();
+}
+
+static void t_volume(void)
+{
+	/* MODE SELECT(10): 8-byte header, no block descriptor, page 0E */
+	static const uint8_t sel10[24] = {
+		0, 0, 0, 0, 0, 0, 0, 0,
+		0x0E, 0x0E, 0x04, 0, 0, 0, 0, 0, 0x01, 0x80, 0x02, 0x40, 0, 0, 0, 0
+	};
+	/* MODE SELECT(6): 4-byte header, an 8-byte block descriptor, page 01, page 0E */
+	static const uint8_t sel6[36] = {
+		0, 0, 0, 8,  0, 0, 0, 0, 0, 0, 0x08, 0,
+		0x01, 0x06, 0, 3, 0, 0, 0, 0,
+		0x0E, 0x0E, 0x04, 0, 0, 0, 0, 0, 0x01, 0x20, 0x02, 0x00, 0, 0, 0, 0
+	};
+	uint8_t c[12];
+	begin("MODE SELECT page 0E: per-channel volume, reported by MODE SENSE 0E");
+	ready_disc(pinball(), "Pinball Fantasies");
+	cdb0(c, 0x55);
+	c[8] = 24;
+	EXPECT(run(c) == ATAPI_RECEIVE && R.length == 24, "MODE SELECT(10): kind %d length %u", R.kind, R.length);
+	atapi_mode_select(&U, c, sel10, 24);
+	EXPECT(U.volume[0] == 0x80 && U.volume[1] == 0x40, "volume %02X %02X", U.volume[0], U.volume[1]);
+	mode_sense10(c, 0x0E, 0xFFFF);
+	expect_response(__LINE__, c, 24);
+	EXPECT(atapi_buf[8 + 9] == 0x80 && atapi_buf[8 + 11] == 0x40, "MODE SENSE 0E volumes %02X %02X",
+	       atapi_buf[8 + 9], atapi_buf[8 + 11]);
+	cdb0(c, 0x15);
+	c[4] = 36;
+	EXPECT(run(c) == ATAPI_RECEIVE && R.length == 36, "MODE SELECT(6): kind %d length %u", R.kind, R.length);
+	atapi_mode_select(&U, c, sel6, 36);
+	EXPECT(U.volume[0] == 0x20 && U.volume[1] == 0x00, "volume %02X %02X", U.volume[0], U.volume[1]);
+	atapi_mode_select(&U, c, sel6, 30);	/* cut inside page 0E: ignored */
+	EXPECT(U.volume[0] == 0x20, "a short page applied");
+	atapi_init(&U);
+	EXPECT(U.volume[0] == 0xFF && U.volume[1] == 0xFF, "power-on volume %02X %02X", U.volume[0], U.volume[1]);
+	end();
+}
+
 static void t_iso_read(const char *path)
 {
 	uint8_t c[12];
@@ -1276,6 +1359,8 @@
 	t_play();
 	t_subchannel();
 	t_audio_caps();
+	t_read_cd();
+	t_volume();
 	t_iso_read(path);
 
 	if (iso_fd >= 0)
--- a/fw/ctrl_832/test/cdrom_test.c
+++ b/fw/ctrl_832/test/cdrom_test.c
@@ -1252,6 +1252,67 @@
 	end();
 }
 
+/* ---- phase 3: READ CD, MODE SELECT volume ---- */
+
+static void t_read_cd(void)
+{
+	uint8_t c[12];
+	unsigned i;
+	int gap = 1, cdda = 1;
+	begin("READ CD: silent gap and WAV sectors as 2352-byte CD-DA, ISO sectors as 2048 user bytes");
+	EXPECT(insert_disc("MIXED   CUE", "Mixed") == CD_OK, "insert refused: '%s'", CD_Message());
+	memset(c, 0, 12);
+	c[0] = 0xBE;
+	c[4] = 0x00; c[5] = 212;	/* LBA 212: two PREGAP sectors, then track 2 */
+	c[8] = 4;
+	c[9] = 0x10;
+	packet(c, 0xFFFE);
+	EXPECT(h.phase_errors == 0 && h.blocks == 4 && h.block_bytes[0] == 2352 && h.block_bytes[3] == 2352,
+	       "blocks %d first %u", h.blocks, h.block_bytes[0]);
+	for (i = 0; i < 2 * 2352; i++) {
+		if (h.in[i])
+			gap = 0;
+		if (h.in[2 * 2352 + i] != wav_byte(44 + i))
+			cdda = 0;
+	}
+	EXPECT(h.in_len == 4 * 2352 && gap && cdda, "data: gap %d cdda %d", gap, cdda);
+	EXPECT(good_end(), "status phase");
+	c[5] = 62;	/* ISO sectors 62-63 */
+	c[8] = 2;
+	packet(c, 0xFFFE);
+	EXPECT(h.blocks == 1 && h.in_len == 4096 && iso_matches(62, 4096) && good_end(), "ISO through READ CD: blocks %d",
+	       h.blocks);
+	end();
+}
+
+static void t_volume_select(void)
+{
+	static const uint8_t mute[24] = {
+		0, 0, 0, 0, 0, 0, 0, 0,
+		0x0E, 0x0E, 0x04, 0, 0, 0, 0, 0, 0x01, 0x00, 0x02, 0x00, 0, 0, 0, 0
+	};
+	uint8_t c[12];
+	unsigned i;
+	int quiet = 1;
+	begin("MODE SELECT page 0E through the glue: the volume reaches the player (0 = silence)");
+	EXPECT(insert_disc("MIXED   CUE", "Mixed") == CD_OK, "insert refused: '%s'", CD_Message());
+	memset(c, 0, 12);
+	c[0] = 0x55;
+	c[8] = 24;
+	memcpy(h.out, mute, 24);
+	h.out_len = 24;
+	packet(c, 0xFFFE);
+	EXPECT(good_end() && cdrom.unit.volume[0] == 0 && cdrom.unit.volume[1] == 0, "volume %02X %02X",
+	       cdrom.unit.volume[0], cdrom.unit.volume[1]);
+	play10(c, 214, 10);
+	packet(c, 0xFFFE);
+	for (i = 0; i < 0x8000; i++)
+		if (ring[i])
+			quiet = 0;
+	EXPECT(cda_status() == CDA_PLAYING && quiet, "muted play: status %02X, ring silent %d", (unsigned)cda_status(), quiet);
+	end();
+}
+
 int main(void)
 {
 	make_wav_header(wav_header, WAV_SECTORS * 2352, 2);
@@ -1286,6 +1347,8 @@
 	t_play();
 	t_play_refused();
 	t_play_stops();
+	t_read_cd();
+	t_volume_select();
 
 	printf("\n%d cases: %d passed, %d failed (%d failed checks)\n",
 	       cases_run, cases_passed, cases_run - cases_passed, total_fails);
--- a/fw/ctrl_832/test/emu/atapi_emu.c
+++ b/fw/ctrl_832/test/emu/atapi_emu.c
@@ -213,6 +213,49 @@
 	atapi_audio_status(&unit, ATAPI_AUDIO_COMPLETED, 2457);
 	expect("status reported once", unit.audio_status, ATAPI_AUDIO_NONE);
 
+	/* READ CD of 2 audio sectors, user data / CD-DA */
+	memset(cdb, 0, sizeof(cdb));
+	cdb[0] = 0xBE;
+	cdb[4] = 0x09;
+	cdb[5] = 0x36;
+	cdb[8] = 2;
+	cdb[9] = 0x10;
+	k = atapi_packet(&unit, cdb, 0xFFFE, &res);
+	expect("READ CD return", k, ATAPI_READ_CD);
+	expect("READ CD kind", res.kind, ATAPI_READ_CD);
+	expect("READ CD lba", res.lba, 2358);
+	expect("READ CD count", res.count, 2);
+	cdb[9] = 0xF8;
+	k = atapi_packet(&unit, cdb, 0xFFFE, &res);
+	expect("READ CD 0xF8 kind", res.kind, ATAPI_CHECK);
+	expect("READ CD 0xF8 asc", res.asc, 0x24);
+
+	/* MODE SELECT(10) page 0E, then MODE SENSE 0E */
+	{
+		static const uint8_t sel[24] = {
+			0, 0, 0, 0, 0, 0, 0, 0,
+			0x0E, 0x0E, 0x04, 0, 0, 0, 0, 0, 0x01, 0x80, 0x02, 0x40, 0, 0, 0, 0
+		};
+		memset(cdb, 0, sizeof(cdb));
+		cdb[0] = 0x55;
+		cdb[8] = 24;
+		k = atapi_packet(&unit, cdb, 0xFFFE, &res);
+		expect("MODE SELECT kind", res.kind, ATAPI_RECEIVE);
+		expect("MODE SELECT length", res.length, 24);
+		atapi_mode_select(&unit, cdb, sel, 24);
+		expect("volume left", unit.volume[0], 0x80);
+		expect("volume right", unit.volume[1], 0x40);
+		expect("audio_seen after the volume", unit.audio_seen, ATAPI_AUDIO_COMPLETED);
+		memset(cdb, 0, sizeof(cdb));
+		cdb[0] = 0x5A;
+		cdb[2] = 0x0E;
+		cdb[8] = 0xFF;
+		k = atapi_packet(&unit, cdb, 0xFFFE, &res);
+		expect("MODE SENSE 0E length", res.length, 24);
+		expect("MODE SENSE 0E left", atapi_buf[17], 0x80);
+		expect("MODE SENSE 0E right", atapi_buf[19], 0x40);
+	}
+
 	if (fails)
 		printf("FAIL %d\n", fails);
 	else
```

- [ ] **Step 2: Run, expected FAIL**

```bash
make -C fw/ctrl_832/test
```

Expected (first lines):

```
atapi_test.c:1205:26: error: ‘ATAPI_READ_CD’ undeclared (first use in this function); did you mean ‘ATAPI_READ’?
atapi_test.c:1252:9: error: implicit declaration of function ‘atapi_mode_select’ [-Werror=implicit-function-declaration]
atapi_test.c:1253:17: error: ‘struct atapi_unit’ has no member named ‘volume’
```

- [ ] **Step 3: Implementation**

```diff
--- a/fw/ctrl_832/atapi.h
+++ b/fw/ctrl_832/atapi.h
@@ -23,7 +23,7 @@
 #include "cue.h"
 
 #define ATAPI_SECTOR_SIZE 2048
-#define ATAPI_BUF_SIZE    2048
+#define ATAPI_BUF_SIZE    2352	/* a raw CD-DA sector (READ CD) */
 #define ATAPI_NAME_LEN    40	/* IDENTIFY model field */
 
 /* atapi_packet() result kinds */
@@ -33,6 +33,7 @@
 #define ATAPI_RECEIVE  3	/* data out: accept length bytes, then GOOD */
 #define ATAPI_CHECK    4	/* CHECK CONDITION, sense in the result and the unit */
 #define ATAPI_PLAY     5	/* GOOD, no data phase, a request for the player in r->audio */
+#define ATAPI_READ_CD  6	/* data in: count sectors from lba, 2048 bytes of a data sector, 2352 of an audio one */
 
 /* atapi_result.audio: what the glue asks of the player (cdaudio.c); 0 = nothing.
    ATAPI_PLAY carries one; START STOP UNIT (stop, eject) carries STOP with
@@ -72,6 +73,7 @@
 	int32_t  audio_status;	/* the player's, ATAPI_AUDIO_PLAYING .. NONE (atapi_audio_status) */
 	uint32_t audio_lba;	/* the player's position */
 	int32_t  audio_seen;	/* COMPLETED / ERROR already reported by READ SUB-CHANNEL, 0 = not */
+	uint8_t  volume[2];	/* MODE SELECT page 0E: left, right, 0..255 */
 	char     name[ATAPI_NAME_LEN + 1];	/* ISO / CUE long name, printable ASCII */
 };
 
@@ -132,4 +134,9 @@
    into DRQ blocks with it.  Returns r->kind. */
 int atapi_packet(struct atapi_unit *u, const uint8_t *cdb, uint16_t limit, struct atapi_result *r);
 
+/* The data of a MODE SELECT(6)/(10) that ended in ATAPI_RECEIVE: len bytes
+   (header, block descriptors, pages).  Page 0E sets the volume; other
+   pages are ignored. */
+void atapi_mode_select(struct atapi_unit *u, const uint8_t *cdb, const uint8_t *data, uint32_t len);
+
 #endif
--- a/fw/ctrl_832/atapi.c
+++ b/fw/ctrl_832/atapi.c
@@ -63,7 +63,8 @@
 }
 
 /* Does [lba, lba + count) touch an audio track (audio = 1) or a data track
-   (audio = 0), gaps included?  The range is inside the disc. */
+   (audio = 0), gaps included?  The
+   range is inside the disc. */
 static int touches(const struct cd_disc *d, uint32_t lba, uint32_t count, int audio)
 {
 	struct cue_loc l;
@@ -152,6 +153,8 @@
 {
 	memset(u, 0, sizeof(*u));
 	u->audio_status = ATAPI_AUDIO_NONE;
+	u->volume[0] = 0xFF;
+	u->volume[1] = 0xFF;
 }
 
 void atapi_audio_status(struct atapi_unit *u, int32_t status, uint32_t lba)
@@ -286,10 +289,10 @@
 		p[0] = 0x0E;
 		p[1] = 0x0E;
 		p[2] = 0x04;	/* IMMED */
-		p[8] = 0x01;	/* port 0: channel 0, full volume */
-		p[9] = 0xFF;
-		p[10] = 0x02;	/* port 1: channel 1, full volume */
-		p[11] = 0xFF;
+		p[8] = 0x01;	/* port 0: channel 0 */
+		p[9] = u->volume[0];
+		p[10] = 0x02;	/* port 1: channel 1 */
+		p[11] = u->volume[1];
 		return p + 16;
 	case 0x2A:		/* capabilities: CD-ROM read, audio play (13.6) */
 		p[0] = 0x2A;
@@ -627,6 +630,30 @@
 	return play(u, r, start, end);
 }
 
+/* READ CD (BE): user data of data sectors (2048 bytes), CD-DA of audio
+   sectors (2352); no sync, headers, EDC/ECC, C2 or subchannel (13.6).
+   Expected sector type (byte 1 bits 4:2): 0 any, 1 CD-DA, 2 Mode 1; the
+   Mode 2 types match no track here. */
+static int read_cd(struct atapi_unit *u, const uint8_t *cdb, struct atapi_result *r)
+{
+	uint32_t lba = get32(cdb + 2);
+	uint32_t count = ((uint32_t)cdb[6] << 16) | ((uint32_t)cdb[7] << 8) | cdb[8];
+	uint8_t type = (cdb[1] >> 2) & 0x07;
+	if (cdb[9] != 0x10 || (cdb[10] & 0x07) || type > 5)
+		return ILLEGAL_FIELD(u, r);
+	if (!count)
+		return good(u, r);
+	if (lba >= u->sectors || count > u->sectors - lba)
+		return check(u, r, 0x05, 0x21, 0x00);
+	if (type > 2 || (type == 1 && touches(u->disc, lba, count, 0)) || (type == 2 && touches(u->disc, lba, count, 1)))
+		return check(u, r, 0x05, 0x64, 0x00);
+	set_sense(u, 0, 0, 0);
+	r->lba = lba;
+	r->count = count;
+	r->kind = ATAPI_READ_CD;
+	return ATAPI_READ_CD;
+}
+
 /* PAUSE/RESUME 4B, STOP PLAY/SCAN 4E: a request for the player. */
 static int audio_request(struct atapi_unit *u, struct atapi_result *r, int32_t what)
 {
@@ -702,14 +729,35 @@
 		return disc_information(u, cdb, r);
 	case 0x52:
 		return track_information(u, cdb, r);
-	case 0x55:	/* MODE SELECT(10): take the data, ignore it */
-		r->length = (uint16_t)get16(cdb + 7);
+	case 0x15:	/* MODE SELECT(6) */
+	case 0x55:	/* MODE SELECT(10): the data go to atapi_mode_select */
+		r->length = (uint16_t)(op == 0x15 ? cdb[4] : get16(cdb + 7));
 		if (!r->length)
 			return good(u, r);
 		set_sense(u, 0, 0, 0);
 		r->kind = ATAPI_RECEIVE;
 		return ATAPI_RECEIVE;
+	case 0xBE:
+		return read_cd(u, cdb, r);
 	}
-	/* READ CD (BE B9 D8 D9) lands here until phase 3 */
+	/* READ CD MSF (B9) and the vendor variants (D8 D9) land here */
 	return check(u, r, 0x05, 0x20, 0x00);
 }
+
+void atapi_mode_select(struct atapi_unit *u, const uint8_t *cdb, const uint8_t *data, uint32_t len)
+{
+	int six = cdb[0] == 0x15;
+	uint32_t p = six ? 4 : 8;	/* the parameter header */
+	if (len < p)
+		return;
+	p += six ? data[3] : get16(data + 6);	/* block descriptors */
+	while (p + 2 <= len) {
+		uint8_t code = data[p] & 0x3F;
+		uint32_t plen = data[p + 1];
+		if (code == 0x0E && plen >= 10 && p + 12 <= len) {	/* CD audio control */
+			u->volume[0] = data[p + 9];	/* port 0 = left; the mapping is fixed */
+			u->volume[1] = data[p + 11];	/* port 1 = right */
+		}
+		p += 2 + plen;
+	}
+}
--- a/fw/ctrl_832/cdrom.c
+++ b/fw/ctrl_832/cdrom.c
@@ -575,8 +575,35 @@
 	return CD_DONE;
 }
 
-/* READ(10)/(12): lba .. lba + count - 1, split where the track, its file
-   or its sector size changes (atapi.c has refused audio sectors). */
+/* Data in of count audio sectors as CD-DA (READ CD): 2352 bytes each from
+   the file, silence for a silent gap and past the end of a WAV's data. */
+static int cd_send_cdda(int port, unsigned char *tfr, const struct cue_loc *l, unsigned long count, unsigned int limit)
+{
+	unsigned long off = l->offset;
+	int r;
+	while (count) {
+		unsigned long have = 0;
+		if (!l->silent) {
+			const struct cd_file *f = &cd_disc.file[l->file];
+			unsigned long end = f->data_offset + f->data_bytes;
+			have = off < end ? end - off : 0;
+			if (have > 2352)
+				have = 2352;
+			if (have && (!cd_data_open(l->file) || !cd_file_read(off, atapi_buf, have)))
+				return cd_read_error(off >> 9);
+		}
+		memset(atapi_buf + have, 0, 2352 - have);
+		if ((r = cd_send_buffer(port, tfr, atapi_buf, 2352, limit)) != CD_DONE)
+			return r;
+		off += 2352;
+		count--;
+	}
+	return CD_DONE;
+}
+
+/* READ(10)/(12) and READ CD: lba .. lba + count - 1, split where the track,
+   its file or its sector size changes.  Audio sectors only come with READ
+   CD (atapi.c refuses them for READ(10)/(12)): CD-DA. */
 static int cd_read(int port, unsigned char *tfr, unsigned long lba, unsigned long count, unsigned int limit)
 {
 	struct cue_loc l;
@@ -586,7 +613,9 @@
 		if (!cue_locate(&cd_disc, lba, &l))
 			return cd_read_error(lba);
 		n = l.run < count ? l.run : count;
-		if (l.silent)
+		if (cd_disc.track[l.track].type == CD_AUDIO)
+			r = cd_send_cdda(port, tfr, &l, n, limit);
+		else if (l.silent)
 			r = cd_send_zero(port, tfr, n, limit);
 		else if (!cd_data_open(l.file))
 			r = cd_read_error(lba);
@@ -602,20 +631,30 @@
 	return CD_DONE;
 }
 
-/* Data out (MODE SELECT): taken and dropped, in blocks of at most the limit. */
+/* Data out (MODE SELECT), in blocks of at most the limit: what fits goes to
+   atapi_buf for atapi_mode_select (page 0E: the volume), the rest is
+   dropped. */
 static int cd_receive(int port, unsigned char *tfr, unsigned int len, unsigned int limit)
 {
+	unsigned int got = 0, kept = 0;
 	int r;
 	if (limit > CD_FIFO_512 * 512)
 		limit = CD_FIFO_512 * 512;
-	while (len) {
-		unsigned int n = len < limit ? len : limit;
+	while (got < len) {
+		unsigned int n = len - got < limit ? len - got : limit;
 		cd_phase(tfr, n, 0x00, IDE_STATUS_REQ | IDE_STATUS_IRQ);
 		if ((r = cd_wait(port)) != CD_DONE)
 			return r;
-		ReadIDEData(0, n);
-		len -= n;
+		if (kept == got && got + n <= ATAPI_BUF_SIZE) {
+			ReadIDEData(atapi_buf + got, n);
+			kept += n;
+		} else {
+			ReadIDEData(0, n);
+		}
+		got += n;
 	}
+	atapi_mode_select(&cdrom.unit, cd_cdb, atapi_buf, kept);
+	cda_volume(cdrom.unit.volume[0], cdrom.unit.volume[1]);
 	return CD_DONE;
 }
 
@@ -628,6 +667,7 @@
 	switch (r->kind) {
 	case ATAPI_RESPONSE: printf(" > %u bytes", (unsigned)r->length); break;
 	case ATAPI_READ:     printf(" > read %lu+%lu", (unsigned long)r->lba, (unsigned long)r->count); break;
+	case ATAPI_READ_CD:  printf(" > read cd %d+%d", (int)r->lba, (int)r->count); break;
 	case ATAPI_RECEIVE:  printf(" < %u bytes", (unsigned)r->length); break;
 	case ATAPI_CHECK:    printf(" CHECK %02X/%02X/%02X", r->sense_key, r->asc, r->ascq); break;
 	case ATAPI_PLAY:     printf(" > audio %d", (int)r->audio); break;
@@ -680,6 +720,9 @@
 	case ATAPI_READ:
 		done = cd_read(port, tfr, r.lba, r.count, limit);
 		break;
+	case ATAPI_READ_CD:
+		done = cd_read(port, tfr, r.lba, r.count, limit);
+		break;
 	case ATAPI_RECEIVE:
 		done = cd_receive(port, tfr, r.length, limit);
 		break;
```

- [ ] **Step 4: Run, expected PASS**

```bash
make -C fw/ctrl_832/test
make -C fw/ctrl_832/test/emu 832DIR=/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64/EightThirtyTwo
```

Expected: `26 cases: 26 passed, 0 failed, 0 skipped` (atapi_test), `31 cases: 31 passed, 0 failed` (cdrom_test), cue_test 11 and cdaudio_test 10 unchanged; emu `PASS` three times (atapi_emu checks `ATAPI_READ_CD` and the two `volume` bytes as vbcc832 stores them).

- [ ] **Step 5: Commit**

```bash
git add fw/ctrl_832/atapi.h fw/ctrl_832/atapi.c fw/ctrl_832/cdrom.c fw/ctrl_832/test/atapi_test.c \
        fw/ctrl_832/test/cdrom_test.c fw/ctrl_832/test/emu/atapi_emu.c
git commit -F- <<'EOF'
fw/ctrl_832: READ CD (user data, CD-DA) and the page 0E volume

findings/cdrom/plan.md 13.6: READ CD with the user-data selection sends
2048 bytes of a data sector and 2352 of an audio sector (silence for a
silent gap and past the end of a WAV); other selections and subchannel
data are 05/24/00, an expected sector type that does not match 05/64/00.
MODE SELECT(6)/(10) page 0E sets the per-channel volume the player uses
and MODE SENSE 0E reports.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
EOF
```

### Task 12: OSD play mark on the CD line, IDE port 2 line on the Harddisks page

**Files:**
- Modify: `fw/ctrl_832/cdrom.h` / `cdrom.c` (`CD_PlayingTrack`), `fw/ctrl_832/menu.c` (`cd_shown_track`, the CD line with the play mark, redraw on a track change, Harddisks page line 6 "IDE port 2" -> page 2, "back" moves to item 7), `fw/ctrl_832/charrom.h` (glyph 0x19: a note)
- Test: `fw/ctrl_832/test/cdrom_test.c` (`t_playing_track`)

**Interfaces:**
- Consumes: `cda_busy`, `cda_position` (task 7), `cue_locate`, `cd_disc` (tasks 1, 4).
- Produces: `int CD_PlayingTrack(void)` (track number while playing or paused, else 0); character 0x19 = note.

The CD line (32 columns): ` CD-ROM: ` (9) + the name (21 characters, 17 while the play mark is shown) + the play mark at columns 27-29 (`0x19` + two digits) + the lock mark at column 31.  `MENU_MAIN2` redraws the page when `CD_PlayingTrack()` differs from what is shown.

- [ ] **Step 1: Write the failing test**

```diff
--- a/fw/ctrl_832/test/cdrom_test.c
+++ b/fw/ctrl_832/test/cdrom_test.c
@@ -1313,6 +1313,25 @@
 	end();
 }
 
+static void t_playing_track(void)
+{
+	uint8_t c[12];
+	begin("CD_PlayingTrack: the track while playing or paused, 0 otherwise (the OSD's play mark)");
+	EXPECT(insert_disc("MIXED   CUE", "Mixed") == CD_OK, "insert refused: '%s'", CD_Message());
+	EXPECT(CD_PlayingTrack() == 0, "track %d before any play", CD_PlayingTrack());
+	play10(c, 214, 10);
+	packet(c, 0xFFFE);
+	EXPECT(CD_PlayingTrack() == 2, "playing: track %d", CD_PlayingTrack());
+	memset(c, 0, 12);
+	c[0] = 0x4B;	/* PAUSE */
+	packet(c, 0xFFFE);
+	EXPECT(CD_PlayingTrack() == 2, "paused: track %d", CD_PlayingTrack());
+	c[0] = 0x4E;	/* STOP */
+	packet(c, 0xFFFE);
+	EXPECT(CD_PlayingTrack() == 0, "stopped: track %d", CD_PlayingTrack());
+	end();
+}
+
 int main(void)
 {
 	make_wav_header(wav_header, WAV_SECTORS * 2352, 2);
@@ -1349,6 +1368,7 @@
 	t_play_stops();
 	t_read_cd();
 	t_volume_select();
+	t_playing_track();
 
 	printf("\n%d cases: %d passed, %d failed (%d failed checks)\n",
 	       cases_run, cases_passed, cases_run - cases_passed, total_fails);
```

- [ ] **Step 2: Run, expected FAIL**

```bash
make -C fw/ctrl_832/test
```

Expected:

```
cdrom_test.c:1321:16: error: implicit declaration of function ‘CD_PlayingTrack’; did you mean ‘t_playing_track’? [-Werror=implicit-function-declaration]
cc1: all warnings being treated as errors
make: *** [Makefile:27: cdrom_test] Error 1
```

- [ ] **Step 3: Implementation**

```diff
--- a/fw/ctrl_832/cdrom.h
+++ b/fw/ctrl_832/cdrom.h
@@ -74,4 +74,8 @@
    or write.  Prints "CDA: underrun n" in DebugMode. */
 void CD_AudioPoll(void);
 
+/* The track the player is in (playing or paused), 0 when it is not: the
+   OSD's play mark (13.8 step 3c). */
+int CD_PlayingTrack(void);
+
 #endif
--- a/fw/ctrl_832/cdrom.c
+++ b/fw/ctrl_832/cdrom.c
@@ -405,6 +405,14 @@
 	}
 }
 
+int CD_PlayingTrack(void)
+{
+	struct cue_loc l;
+	if (!cda_busy() || !cdrom.unit.media || !cue_locate(&cd_disc, cda_position(), &l))
+		return 0;
+	return cd_disc.track[l.track].number;
+}
+
 static void cd_audio_request(const struct atapi_result *r)
 {
 	switch (r->audio) {
```

```diff
--- a/fw/ctrl_832/menu.c
+++ b/fw/ctrl_832/menu.c
@@ -237,6 +237,7 @@
 static unsigned long cd_msg_timer;
 static char cd_msg_on;
 static const char *cd_msg_text;
+static int cd_shown_track;	// the track in the main page's play mark, 0 = none
 
 static void cd_show_msg(const char *text)
 {
@@ -741,23 +742,32 @@
         else
         {
             menumask |= 0x40;
+            cd_shown_track = CD_PlayingTrack();
             if (cd_msg_on)
                 sprintf(s, " CD-ROM: %s", cd_msg_text);
             else if (!cdrom.unit.media)
                 strcpy(s, " CD-ROM: * no disc *");
             else
-            {
-                // strncat: lib832's printf has no precision (it printed "21s" here)
+            {   // the name, the play mark (note + track) at columns 27-29, the
+                // lock mark at column 31.  strncat: lib832's printf has no
+                // precision (it printed "21s" here).
+                char locked = CD_Locked();
                 strcpy(s, " CD-ROM: ");
-                strncat(s, cdrom.unit.name, 21);
-                if (CD_Locked())
-                {   // the lock mark at column 31
+                strncat(s, cdrom.unit.name, cd_shown_track ? 17 : 21);
+                if (cd_shown_track || locked)
+                {
                     len = strlen(s);
                     while (len < 31)
                         s[len++] = ' ';
-                    s[31] = 0x17;
+                    s[31] = locked ? 0x17 : ' ';
                     s[32] = 0;
                 }
+                if (cd_shown_track)
+                {
+                    s[27] = 0x19; // note (charrom.h)
+                    s[28] = (char)('0' + cd_shown_track / 10);
+                    s[29] = (char)('0' + cd_shown_track % 10);
+                }
             }
             OsdWrite(6, s, menusub == 6, 0);
         }
@@ -768,8 +778,8 @@
         break;
 
     case MENU_MAIN2:
-        if (cd_msg_expired())
-            menustate = MENU_MAIN1;
+        if (cd_msg_expired() || (CD_SLOT() >= 0 && CD_PlayingTrack() != cd_shown_track))
+            menustate = MENU_MAIN1; // a message ended, or the play mark changed
         if (menu)
             menustate = MENU_NONE1;
         else if (plus && (config.floppy.drives < 3))
@@ -1900,7 +1910,9 @@
         OsdSetTitle("Harddisks", (core_caps & CORE_CAPS_IDE2) ? OSD_ARROW_RIGHT : 0);
 
         parentstate = menustate;
-        menumask = 0x41; // b01000001 - On/off & exit enabled by default...
+        menumask = 0x81; // b10000001 - On/off & exit enabled by default...
+        if (core_caps & CORE_CAPS_IDE2)
+            menumask |= 0x40; // the IDE port 2 line (12.6: the title arrow alone was not found)
         strcpy(s, "    IDE : ");
         strcat(s, t_enable_ide ? "on " : "off");
         OsdWrite(0, s, menusub == 0, 0);
@@ -1913,8 +1925,11 @@
         strcpy(s, " Sounds : ");
         strcat(s, config.drivesounds & DRIVESOUNDS_HDD ? "on " : "off");
         OsdWrite(5, s, menusub == 5, t_enable_ide == 0);
-        OsdWrite(6, "", 0, 0);
-        OsdWrite(7, STD_BACK, menusub == 6, 0);
+        if (core_caps & CORE_CAPS_IDE2)
+            OsdWrite(6, " IDE port 2 \x16", menusub == 6, 0);
+        else
+            OsdWrite(6, "", 0, 0);
+        OsdWrite(7, STD_BACK, menusub == 7, 0);
 
         menustate = MENU_SETTINGS_HARDFILE2;
 
@@ -1948,7 +1963,12 @@
                     drivesounds_disable(DRIVESOUNDS_HDD);
                 menustate = MENU_SETTINGS_HARDFILE1;
             }
-            else if (menusub == 6) // return to previous menu
+            else if (menusub == 6) // IDE port 2 (the line is only there on a two-port core)
+            {
+                menustate = MENU_SETTINGS_HARDFILE3;
+                menusub = 0;
+            }
+            else if (menusub == 7) // return to previous menu
             {
                 menustate = MENU_HARDFILE_EXIT;
             }
--- a/fw/ctrl_832/charrom.h
+++ b/fw/ctrl_832/charrom.h
@@ -54,7 +54,7 @@
         {0x00,0x7C,0x7C,0x38,0x38,0x10,0x10,0x00},         // 22   [0x16] mini arrow right
         {0x70,0x7c,0x72,0x72,0x72,0x7c,0x70,0x00},         // 23   [0x17] write protect
         {0x70,0x70,0x70,0x70,0x7c,0x72,0x02,0x0c},         // 24   [0x18] write enable
-        {0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00},         // 25   [0x19]
+        {0x20,0x70,0x70,0x3F,0x01,0x02,0x04,0x00},         // 25   [0x19] note: CD audio playing (menu.c)
         {0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00},         // 26   [0x1a]
         {0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00},         // 27   [0x1b]
         {0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00},         // 28   [0x1c]
```

- [ ] **Step 4: Run, expected PASS**

```bash
make -C fw/ctrl_832/test
make -C fw/ctrl_832 clean
make -C fw/ctrl_832 832DIR=/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64/EightThirtyTwo
grep -n '__bss_end__' fw/ctrl_832/832OSDAD.map | head -1
awk '$1 ~ /^0x/ && NF==2 && $2 ~ /^_/ {print $2}' fw/ctrl_832/832OSDAD.map | sort | uniq -d
```

Expected: `32 cases: 32 passed, 0 failed (0 failed checks)` from cdrom_test; the firmware links, `__bss_end__` at `0x0002a920`, duplicates: `_STACKTOP` only.

- [ ] **Step 5: Commit**

```bash
git add fw/ctrl_832/cdrom.h fw/ctrl_832/cdrom.c fw/ctrl_832/menu.c fw/ctrl_832/charrom.h fw/ctrl_832/test/cdrom_test.c
git commit -F- <<'EOF'
fw/ctrl_832: OSD play mark on the CD line, IDE port 2 line on the Harddisks page

findings/cdrom/plan.md 13.8 step 3c, 12.6: while a track plays or is
paused the main page's CD line ends in a note and the track number (new
glyph 0x19), redrawn when the track changes.  The Harddisks page gets a
selectable "IDE port 2" line on a two-port core (the title arrow alone
was not found on the board).

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
EOF
```

### Task 13: Build, stage, board test 3c (Paul)

**Files:** none changed.  Output: `/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64/build/cdfw_phase3c/832OSDAD.BIN`.

- [ ] **Step 1: Build and stage**

```bash
make -C fw/ctrl_832 clean
make -C fw/ctrl_832 832DIR=/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64/EightThirtyTwo
mkdir -p /home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64/build/cdfw_phase3c
cp fw/ctrl_832/832OSDAD.bin /home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64/build/cdfw_phase3c/832OSDAD.BIN
git log --oneline -1 > /home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64/build/cdfw_phase3c/COMMIT
git status --short fw/ctrl_832   # only version.h modified: leave it unstaged
```

- [ ] **Step 2: Board checklist 3c (Paul)**

Same bitstream and SD card, `832OSDAD.BIN` from `build/cdfw_phase3c`.

1. Main page while track 2 plays: line 6 ends in `<note>02` at columns 27-29; it turns `03` when the play reaches track 3 (without a key press); it stays while paused; it is gone after stop.  With the drive locked by the Amiga the padlock is still at column 31.
2. Harddisks page: line 6 reads `IDE port 2` with an arrow; select it -> the IDE port 2 page; `back` is the last item and leaves the page; on page 2, cursor left still returns.
3. A program that reads audio with READ CD (a CD ripper; in DebugMode the CDB log line ends in `> read cd <lba>+<count>`): rip track 2 and compare with the WAV's data (e.g. `cmp` the rip against `tail -c +45` of the WAV on the PC: equal, apart from a padding tail of the last sector).  A selection the plan refuses (0xF8) ends in CHECK 05/24/00 in the log -- note which programs send it.
4. A player with a volume control (MODE SELECT page 0E): lower, mute, raise -- the change is heard at the next half (within ~0.2 s); MODE SENSE 0E reads the values back.
5. Write down: rip comparison result, programs that use READ CD and with which selection byte, any volume control that does not take.

## Self-review

**Spec coverage (section 13):**

| Spec item | Task(s) |
|---|---|
| 13.1 both CUE layouts | 1, 2, 4 (ISO+WAV and BIN/CUE in `cdrom_test`, reference CUE in `cue_test`) |
| 13.1 CD audio wins the buffer, `AUDIOF_AMIGA` yields | 7 (`t_amiga`), 9 (`drivesounds_fill`/`yield`), 10 items 3 and 8 |
| 13.1 refill by cooperative polling, never inside an SD multi-block op | 9 (`cd_wait`, `cd_send_sectors`, ATA waits, `ReadTrack`, main loop) |
| 13.1 refusals with an OSD message, no half-mounted disc | 1, 2 (`t_refusals`, `t_wav`), 4 (`t_cue_refusals`), 5 (`cd_insert_msg`) |
| 13.1 bincue.c / audiotrack.c replaced, `struct cdimage cd` gone | 5 |
| 13.2 ring, AUDIO, TIMER, 588 frames, no byte swap | 7 (port, model), 9 (hardware port) |
| 13.3 units and their tests | 1-4, 7-9, 11 (host), 1-3, 7, 8, 11 (emu) |
| 13.4 structs, accepted / ignored commands, CRLF, quotes | 1 (`t_ignored`, `t_chunks`, `t_bincue`) |
| 13.4 layout, PREGAP / POSTGAP / INDEX 00, lead-out, reference layout | 1 (`t_reference`, `t_pregap_postgap`, `t_implicit_gap`) |
| 13.4 WAV chunk walk, partial last sector | 2 (`t_wav`), 7 (`t_stream`), 11 (`cd_send_cdda`) |
| 13.4 parse error names the line, unknown command refused | 1 (`t_refusals`, `cue_message`) |
| 13.5 picker ISO + CUE | 5 (`ExtensionMatch`, `"ISOCUE"`) |
| 13.5 ISO = one DATA2048 track | 3 (`cue_single` in `CD_Insert`), 4 |
| 13.5 CUE insert, lookup by long name, drive name, config keeps the CUE | 4 (`t_cue_*`, spec issue 1) |
| 13.5 two open files | 4 (`cdrom.hdf`), 9 (`cd_audio`) |
| 13.5 READ paths, split at a boundary, audio -> 05/64/00 | 3 (`t_read_audio`), 4 (`t_cue_bincue`, `t_cue_split`) |
| 13.5 poll points | 9 |
| 13.6 43 TOC | 3 (`t_toc_tracks`) |
| 13.6 45 A5 47 48 4B 4E 1B | 8 (`t_play`), 9 (`t_play_stops`) |
| 13.6 42 SUB-CHANNEL, 13/14 once | 8 (`t_subchannel`), 9 (`t_play`) |
| 13.6 1A 5A / 15 55 page 0E volume | 11 (`t_volume`, `t_volume_select`) |
| 13.6 2A audio bit, 46 feature 0103h | 8 (`t_audio_caps`) |
| 13.6 BE READ CD | 11 (`t_read_cd` in both tests) |
| 13.6 atapi.c without SD / hardware; emu for new fields | 3, 8, 11 |
| 13.7 states, start, refill, end by TIMER, position, volume, late refill, AMIGA, pause | 7 (`cdaudio_test`, `cdaudio_emu`) |
| 13.7 eject / reset / disc change stop | 9 (`t_play_stops`) |
| 13.8 3a / 3b / 3c host tests and board tests | 1-5 + 6, 7-9 + 10, 11-12 + 13 |
| 13.8 OSD play indicator, IDE port 2 line | 12 |
| 13.9 reference disc | 1, 3 (embedded CUE), 6 (board) |
| 13.10 memory | measured: task 5, 9, 12 `__bss_end__` (Clarifications) |
| 13.11 SD bandwidth, poll coverage, shared FAT cache, vbcc832 | 10 items 4-5, 9, accepted (extra FAT reads), emu tests |

**Placeholder scan:** no TBD / TODO / "similar to"; every step has its code or command and its expected output.  **Names and types:** every function or constant a task consumes is produced by an earlier task with the same signature (checked against the Interfaces lines; the prototype built every task in order).  **Review Focus:** each of the five items maps to a named test in its owning task.

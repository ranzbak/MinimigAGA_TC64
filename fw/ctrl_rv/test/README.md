# Host tests of fw/ctrl_rv

`make -C fw/ctrl_rv/test` builds and runs every host test twice, native (LP64)
and `-m32` (ILP32, like RV32), and runs the format-parity gate. The exit status
is the result. `make -C fw/ctrl_rv/test mutants` checks that the tests can
fail.

## Setup (fresh Ubuntu 24.04)

The commands work in bash and zsh, from the repository root:

```sh
sudo apt install build-essential gcc-multilib python3 git mtools dosfstools fdisk
git submodule update --init EightThirtyTwo
make -C fw/ctrl_rv/test
```

The submodule is lib832, the 832's printf and the format-parity reference
(`small_printf.c`). Where it cannot be initialised (no network), or when a
checkout of EightThirtyTwo exists elsewhere, leave the `git submodule` line
out and name the lib832 directory:

```sh
make -C fw/ctrl_rv/test LIB832=/path/to/EightThirtyTwo/lib832
```

The mutant check (every test must go red on its mutants):

```sh
make -C fw/ctrl_rv/test mutants
```

* `build-essential` brings `objcopy` (binutils), which renames the symbols of `fdd_test`'s 832 `fdd.c`.
* `gcc-multilib` is for the `-m32` builds (with AddressSanitizer and UBSan);
  `python3` runs the golden generators and `fmtcheck.py` (standard library
  only, `python3 -I`); `mtools dosfstools fdisk` are what
  `tools/sim/mkcard.sh` needs for the card image of `mock_selftest`, and what
  `fatimg.sh` / `fat_check.sh` use for the images of `fat_test` (`sfdisk`,
  `mkfs.fat`, `fsck.fat`, `mcopy`, `mdel`, `mmd`, `mdir`, `mshowfat`, `mtype`;
  no root, no loop devices). Those images take about 170 MB in `out/` (the
  FAT32 one is 132 MB: FAT32 needs at least 65525 clusters); `hdd_test`'s
  card and hardfiles (`out/hdd/`) another 48 MB, `drivesounds_test`'s card
  and ring snapshots (`out/ds/`) 4 MB.
* `LIB832` defaults to `EightThirtyTwo/lib832` of the repository. Another
  checkout: `make -C fw/ctrl_rv/test LIB832=/path/to/EightThirtyTwo/lib832`.
  A missing `LIB832` fails the run, it never skips the format check.
* `config_test` takes `CFG832_DIR=<dir>` (optional): every file there, real
  832 config files such as copies from an SD card, gets the same round trip
  as the generated cases (`cfgconv --to-rv`, `--to-832` back to the same
  bytes, the same fields in both `--check` outputs), e.g.
  `make -C fw/ctrl_rv/test run-config_test CFG832_DIR="$PWD/build/cfg832"`
  from the repository root (`fw/ctrl_rv/tools/cfgconv/README.md`).
  There is no config file in the repository.
* `drivesounds_test` loads `sw/mkdrivesounds/drivesnd.bin` (`DRIVESND=<file>`
  names another; its scenario is written for that file's sound lengths, and
  `gold/drivesounds.py` fails when a case no longer reaches what it must).
* `atapi_test` has ISO-backed cases. `ISO=<file>` names the ISO (default
  `~/work/amiga/AmigaOS3.9.iso`); every run is repeated with a name that does
  not exist, where those cases are skipped, not failed.
* To check that the hooks leave the target image alone (needs the RISC-V
  toolchain, `bash tools/riscv/fetch-xpack.sh`, `bash tools/riscv/check-toolchain.sh`):
  build `fw/ctrl_rv` before and after a change with the same clock, e.g.
  `make -C fw/ctrl_rv B=/tmp/before` and `... B=/tmp/after` with a `date` that
  does not move (the version string holds the minute), then `cmp` the two
  `RV32OSDA.BIN`.

Output goes to `fw/ctrl_rv/test/out/` and `mut/` (both ignored by git);
`make -C fw/ctrl_rv/test clean` removes them.

## Writing a test

* **A timeout test must assert `mock_timer_reads()`.** The mock advances the
  TIMER on every read (`mock_timer_step()`, default 1) so that a
  `CheckTimer()` loop always ends. A loop whose bound is far too long ends
  all the same: the test passes, silently. So a test of a timeout checks the
  bound itself: the bytes in the SPI trace and `mock_timer_reads()` inside a
  window (`mmc_test` does this for the five `SD_TIMEOUT` loops: 173..174 wait
  bytes, 174..175 reads). A bare "the call failed" proves nothing.
* **A register that has no `-DHOSTTEST` hook crashes the test.** Hooked are
  `SPI`/`RDSPI`, the chip selects, `SPI_slow`/`SPI_fast`, `TIMER`,
  `PLATFORM`, `AUDIO`, `RS232` and `AUDIO_BUFFER` (the `HOSTTEST` block at
  the end of `fw/ctrl_rv/hardware.h`). Every other register macro still
  dereferences its real address (`0xFFFFFFxx`, or `0xDEExxx`), which is not
  mapped on the host: a test that reaches the keyboard (`HW_KEYBOARD`),
  Akiko, the RTC, I2C, `VIDEOSCALE`, `FPGA_TEMP_RAW`, the interrupt
  controller (`GetInterrupts`, `EnableInterrupts`, ...) or `RECONFIGURE` dies
  with SIGSEGV. Such a test needs a new hook: a `HOSTTEST` macro or function
  in `hardware.h` (the target build drops the block, so the image stays the
  same bytes), a model in `mock_hw.c`/`mock_hw.h`, and a mutant for it.
* **Every new test has a mutant** (`mutants.sh`, below) and a golden that does
  not come from the code under test.

## Targets

| Target | What |
|---|---|
| `run` (default) | `fmt` and every `run-<test>` |
| `run-<test>` | one test, native then `-m32` (`run64-<test>`, `run32-<test>`: one of them) |
| `fmt` (`fmt.ok`) | the format-parity gates of `rvlibc.c` against glibc and lib832 (below) |
| `mutants` | `mutants.sh`: each mutant must make the real test target fail |
| `clean` | remove `out/` and `mut/` |

Flags: `-std=gnu2x -funsigned-char -D_DEFAULT_SOURCE -DHOSTTEST -Wall -Wextra -Wno-unused-parameter -Werror -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all`
plus `-U_FORTIFY_SOURCE -D__NO_INLINE__ -fno-builtin` (glibc must not rewrite
`putchar`/`printf`, and `printf("..\n")` must not become the firmware's `puts`).
`-funsigned-char` is the firmware's `char` (`tools/riscv/toolchain.mk`; x86
gcc defaults to signed): added by the final review (I2), every test passed
unchanged with it.
The unmodified 832 source of the format reference (lib832 `small_printf.c`) is
built `-std=gnu17 -m32 -funsigned-char`, like the 832 firmware.

## Tests

| Test | Covers |
|---|---|
| `mock_selftest` | the mock below: scripted replies per chip select, the `spi.txt` trace, TIMER, UART, PLATFORM, AUDIO, the card model by hand and under the real `mmc.c` (`MMC_Init`, `MMC_Read`, `MMC_ReadMultiple`, `MMC_Write`) |
| `cue_test`, `cdaudio_test`, `atapi_test`, `cdrom_test`, `openhf_test` | the CD-ROM code (CUE parser and disc model, CD audio player, ATAPI commands, the Gayle glue, `OpenHardfile` on a CD slot); unchanged from the 832 tests except for the dialect. `openhf_test` still builds `OpenHardfile` alone, cut out of `hdd.c` by `sed`, with stubs for the FAT calls: `hdd.c` as a whole builds under `HOSTTEST` now (`hdd_test` links it), but the cut keeps the stubs the only FAT `OpenHardfile` sees there |
| `lib_test` | `rvlibc.c` against glibc's `vsnprintf` (output, return value, truncation, nesting, heap stubs) |
| `hwmap_test` | with the real macros (`-DHOSTTEST` undefined in that file): address and width of every register, the CS/SPEED values of `Enable*()`/`Disable*()`/`SPI_slow()`/`SPI_fast()`, `SPI()`/`RDSPI` order, the real `RS232()` expansion, `uart.c` `puts` |
| `fmt` | format strings of the firmware: ILP32 == LP64, `fmtcheck.py` model, the 832-versus-RV differences are exactly `gold/fmt_diff_expected.txt` |
| `swap_test` | `../swap.h` and `../swap.c`: `le16/le32/be16/be32` by the bytes they leave in memory (true on any host) and by value on this LE host, `rd_le16/rd_le32/rd_be16/rd_be32` and `wr_be16/wr_be32` at offsets 0..3 of an aligned buffer (a pointer cast would be a misaligned access there, which UBSan stops), `SwapBB/SwapBBBB/SwapWW` without sign extension on LP64 |
| `fat_test` | the real `fat.c` over the real `mmc.c` on the card model, once per image (below): `FindDrive()` (FAT type, partition start and size against the MBR bytes, cluster size), every directory through `ScanDirectory` (names, sizes, start clusters, long names) against `mdir -/ -a` + `mshowfat` (`gold/fatlist.py`), `FileOpen` + `FileRead`/`FileNextSector`, `FileSeek` and `FileReadEx` of a 300 KB file fragmented over a deleted file's clusters, a subdirectory walk with long names (`FindDirectory`, `ChangeDirectory`, `FileOpen` by long name, `ValidateDirectory`, `FindDirectoryByCluster`), `HIGH.BIN` (on FAT32 above cluster 65535: `HighCluster`), `FileOpen` by long name of a file in the second cluster of a two-cluster directory (`GetFATLink`), a name that does not exist, and `FileCreate` + 3 x `FileWrite` + `UpdateEntry` of a 3-sector file (on FAT32 above cluster 65535), read back through `fat.c`, its raw directory entry (create/access date, create time, start cluster, `HighCluster`) against the FAT layout, then `fsck.fat -n` of the written image, `mtype` of the file and `mdir` of its modify date and time (`fat_check.sh`) |
| `config_test` | the config file's byte order (Task 11; `config_test.c`, `config_check.sh`): the generated 832 files, `cfgconv`, `cfg_order`/`cfg_swap`, and `LoadConfiguration`/`ConfigurationExists` on card images; the cases are the table "`config_test` cases" below |
| `hdd_test` | the hard disk emulation (Task 12; `hdd_test.c`): the real `hdd.c` over the real `fat.c` + `mmc.c` on the card model, driven through `HandleHDD()` by a mock Gayle on the FPGA chip select (the status byte of each frame: `CMD_IDECMD` / `CMD_IDEDAT`; `CMD_IDE_REGS_RD`/`_WR`, `_STATUS_WR`, `_DATA_WR`/`_RD`; a 16-sector FIFO: in pio in a poll that finds data answers busy and the "Amiga" reads it all, one chunk, the next poll answers drained; in pio out every other poll finds a sector written). `gold/rdb.py` writes the expected RDSK and PART blocks (big-endian, from the field offsets of `devices/hardblocks.h`, checksum over the finished block) for a 2 MB, a 2 GB and an odd (20001 blocks) hardfile without RDB, with the geometry by WinUAE's rule, and three HDF files (`WORK.HDF` 4 MB with its own RDB, Flags 0x17; `SYNTH.HDF`; `ODD.HDF`) that the Makefile puts on a 32 MB `mkcard.sh` card; `gold/identify.py` the IDENTIFY DEVICE stream (word values low byte first, ATA strings first character in bits 15:8 = the 832's `memcpy` order) for `WORK.HDF` (long name, 8.3 name, SYNTHRDB, both), an odd-length and a 16-character long name, a 2 GB SYNTHRDB and the SD card (whole, partition 3). Checks: `hdf[]` set up as `OpenHardfile` does (geometry against `rdb.py`), FakeRDB's blocks byte for byte on units 0 and 1, and the real `OpenHardfile` on the card's files; IDENTIFY's 512 bytes; the RDB patch of `WORK.HDF`'s own block 0 (unit 0: Flags 0x12, checksum valid; unit 1: as it is); READ SECTORS / READ MULTIPLE (after SET MULTIPLE MODE 3, 4, 16) and WRITE SECTORS / WRITE MULTIPLE (2, 16): the task file -> CHS -> LBA, the task file written back (the last sector's CHS), sector count 0 = 256, the chunks (`sectors_per_block`, never more than the FIFO holds), the status writes, every block against the HDF file (reads: the data frames and the direct-mode transfers of the trace, in order) or on the card (writes: every other card byte unchanged, the read back after a write), READ MULTIPLE ranges that cross from the synthesised cylinder into the file inside a chunk (`hdd.c:536`, Task 4's parenthesis), a WRITE MULTIPLE over that boundary (the fake blocks dropped, `ERROR_HDD`) |
| `fdd_test` | the floppy emulation (Task 13; `fdd_test.c`): the RV `fdd.c` and the 832's `fw/ctrl_832/fdd.c` (copied unchanged into `out/fdd/`, built `-std=gnu17 -funsigned-char` with the RV tree's headers, its globals renamed `<name>_832` by `objcopy`) run the same scenarios on the same mock, from `HandleFDD()`. `gold/mfm.py` (an Amiga MFM track encoder written from the track format: sync 0x4489, header info / label / data split into odd and even bits, header and data checksums as the XOR of the MFM longs AND 0x55555555; its header lists the spec facts and the two Minimig choices it takes as parameters: the 12668-byte track and the read stream's clock bits) writes an LBA-tagged ADF, the read stream of every track, write streams with real MFM clock bits and the ADFs after them. ReadTrack, behind a mock `paula_floppy` that answers the six status bytes of each frame and asks (`CMD_RDTRK`) for a number of frames: the bytes after the status bytes of every FPGA frame (`SendSector`, `SendGap`: the plan's `SectorToFpga`/`SectorGapToFpga`) == `mfm.py`, for each source, and the RV trace == the 832 trace, for track 0 side 0 and track 79 side 1 (`gold/mfm_c00_s0.hex`, `gold/mfm_c79_s1.hex`, committed for Phase 4's L3 data check; `mfm.py` must reproduce them, `cmp`), then every track 0..159 (track/side arithmetic, the cluster cache), a read that stops after 4 sectors and goes on at sector 4, a track change in the middle, the Copy Lock workaround (`fdd.c:243`: the mock reports DSKSYNC 0x8914, 0xA144, 0x0000 in its status bytes 2-3, the firmware must send 0x4489) and a sync it passes through (0x4891), DEBUG on (UART RV == 832). WriteTrack (`FindSync`/`GetHeader`/`GetData`) behind a mock write FIFO (2048 words; status `{trackwr}` and `{dmaen & dsklen[14], fifo_cnt}` as `paula_floppy`'s `wr_fifo_status`; the "Amiga" adds 2048, 300 or 7 words per poll): three cases (track 159 whole with 3 new sectors, track 1 sectors 5, 2, 9, track 80 whole from sector 6), the ADF afterwards == `mfm.py`'s (only the written sectors changed), the whole stream read, never past the FIFO count; a write-protected disk; a bad header and a bad data checksum (that sector dropped, `FatalError` 26 / 29). The file layer is a direct ADF mock with FAT semantics (4-sector clusters in a scattered chain; `FileRead`/`FileWrite` address through `file.cluster` and fail when it disagrees with `file.sector`). Also `UpdateDriveStatus` and `HandleFDD`'s drive sounds. Make also checks that every `SPIN` in `fdd.c` is commented out, as many as in the 832's (`out/fdd/spin.ok`) |
| `mmc_test` | the real `mmc.c` on the card model, over a card image it writes itself (byte i of sector n = (37 n + 11 i + (n >> 8)) mod 256): `MMC_Init`'s card commands against `gold/mmc_init_cmds.txt` (the SD model's `+SD_LOG=1` log of the L2 `boot` run, the boot ROM's same protocol: CMD0, CMD8, three CMD55/ACMD41, CMD58) and its SPEED writes (slow before CMD0, fast after CMD58, no other); `MMC_Read` with token delay 0, 4, 200 bytes, `MMC_ReadMultiple` (+ CMD12) with 4 and 200, `MMC_Write` with busy 8 and 2000 bytes, `MMC_GetCapacity` (CMD9, delay 200): data against the image, every frame exactly as long as the protocol says; the five `SD_TIMEOUT` bounds (CMD17/CMD9/CMD18 token, CMD24/CMD12 busy) on a card that never answers: failure, the message, 173..174 wait bytes in the trace and 174..175 TIMER reads (the timer advances once per byte of the loop); `MMC_Read(lba, NULL)` (direct mode) against `gold/dmode.txt` (from `gold/dmode.py`, the SD protocol with an independent CRC7; also the reference trace for Phase 4), written to `out/mmc_<64\|32>_dmode.txt`; the model's CMD55, CMD0, CMD41 = plain CMD41 |
| `drivesounds_test` | the drive sounds (Task 14; `drivesounds_test.c`): the real `drivesounds.c` (with `audio.c`) loads `sw/mkdrivesounds/drivesnd.bin` and `SYNTH.BIN` through `rafile.c` + `fat.c` + `mmc.c` on the card model (an 8 MB `mkcard.sh` card in `out/ds/`) into the mock's RAM in front of `AUDIO_BUFFER`, where they land as on the target (`DRIVESND.BIN` at 2 mod 4, `SYNTH.BIN` at 0 mod 8), then runs two op lists with the TIMER standing still (step 0, time moves by the ops): events queued (`drivesounds_queueevent`: motor start and stop, steps, insert, eject, HDD steps), `drivesounds_fill()`, the floppy sounds switched off and on, the AUDIO read value (the Amiga owns the ring), `cda_busy()` (the test's stub); the real file's sequence starts at TIMER 65450 (the wrap), renders up to the 127-tick limit, three voices and a fourth switched off, the chains (start -> loop -> loop, loop -> stop), a motor start that cancels a stop, a dropped fourth HDD step, silence until the player stops. `gold/drivesounds.py` computes the 832's ring for the same ops from the file format (big-endian header and samples, as `mkdrivesounds.c` writes them) and the 832's render rules (stated in its header: sum, swap, `* 0x10001`, big-endian store), and asserts the coverage of each case and that `pickstep` never depends on its uninitialised `count`. Checks: the load's return value and UART lines (`Audio file - length`, each `Sound <id> ... length <size>`), and after every fill its return value, AUDIO, and the 64 KB ring byte for byte (`ring_<case>.bin`). Then five bad files (final review I1, `drivesounds.py` `bad_files`): `TRUNC.BIN` (`SYNTH.BIN` cut 100 bytes into sound 2), `ODDLEN.BIN` (`SYNTH.BIN` plus one byte), `ODDSND.BIN` (a sound of 801 bytes), `NEGSIZE.BIN` (size -2), `NEGID.BIN` (id -1): the ring, filled with a pattern a byte swap changes, is untouched, and the return value, `drivesounds_loaded()` and the lines (with `Bad length ...`/`Bad sound ...`) are the RV port's bounds rule (`rv_load`, not the 832's: it only read the file) |
| `boot_test` | the Amiga-facing words of `boot.c`, `main.c` and `hexdump.c` (Task 14; `boot_test.c`): `BootUploadCopper()` without a `COPPER_FILE` writes the default copper list as big-endian words (`00 E0 00 08 00 E2 ...`) at `COPPER_ADDRESS ^ HOSTMAP_ADDR` -- the test maps that page at its own address (`mmap` `MAP_FIXED_NOREPLACE`) and checks that nothing else in it changed; with a `COPPER_FILE` (stubbed `RAOpen`/`RARead`) the file's bytes. `CheckSum` (cut out of `main.c` by `sed` into `out/checksum.inc`: `main.c` holds `main()`) of a 512-byte block = its big-endian word sum (computed by python3, in the comment), at an aligned and an odd address; `hexdump()` prints the 832's (big-endian) words, at an aligned and an odd address |

### `config_test` cases

`gold/mkcfg832.py` writes 832 (big-endian) config files from a field table
that follows `config.h` (`struct.pack`, independent of the C code); the card
images come from `tools/sim/mkcard.sh`.

| Part | What is checked |
|---|---|
| Generated files | the defaults, every field non-zero and distinct, versions 2 and 3, a 208-byte version 3 file, the `fwboot_cfg` file (`l2`), and five corrupt ones (id, version 5, version 0, 155 and 213 bytes) |
| `cfgconv` (built here with the sanitizers, native and `-m32`) | `--check` == the generator's text; `--to-rv`, then `--check` of the result shows the same fields; `--to-832` gives back the same bytes |
| `cfgconv` refusals | corrupt input, already in the target order, the output is the input (by name, `./` spelling or hard link): exit 1 and nothing written |
| `cfg_order` / `cfg_swap` | `cfg_order` of every case; every field of each `--to-rv` result read through the firmware's `configTYPE` against the table; `cfg_swap` == `cfgconv` |
| Card (a) | only `MINMGAR.CFG`: loaded as it is |
| Card (b) | only 832 files (slots 0, 1, 2): converted, the RV files appear and equal `cfgconv --to-rv` (the version-2 rules for old files), the conversion line is on the UART; every byte the run changed lies in the new files' entries, FAT entries and clusters (the 832 files' entries and clusters are unchanged byte for byte); a second load converts nothing and writes nothing |
| Card (c) | an 832 file as `MINMGAR.CFG`: rejected ("Wrong configuration file format!", then "(832 byte order)"), the defaults, nothing written |
| Card (d) | both files: the RV file wins |
| Card (e) | an RV file as `MINMGAA.CFG`: not converted; no file at all: the defaults == the generator's |
| After card (b) | by `mtools`: `MINMGAR.CFG` == `cfgconv --to-rv MINMGAA.CFG`, the 832 files unchanged; `fsck.fat -n` clean |
| `CFG832_DIR` | real 832 files (see Setup): the same round trip as the generated cases |

### The `fat_test` images

`fatimg.sh` builds them into `out/` (or `FATIMG=<dir>`), byte-reproducible
(fixed disk identifier, `mkfs.fat --invariant`, file times from
`SOURCE_DATE_EPOCH` in UTC), with the same files on each (`gold/fatdata.py`:
deterministic contents) and their expected listings (`<image>.gold`):

| Image | Layout | Built by |
|---|---|---|
| `fat16.img` | 16 MB, MBR, FAT16 at LBA 2048 | `tools/sim/mkcard.sh` (+ `mtools` for the deletion, directories, long names) |
| `fat32.img` | 132 MB, MBR (type 0x0c), FAT32 at LBA 2048 | `sfdisk` + `mkfs.fat -F 32 --offset` + `mtools`, the way `mkcard.sh` does FAT16 |
| `super.img` | 16 MB, FAT16 without MBR ("superfloppy") | `mkfs.fat` on the whole file + `mtools` |

All have 4-sector clusters (`FileCreate` allocates one cluster: the 3-sector
file must fit). `BIG.BIN` (307,300 bytes) is copied after `MIDDLE.BIN` was
deleted, so it is fragmented over the hole (`fatimg.sh` checks this with
`mshowfat`). `HIGH.BIN` is in every root; "Games Collection/Many Long
Names" holds three files with 246-character names (20 entries each), two 8.3
names and `DELTA.BIN`'s long name, whose entries start at entry 64: the
directory spans two clusters (`fatimg.sh` checks the chain) and DELTA is in
the second. On FAT32 a 128 MB file of zeros ("Another
Level/FILL.BIN") takes every free cluster below 65536 before `HIGH.BIN` is
copied, so `HIGH.BIN` (checked by `fatimg.sh`) and `FileCreate`'s file start
above cluster 65535. On FAT32 the FSInfo free-cluster count and next-free hint are
"unknown" (0xFFFFFFFF): `mtools` then allocates from cluster 2 (it would
otherwise continue after the last file), and `fsck.fat` does not report the
count that `FileCreate`, like the 832 firmware, leaves alone. Each image is
also checked clean by `fsck.fat -n` as built. `fat_test` only reads the image;
it writes the card to `out/<image>_<64|32>.img` for the checks, which
`fat_check.sh` deletes when they pass. `make` rebuilds the images when a
script changed or one of `fatimg.sh`'s outputs is missing.

## The mock (`mock_hw.c`, `mock_hw.h`)

`-DHOSTTEST` swaps the register macros of `fw/ctrl_rv/hardware.h`
(`SPI`, `RDSPI`, `Enable*`/`Disable*`, `SPI_slow`/`SPI_fast`, `TIMER`,
`PLATFORM`, `AUDIO`, `RS232`) for calls into the mock; without it the target
build is the same bytes. A test that uses the mock links `mock_hw.c`.

* **SPI trace.** Every frame is a run of a constant chip-select register,
  written in the normalised `spi.txt` format of the L2 bench
  (`sim/host_bridge/tb_host_bridge.v` `+SPI_LOG`, read by `spitrace.py`):
  `<cs> <out bytes> / <in bytes>`, hex, no timestamps; cs 20 OSD, 10 FPGA,
  02 card, 40 DMode, 80 RTC, 00 none. `mock_trace()` / `mock_trace_write()`.
* **Direct mode** (DMode with the card selected, frame cs 42): one SPI write
  clocks 512 bytes out of the card with MOSI high, as cfide does (4096
  clocks, `shiftcnt "10111111111111"`); `RDSPI` gives the last one.
* **Scripted MISO** per chip select: `mock_script_bytes()` (a queue),
  `mock_script_fn()` (a callback), `mock_script_idle()`; an empty queue answers
  0xFF and counts an underrun.
* **Card image model** (chip select 02): CMD0/8/9/12/16/17/18/24/25/55/58 and
  ACMD41 over a raw image (`mock_card_load()`), byte for byte the way
  `sim/common/sd_spi_model.v` answers (SDHC, 4 token-delay bytes, 8 busy bytes,
  1 NCR byte, 2 ACMD41 polls). Images come from `tools/sim/mkcard.sh`
  (byte-reproducible); the test Makefile builds an 8 MB one in `out/card.img`.
  Writes land in the memory of the model (`mock_card_sector()`,
  `mock_card_save()`). `mock_card_params()` sets the delays; a negative token
  delay means no token ever, a negative busy count busy without end (until
  deselect or CMD0: not in the Verilog model, for the timeout cases).
  `mock_card_log()`: one line per command, the model's `+SD_LOG=1` line
  without time and cs (`ACMD41 arg=40000000`); `mock_spi_speed_log()`: every
  SPEED write with the number of commands before it.
* **TIMER**: a counter, advanced by `hosttest_advance(n)`, by `mock_timer_step()`
  (default 1) on every read, so that a `CheckTimer()` loop ends, and by
  `mock_timer_spi_rate(n)` (default off) once every n SPI bytes: time that
  passes with the bytes on the wire. Under the per-read step a loop that is
  bounded too long still ends, so a timeout test checks the bound itself (bytes
  in the trace, `mock_timer_reads()`), not only that the call failed.
* **UART**: the bytes of `RS232()` as text (`mock_uart()`).
* **RAM** (`mock_ring()`): `AUDIO_BUFFER` is a `HOSTTEST` hook in
  `hardware.h` (`hosttest_audio_buffer()`); the mock's array `__bss_end` (the
  linker symbol `drivesounds.c` uses) holds `MOCK_LOAD_AREA` (0x48000) bytes
  and then the 64 KB ring, so `AUDIO_BUFFER - &__bss_end` is the room for
  `DRIVESND.BIN` in front of the ring, as on the target (0x70000 -
  `__bss_end`). Zero after `mock_reset()`.
* **AUDIO** is one byte: a read returns the last write or `mock_audio_set()`
  (on the board a read is `{Amiga owns the ring, buffer half}`, independent of
  the writes); `drivesounds_test` sets the read value after each stop.
* `mock_dmode_blocks()`: the direct-mode transfers so far (512 card bytes
  each, which go to the FPGA): what a chip-select callback (`hdd_test`'s
  Gayle FIFO) cannot see in its own frames.

## Mutants

`mutants.sh` copies the sources, the tests and the gold files into
`mut/<name>/`, applies one `sed`, builds the copy with the Makefile's own
targets (`SRC= TD= GOLD= B=`) and runs the real test target. The unmutated
copy must pass first. A mutant is *killed* only when its build succeeded and
the test target then failed; a sed that changed nothing or a build failure is
reported `BROKEN` and fails the run, a passing test is `SURVIVED`. A mutant
may name texts that its failing log must hold, each of them (the cases that must kill it):
a failure without one is `BROKEN` too. Every run
starts from a fresh copy. `fat_test`'s mutants use the images in `out/`, built
once from the unmutated scripts (`FATIMG=out FATIMG_DEPS=`). The format-parity mutants run the real `make fmt`
(a 16-byte print buffer, a deleted line of the expected-difference list, a
stale `formats.txt`, a format without a case). There is a mutant for each
test (for `swap_test`: `rd_le32`, `wr_be16`, `be32`, `le16`, the sign
extension of `SwapBBBB`; for `fat_test`: `StartCluster` read with `SwapBB`
again, everywhere and in `ScanDirectory` only, `FileSize`, the FAT16 and FAT32
links, the FAT32 EOC literal `0xFFFFFF0F`, the MBR signature cases exchanged,
the new entry's start cluster and size, `HighCluster` everywhere, in
`FileOpen` only and in `FileCreate`'s write, `FileCreate`'s modify and create
dates, `GetFATLink`; for `mmc_test`: `SD_TIMEOUT` 0, which must fail the
200-byte token delay, `SD_TIMEOUT` 1000, each of the five bounds doubled on its
own, ACMD41 without HCS, no `SPI_slow`, and the mock's direct mode cut to one
byte; for `config_test`: `cfg_swap` without `hdfdir[3]` (the brief's), `cfg_order`
without the 832 case, `LoadConfiguration` without the swap, saving over the
832 file, with the 832 names, without "(832 byte order)", converting a file
of any order, `ConfigurationExists` without the 832 file, and `cfgconv`
without its output-is-input and target-order refusals; for `hdd_test`: `RDBChecksum`
summing native longs and IDENTIFY without the string swap (the brief's two),
the RDB patch on native longs, the boundary loop with `<= 0` and without its
`blk` bound, sector count 0 = 255, and the mock's direct-mode count; for `fdd_test`: `SendSector` one byte short, which must fail against both references on tracks 0 and 159 (the brief's), the Copy Lock workaround gone, tracks 128..159 read at the sector of track - 128, `GetHeader`'s sector number and `GetData`'s even data bits decoded from the wrong bits, `WriteTrack` going back one sector off, the header checksum not checked, `GetData` taking 515 words for a 516-word sector (reads past the FIFO count at 7 words per poll), and a stale committed golden stream; for `drivesounds_test`: the 832's per-sample swap kept (the brief's: the ring differs), the header read as `*(long *)` (the brief's: on LP64 an 8-byte load at `SYNTH.BIN`'s 4 mod 8 size field, which UBSan stops) and as `*(int *)` (RV32's 4-byte long: the little-endian sizes, the test's load check), the samples not converted at load, the `& 0xffff` dropped, each of the four `(enabled & DRIVESOUNDS_FLOPPY)` conditions always true, and each bound of the in-place conversion dropped (`ds_noclamp`: `TRUNC.BIN` writes the ring; `ds_oddfile`: `ODDLEN.BIN` loads, on x86 without a trap; `ds_oddsize`, `ds_negsize`: the load lines; `ds_negid`: UBSan, `sounds[-1]`); for `boot_test`: the copper list without `be16`, `CheckSum` and `hexdump` on native words) and one for every register class of the I/O map (address and width of
SPI DATA/CS/SPEED, UART, TIMER, PLATFORM, AUDIO, `FPGA_TEMP_RAW`,
`VIDEOSCALE`, `RECONFIGURE`, keyboard words and OUT, Akiko, RTC, I2C, the
interrupt controllers, each CS and SPEED value, `SPI()`/`RDSPI`, and
`RS232()` itself).

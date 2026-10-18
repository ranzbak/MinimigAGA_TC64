# Host tests of fw/ctrl_rv

`make -C fw/ctrl_rv/test` builds and runs every host test twice, native (LP64)
and `-m32` (ILP32, like RV32), and runs the format-parity gate. The exit status
is the result. `make -C fw/ctrl_rv/test mutants` checks that the tests can
fail.

## Setup (fresh Ubuntu 24.04)

The commands work in bash and zsh, from the repository root:

```sh
sudo apt install build-essential gcc-multilib python3 git mtools dosfstools fdisk
git submodule update --init EightThirtyTwo      # lib832: the 832 printf reference
make -C fw/ctrl_rv/test
```

* `gcc-multilib` is for the `-m32` builds (with AddressSanitizer and UBSan);
  `python3` runs the golden generators and `fmtcheck.py` (standard library
  only, `python3 -I`); `mtools dosfstools fdisk` are what
  `tools/sim/mkcard.sh` needs for the card image of `mock_selftest`, and what
  `fatimg.sh` / `fat_check.sh` use for the images of `fat_test` (`sfdisk`,
  `mkfs.fat`, `fsck.fat`, `mcopy`, `mdel`, `mmd`, `mdir`, `mshowfat`, `mtype`;
  no root, no loop devices). Those images take about 170 MB in `out/` (the
  FAT32 one is 132 MB: FAT32 needs at least 65525 clusters).
* `LIB832` defaults to `EightThirtyTwo/lib832` of the repository. Another
  checkout: `make -C fw/ctrl_rv/test LIB832=/path/to/EightThirtyTwo/lib832`.
  A missing `LIB832` fails the run, it never skips the format check.
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

## Targets

| Target | What |
|---|---|
| `run` (default) | `fmt` and every `run-<test>` |
| `run-<test>` | one test, native then `-m32` (`run64-<test>`, `run32-<test>`: one of them) |
| `fmt` (`fmt.ok`) | the format-parity gates of `rvlibc.c` against glibc and lib832 (below) |
| `mutants` | `mutants.sh`: each mutant must make the real test target fail |
| `clean` | remove `out/` and `mut/` |

Flags: `-std=gnu2x -D_DEFAULT_SOURCE -DHOSTTEST -Wall -Wextra -Wno-unused-parameter -Werror -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all`
plus `-U_FORTIFY_SOURCE -D__NO_INLINE__ -fno-builtin` (glibc must not rewrite
`putchar`/`printf`, and `printf("..\n")` must not become the firmware's `puts`).
The unmodified 832 source of the format reference (lib832 `small_printf.c`) is
built `-std=gnu17 -m32 -funsigned-char`, like the 832 firmware.

## Tests

| Test | Covers |
|---|---|
| `mock_selftest` | the mock below: scripted replies per chip select, the `spi.txt` trace, TIMER, UART, PLATFORM, AUDIO, the card model by hand and under the real `mmc.c` (`MMC_Init`, `MMC_Read`, `MMC_ReadMultiple`, `MMC_Write`) |
| `cue_test`, `cdaudio_test`, `atapi_test`, `cdrom_test`, `openhf_test` | the CD-ROM code (CUE parser and disc model, CD audio player, ATAPI commands, the Gayle glue, `OpenHardfile` on a CD slot); unchanged from the 832 tests except for the dialect |
| `lib_test` | `rvlibc.c` against glibc's `vsnprintf` (output, return value, truncation, nesting, heap stubs) |
| `hwmap_test` | with the real macros (`-DHOSTTEST` undefined in that file): address and width of every register, the CS/SPEED values of `Enable*()`/`Disable*()`/`SPI_slow()`/`SPI_fast()`, `SPI()`/`RDSPI` order, the real `RS232()` expansion, `uart.c` `puts` |
| `fmt` | format strings of the firmware: ILP32 == LP64, `fmtcheck.py` model, the 832-versus-RV differences are exactly `gold/fmt_diff_expected.txt` |
| `swap_test` | `../swap.h` and `../swap.c`: `le16/le32/be16/be32` by the bytes they leave in memory (true on any host) and by value on this LE host, `rd_le16/rd_le32/rd_be16/rd_be32` and `wr_be16/wr_be32` at offsets 0..3 of an aligned buffer (a pointer cast would be a misaligned access there, which UBSan stops), `SwapBB/SwapBBBB/SwapWW` without sign extension on LP64 |
| `fat_test` | the real `fat.c` over the real `mmc.c` on the card model, once per image (below): `FindDrive()` (FAT type, partition start and size against the MBR bytes, cluster size), every directory through `ScanDirectory` (names, sizes, start clusters, long names) against `mdir -/ -a` + `mshowfat` (`gold/fatlist.py`), `FileOpen` + `FileRead`/`FileNextSector`, `FileSeek` and `FileReadEx` of a 300 KB file fragmented over a deleted file's clusters, a subdirectory walk with long names (`FindDirectory`, `ChangeDirectory`, `FileOpen` by long name, `ValidateDirectory`, `FindDirectoryByCluster`), a name that does not exist, and `FileCreate` + 3 x `FileWrite` + `UpdateEntry` of a 3-sector file, read back through `fat.c`, then `fsck.fat -n` of the written image and `mtype` of the file (`fat_check.sh`) |

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
`mshowfat`). On FAT32 the FSInfo free-cluster count and next-free hint are
"unknown" (0xFFFFFFFF): `mtools` then allocates from cluster 2 (it would
otherwise continue after the last file), and `fsck.fat` does not report the
count that `FileCreate`, like the 832 firmware, leaves alone. Each image is
also checked clean by `fsck.fat -n` as built. `fat_test` only reads the image;
it writes the card to `out/<image>_<64|32>.img` for the checks, which
`fat_check.sh` deletes when they pass.

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
* **Scripted MISO** per chip select: `mock_script_bytes()` (a queue),
  `mock_script_fn()` (a callback), `mock_script_idle()`; an empty queue answers
  0xFF and counts an underrun.
* **Card image model** (chip select 02): CMD0/8/9/12/16/17/18/24/25/55/58 and
  ACMD41 over a raw image (`mock_card_load()`), byte for byte the way
  `sim/common/sd_spi_model.v` answers (SDHC, 4 token-delay bytes, 8 busy bytes,
  1 NCR byte, 2 ACMD41 polls). Images come from `tools/sim/mkcard.sh`
  (byte-reproducible); the test Makefile builds an 8 MB one in `out/card.img`.
  Writes land in the memory of the model (`mock_card_sector()`,
  `mock_card_save()`).
* **TIMER**: a counter, advanced by `hosttest_advance(n)` and by `mock_timer_step()`
  (default 1) on every read, so that a `CheckTimer()` loop ends.
* **UART**: the bytes of `RS232()` as text (`mock_uart()`).

## Mutants

`mutants.sh` copies the sources, the tests and the gold files into
`mut/<name>/`, applies one `sed`, builds the copy with the Makefile's own
targets (`SRC= TD= GOLD= B=`) and runs the real test target. The unmutated
copy must pass first. A mutant is *killed* only when its build succeeded and
the test target then failed; a sed that changed nothing or a build failure is
reported `BROKEN` and fails the run, a passing test is `SURVIVED`. Every run
starts from a fresh copy. `fat_test`'s mutants use the images in `out/`, built
once from the unmutated scripts (`FATIMG=out FATIMG_DEPS=`). The format-parity mutants run the real `make fmt`
(a 16-byte print buffer, a deleted line of the expected-difference list, a
stale `formats.txt`, a format without a case). There is a mutant for each
test (for `swap_test`: `rd_le32`, `wr_be16`, `be32`, `le16`, the sign
extension of `SwapBBBB`; for `fat_test`: `StartCluster` read with `SwapBB`
again, everywhere and in `ScanDirectory` only, `FileSize`, the FAT16 and FAT32
links, the FAT32 EOC literal `0xFFFFFF0F`, the MBR signature cases exchanged,
the new entry's start cluster and size) and one for every register class of the I/O map (address and width of
SPI DATA/CS/SPEED, UART, TIMER, PLATFORM, AUDIO, `FPGA_TEMP_RAW`,
`VIDEOSCALE`, `RECONFIGURE`, keyboard words and OUT, Akiko, RTC, I2C, the
interrupt controllers, each CS and SPEED value, `SPI()`/`RDSPI`, and
`RS232()` itself).

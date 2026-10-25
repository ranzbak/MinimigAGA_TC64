# Host tests of fw/ctrl

`make -C fw/ctrl/test` builds and runs every host test twice, native (LP64)
and `-m32` (ILP32, like RV32), and runs the format-parity gate. The exit status
is the result. `make -C fw/ctrl/test mutants` checks that the tests can
fail.

## Setup (fresh Ubuntu 24.04)

The commands work in bash and zsh, from the repository root:

```sh
sudo apt install build-essential gcc-multilib python3 git mtools dosfstools fdisk
make -C fw/ctrl/test
```

The mutant check (every test must go red on its mutants):

```sh
make -C fw/ctrl/test mutants
```

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
* `config_test` takes `CFGBE_DIR=<dir>` (optional): every file there, real
  big-endian config files of the previous (832) firmware such as copies
  from an SD card, gets the same round trip
  as the generated cases (`cfgconv --to-rv`, `--to-be` back to the same
  bytes, the same fields in both `--check` outputs), e.g.
  `make -C fw/ctrl/test run-config_test CFGBE_DIR="$PWD/build/cfgbe"`
  from the repository root (`fw/ctrl/tools/cfgconv/README.md`).
  There is no config file in the repository.
* `drivesounds_test` loads `sw/mkdrivesounds/drivesnd.bin` (`DRIVESND=<file>`
  names another; its scenario is written for that file's sound lengths, and
  `gold/drivesounds.py` fails when a case no longer reaches what it must).
* `atapi_test` has ISO-backed cases. `ISO=<file>` names the ISO (default
  `~/work/amiga/AmigaOS3.9.iso`); every run is repeated with a name that does
  not exist, where those cases are skipped, not failed.
* To check that the hooks leave the target image alone (needs the RISC-V
  toolchain, `bash tools/riscv/fetch-xpack.sh`, `bash tools/riscv/check-toolchain.sh`):
  build `fw/ctrl` before and after a change with the same clock, e.g.
  `make -C fw/ctrl B=/tmp/before` and `... B=/tmp/after` with a `date` that
  does not move (the version string holds the minute), then `cmp` the two
  `RV32OSDA.BIN`.

Output goes to `fw/ctrl/test/out/` and `mut/` (both ignored by git);
`make -C fw/ctrl/test clean` removes them.

## Writing a test

* **A timeout test must assert `mock_timer_reads()`.** The mock advances the
  TIMER on every read (`mock_timer_step()`, default 1) so that a
  `CheckTimer()` loop always ends. A loop whose bound is far too long ends
  all the same: the test passes, silently. So a test of a timeout checks the
  bound itself: the bytes in the SPI trace and `mock_timer_reads()` inside a
  window (`spireply_test` does this for `SPI_reply()`'s bound, `sdc_test`
  for `sdc_wait()`'s). A bound of the SD peripheral (its TIMEOUT register)
  is time in the mock, not TIMER reads: set `mock_timer_step(0)` and check
  `mock_now()` inside a window (`mmc_test`'s bounds: 5 x 16, 4 x 1732,
  4 x 6926 units of 16384 cycles). A bare "the call failed" proves nothing.
* **A register that has no `-DHOSTTEST` hook crashes the test.** Hooked are
  `SPI`/`RDSPI`, the chip selects, `SPI_slow`/`SPI_fast`, `TIMER`,
  `HOST_REQ`, `PLATFORM`, `AUDIO`, `RS232` and `AUDIO_BUFFER` (the `HOSTTEST` block at
  the end of `fw/ctrl/hardware.h`), the SD peripheral (`sdc.h`: driver code
  uses `SDC_R` / `SDC_W`, `SDC(x)` does not compile under `HOSTTEST`) and the
  interrupt registers with `irq_save` / `irq_restore` (the `HOSTTEST` block of
  `arch/irq.h`; `arch/irq.c` builds unchanged). Every other register macro still
  dereferences its real address (`0xFFFFFFxx`, or `0xDEExxx`), which is not
  mapped on the host: a test that reaches the keyboard (`HW_KEYBOARD`),
  Akiko, the RTC, I2C, `VIDEOSCALE`, `FPGA_TEMP_RAW` or `RECONFIGURE` dies
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
| `fmt` (`fmt.ok`) | the format-parity gates of `rvlibc.c` over glibc against the ISO printf model (below) |
| `check_io` | `../check_io.awk` (`make -C fw/ctrl check` (b), (c)) on the three listings of `check_io/` (`check_io.sh`): its output and exit status for each listing and mode must be `check_io/expected.txt` |
| `mutants` | `mutants.sh`: each mutant must make the real test target fail |
| `clean` | remove `out/` and `mut/` |

Flags: `-std=gnu2x -funsigned-char -D_DEFAULT_SOURCE -DHOSTTEST -Wall -Wextra -Wno-unused-parameter -Werror -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all`
plus `-U_FORTIFY_SOURCE -D__NO_INLINE__ -fno-builtin` (glibc must not rewrite
`putchar`/`printf`, and `printf("..\n")` must not become the firmware's `puts`).
`-funsigned-char` is the firmware's `char` (`tools/riscv/toolchain.mk`; x86
gcc defaults to signed): added by the final review (I2), every test passed
unchanged with it.

## Tests

| Test | Covers |
|---|---|
| `mock_selftest` | the mock below: scripted replies per chip select, the `spi.txt` trace, TIMER, UART, PLATFORM, AUDIO, the card model by hand (on cfide's SPI) and under the real `mmc.c` (`MMC_Init`, `MMC_Read`, `MMC_ReadMultiple`, `MMC_Write`; since findings/sdcard-engine Task 10 through `sdproto.c` and the mock SD peripheral: the data rate div 2, no SPEED write on cfide's SPI) |
| `cue_test`, `cdaudio_test`, `atapi_test`, `cdrom_test`, `openhf_test` | the CD-ROM code (CUE parser and disc model, CD audio player, ATAPI commands, the Gayle glue, `OpenHardfile` on a CD slot); unchanged from the previous firmware's tests except for the dialect. `openhf_test` still builds `OpenHardfile` alone, cut out of `hdd.c` by `sed`, with stubs for the FAT calls: `hdd.c` as a whole builds under `HOSTTEST` now (`hdd_test` links it), but the cut keeps the stubs the only FAT `OpenHardfile` sees there |
| `lib_test` | `rvlibc.c` against glibc's `vsnprintf` (output, return value, truncation, nesting, heap stubs) |
| `hwmap_test` | with the real macros (`-DHOSTTEST` undefined in that file): address and width of every register (the SD peripheral's twelve too, `SDC_VERSION`, `IRQ_SDCARD`; `SDC_R` / `SDC_W` are one access of `SDC(x)`), the CS/SPEED values of `Enable*()`/`Disable*()`/`SPI_slow()`/`SPI_fast()`, `SPI()`/`RDSPI` order, the real `RS232()` expansion, `uart.c` `puts` |
| `fmt` | format strings of the firmware: `gold/formats.txt` current, every format has a case, ILP32 == LP64, every record == `fmtcheck.py`'s model of ISO printf (`fmtcheck.py iso`) |
| `spireply_test` | `SPI_reply()` (`../hardware.c`, Phase 4 Task 11) on the mock's `HOST_REQ`: ready at once (`1WR`: no TIMER read), ready after 1..3 reads of 0 (polls until 1, only then the DATA write; n TIMER reads, no timeout), never ready at one, two and three TIMER counts per read (returns at the bound: 4 / 3 / 2 TIMER and `HOST_REQ` reads, `osd_rdy_timeouts` 1, the byte still read), and a three-byte frame that waits per byte. The expected orders and counts follow from the rule (2 TIMER counts, `CheckTimer` true once TIMER > T0 + 2) and the mock's TIMER, written in the test's header |
| `diskstat_test` | the disk statistics of the SD baseline (`../diskstat.c`, findings/sdcard-engine Task 1): every sectors-per-command bucket (1, 2, 3-4, 5-8, 9-16, 17-64, 65-256) at both bounds in both directions, `diskstat_report()`'s text on the mock UART (cumulative totals, the loop passes and TIMER counts of the period, a period across the 16-bit TIMER wrap, `diskstat_period_start`). The hooks: `hdd_test` the bucket of every READ/WRITE command and the Amiga polls (one per FIFO wait plus one per `CD_AudioRefill`) |
| `swap_test` | `../swap.h` and `../swap.c`: `le16/le32/be16/be32` by the bytes they leave in memory (true on any host) and by value on this LE host, `rd_le16/rd_le32/rd_be16/rd_be32` and `wr_be16/wr_be32` at offsets 0..3 of an aligned buffer (a pointer cast would be a misaligned access there, which UBSan stops), `SwapBB/SwapBBBB/SwapWW` without sign extension on LP64 |
| `fat_test` | the real `fat.c` over the real `mmc.c` on the card model, once per image (below): `FindDrive()` (FAT type, partition start and size against the MBR bytes, cluster size), every directory through `ScanDirectory` (names, sizes, start clusters, long names) against `mdir -/ -a` + `mshowfat` (`gold/fatlist.py`), `FileOpen` + `FileRead`/`FileNextSector`, `FileSeek` and `FileReadEx` of a 300 KB file fragmented over a deleted file's clusters, a subdirectory walk with long names (`FindDirectory`, `ChangeDirectory`, `FileOpen` by long name, `ValidateDirectory`, `FindDirectoryByCluster`), `HIGH.BIN` (on FAT32 above cluster 65535: `HighCluster`), `FileOpen` by long name of a file in the second cluster of a two-cluster directory (`GetFATLink`), a name that does not exist, and `FileCreate` + 3 x `FileWrite` + `UpdateEntry` of a 3-sector file (on FAT32 above cluster 65535), read back through `fat.c`, its raw directory entry (create/access date, create time, start cluster, `HighCluster`) against the FAT layout, then `fsck.fat -n` of the written image, `mtype` of the file and `mdir` of its modify date and time (`fat_check.sh`); the file's last cluster (findings/sdcard-engine Task 10 fix rounds 1, 2): `FileReadEx` of the whole last cluster 1, one block more 0, `FileSeek` past the end 0 with the pointer left valid (the next seek reads the right last sector) |
| `config_test` | the config file's byte order (Task 11; `config_test.c`, `config_check.sh`): the generated big-endian files, `cfgconv`, `cfg_order`/`cfg_swap`, and `LoadConfiguration`/`ConfigurationExists` on card images; the cases are the table "`config_test` cases" below |
| `hdd_test` | the hard disk emulation (Task 12; `hdd_test.c`): the real `hdd.c` over the real `fat.c` + `mmc.c` on the card model, driven through `HandleHDD()` by a mock Gayle on the FPGA chip select (the status byte of each frame: `CMD_IDECMD` / `CMD_IDEDAT`; `CMD_IDE_REGS_RD`/`_WR`, `_STATUS_WR`, `_DATA_WR`/`_RD`; a 16-sector FIFO: in pio in a poll that finds data answers busy and the "Amiga" reads it all, one chunk, the next poll answers drained; in pio out every other poll finds a sector written). `gold/rdb.py` writes the expected RDSK and PART blocks (big-endian, from the field offsets of `devices/hardblocks.h`, checksum over the finished block) for a 2 MB, a 2 GB and an odd (20001 blocks) hardfile without RDB, with the geometry by WinUAE's rule, and three HDF files (`WORK.HDF` 4 MB with its own RDB, Flags 0x17; `SYNTH.HDF`; `ODD.HDF`) that the Makefile puts on a 32 MB `mkcard.sh` card; `gold/identify.py` the IDENTIFY DEVICE stream (word values low byte first, ATA strings first character in bits 15:8) for `WORK.HDF` (long name, 8.3 name, SYNTHRDB, both), an odd-length and a 16-character long name, a 2 GB SYNTHRDB and the SD card (whole, partition 3). Checks: `hdf[]` set up as `OpenHardfile` does (geometry against `rdb.py`), FakeRDB's blocks byte for byte on units 0 and 1, and the real `OpenHardfile` on the card's files; IDENTIFY's 512 bytes; the RDB patch of `WORK.HDF`'s own block 0 (unit 0: Flags 0x12, checksum valid; unit 1: as it is); READ SECTORS / READ MULTIPLE (after SET MULTIPLE MODE 3, 4, 16) and WRITE SECTORS / WRITE MULTIPLE (2, 16): the task file -> CHS -> LBA, the task file written back (the last sector's CHS), sector count 0 = 256, the chunks (`sectors_per_block`, never more than the FIFO holds), the status writes, every block against the HDF file (reads: the data frames of the trace and the card blocks the mock SD peripheral's `RX_TO_GAYLE` moved, in the order they reached Gayle; no direct-mode frame, no FPGA frame while a Gayle op runs) or on the card (writes: every other card byte unchanged, the read back after a write), READ MULTIPLE ranges that cross from the synthesised cylinder into the file inside a chunk (`hdd.c:536`, Task 4's parenthesis), a WRITE MULTIPLE over that boundary (the fake blocks dropped, `ERROR_HDD`); card errors (findings/sdcard-engine Task 10): the card stops answering during a READ and a WRITE (status END \| IRQ \| ERR after RDY / REQ, no block, `ERROR_SDCARD` not fatal, the card unchanged; the next READ initialises it again), a READ the Amiga abandons (Gayle error: only the RDY status); fix round 1: READ SECTORS / READ MULTIPLE of the HDF's last cluster (a read ending at the file's last sector is good; `FileSeek` keeps the cluster); fix round 2: READ SECTORS 8191+2, READ MULTIPLE 8190+4 and WRITE SECTORS 8191+2 past the end of the 8192-sector WORK.HDF end with END \| IRQ \| ERR before any sector is served or taken, the card unchanged; the last sector alone still good |
| `fdd_test` | the floppy emulation (Task 13; `fdd_test.c`): `../fdd.c` on the mock, every scenario from `HandleFDD()`. `gold/mfm.py` (an Amiga MFM track encoder written from the track format: sync 0x4489, header info / label / data split into odd and even bits, header and data checksums as the XOR of the MFM longs AND 0x55555555; its header lists the spec facts and the two Minimig choices it takes as parameters: the 12668-byte track and the read stream's clock bits) writes an LBA-tagged ADF, the read stream of every track, write streams with real MFM clock bits and the ADFs after them. ReadTrack, behind a mock `paula_floppy` that answers the six status bytes of each frame and asks (`CMD_RDTRK`) for a number of frames: the bytes after the status bytes of every FPGA frame (`SendSector`, `SendGap`: the plan's `SectorToFpga`/`SectorGapToFpga`) == `mfm.py`, for track 0 side 0 and track 79 side 1 (`gold/mfm_c00_s0.hex`, `gold/mfm_c79_s1.hex`, committed for Phase 4's L3 data check; `mfm.py` must reproduce them, `cmp`), then every track 0..159 (track/side arithmetic, the cluster cache), a read that stops after 4 sectors and goes on at sector 4, a track change in the middle, the Copy Lock workaround (`fdd.c:243`: the mock reports DSKSYNC 0x8914, 0xA144, 0x0000 in its status bytes 2-3, the firmware must send 0x4489) and a sync it passes through (0x4891), DEBUG on (the UART text, a literal; silent without DEBUG); per read, the frames, the six status bytes, no error, one `CD_AudioRefill` per `FileRead` and one `FileRead` per sector sent plus one. WriteTrack (`FindSync`/`GetHeader`/`GetData`) behind a mock write FIFO (2048 words; status `{trackwr}` and `{dmaen & dsklen[14], fifo_cnt}` as `paula_floppy`'s `wr_fifo_status`; the "Amiga" adds 2048, 300 or 7 words per poll): three cases (track 159 whole with 3 new sectors, track 1 sectors 5, 2, 9, track 80 whole from sector 6), the ADF afterwards == `mfm.py`'s (only the written sectors changed), the whole stream read, never past the FIFO count; a write-protected disk; a bad header and a bad data checksum (that sector dropped, `FatalError` 26 / 29). The file layer is a direct ADF mock with FAT semantics (4-sector clusters in a scattered chain; `FileRead`/`FileWrite` address through `file.cluster` and fail when it disagrees with `file.sector`). Also `UpdateDriveStatus` and `HandleFDD`'s drive sounds. Make also checks that every `SPIN` in `fdd.c` is commented out and that there are 28 (`out/fdd/spin.ok`; a literal, the count of the previous firmware's `fdd.c`). Fix round 1 (findings/sdcard-engine Task 10): a sector whose `FileRead` fails is sent with a wrong data checksum (checked as the Amiga does) and `ERROR_FDD`, the others as `mfm.py`'s; a failed FAT step (`FileNextSector` 0) makes the rest of the track bad without reading it, the position right again after the wrap and the next read starting over when it stopped before; a failed `FileWrite`: the other sectors written, `ERROR_FDD` "Floppy write error" |
| `mmc_test` | the real `mmc.c` (findings/sdcard-engine Task 10: `sd_sync()` wrappers over `../sdproto.c`, `../sdc.c`, `../arch/irq.c`) on the mock SD peripheral and card, over a card image it writes itself (byte i of sector n = (37 n + 11 i + (n >> 8)) mod 256): `MMC_Init`'s card commands up to the first CMD58 against `gold/mmc_init_cmds.txt` (the SD model's `+SD_LOG=1` log of the L2 `boot` run: CMD0, CMD8, three CMD55/ACMD41, CMD58), then CMD59(1) and CMD9, the CSD in `CSDData`, div 2, nothing on cfide's SPI; `MMC_Read` with token delay 0, 4, 200 bytes, `MMC_ReadMultiple` (CMD18 + CMD12) with 4 and 200, `MMC_Write` with busy 8 and 2000 bytes, `MMC_WriteMultiple` (CMD25) of 3, `MMC_GetCapacity` (CMD9, delay 200): data against the image and the card memory; `MMC_Read(lba, NULL)` / `MMC_ReadMultiple(lba, NULL, 2)` into the Gayle FIFO of `ide_port` (the mock bridge), no direct-mode transfer; the bounds in peripheral time (TIMER step 0): no answer (5 R1 waits of 16 units: `SD_E_GONE`), no data token (4 waits of 1732, `MMC_Read` and `MMC_GetCSD`: `SD_E_RETRIES`), busy for ever (4 waits of 6926: `SD_E_RETRIES`), each on an initialised card, returning 0 within [bound, bound + 3 units] (one unit more or less on each wait falls outside), `ERROR_SDCARD` set, nothing fatal; the card initialised again afterwards (the init after the no-token case fails at its CMD9: `SD_E_NOCARD`); no card at all: 0 at once (`SD_E_NOCARD`); the model's CMD55, CMD0, CMD41 = plain CMD41; fix round 1: CMD10 between CMD59 and CMD9, the re-init after the no-token case cannot read the CID (the card counts as changed until `MMC_Init`), a swapped card (`SD_E_GONE`, "SD card changed - reboot", the card untouched, `MMC_Init` takes it) |
| `drivesounds_test` | the drive sounds (Task 14; `drivesounds_test.c`): the real `drivesounds.c` (with `audio.c`) loads `sw/mkdrivesounds/drivesnd.bin` and `SYNTH.BIN` through `rafile.c` + `fat.c` + `mmc.c` on the card model (an 8 MB `mkcard.sh` card in `out/ds/`) into the mock's RAM in front of `AUDIO_BUFFER`, where they land as on the target (`DRIVESND.BIN` at 2 mod 4, `SYNTH.BIN` at 0 mod 8), then runs two op lists with the TIMER standing still (step 0, time moves by the ops): events queued (`drivesounds_queueevent`: motor start and stop, steps, insert, eject, HDD steps), `drivesounds_fill()`, the floppy sounds switched off and on, the AUDIO read value (the Amiga owns the ring), `cda_busy()` (the test's stub); the real file's sequence starts at TIMER 65450 (the wrap), renders up to the 127-tick limit, three voices and a fourth switched off, the chains (start -> loop -> loop, loop -> stop), a motor start that cancels a stop, a dropped fourth HDD step, silence until the player stops. `gold/drivesounds.py` computes the ring for the same ops from the file format (big-endian header and samples, as `mkdrivesounds.c` writes them) and the render rules (stated in its header as the big-endian firmware had them: sum, swap, `* 0x10001`, big-endian store), and asserts the coverage of each case and that `pickstep` never depends on its uninitialised `count`. Checks: the load's return value and UART lines (`Audio file - length`, each `Sound <id> ... length <size>`), and after every fill its return value, AUDIO, and the 64 KB ring byte for byte (`ring_<case>.bin`). Then five bad files (final review I1, `drivesounds.py` `bad_files`): `TRUNC.BIN` (`SYNTH.BIN` cut 100 bytes into sound 2), `ODDLEN.BIN` (`SYNTH.BIN` plus one byte), `ODDSND.BIN` (a sound of 801 bytes), `NEGSIZE.BIN` (size -2), `NEGID.BIN` (id -1): the ring, filled with a pattern a byte swap changes, is untouched, and the return value, `drivesounds_loaded()` and the lines (with `Bad length ...`/`Bad sound ...`) are the RV port's bounds rule (`rv_load`; the previous firmware only read the file) |
| `sdc_test` | the SD card peripheral driver `../sdc.c` (findings/sdcard-engine Task 9) with the real `../arch/irq.c` on the mock's interrupt controller, and the mock itself against the contract texts (`rtl/host/sdcard_spi.v`'s header, `sim/common/sd_spi_model.v`'s): the interrupt migration (`IrqSetupSources()`, cut out of `main.c` into `out/irqsetup.inc`, on stub handlers: vblank -> `c64keys_inthandler`, Akiko -> `akiko_inthandler`, EDGE, bit order, masked EDGE delivered at `IrqEnable`); the plan's step 1 (push + XFER -> the card logs CMD0, `sdc_wait` with `sdc_events` bit 0, an RX XFER pops NCR, R1 and the OCR, IRQEN off -> no event); `sdc_init` over a running op; `sdc_start`'s refusals (busy: not written; the cycle after an op end, bits 6 + 7, unknown ops, the Gayle checks: STATUS 6, its ERR acknowledged); `sdc_wait`'s wake-ups (ERR, card detect), an op that ends inside one of its TIMER reads (Task 10: the mock counts an interrupt since its last idle step as progress) and, in a forked child, the abort when nothing can happen; its TIMER bound (1804 TIMER reads, then ABORT, and with a byte in flight it returns only when the op stopped); an op still running after `sdc_start` with the default TIMER step (the trace stamp is no TIMER read); FIFO misuse fatal in the mock by default (a forked child) and counted in `sdc_misuse` at the next start; the one-shot watermark bits; a stale LEVEL report; CFG (clamp, CS, refused while busy); push / pop of odd counts; the event trace (fields, order, wrap, every entry naming its op). The mock: reset values, byte time, TX keep / commit / rewind, CRC16 out (31 C3) and in, the interlock (poisoned, an unverified byte ahead), wait ops (LAST, COUNT, TIMEOUT 3 units = 1025 bytes at div 2, 0 = 1 unit, writes ignored while busy), a 500 ms card busy (1181875 bytes at div 2) that TIMEOUT 3500 outlasts and 3400 does not (the TIMER moves 86 counts), RX-full and TX-empty pauses, FIFO misuse, ABORT, card gone mid-byte, the card-detect debounce, level-sticky watermarks, Gayle ops (words, the locked data port, g_err / short g_ack with the TX rollback, Amiga pace, ABORT, the cs 0x10 rule), and the card (CMD59 / CRC7, CRC16 on writes, CMD13, CMD25 + stop token, ACMD22, RDCRC, WRREJ, WRFAIL, NORESP, CMDCRC with repeat counts and NORESP winning, remove / insert) |
| `sdproto_test` | the SD protocol `../sdproto.c` (findings/sdcard-engine Task 10) on `../sdc.c`, the real `../arch/irq.c`, the mock SD peripheral and card. The plan's cases: `init_crc_on` (the init's commands, CMD59(1), CRC on in the card, div 2, CS off, the UART's OCR and SCK lines, the CSD), `read_ok`, `read_crc_retry` (one bad block: one retry, the data right, row 1 counted once), `read_crc_exhaust` (5 bad: `SD_E_RETRIES`, the buffer untouched, 5 CMD17, SCK one step slower with the 3rd retry and still lowered after the re-init), `write_reject_retry` (0B once: token + data + CRC16 on the wire twice, byte for byte), `write_fail_0D` (no retry, the sector untouched, no re-init), `cmd25_acmd22` (the 3rd of 5 rejected: stop token, ACMD22, CMD25 from the 3rd; the card content), `timeout_cmd13_gone` (a card that stops answering: 4 CMD17, then CMD13, `SD_E_GONE`; re-init when it is back), `busy_500ms` and `token_100ms` (no timeout inside the spec's limits; `sd_poll` 1 on every pass of a loop that keeps running), `one_op_at_a_time`; also CMD18 + CMD12 and a CRC failure inside a run (CMD12, CMD18 from the failed block), the to-Gayle form (`RX_TO_GAYLE` per block with the port bit, a bad block never reaches Gayle, an abandoned read: `SD_E_GAYLE`, the card stopped, no error), a command CRC error once and four times (CMD13 answers: `SD_E_RETRIES`), a single-block write rejected five times, card gone in a token wait (`SD_E_GONE`, `SD_E_NOCARD` while out, re-init when back), the CSD op, bad ops. `SDPROTO_UART=1` prints the firmware's UART text of some cases; fix round 1: the card swapped while out (another CID: every op `SD_E_GONE`, no command reaches the card, the card untouched; `sd_forget` + init takes it), a card that reset itself (`SD_E_RESET`, the UART line, re-init), ACMD22 counting one block short (those again from buf) and a card that always loses one (bounded: `SD_E_RETRIES`), the SCK floor (no step, no line), the CMD13 probe's line, `token_100ms` with the peripheral clocking during > 100 loop passes |
| `rom_test` | a failed card read during a ROM load (findings/sdcard-engine Task 10 fix round 1): `SendFileV2` (`fpga.c`) and `UploadKickstart` (`config.c`), cut out by the Makefile, on stub files (512 KB, keyed 0x8000b, `ROM KEY`) with the Amiga window mapped at its own address: a good load (512, both copies), a failed block read (0 at once, no further read, `ERROR_ROM` "ROM read error" with the block), a failed second copy, keyed header and key file read: `UploadKickstart` 0, `ERROR_ROM` (the error page's Reboot path) |
| `boot_test` | the Amiga-facing words of `boot.c`, `main.c` and `hexdump.c` (Task 14; `boot_test.c`): `BootUploadCopper()` without a `COPPER_FILE` writes the default copper list as big-endian words (`00 E0 00 08 00 E2 ...`) at `COPPER_ADDRESS ^ HOSTMAP_ADDR` -- the test maps that page at its own address (`mmap` `MAP_FIXED_NOREPLACE`) and checks that nothing else in it changed; with a `COPPER_FILE` (stubbed `RAOpen`/`RARead`) the file's bytes. `CheckSum` (cut out of `main.c` by `sed` into `out/checksum.inc`: `main.c` holds `main()`) of a 512-byte block = its big-endian word sum (computed by python3, in the comment), at an aligned and an odd address; `hexdump()` prints big-endian words, at an aligned and an odd address; a `COPPER_FILE` whose read fails half way: the default list (findings/sdcard-engine Task 10 fix round 1) |

### `config_test` cases

`gold/mkcfgbe.py` writes big-endian config files (the previous firmware's
layout) from a field table
that follows `config.h` (`struct.pack`, independent of the C code); the card
images come from `tools/sim/mkcard.sh`.

| Part | What is checked |
|---|---|
| Generated files | the defaults, every field non-zero and distinct, versions 2 and 3, a 208-byte version 3 file, the `fwboot_cfg` file (`l2`), and five corrupt ones (id, version 5, version 0, 155 and 213 bytes) |
| `cfgconv` (built here with the sanitizers, native and `-m32`) | `--check` == the generator's text; `--to-rv`, then `--check` of the result shows the same fields; `--to-be` gives back the same bytes |
| `cfgconv` refusals | corrupt input, already in the target order, the output is the input (by name, `./` spelling or hard link): exit 1 and nothing written |
| `cfg_order` / `cfg_swap` | `cfg_order` of every case; every field of each `--to-rv` result read through the firmware's `configTYPE` against the table; `cfg_swap` == `cfgconv` |
| Card (a) | only `MINMGAR.CFG`: loaded as it is |
| Card (b) | only big-endian `MINMGAA*` files (slots 0, 1, 2): converted, the RV files appear and equal `cfgconv --to-rv` (the version-2 rules for old files), the conversion line is on the UART; every byte the run changed lies in the new files' entries, FAT entries and clusters (the `MINMGAA*` files' entries and clusters are unchanged byte for byte); a second load converts nothing and writes nothing |
| Card (c) | a big-endian file as `MINMGAR.CFG`: rejected ("Wrong configuration file format!", then "(832 byte order)"), the defaults, nothing written |
| Card (d) | both files: the RV file wins |
| Card (e) | an RV file as `MINMGAA.CFG`: not converted; no file at all: the defaults == the generator's |
| Card (f) | the config file's read fails (a card error, retries out; findings/sdcard-engine Task 10 fix round 1): no config, the defaults, "Config file read error - using defaults", nothing written |
| After card (b) | by `mtools`: `MINMGAR.CFG` == `cfgconv --to-rv MINMGAA.CFG`, the `MINMGAA*` files unchanged; `fsck.fat -n` clean |
| `CFGBE_DIR` | real big-endian files (see Setup): the same round trip as the generated cases |

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
count that `FileCreate` leaves alone. Each image is
also checked clean by `fsck.fat -n` as built. `fat_test` only reads the image;
it writes the card to `out/<image>_<64|32>.img` for the checks, which
`fat_check.sh` deletes when they pass. `make` rebuilds the images when a
script changed or one of `fatimg.sh`'s outputs is missing.

## The mock (`mock_hw.c`, `mock_sdc.c`, `mock_hw.h`)

`-DHOSTTEST` swaps the register macros of `fw/ctrl/hardware.h`
(`SPI`, `RDSPI`, `Enable*`/`Disable*`, `SPI_slow`/`SPI_fast`, `TIMER`, `HOST_REQ`,
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
* **HOST_REQ** (cfide `0xFFFFFFB4`, bit 0 `OSD_RDY`): `mock_host_req(n)`, the
  next n reads return 0, every read after them 1 (`MOCK_HOST_REQ_STUCK`: 0 for
  ever); 1 at once after `mock_reset()`. `mock_host_req_reads()` counts the
  reads. `mock_order_start()` starts the order log `mock_order()`: one
  character per `HOST_REQ` read (`0`/`1`, its bit 0) and per SPI DATA access
  (`W` write, `R` read: `SPI(x)` is `WR`).
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

The SD card engine (Task 9; `mock_hw.h` has every call with its rules; the
peripheral, the Gayle bridge and the interrupt controller are in
`mock_sdc.c`, which every test that links `mock_hw.c` links too; the two
share `mock_int.h`):

* **The card's Task 4 behaviour** (`sd_spi_model.v`): CMD59 (CRC7 on
  commands, CRC16 on written blocks), CMD13, CMD25 with the stop token,
  ACMD22, `mock_card_error()` (RDCRC, WRREJ, WRFAIL, NORESP, CMDCRC, with
  the model's n / count semantics), `mock_card_remove()` / `_insert()`,
  `mock_card_new()` for a blank card. Read blocks carry their real CRC16
  when the command came through the SD peripheral, the old `00 00` through
  cfide's `SPI()` (the goldens of the old path, `gold/dmode.txt`). Busy and
  token-delay bytes are runs: a million of them cost nothing.
* **One clock** in `clk_114` cycles (`mock_now()`); the TIMER follows it
  (658629 cycles a count) and every TIMER advance is time for the
  peripheral. An SD register access takes 16 cycles. With the default
  TIMER step every TIMER read is 5.8 ms (13.7 KB at div 2): an op ends
  inside code that reads the TIMER; `sdc.c`'s trace stamps with
  `hosttest_timer_peek()`, which moves nothing.
* **The SD peripheral** (`rtl/host/sdcard_spi.v`'s header) at byte level,
  behind `sdc.h`'s `SDC_R` / `SDC_W`: every op, TX keep, the interlock,
  refusals, STATUS 1-8, the level-sticky watermarks, TIMEOUT, pauses, card
  gone, the card-detect debounce. `mock_sdc_step()` runs it to the next
  interrupt (at most a TIMER count), `mock_run()` for a time,
  `mock_sdc_peek()` shows its state, `mock_sdc_log()` its ops and ends,
  `mock_sdc_wire_on()` / `mock_sdc_wire()` the bytes on the wire.
  `sdc_wait()` under `HOSTTEST` steps it and aborts the test when nothing
  can happen (`mock_sdc_on_stall()`, `mock_sdc_stall_fatal(0)` for the
  exceptions). FIFO misuse (STATUS 8) ends the test too
  (`mock_sdc_misuse_fatal(0)` for a test that provokes it).
* **The Gayle bridge** of ops 4 and 5: `mock_gayle_from()` / `_into()` per
  port, `mock_gayle_end()` (g_err, short g_ack), `mock_gayle_hold()` (Amiga
  pace), `mock_gayle_cs_violations()` (a cs 0x10 frame during a Gayle op).
* **The interrupt controller and MIE** behind `arch/irq.h`: the real
  dispatcher is called when the line is up and MIE on, at every mock call
  that can change it (SD register accesses, TIMER reads, `irq_restore`,
  stepping); `mock_irq_pulse()` / `_level()` for the other sources;
  `mock_irq_stale_level()` reports a LEVEL bit once more after it dropped.
  A source nobody clears ends the test ("interrupt storm") instead of
  hanging it.

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
(a 16-byte print buffer, `%x` upper case in the ISO model, a
stale `formats.txt`, a format without a case). There is a mutant for each
test (for `swap_test`: `rd_le32`, `wr_be16`, `be32`, `le16`, the sign
extension of `SwapBBBB`; for `fat_test`: `StartCluster` read with `SwapBB`
again, everywhere and in `ScanDirectory` only, `FileSize`, the FAT16 and FAT32
links, the FAT32 EOC literal `0xFFFFFF0F`, the MBR signature cases exchanged,
the new entry's start cluster and size, `HighCluster` everywhere, in
`FileOpen` only and in `FileCreate`'s write, `FileCreate`'s modify and create
dates, `GetFATLink`; for `sdc_test` (Task 9): the handler without its IRQACK
and without the one-shot watermark rule (both "interrupt storm"), `sdc_start`
without the refusal read-back and without the busy check, without dropping
stale events, `sdc_wait` without ERR / CD in its mask, the TIMER bound 1799,
the divider clamp, the trace head, EDGE mode, `sdc_init` without its ABORT,
the trace stamp as a TIMER read, `sdc_misuse` not counted, `sdc_wait`
without its abort wait, events without their op,
`IrqSetupSources()` with the handlers exchanged and without the Akiko
enable, and the mock against its contract (CRC check, interlock, ahead-ok,
timeout, RX high mark, rewind, byte time, card gone, rollback, the locked
data port, CRC7 and CRC16 checks, RDCRC, ACMD22's count, NORESP, PENDING
clearing its EDGE bits, misuse not fatal); for `sdproto_test` (findings/sdcard-engine
Task 10): the read CRC retries one short and the CRC result ignored (the plan's two),
the write CRC retries one long, the command retries one short, the SCK step at the 4th
retry, no CMD59(1), a wrong CRC7 polynomial, no `TX_REWIND` before a resend, no ACMD22
resume, an abandoned Gayle read reported as a card error, card gone not seen, no CMD13
probe, the token and busy bounds under the spec's maxima; for `mmc_test`: each of the
three bounds one unit off (in peripheral time), no `SetError`, the to-Gayle port
fixed at 0; for `config_test`: `cfg_swap` without `hdfdir[3]` (the brief's), `cfg_order`
without the big-endian case, `LoadConfiguration` without the swap, saving over the
big-endian file, with the `MINMGAA` names, without "(832 byte order)", converting a file
of any order, `ConfigurationExists` without the big-endian file, and `cfgconv`
without its output-is-input and target-order refusals; for `hdd_test`: `RDBChecksum`
summing native longs and IDENTIFY without the string swap (the brief's two),
the RDB patch on native longs, the boundary loop with `<= 0` and without its
`blk` bound, sector count 0 = 255, the mock bridge's `RX_TO_GAYLE` words dropped, the card error's END | IRQ | ERR dropped and an abandoned read given it (Task 10); for `cdrom_test`: an abandoned CD read given an error (Task 10), a read past the end of the chain taken for good (fix rounds 1, 2); Task 10 fix rounds 1 and 2 also: `FileReadEx` failing at the end of the chain with no block left, `FileSeek` storing the EOC mark, no bound check of reads / writes past the end of the HDF (`hdd_test`), no CID compare, a lock that does not stick, no idle-bit check, no ACMD22 loss bound (a hang: the timeout), no probe line, no SCK floor (`sdproto_test`), the OSD's "SD card changed" text (`mmc_test`), a ROM block, copy and key read not checked (`rom_test`), the floppy's wrong checksum, lost position and write error (`fdd_test`), the config read error (`config_test`), the copper fallback (`boot_test`); for `fdd_test`: `SendSector` one byte short, which must fail against `mfm.py`'s streams of tracks 0 and 159 (the brief's), the Copy Lock workaround gone, tracks 128..159 read at the sector of track - 128, `GetHeader`'s sector number and `GetData`'s even data bits decoded from the wrong bits, `WriteTrack` going back one sector off, the header checksum not checked, `GetData` taking 515 words for a 516-word sector (reads past the FIFO count at 7 words per poll), and a stale committed golden stream; for `drivesounds_test`: the previous firmware's per-sample swap kept (the brief's: the ring differs), the header read as `*(long *)` (the brief's: on LP64 an 8-byte load at `SYNTH.BIN`'s 4 mod 8 size field, which UBSan stops) and as `*(int *)` (RV32's 4-byte long: the little-endian sizes, the test's load check), the samples not converted at load, the `& 0xffff` dropped, each of the four `(enabled & DRIVESOUNDS_FLOPPY)` conditions always true, and each bound of the in-place conversion dropped (`ds_noclamp`: `TRUNC.BIN` writes the ring; `ds_oddfile`: `ODDLEN.BIN` loads, on x86 without a trap; `ds_oddsize`, `ds_negsize`: the load lines; `ds_negid`: UBSan, `sounds[-1]`); for `boot_test`: the copper list without `be16`, `CheckSum` and `hexdump` on native words; for `diskstat_test`: a bucket bound off by one (the brief's: 16 sectors counted as 17-64); for `hdd_test`, the diskstat hook: `ATA_WriteSectors`' FIFO wait without the polls that found it not ready (`MMC_Write`'s busy polls went with cfide's SPI card path, Task 10); for `spireply_test`: the poll removed and the bound 0 (the brief's two), the bound 3, the timeout not counted, `HOST_REQ_OSD_RDY` on bit 1; for the `check_io` fixture, through `make check_io`: no forgetting after a `j`, the offset rule by 2, the UART range without `0xFFFFFFF0`, `li` not tracked) and one for every register class of the I/O map (address and width of
SPI DATA/CS/SPEED, UART, TIMER, `HOST_REQ`, PLATFORM, AUDIO, `FPGA_TEMP_RAW`,
`VIDEOSCALE`, `RECONFIGURE`, keyboard words and OUT, Akiko, RTC, I2C, the
interrupt controllers, `IRQ_SDCARD`, the SD peripheral (base, width, CFG,
VERSION's offset, `SDC_VERSION`, `SDC_W`), each CS and SPEED value,
`SPI()`/`RDSPI`, and `RS232()` itself).

# fw/ctrl_rv - OSD / host firmware for the VexRiscv host CPU

Port of `fw/ctrl_832` (ZPU-class 832 host CPU) to RV32IMC. Task 2 made the
**verbatim copy**; from then on `diff -ru fw/ctrl_832 fw/ctrl_rv` is exactly
the port. Edits so far: Task 3's call-site edits ("Differences from
fw/ctrl_832") and the C library / host-test files ("C library", "Host tests");
Task 4's `Makefile` and gcc 15 / gnu23 compile fixes ("Building", "gcc 15 and
gnu23 compile fixes"); Task 5's I/O map ("Differences from fw/ctrl_832");
Task 9's byte-order helpers and the FAT/MBR fields ("Byte order (Task 9)");
Task 10's TIMER bounds in `mmc.c` ("SD driver timeouts and the TIMER (Task 10)");
Task 11's config file byte order, file names and `cfgconv` ("Config file byte
order (Task 11)"); Task 12's hard disk byte order ("Hard disk byte order
(Task 12)"). Task 19 only completed the READMEs.

Every command block in this file (and in the READMEs it points to) starts
from a fresh Ubuntu 24.04 machine, from the repository root, and pastes into
bash and into a stock zsh as it is: no unquoted variable that has to be split
into words, and a comment sits on a line of its own above the command it
describes, never behind it (stock zsh takes no `#` comments at the prompt
without `setopt interactivecomments`: a pasted comment line makes it print
`zsh: command not found: #` and go on; scripts and bash are not affected).

## Copy base

Copied from `fw/ctrl_832` at osd-riscv HEAD `2f5df34c9821fef3d9a4101fe649f9c954a3e482`
(last change to `fw/ctrl_832`: `8f8cf88`).

## What was copied

- The 29 units of the 832 Makefile's `COMMON_SOURCES` (`.c` and `.h`):
  hardware config fat fdd fpga boot hdd main menu mmc spi osd rafile swap
  hexdump uart errors interrupts c64keys akiko audio drivesounds rtc i2c
  adv7511 atapi cdrom cue cdaudio. Task 4 deleted `interrupts.c` and
  `interrupts.h` again: `arch/irq.c` / `arch/irq.h` replace them (same API).
- Headers without a unit: `amiga_rawkey.h charrom.h logo.h minimig_cfg.h
  hdd_internal.h firmware.h bootcustominit.h`, and `bootcustominit.s`.
- `test/*.c`, `test/Makefile`, `test/.gitignore` (unchanged for now) and
  `test/emu/*.c` (the three emu programs, used by L1 `units`).

`arch/` is Phase 2 / Task 1 (crt0, trap, irq, `arch.mk`) and is not part of
the copy.

## What was not copied, and why

- `version.h`: generated into `build/` from Task 4 on, never tracked here.
- `Makefile`: vbcc; this tree's `Makefile` (Task 4) is new.
- `Makefile.68k`, `startup_m68k-elf.s`, `startup_zpu-elf.s`,
  `osd_m68k-elf.ld`, `osd_zpu-elf.ld`: 68k/ZPU leftovers.
- `small_printf.c`, `small_printf.h`, `printf.c`: not in `COMMON_SOURCES`.
  The 832 links lib832's `printf`; the RV tree uses newlib-nano plus its own
  `printf`/`vprintf` (Task 3, decision 12.12). No lib832 file is copied.
- `test/emu/Makefile`: vbcc832 + 832e, 832-only.

## Check the copy

From the repository root (works in zsh and bash; needs only coreutils and
git, no toolchain):

```sh
(cd fw/ctrl_rv && find . -path ./arch -prune -o -type f ! -name README.md ! -name .gitignore -print) | while read -r f; do cmp "fw/ctrl_832/$f" "fw/ctrl_rv/$f" || echo "DIFF $f"; done
```

With the verbatim copy of Task 2 no `DIFF` line appeared. Since Task 3 these
copied files differ on purpose (each edit is a row of "Differences from
fw/ctrl_832"): `akiko.c boot.c config.c drivesounds.c fat.c main.c menu.c`, and
`test/Makefile`, `test/.gitignore` (the C-library wiring); since Task 4 also
`audio.c c64keys.c drivesounds.h firmware.h hdd.c` and `Makefile`; since Task 9
also `fat.h swap.c swap.h`; since Task 11 also `config.h`; since Task 12 also
`hdd_internal.h`; since Task 14 also `hexdump.c` (`firmware.h` is deleted: it
exists only in `fw/ctrl_832` now). `find` also
lists files that only exist here (`rvlibc.c`, `rvlibc.h`, `test/lib_test.c`,
`test/fmt_*`, `test/mutants.sh`, `test/gold/`, `test/rv/`, `test/swap_test.c`,
`test/fat_test.c`, `test/fatimg.sh`, `test/fat_check.sh`, `cfgswap.c`,
`cfgswap.h`, `tools/cfgconv/`, `test/config_test.c`, `test/config_check.sh`,
`test/hdd_test.c`, `test/fdd_test.c`, `test/drivesounds_test.c`,
`test/boot_test.c`); `cmp` reports
those as missing in `fw/ctrl_832`. `interrupts.c`/`interrupts.h` exist only in
`fw/ctrl_832` (Task 4), so the loop above does not see them.

## Building

Packages (Ubuntu 24.04; `make` and `g++` come with `build-essential`):

```sh
sudo apt install build-essential gcc-multilib git curl python3 xxd mtools dosfstools fdisk
```

`gcc-multilib` is for the `-m32` host tests (and the lib832 printf format
reference, which is a 32-bit program); `curl` is what `fetch-xpack.sh` uses;
`mtools dosfstools fdisk` make the SD card images of the tests and the
benches (`tools/sim/mkcard.sh`); `xxd` is for `bootcustominit.h`. For the
simulations (L1, L2) add `sudo apt install verilator ghdl ccache`, for the
Clang build `sudo apt install clang lld` (both optional; their sections say
more).

The RISC-V toolchain is the pinned xPack `riscv-none-elf-gcc` 15.2.0-1,
installed into `~/opt` with its checksum verified. newlib-nano comes with it:
there is nothing else to install.

```sh
bash tools/riscv/fetch-xpack.sh
bash tools/riscv/check-toolchain.sh
```

Another install: `RV_GCC_DIR=... RV_PREFIX=...` in front of any `make`
(`tools/riscv/toolchain.mk`); `tools/riscv/README.md` has the details.

Build, and run the checks (the boot ROM is built first because `check` (g)
reads its map; `make -C fw/ctrl_boot_rv` rebuilds the committed
`OSDBoot_rv_ROM.vhd` byte for byte, so git shows no change):

```sh
make -C fw/ctrl_boot_rv
make -C fw/ctrl_rv clean all size
make -C fw/ctrl_rv check
```

Output in `fw/ctrl_rv/build/` (gitignored): `RV32OSDA.BIN` (`objcopy -O
binary`, loaded by `fw/ctrl_boot_rv` to 0x2000), `RV32OSDA.elf`, `.map`, `.lst`
(disassembly with source), `version.h`. `B=dir` builds into another directory;
`EXTRA_CFLAGS=...` adds compiler flags for bench variants (empty for the
shipped image); `EXTRA_OBJS=...` links extra objects after the firmware's
(empty for the shipped image; `sim/host_bridge/fwboot` links its trap
constructor `smoke_trap.o` this way, into its own `B=` directory).

- **Flags** (Global Constraints, decision 12.12): `$(RV_CFLAGS_FW) -std=gnu23
  --specs=nano.specs -g -I. -Iarch -I$(B) -Wall -Wextra -Werror`; link `$(RV_LDFLAGS_FW)
  --specs=nano.specs -nostartfiles -T arch/firmware.ld
  -Wl,--no-warn-rwx-segments -Wl,-Map,...` with `-lc_nano -lgcc` last;
  `arch/crt0.S` is the start-up (`arch/arch.mk`). The tree is warning-free under
  `-Wall -Wextra -Werror` ("Found by -Wextra (Task 7)").
- **Sources:** the 832 Makefile's `COMMON_SOURCES` without `interrupts`
  (`arch/irq.c`), plus `rvlibc.c`.
- **`version.h`** is generated into `build/` by the 832 recipe with `-RV` for
  `-832` (`MM_VERSTRING "$VER:AMR<yymmdd>-RV"`, `MM_FIRMWARE_VERSION
  "<yyyy-m-d-h-m>"`, `MM_YEAR`..`MM_WEEKDAY`), never in this directory. It is
  regenerated on every `make` and replaced only when its text changed (the
  minute), so `fpga.c main.c rtc.c` rebuild then (the 832 Makefile `touch`ed
  `fpga.c main.c`).
- **`bootcustominit.h`** is used as committed. It is rebuilt (`vasmm68k_mot`
  + `xxd`, the `.bin` in `build/`) only if `bootcustominit.s` is newer and
  vasm is installed; the result is byte-identical to the committed header
  (checked 2026-10-17).

**Size** (`make size`, xPack gcc 15.2.0-1, 2026-10-17, `-Os`):

| | text | data | bss | `.BIN` |
|---|---|---|---|---|
| RV32IMC, gcc (this tree, Task 18 fix) | 89,112 | 3,484 | 59,292 | **92,596 B** |
| RV32IMC, clang (`CLANG=1`, "Clang build") | | | | 100,188 B |
| 832 (`832OSDAD.bin`) | | | | 83,830 B |

Plan estimate 85-95 KB; the gcc image is +8,766 B (+10.5 %) over the 832's.
The figure moves by a few bytes with the date strings of `version.h`. `_end` =
0x27150 (from the map; < 0x70000, `AUDIO_BUFFER`, a linker ASSERT); the boot
ROM's `_end` is 0x1040 (< 0x1400). Stack high-water mark on `fwboot`: 0x1950
(1712 B used). History: Task 4 93,764 B, Task 9 91,368 B (`le16`/`le32` are
the identity on RV32, so the `SwapBB`/`SwapBBBB` calls of `fat.c` are gone),
Task 14 92,436 B, Task 17 92,588 B, Task 18 92,596 B (`StackFill`, below).

**`make check`** runs every part (`make -k`) and fails if any is red:

| Part | What | Status |
|---|---|---|
| (a) | no `lr.w`/`sc.w`/`amo*.w` in the disassembly (the core has no A extension) | pass |
| (b) | no load from the UART, `0xFFFFFFF0` (a read deadlocks the bus): `check_io.awk` over the disassembly | pass |
| (c) | every I/O access (address `0xFFFFFF00..0xFFFFFFFF`) has an address that is a multiple of 4 (each register at offset 0, 4, 8 or 0xC of its 16-byte window): `check_io.awk` | pass (Task 5: 1155 I/O accesses seen) |
| (d) | no `__geta4`, `__constructor`, `setstack`, `c_entry` in `fw/ctrl_rv/*.[ch]` | pass |
| (e) | the C library guard ("C library"): `nm` of the `.elf` has none of `_sbrk _sbrk_r malloc free realloc calloc _write _write_r _read _read_r _fstat _fstat_r _isatty _isatty_r _lseek _lseek_r _close _close_r __sinit __sfp _printf_float _scanf_float asprintf vasprintf open_memstream fprintf fputc fputs fflush`; the map shows `_malloc_r _realloc_r _free_r printf vprintf` from `rvlibc.o` and `putchar puts` from `uart.o` (so none of them from `libc_nano.a`). A syscall pull is already a link error (no syscall is defined) | pass |
| (f) | no `#define true` / `#define false` in `fw/ctrl_rv/*.[ch]` (gcc 15 accepts redefining the C23 keywords without a word) | pass |

(b) and (c) see an access when its base register is `zero` or holds a
constant set by `li`/`lui`/`addi`/`mv` earlier in the same function (straight
line; forgotten at a call, no tracking over a branch join). On the Task 5 tree
1147 of the 1155 I/O accesses are zero-based; 8 compile as `li a4,-112` +
`lhu 0(a4)` (the keyboard words in `c64keys.c`) or `li a5,-160` + `sw 0(a5)`
(the I2C base in `i2c.c`) and are seen through the tracking. An address
computed any other way, or a base held across a branch join, is not seen:
the only guarantees there are that `uart.h` has no read and that no source
file reads `UART_TX`. The checks fail when they find no I/O access at all, and
`.DELETE_ON_ERROR` plus a failing `nm` make a broken tool a red check, not an
empty pass.

Each part was seen red once (Task 4): (a) (b) (c) (e) on a disassembly / `nm` / map
with a planted `amoadd.w`, `lbu a5,-16(zero)`, `sh zero,-30(zero)`,
`sw a4,-6(zero)`, `_sbrk`, `fflush` and `puts` moved to `libc_nano.a`; (d)
and (f) on the Task 3 tree (`__constructor`, `setstack`, `c_entry`,
`__geta4`; `firmware.h:23-24`).

**Constructors** (`.init_array` in the map, `SORT_BY_INIT_PRIORITY`): the 832
ran `interrupts` (priority 100), then the two at 101 in name order, `akiko`
before `c64keys`. Here `arch/irq.c` (101) installs the default handler,
`akikoconstructor` is `constructor(102)`, `c64keysconstructor`
`constructor(103)`. The map shows `.init_array.00101` (`irq.o`) and
`.init_array.00103` (`c64keys.o`) only: `akikoconstructor` has an empty body,
and gcc at `-Os` drops the `.init_array` entry of an empty constructor (the
function itself stays; at `-O0` `akiko.o` has `.init_array.00102`). Nothing
runs at that slot on either CPU, so the order is the 832's.

## On the SD card

The boot ROM (`fw/ctrl_boot_rv`, in the bitstream) looks for `RV32OSDA.BIN`
in the root directory of the first FAT partition and loads it to 0x2000; the
832 bitstream's boot ROM looks for `832OSDAD.BIN` in the same place. One card
serves both bitstreams: copy `fw/ctrl_rv/build/RV32OSDA.BIN` to the card
root next to `832OSDAD.BIN` (and `KICK.ROM`, `DRIVESND.BIN`, the ADFs and
hardfiles as before). Names are upper-case 8.3.

With a card that a desktop mounts (the volume name below is only an
example; `sync` before the card comes out):

<!-- replay-skip: needs a real SD card -->
```sh
cp fw/ctrl_rv/build/RV32OSDA.BIN "/media/$USER/MINIMIG/RV32OSDA.BIN"
sync
```

Or without mounting, with mtools on the partition (`lsblk` shows it; `sdX1`
is a placeholder, and the partition must not be mounted):

<!-- replay-skip: needs a real SD card -->
```sh
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT
sudo env MTOOLS_SKIP_CHECK=1 mcopy -o -i /dev/sdX1 fw/ctrl_rv/build/RV32OSDA.BIN ::RV32OSDA.BIN
sync
```

Without a card, the same on a raw card image (what the benches use):
`tools/sim/mkcard.sh` makes a reproducible FAT16 image (MBR, partition at
LBA 2048 = byte 1048576) holding the files given, and mtools reaches
inside:

```sh
bash tools/sim/mkcard.sh fw/ctrl_rv/build/card.img 16 fw/ctrl_rv/build/RV32OSDA.BIN
MTOOLS_SKIP_CHECK=1 mdir -i fw/ctrl_rv/build/card.img@@1048576 ::
```

## Config files on the card

The firmware keeps its settings in a 212-byte file in the card root:
`MINMGAR.CFG` (the default slot) and `MINMGAR1.CFG` .. `MINMGAR4.CFG`,
little-endian ("Config file byte order (Task 11)"). The 832 firmware's
files are `MINMGAA*.CFG`, big-endian. **First boot:** when a slot has no
`MINMGAR*` file but has the 832 one, the firmware reads the 832 file,
converts it in memory, uses it and saves it as the `MINMGAR*` file (boot
line `Converted 832 configuration MINMGAA.CFG`); the 832 file is never
written. An 832 file that is put under the RV name is rejected ("Wrong
configuration file format!", "(832 byte order)") and the defaults are used.
`tools/cfgconv` converts by hand, ahead of time or back
(`fw/ctrl_rv/tools/cfgconv/README.md` has the card and image recipes). A
complete round trip on made-up data (`mkcfg832.py` writes the 832 files the
host tests use) and onto the card image of the section above:

```sh
make -C fw/ctrl_rv/tools/cfgconv
python3 -I fw/ctrl_rv/test/gold/mkcfg832.py fw/ctrl_rv/build/cfg832
fw/ctrl_rv/tools/cfgconv/cfgconv --check fw/ctrl_rv/build/cfg832/defaults.cfg
fw/ctrl_rv/tools/cfgconv/cfgconv --to-rv fw/ctrl_rv/build/cfg832/defaults.cfg fw/ctrl_rv/build/MINMGAR.CFG
fw/ctrl_rv/tools/cfgconv/cfgconv --check fw/ctrl_rv/build/MINMGAR.CFG
MTOOLS_SKIP_CHECK=1 mcopy -o -i fw/ctrl_rv/build/card.img@@1048576 fw/ctrl_rv/build/MINMGAR.CFG ::MINMGAR.CFG
MTOOLS_SKIP_CHECK=1 mdir -i fw/ctrl_rv/build/card.img@@1048576 ::
```

## Clang build (Task 18, decision 12.8 gate 1b)

After the packages and the toolchain steps under "Building" (the boot ROM
is built there; `check` (g) reads its map), output in `build_clang/`
(gitignored):

```sh
sudo apt install clang lld
make -C fw/ctrl_rv CLANG=1 clean all size check
```

A portability check, not a shipping build: gcc stays the image. clang is
Ubuntu 18.1.3 (`clang --target=riscv32-unknown-elf`; `-std=gnu23` is accepted,
`__STDC_VERSION__` 202311L, so no `gnu2x` fallback). The flags are the gcc
build's (`RV_CFLAGS_FW`, `-Wall -Wextra -Werror`) with two differences:

- clang has no `nano.specs`: the newlib-nano headers are given by hand,
  `-isystem $(RV_GCC_DIR)/riscv-none-elf/include/newlib-nano -isystem
  $(RV_GCC_DIR)/riscv-none-elf/include`, in that order.
- no `-fstack-usage` in clang (`make stack` refuses with `CLANG=1`).

Only compiling (the C files and `arch/crt0.S`, `arch/trap.S`) is clang; the
link stays on the xPack gcc driver with the firmware's line (`-nostdlib
-nostartfiles`, `--specs=nano.specs`, `-lc_nano -lgcc` last), not `ld.lld`
(installed here, unused): the map is GNU ld's, so check (e) works unchanged.
`CLANG_CC=...` picks another clang.

`-Wno-unknown-warning-option -Wno-unknown-attributes` (the `CLANG_WNO` variable,
CLANG block only): `hdd.c` and `drivesounds.c` carry `#pragma GCC diagnostic
ignored "-Wmaybe-uninitialized"` and `menu.c` an `__attribute__((nonstring))`,
both gcc-only spellings that clang does not know; neither is a defect.

Fixed in the source (codegen-neutral for gcc: the disassembly is identical
before and after except `StackFill` below):

- `rafile.c` `RAReadLine`: `result` was only ever ANDed, never returned (clang
  `-Wunused-but-set-variable`); the variable is gone, `FileRead` is still called.
- `c64keys.c` `c64keys_inthandler`: `idx` was only decremented (same warning);
  removed with its `--idx`.
- `stackcheck.c` `StackFill`: `register uintptr_t sp __asm__("sp")` read as a
  plain variable is an uninitialised local in clang (real: it would have read
  garbage, and at `-O0` clang even stores that slot into `sp`). Now
  `uintptr_t sp; __asm__ volatile("mv %0, sp" : "=r"(sp));`, which only reads
  `sp` at every `-O` level on both compilers. This is the one change that is
  not byte-identical for gcc: `StackFill` at `-Os` is `mv a4,sp; addi a4,a4,-64`
  instead of `addi a3,sp,-64` (the same value; the gcc `.BIN` is 92,596 B, +8 B).

`check_io.awk` now forgets its tracked constants after an unconditional jump
(`j`, `jr`, `ret`, `mret`): clang places blocks that are reached only by a
branch right after a `j`, where a stale `li s1,0` made `lw s6,-16(s1)` look
like a UART read. The gcc listing gives the same counts as before. clang folds
every I/O address into a zero-based access (1340 seen, all `(zero)`), so (b) and
(c) still check something.

Result: clang image `.text` 96,708 B, `RV32OSDA.BIN` 100,188 B (gcc 92,596 B).
`SIM=verilator RUNTAG=p3t18 FW=fw/ctrl_rv/build_clang/RV32OSDA.BIN bash
sim/host_bridge/run.sh fwboot`: PASS, OSD GAP min 40, STACK low 0x1980 (gcc:
40, 0x1950).

## Stack and size budget (Task 17)

The boot ROM map that `check` (g) reads comes from `make -C fw/ctrl_boot_rv`
(under "Building"). `build_sr` is the sim-only image:

```sh
make -C fw/ctrl_rv all stack size check
make -C fw/ctrl_rv B=build_sr EXTRA_CFLAGS=-DRV_STACK_REPORT
SIM=verilator RUNTAG=p3t17 bash sim/host_bridge/run.sh fwboot
SIM=verilator RUNTAG=p3t17s FW=fw/ctrl_rv/build_sr/RV32OSDA.BIN bash sim/host_bridge/run.sh fwboot
```

(The first `fwboot` run uses `fw/ctrl_rv/build/RV32OSDA.BIN`, the second the
sim-only image; about 6 minutes each on Verilator.)

The stack starts at 0x2000 (`__stack_top`) and grows down into the 8 KB boot
BRAM. `stackcheck.c`: `StackFill()` (first statement of `main()`) paints
`[0x1400, sp - 64)` with `0x5A5AA5A5`; `StackHighWater()` returns the lowest
address that no longer holds the pattern. The floor 0x1400 is where the boot
ROM image has to end below (`make check` (g) reads `_end` from
`fw/ctrl_boot_rv/build/OSDBoot_rv.map`: 0x1040), so a soft re-run of the boot
ROM stays possible. The value is printed on the UART (`Stack high water <hex>`)
when DebugMode is switched on (main loop, on the 0 -> 1 edge). The Debug OSD
page has no free text line (`_showdebugmessages` writes all eight rows), so
UART only. `-fstack-usage` writes `build/*.su`; `make stack` lists the 20
largest frames.

`-DRV_STACK_REPORT` (directory `build_sr`, gitignored; the shipped
`build/RV32OSDA.BIN` has no such code) prints `STACKHW <hex>` once, at the 5th
pass of either main loop (the bench card has no kickstart, so the firmware
sits in the error loop). The bench's `STACK low` monitor ignores full-word
writes of the pattern, so `StackFill` itself does not count.

Measured (2026-10-18, gcc 15.2.0-1, `-Os`, after the Task 18 fix):

| | |
|---|---|
| `size` text / data / bss | 89,112 / 3,484 / 59,292 |
| `RV32OSDA.BIN` | 92,596 B (83,830 B for the 832 image: +8,766 B) |
| `_end` | 0x27150 (< 0x70000, the linker ASSERT) |
| boot ROM `_end` | 0x1040 (< 0x1400) |
| L2 `fwboot` `STACK low` | 0x1950 (1712 B used); `STACKHW` 0x1950; 0x550 above the 0x1400 floor |

The 20 largest frames (bytes, `make stack`): drivesounds_init 880, BootUploadLogo
880, BootUploadCopper 848, BootUploadBall 848, CD_Insert 160, ScanDirectory 128,
cd_read 128, cdaudio fill 128, HandleUI 112, LoadConfiguration 112,
CD_HandleCommand 112, ATA_ReadSectors 96, cue_wav 96, atapi_packet 96,
ATA_WriteSectors 80, SendFileV2 80, fpga_init 80, FileOpen 80, FindDrive 80,
bprintfl 80. (The deepest call chain, not the sum, is what the bench measures.)

## C library

Decision 12.12: the firmware links **newlib-nano 4.5** (`rv32imc/ilp32/libc_nano.a`
of the xPack 15.2.0-1 pin), not a port of lib832's `small_printf.c` /
`string.S`. Compile with `--specs=nano.specs` (selects newlib-nano's headers),
link with `-lc_nano -lgcc` last. Integer formatting only (no `%f`, no `%ll`).
No stdio FILE layer, no heap, no syscall stubs: a call that needs `_sbrk`,
`_write` and friends fails the link, on purpose.

| File | What it defines |
|---|---|
| `rvlibc.c`, `rvlibc.h` | `printf`, `vprintf`: `vsnprintf` into a static buffer of `RV_PRINTF_BUF` bytes, then the bytes one by one through `putchar`; `vprintf` returns `vsnprintf`'s value. `_malloc_r`, `_realloc_r`, `_free_r` as `NULL`/no-op stubs counting calls in `rv_libc_heap_calls` (newlib-nano's `vsnprintf` references them for the `asprintf` case, which a fixed buffer never takes; undefined they would pull `_sbrk`) |
| `uart.c` (Task 5) | `putchar`, `puts` |

`RV_PRINTF_BUF` is 320 and `RV_PRINTF_IRQ_BUF` 64 (audit below; both include the
terminating NUL, so a line of 319 / 63 bytes passes whole).

**Truncation.** A line that does not fit is cut to `size - 1` bytes (all of
them are sent), `rv_printf_truncations` is incremented once, and `vprintf`
still returns the length `vsnprintf` wanted. The audit finds no call site that
can reach the limit.

**Interrupt context.** `inthandler()` (`main.c`) calls `akiko_inthandler()`,
which `printf`s, so a `printf` can run between two bytes of another `printf`.
`vprintf` keeps a nesting count: a call that starts while another is in
progress formats into the second buffer (`RV_PRINTF_IRQ_BUF`). The legacy
interrupt path does not nest deeper (MIE is clear inside the handler); a third
level would share the second buffer. The count is read and written without a
lock: the handler runs to completion before the interrupted code continues, so
the only race is an interrupt between the read and the write, where the handler
sees depth 0, uses the first buffer and finishes before the interrupted call
has put anything in it. The 832 streamed `printf` byte by byte, so there the
interrupt's line also landed inside the interrupted one; here it lands at a
byte boundary of the interrupted line's *send* loop, not of its formatting
(see "Differences").

### printf buffer audit

Longest output of each `printf` call site that is compiled (found by running
the preprocessor over every `fw/ctrl_rv/*.c`, 2026-10-17: 136 sites, 138
with Task 11's two in `config.c` (`ConfigMessage`); a
raw `grep` also finds the commented-out ones). Conversions are taken at their
maximum: `%d`/`%ld` 11 bytes, `%u`/`%lu` 10, `%x`/`%X`/`%lX` 8, a width raises
the figure to the width. Each `%s` is bounded by its source:

| Site | `%s` bound |
|---|---|
| `fat.c:398`, `423`, `582`, `603` (`name` of `FileOpen`/`FindDirectory`) | 260: a CUE `FILE` name is at most 255 characters (`CUE_LINE_MAX 300`), `fat.h` `long_name[261]` |
| `menu.c:2968` (`file.long_name`) | 260 |
| `cdrom.c:291` | `shortname` 11, `cd_msg[24]` 23 |
| `cdrom.c:305` | `shortname` 11, `cdrom.unit.name` 40 |
| `fpga.c:124`, `127` | `kick1xfoundstr` 21, `applymemdetectionpatchstr` 46 |
| `%.8s`, `%.3s`, `%.11s` | the precision |
| `boot.c:260` (`printf("%s", str)`, `BootPrintEx`) | 80: the longest literal is 75, `s[40]`, `rtl_ver[45]` |
| `config.c:257` (`printf("%s", text)`, `ConfigMessage`, Task 11) | 40: `Converted 832 configuration MINMGAA4.CFG` (`msg[48]`), `(832 byte order)` 16 |

Per file, `line:bytes`:

| File | Sites | Longest output of each (line:bytes) |
|---|---|---|
| `akiko.c` | 2 | 17:32, 19:21 |
| `boot.c` | 2 | 260:80, 261:1 |
| `cdrom.c` | 17 | 291:50, 305:108, 334:17, 416:27, 485:18, 521:34, 684:17, 686:9, 688:19, 689:29, 690:34, 691:19, 692:33, 693:20, 694:5, 696:2, 777:84 |
| `config.c` | 13 | 65:21, 186:24, 257:40, 258:1, 326:36, 679:30, 680:30, 684:57, 687:14, 688:28, 694:27, 698:19, 701:22 (Task 11's lines) |
| `drivesounds.c` | 4 | 455:32, 477:50, 497:34, 500:28 |
| `fat.c` | 39 | 188:28, 192:4, 195:5, 198:5, 201:5, 205:7, 208:2, 295:21, 296:23, 297:22, 298:33, 299:24, 300:23, 301:25, 302:23, 398:274, 423:278, 461:33, 514:32, 534:35, 582:295, 603:283, 782:28, 789:33, 862:11, 1583:59, 1596:31, 1611:26, 1623:32, 1633:49, 1649:55, 1651:54, 1656:38, 1703:38, 1714:45, 1715:30, 1716:24, 1717:26, 1725:39 |
| `fdd.c` | 11 | 184:32, 191:12, 222:23, 252:17, 300:2, 303:4, 339:6, 377:29, 433:59, 438:23, 635:13 |
| `fpga.c` | 6 | 93:25, 94:1, 102:1, 121:2, 124:21, 127:46 |
| `hdd.c` | 13 | 471:29, 481:30, 763:20, 765:4, 767:9, 768:9, 861:87, 926:22, 927:21, 928:33, 929:37, 930:17, 935:34 |
| `main.c` | 2 | 277:29, 290:31 |
| `menu.c` | 7 | 2928:52, 2968:281, 2970:32, 2972:28, 2973:38, 2974:25, 2975:25 |
| `mmc.c` | 22 | 87:19, 102:25, 118:24, 123:36, 134:17, 143:29, 161:24, 166:34, 173:18, 180:29, 198:35, 204:25, 229:65, 241:52, 283:45, 296:34, 357:74, 371:61, 422:66, 446:64, 457:57, 532:46 |

Maximum 295 bytes (`fat.c:582`, a `FindDirectory` name of 260 characters; no
caller exists, so the real maximum is `menu.c:2968`, 281). 295 + NUL = 296,
rounded up to a multiple of 64: **`RV_PRINTF_BUF` = 320**.

Reachable from the interrupt handler: `akiko.c:17` (32 bytes) and `akiko.c:19`
(21 bytes); `c64keys_inthandler()` prints nothing. 32 + NUL = 33, rounded up to
64: **`RV_PRINTF_IRQ_BUF` = 64**. `lib_test` checks that exactly `size - 1`
bytes fit and one more is cut and counted, in both buffers.

### Return values

No call site uses the return value of `printf`, `sprintf`, `snprintf` or
`vprintf` (preprocessed sources, 2026-10-17: every call is an expression
statement). Verdict: the return-value differences below are not observable.

## Format parity (832 versus RV)

`test/gold/formats.txt` is every string literal of `fw/ctrl_rv/*.c` that
contains a `%` (135 lines, made by
`grep -ho '"[^"]*%[^"]*"' fw/ctrl_rv/*.c | LC_ALL=C sort -u`; the Makefile
checks it is current). Conversions used: `%d %u %x %X %s %ld %lu %lx`, widths
`%4d %02X %04X %04x %08X %08lX %08lx`, precisions `%.3s %.8s %.11s`; no `%c %p
%b %ll %h %z`. Three lines are inline-assembly templates (`"rol.w #8,%0\n\t"`,
`"swap %0\n\t"`, and since Task 18 `"mv %0, sp"` in `stackcheck.c`) and are
not formats (`NOT_FORMATS` in `fmtcheck.py`). `test/fmt_cases.h` has one or more
cases for every line (909 cases: 0, 1, -1, the type's maximum, bit 31 set,
empty/short/longer-than-precision strings, the longest a call site can pass;
the first case of a format has the zero/empty values, the last the extremes);
`test/gold/fmtcheck.py cover` fails when a line has none.

Every case runs as `sprintf` into a buffer and as `printf` into a captured
`putchar` stream (`test/fmt_run.h`), giving `FMT <n> S ret=.. buf=<hex> side=<hex>`
and `FMT <n> P ret=.. out=<hex>` (`side` = bytes that reached `putchar` during
the `sprintf`). Three producers, one case list:

| Producer | What it runs |
|---|---|
| `fmt_832` (host, `-m32`) | lib832's `small_printf.c`, unchanged, from `LIB832` (`-std=gnu17 -m32 -w -D__weak=` and renames so it links next to glibc), with a capturing `putchar` |
| `fmt_glibc` (host, native and `-m32`) | glibc's `sprintf`; `printf` is `rvlibc.c` over glibc's `vsnprintf` |
| `fmt_rv` (L1 bench, `sim/rv_l1/run.sh fmt`) | newlib-nano's `sprintf` and `rvlibc.c`, the target libc; digests, see gate 3 |

Gates (`make -C fw/ctrl_rv/test fmt`, part of the default `run`, and `run.sh fmt`):

1. `fmt_glibc` native == `-m32`;
2. `fmtcheck.py diff fmt_832.txt fmt_glibc_64.txt` == `test/gold/fmt_diff_expected.txt`
   exactly (413 lines: 278 case lines and 135 `RET` lines);
3. on the L1 bench, `fmt_rv.txt` == `fmtcheck.py digest fmt_glibc_64.txt`: all
   909 cases, one 32-bit FNV-1a digest per record instead of the text
   (`FMT <n> S h=<hex>`; the host has the full text). This makes glibc's text
   stand in for newlib-nano's in gate 2, as the host tests need. The full run
   is 30.5 M cycles (25 s on Verilator, many hours on iverilog), so for the
   iverilog X-check reference there is a **subset** build, `fmt_rv_subset`
   (`FMT_SUBSET=1`): the first and the last case of every run of equal format
   strings (272 cases, 544 records; `fmtcheck.py digest --subset`), 13.0 M cycles
   (about 38 minutes on iverilog). Gates: Verilator full run; Verilator
   subset run and iverilog subset run, which must be SAME under `run.sh compare`.

`fmtcheck.py` is the golden. It holds a model of lib832's `_printfcore` and of
ISO `printf` for these conversions, requires `fmt_832.txt` to equal the first
and the RV records (glibc) to equal the second for every case, and names each
difference by the smallest set of 832 deviations whose removal explains it (a
difference it cannot explain fails the check). Run `make -C fw/ctrl_rv/test`
after any change to a format string or `rvlibc.c`, and `run.sh fmt` after any
change to `rvlibc.c`, a format string or the library link (and in Task 20).

## Differences from fw/ctrl_832

Paul's ruling (2026-10-17, decision 12.12): **evident lib832 printf bugs are
not reproduced.** The RV firmware prints newlib's correct output, also where
that changes an OSD line; there is no bug emulation at any call site. A
non-bug difference may be matched at the call site.

| Tag in `fmt_diff_expected.txt` | lib832 | newlib-nano (RV) | Class | Where it shows |
|---|---|---|---|---|
| `UPPER` | `%x` prints digits upper case | lower case for `%x`, upper for `%X` | non-bug | matched at the 19 compiled call sites by `%x` -> `%X` (list below); the 5 formats still listed are in comments / dead code (`c1:`, `c2:`, `c3:`, `iDirectoryCluster:`, `New directory sector:`) |
| `ZERO` | an argument 0 prints `0`, ignoring width and zero fill (`%02X` of 0 -> `0`) | `00` | 832 printf bug | UART lines (`CD%d ATA %02X ...`, `CMD17 ... 0x%02X`, `partition type`, `drive status`, `cluster_mask %08lX`, `systimer`), OSD `  %dC %04X HDMI %08lX`, ` Hpos : %4d` |
| `SIGNW` | width counts the digits only: `%4d` of -12 -> `-  12` | `-12` right-aligned in 4: `  -12` | 832 printf bug | OSD ` Hpos : %4d \| Vpos : %4d` with negative positions |
| `SIGNUART` | `sprintf` sends the `-` of a negative `%d`/`%ld` to the UART (`putchar`), not into the buffer | the `-` is in the buffer | 832 printf bug | every OSD/`sprintf` line with a negative number (`Boot file size`, ` Hpos`, `INT %d`, ...): the sign now appears, and the UART no longer gets a stray `-` |
| `PREC` | `%.Ns` is not parsed: prints `Ns` literally and does not consume its argument, so later arguments shift | prints the first N characters | 832 printf bug | `\nHardfile 0: %.8s.%.3s` and the two other config lines (the 832 OSD shows `8s.3s`), UART `file: "%.8s.%.3s"`, `Inserting floppy: "%.11s"` |
| `RET` | the return value counts converted fields only (`%s` one short, literal text and the sign not counted); `snprintf` returns the bytes written | the length | 832 printf bug | not observable: no call site uses a return value (above) |

lib832 also ignores `-` and `+` flags, does not parse the width digit `9` or a
`0` after the first width digit, and has no `%ll`/`%h`/`%z`; none of these
occurs in a firmware format, so no case shows them.

Other rows:

| Row | 832 | RV |
|---|---|---|
| Order of an interrupt's `printf` inside another `printf` | streamed byte by byte while formatting | the interrupted line is formatted completely first; the interrupt's line is inserted at a byte boundary of its send loop. Both lines intact (`lib_test`) |
| Line longer than the buffer | no limit | cut to 319 bytes, `rv_printf_truncations` (audit: no site reaches it) |
| String and memory functions | lib832 `string.S` | newlib-nano; no observable difference at any call site (next table; "String semantics audit") |

I/O map (Task 5, plan 5.3): every register is at offset 0 of its 16-byte
window, CPU address `0xFFFFFFx0` (the 832's `0x0FFFFFxx` bases lose the `0x0`
and the big-endian byte lane `+2`/`+3`):

| Register | 832 | RV |
|---|---|---|
| SPI `HW_SPI` base, DATA / CS / SPEED | `0x0FFFFFE0`; +3 / +7 / +11 | `0xFFFFFFE0`; +0 / +4 / +8 (`HW_SPI_DATA 0`, `HW_SPI_CS 4`, `HW_SPI_SPEED 8`) |
| UART TX | `RS232(x)`: byte store to `0x0FFFFFF3` | `UART_TX`, byte store to `0xFFFFFFF0`; `RS232(x)` is `(UART_TX=(x))`. Write only |
| `uart.h` | `UARTBASE`, `HW_UART`, `REG_UART_RXINT`, `REG_UART_TXREADY`, `getserial` | removed (cfide never acks a read of `0xFFFFFFF0`; nothing used them) |
| `puts` (`uart.c`) | reads the string as 32-bit words, bytes by `>> 24` (BE only; misaligned for an unaligned string) | byte loop; still no newline, still returns the byte count |
| `TIMER` / `PLATFORM` / `AUDIO` | `0x0FFFFFD2` / `0x0FFFFFC2` / `0x0FFFFFB3` | `0xFFFFFFD0` / `0xFFFFFFC0` / `0xFFFFFFB0` (16, 16, 8 bit) |
| Keyboard | base `0x0FFFFF90`; words +2/+6/+0xA/+0xE, `REG_KEYBOARD_OUT` +2 | `0xFFFFFF90`; words +0/+4/+8/+0xC, `REG_KEYBOARD_OUT` +0 |
| Akiko | base `0x0FFFFF80`; ADDR +2, DATA +6 | `0xFFFFFF80`; ADDR +0, DATA +4 |
| RTC | base `0x0FFFFF72` | `0xFFFFFF70` (offsets 0/4/8/0xC as before) |
| I2C / `VIDEOSCALE` / `FPGA_TEMP_RAW` | `0x0FFFFF60` / `0x0FFFFF50` / `0x0FFFFF40` | `0xFFFFFF60` / `0xFFFFFF50` / `0xFFFFFF40` |
| `hardware.h` | no include guard | `HARDWARE_H` guard (the host test includes `uart.c` after it) |

`test/hwmap_test.c` asserts address and access width of every register macro
(real macros: it undefines `HOSTTEST`), the CS / SPEED values, the order of
`SPI()`, the real `RS232()` expansion, and `puts` over a UART store at offsets
0..3 of an aligned buffer.

Call-site edits to the copied `fw/ctrl_rv/*.c` made by Task 3 (everything else
is verbatim):

| File:line | 832 | RV | Why |
|---|---|---|---|
| `akiko.c:17,19`, `config.c:684`, `drivesounds.c:477`, `fat.c:782,789,1649,1651`, `main.c:176`, `menu.c:1595,2663,2665,3042,3044,3046,3048,3050,3052,3054` | `%x`, `%04x`, `%08lx`, `%lx` | `%X`, `%04X`, `%08lX`, `%lX` | `UPPER`: keeps the UART/OSD text identical |
| `boot.c:260` | `printf(str)` | `printf("%s", str)` | `str` is data (a file name, `rtl_ver`): a `%` in it would be taken for a conversion with garbage arguments, and the two libraries differ on that. Identical for every string without `%` |

### gcc 15 and gnu23 compile fixes (Task 4)

Decision 12.12: the tree is C gnu23 (`f()` means `f(void)`; `bool`, `true`,
`false` are keywords, `true` == 1) and the code is fixed for it, not built
with `-std=gnu17`. Every edit is minimal; behaviour is the 832's. Found by
building the Task 3 tree (`make -C fw/ctrl_rv -k`: 23 distinct errors, all
covered below) plus the source rules of 12.12.

| File:line | 832 | RV | Why |
|---|---|---|---|
| `firmware.h:23-24` | `#define true -1`, `#define false 0` | removed | C23 keywords; audit below (no site observes -1) |
| `drivesounds.h:14-15` | `void drivesounds_enable();`, `void drivesounds_disable();` | `(int type)` | the definitions take `int`; gcc 15 rejects the calls (`main.c:229`, `menu.c:901,903,1961,1963`: too many arguments) and the conflicting definitions (`drivesounds.c:50,55`) |
| `menu.c:2989` | `void ShowError(char *message, unsigned char code)` | `void ShowError(void)` | conflicts with `menu.h`'s `ShowError()` (= `(void)` in C23); the only call (`main.c:364`) passes nothing and the body uses neither parameter. `menu.h` stays as written |
| `fat.c:472` | `int FindDirectoryByCluster(...)` | `unsigned long FindDirectoryByCluster(...)` | conflicts with `fat.h:126` (`unsigned long`), which its one caller (`fat.c:462`, a truth value) sees; same 32-bit value |
| `config.c:30` | `int CheckSum();` | `int CheckSum(char *adr,int size);` | the definition (`main.c:82`) takes parameters (rule of 12.12); `config.c` calls it only in comments |
| `config.c:41`, `config.c:50` | `int *p=(0xe00000 & 0x7fffff) ^ HOSTMAP_ADDR;`, `int *p=0 ^ HOSTMAP_ADDR;` | `(int *)(...)` | integer -> pointer is an error in gcc 15; same address |
| `boot.c:238` | `BootClearScreen(SCREEN_ADDRESS, ...)` | `BootClearScreen((unsigned short *)SCREEN_ADDRESS, ...)` | `boot.h:15` `SCREEN_ADDRESS` is an integer; same address |
| `audio.c:25`, `drivesounds.c:444` | `unsigned char *p=AUDIO_BUFFER;`, `char *buf=AUDIO_BUFFER;` | `(unsigned char *)`, `(char *)` cast | `hardware.h:40` `AUDIO_BUFFER` is an integer (its other users already cast); same address |
| `hdd.c:536` | `while(blk && (((lba+hdf[unit].offset)<0) \|\| (unit==0 && hdf[unit].type==HDF_FILE && lba==0))` | one `)` added at the end: `blk && (A \|\| B)` | a missing `)` that vbcc832 accepted (warning 59 "`)` expected" at line 519: it inserts the `)` before the `{`). The 832 assembly (vbcc832 with the 832 Makefile's flags on `fw/ctrl_832/hdd.c`) tests `blk` first and leaves the loop when it is 0 without evaluating A or B, i.e. `blk && (A \|\| B)`, not `(blk && A) \|\| B` (the other place where one `)` would parse) |
| `drivesounds.c:393`, `404`, `410`, `426` | `if ((drivesounds.enabled & DRIVESOUNDS_FLOPPY)` | `if ((drivesounds.enabled & DRIVESOUNDS_FLOPPY))` | the same missing `)` four times (the plan named the first; gcc's error at 380 hid the other three; vbcc832 warns 59 at 381, 392, 398, 414, and nowhere else in `fw/ctrl_832`): every placement means `(enabled & FLOPPY)` |
| `drivesounds.c:12`, `445` | `extern char _bss_end__;`, `buf-&_bss_end__` | `__bss_end` | link error: `_bss_end__` is the 832 linker's `__bss_end__` (vbcc prefixes `_`); `arch/firmware.ld` names the end of `.bss` `__bss_end` (= `_end`) |
| `akiko.c:25` | `__constructor(101.akiko)` | `__attribute__((constructor(102)))` | the 832 order ("Building", Constructors) |
| `c64keys.c:301` | `__constructor(101.c64keys)` | `__attribute__((constructor(103)))` | the 832 order |
| `akiko.c:3`, `c64keys.c:3`, `main.c:58` | `#include "interrupts.h"` | `#include "irq.h"` | `interrupts.c`/`.h` deleted; `arch/irq.c` replaces them (default handler at constructor priority 101; the 832's `intconstructor` was 100) |
| `main.c:266` | `void setstack();`, `#ifdef __GNUC__ void c_entry(void) #else __geta4 int main(void) #endif`, `setstack();` | `int main(void)` | crt0 calls `main` and has set `sp`; `__geta4` (defined empty for the 832) is not needed. `main.c` is 6 lines shorter from here on: the printf audit lines of `main.c` are listed with their current numbers above |

Checked and left alone:

- **Implicit `puts`** (in the plan's list): not an error. `config.c` calls it
  with newlib's `<stdio.h>` included, which declares `int puts(const char *)`,
  the signature of `uart.c`'s definition.
- **Other `f()` declarations:** each declaration with `()` was compared with
  its definition: all are right as `f(void)` or have no definition and are
  never called (`drivesounds_on`, `drivesounds_off`, `OsdKeyGet`,
  `OsdCoreName`, `getserial`); they stay as written. `menu.c:136`
  `void (*confirmfunc)()` holds only `void(void)` functions.
- **K&R definitions:** none (`-Wold-style-definition` over every `*.c`, once;
  the flag is not kept).
- **C23 keywords as identifiers** (`bool nullptr constexpr typeof
  static_assert thread_local alignas alignof`): none.

#### `true`/`false` audit

All 32 hits of `\btrue\b|\bfalse\b` in the copy (line numbers of the Task 3
tree; Task 4 does not move these lines). "Truth only": the value is used only
as a condition, so C23 `true` (1) behaves as the 832's -1 (0xFF in an
`unsigned char`). "Value kept" would be a site where -1 is observable (stored
and compared with `==`/`!=`, written to a config field, the SPI or the OSD, a
mask, arithmetic, sign extension) and would use a named -1 constant. **No
site is "value kept"**, so no such constant exists. The `menu.c` flags are
locals and statics of `HandleUI()`, read only as conditions (`if (x)`, `else
if (x)`, `&&`, `||`): `ctrl`/`lalt` at 472, 502, 553, 572; `lshift` at 481,
511, 532; `menu`, `select`, `up`, `down`, `left`, `right` at 605 and in the
menu states' `if`/`else if`; `plus` at 785, `minus` at 791. None is passed to
a function, copied elsewhere or used in arithmetic.

| File:line | Use | Verdict |
|---|---|---|
| `firmware.h:23` | `#define true -1` | removed (C23 keyword, `true` == 1) |
| `firmware.h:24` | `#define false 0` | removed (C23 keyword, `false` == 0) |
| `config.c:340` | `updatekickstart=true;` (`int` local) | truth only: never read (gcc: set but not used) |
| `config.c:430` | `updatekickstart=true;` | truth only: never read |
| `menu.c:124` | the word "true" in a help string | text, not code |
| `menu.c:126` | the word "true" in a help string | text, not code |
| `menu.c:411` | `static unsigned char ctrl = false;` | truth only |
| `menu.c:412` | `static unsigned char lalt = false;` | truth only |
| `menu.c:413` | `static unsigned char lshift = false;` | truth only |
| `menu.c:442` | `menu = false;` (`unsigned char` local) | truth only |
| `menu.c:443` | `select = false;` (`unsigned char` local) | truth only |
| `menu.c:444` | `up = false;` (`unsigned char` local) | truth only |
| `menu.c:445` | `down = false;` (`unsigned char` local) | truth only |
| `menu.c:446` | `left = false;` (`unsigned char` local) | truth only |
| `menu.c:447` | `right = false;` (`unsigned char` local) | truth only |
| `menu.c:448` | `plus = false;` (`unsigned char` local) | truth only |
| `menu.c:449` | `minus = false;` (`unsigned char` local) | truth only |
| `menu.c:454` | `ctrl = true;` | truth only |
| `menu.c:457` | `ctrl = false;` | truth only |
| `menu.c:460` | `lalt = true;` | truth only |
| `menu.c:463` | `lalt = false;` | truth only |
| `menu.c:466` | `lshift = true;` | truth only |
| `menu.c:469` | `lshift = false;` | truth only |
| `menu.c:499` | `plus = true;` | truth only |
| `menu.c:529` | `minus = true;` | truth only |
| `menu.c:581` | `menu = true;` | truth only |
| `menu.c:585` | `menu = true;` | truth only |
| `menu.c:589` | `select = true;` | truth only |
| `menu.c:592` | `up = true;` | truth only |
| `menu.c:595` | `down = true;` | truth only |
| `menu.c:598` | `left = true;` | truth only |
| `menu.c:601` | `right = true;` | truth only |

## Found by -Wextra (Task 7)

The tree builds `-Wall -Wextra -Werror` clean (`make -C fw/ctrl_rv clean all`).
Rule: the generated code does not change (checked against the Task 6 `.text`,
see the commit message). So the 120 `-Wall` warnings Task 4 left and the
ones `-Wextra` adds were fixed only by casts that spell out the conversion C already applies, `(void)`
and `__attribute__((unused))` for unused parameters/variables, removing dead
locals, braces/parentheses, `const` where a pointer is only read, and
`unsigned char` for `char` subscripts (the firmware is `-funsigned-char`, so
`char` already was unsigned). `%d`/`%X` arguments that are `long`/pointers got
casts to `int`/`unsigned int` (32 bits on RV32); no format string changed.
Line numbers elsewhere in this README that point into a changed file refer to
the Task 4 tree except where updated above.

The warnings below point at real defects (or at code that does not do what it
looks like). They are **left as they are**; Task 16 or a later task decides.
Where `-Werror` would stop the build, the warning is silenced for that one
function with a `#pragma GCC diagnostic push/ignored/pop` and a comment that
names this section; no global `-Wno-...`.

| File:line | What is wrong | Silenced by |
|---|---|---|
| `drivesounds.c:335-337` `pickstep()` | `count` is read in `while(count>maxactive)` before it is ever assigned: undefined behaviour (the 832 got whatever its stack held). When `count` happens to be `<= maxactive` the loop is skipped and no sound is stopped | pragma around the function (`-Wuninitialized`, `-Wmaybe-uninitialized`) |
| `fpga.c:138` `BootPrint()` | declared `char`, falls off the end without a return (the body is the `//return(1)` stub). The callers (`config.c`) ignore the value today; using it would be undefined behaviour | pragma around the function (`-Wreturn-type`) |
| `config.c:300,340,430` `LoadConfiguration()` | `updatekickstart` is set to `true` in two places and never read: whatever it was meant to trigger (a kickstart re-upload after a config change) does not happen | `__attribute__((unused))` on the variable |
| `drivesounds.c:150,222` | `b1`, `b2` (the 0x4000 bit of the audio cursor before and after a fill) are assigned and never used (a check on them was probably meant, or removed) | `__attribute__((unused))` |
| `atapi.c:666` `atapi_packet()` | parameter `limit` (the host's allocation length) is never used | `(void)limit` |
| `osd.c` `OsdColor(color)`, `ConfigScanlines(scanlines)`, `menu.c` `ErrorMessage(message, code)`, `hdd.c` `ATA_Recalibrate(.., unit)`, `ATA_Diagnostic(tfr)`, `ATA_Initialize(.., unit)`, `HandleHDD(c1, c2)`, `fdd.c` `HandleFDD(.., c3, ..)`, `menu.c` `VolumeBar(vol, ..)`, `fpga.c` `BootPrint(text)`, `cdrom.c` `cd_lookup_read`/`cd_cue_open` (`ctx`) | stubs or parameters the body ignores (FIXME/TODO in the 832 source) | `(void)param` |
| `c64keys.c:47` `LAYER(x,y)` | the macro masks `x&0xffff` without parenthesising `x`; for `LAYER(QUAL_BLOCKLAYER\|RK_RAmiga, ..)` it computes `QUAL_BLOCKLAYER \| (RK_RAmiga&0xffff)`. Same value as long as every qualifier is `< 0x10000` (they are: `QUAL_*` are `<= 0x8000`), wrong for a larger one | macro parenthesised (`((x)&0xffff)`); the table values are unchanged |
| `fdd.c:85,88,102` | `11 - sector >> 1 & 0x55` parses as `((11-sector)>>1)&0x55`; if the intent was `11 - (sector>>1&0x55)` this is a bug in the MFM checksum. It is the 832's reading (that is what vbcc832 compiled), so it is kept | parentheses spell out the existing parse |
| `hdd.c:897` | **Cosmetic, not a defect.** `lba & (-1 << n)`: shift of a negative value (undefined in C before C23, well defined here because gcc shifts two's complement) | `(int)(~0U << n)`, same bits |
| `config.c:620`, `drivesounds.c:378` | **Cosmetic, not a defect.** `if (romsize=Upload...)` and `while(dse=...)` assign in a condition: intended, but easy to misread | extra parentheses |
| `fpga.c:148` `ClearMemory()` | `c2` (the "disk present" byte of the `0x10` track-read status) is read from the SPI and never used; the read itself must stay (it clocks the byte) | `__attribute__((unused))` |
| `fpga.c:207` `fpga_init()` | `time = GetTimer(0)` is set and never read (nothing uses it) | `__attribute__((unused))` |
| `main.c:139` `inthandler()` | `ints = GetInterrupts()` is never read; the read is the point (it clears the interrupt sources, `arch/irq.h`), so it stays | `__attribute__((unused))` |
| `menu.c:2763` | `static char template[4] = " of "` holds no NUL (4 chars): fine while only `sizeof` and byte compares are used, never as a string | `__attribute__((nonstring))` |
| `menu.c:2590` | the `case MENU_ROMFILE_SELECTED:` falls into `..._SELECTED1:` ("no break intended" in the 832 source) | `__attribute__((fallthrough))` |
| `hdd.c:779-863` `GetHardfileGeometry`, `drivesounds.c:141-307` `drivesounds_render` | `-Wmaybe-uninitialized` on `cyl/head/spt` (set in the first pass of loops that always run, `sptt[0] >= 0`) and `srcs/srcs2/srcs3` (read only when the matching `src` pointer is set, which also sets them): false positives, not bugs | pragma around the function |
| `fat.c`, `mmc.c` | `#pragma section_code_init` / `section_no_code_init` (the 832 linker's RAM-function sections) are unknown to gcc and do nothing here: `RAMFUNC` code stays in `.text` | file-level `#pragma GCC diagnostic ignored "-Wunknown-pragmas"` before the first one |
| `fat.c:121` | `if (!MMC_Read(..)) return(0);` was followed by two tab-indented lines that looked guarded (`-Wmisleading-indentation`); they are not | re-indented with spaces |

## Byte order (Task 9)

Plan 5.2 "flips" and items 7/8 for `fat.c`. `swap.h` has the helpers of the
Global Constraints, `static inline`: `le16`/`le32` (a field that is
little-endian in memory: the identity here, a swap on a big-endian CPU),
`be16`/`be32` (big-endian in memory: a swap here), `rd_le16`, `rd_le32`,
`rd_be16`, `rd_be32` (read byte by byte, any alignment), `wr_be16`, `wr_be32`.
`SwapBB`/`SwapBBBB`/`SwapWW` (`swap.c`) stay for a caller that really means
"swap"; after Task 9 that is only `SwapPartitionBytes` (`SwapBBBB`). A
converted line says what the disk format is ("little-endian on disk").

| File:line | 832 | RV | Why |
|---|---|---|---|
| `fat.c:388` | `file->size = SwapBBBB(pEntry->FileSize); // for 68000` | `le32(pEntry->FileSize)` | `FileSize` is little-endian on disk |
| `fat.c:391`, `460`, `511`, `581` | `SwapBB(pEntry->StartCluster) + (fat32 ? (SwapBB(pEntry->HighCluster) & 0x0FFF) << 16 : 0)` | `le16(..)` for both | `StartCluster`/`HighCluster` little-endian on disk |
| `fat.c:808-810` (`ScanDirectory`) | the in-place `SwapBB`/`SwapBB`/`SwapBBBB` of each non-LFN entry of the sector | `le16`/`le16`/`le32` | `DirEntry[]` keeps native values (`menu.c:1257,1340,1374-1377` use them as such) |
| `fat.c:1366` (`GetFATLink`), `1405` (`FileNextSector`), `1460`, `1466` (`FileSeek`) | `SwapBBBB(fat_buffer.fat32[i])`, `SwapBB(fat_buffer.fat16[i])` | `le32`, `le16` | FAT links are little-endian on disk |
| `fat.c:1616` (`FileCreate`) | `fat_buffer.fat32[..] = 0xFFFFFF0F; // FAT32 EOC change for 68000!` | `= le32(0x0FFFFFFF)` | the 832 stored the byte-swapped literal; on LE that would be cluster `0x0FFFFF0F` (`fat_eoc32` mutant: `fsck.fat` "Cluster .. out of range") |
| `fat.c:1642-1646` | `SwapBB(FILEDATE(2009, 9, 1))`, `SwapBB(FILETIME(0, 0, 0))` | `le16(..)` | dates and times are little-endian on disk |
| `fat.c:1647-1648` | `(unsigned short)SwapBB(cluster)`, `(unsigned short)SwapBB(cluster >> 16)` | `le16((unsigned short)cluster)`, `le16((unsigned short)(cluster >> 16))` | same |
| `fat.c:1650`, `1721` | `pEntry->FileSize = SwapBBBB(file->size); // for 68000` | `le32(file->size)` | same |
| `fat.c:1712`, `1715` (`UpdateEntry`) | `SwapBBBB(pEntry->FileSize)` | `le32(..)`; the `%lu` argument cast `(unsigned long)` | same; the cast because `le32` is `uint32_t` (`unsigned int` on the host ABIs) |
| `fat.c:1651` | `printf(".. %lX\n",pEntry->FileSize)` | `(unsigned long)pEntry->FileSize` | `FileSize` is `uint32_t` now (row `fat.h` below); format and output unchanged |
| `fat.c:146`, `154` (`FindDrive`) | `switch(mbr->Signature)`: `case 0x55aa:` swaps the partition entries, falls through to `case 0xaa55:` | unchanged, comments only | on LE the signature bytes `55 AA` read `0xaa55`: no swap; `SwapPartitionBytes` keeps `SwapBBBB` (a real swap, BE host only). `fat_mbr_sig` mutant (labels exchanged): `FindDrive` fails |
| `fat.c:139` | `memcpy(&partitions[0],&mbr->Partition[0],..)` x4 | unchanged, comment | item 8: `Partition[]` is at 446 (2 mod 4); the entries are copied (newlib `memcpy`, a call: `-fno-builtin`) into the aligned `partitions[]`, never read in place. The disassembly of `FindDrive` has the four `jal memcpy` from `sector_buffer+0x1be..0x1ee` and only aligned `lhu`/`lw` from `sector_buffer` (`lhu 22`, `lhu 44`, `lw 36`, `lhu 510`) |
| `fat.c:74`, `fat.h:85` | `unsigned char sector_buffer[1024];` | `__attribute__((aligned(4)))` (definition and `extern`) | item 7: `DIRENTRY`, `MasterBootRecord` (and `configTYPE`, `config.c:324`, Task 11) are overlaid on it; gcc merges the BPB byte reads into `lw 36(s0)` (`fat_size`), which needs the 4-aligned base |
| `fat.c:79` | `FATBUFFER fat_buffer;` | `__attribute__((aligned(4)))` | item 7 |
| `fat.h:31-32`, `72`, `77` | `unsigned long startlba, sectors`, `unsigned long FileSize`, `unsigned long fat32[128]` | `uint32_t` | on-disk layouts: 32 bits on every ABI. Same type on RV32 (`uint32_t` is `unsigned long` there: `__UINT32_TYPE__`), so the target code does not change by it; on the LP64 host leg `unsigned long` made `PartitionEntry` 24 and `DIRENTRY` 40 bytes (`fat_test` RED). `_Static_assert`s at the end of `fat.h`: 16, 512, 32, 512 bytes |
| `fat.h:5` | (blank line) | `#include <stdint.h>` | for `uint32_t` |
| `swap.c:20`, `30`, `37` | `int result` | `unsigned long result` / `unsigned int result` | an `int` with bit 31 set was sign-extended into a 64-bit `unsigned long` (LP64: `SwapBBBB(0xFF)` = `0xffffffffff000000`, `swap_test` RED against `fw/ctrl_832/swap.c`); the same bits on RV32. `swap.c` now includes `swap.h` |

Not changed (832 parity, seen by `fat_test`): `FileCreate` allocates exactly
one cluster and does not update the FAT32 FSInfo free-cluster count
(`fsck.fat -n` then reports "Free cluster summary wrong" and exits 1 on a card
whose count is known; the test's FAT32 image has it "unknown", 0xFFFFFFFF);
`FileReadEx` with a buffer does not advance `pBuffer` from one cluster to the
next (every caller passes one sector or `NULL`). Task 9 kept the line count
of `fat.c` (each edit on its own line), so the `fat.c` line numbers elsewhere
in this README still hold.

## Config file byte order (Task 11)

Plan 5.2 item 5 and item 7 (`config.c:324`), decision 12.4. The struct is
unchanged: `configTYPE`, 212 bytes, `CONFIG_VERSION 4`, id `MNMGCFGA`. The
RISC-V firmware reads and writes it as it is in memory, little-endian; the
832 wrote it big-endian. Its only multi-byte fields are seven 32-bit ones:
`version` @8, `kickdir` @132, `extromdir` @136, `hdfdir[0..3]` @140, 144,
148, 152 (`cfgswap.h` `CFG_OFF_*`, checked by `_Static_assert` in `config.c`
against `offsetof`, with `sizeof == 212`, which replaces the negative-array
typedef). The byte order of a file is told by `version`: 1..4 read
little-endian = RV, 1..4 read big-endian = 832.

| What | 832 | RV |
|---|---|---|
| file names (`SetConfigurationFilename`) | `MINMGAA CFG`, `MINMGAA%dCFG` | `MINMGAR CFG`, `MINMGAR%dCFG` (`MINMGAR.CFG`, `MINMGAR1.CFG` ..) |
| `config.h` `version`, `kickdir`, `extromdir`, `hdfdir[4]` | `unsigned long` | `uint32_t`: the file layout on every ABI. The same type on RV32 (`__UINT32_TYPE__` is `unsigned long`): the stripped code of `cdrom.o`, `hdd.o`, `fpga.o`, `main.o` is the same as before; on the LP64 host leg `unsigned long` made the struct 240 bytes |
| `cfgswap.c`, `cfgswap.h` (new; pure C, shared with `tools/cfgconv`) | | `cfg_order(buf, len)` -> `CFG_RV` / `CFG_832` / `CFG_BAD` (length 156..212, id, version); `cfg_swap(buf)` swaps the seven fields in place, byte by byte |
| `LoadConfiguration` | reads `MINMGAA..` | reads `MINMGAR..`. A file in 832 order under that name takes the existing `version > CONFIG_VERSION` path ("Wrong configuration file format!") plus "(832 byte order)": the defaults. **First boot:** no `MINMGAR..` file but the slot's `MINMGAA..` file: it is read, `cfg_order == CFG_832` -> `cfg_swap` in the sector buffer, then the usual checks (old versions included); used, and saved under the RV name (`SaveConfiguration` creates it), "Converted 832 configuration MINMGAA.CFG". Any other order under the 832 name: the defaults. The 832 file is never written (no `FileWrite`/`UpdateEntry` on it) |
| `ConfigurationExists` | the file | the RV file, or else the slot's 832 file (so that the Load page offers a slot that only the 832 firmware saved; loading it converts it) |
| the two new messages | | `ConfigMessage`: `BootPrint` (disabled, as on the 832) and the UART |

Tools and tests: `tools/cfgconv` (`cfgconv --to-rv|--to-832|--check`, its
`README.md`); `test/config_test` with `test/gold/mkcfg832.py`, an independent
generator of 832 files (`test/README.md`); L2 `run.sh fwboot_cfg`
(`sim/host_bridge/README.md`). `fwboot`'s milestones now name both files
(`file "MINMGAR CFG" not found`, `file "MINMGAA CFG" not found`). No change
in `fat.c` or `mmc.c`.

## Hard disk byte order (Task 12)

Plan 5.2 items 1, 2 and 7 (`hdd.c` struct overlays). The Amiga reads a
disk's RigidDiskBlock and PartitionBlock as big-endian longs and IDENTIFY
DEVICE as ATA words; the 832, big-endian, produced both by storing native
values. The RV firmware stores the same bytes:

| File:line | 832 | RV | Why |
|---|---|---|---|
| `hdd_internal.h` (`RigidDiskBlock`, `DosEnvec`, `PartitionBlock`) | `unsigned long` / `long` fields | `uint32_t` / `int32_t`; `#include <stdint.h>`; `_Static_assert` 256 bytes each (SummedLongs 0x40) | on-disk layouts: 32 bits on every ABI (on the LP64 host leg `unsigned long` made the RDSK 8-byte longs, `hdd_test` RED). The same types on RV32 |
| `hdd.c:65`-`74` (`RDBChecksum`) | `count=p[1]`, `result+=p[c2]` (`long`), `p[2]=-result` | `count=be32(p[1])`, `result+=be32(p[c2])` (`uint32_t`), `p[2]=be32(-result)`; the argument `uint32_t *` | the checksum is over big-endian longs; `uint32_t` wraps as the 832's `long` did, without signed overflow (UBSan) |
| `hdd.c:96`-`130` (`FakeRDB`, RDSK) | every long assigned its value | every long `be32(value)`; `0xffffffff` and `0` as they are (the same in either order); `Park`, `WritePreComp`, `ReducedWrite` copy the big-endian `Cylinders`; `HiCylinder` = `be32(cylinders-1)`, `CylBlocks` = `be32(heads*sectors)` from `hdf[]` (the 832 computed them from the fields it had just stored) | big-endian longs; the strings unchanged |
| `hdd.c:138`-`161` (`FakeRDB`, PART) | the same | the same | the same |
| `hdd.c:246`-`254` (`IdentifyDevice`) | (none) | after the `switch`: `pBuffer[i] = be16(pBuffer[i])` for words 10..19 (serial) and 23..46 (firmware, model incl. the file name copy) | ATA strings have the first character in bits 15:8. The 832's `memcpy` put it there (big-endian); on RV it lands in bits 7:0, so each string word is swapped after all copies (also after `p[10]+=partition`). `ATA_IdentifyDevice` sends every word low byte first from its value: the numeric words (0, 1, 3, 6, 47, 53-58) need nothing. The byte stream is the 832's (correction of plan 5.2 item 2, which said "swap every word") |
| `hdd.c:543`-`544` (`ATA_ReadSectors`, unit 0, plain `HDF_FILE`, block 0) | `rdb_ChkSum = rdb_ChkSum + rdb_Flags - 0x12; rdb_Flags = 0x12` | `be32(be32(rdb_ChkSum) + be32(rdb_Flags) - 0x12)`, `be32(0x12)` | the HDF's own RDB: big-endian longs read from the file |
| `hdd.c:38` | | `#include "swap.h"` | |

No other change in `hdd.c` (`hdd.c` grew by 15 lines: line numbers after 64
moved). `test/hdd_test` (`test/README.md`) checks each row against
`test/gold/rdb.py` (the RDSK and PART blocks from the field offsets of
`devices/hardblocks.h`, the checksum computed over the finished block) and
`test/gold/identify.py` (the IDENTIFY stream from the ATA word and string
rules), not against `fw/ctrl_832`'s code: compiled for this little-endian
host, the 832 source would not give the 832's bytes for exactly these fields.

Found while testing, unchanged (832 parity):

- `hdd.c:536`, the Task 4 parenthesis: `blk && (A || B)` and the other parse,
  `(blk && A) || B`, behave the same for every valid CHS address. They differ
  only when `blk` is 0 and B holds (`unit == 0`, plain `HDF_FILE`, `lba ==
  0`), but `lba` is 0 only on the loop's first pass, where `blk` is the chunk
  size (>= 1). With sector number 0 in the task file (invalid, `lba` -1) the
  other parse would run on with `blk` negative. So no host test can tell the
  two apart; Task 4's reading rests on the 832 assembly. `hdd_test` covers the
  line with READ MULTIPLE chunks that cross from the synthesised cylinder into
  the file (mutants `hdd_boundary`, `hdd_boundary_blk`).
- The RDB patch is for unit 0 only (`unit==0 && ... lba==0`): the same HDF on
  unit 1 is sent with its own `rdb_Flags` (`hdd_test` "unit 1 lba 0").
- A write into the synthesised first cylinder (`lba < 0` after the offset)
  drops those blocks and sets `ERROR_HDD` ("Write to auto-generated RDB!"),
  but the status still reports success (END | IRQ).
- `ATA_ReadSectors`/`ATA_WriteSectors` always decode CHS: the LBA bit of the
  drive/head register is ignored. IDENTIFY offers no LBA mode (word 49 is 0),
  so the Amiga's driver uses CHS.
- `IdentifyDevice`, `HDF_CARD` case: `pBuffer[23] += type - HDF_CARD` is
  overwritten by the `memcpy` of the firmware revision on the next line (dead).
- `HandleHDD` calls `trap2()` (prints `T` on the UART) after any command whose
  task file holds cylinder 444, head 2, sector 61: a debugging leftover.

## Floppy (Task 13)

`fdd.c` is unchanged by the port (the audit finds nothing to change). Its
only differences from `fw/ctrl_832/fdd.c` are Task 7's: the parentheses in
`SendSector` (`fdd.c:88`, `:102`, `11 - sector >> 1 & 0x55` parses as
`((11 - sector) >> 1) & 0x55` either way) and `(void)c3` in `HandleFDD`.
`test/fdd_test` shows the two sources give the same SPI traces (below).

### Multi-byte accesses

| File:line | Access | Verdict |
|---|---|---|
| `fdd.c:197`, `:291`, `:624`, `:652` | `drive->cache[drive->track]`, an `unsigned long` load | native value: `InsertFloppy` (`menu.c:2936`) stores `file.cluster` there, `fdd.c` hands it back to `fat.c`; never on disk or on the wire. Aligned struct member |
| `fdd.c:197`-`200`, `:204`-`206`, `:291`-`292`, `:296`-`297`, `:624`-`625`, `:652`-`653` | `file.cluster`, `file.sector`, `drive->cluster_offset` (`unsigned long`) | native values for `fat.c` (`file.sector = track * 11 [+ sector]`): no byte order. Aligned |
| `fdd.c:440`-`441` | `*pTrack = c2; *pSector = c3;` (`unsigned int *`) | `WriteTrack`'s locals: aligned, native |
| `fdd.c:212`-`215`, `:234`-`237`, `:329`, `:516` | `dsksync = SPI(0) << 8 \| SPI(0)`, `dsklen`, `n = ((c3 & 0x3F) << 8) + c4` | `unsigned int` arithmetic on the bytes in the order paula_floppy sends them (high byte first): values, not memory |
| `fdd.c:131`-`161` (`SendSector`), `:548`-`587` (`GetData`) | the sector data, `*p++` over `sector_buffer` | bytes. The Amiga's big-endian data longs exist only on the wire: byte k of each long is sent first / stored first, so `sector_buffer` holds the ADF's bytes in file order on either CPU and the checksums are per byte position (`checksum[0..3]`) |
| everything else | `checksum[]`, `drive->track`/`track_prev`/`status`/`tracks`/`motor`, `df[].status`, the `c1`..`c4` bytes | `unsigned char` |

No `swap.h` helper is needed. `drive->track_prev = -1` (`fdd.c:632`) stores
0xFF into an `unsigned char`, as on the 832. `fdd.h` still declares
`SectorGapToFpga` and `SectorHeaderToFpga`, which no file defines (the plan's
`SectorToFpga`/`SectorGapToFpga` are `SendSector`/`SendGap`): dead
declarations, kept (832 parity).

### SPIN

The 28 `SPIN`s of `fdd.c` (`GetHeader` lines 381-470: 14, `GetData` lines
520-581: 14; the historic ADF-write workaround) stay commented out, the same
28 lines as in the 832 tree. `make -C fw/ctrl_rv/test run-fdd_test` checks it
(`out/fdd/spin.ok`: every line with `SPIN` is `// SPIN;`, and the count equals
the 832's).

### Timing items for Phase 4 (plan 7.1 items 6 and 7)

The host tests check the protocol (what is sent and read, never past the
FIFO count), not the rates; both items stay Phase 4's (L3 co-simulation with
the real `paula_floppy` / `paula_floppy_fifo`).

- Item 6, track read, FIFO not starved: `ReadTrack` -> `SendSector`
  (1088 bytes per sector) / `SendGap` (700 bytes after sector 10), one
  `FileRead` (an SD block read) and one `CD_AudioPoll` per sector, called
  from `HandleFDD` in the main loop. `paula_floppy` asks (`CMD_RDTRK`,
  `spi_tx_data_0` bit 0 = `trackrd & ~fifo_cnt[10]`) while its FIFO holds
  fewer than 1024 words; `ReadTrack` then sends a whole sector (544 words,
  +350 of gap), so it does not overrun the 2048-word FIFO. Paula's DMA drains
  a word per ~32 us; the latency to watch is the main loop between two
  `HandleFDD` calls and the SD read + CD refill inside the loop.
- Item 7, track write, FIFO not overrun: `WriteTrack` -> `FindSync`,
  `GetHeader` (25 words), `GetData` (516 words), then `FileWrite` (an SD
  block write with its busy time) per sector. `paula_floppy` requests the
  Amiga's write DMA only while the FIFO is not full (`dmal`/`dmas`,
  `~fifo_full`, `paula_floppy.v:733`-`736`), so a slow host stretches the
  write rather than losing words; Phase 4 measures how long the FIFO stays
  full (the plan's "FIFO full && Amiga writing" monitor) over a whole track
  (~6300 words, ~200 ms at the disk rate).

### Tests

`test/fdd_test` (`test/README.md`) runs `fdd.c` and, in the same binary, the
832's `fdd.c` compiled for the host with the same mock, against
`test/gold/mfm.py`, an Amiga MFM track encoder written from the track
format. `ReadTrack`'s stream of tracks 0 (cylinder 0 side 0) and 159
(cylinder 79 side 1) is equal in all three; the golden streams are committed
as `test/gold/mfm_c00_s0.hex` and `test/gold/mfm_c79_s1.hex` (hex, 32 bytes per
line, `xxd -r -p` gives the 12668 bytes) for Phase 4's L3 data check. The
Copy Lock workaround (`fdd.c:242`-`244`, DSKSYNC 0x0000, 0x8914, 0xA144 sent as
0x4489) is reached by a mock `paula_floppy` that reports those values in the
DSKSYNC bytes (2-3) of its status frames.

## Amiga-facing data (Task 14)

Plan 5.2 items 3, 4 and 6 and the "new" rows of the exec-3 audit list: the
remaining data the Amiga reads (or a file made for it holds) in big-endian
order, and the dead firmware-upgrade declarations.

| File:line | 832 | RV | Why |
|---|---|---|---|
| `boot.c:196`-`204` (`BootUploadCopper`, no `MINIMIG.COP` on the card) | `*p++=0x00e0; *p++=0x0008; ...` (12 words) | `*p++=be16(0x00e0); ...` | the copper reads big-endian words: the list is `00 E0 00 08 00 E2 00 00 00 E4 00 08 00 E6 50 00 01 00 A2 00 FF FF FF FE` in Amiga memory, as the 832 left it. With the file: `RARead`, bytes, unchanged |
| `drivesounds.c:467`, `469`, `484`, `486` (`drivesounds_init`) | `id=*(long *)buf; size=*(long *)buf;` | `rd_be32(buf)` | `DRIVESND` header longs are big-endian (`sw/mkdrivesounds/mkdrivesounds.c`) and at `2 mod 4` (the file sits at `AUDIO_BUFFER - 212098`, `0x3C37E`; the sound sizes are even, not multiples of 4): a word load there traps on VexRiscv (mcause 4) |
| `drivesounds.c:476`-`481` | the samples used in place (big-endian = native) | each sound's samples converted once, in place: `samples[i]=(short)rd_be16(&samples[i])` | the render loops read them as `short`; the buffer is the firmware's own (in front of the ring), loaded anew by every `drivesounds_init` |
| `drivesounds.c:239`-`242`, `262`-`264`, `281`-`282` (`drivesounds_render`, 3, 2 and 1 sources) | `int c=*src++; ...; c=((c&255)<<8) \| ((c>>8)&255); c=c*0x10001; *buf++=c;` | `unsigned int c=*src++; ...; c=(c&0xffff)*0x10001; *buf++=c;` | the ring bytes are the 832's: the low 16 bits of the sum, little-endian, both channels (`lo hi lo hi`). The 832 swapped the 16 bits and stored the long big-endian; the little-endian store does the same without the swap. `c*0x10001` stays; the `& 0xffff` is the swap's masking, which the multiply needs (a negative sum: `-1 * 0x10001` is `0xfffeffff`; mutant `ds_nomask`). Unsigned: the 832's `int` product overflows for every sum with bit 15 set (signed overflow: UBSan stops it on the host) |
| `main.c:82`-`92` (`CheckSum`, the kickstart's `checksum_pre` the menu shows) | `int *ptr`, `sum+=*ptr++` | `sum+=rd_be32(adr)`, `unsigned int` | the 832 summed big-endian words; the shown value is now the 832's for the same file. Byte-wise (any alignment), unsigned (wraps without signed overflow) |
| `hexdump.c:14` | `unsigned int t=*p2++` | `rd_be32(p)` | prints 32-bit words in memory order, the 832's (big-endian) view, at any alignment. No caller today (`hexdump.h` is included by `fat.c`, `menu.c`, `config.c`) |
| `firmware.h` | `romTYPE`, `UPGRADE`, `NVCONFIG`, `NVCONFIG_SPIMODE`, `SPIMODE_NORMAL`, `SPIMODE_FAST`, `CalculateCRC32`, `CheckFirmware`, `WriteFirmware`, `SetSPIMode`, `GetSPIMode` | file deleted; its `#include` became `#include "swap.h"` in `main.c:53` and a comment line in `config.c:11` and `menu.c:37` (their line numbers stay) | plan 5.2 item 6: declared, never defined or called (`grep`: only `mmc.c`'s commented-out `GetSPIMode() == SPIMODE_FAST` lines and `//#include "firmware.h"`, left as they are). Nothing in it was used; `SPIMODE_*` belong to the same dead upgrade path |
| `hardware.h` (`HOSTTEST` block) | | `AUDIO_BUFFER` is `hosttest_audio_buffer()` | host tests only (the mock's RAM, `test/mock_hw.c`); the target build drops the block. `hwmap_test` checks the real value, `0x70000` |

The target image is otherwise unchanged by the task's test hooks; `make -C
fw/ctrl_rv check` passes. `RV32OSDA.BIN` is 92,436 B, `__bss_end` `0x270AC`:
room for 298,836 B of drive sounds in front of `AUDIO_BUFFER`.

### Seen by `drivesounds_test`, unchanged (832 parity)

- `pickstep()`'s `count` is read uninitialised ("Found by -Wextra"). The
  test's sequences reach `pickstep` (floppy `STEP` and `HDDSTEP` events) only
  with at most `maxactive` step sounds of that kind playing, which
  `gold/drivesounds.py` asserts at every pick: there the result does not
  depend on `count` (if the loop runs, it finds `count <= maxactive` and stops
  nothing), so the test is deterministic and does not reach the case where
  the stack garbage decides which sound is cut.
- Three voices: every playing sound after the third (by index) is switched
  off, its cursor kept; a step sound picked again later resumes there.
- `drivesounds.sounds[dse->type].cursor=0` runs for every event before its
  case: a `STEP`/`HDDSTEP` event rewinds sound `STEP`/`HDDSTEP` even when
  another one is picked or the `HDDSTEP` is dropped (three already playing),
  and a `MOTORSTART` with the floppy sounds off rewinds a playing
  `MOTORSTART`.
- `playing` is never set: `audio_start()` is written on every render that
  ends in the second half of the ring.
- `drivesounds_init()` resets the queue and the player, not the sounds'
  `active`/`chain`/`cursor`, nor `timestamp`/`silence`.
- Task 4's four parentheses (`(drivesounds.enabled & DRIVESOUNDS_FLOPPY)` in
  the `MOTORSTART`, `MOTORSTOP`, `STEP` and `default` cases): each is reached
  with the floppy sounds on and off (mutants `ds_floppy_start`, `_stop`,
  `_step`, `_default`: the condition always true).

### Audit: multi-byte accesses to Amiga memory and file data

Every `(short *)`, `(long *)`, `(int *)`, `unsigned short *` (and `unsigned
int *`, `unsigned long *`, `uint16_t *`, `uint32_t *`) access in `fw/ctrl_rv`,
listed by (from the repository root)

```sh
grep -nE '\((unsigned )?(short|long|int) *\*\)|unsigned (short|long|int) *\*|u?int(16|32)_t *\*|(^|[^a-z_])(short|int|long) +\*[a-z_]' fw/ctrl_rv/*.c fw/ctrl_rv/*.h | grep -v '^fw/ctrl_rv/swap\.[ch]:'
```

plus the two this task removed (`main.c` `CheckSum`, `hexdump.c`) and the
struct overlays of Tasks 9, 11 and 12 (`grep -n '\*)sector_buffer\|\*)&sector_buffer' fw/ctrl_rv/*.c`):

| File:line | Access | Data | Verdict |
|---|---|---|---|
| `boot.c:126`-`133` (`BootClearScreen`, called at `:238`) | `unsigned short *` stores | Amiga chip RAM (the boot screen) | zeros: neutral |
| `boot.c:198`-`204` (`BootUploadCopper`) | `unsigned short *` stores | the copper list | `be16`, this task |
| `boot.c` `BootUploadLogo`, `BootUploadBall`, the `COPPER_FILE` case, `BootCustomInit`, `BootPrintEx` | `unsigned char *` | file bytes, font bytes | bytes: neutral |
| `drivesounds.c:146`, `220` (`int *buf`) | the ring, one long per frame | `AUDIO_BUFFER` (the audio DMA reads it) | the 832's bytes, this task |
| `drivesounds.c:17`, `147`, `476` (`short *base`, `src`, `samples`) | sample reads | `DRIVESND.BIN` | native after the load's conversion, this task |
| `drivesounds.c:467`-`486` | the header longs | `DRIVESND.BIN` | `rd_be32`, this task |
| `main.c:82` (`CheckSum`) | was `int *` | kickstart in Amiga memory | `rd_be32`, this task |
| `hexdump.c:14` | was `unsigned int *` | any | `rd_be32`, this task |
| `fpga.c:101`-`117` (`SendFileV2`, kickstart upload) | `unsigned char *adr`: `RARead(file, adr, 512)` into Amiga memory, the decrypt `adr[j] ^= key[keyidx++]`, `PatchKick1xMemoryDetection` (`buf[0x154]`, `strncmp`) | kickstart ROM | bytes: neutral; `CheckSum` above |
| `config.c:41`, `50` (`ClearKickstartMirrorE0`, `ClearVectorTable`) | `int *` stores | Amiga memory | zeros: neutral |
| `config.c:189`-`217` (HRTmon config) | `unsigned char *` | Amiga memory | bytes; `maxchip` stored high byte first by shifts: big-endian on either CPU |
| `config.c:324` (`configTYPE` on `sector_buffer`) | struct overlay | the config file | Task 11 (little-endian file, own name, `cfgconv`) |
| `hdd.c:65`, `130`, `161` (`RDBChecksum`), `:93`, `:135` (RDSK/PART on `sector_buffer`), `:542` (an HDF's own RDB) | `uint32_t *`, struct overlays | blocks for the Amiga | Task 12 (`be32`) |
| `hdd.c:171` (`IdentifyDevice`), `:442` (`ATA_IdentifyDevice`) | `unsigned short *` | IDENTIFY DEVICE | Task 12 (words sent by value, low byte first; string words swapped) |
| `hdd.c:870` (`unsigned long *index`) | | the firmware's own cluster index of an HDF | native: not Amiga or file data |
| `atapi.c:102` (`ata_string`), `:221` (`atapi_identify`) | `uint16_t *` | IDENTIFY PACKET DEVICE | values (strings by shifts, first character in 15:8); `cdrom.c:763`-`765` sends them low byte first: neutral |
| `fat.c:136`, `369` ff. (`MasterBootRecord`, `DIRENTRY` on `sector_buffer`), `fat_buffer` | struct overlays | FAT data (little-endian) | Task 9 (`le16`/`le32`) |
| `fdd.c:350` (`GetHeader(unsigned int *pTrack, ...)`) | | `WriteTrack`'s locals | native; Task 13 ("Floppy", Multi-byte accesses) |
| `cue.c:52`, `82` (`int32_t *v`), `cdrom.c:226` (`int *open`) | | parser outputs, a flag | native: not data |
| `akiko.h:6`, `c64keys.h:5`, `rtc.h:6`, `i2c.h:46`, `hardware.h:53`, `58`, `97`, `111`, `120` | `volatile` register macros | I/O registers | not memory: the I/O map (Task 5, `hwmap_test`) |
| `hardware.h:79`, `osd.c:872` | | commented out | |

Not multi-byte, for completeness: `cdaudio.c:95`-`103` builds the CD audio
samples from bytes (little-endian, the ring's order) and `atapi.c`'s
`put16`/`put32`/`get16`/`get32` are byte-wise big-endian by shifts.

## SD driver timeouts and the TIMER (Task 10)

The 832's `mmc.c` bounded its five data-token and busy waits by loop count
(`timeout = 0; ... if (timeout++ >= 1000000)`): a bound in CPU speed, which
the ~7x faster RISC-V CPU would have cut to a seventh. They are TIMER bounds
now, `SD_TIMEOUT` counts:

| File:line (832 bound) | Wait | RV |
|---|---|---|
| `mmc.c:235`/`238` (`MMC_Read`, CMD17) | data token 0xFE | `t = GetTimer(SD_TIMEOUT); ... if (CheckTimer(t))` |
| `mmc.c:290`/`293` (`MMC_GetCSD`, CMD9) | data token 0xFE | same |
| `mmc.c:366`/`369` (`MMC_ReadMultiple`, CMD18, per block) | data token 0xFE | same |
| `mmc.c:452`/`455` (`MMC_Write`, CMD24) | busy (0x00) after the data response | same |
| `mmc.c:527`/`530` (`MMC_CMD12`) | busy after the stop command | same |

`#define SD_TIMEOUT 173` (`mmc.c:43`): 173 x 5.804 ms = 1.004 s, at least the
832's real bound (~1,000,000 SPI byte reads). `t` is a local of each
function; the global `timeout` stays `MMC_Init`'s. Unchanged: the `Ncr` loops
of `MMC_Command` and `MMC_CMD12` (`while (response == 0xFF && Ncr--)`, 100
polls: an SD-spec byte count, not a delay), `MMC_Init`'s `WaitTimer(20)` and
`GetTimer(1000)` (TIMER units already: parity), the messages and the
`FatalError` calls, and `MMC_ReadMultiple` still returning 1 when
`MMC_CMD12` timed out (it ignores that result, as on the 832). `grep -n
'timeout++' fw/ctrl_rv/mmc.c` is empty. `test/mmc_test.c` checks every bound
(`test/README.md`). In the L2 bench (TIMER 643x fast) `SD_TIMEOUT` is 1.56 ms
of simulated time; the SD model's waits there (4 token bytes, 8 busy bytes)
stay far below it.

### Every TIMER user

One TIMER count = 256 x 643 `clk_28` = **5.804 ms** on the board, for both
CPUs (cfide `timecnt(23 downto 8)`, `tick_in` 44.1 kHz: 256 audio frames).
`GetTimer(n)` returns `(TIMER + n) << 16`, `CheckTimer(t)` is true once
`t - (TIMER << 16)` is negative, so a deadline can be at most 32,767 counts
(190 s) ahead; `WaitTimer(n)` spins on both. The firmware's "ms" arguments
are counts: every value below is unchanged from `fw/ctrl_832` (the
`SD_TIMEOUT` sites replace count loops), and both CPUs wait the same board
time. In the L2 bench TIMER runs 643x fast (`tick_in = 1`: one count ~9.0
us). Lines are those of the current tree.

| File:line | User | Nominal (counts) | Board time |
|---|---|---|---|
| `hardware.h:53` | `TIMER`, 16-bit read of `0xFFFFFFD0` | | |
| `hardware.c:180`, `188`, `201` | `GetTimer`, `CheckTimer`, `WaitTimer` (above) | | |
| `hardware.h:59` | `SPIN`: one TIMER read, the value unused (a cfide handshake as a delay); live at `hardware.c:236` (`SPI_reply`, 4x), `fpga.c:226` (4x), `config.c:618` (4x) | | one bus access each |
| `audio.c:33`-`34` (`audio_clear`) | waits for the next TIMER change after `AUDIOF_ENA` | <= 1 | <= 5.804 ms |
| `drivesounds.c:79`, `99`, `435` | event and render timestamps (`drivesounds_render`, `samples = timestamp - drivesounds.timestamp`, `:158`) | 1 = 256 frames | 5.804 ms per count |
| `drivesounds.c:360` | `TIMER & 3`: pseudo-random pick of one of four sounds | | |
| `cdrom.c:380` (`cda_port_timer`), `cdaudio.c:52`, `179`, `191` | CD audio play position: `CDA_HALF_UNITS` (`cdaudio.h:39`) counts per half buffer | 32 | 185.7 ms (8192 frames) |
| `cdrom.c:471`, `483` (`cd_wait`) | `CD_TIMEOUT` (`cdrom.c:64`): host data phase | 10000 | 58.04 s |
| `hdd.c:932`, `934` (`OpenHardfile`) | `GetTimer(0)` difference, printed as "ms" (`time >> 16`) | counts | 5.804 ms per printed "ms" |
| `fpga.c:207` (`fpga_init`) | `GetTimer(0)`, unused | | |
| `fpga.c:230`, `232`, `254` (`fpga_init`) | `WaitTimer(50)`, `WaitTimer(100)`, `WaitTimer(1000)` (boot screen) | 50, 100, 1000 | 290.2 ms, 580.4 ms, 5.804 s |
| `osd.c:1030` (`OsdGetCtrl`) | menu button held: `BUTTONDELAY` (`osd.h:56`) | 20 | 116.1 ms |
| `osd.c:1035` | `GetTimer(-1)`: expired at once | -1 | 0 |
| `osd.c:1044`, `1048` (`OsdGetCtrl`) | key repeat: `REPEATDELAY`, `REPEATRATE` (`osd.h:54`, `55`) | 100, 25 | 580.4 ms, 145.1 ms |
| `osd.c:1119`, `1085` (`ScrollReset`, `ScrollText`) | name scroll: `SCROLL_DELAY`, `SCROLL_DELAY2` (`osd.c:269`, `270`) | 300, 3 | 1.741 s, 17.4 ms |
| `menu.c:247`, `269` (`cd_show_msg`, `cd_msg_expired`) | CD message: `CD_MSG_DELAY` (`menu.c:237`) | 4000 | 23.22 s |
| `menu.c:610`, `617`, `619` (`HandleUI`) | help text: `HELPTEXT_DELAY`, `FRAME_DELAY` (`menu.c:201`, `202`) | 2500, 50 | 14.51 s, 290.2 ms |
| `menu.c:3021`, `2714` (`InfoMessage`) | info popup | 1000 | 5.804 s |
| `main.c:107`, `109`, `111` (`FatalError`) | LED blink: `WaitTimer(250)` x2, `WaitTimer(1000)` | 250, 1000 | 1.451 s, 5.804 s |
| `main.c:297`, `343`, `346` (`main`) | ADV7511 poll (`adv_timer`) | 250 | 1.451 s |
| `mmc.c:72` (`MMC_Init`) | `WaitTimer(20)` after the 80 clocks | 20 | 116.1 ms |
| `mmc.c:80`, `88`, `135`, `174` (`MMC_Init`) | init timeout: `GetTimer(1000)`, ACMD41 / CMD1 polls | 1000 | 5.804 s |
| `mmc.c:235`, `290`, `366`, `452`, `527` | `SD_TIMEOUT` (above) | 173 | 1.004 s |
| `fat.c:723`, `1318` | `GetTimer(0)` inside a comment (dead); `fat.c:96` declares `GetTimer` | | |
| `menu.c:2737`, `config.c:612`, `fat.c:168` | in comments (dead) | | |

The boot ROM (`fw/ctrl_boot_rv`) is not part of this firmware and unchanged.

## String semantics audit

lib832 (`string.S`, `string_c.c`, `stringstubs.c`, `include/string.h`,
`string_asm.h` at EightThirtyTwo `d1cd671`) read against ISO C / newlib. The
host tests link glibc, which has the target libc's (newlib-nano's) semantics,
so they need no lib832 emulation.

| Function | lib832 | ISO C / newlib | Observable? |
|---|---|---|---|
| `strncpy` | copies bytes up to and including the first NUL, or `n` bytes; **does not pad** the rest with NULs; `n == 0` copies nothing; returns `dst` | pads with NULs up to `n` | only if a byte after the NUL is read: see the call-site table |
| `strncmp`, `memcmp` | `n == 0` returns whatever `r0` holds (nothing sets it); otherwise the byte difference `a - b` as unsigned bytes (same sign as ISO) | `n == 0` returns 0 | only `fat.c:383` can call with `n == 0` (`strncmp(fileLFN, name, strlen(name))`, empty `name`): there `r0` still holds the result of `strlen(name)`, i.e. 0 (checked by compiling the 832 `fat.c` with vbcc832), so lib832 returns 0 too. Same |
| `strncat` | `n == 0` copies the **whole** source (the loop counts `n - 1` to zero); `n > 0` copies at most `n` bytes then a NUL, like ISO; the return value is not set | `n == 0` appends nothing | no `n == 0` call; the return value is never used |
| `strcat` | return value not set | returns `dst` | never used |
| `strcmp`, `strlen`, `strcpy`, `memcpy`, `memset` | ISO (`strcpy`, `memcpy`, `memset` return `dst`; the `void memset` in `stringstubs.c` is not what `string.h` maps to) | same | no |
| `memmove` | the forward-copy branch (`src <= dst`) jumps into `memcpy`'s loop, where `r1` is the destination pointer and `r3` the end; `memmove` has them swapped (`r3` = dst, `r1` = dst + size), and its backward loop decrements `r3`, the destination start | ISO, overlap safe | 0 call sites |
| `tolower`, `toupper` | ASCII `A`-`Z` only, everything else (128-255, negative) unchanged | the same in the C locale | no |
| `strtol`, `strtoul` | skip only spaces; no `+`; no `0x`; no base 0; digits `0-9` accepted in any base, letters only in base 16; `*endptr` stored unconditionally (NULL crashes); `int` arithmetic, no overflow handling; `strtoul` ignores `-` | ISO | 0 call sites |
| `strtok`, `strtok_r`, `strspn`, `strcspn` | own implementations (`strtok` has static state) | ISO | 0 call sites |

`rvlibc.c` needs no string helper: no call site depends on a lib832 behaviour
that ISO lacks. Verdicts per call site (preprocessed sources, 2026-10-17;
counts are the compiled sites):

| Call sites | Verdict |
|---|---|
| `strncpy` `config.c:62,150`, `hdd.c:914` (`filename`, 8, then `strcpy(&filename[8], "ROM"/"HDF")`) | The source is an 8-character space-padded name without NUL: exactly 8 bytes copied by both. A name with an early NUL (a corrupt config) would leave `filename` bytes uninitialised on the 832 and zero on RV; `FileOpen` then compares 11 bytes. Indeterminate on the 832: not emulated |
| `strncpy` `config.c:353,409,410,421,423,435` | An 8-character literal (`EXTENDED`, `MNMGCFGA`, `KICK    `, `HARDFILE`) into an 8-byte field: no NUL copied, nothing to pad. Same |
| `strncpy` `config.c:681` (`file.name`, 11) | `MINMGAR CFG` / `MINMGAR<n>CFG` is 11 characters. Same |
| `strncpy` `config.c:247` (`ConfigName832`, Task 11, no 832 counterpart) | the source is an 11-character RV name, `buf[11] = 0` after it |
| `strncpy` `cdrom.c:86`, `275` | `86`: the destination was zeroed by `memset` just before. `275`: `longname[41]`, read only as a NUL-terminated string (`atapi_insert`, `cd_config`). Same |
| `strncpy` `osd.c:1106,1109` (`ScrollText`) | Inside `len > max_len`: the source is longer than `n` in both copies (`n < max_len < len <= strlen`), so no NUL is copied and nothing is padded. Same |
| `strncpy` `fat.c:385` (`file->name`, 11) | `pEntry->Name` is 11 bytes of an 8.3 name, no NUL. Same |
| `strncpy` `fat.c:884,899,932,951,966,999,1024,1046,1069,1087,1103,1136,1152,1191,1207` (`DirEntryLFN[..]`, `lfn`, 261) | Destination rows are `[261]`, set to NUL-terminated names and read only as strings (`strlen`, `strcmp`, `strcpy`, `strncpy(file.long_name, .., len)`, `ScrollText`); no `memcpy` of a row. The zero padding of up to 260 bytes per copied entry is never read. Same |
| `strncpy` `menu.c:349,351,717,2866,2867,2870,2874,2886` (the OSD line `s`) | Both copy the NUL at the same place; `OsdWrite` stops at the first NUL, so the bytes after it (spaces from the earlier `memset` on the 832, zeros on RV) are never drawn. For a long name shorter than 24 characters the NUL ends the line before the disk number (`2866/2867`) and before ` <DIR>` on both CPUs. Same |
| `strncpy` `menu.c:1369,1371,1372`, `2946,2953` | `file.name` 11 and `drive->name` 8 bytes from space-padded names: no NUL. `file.long_name` is zeroed by `memset` first (`1370`). `DiskInfo[5]` is `XX/XX` (5 characters, `GetDiskInfo`) or starts with NUL and is then not used (`menu.c:2953`). Same |
| `strncpy` `menu.c:3060` (`debuglines`) | The line is drawn by `OsdWrite`, which stops at the NUL. Same |
| `strncmp` (17: `config.c:245` (Task 11, n = 7), `339,347`, `drivesounds.c:463`, `fat.c:128,130,182,185,249,383 (x2),459,580`, `fpga.c:60,65`, `menu.c:1343,2140`) | `n` is a constant or `sizeof`, always > 0, and the result is compared with 0. Same |
| `strncmp` `fat.c:383` first call, `n = strlen(name)` | `name` empty (`n == 0`): lib832 returns `r0`, which still holds the `strlen(name)` result, 0 (vbcc832 output of the 832 `fat.c`); ISO returns 0. An empty name matches the first plain file entry on both. Same, no edit |
| `memcmp` (5: `cdrom.c:82,285`, `menu.c:394,2052`, `cfgswap.c:22` (Task 11, n = 8)) | `n` = 3 or `sizeof`, > 0, compared with 0. Same |
| `strncat` (3: `menu.c:756` n = 17/21, `1759` 16, `1761` 8) | `n > 0`: at most `n` bytes then NUL on both; `kickstart.name` has no NUL (8 characters) and both copy exactly 8. Return value unused. Same |
| `strcat` (38), `strcpy` (54) | ISO on both; no return value is used. Same |
| `tolower` (6: `fat.c:628 x2, 1176 x2, 1178 x2`) | ASCII letters on both; the arguments are `unsigned char` values (`-funsigned-char`). Same |
| `strcmp` (1: `menu.c:168`), `strlen` (10), `memcpy` (36), `memset` (28) (each count with Task 11's one in `LoadConfiguration`) | ISO on both. Same |
| `memmove`, `strtol`, `strtoul`, `strtok`, `strspn`, `strcspn`, `toupper` | 0 call sites |

## Host tests

The tests compile the firmware sources for the host (native and `-m32`, with
AddressSanitizer and UBSan) against a mock of the hardware. The format-parity
check needs lib832's `small_printf.c` (the 832's printf, the reference): it
is in the `EightThirtyTwo` submodule. From a fresh Ubuntu 24.04 machine
(works in bash and zsh), from the repository root:

```sh
sudo apt install build-essential gcc-multilib python3 git mtools dosfstools fdisk
git submodule update --init EightThirtyTwo
make -C fw/ctrl_rv/test
```

(`make -C fw/ctrl_rv/test` is every test, native and `-m32`, and the format
gates; the exit status is the result.) Without the submodule (no network, or
a checkout of EightThirtyTwo that already exists elsewhere) skip the
`git submodule` line and name the lib832 directory instead:

```sh
make -C fw/ctrl_rv/test LIB832=/path/to/EightThirtyTwo/lib832
```

A missing `LIB832` fails the run; the check is never skipped. The mutants,
which every test must go red on:

```sh
make -C fw/ctrl_rv/test mutants
```

`swap_test` checks the byte-order helpers (memory order on any host, the
`rd_*`/`wr_*` forms at offsets 0..3 under UBSan, the legacy swaps without sign
extension); `fat_test` runs the real `fat.c` + `mmc.c` on three card images
(FAT16 with MBR, FAT32 with MBR, FAT16 superfloppy) against `mtools` and
`fsck.fat`; `mmc_test` runs the real `mmc.c` on the card model (`MMC_Init`'s
command sequence against the L2 boot run's SD log, token delays, busy, the
five `SD_TIMEOUT` bounds, the direct-mode trace `test/gold/dmode.txt`);
`config_test` checks the config file's byte order (`cfgswap.c`, `cfgconv`,
`LoadConfiguration` on the card model, the 832 file never written);
`hdd_test` runs the real `hdd.c` over `fat.c` + `mmc.c` behind a mock Gayle
(FakeRDB, the RDB patch, IDENTIFY DEVICE against independent generators, the
ATA read/write paths against the HDF files); `fdd_test` runs `fdd.c` and the
832's `fdd.c` (built for the host) behind a mock `paula_floppy`: the read
stream of every track against `test/gold/mfm.py`, an independent MFM
encoder, and track writes decoded into the ADF; `drivesounds_test` loads
`sw/mkdrivesounds/drivesnd.bin` through the card model and compares the
audio ring after every fill of an event sequence with
`test/gold/drivesounds.py` (the 832's file format and render rules);
`boot_test` checks the default copper list, `CheckSum` and `hexdump` by
their bytes.
`fw/ctrl_rv/test/README.md` has the targets, the flags, the mock (an SPI/TIMER/UART
model with a card-image model; `-DHOSTTEST` hooks in `hardware.h` that leave
the target image byte for byte the same), the rules for writing a test and the
mutant rules. `LIB832` is `$(TOP)/EightThirtyTwo/lib832` by default
(EightThirtyTwo pin `d1cd671`).
`lib_test` checks `rvlibc.c` against glibc's `vsnprintf` with a mock `putchar`
(equal output and return value, the truncation case, a `printf` issued from
inside `putchar`, the nesting count, the heap stubs). `make mutants` runs the
mutants of every test and of every register class of the I/O map; a mutant
counts as killed only when the real test target fails on a build that
succeeded.

## Simulation runs (L1, L2)

The firmware also runs on the real host side of the core in simulation. The
benches are `sim/rv_l1` (L1: `rv_hostcpu` against an abstract memory,
Icarus Verilog or Verilator) and `sim/host_bridge` (L2: the real bridge,
`cfide` and an SD card model, xsim or Verilator on the Verilog that GHDL
makes of the VHDL); their READMEs have the details. The blocks here use
Verilator, which needs the toolchain steps under "Building" and

```sh
sudo apt install verilator ghdl ccache
```

### On the L1 bench

`fmt_rv` (`test/rv/fmt_rv.c`; `fmt_rv_subset` is the same source with `-DFMT_SUBSET=1`) is built by `sim/rv_l1/prog/Makefile` the way
the firmware will be linked (`--specs=nano.specs -nostdlib -nostartfiles`,
`crt0_l1.o` + `l1_newlib.ld`, no `syscalls.o`, `-lc_nano -lgcc` last). Besides
the format cases it runs newlib-nano's `memcpy`, `memmove` (overlapping both
ways), `memset`, `memcmp`, `strlen`, `strcmp`, `strncmp`, `strncpy`, `strncat`
at source and destination offsets 0..3 (lengths 0, 1, 3, 4, 5, 8, 9, 17) (VexRiscv traps a misaligned access:
the run would end `=== FAIL 80xx`), and prints `rv_libc_heap_calls` (must be 0).
`run.sh fmt` also checks that `fmt_rv.map` has no `_sbrk`, `_sbrk_r`,
`__sinit`, `__sfp`, `_write`, and that `_malloc_r`, `_realloc_r`, `_free_r`
come from `rvlibc.o`.

All 909 cases take 25 s on Verilator, the subset 10 s:

```sh
SIM=verilator RUNTAG=p3t3b bash sim/rv_l1/run.sh fmt
FMT_SUBSET=1 SIM=verilator RUNTAG=p3t3s bash sim/rv_l1/run.sh fmt
```

The X-checking reference is Icarus Verilog 12 at `/usr/local/bin/iverilog`
(`sim/rv_l1/README.md`). The subset takes about 38 minutes there, and
`compare` must say SAME against the Verilator subset run above:

<!-- replay-skip: 38 minutes of iverilog -->
```sh
FMT_SUBSET=1 RUNTAG=p3t3i bash sim/rv_l1/run.sh fmt
bash sim/rv_l1/run.sh compare p3t3i p3t3s
```

The firmware's CD-ROM unit programs (`test/emu`: `atapi_emu`, `cue_emu`,
`cdaudio_emu`) are built from `fw/ctrl_rv` (the default `FWDIR`) and run on
the same bench (seconds on Verilator; ends with `=== UNITS PASS`):

```sh
SIM=verilator RUNTAG=p3t19u bash sim/rv_l1/run.sh units
```

A change of the toolchain or of `RV_CFLAGS_FW` needs `make -B` in
`sim/rv_l1/prog` (or a new tree): the `fwdir` stamp only covers the path of
`FWDIR`, so the objects would otherwise be reused (`sim/rv_l1/README.md`).

### On the L2 bench

`fwboot` boots the real `RV32OSDA.BIN` (`fw/ctrl_rv/build/`, built as under
"Building") from a 16 MB FAT16 card with the committed boot ROM and runs it
into its main loop (the fatal-error loop: the bench card has no kickstart).
`fwboot_trap` is the same with a constructor that executes an illegal
instruction, `fwboot_cfg` has an 832 config file on the card that the
firmware converts on its first boot. Each is a PASS/FAIL gate on milestones
of the UART and SPI streams (`sim/host_bridge/README.md`, "Firmware boot"):

```sh
SIM=verilator RUNTAG=fwv bash sim/host_bridge/run.sh fwboot
SIM=verilator RUNTAG=fwvt bash sim/host_bridge/run.sh fwboot_trap
SIM=verilator RUNTAG=fwvc bash sim/host_bridge/run.sh fwboot_cfg
```

About 6, 3 and 6 minutes. The run lengths are cycle limits of `clk_114`:
`fwboot` 176.4 M cycles (the card holds `DRIVESND.BIN`, whose load takes
about 39 M cycles), `fwboot_cfg` 119.6 M (no `DRIVESND.BIN`), `fwboot_trap`
65.9 M; `FWBOOT_TIMEOUT=<cycles>` overrides. `fwboot_trap` links its own
firmware: it ignores `FW=`. The xsim reference run of `fwboot` takes about
27 minutes and needs Vivado 2023.2 (`sim/host_bridge/README.md`).

The `fwboot` run also reports the OSD reply gap: **`OSD GAP min 40`**, the
bench's measure of the host's access spacing during an OSD reply read,
against the 40 `clk_114` that `userio_osd` needs (`sim/spi_cdc`). It has no
margin left; whether the real `userio_osd` accepts it is an open risk that
Phase 4 (L3 co-simulation) checks.

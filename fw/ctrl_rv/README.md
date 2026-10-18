# fw/ctrl_rv - OSD / host firmware for the VexRiscv host CPU

Port of `fw/ctrl_832` (ZPU-class 832 host CPU) to RV32IMC. Task 2 made the
**verbatim copy**; from then on `diff -ru fw/ctrl_832 fw/ctrl_rv` is exactly
the port. Edits so far: Task 3's call-site edits ("Differences from
fw/ctrl_832") and the C library / host-test files ("C library", "Host tests");
Task 4's `Makefile` and gcc 15 / gnu23 compile fixes ("Building", "gcc 15 and
gnu23 compile fixes"); Task 5's I/O map ("Differences from fw/ctrl_832");
Task 9's byte-order helpers and the FAT/MBR fields ("Byte order (Task 9)");
Task 10's TIMER bounds in `mmc.c` ("SD driver timeouts and the TIMER (Task 10)").

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
also `fat.h swap.c swap.h`. `find` also
lists files that only exist here (`rvlibc.c`, `rvlibc.h`, `test/lib_test.c`,
`test/fmt_*`, `test/mutants.sh`, `test/gold/`, `test/rv/`, `test/swap_test.c`,
`test/fat_test.c`, `test/fatimg.sh`, `test/fat_check.sh`); `cmp` reports
those as missing in `fw/ctrl_832`. `interrupts.c`/`interrupts.h` exist only in
`fw/ctrl_832` (Task 4), so the loop above does not see them.

## Building

From a fresh Ubuntu 24.04 machine, from the repository root (works in zsh and
bash):

```sh
sudo apt install build-essential git python3 xxd
bash tools/riscv/fetch-xpack.sh
bash tools/riscv/check-toolchain.sh
make -C fw/ctrl_rv clean all size
make -C fw/ctrl_rv check
```

Output in `fw/ctrl_rv/build/` (gitignored): `RV32OSDA.BIN` (`objcopy -O
binary`, loaded by `fw/ctrl_boot_rv` to 0x2000), `RV32OSDA.elf`, `.map`, `.lst`
(disassembly with source), `version.h`. `B=dir` builds into another directory;
`EXTRA_CFLAGS=...` adds compiler flags for bench variants (empty for the
shipped image); `EXTRA_OBJS=...` links extra objects after the firmware's
(empty for the shipped image; `sim/host_bridge/fwboot` links its trap
constructor `smoke_trap.o` this way, into its own `B=` directory). Another toolchain install: `RV_GCC_DIR=... RV_PREFIX=...`
(`tools/riscv/toolchain.mk`).

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
| RV32IMC (this tree) | 90,278 | 3,484 | 59,288 | **93,764 B** |
| 832 (`832OSDAD.bin`) | | | | 83,830 B |

Plan estimate 85-95 KB; +11.9 % over the 832. The figure moves by a few bytes
with the date strings of `version.h` (93,768 B at 21:58). `_end` = 0x275DC
(< 0x70000, `AUDIO_BUFFER`). Task 9: text 87,882, **91,368 B** (2026-10-18):
`le16`/`le32` are the identity on RV32, so the `SwapBB`/`SwapBBBB` calls of
`fat.c` are gone.

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
the preprocessor over every `fw/ctrl_rv/*.c`, 2026-10-17: 136 sites; a
raw `grep` also finds the commented-out ones). Conversions are taken at their
maximum: `%d`/`%ld` 11 bytes, `%u`/`%lu` 10, `%x`/`%X`/`%lX` 8, a width raises
the figure to the width. Each `%s` is bounded by its source:

| Site | `%s` bound |
|---|---|
| `fat.c:399`, `424`, `583`, `604` (`name` of `FileOpen`/`FindDirectory`) | 260: a CUE `FILE` name is at most 255 characters (`CUE_LINE_MAX 300`), `fat.h` `long_name[261]` |
| `menu.c:2968` (`file.long_name`) | 260 |
| `cdrom.c:291` | `shortname` 11, `cd_msg[24]` 23 |
| `cdrom.c:305` | `shortname` 11, `cdrom.unit.name` 40 |
| `fpga.c:125`, `128` | `kick1xfoundstr` 21, `applymemdetectionpatchstr` 46 |
| `%.8s`, `%.3s`, `%.11s` | the precision |
| `boot.c:263` (`printf("%s", str)`, `BootPrintEx`) | 80: the longest literal is 75, `s[40]`, `rtl_ver[45]` |

Per file, `line:bytes`:

| File | Sites | Longest output of each (line:bytes) |
|---|---|---|
| `akiko.c` | 2 | 17:32, 19:21 |
| `boot.c` | 2 | 263:80, 264:1 |
| `cdrom.c` | 17 | 291:50, 305:108, 334:17, 416:27, 485:18, 521:34, 684:17, 686:9, 688:19, 689:29, 690:34, 691:19, 692:33, 693:20, 694:5, 696:2, 777:84 |
| `config.c` | 11 | 65:21, 186:24, 277:36, 609:30, 610:30, 614:57, 617:14, 618:28, 624:27, 628:19, 631:22 |
| `drivesounds.c` | 4 | 442:32, 457:50, 475:34, 478:28 |
| `fat.c` | 39 | 189:28, 193:4, 196:5, 199:5, 202:5, 206:7, 209:2, 296:21, 297:23, 298:22, 299:33, 300:24, 301:23, 302:25, 303:23, 399:274, 424:278, 462:33, 515:32, 535:35, 583:295, 604:283, 783:28, 790:33, 863:11, 1581:59, 1594:31, 1609:26, 1621:32, 1631:49, 1647:55, 1649:54, 1654:38, 1701:38, 1712:45, 1713:30, 1714:24, 1715:26, 1723:39 |
| `fdd.c` | 11 | 184:32, 191:12, 222:23, 252:17, 300:2, 303:4, 339:6, 377:29, 433:59, 438:23, 635:13 |
| `fpga.c` | 6 | 94:25, 95:1, 103:1, 122:2, 125:21, 128:46 |
| `hdd.c` | 13 | 453:29, 463:30, 745:20, 747:4, 749:9, 750:9, 840:87, 904:22, 905:21, 906:33, 907:37, 908:17, 913:34 |
| `main.c` | 2 | 262:29, 275:31 |
| `menu.c` | 7 | 2928:52, 2968:281, 2970:32, 2972:28, 2973:38, 2974:25, 2975:25 |
| `mmc.c` | 22 | 80:19, 95:25, 111:24, 116:36, 127:17, 136:29, 154:24, 159:34, 166:18, 173:29, 191:35, 197:25, 219:65, 231:52, 272:45, 285:34, 346:74, 360:61, 410:66, 434:64, 445:57, 518:46 |

Maximum 295 bytes (`fat.c:583`, a `FindDirectory` name of 260 characters; no
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
contains a `%` (134 lines, made by
`grep -ho '"[^"]*%[^"]*"' fw/ctrl_rv/*.c | LC_ALL=C sort -u`; the Makefile
checks it is current). Conversions used: `%d %u %x %X %s %ld %lu %lx`, widths
`%4d %02X %04X %04x %08X %08lX %08lx`, precisions `%.3s %.8s %.11s`; no `%c %p
%b %ll %h %z`. Two lines are inline-assembly templates (`"rol.w #8,%0\n\t"`,
`"swap %0\n\t"`) and are not formats. `test/fmt_cases.h` has one or more
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
| `akiko.c:17,19`, `config.c:612`, `drivesounds.c:465`, `fat.c:782,789,1649,1651`, `main.c:175`, `menu.c:1595,2663,2665,3042,3044,3046,3048,3050,3052,3054` | `%x`, `%04x`, `%08lx`, `%lx` | `%X`, `%04X`, `%08lX`, `%lX` | `UPPER`: keeps the UART/OSD text identical |
| `boot.c:258` | `printf(str)` | `printf("%s", str)` | `str` is data (a file name, `rtl_ver`): a `%` in it would be taken for a conversion with garbage arguments, and the two libraries differ on that. Identical for every string without `%` |

### gcc 15 and gnu23 compile fixes (Task 4)

Decision 12.12: the tree is C gnu23 (`f()` means `f(void)`; `bool`, `true`,
`false` are keywords, `true` == 1) and the code is fixed for it, not built
with `-std=gnu17`. Every edit is minimal; behaviour is the 832's. Found by
building the Task 3 tree (`make -C fw/ctrl_rv -k`: 23 distinct errors, all
covered below) plus the source rules of 12.12.

| File:line | 832 | RV | Why |
|---|---|---|---|
| `firmware.h:23-24` | `#define true -1`, `#define false 0` | removed | C23 keywords; audit below (no site observes -1) |
| `drivesounds.h:14-15` | `void drivesounds_enable();`, `void drivesounds_disable();` | `(int type)` | the definitions take `int`; gcc 15 rejects the calls (`main.c:228`, `menu.c:901,903,1961,1963`: too many arguments) and the conflicting definitions (`drivesounds.c:49,54`) |
| `menu.c:2987` | `void ShowError(char *message, unsigned char code)` | `void ShowError(void)` | conflicts with `menu.h`'s `ShowError()` (= `(void)` in C23); the only call (`main.c:332`) passes nothing and the body uses neither parameter. `menu.h` stays as written |
| `fat.c:473` | `int FindDirectoryByCluster(...)` | `unsigned long FindDirectoryByCluster(...)` | conflicts with `fat.h:126` (`unsigned long`), which its one caller (`fat.c:463`, a truth value) sees; same 32-bit value |
| `config.c:29` | `int CheckSum();` | `int CheckSum(char *adr,int size);` | the definition (`main.c:81`) takes parameters (rule of 12.12); `config.c` calls it only in comments |
| `config.c:41`, `config.c:50` | `int *p=(0xe00000 & 0x7fffff) ^ HOSTMAP_ADDR;`, `int *p=0 ^ HOSTMAP_ADDR;` | `(int *)(...)` | integer -> pointer is an error in gcc 15; same address |
| `boot.c:240` | `BootClearScreen(SCREEN_ADDRESS, ...)` | `BootClearScreen((unsigned short *)SCREEN_ADDRESS, ...)` | `boot.h:15` `SCREEN_ADDRESS` is an integer; same address |
| `audio.c:25`, `drivesounds.c:431` | `unsigned char *p=AUDIO_BUFFER;`, `char *buf=AUDIO_BUFFER;` | `(unsigned char *)`, `(char *)` cast | `hardware.h:33` `AUDIO_BUFFER` is an integer (its other users already cast); same address |
| `hdd.c:518` | `while(blk && (((lba+hdf[unit].offset)<0) \|\| (unit==0 && hdf[unit].type==HDF_FILE && lba==0))` | one `)` added at the end: `blk && (A \|\| B)` | a missing `)` that vbcc832 accepted (warning 59 "`)` expected" at line 519: it inserts the `)` before the `{`). The 832 assembly (vbcc832 with the 832 Makefile's flags on `fw/ctrl_832/hdd.c`) tests `blk` first and leaves the loop when it is 0 without evaluating A or B, i.e. `blk && (A \|\| B)`, not `(blk && A) \|\| B` (the other place where one `)` would parse) |
| `drivesounds.c:380`, `391`, `397`, `413` | `if ((drivesounds.enabled & DRIVESOUNDS_FLOPPY)` | `if ((drivesounds.enabled & DRIVESOUNDS_FLOPPY))` | the same missing `)` four times (the plan named the first; gcc's error at 380 hid the other three; vbcc832 warns 59 at 381, 392, 398, 414, and nowhere else in `fw/ctrl_832`): every placement means `(enabled & FLOPPY)` |
| `drivesounds.c:11`, `432` | `extern char _bss_end__;`, `buf-&_bss_end__` | `__bss_end` | link error: `_bss_end__` is the 832 linker's `__bss_end__` (vbcc prefixes `_`); `arch/firmware.ld` names the end of `.bss` `__bss_end` (= `_end`) |
| `akiko.c:25` | `__constructor(101.akiko)` | `__attribute__((constructor(102)))` | the 832 order ("Building", Constructors) |
| `c64keys.c:305` | `__constructor(101.c64keys)` | `__attribute__((constructor(103)))` | the 832 order |
| `akiko.c:3`, `c64keys.c:3`, `main.c:58` | `#include "interrupts.h"` | `#include "irq.h"` | `interrupts.c`/`.h` deleted; `arch/irq.c` replaces them (default handler at constructor priority 101; the 832's `intconstructor` was 100) |
| `main.c:245-254` | `void setstack();`, `#ifdef __GNUC__ void c_entry(void) #else __geta4 int main(void) #endif`, `setstack();` | `int main(void)` | crt0 calls `main` and has set `sp`; `__geta4` (defined empty for the 832) is not needed. `main.c` is 6 lines shorter from here on: Task 3's printf audit lines `main.c:262`, `275` are now `256`, `269` |

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
| `config.c:288` | `updatekickstart=true;` (`int` local) | truth only: never read (gcc: set but not used) |
| `config.c:360` | `updatekickstart=true;` | truth only: never read |
| `menu.c:124` | the word "true" in a help string | text, not code |
| `menu.c:126` | the word "true" in a help string | text, not code |
| `menu.c:410` | `static unsigned char ctrl = false;` | truth only |
| `menu.c:411` | `static unsigned char lalt = false;` | truth only |
| `menu.c:412` | `static unsigned char lshift = false;` | truth only |
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
| `drivesounds.c:330-332` `pickstep()` | `count` is read in `while(count>maxactive)` before it is ever assigned: undefined behaviour (the 832 got whatever its stack held). When `count` happens to be `<= maxactive` the loop is skipped and no sound is stopped | pragma around the function (`-Wuninitialized`, `-Wmaybe-uninitialized`) |
| `fpga.c:138` `BootPrint()` | declared `char`, falls off the end without a return (the body is the `//return(1)` stub). The callers (`config.c`) ignore the value today; using it would be undefined behaviour | pragma around the function (`-Wreturn-type`) |
| `config.c:263,286,358` `LoadConfiguration()` | `updatekickstart` is set to `true` in two places and never read: whatever it was meant to trigger (a kickstart re-upload after a config change) does not happen | `__attribute__((unused))` on the variable |
| `drivesounds.c:142,214` | `b1`, `b2` (the 0x4000 bit of the audio cursor before and after a fill) are assigned and never used (a check on them was probably meant, or removed) | `__attribute__((unused))` |
| `atapi.c:666` `atapi_packet()` | parameter `limit` (the host's allocation length) is never used | `(void)limit` |
| `osd.c` `OsdColor(color)`, `ConfigScanlines(scanlines)`, `menu.c` `ErrorMessage(message, code)`, `hdd.c` `ATA_Recalibrate(.., unit)`, `ATA_Diagnostic(tfr)`, `ATA_Initialize(.., unit)`, `HandleHDD(c1, c2)`, `fdd.c` `HandleFDD(.., c3, ..)`, `menu.c` `VolumeBar(vol, ..)`, `fpga.c` `BootPrint(text)`, `cdrom.c` `cd_lookup_read`/`cd_cue_open` (`ctx`) | stubs or parameters the body ignores (FIXME/TODO in the 832 source) | `(void)param` |
| `c64keys.c:47` `LAYER(x,y)` | the macro masks `x&0xffff` without parenthesising `x`; for `LAYER(QUAL_BLOCKLAYER\|RK_RAmiga, ..)` it computes `QUAL_BLOCKLAYER \| (RK_RAmiga&0xffff)`. Same value as long as every qualifier is `< 0x10000` (they are: `QUAL_*` are `<= 0x8000`), wrong for a larger one | macro parenthesised (`((x)&0xffff)`); the table values are unchanged |
| `fdd.c:85,88,102` | `11 - sector >> 1 & 0x55` parses as `((11-sector)>>1)&0x55`; if the intent was `11 - (sector>>1&0x55)` this is a bug in the MFM checksum. It is the 832's reading (that is what vbcc832 compiled), so it is kept | parentheses spell out the existing parse |
| `hdd.c:882` | `lba & (-1 << n)`: shift of a negative value (undefined in C before C23, well defined here because gcc shifts two's complement) | `(int)(~0U << n)`, same bits |
| `config.c:548`, `drivesounds.c:365` | `if (romsize=Upload...)` and `while(dse=...)` assign in a condition: intended, but easy to misread | extra parentheses |
| `menu.c:2763` | `static char template[4] = " of "` holds no NUL (4 chars): fine while only `sizeof` and byte compares are used, never as a string | `__attribute__((nonstring))` |
| `menu.c:2593` | the `case MENU_ROMFILE_SELECTED:` falls into `..._SELECTED1:` ("no break intended" in the 832 source) | `__attribute__((fallthrough))` |
| `hdd.c:764-848` `GetHardfileGeometry`, `drivesounds.c:133-302` `drivesounds_render` | `-Wmaybe-uninitialized` on `cyl/head/spt` (set in the first pass of loops that always run, `sptt[0] >= 0`) and `srcs/srcs2/srcs3` (read only when the matching `src` pointer is set, which also sets them): false positives, not bugs | pragma around the function |
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
| `fat.c:74`, `fat.h:85` | `unsigned char sector_buffer[1024];` | `__attribute__((aligned(4)))` (definition and `extern`) | item 7: `DIRENTRY`, `MasterBootRecord` (and `configTYPE`, `config.c:273`, Task 11) are overlaid on it; gcc merges the BPB byte reads into `lw 36(s0)` (`fat_size`), which needs the 4-aligned base |
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
| `hardware.h:59` | `SPIN`: one TIMER read, the value unused (a cfide handshake as a delay); live at `hardware.c:236` (`SPI_reply`, 4x), `fpga.c:226` (4x), `config.c:546` (4x) | | one bus access each |
| `audio.c:33`-`34` (`audio_clear`) | waits for the next TIMER change after `AUDIOF_ENA` | <= 1 | <= 5.804 ms |
| `drivesounds.c:78`, `98`, `430` | event and render timestamps (`drivesounds_render`, `samples = timestamp - drivesounds.timestamp`, `:150`) | 1 = 256 frames | 5.804 ms per count |
| `drivesounds.c:355` | `TIMER & 3`: pseudo-random pick of one of four sounds | | |
| `cdrom.c:384` (`cda_port_timer`), `cdaudio.c:55`, `182`, `194` | CD audio play position: `CDA_HALF_UNITS` (`cdaudio.h:38`) counts per half buffer | 32 | 185.7 ms (8192 frames) |
| `cdrom.c:473`, `485` (`cd_wait`) | `CD_TIMEOUT` (`cdrom.c:64`): host data phase | 10000 | 58.04 s |
| `hdd.c:917`, `919` (`OpenHardfile`) | `GetTimer(0)` difference, printed as "ms" (`time >> 16`) | counts | 5.804 ms per printed "ms" |
| `fpga.c:207` (`fpga_init`) | `GetTimer(0)`, unused | | |
| `fpga.c:230`, `232`, `254` (`fpga_init`) | `WaitTimer(50)`, `WaitTimer(100)`, `WaitTimer(1000)` (boot screen) | 50, 100, 1000 | 290.2 ms, 580.4 ms, 5.804 s |
| `osd.c:1030` (`OsdGetCtrl`) | menu button held: `BUTTONDELAY` (`osd.h:56`) | 20 | 116.1 ms |
| `osd.c:1035` | `GetTimer(-1)`: expired at once | -1 | 0 |
| `osd.c:1044`, `1048` (`OsdGetCtrl`) | key repeat: `REPEATDELAY`, `REPEATRATE` (`osd.h:54`, `55`) | 100, 25 | 580.4 ms, 145.1 ms |
| `osd.c:1119`, `1085` (`ScrollReset`, `ScrollText`) | name scroll: `SCROLL_DELAY`, `SCROLL_DELAY2` (`osd.c:269`, `270`) | 300, 3 | 1.741 s, 17.4 ms |
| `menu.c:247`, `269` (`cd_show_msg`, `cd_msg_expired`) | CD message: `CD_MSG_DELAY` (`menu.c:237`) | 4000 | 23.22 s |
| `menu.c:610`, `617`, `619` (`HandleUI`) | help text: `HELPTEXT_DELAY`, `FRAME_DELAY` (`menu.c:201`, `202`) | 2500, 50 | 14.51 s, 290.2 ms |
| `menu.c:3021`, `2714` (`InfoMessage`) | info popup | 1000 | 5.804 s |
| `main.c:106`, `108`, `110` (`FatalError`) | LED blink: `WaitTimer(250)` x2, `WaitTimer(1000)` | 250, 1000 | 1.451 s, 5.804 s |
| `main.c:275`, `310`, `313` (`main`) | ADV7511 poll (`adv_timer`) | 250 | 1.451 s |
| `mmc.c:72` (`MMC_Init`) | `WaitTimer(20)` after the 80 clocks | 20 | 116.1 ms |
| `mmc.c:80`, `88`, `135`, `174` (`MMC_Init`) | init timeout: `GetTimer(1000)`, ACMD41 / CMD1 polls | 1000 | 5.804 s |
| `mmc.c:235`, `290`, `366`, `452`, `527` | `SD_TIMEOUT` (above) | 173 | 1.004 s |
| `fat.c:723`, `1318` | `GetTimer(0)` inside a comment (dead); `fat.c:96` declares `GetTimer` | | |
| `menu.c:2737`, `config.c:540`, `fat.c:168` | in comments (dead) | | |

The boot ROM (`fw/ctrl_boot_rv`) is not part of this firmware and unchanged.

## String semantics audit

lib832 (`string.S`, `string_c.c`, `stringstubs.c`, `include/string.h`,
`string_asm.h` at EightThirtyTwo `d1cd671`) read against ISO C / newlib. The
host tests link glibc, which has the target libc's (newlib-nano's) semantics,
so they need no lib832 emulation.

| Function | lib832 | ISO C / newlib | Observable? |
|---|---|---|---|
| `strncpy` | copies bytes up to and including the first NUL, or `n` bytes; **does not pad** the rest with NULs; `n == 0` copies nothing; returns `dst` | pads with NULs up to `n` | only if a byte after the NUL is read: see the call-site table |
| `strncmp`, `memcmp` | `n == 0` returns whatever `r0` holds (nothing sets it); otherwise the byte difference `a - b` as unsigned bytes (same sign as ISO) | `n == 0` returns 0 | only `fat.c:384` can call with `n == 0` (`strncmp(fileLFN, name, strlen(name))`, empty `name`): there `r0` still holds the result of `strlen(name)`, i.e. 0 (checked by compiling the 832 `fat.c` with vbcc832), so lib832 returns 0 too. Same |
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
| `strncpy` `config.c:62,150`, `hdd.c:892` (`filename`, 8, then `strcpy(&filename[8], "ROM"/"HDF")`) | The source is an 8-character space-padded name without NUL: exactly 8 bytes copied by both. A name with an early NUL (a corrupt config) would leave `filename` bytes uninitialised on the 832 and zero on RV; `FileOpen` then compares 11 bytes. Indeterminate on the 832: not emulated |
| `strncpy` `config.c:301,339,340,351,353,365` | An 8-character literal (`EXTENDED`, `MNMGCFGA`, `KICK    `, `HARDFILE`) into an 8-byte field: no NUL copied, nothing to pad. Same |
| `strncpy` `config.c:611` (`file.name`, 11) | `MINMGAA CFG` is 11 characters. Same |
| `strncpy` `cdrom.c:86`, `275` | `86`: the destination was zeroed by `memset` just before. `275`: `longname[41]`, read only as a NUL-terminated string (`atapi_insert`, `cd_config`). Same |
| `strncpy` `osd.c:1105,1108` (`ScrollText`) | Inside `len > max_len`: the source is longer than `n` in both copies (`n < max_len < len <= strlen`), so no NUL is copied and nothing is padded. Same |
| `strncpy` `fat.c:386` (`file->name`, 11) | `pEntry->Name` is 11 bytes of an 8.3 name, no NUL. Same |
| `strncpy` `fat.c:885,900,933,952,967,1000,1025,1047,1070,1088,1104,1137,1153,1192,1208` (`DirEntryLFN[..]`, `lfn`, 261) | Destination rows are `[261]`, set to NUL-terminated names and read only as strings (`strlen`, `strcmp`, `strcpy`, `strncpy(file.long_name, .., len)`, `ScrollText`); no `memcpy` of a row. The zero padding of up to 260 bytes per copied entry is never read. Same |
| `strncpy` `menu.c:348,350,717,2866,2867,2870,2874,2886` (the OSD line `s`) | Both copy the NUL at the same place; `OsdWrite` stops at the first NUL, so the bytes after it (spaces from the earlier `memset` on the 832, zeros on RV) are never drawn. For a long name shorter than 24 characters the NUL ends the line before the disk number (`2866/2867`) and before ` <DIR>` on both CPUs. Same |
| `strncpy` `menu.c:1369,1371,1372`, `2946,2953` | `file.name` 11 and `drive->name` 8 bytes from space-padded names: no NUL. `file.long_name` is zeroed by `memset` first (`1370`). `DiskInfo[5]` is `XX/XX` (5 characters, `GetDiskInfo`) or starts with NUL and is then not used (`menu.c:2950`). Same |
| `strncpy` `menu.c:3060` (`debuglines`) | The line is drawn by `OsdWrite`, which stops at the NUL. Same |
| `strncmp` (16: `config.c:287,295`, `drivesounds.c:445`, `fat.c:129,131,183,186,250,384 (x2),459,580`, `fpga.c:61,66`, `menu.c:1343,2140`) | `n` is a constant or `sizeof`, always > 0, and the result is compared with 0. Same |
| `strncmp` `fat.c:384` first call, `n = strlen(name)` | `name` empty (`n == 0`): lib832 returns `r0`, which still holds the `strlen(name)` result, 0 (vbcc832 output of the 832 `fat.c`); ISO returns 0. An empty name matches the first plain file entry on both. Same, no edit |
| `memcmp` (4: `cdrom.c:82,285`, `menu.c:393,2052`) | `n` = 3 or `sizeof`, > 0, compared with 0. Same |
| `strncat` (3: `menu.c:756` n = 17/21, `1759` 16, `1761` 8) | `n > 0`: at most `n` bytes then NUL on both; `kickstart.name` has no NUL (8 characters) and both copy exactly 8. Return value unused. Same |
| `strcat` (38), `strcpy` (54) | ISO on both; no return value is used. Same |
| `tolower` (6: `fat.c:629 x2, 1176 x2, 1178 x2`) | ASCII letters on both; the arguments are `unsigned char` values (`-funsigned-char`). Same |
| `strcmp` (1: `menu.c:168`), `strlen` (9), `memcpy` (35), `memset` (28) | ISO on both. Same |
| `memmove`, `strtol`, `strtoul`, `strtok`, `strspn`, `strcspn`, `toupper` | 0 call sites |

## Host tests

From a fresh Ubuntu 24.04 machine (works in zsh and bash), from the repository
root:

```sh
sudo apt install build-essential gcc-multilib python3 git mtools dosfstools fdisk
git submodule update --init EightThirtyTwo          # lib832, the 832 printf reference
make -C fw/ctrl_rv/test                             # every test, native and -m32, and the format gates
make -C fw/ctrl_rv/test mutants                     # every test must go red on its mutants
```

`swap_test` checks the byte-order helpers (memory order on any host, the
`rd_*`/`wr_*` forms at offsets 0..3 under UBSan, the legacy swaps without sign
extension); `fat_test` runs the real `fat.c` + `mmc.c` on three card images
(FAT16 with MBR, FAT32 with MBR, FAT16 superfloppy) against `mtools` and
`fsck.fat`; `mmc_test` runs the real `mmc.c` on the card model (`MMC_Init`'s
command sequence against the L2 boot run's SD log, token delays, busy, the
five `SD_TIMEOUT` bounds, the direct-mode trace `test/gold/dmode.txt`).
`fw/ctrl_rv/test/README.md` has the targets, the flags, the mock (an SPI/TIMER/UART
model with a card-image model; `-DHOSTTEST` hooks in `hardware.h` that leave
the target image byte for byte the same) and the mutant rules. `LIB832` is
`$(TOP)/EightThirtyTwo/lib832` by default; pass
`LIB832=/path/to/EightThirtyTwo/lib832` to use another checkout (EightThirtyTwo
pin `d1cd671`). A missing `LIB832` fails the run; the check is never skipped.
`lib_test` checks `rvlibc.c` against glibc's `vsnprintf` with a mock `putchar`
(equal output and return value, the truncation case, a `printf` issued from
inside `putchar`, the nesting count, the heap stubs). `make mutants` runs the
mutants of every test and of every register class of the I/O map; a mutant
counts as killed only when the real test target fails on a build that
succeeded.

### On the L1 bench

`fmt_rv` (`test/rv/fmt_rv.c`; `fmt_rv_subset` is the same source with `-DFMT_SUBSET=1`) is built by `sim/rv_l1/prog/Makefile` the way
the firmware will be linked (`--specs=nano.specs -nostdlib -nostartfiles`,
`crt0_l1.o` + `l1_newlib.ld`, no `syscalls.o`, `-lc_nano -lgcc` last). Besides
the format cases it runs newlib-nano's `memcpy`, `memmove` (overlapping both
ways), `memset`, `memcmp`, `strlen`, `strcmp`, `strncmp`, `strncpy`, `strncat`
at source and destination offsets 0..3 (lengths 0, 1, 3, 4, 5, 8, 9, 17) (VexRiscv traps a misaligned access:
the run would end `=== FAIL 80xx`), and prints `rv_libc_heap_calls` (must be 0).

```sh
bash tools/riscv/fetch-xpack.sh
bash tools/riscv/check-toolchain.sh
SIM=verilator RUNTAG=p3t3b bash sim/rv_l1/run.sh fmt                    # all 909 cases, 25 s
FMT_SUBSET=1 SIM=verilator RUNTAG=p3t3s bash sim/rv_l1/run.sh fmt       # subset, 10 s
FMT_SUBSET=1 RUNTAG=p3t3i bash sim/rv_l1/run.sh fmt                     # iverilog (X reference), ~38 min
bash sim/rv_l1/run.sh compare p3t3i p3t3s
```

Verilator needs `sudo apt install verilator g++`; Icarus Verilog 12 is
described in `sim/rv_l1/README.md`. `run.sh fmt` also checks that
`fmt_rv.map` has no `_sbrk`, `_sbrk_r`, `__sinit`, `__sfp`, `_write`, and that
`_malloc_r`, `_realloc_r`, `_free_r` come from `rvlibc.o`.

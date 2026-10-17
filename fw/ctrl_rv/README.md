# fw/ctrl_rv - OSD / host firmware for the VexRiscv host CPU

Port of `fw/ctrl_832` (ZPU-class 832 host CPU) to RV32IMC. Task 2 made the
**verbatim copy**; from then on `diff -ru fw/ctrl_832 fw/ctrl_rv` is exactly
the port. Edits so far: Task 3's call-site edits ("Differences from
fw/ctrl_832") and the C library / host-test files ("C library", "Host tests").

## Copy base

Copied from `fw/ctrl_832` at osd-riscv HEAD `2f5df34c9821fef3d9a4101fe649f9c954a3e482`
(last change to `fw/ctrl_832`: `8f8cf88`).

## What was copied

- The 29 units of the 832 Makefile's `COMMON_SOURCES` (`.c` and `.h`):
  hardware config fat fdd fpga boot hdd main menu mmc spi osd rafile swap
  hexdump uart errors interrupts c64keys akiko audio drivesounds rtc i2c
  adv7511 atapi cdrom cue cdaudio.
- Headers without a unit: `amiga_rawkey.h charrom.h logo.h minimig_cfg.h
  hdd_internal.h firmware.h bootcustominit.h`, and `bootcustominit.s`.
- `test/*.c`, `test/Makefile`, `test/.gitignore` (unchanged for now) and
  `test/emu/*.c` (the three emu programs, used by L1 `units`).

`arch/` is Phase 2 / Task 1 (crt0, trap, irq, `arch.mk`) and is not part of
the copy.

## What was not copied, and why

- `version.h`: generated into `build/` from Task 4 on, never tracked here.
- `Makefile`: vbcc; replaced in Task 4.
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
`test/Makefile`, `test/.gitignore` (the C-library wiring). `find` also lists
files that only exist here (`rvlibc.c`, `rvlibc.h`, `test/lib_test.c`,
`test/fmt_*`, `test/mutants.sh`, `test/gold/`, `test/rv/`); `cmp` reports
those as missing in `fw/ctrl_832`.

## Building

Nothing builds as firmware yet; the RISC-V Makefile arrives in Task 4 (the C
library and its tests build today: see "C library", "Host tests"). The toolchain
setup it will need, from a fresh Ubuntu 24.04 machine:

```sh
sudo apt install build-essential git python3
bash tools/riscv/fetch-xpack.sh
bash tools/riscv/check-toolchain.sh
```

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

Gates (`make -C fw/ctrl_rv/test fmt.ok`, part of `lib_test`, and `run.sh fmt`):

1. `fmt_glibc` native == `-m32`;
2. `fmtcheck.py diff fmt_832.txt fmt_glibc_64.txt` == `test/gold/fmt_diff_expected.txt`
   exactly (413 lines: 278 case lines and 135 `RET` lines);
3. on the L1 bench, `fmt_rv.txt` == `fmtcheck.py digest fmt_glibc_64.txt`. A
   case costs about 30,000 cycles on the target and iverilog simulates about
   7,000 cycles a second, so `fmt_rv` runs the **first and the last case of
   every run of equal format strings** (272 of the 909 cases: the zero/empty
   value and the extreme one, 544 records) and prints one 32-bit FNV-1a
   digest per record instead of the text (`FMT <n> S h=<hex>`); the host runs
   all 909 with the full text. Gate 3 makes glibc's text stand in for newlib-nano's
   for gate 2, as the host tests need: every firmware format string
   run on the target libc gives what glibc gives, for the cases on the target.

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
| String and memory functions | lib832 `string.S` | newlib-nano; no observable difference at any call site except `fat.c:384` (next table; "String semantics audit") |

Call-site edits to the copied `fw/ctrl_rv/*.c` made by Task 3 (everything else
is verbatim):

| File:line | 832 | RV | Why |
|---|---|---|---|
| `akiko.c:17,19`, `config.c:614`, `drivesounds.c:457`, `fat.c:783,790,1647,1649`, `main.c:175`, `menu.c:1595,2663,2665,3040,3042,3044,3046,3048,3050,3052` | `%x`, `%04x`, `%08lx`, `%lx` | `%X`, `%04X`, `%08lX`, `%lX` | `UPPER`: keeps the UART/OSD text identical |
| `boot.c:263` | `printf(str)` | `printf("%s", str)` | `str` is data (a file name, `rtl_ver`): a `%` in it would be taken for a conversion with garbage arguments, and the two libraries differ on that. Identical for every string without `%` |
| `fat.c:384` | `strncmp(fileLFN, name, strlen(name)) == 0 \|\| ...` | `(name[0] && strncmp(fileLFN, name, strlen(name)) == 0) \|\| ...` | `strncmp(.., .., 0)`: lib832 returns whatever was in `r0`; ISO returns 0 (match any entry). An empty name (`FILE ""` in a CUE sheet) must not match; see the string table |

## String semantics audit

lib832 (`string.S`, `string_c.c`, `stringstubs.c`, `include/string.h`,
`string_asm.h` at EightThirtyTwo `d1cd671`) read against ISO C / newlib. The
host tests link glibc, which has the target libc's (newlib-nano's) semantics,
so they need no lib832 emulation.

| Function | lib832 | ISO C / newlib | Observable? |
|---|---|---|---|
| `strncpy` | copies bytes up to and including the first NUL, or `n` bytes; **does not pad** the rest with NULs; `n == 0` copies nothing; returns `dst` | pads with NULs up to `n` | only if a byte after the NUL is read: see the call-site table |
| `strncmp`, `memcmp` | `n == 0` returns an uninitialised `r0`; otherwise the byte difference `a - b` as unsigned bytes (same sign as ISO) | `n == 0` returns 0 | `strncmp(.., .., strlen(name))` with an empty `name`: `fat.c:384`, fixed at the call site |
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
| `strncpy` `menu.c:3058` (`debuglines`) | The line is drawn by `OsdWrite`, which stops at the NUL. Same |
| `strncmp` (16: `config.c:287,295`, `drivesounds.c:445`, `fat.c:129,131,183,186,250,384 (x2),459,580`, `fpga.c:61,66`, `menu.c:1343,2140`) | `n` is a constant or `sizeof`, always > 0, and the result is compared with 0. Same |
| `strncmp` `fat.c:384` first call, `n = strlen(name)` | `name` empty: lib832 returns an indeterminate value, ISO 0. Edited: `name[0] && ...` (no match for an empty name) |
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
sudo apt install build-essential gcc-multilib python3 git
git submodule update --init EightThirtyTwo          # lib832, the 832 printf reference
make -C fw/ctrl_rv/test lib_test lib_test_32
./fw/ctrl_rv/test/lib_test && ./fw/ctrl_rv/test/lib_test_32
make -C fw/ctrl_rv/test mutants
```

`make -C fw/ctrl_rv/test lib_test` first runs the format-parity gates (above)
and fails when they are red. `make -C fw/ctrl_rv/test` runs all host tests,
including `lib_test` natively and `-m32`. `LIB832` is `$(TOP)/EightThirtyTwo/lib832`
by default; pass `LIB832=/path/to/EightThirtyTwo/lib832` to use another
checkout (EightThirtyTwo pin `d1cd671`). A missing `LIB832` fails the build;
the check is never skipped. `lib_test` checks `rvlibc.c` against glibc's
`vsnprintf` with a mock `putchar` (equal output and return value, the
truncation case, a `printf` issued from inside `putchar`, the nesting count,
the heap stubs). `make mutants` runs 9 mutants (a 16-byte print buffer, a format without a case and a
deleted line of the expected list turn the format-parity checks red; six
changes to `rvlibc.c` turn `lib_test` red); the full harness's `mutants`
target comes with Task 8.

### On the L1 bench

`fmt_rv` (`test/rv/fmt_rv.c`, 13.0 M cycles: about 9 s on Verilator, about 30 minutes on iverilog) is built by `sim/rv_l1/prog/Makefile` the way
the firmware will be linked (`--specs=nano.specs -nostdlib -nostartfiles`,
`crt0_l1.o` + `l1_newlib.ld`, no `syscalls.o`, `-lc_nano -lgcc` last). Besides
the format cases it runs newlib-nano's `memcpy`, `memmove` (overlapping both
ways), `memset`, `memcmp`, `strlen`, `strcmp`, `strncmp`, `strncpy`, `strncat`
at source and destination offsets 0..3 (lengths 0, 1, 3, 4, 5, 8, 9, 17) (VexRiscv traps a misaligned access:
the run would end `=== FAIL 80xx`), and prints `rv_libc_heap_calls` (must be 0).

```sh
bash tools/riscv/fetch-xpack.sh
bash tools/riscv/check-toolchain.sh
SIM=verilator RUNTAG=p3t3 bash sim/rv_l1/run.sh fmt       # Verilator, about a minute
RUNTAG=p3t3i bash sim/rv_l1/run.sh fmt                    # iverilog, the X-checking reference
bash sim/rv_l1/run.sh compare p3t3i p3t3
```

Verilator needs `sudo apt install verilator g++`; Icarus Verilog 12 is
described in `sim/rv_l1/README.md`. `run.sh fmt` also checks that
`fmt_rv.map` has no `_sbrk`, `_sbrk_r`, `__sinit`, `__sfp`, `_write`, and that
`_malloc_r`, `_realloc_r`, `_free_r` come from `rvlibc.o`.

# OSD host CPU -> VexRiscv: executable plan, stage 3 (Phase 3 -- firmware 1:1, host tests, LE config)

**Goal.** Port the OSD firmware `fw/ctrl_832` (vbcc832, big-endian, ~14,400
lines incl. CD-ROM/ATAPI/CUE/CD audio) 1:1 to the RISC-V host CPU as a new C
tree `fw/ctrl_rv` that builds `RV32OSDA.BIN` with the pinned xPack gcc, boots
from the committed RISC-V boot ROM on the L2 bench to its main loop, and is
covered module by module by host-native tests with goldens that do not come
from the code under test. The config file becomes little-endian under its own
RISC-V file names, with a host converter and a one-time conversion of an 832
config on first boot (the 832 file is never written). The phase ends at a gate
from which Phase 4 (L3 co-simulation of floppy, HDD and CD against the 832)
starts; the list of what Phase 4 consumes is at the end. Parent plan:
`doc/osd-riscv-plan.md` (sections 5, 6.2, 7.1, 7.3, 8 Phase 3/4; Paul's
decisions in section 12, binding: 12.4 config, 12.6 debug, 12.10 one CPU per
bitstream, 12.11 C and 1:1). Stages before this one: `doc/osd-riscv-exec-1.md`
(Phases 1-2), `doc/osd-riscv-exec-2.md` (Phase 8.0 and the Verilator
backends).

"1:1" (plan, top): the same features and behaviour for the user, on today's
hardware interface, polling, the 832 bitstream (`build/stage_spicdc_49b1868`)
as the reference. Not the same bytes: wherever the port must differ (I/O
offsets, byte order, config names, timeouts converted from counts, vbcc
workarounds), the difference is listed in `fw/ctrl_rv/README.md` section
"Differences from fw/ctrl_832" in the commit that makes it.

**Architecture summary.** `fw/ctrl_rv/` = a verbatim copy of the built part of
`fw/ctrl_832` (Task 2, one commit, so every later change is a reviewable
`diff -ru fw/ctrl_832 fw/ctrl_rv`), plus the Phase 2 `arch/` (crt0, trap entry,
legacy interrupt API) and a small C library `lib/` that reproduces lib832's
`printf`/string semantics. Byte-order helpers `le16/le32/be16/be32` replace the
"for 68000" swaps (identity on LE disk fields) and make every Amiga-facing
structure explicit big-endian. Tests: `fw/ctrl_rv/test` (host gcc, native and
`-m32`, ASan/UBSan, an SPI/TIMER/card mock under `-DHOSTTEST`, goldens from
independent Python generators), L1 `units` on `fw/ctrl_rv` sources, and a new
L2 target `fwboot` that boots the real firmware from the SD-card model through
the committed boot ROM, with a bench stub for the minimig SPI slaves (Phase 4
replaces the stub with the real slaves).

## Global Constraints (binding for every task)

| Item | Value |
|---|---|
| Earlier constraints | Everything in `doc/osd-riscv-exec-1.md` "Global Constraints" as corrected (worktree/branch `osd-riscv`, one commit per task with only its files, never stage `fw/ctrl_832/version.h`, `*.wcfg`, `tools/vivado/ila_fastram_check.py`; commit message ends with the implementer's `Co-Authored-By` line; tools; CPU byte memory map incl. the interrupt controller `0xFFFFFF3x`; lane rule; bus contract; toolchain pin; vendor-neutral rule; run directories) and `doc/osd-riscv-exec-2.md` (interrupt controller semantics, Verilator backends). Nothing of this branch goes to `5.0-040-pipelined` until board-verified (Phase 5.3). |
| Scope | `fw/ctrl_rv/**`, `sim/**` benches, `tools/sim/**`, `doc/**`. **No change under `rtl/`** in Phase 3 (if the port seems to need one, stop and report). `fw/ctrl_832`, `fw/ctrl_boot_832`, `fw/dhrystone_832` are read-only (benches and tests may read them). `fw/ctrl_boot_rv` and its committed `OSDBoot_rv_ROM.vhd` stay unchanged. |
| Copy base | Task 2 copies `fw/ctrl_832` as it is at the `osd-riscv` HEAD when Task 2 runs (last `fw/ctrl_832` change today: `8f8cf88`); the commit hash goes into `fw/ctrl_rv/README.md`. A fix that must land in both trees during the port is two commits that name each other (plan 3.7). |
| C dialect and flags | Firmware: `$(RV_CFLAGS_FW) -std=gnu17` (gcc 15 defaults to gnu23, where `f()` means `f(void)` and `true`/`false` are keywords: `firmware.h` defines `true` as -1) plus `-g -I. -Iarch -Ilib`; from Task 7 on `-Wall -Wextra -Werror`. Link: `$(RV_LDFLAGS_FW) -nostartfiles -T arch/firmware.ld -Wl,--no-warn-rwx-segments -Wl,-Map,...` with `$(RV_LIBS_FW)` (`-lgcc`) **last** on the line. All RISC-V Makefiles include `tools/riscv/toolchain.mk` and (from Task 1) `fw/ctrl_rv/arch/arch.mk`. Output in `fw/ctrl_rv/build/` (gitignored): `RV32OSDA.BIN` (`objcopy -O binary`), `.elf`, `.map`, `.lst`. |
| I/O map (plan 5.3) | Every firmware register at offset 0 of its 16-byte window, CPU addresses `0xFFFFFFx0`: SPI DATA `0xFFFFFFE0` (8-bit), CS `0xFFFFFFE4`, SPEED `0xFFFFFFE8`; UART TX `0xFFFFFFF0` (8-bit, write only); TIMER `0xFFFFFFD0` (16-bit); PLATFORM `0xFFFFFFC0` (16-bit); AUDIO `0xFFFFFFB0` (8-bit); INTERRUPT `0xFFFFFFA0` (32-bit); keyboard `0xFFFFFF90` + 0/4/8/0xC (words 0..3), `REG_KEYBOARD_OUT` + 0; Akiko `0xFFFFFF80` + 0 (ADDR) / 4 (DATA); RTC base `0xFFFFFF70`; I2C `0xFFFFFF60` (32-bit, as today); VIDEOSCALE `0xFFFFFF50` (32-bit); `FPGA_TEMP_RAW` `0xFFFFFF40` (16-bit). `RECONFIGURE` (`0xDEE016`) is kept as the 832 has it (an unmapped cfide window on this core; a halfword store, aligned). The 832's `0x0FFFFFxx` bases become `0xFFFFFFxx` (x0-relative 12-bit offsets). |
| UART | Write only. cfide never acks a read of `0xFFFFFFF0` (the CPU deadlocks). No firmware file may read it: `uart.h` has no RX, no `REG_UART_TXREADY`, no `getserial`; `make -C fw/ctrl_rv check` greps the disassembly for any load from `-16(zero)` and fails. |
| Interrupts | Phase 3 uses only the legacy path of `fw/ctrl_rv/arch/irq.h` (`SetIntHandler`, `EnableInterrupts`, `DisableInterrupts`, `GetInterrupts`; `0xFFFFFFA0`), exactly as the 832 (`inthandler()` in `main.c`). No `IrqInstall/IrqEnable/IrqSetMode` (Phase 8). Nothing in Phase 3 depends on `irq_src` bits 4..15; the P1 rule (sources are pulses of at least one `clk_28` cycle or levels) is Phase 8's. The firmware does not override `rv_exception` (the arch default prints `EXC mcause=.. mepc=.. mtval=..` and spins; no OSD message from a trap: it may hit mid-SPI-transfer). |
| TIMER | One count = 256 x 643 `clk_28` = **5.804 ms** on the board, the same for both CPUs (cfide `timecnt(23 downto 8)`, `tick_in` 44.1 kHz). The firmware's nominal "ms" arguments (`WaitTimer(1000)` = 5.8 s) are kept as they are: parity, not a fix. The L2 bench holds `tick_in = 1`: TIMER runs **643x fast** there (one count = 256 `clk_28` = ~9.0 us), so timeouts in L2 are 643x shorter in simulated time; a test that depends on a timeout length says so. |
| No new count-based delays (plan 7.1 item 11) | No new `SPIN`, empty counted loops or `timeout++` bounds. The live `SPIN` sites stay exactly three: `SPI_reply()` (`hardware.c`, 4 x `SPIN`, 174322f, OSD reply rule below), `fpga_init()` after the version read, `config.c:548`. The commented `SPIN`s in `fdd.c` stay commented. Gate in Task 20: `git diff <Task-2 commit> -- fw/ctrl_rv | grep '^+' | grep -nE 'SPIN|for *\([^;]*;[^;]*;[^)]*\) *;|timeout\+\+'` lists nothing but lines that Task 10 replaced. |
| OSD reply rule | `userio_osd` loads a reply byte on its `clk7_en` grid after the previous transfer; the host needs >= 40 `clk_114` between the accesses of an OSD reply read (`sim/spi_cdc/tb_spi_cdc.v` `+GAP`, `OSD_MIN_GAP=40`; below it `OSD_CMD_VERSION` fails 3/3 in every skew corner). `SPI_reply()`'s four `SPIN`s (each a TIMER read through the four-phase hw handshake, i.e. bounded by cfide's `clk_28` handshake, not by CPU speed) stay; Task 6 measures the RV figure in L2 and Phase 4 re-checks it against the real `userio_osd` (plan 7.1 item 2, open until P1). |
| Byte order | Helpers in `fw/ctrl_rv/swap.h`: `le16/le32` (identity when `__BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__`), `be16/be32` (swap on LE), `rd_le16/rd_le32/rd_be16/rd_be32(const void *)` and `wr_be16/wr_be32(void *, v)` (byte-wise: safe at any alignment). Disk/Amiga data at a possibly misaligned address is always read byte-wise (VexRiscv traps misaligned accesses: `mcause` 4/6). Buffers that structs are overlaid on are `__attribute__((aligned(4)))`. |
| Host tests | `make -C fw/ctrl_rv/test` is the single entry point (exit status = result). `gcc -std=c99 -D_DEFAULT_SOURCE -DHOSTTEST -Wall -Wextra -Wno-unused-parameter -Werror -O1 -g -fsanitize=address,undefined -fno-sanitize-recover=all`, each test built and run twice: native (LP64) and **`-m32`** (ILP32 like RV32: the firmware's `unsigned long` is 32 bits; `config.c` asserts `sizeof(configTYPE) == 212`). Every new test has a mutant check (`make -C fw/ctrl_rv/test mutants`: a sed on a run copy of the unit that must turn the test red). Goldens come from independent generators (`fw/ctrl_rv/test/gold/*.py`, python3 stdlib only, run with `python3 -I`) or, where the 832 code is byte-level, from the **`fw/ctrl_832` source compiled for the host** with the same mock -- never from the code under test. |
| Simulators | Long runs (`fwboot*`, L1 `units`) on Verilator (`SIM=verilator`); xsim (L2) / iverilog (L1) stay the X-checking reference: every new L2 target also passes once on xsim, and `run.sh compare` of the two run directories reports SAME. One xsim at a time. A new RUNTAG per code change. |
| Sizes | `_start == 0x2000` and `_end < 0x70000` (`AUDIO_BUFFER`) are linker ASSERTs in `arch/firmware.ld`. Stack: top 0x2000, grows into the boot BRAM; Task 17's gate keeps it above **0x1400** (the boot ROM image ends below it, so a soft re-run of the boot ROM stays possible -- exec-1 final review, "Declined to judge"). |
| README rule (Paul) | Every README a task creates or changes gives copy-pasteable commands from a fresh Ubuntu 24.04 machine, toolchain setup included (`bash tools/riscv/fetch-xpack.sh`, `bash tools/riscv/check-toolchain.sh`, apt packages by name), and works in zsh and bash (Paul's shell is zsh: no unquoted word-splitting of variables). |

### Endianness audit (plan 5.2) -> tasks

| 5.2 item | What | Task |
|---|---|---|
| "flips" | `fat.c` `SwapBB/SwapBBBB` on FileSize/StartCluster/HighCluster/FAT links/dates, `SwapPartitionBytes` (the MBR signature switch keeps both branches: on LE the `0xaa55` branch is taken), FAT32 EOC literal `0xFFFFFF0F` (`fat.c:1614`, written "for 68000") | 9 |
| 1 | `hdd.c` RDB/PartitionBlock synthesis (`FakeRDB`), `RDBChecksum` over BE longs | 12 |
| 2 | `hdd.c` `IdentifyDevice`: **correction** -- `ATA_IdentifyDevice` already sends every word low byte first from its value (endian-neutral); only the `memcpy`'d string words (serial, firmware, model, file name) change byte order on LE and get a 16-bit swap | 12 |
| 3 | `boot.c` default copper list -> `be16` | 14 |
| 4 | `drivesounds.c`: the per-sample byte swap, plus (new) the `DRIVESND` header longs read with `*(long *)` at `2 mod 4` addresses (sound sizes are even, not multiples of 4: `sw/mkdrivesounds/drivesnd.bin`, first size 0x577a) -- misaligned on RV -- and BE sample words | 14 |
| 5 | config file: LE layout, own file names, `cfgconv`, first-boot conversion, wrong byte order rejected by `version` | 11 |
| 6 | `firmware.h` `UPGRADE`/`CheckFirmware`/`WriteFirmware`: declared, never defined or called (dead) | 14 |
| 7 | struct overlays: `fat.c:137` `MasterBootRecord` (9), `hdd.c:90/131` (12), `hdd.c:524` RDB patch of an HDF's own RDB (12), `config.c:275` (11) | 9, 11, 12 |
| 8 | misaligned multi-byte accesses: MBR partition entries (`fat.c` copies them with `memcpy` first: verify), `uart.c` `puts` and lib832 `small_printf` reading strings as 32-bit words and taking bytes with `>> 24` (new: BE-only and misaligned for an unaligned string), drivesounds headers (4) | 3, 5, 9, 14 |
| new | `main.c` `CheckSum` (kickstart checksum `checksum_pre`, shown by the menu): summed over native words, so the shown value would differ from the 832's -> sum `be32` words; `hexdump.c` prints native 32-bit words -> print the 832's (BE) view | 14 |
| 9 | anything else: L3 differential traces | Phase 4 |

---

### Task 1: One shared build fragment for `fw/ctrl_rv/arch` (`arch.mk`) and one hex rule

- **Phase / depends on:** plan 3.1 groundwork (exec-1 final review Minor 6, "before a fifth copy appears") / none.
- **Model:** Sonnet.
- **Files:** create `fw/ctrl_rv/arch/arch.mk`, `tools/riscv/bin2hex.sh`; modify
  `sim/rv_l1/Makefile`, `sim/host_bridge/Makefile`, `sim/host_bridge/boot/Makefile`,
  `fw/dhrystone_rv/Makefile`, `fw/ctrl_rv/arch/README.md` ("Linking firmware"
  becomes "include arch.mk").
- **Interfaces:** `arch.mk` (included after `toolchain.mk`, needs `TOP` and a
  build directory variable `ARCH_B`) defines `ARCH := $(TOP)/fw/ctrl_rv/arch`,
  `ARCH_OBJS := $(ARCH_B)/arch/crt0.o $(ARCH_B)/arch/trap_entry.o $(ARCH_B)/arch/trap.o $(ARCH_B)/arch/irq.o`,
  their rules with header dependencies (`-MMD -MP`, `-include` of the `.d`
  files: closes ledger "L1 test objects lack arch header deps"), and
  `ARCH_LDFLAGS := -nostartfiles -T $(ARCH)/firmware.ld -Wl,--no-warn-rwx-segments`.
  `bin2hex.sh <in.bin> <out.hex>`: one BE word per line, file byte i in lane i
  (the `od | awk` rule now copied three times; zero-pad the last word).
  `fw/dhrystone_rv` builds its board/L1 objects in its own `build/`, no longer
  in `sim/rv_l1/build/`.
- **Test first:** before editing, build every consumer and keep the outputs
  (`sha256sum` of every `.bin`/`.hex` the four Makefiles produce, and the
  `.lst` files) in the scratchpad.
- **Steps:** write `arch.mk` and `bin2hex.sh`; switch the four Makefiles;
  rebuild from clean; compare.
- **Commands:**
  `make -C sim/rv_l1 tests && make -C sim/rv_l1/prog && make -C fw/dhrystone_rv && make -C sim/host_bridge/boot && SIM=verilator RUNTAG=p3t1 bash sim/rv_l1/run.sh all && SIM=verilator RUNTAG=p3t1 bash sim/host_bridge/run.sh all && SIM=verilator RUNTAG=p3t1b bash sim/host_bridge/run.sh boot`
- **Pass gate:** every rebuilt `.bin`/`.hex` byte-identical to the baseline
  (only paths in `.map` files may differ); L1 `all` and L2 `all`/`boot` PASS;
  `grep -rn 'od -An -v -tx1' sim fw/dhrystone_rv` finds nothing outside
  `tools/riscv/bin2hex.sh`; touching `fw/ctrl_rv/arch/irq.h` rebuilds
  `irq.o` in every consumer (shown with `make -n`).

### Task 2: Verbatim copy `fw/ctrl_832` -> `fw/ctrl_rv`

- **Phase / depends on:** plan 3.1 / Task 1.
- **Model:** Sonnet.
- **Files (create):** in `fw/ctrl_rv/`: every `.c`/`.h` that the 832
  `Makefile`'s `COMMON_SOURCES` builds or includes (29 units: hardware config
  fat fdd fpga boot hdd main menu mmc spi osd rafile swap hexdump uart errors
  interrupts c64keys akiko audio drivesounds rtc i2c adv7511 atapi cdrom cue
  cdaudio, their headers, `amiga_rawkey.h charrom.h logo.h minimig_cfg.h
  hdd_internal.h firmware.h bootcustominit.h bootcustominit.s`), `test/*.c`,
  `test/Makefile` (unchanged for now), `test/emu/*.c` (the three emu
  programs, used by L1 `units`); `fw/ctrl_rv/README.md` (new: source commit,
  file list, what was not copied and why), `fw/ctrl_rv/.gitignore` (`build/`,
  `test/` binaries).
- **Not copied (record in README):** `version.h` (generated into `build/`
  from Task 4 on, never tracked in this tree), `Makefile` (vbcc; replaced in
  Task 4), `Makefile.68k`, `startup_m68k-elf.s`, `startup_zpu-elf.s`,
  `osd_m68k-elf.ld`, `osd_zpu-elf.ld` (68k/ZPU leftovers),
  `small_printf.c`/`small_printf.h`/`printf.c` of the firmware tree (not in
  `COMMON_SOURCES`: the 832 links lib832's `printf`; Task 3 ports that one),
  `test/emu/Makefile` (vbcc832 + 832e; 832-only).
- **Test first:** a script line that proves the copy: for every copied file
  `cmp fw/ctrl_832/<f> fw/ctrl_rv/<f>`.
- **Steps:** copy; README; `.gitignore`; nothing else (no edits, so Task 4+
  diffs are the whole port).
- **Commands:** `(cd fw/ctrl_rv && find . -path ./arch -prune -o -type f ! -name README.md ! -name .gitignore -print) | while read -r f; do cmp "fw/ctrl_832/$f" "fw/ctrl_rv/$f" || echo "DIFF $f"; done`
  (works in zsh and bash)
- **Pass gate:** no `DIFF` line; `git status fw/ctrl_832` clean; the existing
  benches are unaffected (nothing includes the new files yet; `make -C
  sim/rv_l1/prog` still uses `FWDIR=fw/ctrl_832` until Task 15).

### Task 3: `fw/ctrl_rv/lib` -- lib832's printf and string semantics in plain C

- **Phase / depends on:** plan 3.1/3.7 ("lib832's `string.S` becomes plain C") / Task 2.
- **Model:** Sonnet.
- **Why lib832 and not newlib-nano:** the firmware relies on lib832's
  behaviour (e.g. `menu.c:752`: "lib832's printf has no precision", so the
  code uses `strncat`); the same formatter keeps every UART/OSD string
  identical to the 832's, which the Phase 4 differential compares.
- **Files (create):** `fw/ctrl_rv/lib/small_printf.c` (from
  `EightThirtyTwo/lib832/small_printf.c`: `printf`, `vprintf`, `sprintf`,
  `snprintf`, `vsprintf`, the `_cvt`/`_pfputs` helpers; `putchar` comes
  from `uart.c`), `fw/ctrl_rv/lib/string.c` (C versions of lib832
  `string.S`, `string_c.c`, `stringstubs.c`: `memcpy memmove memset memcmp
  strcpy strncpy strcat strncat strcmp strncmp strlen tolower toupper strspn
  strcspn strtok strtok_r strtol strtoul`, byte loops, no word tricks),
  `fw/ctrl_rv/lib/{stdio.h,string.h,ctype.h,stdlib.h}` with exactly the
  prototypes the firmware uses (`stdarg.h`/`stddef.h`/`stdint.h` come from
  gcc's freestanding headers), `fw/ctrl_rv/lib/COPYING.LESSER`
  (lib832's licence, LGPL 2.1; the README says which files are derived and
  from which EightThirtyTwo commit: `git -C EightThirtyTwo rev-parse HEAD`
  in the main checkout), `fw/ctrl_rv/test/lib_test.c`.
- **Rules:** keep lib832's semantics where they differ from ISO C and list
  each difference in the README (read `string.S` for `strncpy` padding,
  `strncat` count, `memcmp` sign, the return values; read `small_printf.c` for
  the conversions it supports: `%d %u %x %s %c %l..`, width, zero fill, no
  precision). The 32-bit-chunk string reading of the old ROM-loadb workaround
  (if present in lib832's file) becomes a byte loop. No `__geta4`/vbcc
  pragmas.
- **Test first (`lib_test.c`, host, native and `-m32`):** (1) every string
  function against glibc on random inputs (lengths 0..64, all offsets 0..3,
  overlapping `memmove`) except the documented lib832 differences, which are
  tested against their own expectation; (2) every format string used in
  `fw/ctrl_rv/*.c` (`grep -ho '"[^"]*%[^"]*"' fw/ctrl_rv/*.c | sort -u` into
  `test/gold/formats.txt`) with representative arguments, the RV copy against
  **lib832's original `small_printf.c` compiled for the host** (it is C; a
  shim provides `putchar` into a buffer) -- byte-identical output. Mutant:
  `strncpy` without its padding (or whatever lib832 does) fails (1).
- **Commands:** `make -C fw/ctrl_rv/test lib_test && ./fw/ctrl_rv/test/lib_test`
  (the Makefile wiring is minimal here; Task 8 folds it into the harness).
- **Pass gate:** `lib_test` PASS native and `-m32`; mutant FAIL; the lib
  compiles for RV with `$(RV_CFLAGS_FW) -std=gnu17 -Wall -Wextra -Werror`.

### Task 4: RV Makefile and the gcc build of the firmware (compile fixes only)

- **Phase / depends on:** plan 3.1 + the gcc part of 3.2 / Tasks 1-3.
- **Model:** Sonnet; Opus reviews the two parenthesis fixes and the
  constructor order.
- **Files:** create `fw/ctrl_rv/Makefile`; modify the copied sources only as
  listed; delete `fw/ctrl_rv/interrupts.c` and `interrupts.h` (replaced by
  `arch/irq.c`/`irq.h`; the copied `#include "interrupts.h"` lines become
  `#include "irq.h"`); README "Differences".
- **Makefile:** includes `toolchain.mk` and `arch/arch.mk`; flags per Global
  Constraints (warnings not yet fatal: `-Wall` only, Task 7 makes the tree
  clean); `version.h` generated into `build/` (the 832 recipe, `MM_VERSTRING
  "$VER:AMR<yymmdd>-RV"`, `MM_FIRMWARE_VERSION` as there), never in the
  source directory; `bootcustominit.h` used as committed (rebuild with
  `vasmm68k_mot` + `xxd` only if `bootcustominit.s` is newer and vasm exists,
  as `fw/ctrl_boot_rv` does for `bootdiag.h`); `B ?= build` (output
  directory) and `EXTRA_CFLAGS ?=` (bench variants; empty for the shipped
  image); targets `all`
  (`build/RV32OSDA.BIN`), `size` (`$(RV_SIZE)` + bytes of the .BIN), `check`
  (below), `clean`. `check`: (a) no `lr.w/sc.w/amo*.w` in the disassembly;
  (b) no load from `-16(zero)` (UART read); (c) every load/store with
  `(zero)` as base and an offset in -256..-1 has `offset % 4 == 0` (all
  registers at offset 0, 4, 8 or 0xC of a window -- turns red until Task 5,
  so `check` is introduced here but listed as expected-red in the README
  until then); (d) no `__geta4`, `__constructor`, `setstack`, `c_entry` left
  in `fw/ctrl_rv/*.[ch]`.
- **Source fixes (each a minimal edit, each listed in the README):**
  - `-std=gnu17` (not gnu23: `firmware.h` `#define true -1`, and `f()`
    prototypes).
  - Prototype mismatches gcc rejects: `drivesounds_enable/disable` (header
    `()` vs definition `(int)`), `ShowError` (`menu.c:2987`),
    `FindDirectoryByCluster` (`fat.c:473`), implicit `puts`.
  - Integer -> pointer initialisations: `AUDIO_BUFFER`, `HOSTMAP_ADDR`
    arithmetic (`config.c:41,50`, `boot.h:15` `SCREEN_ADDRESS` passed to
    `BootClearScreen`, `hardware.h:33` users): explicit casts, same address.
  - Two **missing closing parentheses that vbcc832 accepted** (they are
    real syntax errors, not macro trouble): `hdd.c:518` `while(blk &&
    (((lba+hdf[unit].offset)<0) || (...))` and `drivesounds.c:380` `if
    ((drivesounds.enabled & DRIVESOUNDS_FLOPPY)`: add the `)` that makes the
    evident intent (`blk && (A || B)`; `(enabled & FLOPPY)`), and state in
    the commit message that this is the reading vbcc compiled (Opus checks it
    against the surrounding logic and, if in doubt, against the 832 assembly
    `vbcc832 -S` output from the main checkout's `EightThirtyTwo/vbcc`).
  - `__constructor(100.interrupts)` is gone with `interrupts.c`
    (`arch/irq.c` installs the default handler at priority 101);
    `__constructor(101.akiko)` -> `__attribute__((constructor(102)))`,
    `__constructor(101.c64keys)` -> `constructor(103)`: the 832 order
    (interrupts, then the two at 101 in name order, akiko before c64keys).
  - `main.c`: the `#ifdef __GNUC__ void c_entry(void)` branch becomes `int
    main(void)` (crt0 calls it), `setstack()` and its prototype go (crt0 set
    `sp`), `__geta4` defined empty is no longer needed.
- **Test first:** `make -C fw/ctrl_rv 2>&1 | grep -c error` is non-zero on
  the pure copy (record the list: it must match the fixes above, otherwise
  extend the list in the README).
- **Commands:** `make -C fw/ctrl_rv clean all size && make -C fw/ctrl_rv check || true`
- **Pass gate:** `build/RV32OSDA.BIN` links (the linker ASSERTs hold);
  `check` (a), (b), (d) pass; size recorded in the README next to the 832's
  83,830 B (plan estimate 85-95 KB); `git status fw/ctrl_832` clean; the
  constructor order is visible in `.init_array` of the map (irq 101, akiko
  102, c64keys 103).

### Task 5: I/O offsets (plan 5.3), UART write-only, register-map test

- **Phase / depends on:** plan 3.2 (I/O offsets) / Task 4.
- **Model:** Sonnet.
- **Files:** modify `fw/ctrl_rv/hardware.h`, `uart.h`, `uart.c`, `akiko.h`,
  `c64keys.h`, `rtc.h`, `i2c.h`, `spi.h` (dead `#if 0` block stays), any
  other `0x0fffff..` user (`grep -n '0x0fffff' fw/ctrl_rv/*.[ch]`); create
  `fw/ctrl_rv/test/hwmap_test.c`.
- **Changes:** the I/O map of the Global Constraints. `HW_SPI_CS 7 -> 4`,
  `HW_SPI_DATA 3 -> 0`, `HW_SPI_SPEED 11 -> 8`, base `0xFFFFFFE0`;
  `RS232(x)` -> 8-bit store to `0xFFFFFFF0`; TIMER `0xFFFFFFD0`; PLATFORM
  `0xFFFFFFC0`; AUDIO `0xFFFFFFB0`; Akiko/keyboard/RTC offsets per the map;
  32-bit registers keep offset 0. `uart.h`: drop `UARTBASE`/`HW_UART`,
  `REG_UART_RXINT`, `REG_UART_TXREADY`, `getserial`. `uart.c` `puts`: a byte
  loop (`while ((c = *msg++)) putchar(c)`) -- the 832 version reads the
  string as 32-bit words and takes bytes with `>> 24` (BE-only, and a
  misaligned load for an unaligned string).
- **Test first (`hwmap_test.c`, host, `-DHOSTTEST` off for this file: it
  only takes addresses):** asserts `(uintptr_t)&TIMER == 0xFFFFFFD0`,
  `sizeof(TIMER) == 2`, and the same for every register macro in the map
  (address and access width); and `puts("ab\0")` through a `putchar` mock
  for strings at offsets 0..3 of an aligned buffer. Red on Task 4's tree.
- **Commands:** `make -C fw/ctrl_rv/test hwmap_test && ./fw/ctrl_rv/test/hwmap_test && make -C fw/ctrl_rv all check`
- **Pass gate:** `hwmap_test` PASS; `make check` all four parts PASS
  (including (c), now green); no `0x0fffff` left in `fw/ctrl_rv/*.[ch]`
  except in comments.

### Task 6: L2 smoke test -- the real firmware boots to its main loop (`run.sh fwboot`)

- **Phase / depends on:** plan 3.1 gate + 7.1 item 2 measurement / Task 5
  (exec-1 Task 12 bench, exec-2 Task 5 Verilator backend).
- **Model:** Opus.
- **Files:** create `sim/host_bridge/minimig_spi_stub.v`,
  `sim/host_bridge/fwboot/Makefile`, `sim/host_bridge/fwboot/milestones.txt`,
  `sim/host_bridge/fwboot/smoke_trap.c`, `sim/host_bridge/spitrace.py`;
  modify `sim/host_bridge/tb_host_bridge.v` (`ifdef FWBOOT`),
  `sim/host_bridge/run.sh` (targets `fwboot`, `fwboot_trap`),
  `sim/host_bridge/README.md`, `tools/sim/mkcard.sh` (ledger: refuse names
  that are not 8.3 upper case; refuse sizes above the FAT16 2 GB limit).
- **Bench (`-d SDCARD -d FWBOOT -d RV_HOSTCPU_STATS`):** the committed boot
  ROM, the SD model on `sd_cs[1]`, and `minimig_spi_stub.v` on the other
  chip selects: MISO = card MISO while `sd_cs[1]` is low, else the stub's.
  Stub: `sd_cs[4]` (FPGA, `EnableFpga` 0x10): every byte 0x00 (no drive
  request); `sd_cs[5]` (OSD, 0x20): the first byte is the command; reply to
  `OSD_CMD_VERSION` 0x88 with `01 1A 0A 02 A4 7D` (the board's correct
  reply, 174322f), to `OSD_CMD_KEYQ` 0x98 with 0x00 (empty), to
  `OSD_CMD_READ` 0x00 with 0x00, otherwise 0x00; `sd_cs[7]` (RTC): 0x00.
  The bench logs every SPI frame (CS value, MOSI/MISO bytes) in a normalised
  form `spi.txt` (`<cs> <out bytes> / <in bytes>`, no timestamps; a CPU-neutral
  format Phase 4 reuses for the 832/RV diff; `spitrace.py` summarises it), the
  UART lines (`UART:`), any `EXC `/`TRAP ` line, and two monitors:
  - **OSD reply gap:** for every OSD frame, the idle `clk_114` cycles between
    consecutive host accesses that belong to the reply read, defined exactly
    as `tb_spi_cdc.v`'s `+GAP` (read its definition first and say in the
    README which events are measured); print `=== OSD GAP min <n> over <m>
    bytes`.
  - **Stack low-water:** the lowest byte address the CPU writes below 0x2000
    after the first fetch from 0x2000 (bridge `rom` state writes); print
    `=== STACK low <hex> (<n> bytes used)`.
  The card (`fwboot/Makefile`, `mkcard.sh`, 16 MB FAT16): `RV32OSDA.BIN`
  from `make -C fw/ctrl_rv` (copied, not rebuilt with other flags),
  `832OSDAD.BIN` decoy; no config file, no kickstart (the firmware takes the
  defaults and shows the "Kickstart ROM failed to load" error; its error loop
  `while(ErrorMask)` runs `HandleFpga` and `HandleUI` -- that is the main
  loop for this test). TIMER at `tick_in = 1` (643x fast, Global
  Constraints). If the ADV7511 service stalls the run with the bench's
  `havei2c = false`, run with `havei2c = true` (real `i2c_master_mmio`, no
  slave: NACK, every wait is timer-bounded) and say which in the README.
- **Test first:** `milestones.txt` = the ordered UART lines the firmware must
  print on this card (taken from the source: the boot ROM's lines up to the
  jump as in `boot/expect.txt`, then the firmware's `printf`s of
  `main()`/`ColdBoot()`/`MMC_Init()`/`LoadConfiguration()` that this path
  reaches) and the SPI milestones: one `0x20` frame starting `88` with six
  reply bytes `01 1A 0A 02 A4 7D`; `OSD_CMD_RST` frames (`08 ..`); at least
  10 `OSD_CMD_OSD_WR` frames (`0c ..`, the boot screen text); then at least
  20 `0x10` frames of exactly 6 bytes (`HandleFpga`). The run is checked as
  an ordered subsequence (not line for line: these logs depend on dosfstools'
  layout less than `boot/expect.txt` did, ledger item 54). Run it on the
  Task 5 tree with a deliberately wrong `HW_SPI_DATA` offset (run copy):
  it must fail.
- **`fwboot_trap` (teeth for the trap path, ledger item 50):** the same card
  with an `RV32OSDA.BIN` linked with `fwboot/smoke_trap.o` (a constructor at
  priority 65535 executing `.word 0xffffffff`; no firmware source change):
  the UART must show `EXC mcause=00000002 mepc=<the address from the map>
  mtval=ffffffff` and no `HandleFpga` frame.
- **Steps:** stub + MISO mux + logs + monitors; card Makefile; milestones;
  first run on Verilator, measure the cycle count to the 20th `HandleFpga`
  frame and set `FWBOOT_TIMEOUT` to 1.5x of it; then once on xsim; compare.
  `run.sh fwboot*` take `FW=<path to an RV32OSDA.BIN>` (default
  `fw/ctrl_rv/build/RV32OSDA.BIN`) so other builds (Tasks 17, 18) run on the
  same card recipe.
- **Commands:**
  `make -C fw/ctrl_rv && SIM=verilator RUNTAG=p3t6 bash sim/host_bridge/run.sh fwboot && SIM=verilator RUNTAG=p3t6t bash sim/host_bridge/run.sh fwboot_trap && RUNTAG=p3t6x bash sim/host_bridge/run.sh fwboot && bash sim/host_bridge/run.sh compare p3t6x p3t6`
- **Pass gate:** `fwboot` PASS on Verilator and xsim (SAME; xsim: no X on
  the bus); milestones in order; no `EXC`/`TRAP` line; `fwboot_trap` shows
  the expected `EXC` line; the wrong-offset run copy FAILs; `OSD GAP min`
  and `STACK low` recorded in the README (OSD GAP below 40: record it, do not
  tune -- the rule's real check is Phase 4 with `userio_osd`; report it as
  an open 7.1 item 2 finding); I$ refill count and boot cycle count recorded;
  the existing `all`, `boot`, `boot_nofile` still PASS (the `FWBOOT` ifdef
  leaves them alone).

### Task 7: `-Wall -Wextra` warning-clean, code-identical

- **Phase / depends on:** Paul's "warning-clean build" / Task 6.
- **Model:** Sonnet.
- **Files:** `fw/ctrl_rv/*.c`, `*.h`, `lib/*`, `fw/ctrl_rv/Makefile`
  (`-Wall -Wextra -Werror` from here on).
- **Rule:** a warning is fixed so that the generated code does not change:
  casts that spell out the conversion C already applies (e.g. for
  `-Wsign-compare`, cast to the type the usual arithmetic conversions
  already chose), `(void)` for unused parameters/results, `const` where
  the pointer is only read, removal of unused locals, explicit braces or
  parentheses for `-Wparentheses`/`-Wmisleading-indentation`. A warning that
  points at a real bug is **not** fixed here: list it in the README
  ("Found by -Wextra", file:line, what is wrong) and leave the code; Task 16
  or a later task decides.
- **Test first:** `objdump -d -j .text` of `build/RV32OSDA.elf` before the
  task (Task 6 tree), symbol addresses stripped (`sed` the address column),
  saved.
- **Commands:** `make -C fw/ctrl_rv clean all 2>&1 | tee build.log; grep -c 'warning:' build.log` and the objdump compare.
- **Pass gate:** zero warnings with `-Wall -Wextra`; the normalised `.text`
  disassembly identical to the baseline except where `.rodata` string
  addresses moved (`const` additions); any other difference is explained
  line by line in the commit message; `fwboot` PASS (Verilator).

### Task 8: Host-test harness (`-DHOSTTEST` hooks, SPI/TIMER/card mock, `-m32`)

- **Phase / depends on:** plan 3.2 ("`SPI()`/`EnableFpga()` overridable under
  `-DHOSTTEST`") and 7.3 / Task 7.
- **Model:** Sonnet.
- **Files:** modify `fw/ctrl_rv/hardware.h` (under `#ifdef HOSTTEST` only:
  `SPI(x)` -> `hosttest_spi(x)`, `RDSPI`, the `Enable*/Disable*` CS macros ->
  `hosttest_cs(v)`, `SPI_slow/fast`, `TIMER` -> `hosttest_timer()`,
  `PLATFORM`, `AUDIO`, `RS232`; the target build is untouched: `make -C
  fw/ctrl_rv` gives a byte-identical `RV32OSDA.BIN`), `fw/ctrl_rv/test/Makefile`
  (rewritten: native and `-m32` builds of every test, `run`, `mutants`,
  `clean`; the five existing tests and `lib_test`/`hwmap_test` folded in);
  create `fw/ctrl_rv/test/mock_hw.c`, `mock_hw.h`, `fw/ctrl_rv/test/README.md`.
- **Mock (`mock_hw.c`):** an SPI trace recorder (`cs` changes and bytes out,
  in the `spi.txt` format of Task 6 so host and L2 traces are comparable);
  scripted MISO per chip select (a queue of reply bytes or a callback; the
  SD side either scripted or a **card-image model** that answers CMD17/18/24
  from a raw image file: `MMC_Read`/`MMC_Write`-level fakes are not enough
  for `mmc_test`, so the card model speaks the SPI protocol the way
  `sim/common/sd_spi_model.v` does); a controllable TIMER (`hosttest_advance(n)`,
  auto-advance per call so timeout loops end); UART capture.
- **Test first:** `mock_selftest.c`: scripted replies come back in order per
  CS; the card model returns sector 0 of a `mkcard.sh` image (0x55AA at
  510); a timeout loop over `CheckTimer` terminates.
- **Commands:** `make -C fw/ctrl_rv/test` and `make -C fw/ctrl_rv && cmp build/RV32OSDA.BIN <Task-7 copy>`
- **Pass gate:** all tests PASS native and `-m32` (`atapi_test` with and
  without `ISO=`); `mutants` target exists and every existing test has one
  (e.g. `cue_test` with an off-by-one in `cue.c` frame arithmetic); the
  target binary unchanged; `fw/ctrl_832/test` untouched and still green
  (`make -C fw/ctrl_832/test`).

### Task 9: Byte-order helpers, FAT and MBR (5.2 "flips", items 7 and 8 for fat.c)

- **Phase / depends on:** plan 3.2 (le/be helpers) + 3.3 / Task 8.
- **Model:** Opus.
- **Files:** `fw/ctrl_rv/swap.h`, `swap.c` (helpers of the Global
  Constraints; `SwapBB/SwapBBBB/SwapWW` stay for any caller that really means
  "swap"), `fat.c`, `fat.h`; create `fw/ctrl_rv/test/swap_test.c`,
  `fw/ctrl_rv/test/fat_test.c`, images built by the test Makefile: FAT16 with
  MBR by `tools/sim/mkcard.sh`, FAT32 with MBR (`sfdisk` + `mkfs.fat -F 32`
  on the partition offset + `mcopy`, the way `mkcard.sh` does FAT16) and a
  superfloppy FAT16 image without MBR (`mkfs.fat` on the whole file).
- **Changes:** every "for 68000" swap of an on-disk LE field becomes `le16`/
  `le32` (identity here, a swap on a BE host -- the code says what the disk
  format is); the FAT32 end-of-chain store `0xFFFFFF0F` ("EOC change for
  68000") becomes `le32(0x0FFFFFFF)`; `sector_buffer[1024]` and the
  `fat_buffer` union `__attribute__((aligned(4)))`; the MBR path: the
  `Signature` switch keeps both cases (on LE the `0xaa55` case runs, no
  swap), partition entries keep their `memcpy` into the aligned
  `partitions[]` (check that no 32-bit field is read in place at MBR offset
  454 = 2 mod 4). `bprintfl` and debug prints unchanged.
- **Test first:** `swap_test.c`: each helper on known values, plus the
  `rd_*`/`wr_*` forms at offsets 0..3 (UBSan would flag a misaligned cast).
  `fat_test.c` (`-m32` and native, card model of Task 8 under the real
  `mmc.c` and `fat.c`): FAT16 image with MBR, FAT32 image, superfloppy:
  `FindDrive()`, root directory listing (names, sizes, start clusters
  against `mdir -/ -a` output parsed by the test script), `FileOpen` +
  `FileRead` of a 300 KB file (fragmented: create it after deleting a file
  in the middle) compared byte-for-byte, a subdirectory walk with long names,
  `FileCreate` + `FileWrite` + `UpdateEntry` of a 3-sector file, then the
  image checked with `fsck.fat -n` and the file read back with `mtype`.
  Mutant: `le16` of `StartCluster` replaced by `SwapBB` must fail the
  listing.
- **Commands:** `make -C fw/ctrl_rv/test run mutants && make -C fw/ctrl_rv && SIM=verilator RUNTAG=p3t9 bash sim/host_bridge/run.sh fwboot`
- **Pass gate:** `swap_test`, `fat_test` PASS (both ABIs, all three
  images); mutant FAIL; `fsck.fat -n` clean after the write; `fwboot`
  PASS (its milestones may now include config/kickstart file lookups that
  report "not found" correctly instead of garbage).

### Task 10: SD/MMC driver -- timer-bounded waits, CMD sequence trace, timer-user audit

- **Phase / depends on:** plan 3.2 (`mmc.c` count loops -> `CheckTimer`, 7.1
  item 10) / Task 9.
- **Model:** Opus.
- **Files:** `fw/ctrl_rv/mmc.c`, `mmc.h`; create `fw/ctrl_rv/test/mmc_test.c`;
  `sim/common/sd_spi_model.v` (ledger 41: CMD0 clears `app_cmd`) +
  `sim/common/tb_sd_spi_model.v` (a CMD55, CMD0, CMD41 sequence must be
  answered as plain CMD41) and its README (ledger 40: the bench compare
  assumes a contiguous file; say so); `fw/ctrl_rv/README.md` (TIMER table).
- **Changes:** the five `timeout++ >= 1000000` bounds (`mmc.c` data-token
  waits of CMD17/CMD18 and the CMD24/CMD12 busy waits) become
  `t = GetTimer(SD_TIMEOUT); ... if (CheckTimer(t))` with `#define
  SD_TIMEOUT 173` (173 x 5.804 ms = 1.004 s: at least the 832's real bound,
  which was ~1 M SPI byte reads; comment states the unit). The `Ncr` loops
  (`while (response == 0xFF && Ncr--)`) are SD-spec byte counts, not delays:
  unchanged. `MMC_Init`'s `WaitTimer(20)` and `GetTimer(1000)` unchanged
  (TIMER units, parity). **TIMER audit:** a table in the README of every
  `TIMER`/`GetTimer`/`CheckTimer`/`WaitTimer` user (`grep` list: `audio.c`,
  `drivesounds.c`, `cdaudio.c`, `cdrom.c` `CD_TIMEOUT`, `hdd.c:910`,
  `fpga.c`, `osd.c` key repeat/scroll, `mmc.c`, `main.c` ADV7511 250) with
  its nominal value and the real board time at 5.804 ms per count: all
  unchanged, both CPUs identical.
- **Test first (`mmc_test.c`, card model + SPI trace of Task 8):**
  `MMC_Init()` on an SDHC model: the CMD sequence (CMD0, CMD8, CMD55/ACMD41
  polls, CMD58, speed switch) equals a golden list taken from the SD
  model's command log of the L2 `boot` run (same protocol); `MMC_Read` with
  token delay 0/4/200 bytes; `MMC_ReadMultiple`; `MMC_Write` with busy 8 and
  2000 bytes; a card that never sends the token -> the read returns failure
  after the timer bound (the mock TIMER advances per byte) and the trace
  shows no more than the bound's worth of bytes; the direct-mode sequence
  (`EnableDMode`, `SPI(0xFF)`, `RDSPI`, `DisableDMode`) recorded as a trace
  file for Phase 4 (`test/gold/dmode.txt`). Mutant: `SD_TIMEOUT` 0 must fail
  the token-delay-200 case.
- **Commands:** `make -C fw/ctrl_rv/test run mutants && bash sim/common/run_sd_model.sh && make -C fw/ctrl_rv && SIM=verilator RUNTAG=p3t10 bash sim/host_bridge/run.sh fwboot && SIM=verilator RUNTAG=p3t10b bash sim/host_bridge/run.sh boot`
- **Pass gate:** `mmc_test` PASS both ABIs; mutant FAIL; SD model bench
  PASS with the new app_cmd case; L2 `fwboot` and `boot` PASS; `grep -n
  'timeout++' fw/ctrl_rv/mmc.c` empty; TIMER table in the README.

### Task 11: Config file little-endian, RISC-V file names, `cfgconv`, first-boot conversion

- **Phase / depends on:** plan 3.4, decision 12.4 and the Phase-3 note in the
  exec-1 ledger (Paul copies his SD card: one card serves both bitstreams) /
  Task 9 (FAT write path).
- **Model:** Opus.
- **Files:** `fw/ctrl_rv/config.c`, `config.h`; create `fw/ctrl_rv/cfgswap.c`,
  `cfgswap.h`, `fw/ctrl_rv/tools/cfgconv/cfgconv.c`, `Makefile`, `README.md`,
  `fw/ctrl_rv/test/config_test.c`, `fw/ctrl_rv/test/gold/mkcfg832.py`;
  `sim/host_bridge/fwboot/Makefile` (second card), `run.sh` target
  `fwboot_cfg`.
- **Format (decided here, recorded in plan 12.4 by Task 20):** the struct is
  unchanged (212 bytes, `CONFIG_VERSION 4`, id `"MNMGCFGA"`); the RV firmware
  stores it natively (LE). The only multi-byte fields are seven 32-bit ones:
  `version` @8, `kickdir` @132, `extromdir` @136, `hdfdir[0..3]` @140/144/
  148/152 (checked: gcc `-m32` and RV32 give these offsets; `config.c` gets
  `_Static_assert` on each `offsetof` and on `sizeof == 212`, replacing the
  negative-array typedef). RISC-V file names: **`MINMGAR CFG`** (slot 0) and
  **`MINMGAR%dCFG`** (slots 1..), i.e. `MINMGAR.CFG`, `MINMGAR1.CFG`...; the
  832's are `MINMGAA*`. Byte order is told by `version`: LE 1..4 = RV, a
  value whose BE reading is 1..4 = 832. `cfgswap.c` (pure C, shared by the
  firmware and the tool): `cfg_order(const uint8_t *buf, size_t len)` ->
  `CFG_RV`/`CFG_832`/`CFG_BAD` (id and length checked too), `cfg_swap(uint8_t
  *buf)` (swaps the seven fields in place, byte-wise).
- **Firmware behaviour:** `LoadConfiguration` reads the RV name; a file in
  832 order under the RV name is rejected with the BootPrint "Wrong
  configuration file format!" (the existing `version > CONFIG_VERSION`
  path) plus "(832 byte order)" and defaults are used. **First boot:** if the
  RV file of the slot does not exist and the 832 file (`MINMGAA..CFG`) does,
  read it, `cfg_order == CFG_832` -> `cfg_swap`, then the normal version
  checks, use it, and save it under the RV name (`SaveConfiguration` creates
  the file); BootPrint "Converted 832 configuration <name>". The 832 file is
  **never written** (no `FileWrite`/`UpdateEntry` on it). Slots 1.. convert
  the same way when they are first loaded.
- **`cfgconv`:** `cfgconv [--to-rv|--to-832|--check] <in> <out>`; `--check`
  prints the order and every field (name = value) of a file; refuses
  `CFG_BAD`, a file already in the target order, and an output path equal to
  the input. Host C (`gcc -Wall -Wextra -Werror`, sanitizers in the test
  build), README with examples (copying `MINMGAA.CFG` from a card,
  converting, `mcopy` back).
- **Test first:** `mkcfg832.py` writes 832 (BE) config files from a field
  table, independently of the C code (`struct.pack('>8sL24s...')` following
  `config.h`): defaults, every field non-zero and distinct, version 2 and 3
  files (old-format paths), and a corrupt one. `config_test.c` (both ABIs):
  `cfgconv --to-rv` of each, then field-by-field compare of the LE result
  with the table (read with the firmware's `configTYPE` on the host); round
  trip `--to-832` gives the original bytes; `cfg_order` on every case;
  `LoadConfiguration` through `fat.c` on a card image with (a) only an RV
  file, (b) only an 832 file (conversion: the RV file appears, equals
  `cfgconv` output, the 832 file is byte-identical and its directory entry
  unchanged), (c) an 832-order file under the RV name (rejected, defaults),
  (d) both files (the RV one wins). Mutant: `cfg_swap` missing `hdfdir[3]`
  must fail.
- **L2 (`fwboot_cfg`):** the Task 6 card plus an 832 `MINMGAA.CFG` from
  `mkcfg832.py`; run with `+SD_SAVE`; afterwards the script extracts both
  files with `mtools`: `MINMGAR.CFG` == `cfgconv --to-rv MINMGAA.CFG`,
  `MINMGAA.CFG` unchanged, `fsck.fat -n` clean; UART shows the conversion
  line.
- **Commands:** `make -C fw/ctrl_rv/tools/cfgconv && make -C fw/ctrl_rv/test run mutants && make -C fw/ctrl_rv && SIM=verilator RUNTAG=p3t11 bash sim/host_bridge/run.sh fwboot_cfg && RUNTAG=p3t11x bash sim/host_bridge/run.sh fwboot_cfg`
- **Pass gate:** all of the above PASS; plan gate 3.4 ("round-trip test on
  every config file in the repo/SD image, field-by-field compare;
  wrong-order file rejected") met for the generated set -- there is no config
  file in the repo; `CFG832_DIR=<dir>` runs the same round trip on real 832
  files (Paul's card copies) when given, and the README says so.

### Task 12: Hard disk -- RDB/PART synthesis, RDB patch, IDENTIFY, ATA paths (5.2 items 1, 2, 7)

- **Phase / depends on:** plan 3.3 + 7.3 `hdd_test.c` / Task 8 (Task 9 for
  the HDF file path).
- **Model:** Opus.
- **Files:** `fw/ctrl_rv/hdd.c`, `hdd.h`, `hdd_internal.h`; create
  `fw/ctrl_rv/test/hdd_test.c`, `fw/ctrl_rv/test/gold/rdb.py`,
  `gold/identify.py`; `test/Makefile` (`openhf_test` links the real
  `hdd.c` now that it builds whole under `HOSTTEST`, or keeps the `sed` cut
  -- implementer's choice, say which).
- **Changes:** `FakeRDB` builds the RigidDiskBlock and PartitionBlock with
  every long (and the IDs `'RDSK'`, `'PART'`) stored `be32`; `RDBChecksum`
  sums `be32(p[i])` over `be32(p[1])` longs and stores `be32(-sum)`; the
  read-and-patch path of an HDF's own RDB (`hdd.c:524`, `rdb_ChkSum +=
  rdb_Flags - 0x12; rdb_Flags = 0x12`) works on `be32` values;
  `IdentifyDevice`: numeric words stay as they are (sent low byte first by
  `ATA_IdentifyDevice`), the string words (serial `pBuffer[10..19]`, firmware
  `[23..26]`, model `[27..46]` incl. the file-name copy) get a 16-bit swap
  on LE after the copy, so the byte stream equals the 832's (the plan's item
  2 text is corrected in Task 20). No other change in `hdd.c`.
- **Test first (`hdd_test.c`, SPI mock + card model):** `rdb.py` builds the
  expected 512-byte RDSK and PART blocks (BE, checksum) for three geometries
  (from `hdf[]` set up as `OpenHardfile` does for a small, a 2 GB and an odd
  HDF); `FakeRDB` output compared byte for byte. `identify.py` gives the
  expected 512-byte stream for an HDF named `WORK.HDF` (long name and 8.3
  cases, SYNTHRDB and plain) as the 832 sends it (word value -> low byte,
  high byte; strings as the 832's BE memcpy makes them); `ATA_IdentifyDevice`
  trace compared. `ATA_ReadSectors`/`WriteSectors` LBA and CHS math
  (`tfr` bytes -> LBA) incl. sector count 0 = 256 and the read-multiple
  chunking against a mock gayle FIFO status (`CMD_IDECMD`/`CMD_IDEDAT`
  scripted), data compared with the HDF; the FakeRDB boundary loop of
  `hdd.c:518` (the Task 4 parenthesis) with an LBA range crossing it.
  Mutants: `RDBChecksum` without `be32` on the sum; IDENTIFY without the
  string swap.
- **Commands:** `make -C fw/ctrl_rv/test run mutants && make -C fw/ctrl_rv && SIM=verilator RUNTAG=p3t12 bash sim/host_bridge/run.sh fwboot`
- **Pass gate:** `hdd_test`, `openhf_test` PASS both ABIs; both mutants
  FAIL; `fwboot` PASS.

### Task 13: Floppy -- MFM sector streams and write-track decode (`fdd.c`)

- **Phase / depends on:** plan 7.3 `fdd_test.c` / Task 8.
- **Model:** Opus.
- **Files:** create `fw/ctrl_rv/test/fdd_test.c`, `fw/ctrl_rv/test/gold/mfm.py`;
  `fw/ctrl_rv/fdd.c` only if the audit finds something (expected: nothing --
  the module is byte-level).
- **Audit (README):** every multi-byte access in `fdd.c` (expected none
  besides `int` arithmetic on bytes); the commented `SPIN`s stay commented
  (historic ADF-write workaround); timing items 7.1 #6/#7 (FIFO not starved
  / not overrun) are Phase 4's, noted with the functions involved.
- **Test first (`fdd_test.c`, SPI mock, ADF image file):** `ReadTrack` for
  track 0 side 0 and track 79 side 1 of a generated ADF (LBA-tagged sector
  contents): the bytes sent under the FPGA CS (`SectorToFpga`,
  `SectorGapToFpga`, header, checksums) against two references: (1)
  `mfm.py`, an independent Amiga MFM track encoder (sync 0x4489, odd/even
  split, header/data checksums), and (2) the same function from
  **`fw/ctrl_832/fdd.c` compiled for the host** with the same mock (byte-level
  code: the host build of the 832 source is the 832's behaviour) -- all
  three equal. Write path: `mfm.py` produces the MFM stream the Amiga writes
  for a modified track; fed through the mock to `FindSync`/`GetHeader`/
  `GetData`/`WriteTrack`; the ADF afterwards differs from the original only
  in the written sectors, which hold the new data. Track/side arithmetic
  for all 160 tracks; the Copy Lock workaround path (`fdd.c:242`) reached
  once. Mutant: a one-byte-short sector (`SectorToFpga` loop bound - 1)
  must fail both references.
- **Commands:** `make -C fw/ctrl_rv/test run mutants`
- **Pass gate:** `fdd_test` PASS both ABIs (RV source == 832 source ==
  `mfm.py`); mutant FAIL; the golden streams of track 0/79 committed under
  `test/gold/` for Phase 4's L3 data check.

### Task 14: Remaining Amiga-facing data -- copper list, drive sounds, checksums, dead firmware upgrade

- **Phase / depends on:** plan 3.3 items 3, 4, 6 and the new rows of the
  audit table / Task 8.
- **Model:** Opus.
- **Files:** `fw/ctrl_rv/boot.c`, `drivesounds.c`, `main.c` (`CheckSum`),
  `hexdump.c`, `firmware.h` (and any user); create
  `fw/ctrl_rv/test/drivesounds_test.c`, `test/boot_test.c`,
  `test/gold/drivesounds.py`.
- **Changes:**
  - `boot.c` default copper list (no `COPPER_FILE` on the card): each word
    stored `be16` (the 68k reads BE words).
  - `drivesounds.c`: the `DRIVESND` header's `id`/`size` read with
    `rd_be32` (they sit at `2 mod 4`: a misaligned 32-bit load traps on
    VexRiscv); the sample data (BE 16-bit words in the file,
    `sw/mkdrivesounds/mkdrivesounds.c`) converted to native order **once at
    load** (in place, the buffer is the firmware's own), and the per-sample
    byte swap in the render loops (`c=((c&255)<<8) | ((c>>8)&255)`, all
    variants) deleted; `c*0x10001` stays. Net effect: the ring bytes equal
    the 832's.
  - `CheckSum` (`main.c`, kickstart `checksum_pre` shown by the menu): sum
    `rd_be32` words so the shown value is the 832's for the same file.
  - `hexdump.c`: print the bytes as the 832 shows them (BE word view).
  - `firmware.h`: `UPGRADE`, `romTYPE`, `CheckFirmware`, `WriteFirmware`,
    `CalculateCRC32`, `SetSPIMode`, `GetSPIMode`, `NVCONFIG*` are declared
    and never defined or called (`grep`): delete the dead declarations,
    keep `true`/`false` (README "Differences").
  - Close the audit: a README table of every `(short *)`, `(long *)`,
    `(int *)`, `unsigned short *` access to Amiga memory or file data in
    `fw/ctrl_rv` (`grep` list as in this plan's preparation: drivesounds,
    hexdump, `main.c` CheckSum, `boot.c` `BootClearScreen` (zeros: neutral)
    and copper, `hdd.c` RDB (Task 12), `config.c` (Task 11), kickstart upload
    `fpga.c` (512-byte `RARead` into Amiga memory: bytes, neutral; the
    `adr[j] ^= key` decrypt: bytes)), each with its verdict.
- **Test first:** `drivesounds_test.c` (host, both ABIs): load
  `sw/mkdrivesounds/drivesnd.bin` through the mock file layer, queue a fixed
  event sequence (motor start, steps, eject), render into a mock ring;
  `drivesounds.py` computes the 832's ring bytes for the same sequence from
  the same file (BE samples, the 832's sum/swap/`*0x10001`/BE store);
  compare. `boot_test.c`: the default copper list bytes = `00 E0 00 08 00
  E2 ...` (BE), `CheckSum` of a known 512-byte block = the BE sum. Mutants:
  keep the old per-sample swap (ring differs); `*(long *)` header read
  (UBSan misaligned error or wrong size).
- **Commands:** `make -C fw/ctrl_rv/test run mutants && make -C fw/ctrl_rv && SIM=verilator RUNTAG=p3t14 bash sim/host_bridge/run.sh fwboot`
- **Pass gate:** tests PASS both ABIs; mutants FAIL; audit table complete;
  `fwboot` PASS (add `DRIVESND.BIN` to the fwboot card: no `EXC` while it
  loads).

### Task 15: CD-ROM/ATAPI/CUE/CD audio in the RV tree; L1 `units` on `fw/ctrl_rv`

- **Phase / depends on:** plan 3.6 for the CD units, exec-1 ledger items
  15/16/22/23/49 (L1 bench) / Task 8.
- **Model:** Opus (CD audio refill and ring timing).
- **Files:** `fw/ctrl_rv/cdaudio.c`, `cdrom.c` (audit; changes only if
  found), `sim/rv_l1/prog/Makefile` (`FWDIR ?= ../../../fw/ctrl_rv`; objects
  in `build/$(notdir $(FWDIR))/` so the two trees never share objects;
  `-MMD -MP` dependencies incl. `$(FWDIR)/test/emu/*.h` -- ledger 22, 23 and
  the final-fix-wave "stale Task-5 object gave 'want 2209'"),
  `sim/rv_l1/run.sh` (`units` always runs `make -C prog FWDIR=...` first and
  prints the FWDIR it used; one PROGS list read from the Makefile -- ledger
  16; FAIL codes printed in decimal like the checks -- ledger 15),
  `sim/rv_l1/tests/irq_c.c` (ledger 49: check 10 also catches a reversed
  `SetIntHandler` order), `sim/rv_l1/README.md`.
- **Audit (README):** `cdaudio.c` ring writes are byte stores (LE 16-bit
  format in the ring, neutral); `CD_AudioPoll` uses TIMER units
  (`CDA_HALF_UNITS`) the same way on both CPUs; `cda_port_ring()` =
  `AUDIO_BUFFER` 0x70000 (above `_end`: the linker ASSERT); `cdrom.c`'s
  `CD_TIMEOUT` and the 2.5 KB static `cd_cue` (stays static: the stack is
  still in the 8 KB BRAM). Refill cost and ring-fill time are Phase 4.4.
- **Test first:** run `units` with `FWDIR=fw/ctrl_rv` on Task 14's tree
  before the Makefile change and show the stale-object case (touch a header
  only in one tree; the old Makefile does not rebuild).
- **Commands:** `make -C fw/ctrl_rv/test run && SIM=verilator RUNTAG=p3t15 bash sim/rv_l1/run.sh units && RUNTAG=p3t15i bash sim/rv_l1/run.sh units && bash sim/rv_l1/run.sh compare p3t15i p3t15 && SIM=verilator RUNTAG=p3t15a bash sim/rv_l1/run.sh all && SIM=verilator RUNTAG=p3t15q bash sim/rv_l1/run.sh irq`
- **Pass gate:** `cue_test`, `cdaudio_test`, `atapi_test`, `cdrom_test`
  PASS both ABIs from `fw/ctrl_rv/test`; L1 `units` PASS on Verilator and
  iverilog from `fw/ctrl_rv` sources (SAME); a header edit rebuilds the
  affected unit (`make -n`); L1 `all` and `irq` PASS; the new irq_c check
  fails against a run copy with the order reversed.

### Task 16: Remove the vbcc832 workarounds (only those a comment names)

- **Phase / depends on:** plan 3.5 / Tasks 12-15 (host tests in place).
- **Model:** Sonnet implements; Opus reviews the diff (behaviour unchanged).
- **Candidates (`grep -n -i 'vbcc\|832e\|loadb' fw/ctrl_rv/*.[ch]`):** the
  "32 bits on purpose" fields (`atapi.h:82`, `cue.h:12-13`, `cdaudio.h:16`:
  vbcc832 12.6 stores a byte field as a word on "set then return the same
  constant") -> their natural types; the "`for (;;)` / `break`" loop shapes
  of `cue.c:36`/`cdaudio.c:10` (vbcc832 dropped a loop exit) -> plain loops;
  `config_size_is_212` typedef (already a `_Static_assert` from Task 11). Not
  removed (record why): `cdrom.c:54` static parser ("the 832 stack is
  small": the RV stack is the same 8 KB BRAM), `i2c.c:113` (a hardware
  rule, not a compiler one), anything whose comment names no compiler bug.
- **Rules:** one hunk per workaround, each with its comment updated; no
  struct that is written to disk, sent over SPI or shared with the 68k
  changes layout (check each: these structs are internal).
- **Test first:** record before the change: `make -C fw/ctrl_rv/test` PASS,
  L1 `units` PASS, `fwboot` `spi.txt`, `build/RV32OSDA.BIN` size.
- **Commands:** `make -C fw/ctrl_rv/test run mutants && SIM=verilator RUNTAG=p3t16 bash sim/rv_l1/run.sh units && make -C fw/ctrl_rv size && SIM=verilator RUNTAG=p3t16f bash sim/host_bridge/run.sh fwboot`
- **Pass gate:** all host tests and `units` PASS; the `fwboot` `spi.txt`
  identical to the recorded one; firmware not larger; Opus review approves
  each hunk as behaviour-neutral (the review note goes into the commit
  message).

### Task 17: Stack high-water mark and size budget

- **Phase / depends on:** plan 3.7 / Task 16.
- **Model:** Sonnet.
- **Files:** create `fw/ctrl_rv/stackcheck.c`, `stackcheck.h`; modify
  `fw/ctrl_rv/main.c` (one call at the start of `main`, one DebugMode print),
  `fw/ctrl_rv/Makefile` (`-fstack-usage` into `build/`, target `stack`:
  the 20 largest frames from the `.su` files), `fw/ctrl_rv/README.md`.
- **Interfaces:** `StackFill()` at the start of `main()`: fills
  `[0x1400, sp - 64)` with `0x5A5AA5A5` (0x1400: above the boot ROM image,
  Global Constraints "Sizes"; `make check` gets a line that reads
  `fw/ctrl_boot_rv/build/*.map` `_end` and fails if it is not below 0x1400);
  `StackHighWater()` returns the lowest address no longer holding the
  pattern; printed on the UART when DebugMode is switched on and on the
  Debug OSD page's existing text line if one has room (no layout change;
  otherwise UART only).
- **Test first:** the L2 bench's `STACK low` monitor (Task 6) is the
  reference. A sim-only build (`make -C fw/ctrl_rv B=build_sr
  EXTRA_CFLAGS=-DRV_STACK_REPORT`: prints `STACKHW <hex>` once from the main
  loop; off in the shipped build) run with `FW=fw/ctrl_rv/build_sr/RV32OSDA.BIN
  run.sh fwboot` must print a value within 64 bytes of the bench's figure;
  red before `stackcheck.c` exists (no line).
- **Commands:** `make -C fw/ctrl_rv all stack size check && make -C fw/ctrl_rv B=build_sr EXTRA_CFLAGS=-DRV_STACK_REPORT && SIM=verilator RUNTAG=p3t17 bash sim/host_bridge/run.sh fwboot && SIM=verilator RUNTAG=p3t17s FW=fw/ctrl_rv/build_sr/RV32OSDA.BIN bash sim/host_bridge/run.sh fwboot`
- **Pass gate:** recorded in the README: text/data/bss/BIN size (vs 83,830
  B), `_end`, the 20 largest frames, the L2 high-water; the high-water in
  `fwboot` stays above 0x1400 (if not: record it and stop -- a boot BRAM
  layout question for Paul, backlog "reset & boot"); `fwboot` PASS.

### Task 18: Clang/LLVM build check (decision 12.8 "gate 1b")

- **Phase / depends on:** plan 3.7 / Task 17.
- **Model:** Sonnet.
- **Files:** `fw/ctrl_rv/Makefile` (`CC=clang` mode: `make -C fw/ctrl_rv
  CLANG=1` -> `clang --target=riscv32-unknown-elf -march=rv32imc_zicsr_zifencei
  -mabi=ilp32` with the same `-std=gnu17 -Os -ffreestanding -fno-builtin
  -funsigned-char -Wall -Wextra`, link with the xPack `ld` and libgcc (or
  `ld.lld` if simpler; say which), output `build_clang/`), README.
- **Test first:** `clang --version` (Ubuntu 18.1.3 here) and `clang
  -print-targets | grep riscv32`.
- **Commands:** `make -C fw/ctrl_rv CLANG=1 clean all size check && SIM=verilator RUNTAG=p3t18 FW=fw/ctrl_rv/build_clang/RV32OSDA.BIN bash sim/host_bridge/run.sh fwboot`
  (`FW=` as defined in Task 6).
- **Pass gate:** the clang build compiles with zero warnings (a clang-only
  warning that is a real issue is fixed in the source with the Task 7 rule,
  `.text` of the gcc build unchanged; one that is not is listed with a
  targeted `-Wno-` in the CLANG block only); links; `check` passes; size
  recorded; `fwboot` PASS with the clang image. Not a requirement for
  shipping (plan 3.7): gcc stays the build.

### Task 19: README for `fw/ctrl_rv` (and the touched tools)

- **Phase / depends on:** Paul's README rule / Tasks 1-18.
- **Model:** Sonnet.
- **Files:** `fw/ctrl_rv/README.md` (complete), `fw/ctrl_rv/test/README.md`,
  `fw/ctrl_rv/tools/cfgconv/README.md`, `tools/sim/README.md` (mkcard
  guards), `sim/host_bridge/README.md` (`fwboot*`), `sim/rv_l1/README.md`
  (`units` on `fw/ctrl_rv`).
- **Content:** from a fresh Ubuntu 24.04 machine: `sudo apt install` line
  (build-essential gcc-multilib (for `-m32`), python3, mtools, dosfstools,
  fdisk, verilator, ghdl, clang lld optional); `bash
  tools/riscv/fetch-xpack.sh && bash tools/riscv/check-toolchain.sh`; build
  (`make -C fw/ctrl_rv`), what lands where, copying `RV32OSDA.BIN` to the SD
  card root next to `832OSDAD.BIN`; config files on the card (`MINMGAR*.CFG`,
  first-boot conversion, `cfgconv` examples); host tests; L1/L2 runs; the
  "Differences from fw/ctrl_832" list; the TIMER table; the audit tables;
  the sizes. Paths relative to the repository root, no `/home/paul`.
- **Test first:** none (documentation); the check is the replay below.
- **Commands:** extract every fenced `sh` block of `fw/ctrl_rv/README.md`
  into a script and run it with `zsh` and with `bash` in a scratch clone
  (`git clone . <scratch>/clone`, toolchain already installed: skip the
  fetch line with a note).
- **Pass gate:** both shells run the blocks without error and produce
  `build/RV32OSDA.BIN` and a green host test run; no absolute personal path
  in any README.

### Task 20: Phase 3 gate run and plan status

- **Phase / depends on:** end of Phase 3 / Tasks 1-19.
- **Model:** Sonnet.
- **Files:** `doc/osd-riscv-plan.md` (header status line, section 4 code
  size measured, 5.2 item 2 corrected and the new audit rows, 7.1 rows 2,
  10, 11 status, section 8 Phase 3 marked done with commit range, decision
  12.4 completed with the file names/format of Task 11), this file (status
  line under the title).
- **Gate run (record the results in the plan's Phase 3 entry):**
  `make -C fw/ctrl_rv clean all check size stack`; `make -C fw/ctrl_rv
  CLANG=1 all`; `make -C fw/ctrl_rv/test run mutants`; `make -C
  fw/ctrl_rv/tools/cfgconv`; `make -C fw/ctrl_832/test` (832 tree still
  green); L1 `all`, `irq`, `units`, `dm_smoke`, `dhry` (Verilator, plus
  `units` on iverilog); L2 `all`, `mutant`, `irqmut`, `boot`, `boot_nofile`,
  `fwboot`, `fwboot_trap`, `fwboot_cfg` on Verilator and `fwboot`,
  `fwboot_cfg` once on xsim (`compare` SAME); `bash sim/common/run_sd_model.sh`;
  the no-new-delays grep of the Global Constraints; `git status fw/ctrl_832
  fw/ctrl_boot_832 fw/ctrl_boot_rv rtl` clean; `diff -ru fw/ctrl_832
  fw/ctrl_rv` reviewed once against the README "Differences" list (every
  hunk is covered by an entry).
- **Pass gate:** everything above green; plan updated; the Phase 4 hand-over
  list below is true for the tree as committed.

---

## What Phase 4 consumes (the Phase 3 exit gate)

Phase 4 (plan 8, 4.1-4.6: L3 `sim/spi_cdc/hostrv/`, differential 832 vs RV,
trap log, speed, I$ hit rate) starts from:

1. **The firmware:** `make -C fw/ctrl_rv` -> `build/RV32OSDA.BIN` (+ `.elf`,
   `.map`, `.lst`), no sim-only code in it (`smoke_trap.o`,
   `-DRV_STACK_REPORT` only in their own bench builds); sizes and `_end` in
   `fw/ctrl_rv/README.md`.
2. **The L2 smoke family** `sim/host_bridge/run.sh fwboot | fwboot_trap |
   fwboot_cfg` (Verilator and xsim) as the quick regression for every later
   firmware change; its `minimig_spi_stub.v` is what L3 replaces with the
   real `userio_osd`, `paula_floppy`, `gayle` slaves.
3. **The normalised SPI trace** `spi.txt` (CS, bytes out/in, no time) from
   the L2 bench and from the host mock (same format), plus `spitrace.py`:
   the basis of 4.2's 832-vs-RV diff. Expected, listed differences between
   the two CPUs' traces: config file names and sectors (`MINMGAR` vs
   `MINMGAA`, first-boot conversion writes), firmware file size/sectors,
   version strings, timeout lengths of failure paths.
4. **Card recipes:** `sim/host_bridge/fwboot/Makefile` (RV32OSDA.BIN,
   832OSDAD.BIN, DRIVESND.BIN, config in either order) on `mkcard.sh` with
   the 8.3 and size guards; L3 adds kickstart, ADF, HDF (incl. the
   synthesised-RDB case), ISO and CUE/BIN.
5. **Goldens and generators** in `fw/ctrl_rv/test/gold/`: `mfm.py` and the
   committed track streams (ADF read/write data checks), `rdb.py`,
   `identify.py` (HDF/RDB checks), `mkcfg832.py`, `drivesounds.py`,
   `dmode.txt` (direct-mode call sequence), `formats.txt`.
6. **`cfgconv`** and the conversion rules (decision 12.4 as implemented),
   for the A/B card (Phase 5.3) and the parity row "832-written config files
   load identically after `cfgconv`" (plan 9).
7. **Trap and stack evidence:** the `EXC mcause=` line format (4.3 greps
   it; `fwboot_trap` proves the print path), the bench's `STACK low`
   monitor and the firmware's `StackHighWater()` (re-measured under L3 load
   and on the board in Phase 6).
8. **7.1 inventory status after Phase 3:** item 10 closed (SD waits on
   TIMER, Task 10); item 11 closed (no new count delays, grep gate); item 2
   measured against the stub (`OSD GAP min`, Task 6) and still open until
   L3 with `userio_osd` (and P1); items 3, 4, 6-9, 12-14 untouched, for L3.
9. **Bench timing facts:** L2/L3 TIMER runs 643x fast (`tick_in = 1`); a
   scenario that needs board-length timeouts (CD 10 s, SD 1 s) must drive
   `tick_in` at the real 44.1 kHz rate or account for the factor.
10. **First hot-set data for 4.5:** `RV_HOSTCPU_STATS` I$ refill counts and
    cycle counts of `fwboot` (boot to the 20th main-loop poll).
11. **Host test suite** `make -C fw/ctrl_rv/test` (native + `-m32`, mutants)
    and L1 `units` on `fw/ctrl_rv`: the regression that every Phase 4 fix
    must keep green.

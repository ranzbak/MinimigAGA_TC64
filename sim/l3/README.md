# L3 co-simulation bench

Work in progress (Phase 4 of the OSD host CPU migration). This file grows
with the bench; so far it has the sections "Bench", "Run", "boot",
"832", "Differential", "keys", "Monitors" and "Cards".

## Bench

`tb_l3.v` puts the host CPU against the real Minimig SPI slaves and boots
the committed boot ROM and the real firmware from an SD card image:

| Part | What | From |
|---|---|---|
| host CPU | `EightThirtyTwo_Bridge` (`cpu_riscv = true`: `rv_hostcpu` + VexOsd, the boot ROM `fw/ctrl_boot_rv/OSDBoot_rv_ROM.vhd`, `hostcache.v`; `CPU=832`: `cpu_riscv = false`, the EightThirtyTwo and `fw/ctrl_boot_832/OSDBoot_832_ROM.vhd`, section "832") | `rtl/host` |
| SDRAM | `sdram_host_model.v` (`+SLAT`, `+SJIT`, `+SEED`; `+SDRAM_DUMP=<file>` writes its 8 MB before the verdict) | `sim/host_bridge` |
| cfide | the board's generics: `spimux` false, `havespirtc`, `havei2c`, `havevpos` true; no I2C slave (every ADV7511 transfer NACKs) | `rtl/host/cfide.vhd` |
| card | `sd_spi_model #(.IMG_SECTORS(65536))` on `sd_cs[1]`, a 32 MB card from `sim/l3/card` | `sim/common` |
| RTC | `rtc_model.v` on `sd_cs[7]`: the SPI RTC `fw/ctrl_rv/rtc.c` reads, a fixed time ("Monitors", item 12); its MISO shares cfide's `sd_dimm` with the card | `sim/l3` |
| OSD | `userio_osd` (instance `osd1`) on `sd_cs[5]`, `CORE_CAPS` 0xAD | `rtl/minimig` |
| floppy / HDD | `paula_floppy` on `sd_cs[4]`, direct mode on `~sd_cs[6]` from the card's MISO; `gayle #(.IDE_PORTS(2))` behind it on the `hdd_*` bus | `rtl/minimig` |
| reset | `minimig_syscontrol` (`mrst` = `usrrst`, `cnt` = sof); chipset reset = `sys_reset \| cpurst` | `rtl/minimig` |
| audio ring | `bfm_audio.v`: the ring position, cfide `audio_buf` = bit 15 | `sim/l3` |

The wiring is that of `rtl/minimig/minimig.v` and
`rtl/soc/minimig_virtual_top.v`: cfide's `sd_di` is the slaves' MISO
(`paula_sdo | user_sdo`), its `sd_dimm` the card's; the OSD's
configuration outputs pass minimig.v's one-clock registers to
`floppy_drives` and Gayle's `hdd0/1_ena` and ATAPI bits. `CORE_CAPS` = 0xAD
is minimig_virtual_top's value for the board (`ap040_has_mmu` =
`ap040_has_fpu` = 1: 0x2D) with minimig.v's `CAPS_IDE2` (0x80); userio_osd
adds `CAPS_KEYQ` and `CAPS_INDIAG`, so the version reply's caps byte is
0xFD. The slaves are compiled after `rtl/soc/openaars_defines.vh` (the
board's global include; `MINIMIG_HOST_DIRECT`: userio_osd's `host_cs` is
constant 0, and the bench fails the run if it ever rises) with the board's
`fpga/openaars/minimig_version.vh`.

The Amiga side is idle: the floppy is deselected (`_sel` 1111, `_motor`
1), no register or Gayle access, `osd_ctrl` 0, `in_diag` 0. The CPU's
reset output follows its reset input, so the chipset reset is
`sys_reset | cpurst`; sof is one clk7 cycle per PAL frame (`+SOF_CLK7`,
default 142,102 = 313 lines x 227 colour clocks x 2).

Clocks: `clk_114` (8.8154 ns), `clk_28` = `clk_114` / 4 with its edges
`+C28DLY=<ns>` (default 0.3) after the `clk_114` edge, `clk7_en` /
`clk7n_en` as `rtl/clock/amiga_clk.v`, and the slaves see `sck`
`+SCKDLY=<ns>` (default 1.5) after cfide's pin register, the two delays of
`sim/spi_cdc/tb_spi_cdc.v`. TIMER: cfide's `tick_in` comes from the tick
generator, `+TICKDIV=<n>` one `clk_28` pulse every n cycles: 1 (default)
holds it at 1 (L2's TIMER, 643 x the board's), 643 is the board's 44.1 kHz;
`+TICKDIV_AT=scenario` runs at 1 until the scenario's main-loop milestone.

Monitors (`sim/common/hostmon.vh`, as in L2): stale ack, SPI accept, X on
the bus, the UART lines, the SPI frame log `spi.txt`, `=== OSD GAP`,
`=== STACK low`, `=== BOOT`, `=== STATS` (the whole run). The bench adds:

| Line / file | What |
|---|---|
| `spi_t.txt` | the frames of `spi.txt` with `<start> <end>` cycles in front (for Task 20; never compared) |
| `=== MAIN first HandleFpga frame at cycle <n>` | the main-loop milestone |
| `=== END <scenario>: ...`, `=== STATS@<scenario>` | the scenario's end event and the `rv_hostcpu` counters up to it |
| `=== MARGIN ...`, `=== KICK ...`, `=== RTC ...` | the margin monitors of `mon_l3.vh` and `rtc_model.v` ("Monitors") |
| `=== OSD EARLY <n> of <m> reply bytes` | in `OSD_CMD_VERSION` (0x88) and `OSD_CMD_KEYQ` (0x98) frames, every byte after the command: userio_osd_spi loads its output register from `in` (negedge of its `sck`, `bit_cnt` 0) while `osd1.spi0.new_byte \| rx_sync \| rx` is 1, i.e. before the previous byte is through the clk7 synchroniser and the reply counters have moved. n > 0 is a bench error unless `+OSD_EARLY_OK=1` |

Plusargs besides those: `+SCENARIO=<name>`, `+TIMEOUT=<clk_114 cycles>`,
`+FAST_HW=1` (run.sh puts `+SD_TOKEN_DLY=0 +SD_BUSY=1 +SD_NCR=1 +SLAT=2
+SJIT=0` first, the bench checks that the models took them),
`+OSD_MIN_GAP=<n>` (hostmon, default 40), `+RTC_CSH_MIN=<ns>` (item 12's
bound, default 0), `+BOOT_END=rtc2` (`boot` ends at the second RTC frame),
`+SD_SAVE=<file>`, the card
model's `+SD_*`, `+VERBOSE=1`. Parameter `EXTRA_WS`: the bridge's
`rv_extra_ws`. A scenario (`scenarios.vh`) ends the run at its end event:
"=== PASS" without DONE when there was no bench error; at `+TIMEOUT` the
run fails ("end event not reached").

Under Verilator the VHDL (cfide, the bridge, the ROM) is converted with
`ghdl --synth` as in L2 (`sim/common/hostsim.sh`, with the L2 bench's
`verilator/blackbox.vhd` and `romcheck.py`); lint waivers in `l3.vlt`.
`XRAND=1` is the X-sensitivity build (`sim/host_bridge/README.md`, "Shared
parts"), with the same five reset-less flops pinned to 0 and, in the run
copy of `paula_floppy.v`, the never-reset `dsktrack` ("boot", XRAND).

## Run

Setup on a fresh Ubuntu 24.04, bash or zsh, from the repository root (the
Vivado part only for `SIM=xsim`, see `sim/host_bridge/README.md`,
Prerequisites: Vivado 2023.2 and the `libtinfo.so.5` shim):

```sh
sudo apt install build-essential make python3 mtools dosfstools fdisk xorriso ghdl verilator ccache iverilog
bash tools/riscv/fetch-xpack.sh
bash tools/riscv/check-toolchain.sh
make -C fw/ctrl_rv
```

Then:

```sh
SIM=verilator RUNTAG=b bash sim/l3/run.sh boot
SIM=verilator RUNTAG=bx bash sim/l3/run.sh xpair boot
SIM=verilator RUNTAG=bn NOKICK=1 bash sim/l3/run.sh boot
SIM=verilator RUNTAG=rtc SLAT=4 TIMEOUT=300000000 XARGS=+BOOT_END=rtc2 bash sim/l3/run.sh boot
SIM=verilator RUNTAG=s bash sim/l3/run.sh boot_short
RUNTAG=sx bash sim/l3/run.sh boot_short
bash sim/l3/run.sh compare sx s
```

`run.sh <scenario>` builds the firmware from `fw/ctrl_rv` into the run
directory under a date shim (so two runs of one tree boot the same image;
`FW=<RV32OSDA.BIN>` takes another one), builds the card into it
(`sim/l3/card`), builds the bench, runs it and then the scenario's checks,
and prints `=== <scenario> PASS` or `FAILED` (exit 0 / 1). A step that
fails (firmware, card, conversion, build) ends the run at once with
`=== <scenario> FAILED`, and an offline check (`spitrace.py`, `l3check.py`,
run.sh's `l3_check`) counts only when it exits 0 and prints its pass line. `xpair` runs the
scenario and its `XRAND=1` twin in parallel (`run_<RUNTAG>`,
`run_<RUNTAG>_xr`) and compares them. `compare` diffs every `tb_*.log` and
`spi.txt` of two run directories (L2's rules). Environment: `CPU=rv`
(default) or `832` (section "832", with `E832`, `E832DIR`), `SIM=xsim`
(default) or `verilator`, `RUNTAG`, `FW`, `FW832`, `L3_DATE`, `EXTRA_WS`,
`SLAT`, `SJIT`, `SEED`, `XARGS` (more plusargs), `TIMEOUT`, `NOKICK=1`,
`XRAND=1`, `XSEED`, `KEYS` (section "keys"), `RDY_MUT=1` (section "keys", teeth). Every log starts with `=== CPU rv` or `=== CPU 832`.

A run directory `sim/l3/run_<RUNTAG>/` holds `results.txt`, the log
`tb_<scenario>_x<EXTRA_WS>_s<SLAT>_j<SJIT>.log`, `spi.txt`,
`spi_summary.txt`, `spi_t.txt`, `hw.txt` and `uart.txt` (section
"Differential"), `sdram.bin`, `memhash.txt`, `milestones.txt` (the check's
output), `kick.txt`, `order.txt` and `mmc.txt` (`boot`), `card/`, `fwrv/` and
(`CPU=832`) `fw832/`.

## boot

`boot` boots the `boot` card (both firmwares, `MINMGAR.CFG`,
`MINMGAA.CFG`, `KICK.ROM`) with the TIMER at 1 (`TICKDIV` 1): the boot ROM
loads `RV32OSDA.BIN`, the firmware runs `MMC_Init`, `LoadConfiguration`
(finds `MINMGAR.CFG`), `fpga_init` against the real userio_osd, loads the
kickstart and releases the Amiga, then enters its main loop. The main-loop
milestone is the first HandleFpga frame (`10` with six 00 bytes); the run
ends at the 20th after it. Checks:

- `milestones_boot.txt` in order (`sim/host_bridge/spitrace.py check`:
  UART lines and SPI frames), taken from the sources: the boot ROM lines,
  `MMC_Init`, `MINMGAR CFG` found (212 bytes), the configuration frames of
  that file (floppy `20 44 04`, the defaults would send `05`), the version
  reply `20 88 ff ff ff ff ff ff / xx 01 1a 0a 02 a4 fd` (computed from
  `fpga/openaars/minimig_version.vh` and the caps) and the banner it prints,
  the IDE port frames (`20 54 01`, `20 58 0b`: port 2 has the ATAPI CD), the
  kickstart lines (`Boot file size: 262144`, two `File size: 256kB`,
  `##End result : 1`), the release `20 08 03` / `20 08 00`, then 21
  HandleFpga frames; and its `NOT UART` lines: no `ROM loading failed`, no
  `Fatal error`
- no `EXC` / `TRAP` on the UART
- `l3check.py kick <run>`: the 256 KB the firmware uploaded equals `KICK.ROM`
  byte for byte at both places (Amiga 0xf80000 and the 0xfc0000 mirror,
  host 0x100000 / 0x140000, from `sdram.bin`)
- the RTC frame of the first main-loop pass, `80 92 ff ff ff ff ff ff ff /
  ff 00 00 00 01 04 01 26` (a milestone: `rtc_model`'s fixed time)
- `l3check.py order <run>`: the last SDRAM write into the kickstart region
  comes before the Amiga CPU's release (plan 7.1 item 14, "Monitors")
- `l3check.py mmc <run>`: `boot` runs with `+SD_LOG=1`; the firmware's
  `MMC_Init` card commands after the jump to 0x2000, up to the first CMD58,
  equal `gold/mmc_init_rv.txt` (the lines of
  `fw/ctrl_rv/test/gold/mmc_init_cmds.txt`, mmc_test's golden for the same
  card model)
- every `=== MARGIN` line present and `ok` ("Monitors")
- bench `=== PASS`: no X, no stale ack, OSD GAP >= 40, OSD EARLY 0, no
  MARGIN LOW

`NOKICK=1` builds the boot card without `KICK.ROM`: the firmware ends in the
fatal-error loop (`ROM loading failed`, no HandleFpga frame after the
first), the run fails at the main-loop milestone, and `run.sh` exits 0 when
it fails exactly there (the negative test).

`boot_short` is the xsim cross-check (it fits the xsim budget): `boot` cut
at the end of the first `OSD_CMD_READ` frame (`20 00`, ColdBoot's
`OsdGetKeyLevel()`) after the version frame, i.e. boot ROM, firmware load,
`MMC_Init`, `LoadConfiguration`, `fpga_init` with the real userio_osd, the
`BootInit()` boot screen and the banner, before the kickstart upload; it
checks `milestones_boot.txt` up to `#@ boot_short end`.
`XARGS=+SHORT_END=version` cuts at the end of the version frame instead.
The plan's cut, the 10th `20 0c` (`OSD_CMD_OSD_WR`) frame after the version
frame, does not exist on a card with a kickstart: the boot sends no OSD
text at all (in L2's `fwboot` those frames came from the error page).

### Measured (2026-10-19, RV, SLAT=8 SJIT=0, SCKDLY 1.5 / C28DLY 0.3, TICKDIV 1)

| Event | `clk_114` cycle |
|---|---|
| the boot ROM jumps to the firmware (first read of 0x2000) | 43,190,675 |
| `boot_short` end (the first `OSD_CMD_READ` after the version frame) | 57,659,090 |
| main-loop milestone (first HandleFpga frame) | 158,044,038 |
| `boot` end (the 20th HandleFpga frame after it) | 158,155,012 |

`L3_BOOT_TO` = 237,300,000 and `L3_SHORT_TO` = 86,500,000 (`run.sh`
defaults, 1.5 x the end events; `TIMEOUT=` overrides). The kickstart upload
takes most of the boot: the firmware is at its CPU reset for the upload at
67.0 M cycles and releases the Amiga at 157.0 M.

Speed: Verilator 0.38 M cycles/s alone (`boot` in 412 s), about 0.16 M
cycles/s with six Verilator runs and one xsim on the machine (`boot` 978 s);
xsim 2023.2 48 k cycles/s (`boot_short` in 1,191 s, with Verilator runs
alongside). The bench is slower than L2 (0.47 M cycles/s) by the Minimig
slaves on `clk_28` and their `#1` delays.

End of `boot` (p4t5e; the same in its `XRAND` twin p4t5e_xr; `STATS@boot`
counts up to the end event):

```
=== BOOT first read of 0x2000 at cycle 43190675, irefill 95 dread 99698 dwrite 125958 so far
=== KICK cpurst falls at cycle 52953181 (last kickstart-region SDRAM write so far: cycle 52953021)
=== KICK cpurst falls at cycle 156968829 (last kickstart-region SDRAM write so far: cycle 150139042)
=== MAIN first HandleFpga frame at cycle 158044038
=== END boot: HandleFpga frame 20 after the first at cycle 158155012
=== STATS@boot irefill 18048 dread 1454655 dwrite 1881249 busy_cycles 133194412 (rv_hostcpu, to cycle 158155012)
=== HW accesses 1685611, stale acks 0, X 0, SDRAM reads 92580 writes 1008672, main done 79381, cycles 158155021
=== STATS irefill 18048 dread 1454655 dwrite 1881250 busy_cycles 133194419 (rv_hostcpu, whole run)
=== SPI frames 1874, HandleFpga frames 21, KEYQ frames 20
=== OSD GAP min 44 over 26 bytes
=== STACK low 00001950 (1712 bytes used)
=== OSD EARLY 0 of 26 reply bytes
=== RTC transfers 1, writes 0
=== RTC CS high min none ns over 0 gaps (datasheet minimum: not found)
=== KICK last SDRAM write into the kickstart region at cycle 150139042 (host 0017fffc), 524594 writes
=== MARGIN 1 stale_acks min 0 count (bound 0, ok) over 1685611 hw accesses
=== MARGIN 3 dmode_release min none clk_114 (bound 0, n/a) over 0 direct transfers
=== MARGIN 3 dmode_L min none clk_114 (bound 0, n/a) over 0 direct transfers
=== MARGIN 4 paula_cs_release min 10.8 clk_114 (bound 0, ok) over 41 frames
=== MARGIN 4 userio_cs_release min 10.8 clk_114 (bound 0, ok) over 72 frames
=== MARGIN 4 paula_word_spacing min 117.0 clk_114 (bound 40, ok) over 82 words
=== MARGIN 4 userio_byte_spacing min 57.0 clk_114 (bound 40, ok) over 129 bytes
=== MARGIN 5 spi_write_busy min 0 count (bound 0, ok) over 829924 DATA writes
=== MARGIN 12 rtc_cs_high min none ns (bound 0, n/a) over 0 gaps
=== MARGIN 14 kick_order min 6829787.0 clk_114 (bound 1, ok) over 2 releases
ok   MARGIN lines: all 10 present, none LOW, 7 required ones ok
ok   milestones: 51 of 51 found in order
ok   no UART line contains 'ROM loading failed'
ok   no UART line contains 'Fatal error'
ok   PASS kick: KICK.ROM (262144 bytes) at Amiga 0xf80000 and 0xfc0000 (host 0x100000, 0x140000)
ok   PASS order: the last kickstart-region SDRAM write at cycle 150139042 (host 0017fffc), the CPU released at cycle 156968829, 6829787 cycles later
ok   PASS mmc: MMC_Init's 9 commands after the jump (CMD0 arg=00000000 ... CMD58 arg=00000000) = sim/l3/gold/mmc_init_rv.txt
ok   bench verdict: === PASS
=== boot PASS
```

`OSD EARLY` is 0 and the version reply is the one computed from the
sources: the RV firmware's four `SPIN`s per reply byte keep every reply
byte behind the synchroniser of the real userio_osd (`OSD GAP` 44 in
`boot`, 40 in `NOKICK`'s error loop, 1,532 bytes; E_osd is 34,
`findings/osd-riscv/phase4.md`). `STACK low` with a kickstart card is the
Phase 3 figure (0x1950, 1,712 bytes).

XRAND: the first twin differed in every HandleFpga frame (the track byte,
`paula_floppy.v`'s never-reset `dsktrack`); `XRAND=1` now pins it to 0 in
the run copy, as the bridge's and hostcache's reset-less flops are pinned
(`=== XRAND pinned 9 regs`), and the twin is SAME. The finding is in
`findings/osd-riscv/phase4.md`.

Async set / clear at time 0 (every run, both simulators, `run.sh
l3_pin_async`). A later twin, p4t5c_xr with seed 820757315, differed in
the MISO of the very first OSD frame: `20 08 06 / a8 00` instead of
`/ 00 00`.

- **Cause.** `userio_osd_spi.v` and `paula_floppy.v` set or clear some SPI
  registers with an edge-triggered asynchronous reset on the select
  (`always @(posedge sck or posedge _scs) if (_scs) ...`). Synthesis makes
  these level-sensitive preset / clear flops, and the selects are high
  from configuration on, so on the board the registers are held in that
  state from the start.
- **Simulators.** A simulator applies the reset only on an edge of the
  select:
  - xsim sees X -> 1 at time 0 as an edge.
  - Verilator's two-state build does not. Probed: `first_byte` was 0 at
    50 ns, so the boot ROM's first OSD frame had its command byte taken as
    data.
  - XRAND starts the registers random.
- **The pin.** The run copies initialise the registers to the held state:
  - `userio_osd_spi.v`: `bit_cnt` 0, `first_byte` 1.
  - `paula_floppy.v`: `spi_bit_cnt` 0, `spi_tx_cnt` 0, `spi_rx_cnt_rst` 1.

  With the pin, both simulators and the board agree: the probe shows
  `first_byte` 1 and command `08` decoded in the first frame. The twin pairs
  p4t5e / p4t5e_xr (default seed) and p4t5f / p4t5f_xr (seed 820757315) are
  SAME. This models the RTL as synthesised; it is not
  a defect of the RTL (`findings/osd-riscv/phase4.md`).

## 832

`CPU=832` runs the same scenarios and checks with the 832 host CPU: the
bridge with `cpu_riscv = false` (the EightThirtyTwo, the committed boot ROM
`fw/ctrl_boot_832/OSDBoot_832_ROM.vhd`) and `832OSDAD.BIN`, built from a
copy of the unchanged `fw/ctrl_832`. The card is the same `boot` card,
with both firmwares built in the run directory: the 832 boot ROM loads
`832OSDAD.BIN`, and the firmware reads `MINMGAA.CFG` (the RV firmware
reads `MINMGAR.CFG`; both files have the same fields). This is the other
leg of the 832-vs-RV differential (Task 7).

### Setup

The EightThirtyTwo tools (vbcc832, 832a / 832l, lib832) and its VHDL come
from an EightThirtyTwo checkout: the submodule, or in a git worktree
(where the submodule is not initialised) the main checkout's. On a fresh
machine, after the "Run" setup, from the repository root:

```sh
git submodule update --init EightThirtyTwo
E832DIR=$PWD/EightThirtyTwo
E832=$E832DIR/RTL
make -C "$E832DIR" vbcc
make -C "$E832DIR/832a"
make -C "$E832DIR/lib832"
```

`make vbcc` fetches vbcc 0.9g (wget), applies the volatile fix and builds
it; vbcc's configuration asks questions, the defaults are right on Linux
(EightThirtyTwo's Makefile). In a worktree set `E832DIR` to the main
checkout's `EightThirtyTwo` instead of the first three lines (the tools
are used in place; nothing is built there by the bench).

### Run

```sh
make -C sim/l3/fw832 E832DIR="$E832DIR"
CPU=832 E832="$E832" E832DIR="$E832DIR" SIM=verilator RUNTAG=b832 bash sim/l3/run.sh boot
CPU=832 E832="$E832" E832DIR="$E832DIR" SIM=verilator RUNTAG=bx832 bash sim/l3/run.sh xpair boot
CPU=832 E832="$E832" E832DIR="$E832DIR" SIM=verilator RUNTAG=s832 bash sim/l3/run.sh boot_short
CPU=832 E832="$E832" E832DIR="$E832DIR" RUNTAG=sx832 bash sim/l3/run.sh boot_short
bash sim/l3/run.sh compare sx832 s832
```

`sim/l3/fw832/Makefile` (`make -C sim/l3/fw832 B=<dir> E832DIR=<dir>`)
copies the tracked files of `fw/ctrl_832` to `<dir>/src` and builds them
there with fw/ctrl_832's own Makefile (`832DIR=$E832DIR`, targets
`version.h` and `832OSDAD.bin` only, so the tracked `bootcustominit.h` is
used and no 68k assembler is needed) with `date.sh` first on `PATH` as
`date`: every `date` prints `L3_DATE` (default 2026-01-01), so the version
strings and the image are the same in every build. Output:
`<dir>/832OSDAD.BIN`, `.map`, `832OSDAD.txt` (the sources' git state,
`L3_DATE`, size and sha256) and `make.log`. `fw/ctrl_832` is never built
in place (its tracked `version.h` would change). `run.sh` builds it into
`<run>/fw832` for `CPU=832`; `FW832=<file>` takes another image, for
either CPU (with `CPU=rv` and no `FW832` the card has the stand-in).

### What differs from the RV run

- Milestones: `milestones_boot.txt` lines `CPU=rv <line>` / `CPU=832
  <line>` hold for that CPU only: the file the boot ROM loads
  (`RV32OSDABIN` / `832OSDADBIN`) and the config file
  (`MINMGAR CFG` / `MINMGAA CFG`). The printed firmware version is the
  same, `Firmware version: 2026-1-1-0-0` in both (one `L3_DATE`).
- No `rv_hostcpu` counters: no `=== STATS` / `=== STATS@` lines, and the
  `=== BOOT` line has no counts. `boot_seen` (the first read of 0x2000)
  works for both CPUs.
- `EXTRA_WS` is the RV's (`rv_extra_ws`); `CPU=832` refuses another value
  than 0.
- `=== STACK low` is not the 832's stack depth: the firmware installs its
  interrupt handler by writing the vector word at 0x0d (lib832's
  `_InterruptVector`), the lowest write below 0x2000.
- Timeouts: `L3_BOOT_TO` / `L3_SHORT_TO` default to 1.5 x the 832's end
  events (below).

Two bench monitors were RV-shaped and now follow the hardware for both
CPUs (`sim/common/hostmon.vh`; L2 and the RV runs are unchanged by it):
the UART line printer takes every write cfide decodes as the transmit
register (`rs232_select`: address bit 23 and bits 7..4 = F; the RV writes
the word at 0xFFFFFFF0, the 832 firmware the byte at 0x0FFFFFF3), and the
OSD reply-gap monitor no longer assumes the command byte's read-back
(vbcc drops it: `SPI(OSD_CMD_VERSION)`'s result is unused), so a read is
the read-back of the write before it and every later write is a reply
byte's.

### The 832 under Verilator and xsim

The VHDL is converted with `ghdl --synth` as for the RV
(`sim/common/hostsim.sh` `hs_ghdl_convert` with `cpu_riscv=false`: the
EightThirtyTwo VHDL from `E832`, `sim/spi_cdc/host832/debug_bridge_stub.vhd`
for the debug bridge entity the bridge names, the ROM). Four things needed
a bench-side answer; the RTL and the sources in `E832` are not changed:

| What | Where | Why |
|---|---|---|
| the boot ROM's RAM is a `signal` written by two port processes | `hs_rom832`, both simulators: the run copy uses the RV ROM's `shared variable` template (same words, ports, processes) | in simulation the two processes are two drivers of the whole signal: a port A write resolves against port B's driver and reads back X (the 832's stack is in this BRAM); `ghdl --synth` refuses it ("multiple assignments for ram"). Synthesis infers one true-dual-port BRAM either way |
| ALU instance label `alu` | `hs_ghdl_convert`, the conversion's copy: `alu_unit` | GHDL 4.1 names an instance's output nets `<label>_<port>`; with outputs `q1 q2 carry ack` wired to signals `alu_q1` ... the output declares them twice |
| reset branch of the main process | `hs_ghdl_convert`, the conversion's copy: also clears `thread.d_imm`, `d_reg`, `d_alu_op`, `d_alu_reg1`, `d_alu_reg2`, `d_read_tmp`, `d_read_reg` | GHDL 4.1 drops the flops of the `thread` record's fields from `d_imm` on when some fields are reset and others not (the clock edge becomes a constant 0, each field a mux of itself: the decoded op never reaches the ALU and the CPU runs straight through its boot ROM; found by comparing bus traces with xsim, GHDL's own simulation of the VHDL agrees with xsim). The FPGA starts these flops at 0 and the bench resets once at time 0, so the state at the release is the same; xsim on the original VHDL is the cross-check |
| the register file's data registers (`regfile.tmp`, `gpr0..gpr6`) have no reset | `run.sh l3_e832_xsim`, xsim only: declaration initial value 0 | the boot ROM's first function prologue stores them to the stack: xsim's X on the bus (`write 0000158c data xxxxxxxx`, cycle 2627). The FPGA starts them at 0; Verilator's two-state build does too, and the XRAND twin randomises them |

`l3.vlt` waives `UNOPTFLAT` for the converted CPU: the `regfile` and
`thread` records are one vector each, and some fields are concurrent
assignments from other fields, a vector-level path, not a loop between
bits.

### Measured (2026-10-19, 832, SLAT=8 SJIT=0, SCKDLY 1.5 / C28DLY 0.3, TICKDIV 1)

| Event | 832 `clk_114` cycle | RV (section "boot") | 832 / RV |
|---|---|---|---|
| the boot ROM jumps to the firmware (first read of 0x2000) | 54,832,554 | 43,190,675 | 1.270 |
| `boot_short` end | 74,525,542 | 57,659,090 | 1.293 |
| the Amiga CPU released after the kickstart upload (the last cpurst fall) | 198,239,949 | 156,968,829 | 1.263 |
| main-loop milestone (first HandleFpga frame) | 202,610,912 | 158,044,038 | **1.282** (the 832 factor) |
| `boot` end | 202,841,132 | 158,155,012 | 1.283 |

`L3_BOOT_TO` = 304,300,000 and `L3_SHORT_TO` = 111,800,000 for `CPU=832`
(1.5 x the end events). `boot_short` is 74.5 M cycles, under the plan's
120 M limit, so the xsim cross-check runs the whole of it (no
`+SHORT_END=version`).

Speed: Verilator 0.29 M cycles/s for the 832 (p4t6e: `boot_short`, 74.5 M cycles in 257 s, with
one short L2 run alongside; the RV 0.38 M/s alone), 0.106 M cycles/s with
seven simulations on the machine (`boot` 1,918 s); xsim 2023.2
33 k cycles/s (`boot_short` in 2,282 s, with Verilator runs alongside; the RV
48 k cycles/s). The 832 bench is slower per cycle than the RV one: the
converted CPU is a flat netlist with the two record vectors that Verilator
re-evaluates (`UNOPTFLAT`).

Gate runs (`p4t6` / `p4t6_xr`, seed 639498575, `=== XRAND pinned 9 regs`;
`p4t6s`, `p4t6x`): `boot` PASS with milestones 51 / 51, kick, order and
mmc PASS (the 832's `MMC_Init` sends the 9 commands of
`gold/mmc_init_rv.txt`), every MARGIN line present and the 7 required ones
`ok`, X 0, stale 0, `OSD EARLY 0 of 26`, `OSD GAP min 254` (the 832's four
`SPIN`s per reply byte; the RV 44); the twin SAME (`tb_boot_*.log`,
`spi.txt`, 1,937 frames). `boot_short` on xsim SAME against Verilator
(`run.sh compare p4t6x p4t6s`: 2 same; xsim `X 0`).

| MARGIN | 832 `boot` | RV `boot` |
|---|---|---|
| 1 stale_acks | 0 of 1,685,709 | 0 of 1,685,611 |
| 4 paula_cs_release / userio_cs_release | 3.8 / 3.8 | 10.8 / 10.8 |
| 4 paula_word_spacing / userio_byte_spacing | 121.0 / 49.0 | 117.0 / 57.0 |
| 5 spi_write_busy | 0 of 844,721 | 0 of 829,924 |
| 14 kick_order | 13,589,729 | 6,829,787 |

## Differential

The RV and the 832 run of one scenario are compared after normalisation:
what remains different must be a rule of `sim/l3/expected_diff.txt`, each
with a comment naming its source. Setup as in "Run" and "832" (the 832
tools; in a worktree `E832DIR` = the main checkout's `EightThirtyTwo`).
Both runs must boot the same card, so both firmwares are built once and
given to both runs (`FW`, `FW832`); `run.sh diff` refuses two different
card images. From the repository root:

```sh
E832DIR=$PWD/EightThirtyTwo
E832=$E832DIR/RTL
FWD=$PWD/sim/l3/run_fw
mkdir -p "$FWD/dateshim" "$FWD/fwrv"
printf '%s\n' '#!/bin/sh' 'TZ=UTC exec /bin/date -d "${L3_DATE:-2026-01-01} 00:00:00" "$@"' > "$FWD/dateshim/date"
chmod +x "$FWD/dateshim/date"
PATH="$FWD/dateshim:$PATH" make -s -C fw/ctrl_rv B="$FWD/fwrv"
make -C sim/l3/fw832 B="$FWD/fw832" E832DIR="$E832DIR"
SIM=verilator RUNTAG=drv FW="$FWD/fwrv/RV32OSDA.BIN" FW832="$FWD/fw832/832OSDAD.BIN" bash sim/l3/run.sh boot &
CPU=832 E832="$E832" E832DIR="$E832DIR" SIM=verilator RUNTAG=d832 FW="$FWD/fwrv/RV32OSDA.BIN" FW832="$FWD/fw832/832OSDAD.BIN" bash sim/l3/run.sh boot &
wait
bash sim/l3/run.sh diff --unused-rules drv d832
bash sim/l3/test/spitrace_test.sh
```

(the date shim is the one `run.sh` uses, so `FWD/fwrv` is the image a
default RV run would build; the two `boot` runs take about 10 and 15
minutes side by side.)

What a run writes for it (`sim/common/hostmon.vh`, every L3 scenario):

| File | Lines |
|---|---|
| `spi.txt` | the SPI frames (section "Bench") |
| `hw.txt` | `<frames> <ev> <addr> <value16>` per hw-register write except SPI DATA / CS, the UART and the L2 bench registers 0x..00 / 04; `addr` = the 24 bits cfide decodes (the RV's 0xFFFFFFB0 and the 832's 0x0FFFFFB3 are both `ffffb0`), `value16` = cfide's d (a byte write: 00 and its byte); at the end `MEM <region> <sha256>` per SDRAM region the CPU wrote (`kickstart` host 0x100000..0x17ffff, `audio_ring` 0x70000..0x7ffff), hashed from `sdram.bin` by `l3check.py memhash` |
| `uart.txt` | `<frames> <ev> <text>` per UART line |

`<frames>` is the number of `spi.txt` lines before the event and `<ev>`
one counter over both files: the order without the cycles.

`run.sh diff <rv run> <832 run>` runs `spitrace.py norm` on each
(`<run>/norm.txt`) and `spitrace.py diff` on the two: a unified diff, exit 0
only when it is empty. `norm` writes one stream in frame order,
`<STREAM> <text>` per line:

- **dropped poll frames** (their number depends on the CPU's speed):
  FPGA status frames (`10` and six 00 bytes) without a request (MISO 0
  bits 3..0: track read / write, IDE command / data) whose MISO bytes equal
  the previous status frame's (HandleFDD also acts on the drive count,
  track and motor bytes, so a frame where one changed is kept; a request
  is always kept), FPGA
  drive-status frames (`10 10 <s>`, after every HandleFpga) whose `<s>`
  is the previous one's, `OSD_CMD_READ` (`20 00`) whose level is the
  previous one's, `OSD_CMD_KEYQ` (`20 98`) with status 00 (no event, no
  overflow), every RTC frame (`80`), the SD deselect clocks (cs `00`, all
  MOSI ff). A request, a changed status frame, level or drive status, a
  queued key stays. Every file is read as latin-1, byte for byte (a UART
  byte >= 0x80 stays itself)
- `SD CMD<n> <lba or arg> R<r1> [rd|wr <sha256 per block>]`: one line per
  card command (CMD8 / CMD58 with their response bytes, writes with the data
  response `D<xx>`)
- `OSD <row> <text>`: `OSD_CMD_OSD_WR` frames decoded with
  `fw/ctrl_rv/charrom.h` (`stripe=<hash>` for the side stripe,
  `{inv:...}` inverted characters, `{xx ...}` columns that are no
  character); `spitrace.py osd <spi.txt>` prints the pages
- `SPI <cs> <MOSI> / <MISO>`: every other frame, unchanged
- `HW <addr> <value16>`, `HW MEM <region> <sha256>`, `UART <text>`
- then the rules of `expected_diff.txt`, in file order:
  `SUBST <stream> <regex> <replacement>`, `DROP <stream> <regex>` (stream
  `uart`, `osd`, `hw`, `sd`, `spi` or `all`; the regex has no blanks,
  `\x20`), `DROPBLOCK <stream> <start-regex> <end-regex>` (from a line of
  the stream matching the start to the next one matching the end, both
  included, every line of any stream; a start without its end is an
  error), `SDFILE <8.3 name> <alias>`: an access inside the file's
  clusters (read from the run's card) is `CMD<n> <alias>+<offset>` without
  its data hash, and a run of them is one line (the hw writes and other card
  accesses inside the run are printed once): `RV32OSDA.BIN` and
  `832OSDAD.BIN` are both `FIRMWARE+00000000 ..`. A rule without a comment
  line above it is refused
- `# rule <line> used <n>` and `# dropped ...` lines (not compared):
  `diff --unused-rules` prints `UNUSED <line>: <rule>` for a rule neither
  run used, and exits 1

`sim/l3/test/spitrace_test.sh` (a few seconds, `mkcard.sh`'s tools) checks
the tools on generated fixtures: other poll counts and the fixture's
rules give an empty diff; one changed byte in an SD read, an FPGA frame, an
OSD text line, a hw write, a UART line, a KEYQ event, a status frame with
a request, a new drive status (`10 10 <s>`), a cs `00` frame that is not
all ff, and the lines just before and after a `DROPBLOCK` block each give a
diff line; a `DROPBLOCK` start without its end fails `norm`; each rule
removed in turn brings its difference back; an unused rule is reported.

The rules of `boot` (`expected_diff.txt`): the firmware file
(`SDFILE` of both names, the UART line with the name and the boot ROM's
one `0` per sector), the config file (`SDFILE` of `MINMGAR.CFG` and
`MINMGAA.CFG`, the UART name), `fmt_diff_expected.txt` line 275 (the
832's `partition type: 0x0`), the 832's spurious "Overriding screenmode."
pass (a `DROPBLOCK` up to its `##End result : 0`: an 832-only firmware
defect, `findings/osd-riscv/phase4.md` "Findings for Paul") and the RV-only
`IRQ_MASK` write (`HW ffff34`, `fw/ctrl_rv/arch/irq.c`). With them, the
`boot` diff (runs `p4t7r2`, `p4t7c2`) is empty and all 9 rules are used.

## keys

`keys` drives the OSD keys: `bfm_keys.v` sets userio_osd's `osd_ctrl` (the
keyboard's OSD code; 0 in every other scenario) from a key script, and the
firmware's menu runs on the real userio_osd. It boots the `boot` card like
`boot` and starts the script (`+KEYS=`, run.sh `KEYS`, default
`keys/menu_tour.txt`) at the main-loop milestone; the end event is the
script's end. TIMER: `+TICKDIV=643 +TICKDIV_AT=scenario` (run.sh): the boot
runs at TICKDIV 1, the script at the board's rate, so the firmware's key
repeat (`REPEATRATE` 25 counts), help text (`HELPTEXT_DELAY` 2,500) and CD
message (4,000) timers do not run out inside the script (at TICKDIV 1 the
help text would start scrolling 2.6 M cycles into an idle page, a number of
OSD writes that depends on the CPU's speed).

The script (`bfm_keys.v` has the syntax): `KEY <code> <hold>` (the code,
then 0 after the hold: two queue events), `BURST <code> ...` (one change
every 32 `clk_114`), `WAIT_OSD_IDLE <cycles>` (no `OSD_CMD_OSD_WR` frame
open or closing for that long, counted from the step's start),
`WAIT_KEYQ <n>`. `menu_tour.txt` opens the OSD (`KEY_MENU`), walks down
the main page over all six selectable lines and up again, enters the
Floppy page (down twice, `exit`) and the Harddisks page (`KEY_ESC` back),
sends one `BURST 4c 00 4d 00 4c 00` (three presses, up / down / up, each
with its release: six events) and closes the OSD with `KEY_MENU`.

Two rules keep the run independent of the CPU's speed, each enforced by a
bench error:

- Every `KEY` / `BURST` comes right after a KEYQ frame that drained
  nothing (`WAIT_OSD_IDLE`, then `WAIT_KEYQ 1`; `bfm_keys` checks the last
  frame's status byte). The next KEYQ frame then takes all of the step's
  events: a main-loop pass is at least 5,320 `clk_114` on the RV and
  11,244 on the 832, the `BURST` takes 192. While the firmware still hands
  out drained events (one per pass), `OSD_CMD_READ` could see a new code
  with no event to deliver, and `OsdGetCtrl` turns that into a key repeat
  when its TIMER says so.
- No `OSD_CMD_READ` frame while a key is held (`tb_l3.v`): the holds are 64
  `clk_114`, far shorter than the time to the next level read, so the key
  repeat never sees a held key.

Found on the way (both firmwares, `findings/osd-riscv/phase4.md` "Shared
defects"): `OSD_CMD_READ`'s answer is the byte userio_osd_spi loads at the
frame's start, the read data of the *previous* command (`userio_osd.v`
`rddat` under the old `cmd_dat`). In the main loop that command is the
previous pass's `OSD_CMD_KEYQ`, so the "level" is the queue's head or 0,
not `osd_ctrl` (run p4t8, spi.txt line 1877: `20 00 / 4d` 6,325
`clk_114` after the key was released, just before the frame that drains
it). Only the key repeat reads it.

Checks: boot's milestones (`milestones_boot.txt`, so the main loop was
reached), no `EXC` / `TRAP`, kick and order (as `boot`), every MARGIN line
(`MARGIN_REQ_keys` = boot's), bench `=== PASS` (with `OSD EARLY 0` unless
`+OSD_EARLY_OK=1`) and `l3check.py keys`:

- the events the bench made (`=== KEYS ev` lines) are the script's
- the KEYQ frames against the queue as a FIFO (`spi_t.txt`): each status
  byte is the number of events made before the frame and not yet read, each
  per-key byte the queue's head (a wrong one counts as read: the RTL pops
  on every byte), nothing left at the end; no event while a KEYQ frame is
  open
- each `KEY` / `BURST` step's events in one KEYQ frame, the `BURST` with
  count 6
- the `OSD_CMD_VERSION` reply equal to `milestones_boot.txt`'s
- no `OSD_CMD_OSD_WR` frame before the first key: the boot draws no page,
  so one there is an error page, which the main-loop milestones alone
  cannot tell from the main loop
- the OSD pages (decoded as `spitrace.py osd`, after the `osd` / `all`
  `SUBST` and `DROP` rules of `expected_diff.txt`) equal
  `osdtext_expect/keys.txt`

It prints `REPLY <cmd> byte <k>: <r> of <n> right` per reply byte, and the
bench `=== OSD REPLY <cmd> byte <k>: gap min <g> over <n> writes, early
<e> of <m> loads` (hostmon's OSD GAP and the OSD EARLY monitor per byte):
the "before" table of `findings/osd-riscv/phase4.md` (Task 8).

`osdtext_expect/keys.txt` is written by `osdtext_expect/osdpages.py keys`
from the sources, before any run: a model of `fw/ctrl_rv/osd.c`'s
`OsdSetTitle` / `OsdWriteOffset` / `OsdClear` (so the side stripe, arrows,
inverted and stippled lines come out byte for byte) and of the `menu.c`
pages the tour passes, with the line numbers they come from and the boot
card's configuration (two floppy drives, no disk; IDE on, two hardfiles
not on the card; the CD slot with no disc). Its rows are decoded with
`spitrace.py`'s own decoder; `l3check.py keys` fails when `keys.txt` is
not what `osdpages.py keys` writes. After a change to the script or the
menu:

```sh
python3 -I sim/l3/osdtext_expect/osdpages.py keys > sim/l3/osdtext_expect/keys.txt
```

Run, setup as in "Run" and "832" (both legs boot the same card, as in
"Differential"; the RV firmware polls the reply-ready handshake since
Phase 4 Task 11, so no `+OSD_EARLY_OK=1`: `OSD EARLY` must be 0), from the
repository root:

```sh
E832DIR=$PWD/EightThirtyTwo
E832=$E832DIR/RTL
FWD=$PWD/sim/l3/run_fw
mkdir -p "$FWD/dateshim" "$FWD/fwrv"
printf '%s\n' '#!/bin/sh' 'TZ=UTC exec /bin/date -d "${L3_DATE:-2026-01-01} 00:00:00" "$@"' > "$FWD/dateshim/date"
chmod +x "$FWD/dateshim/date"
PATH="$FWD/dateshim:$PATH" make -s -C fw/ctrl_rv B="$FWD/fwrv"
make -C sim/l3/fw832 B="$FWD/fw832" E832DIR="$E832DIR"
SIM=verilator RUNTAG=k FW="$FWD/fwrv/RV32OSDA.BIN" FW832="$FWD/fw832/832OSDAD.BIN" bash sim/l3/run.sh xpair keys
CPU=832 E832="$E832" E832DIR="$E832DIR" SIM=verilator RUNTAG=kc FW="$FWD/fwrv/RV32OSDA.BIN" FW832="$FWD/fw832/832OSDAD.BIN" bash sim/l3/run.sh xpair keys
bash sim/l3/run.sh diff k kc
```

(the two `xpair`s run four simulations; side by side 22 minutes for the RV
pair, 31 for the 832 pair, with a fifth run on the machine.)

### The handshake's teeth (Phase 4 Task 12)

`RDY_MUT=1` makes the run copy of cfide (`<run>/src/cfide.vhd`, never the
tree's) answer `OSD_RDY` = 1 whatever the counts say, like `sim/spi_cdc/run.sh`'s
`RDY_MUT` (an exact-count check on the `-- OSD RDY` line). The firmware
without the poll is another image: a copy of `fw/ctrl_rv` from git `HEAD`
outside the tree, built under the date shim (`FWD` as above):

```sh
D=$FWD/nopoll
mkdir -p "$D"
git archive HEAD fw/ctrl_rv tools/riscv | tar -x -C "$D"
sed -i 's/if (!(HOST_REQ & HOST_REQ_OSD_RDY)) {/if (0) {/' "$D/fw/ctrl_rv/hardware.c"
grep -c 'if (0) {' "$D/fw/ctrl_rv/hardware.c"
PATH="$FWD/dateshim:$PATH" make -s -C "$D/fw/ctrl_rv" B="$D/build"
SIM=verilator RUNTAG=m1c RDY_MUT=1 XARGS=+FAST_HW=1 FW="$FWD/fwrv/RV32OSDA.BIN" FW832="$FWD/fw832/832OSDAD.BIN" bash sim/l3/run.sh keys
SIM=verilator RUNTAG=m2 FW="$D/build/RV32OSDA.BIN" FW832="$FWD/fw832/832OSDAD.BIN" bash sim/l3/run.sh keys
```

(`grep -c` must print 1.) Both must exit 1 (`=== keys FAILED`): `m1c` with
`OSD EARLY 1 of 450` and `version reply byte 2: 1a, want 0a`, `m2` with
`OSD EARLY 3 of 6`, the repeated VERSION bytes and no KEYQ frame. The
default-timing run of the cfide mutant fails on `OSD GAP min 27` alone
(`OSD EARLY 0`): the `FAST_HW` bus is what makes its one remaining poll
read too quick for the synchroniser. Figures: `findings/osd-riscv/phase4.md`,
"Task 12".

### Measured (2026-10-19, SLAT=8 SJIT=0, SCKDLY 1.5 / C28DLY 0.3, TICKDIV 1 then 643)

| | RV (`p4t8`, `+OSD_EARLY_OK=1`) | 832 (`p4t8c`) |
|---|---|---|
| main-loop milestone (script start) | 158,045,126 | 202,610,912 |
| end of the script | 165,059,293 (+7.01 M) | 215,391,641 (+12.78 M) |
| KEYQ frames (with events) | 354 (22) | 144 (22) |
| main-loop pass in the open menu, min / median (`p4t8d`, `p4t8dc`) | 5,320 / 7,108 | 11,244 / 13,324 |
| `OSD EARLY` | 0 of 408 | 0 of 198 |
| `OSD GAP` min: VERSION / KEYQ status / per-key bytes | 44 / 295 / 56 | 254 / 306 / 338 |
| `l3check.py keys` | PASS: 48 events, BURST one frame, count 6, 24 pages | the same |
| wall time (Verilator, 5 runs on the machine) | 1,281 s | 1,824 s |

After the handshake (Task 12, `p4t12`, no `+OSD_EARLY_OK`): the script
ends at 164,861,841 (milestone 157,844,924), KEYQ frames 366, `OSD EARLY` 0
of 420, `OSD GAP` min 43, `l3check.py keys` PASS, wall 1,653 s (six runs on
the machine); the same `keys` with `+FAST_HW=1`, and in the skew pairs
0.3 / 4.0 and 9.5 / 0.3, also `OSD EARLY` 0; `run.sh diff p4t12 p4t12c`
(832) empty. The per-byte before/after table is in
`findings/osd-riscv/phase4.md`, "Task 12".

`L3_KEYS_TO` = 247,400,000 (RV) and 321,300,000 (832): 1.5 x the end of
the script. The per-byte figures are the "before" table of
`findings/osd-riscv/phase4.md`. `run.sh diff p4t8 p4t8c` is empty with the
9 rules of `boot` (all used; `keys` reaches no line of
`fmt_diff_expected.txt`: the only formatted number on its pages is
"Floppy drives : 2").

XRAND: the RV twin `p4t8_xr` is SAME. The 832 twin `p4t8c_xr` (seed
505647130) has the same `spi.txt` but other cycles from the first frame on
(the first hw access at 2,644 instead of 2,641): the EightThirtyTwo starts
from random state that changes its timing, a property of the 832 build
that the `boot` twin of Task 6 did not show only because of its seed
(`findings/osd-riscv/phase4.md`, "Found by the L3 bench (Task 8)"). With a
seed whose 832 start matches (`XSEED=4`, run `p4t8c_xs4`) the twin is
SAME: the rest of the bench, userio_osd and `bfm_keys` start from random
state without effect.

Teeth (not committed): `p4t8red`, a script that applies a key right after
the KEYQ frame that drained the previous one, fails with `BENCH ERROR:
bfm_keys ... key applied after a KEYQ frame that drained events`.
`l3check.py keys` on edited copies of the `p4t8d` log and `spi_t.txt`
fails for each of: a wrong per-key byte in the BURST frame, the BURST split
into two frames of three, a changed character column of an OSD row, an
`OSD_CMD_OSD_WR` frame before the first key, a frame one per-key byte
short, a stale status byte (00, the events read one frame later) and a
missing `=== KEYS ev` line; the unedited copy passes.

## Monitors

`mon_l3.vh` (included by `tb_l3.v`) measures the host-side handshakes of
plan 7.1 that depend on timing, in every run, and prints one line per
measurement before the verdict:

```
=== MARGIN <item> <name> min <value> <unit> (bound <b>, <verdict>) over <n> <events>
```

`<value>` is the smallest seen. Items 1 and 5 are counts: the value is the
count and `LOW` means above the bound. The verdict:

| Verdict | Meaning |
|---|---|
| `ok` | events seen, the value can violate its bound, and it does not |
| `LOW` | events seen, the bound is violated: a bench error, the run fails |
| `n/a` | no such event in this run (`min none`) |
| `rec` | events seen, record only: the value cannot violate its bound. `dmode_L` (the request always follows the ack) and `rtc_cs_high` with the default bound 0 (a gap is never negative) |

`run.sh` fails a scenario unless all ten lines are there and none is
`LOW`. Each scenario also lists the lines that must have seen events
(`MARGIN_REQ_<scenario>` in `run.sh`); for those, `n/a` or `rec` fails it
too. A monitor that stops seeing its events therefore cannot pass in
silence:

| Scenario | Lines that must be `ok` | `n/a` there, and why |
|---|---|---|
| `boot` | 1, 4 (all four), 5, 14 | 3 (no direct transfer), 12 (one RTC transfer, no gap) |
| `boot_short` | 1, `userio_cs_release`, `userio_byte_spacing`, 5 | 3, 12, the paula lines (no paula frame before the cut); its `kick_order` is fpga_init's reset pulse, not a kickstart release, so it is not required |

Times are taken at the slave pins: an `sck` edge reaches the slaves
`+SCKDLY` ns after cfide's pin, `sd_cs` undelayed.

| Item | Name | What | Bound | `boot` (p4t5e) |
|---|---|---|---|---|
| 1 | `stale_acks` | hostmon's stale-ack count (an ack no `clk_28` edge saw the request for) | 0 | 0 of 1,685,611 hw accesses |
| 3 | `dmode_release` | a direct-mode transfer (`sd_cs[6]` low): its last (4096th) `sck` rising edge at paula to `direct_scs` released (`sd_cs[6]` rising), `clk_114` | 0 | n/a (`boot` has no direct transfer); 108.8 ok in the probe run below |
| 3 | `dmode_L` | the RDSPI ack (a DATA read acked while `sd_cs[6]` is low) to the DisableDMode request (CS write 41), `clk_114`: `sim/spi_cdc/host832/tb_832_dmode.v`'s `L` | 0, `rec` | n/a; 6.0 rec in the probe run |
| 4 | `paula_cs_release`, `userio_cs_release` | per slave (`sd_cs[4]` paula, `sd_cs[5]` userio_osd): the last `sck` rising edge of a frame at the slave to its select rising, `clk_114` | 0 (derived below) | 10.8 over 41 frames; 10.8 over 72 frames |
| 4 | `paula_word_spacing`, `userio_byte_spacing` | the last edge of one received word (paula, 16 bits, `sd_cs[4]` or `[6]`) / byte (userio, 8) to the last edge of the next, `clk_114` | 40 (derived below) | 117.0 over 82 words; 57.0 over 129 bytes |
| 5 | `spi_write_busy` | SPI DATA writes acknowledged without starting a transfer of their own (no `SD_busy` rise from the request to the cycle after its ack): taken while the shifter was busy | 0 | 0 of 829,924 |
| 12 | `rtc_cs_high` | `rtc_model`: the CS-inactive time between two RTC transfers, ns | `+RTC_CSH_MIN`; the default 0 (datasheet not found, below) makes it `rec` | n/a (one RTC transfer in `boot`); 363,982,789 ns rec in the `rtc2` run below |
| 14 | `kick_order` | the last `cpurst` fall (userio_osd releases the Amiga CPU) minus the last SDRAM write into the kickstart region (host 0x100000..0x17ffff, `sdram_host_model` at its ack), `clk_114` | 1 (the write lands first) | 6,829,787 (write at 150,139,042, release at 156,968,829) |

Also printed: `=== KICK cpurst falls at cycle <n> ...` at every fall,
`=== KICK last SDRAM write into the kickstart region at cycle <n> (host
<a>), <k> writes` (what `l3check.py order` reads), `=== RTC transfers <n>,
writes <m>` and `=== RTC CS high min <ns> ns over <k> gaps (datasheet
minimum: not found)`. `boot_short` prints the same lines; its `kick_order`
is the reset pulse of `fpga_init` (no kickstart yet), so only `boot`'s
`order` check reads item 14.

### Item 4: the bounds from the RTL

The plan's bound, "2 `clk7_en` periods = 32 `clk_114`", assumed that a
select released too early cuts the last byte. The RTL says otherwise, so
the release bound is 0. The synchroniser latency the plan meant is up to 40
`clk_114`, and it bounds something else: the spacing of the next byte or
word on the same slave.

- `rtl/minimig/userio_osd_spi.v`: `_scs` asynchronously resets `bit_cnt`
  (already 0: three bits wrap after the eighth edge) and sets `first_byte`
  (for the next frame), and it gates `sdo`. The received byte (`out`),
  `cmd` and `new_byte` are written on `sck` edges only. `rx_sync` follows
  `new_byte` on `clk7n_en`, `rx` follows `rx_sync` on `clk7_en`, and
  `userio_osd.v`'s consumers (`rx && cmd`, `rx && !cmd`) never look at
  `_scs` (its `vld` / `spi_invalidate` drives nothing: the one use is
  commented out).
- `rtl/minimig/paula_floppy.v`: `~scs` resets `spi_bit_cnt` (wrapped to 0),
  `spi_tx_cnt` (the transmit side) and sets `spi_rx_cnt_rst` (for the next
  word). `rx_data`, `spi_rx_flag`, `spi_rx_cnt` and, since 202e077,
  `rx_direct` are written on `sck` edges. `rx_flag` comes through
  `rx_flag_sync` (`clk7n_en`) on `clk7_en`. The consumers (`cmd_*`,
  `hdd_wr`, `hdd_data_wr`, `spidat`) use `rx_flag` and `rx_cnt` only.

So the select may rise any time after the slave's last `sck` edge: the bound
is 0. A negative value means the slave sees its last edge after the select
rose, and the async reset clears the bit counter before the last bit.
Measured: 10.8 `clk_114` on both slaves.

At cfide's pins the release cannot come early. cfide holds a CS write
(and every SPI register access) until `SD_busy` is 0, and `SD_busy` falls
one SPI half-period (3 `clk_114` at speed 1) after the last edge. So the
CPU can only make the figure larger. It goes negative only if the slaves
see `sck` later than their select by more than that distance, which is a
clock-routing delay (the red case below, `+SCKDLY`), not a firmware timing.

The synchroniser: a byte's last edge sets `new_byte` / `spi_rx_flag` at
t0. The first `clk7n_en` edge after it comes within 16 `clk_114` and takes
it into `rx_sync` / `rx_flag_sync`. `rx` / `rx_flag` follow at the
`clk7_en` edge 8 `clk_114` later (`amiga_clk.v`: `clk7_en` two `clk_28`
after `clk7n_en`). The consumers see them, and read `out` / `rx_data`, at
the `clk7_en` edge after that, 16 later. That makes at most 16 + 8 + 16 =
40 `clk_114` from t0. The next byte's or word's last edge must come later:
it overwrites `out` / `rx_data`, and its flag would merge with the
pending one. The SPI clock sets the floor of this spacing: the next
byte's eighth edge cannot come sooner than eight bit periods after the
last one, plus cfide's hold of the next write until `SD_busy` falls. At
speed 1 a bit takes 6 `clk_114`, so 8 bits take 48 and 16 take 96,
whatever the CPU does. The firmware's minima are 57 and 117. Only a
faster SPI speed can break it: speed 0, 2 `clk_114` per bit, in the red
case below.

### Item 12: the RTC

`fw/ctrl_rv/rtc.c` does not name its part. The board's RTC is the NXP
PCF2123 (plan 7.1 item 12, `doc/hardware.md`, `rtl/openaars/pcf2123`).
`rtc.c` sends `0x92` = read, subaddress 001, register 2 (Seconds), then
reads Seconds, Minutes, Hours, Days, Weekdays, Months, Years. Its comment
says "register 0000"; the code reads from register 2. `rtc_model.v`
answers that protocol with the fixed BCD time 2026-01-01 00:00:00 (weekday
4) and records writes, so the RTC frame is the same in every run:
`80 92 ff ff ff ff ff ff ff / ff 00 00 00 01 04 01 26`. This is the
`milestones_boot.txt` line; `boot` at SLAT 8 (p4t5e) and the `rtc2` run
at SLAT 4 (p4t5rtce, both frames) give the same bytes.

**Datasheet minimum: not found.** `doc/rtc` holds `OKI MSM6242B.pdf` (the
parallel clock-port RTC the PCF2123 is presented to the Amiga as), a clock
port manual and HTML pages; no PCF2123 datasheet. The bound is therefore
0, and the record is the firmware's own spacing. `HandleRTC()` reads the
RTC on the first main-loop pass and then every 8,192 passes
(`(c++&8191)==0`), so `boot` (20 passes) has one transfer and no gap.
`XARGS=+BOOT_END=rtc2` ends `boot` at the second RTC frame instead and
measures it: 363,982,789 ns = 41.3 M `clk_114` at SLAT 4 (p4t5rtce), 389,857,255
ns = 44.2 M at SLAT 8 (p4t5r12e), TICKDIV 1. Both are 8,192 passes of the
main loop, so the figure follows the loop's speed. It is milliseconds
apart from any bound a datasheet could give. `+RTC_CSH_MIN=<ns>` sets a bound once the datasheet value is
known.

On this board the firmware's RTC frame reaches no chip: `minimig_openaars_top.v`
leaves the virtual top's `RTC_CS` (`SPI_CS[7]`) unconnected, and the
PCF2123 is read by `rtl/openaars/pcf2123/rtc_spi_clock.sv` on its own pins
(`findings/osd-riscv/phase4.md`).

### Teeth (red cases, not committed)

Each monitor was shown to fail, in a run copy of the bench (sim/l3 copied
elsewhere with `ROOT` pointed back at the tree), with a plusarg, or offline
on a copy of a log. The "probe" firmware is `fw/ctrl_rv` built with one
bench-only constructor linked in (`make -C fw/ctrl_rv EXTRA_OBJS=probe.o`,
as `sim/host_bridge/fwboot/smoke_trap.c`). It runs before `main`: two SPI
DATA writes back to back with no read-back, one paula frame (`10`, two
bytes), then `MMC_Init()` and `MMC_Read(0, 0)` (one direct-mode sector).
Probe v3 adds a 4-byte paula frame and a 4-byte userio frame (command 00)
at SPI speed 0. The red runs were repeated on the tree with the verdicts
and the async pins (RUNTAGs below; the first round, p4t5r1a, p4t5r34b,
p4t5r4s, p4t5r5a and p4t5r12b, gave the same values). The probe runs end
at `TIMEOUT=46000000`, just after the probe,
so their verdict is FAIL (end event not reached); the MARGIN lines are what
counts.

| Item | Red case | RUNTAG | Result | Green |
|---|---|---|---|---|
| 1 | run copy: `832_bridge.vhd`'s `-- 4PHASE` line becomes `state <= waiting;` and `rv_hostcpu.v` gets the fast master (both exactly as `sim/host_bridge/run.sh` `mutant`'s gate leg), `boot_short`, `TIMEOUT=10000000` | p4t5r1e | `stale_acks min 1184 count (bound 0, LOW)` | p4t5e: 0 |
| 3, 4 | probe v2, `XARGS=+SCKDLY=1000` (the slaves see `sck` 1 us late) | p4t5r34e | `dmode_release min -4.4 LOW`, `paula_cs_release min -87.4 LOW`, `userio_cs_release min -102.4 LOW` | probe v2 without the plusarg, p4t5p35e: 108.8 / 25.8 / 10.8 ok, `dmode_L` 6.0 rec |
| 4 spacing | probe v3 (SPI speed 0: 2 `clk_114` per bit) | p4t5r4se | `userio_byte_spacing min 24.0 (bound 40, LOW)`; `paula_word_spacing` 48.0 stays ok (16 bits cannot come closer than 32 plus the access) | p4t5e: 57.0 / 117.0 |
| 5 | run copy: cfide's support state machine acknowledges an SPI write while `SD_busy` (`IF SD_busy = '0' or wr = '1' THEN`), probe v1 (v2 without the paula frame) | p4t5r5e | `spi_write_busy min 92934 count (bound 0, LOW)`, from the boot ROM on | p4t5p35e: 0 (the probe's second write is held) |
| 12 | `XARGS="+BOOT_END=rtc2 +RTC_CSH_MIN=1000000000"`, `TIMEOUT=300000000` | p4t5r12e | `rtc_cs_high min 389857255.3 ns (bound 1000000000, LOW) over 1 gaps` | p4t5rtce: 363982789.0, rec (bound 0) |
| 14 | `l3check.py order` on a copy of `run_p4t5/tb_boot_x0_s8_j0.log` with the last kickstart write moved to cycle 156,968,900 (after the release at 156,968,829) | offline | `FAIL order: the last kickstart-region SDRAM write (cycle 156968900, ...) is not before the last cpurst fall (cycle 156968829)` | `PASS order` on the log |
| required events | `run.sh`'s `margins` with `boot`'s `MARGIN_REQ_boot` on a `boot_short` log (p4t5cs: no paula frame) | offline | `BAD  MARGIN 4 paula_cs_release is n/a: scenario boot must check it (MARGIN_REQ_boot)`, the same for `paula_word_spacing` | the same log as `boot_short`: `ok   MARGIN lines: all 10 present, none LOW, 4 required ones ok` |
| MMC | `l3check.py mmc run_p4t5 <golden>` with the first `ACMD41 arg=40000000` changed to `arg=00000000` | offline | `FAIL mmc: command 4 is ACMD41 arg=40000000, the golden ... says ACMD41 arg=00000000` | `PASS mmc: MMC_Init's 9 commands` |

The RTC measurement and its red case, from the repository root (about
220 M cycles each, 10 to 20 minutes):

```sh
SIM=verilator RUNTAG=rtc SLAT=4 TIMEOUT=300000000 XARGS=+BOOT_END=rtc2 bash sim/l3/run.sh boot
SIM=verilator RUNTAG=rtcred TIMEOUT=300000000 XARGS="+BOOT_END=rtc2 +RTC_CSH_MIN=1000000000" bash sim/l3/run.sh boot
```

## Cards

`sim/l3/card` builds the SD card images the L3 scenarios boot, and
`sim/l3/gen` holds the generators of everything on them. Nothing on a card is
copyrighted: the kickstart is a synthetic 256 KB file, the drive sounds file
is the project's own (`sw/mkdrivesounds/drivesnd.bin`). Images are built,
never committed; `sim/l3/card/manifest.txt` lists name, size and sha256 of
every generated file and image, so a generator change shows in review.

Setup on a fresh Ubuntu 24.04, bash or zsh, from the repository root:

```sh
sudo apt install build-essential make python3 mtools dosfstools fdisk xorriso ghdl verilator ccache iverilog
bash tools/riscv/fetch-xpack.sh
bash tools/riscv/check-toolchain.sh
make -C fw/ctrl_rv
```

The cards need `fw/ctrl_rv/build/RV32OSDA.BIN` (the last line) and,
for the 832 twin, `832OSDAD.BIN` (`make -C sim/l3/fw832`, section "832").
Without `FW832` a deterministic 84 KB stand-in takes its place.

Build the cards and run the proof (one minute; output in
`sim/l3/card/build/`, `B=<dir>` puts it elsewhere):

```sh
make -C sim/l3/card cards FWRV=fw/ctrl_rv/build/RV32OSDA.BIN
make -C sim/l3/card check FWRV=fw/ctrl_rv/build/RV32OSDA.BIN
```

`check` builds every card twice, two seconds apart, in two directories and
compares the bytes; runs `fsck.fat -n` on each image; lists each root
directory with `mdir` against the names the card should hold; reads the config
files back from the images and compares `cfgconv --check` with the field
table `gen/mkcfg.py` was given; prints the CHS of `SYNTH.HDF` and requires
more than 255 cylinders; and compares `manifest.txt` with a fresh stand-in
build. It ends with `check PASS`. The bytes of `TEST.ISO` depend on the xorriso version (the committed manifest was made with 1.5.6): on another version `check` can fail with "manifest.txt is stale", and `make -C sim/l3/card manifest` regenerates it. After a change to a generator,
`make -C sim/l3/card manifest` rewrites `manifest.txt`.

One card, with real firmware files (the 832 one from your own build):

```sh
make -C sim/l3/card hdd FWRV=fw/ctrl_rv/build/RV32OSDA.BIN FW832=path/to/832OSDAD.BIN
mdir -i sim/l3/card/build/hdd.img@@1048576 ::
```

| Card | Files (all cards also hold both firmwares and `KICK.ROM`) |
|---|---|
| `boot` | `MINMGAR.CFG` (RISC-V, little-endian), `MINMGAA.CFG` (832, big-endian) |
| `boot832cfg` | only `MINMGAA.CFG`: the RISC-V first-boot conversion path |
| `fdd` | boot + `TEST.ADF`, `DRIVESND.BIN` |
| `hdd` | boot + `SYNTH.HDF`, `RDB.HDF` |
| `cd` | boot + `TEST.CUE`, `TEST.BIN`, `TEST.ISO`; `CDCFG=iso` (image `cd_iso.img`) names `TEST.ISO` in the configs instead of `TEST.CUE` |
| `cdhdd` | boot + both HDFs + `TEST.CUE`, `TEST.BIN` |

All cards are 32 MB, FAT16 at LBA 2048 (`tools/sim/mkcard.sh`), file times
from `SOURCE_DATE_EPOCH` (default 2026-01-01 00:00 UTC).

Content (`sim/l3/gen`, python3 stdlib run with `-I`, plus `xorriso`):

| File | Generator | Content |
|---|---|---|
| `KICK.ROM` | `mkkick.py` | 262,144 bytes; word i = `0x4B490000` + i, big-endian; ASCII `L3 SYNTHETIC KICKSTART` at 0x18 |
| `TEST.ADF` | `mkadf.py` | 901,120 bytes; sector s (LBA) tagged `L` `B` s>>8 s&0xff, then the pattern of `fw/ctrl_rv/test/gold/mfm.py` |
| `SYNTH.HDF` | `mkhdf.py` | 4 MB, no RDB (the firmware synthesises one); CHS 257.1.32 (`mkhdf.py --chs SYNTH.HDF`); block n tagged `H` 2 n>>8 n&0xff |
| `RDB.HDF` | `mkhdf.py` | 2 MB, own RDSK at block 0 with `rdb_Flags` 0x17 (not 0x12) and a PART at block 1; other blocks tagged `H` 1 n>>8 n&0xff |
| `TEST.ISO` | `mkiso.sh` | one file `DATA.BIN`, 256 KB, block n of 2048 bytes tagged `L` `B` n>>8 n&0xff |
| `TEST.BIN`, `TEST.CUE` | `mkcue.py` | 364 raw sectors: 64 MODE1/2352 data, then two AUDIO tracks of 2 s; track 2 has the 2 s PREGAP; audio frame f (from track 2) is left `f & 0xFFFF`, right `~f & 0xFFFF` |
| `MINMGAA.CFG`, `MINMGAR.CFG` | `mkcfg.py`, `cfgconv --to-rv` | 212 bytes: kickstart `KICK`, IDE on, one floppy at normal speed, hardfile 0 = `RDB` (plain file, own RDB: unit 0, so the firmware patches its `rdb_Flags`), hardfile 1 = `SYNTH` (synthesised RDB), IDE port 2 master = CD with `TEST` (CUE or ISO), the rest the 832 defaults |

Disc map of `TEST.CUE`: LBA 0..63 data, 64..213 silent pregap of track 2,
214..363 track 2, 364..513 track 3, lead-out 514.

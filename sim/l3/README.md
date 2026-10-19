# L3 co-simulation bench

Work in progress (Phase 4 of the OSD host CPU migration). This file grows
with the bench; so far it has the sections "Bench", "Run", "boot" and
"Cards".

## Bench

`tb_l3.v` puts the host CPU against the real Minimig SPI slaves and boots
the committed boot ROM and the real firmware from an SD card image:

| Part | What | From |
|---|---|---|
| host CPU | `EightThirtyTwo_Bridge` (`cpu_riscv = true`: `rv_hostcpu` + VexOsd, the boot ROM `fw/ctrl_boot_rv/OSDBoot_rv_ROM.vhd`, `hostcache.v`) | `rtl/host` |
| SDRAM | `sdram_host_model.v` (`+SLAT`, `+SJIT`, `+SEED`; `+SDRAM_DUMP=<file>` writes its 8 MB before the verdict) | `sim/host_bridge` |
| cfide | the board's generics: `spimux` false, `havespirtc`, `havei2c`, `havevpos` true; no I2C slave (every ADV7511 transfer NACKs) | `rtl/host/cfide.vhd` |
| card | `sd_spi_model #(.IMG_SECTORS(65536))` on `sd_cs[1]`, a 32 MB card from `sim/l3/card` | `sim/common` |
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
| `=== OSD EARLY <n> of <m> reply bytes` | in `OSD_CMD_VERSION` (0x88) and `OSD_CMD_KEYQ` (0x98) frames, every byte after the command: userio_osd_spi loads its output register from `in` (negedge of its `sck`, `bit_cnt` 0) while `osd1.spi0.new_byte \| rx_sync \| rx` is 1, i.e. before the previous byte is through the clk7 synchroniser and the reply counters have moved. n > 0 is a bench error unless `+OSD_EARLY_OK=1` |

Plusargs besides those: `+SCENARIO=<name>`, `+TIMEOUT=<clk_114 cycles>`,
`+FAST_HW=1` (run.sh puts `+SD_TOKEN_DLY=0 +SD_BUSY=1 +SD_NCR=1 +SLAT=2
+SJIT=0` first, the bench checks that the models took them),
`+OSD_MIN_GAP=<n>` (hostmon, default 40), `+SD_SAVE=<file>`, the card
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
(default; `832` comes with Task 6), `SIM=xsim` (default) or `verilator`,
`RUNTAG`, `FW`, `EXTRA_WS`, `SLAT`, `SJIT`, `SEED`, `XARGS` (more
plusargs), `TIMEOUT`, `NOKICK=1`, `XRAND=1`, `XSEED`.

A run directory `sim/l3/run_<RUNTAG>/` holds `results.txt`, the log
`tb_<scenario>_x<EXTRA_WS>_s<SLAT>_j<SJIT>.log`, `spi.txt`,
`spi_summary.txt`, `spi_t.txt`, `milestones.txt` (the check's output),
`sdram.bin` (`boot`), `card/` and `fwrv/`.

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
- bench `=== PASS`: no X, no stale ack, OSD GAP >= 40, OSD EARLY 0

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

End of `boot` (the same in its `XRAND` twin; `STATS@boot` counts up to the
end event):

```
=== BOOT first read of 0x2000 at cycle 43190675, irefill 95 dread 99698 dwrite 125958 so far
=== MAIN first HandleFpga frame at cycle 158044038
=== END boot: HandleFpga frame 20 after the first at cycle 158155012
=== STATS@boot irefill 18048 dread 1454655 dwrite 1881249 busy_cycles 133194412 (rv_hostcpu, to cycle 158155012)
=== HW accesses 1685611, stale acks 0, X 0, SDRAM reads 92580 writes 1008672, main done 79381, cycles 158155021
=== STATS irefill 18048 dread 1454655 dwrite 1881250 busy_cycles 133194419 (rv_hostcpu, whole run)
=== SPI frames 1874, HandleFpga frames 21, KEYQ frames 20
=== OSD GAP min 44 over 26 bytes
=== STACK low 00001950 (1712 bytes used)
=== OSD EARLY 0 of 26 reply bytes
ok   milestones: 50 of 50 found in order
ok   PASS kick: KICK.ROM (262144 bytes) at Amiga 0xf80000 and 0xfc0000 (host 0x100000, 0x140000)
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
for the 832 twin, `832OSDAD.BIN`. Until the 832 firmware is built (Task 6)
leave `FW832` out: a deterministic 84 KB stand-in takes its place.

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

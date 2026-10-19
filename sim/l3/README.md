# L3 co-simulation bench

Work in progress (Phase 4 of the OSD host CPU migration). This file grows
with the bench; so far it has the sections "Bench", "Run", "boot",
"Monitors" and "Cards".

## Bench

`tb_l3.v` puts the host CPU against the real Minimig SPI slaves and boots
the committed boot ROM and the real firmware from an SD card image:

| Part | What | From |
|---|---|---|
| host CPU | `EightThirtyTwo_Bridge` (`cpu_riscv = true`: `rv_hostcpu` + VexOsd, the boot ROM `fw/ctrl_boot_rv/OSDBoot_rv_ROM.vhd`, `hostcache.v`) | `rtl/host` |
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
(default; `832` comes with Task 6), `SIM=xsim` (default) or `verilator`,
`RUNTAG`, `FW`, `EXTRA_WS`, `SLAT`, `SJIT`, `SEED`, `XARGS` (more
plusargs), `TIMEOUT`, `NOKICK=1`, `XRAND=1`, `XSEED`.

A run directory `sim/l3/run_<RUNTAG>/` holds `results.txt`, the log
`tb_<scenario>_x<EXTRA_WS>_s<SLAT>_j<SJIT>.log`, `spi.txt`,
`spi_summary.txt`, `spi_t.txt`, `milestones.txt` (the check's output),
`kick.txt`, `order.txt`, `mmc.txt` and `sdram.bin` (`boot`), `card/` and
`fwrv/`.

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

End of `boot` (p4t5b; the same in its `XRAND` twin p4t5b_xr; `STATS@boot`
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
=== MARGIN 3 dmode_release min none clk_114 (bound 0, ok) over 0 direct transfers
=== MARGIN 3 dmode_L min none clk_114 (bound 0, ok) over 0 direct transfers
=== MARGIN 4 paula_cs_release min 10.8 clk_114 (bound 0, ok) over 41 frames
=== MARGIN 4 userio_cs_release min 10.8 clk_114 (bound 0, ok) over 72 frames
=== MARGIN 4 paula_word_spacing min 117.0 clk_114 (bound 40, ok) over 82 words
=== MARGIN 4 userio_byte_spacing min 57.0 clk_114 (bound 40, ok) over 129 bytes
=== MARGIN 5 spi_write_busy min 0 count (bound 0, ok) over 829924 DATA writes
=== MARGIN 12 rtc_cs_high min none ns (bound 0, ok) over 0 gaps
=== MARGIN 14 kick_order min 6829787.0 clk_114 (bound 1, ok) over 2 releases
ok   MARGIN lines: all 10 present, none LOW
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
(`=== XRAND pinned 9 regs`), and the twin is SAME. A later twin (p4t5c_xr,
seed 820757315) differed in the MISO of the very first OSD frame (`20 08 06
/ a8 00` instead of `/ 00 00`): `userio_osd_spi.v`'s `bit_cnt` and
`first_byte` are cleared only by a rising `_scs`, which a start at
"deselected" never gives. `XRAND=1` pins both to 0 as well (`=== XRAND
pinned 11 regs`; the same seed is then SAME, p4t5d). The findings are in
`findings/osd-riscv/phase4.md`.

## Monitors

`mon_l3.vh` (included by `tb_l3.v`) measures the host-side handshakes of
plan 7.1 that depend on timing, in every run, and prints one line per
measurement before the verdict:

```
=== MARGIN <item> <name> min <value> <unit> (bound <b>, ok|LOW) over <n> <events>
```

`<value>` is the smallest seen, `none` when the run had no such event (then
`ok`). Items 1 and 5 are counts: the value is the count and `LOW` means
above the bound. A `LOW` line is a bench error, and `run.sh` fails a
scenario unless all ten lines are there and none is `LOW`. Times are taken at
the slave pins: an `sck` edge reaches the slaves `+SCKDLY` ns after cfide's
pin, `sd_cs` undelayed.

| Item | Name | What | Bound | `boot` (p4t5b) |
|---|---|---|---|---|
| 1 | `stale_acks` | hostmon's stale-ack count (an ack no `clk_28` edge saw the request for) | 0 | 0 of 1,685,611 hw accesses |
| 3 | `dmode_release` | a direct-mode transfer (`sd_cs[6]` low): its last (4096th) `sck` rising edge at paula to `direct_scs` released (`sd_cs[6]` rising), `clk_114` | 0 | none (`boot` has no direct transfer); 108.8 in the probe run below |
| 3 | `dmode_L` | the RDSPI ack (a DATA read acked while `sd_cs[6]` is low) to the DisableDMode request (CS write 41), `clk_114`: `sim/spi_cdc/host832/tb_832_dmode.v`'s `L` | 0 | none; 6 in the probe run |
| 4 | `paula_cs_release`, `userio_cs_release` | per slave (`sd_cs[4]` paula, `sd_cs[5]` userio_osd): the last `sck` rising edge of a frame at the slave to its select rising, `clk_114` | 0 (derived below) | 10.8 over 41 frames; 10.8 over 72 frames |
| 4 | `paula_word_spacing`, `userio_byte_spacing` | the last edge of one received word (paula, 16 bits, `sd_cs[4]` or `[6]`) / byte (userio, 8) to the last edge of the next, `clk_114` | 40 (derived below) | 117.0 over 82 words; 57.0 over 129 bytes |
| 5 | `spi_write_busy` | SPI DATA writes acknowledged without starting a transfer of their own (no `SD_busy` rise from the request to the cycle after its ack): taken while the shifter was busy | 0 | 0 of 829,924 |
| 12 | `rtc_cs_high` | `rtc_model`: the CS-inactive time between two RTC transfers, ns | `+RTC_CSH_MIN`, default 0 (datasheet not found, below) | none (one RTC transfer in `boot`); 363,982,789 ns in the `rtc2` run below |
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
Measured: 10.8 `clk_114` on both slaves. cfide takes a CS write only while
`SD_busy` is 0, and `SD_busy` falls one SPI half-period (3 `clk_114` at
speed 1) after the last edge.

The synchroniser: a byte's last edge sets `new_byte` / `spi_rx_flag` at
t0. The first `clk7n_en` edge after it comes within 16 `clk_114` and takes
it into `rx_sync` / `rx_flag_sync`. `rx` / `rx_flag` follow at the
`clk7_en` edge 8 `clk_114` later (`amiga_clk.v`: `clk7_en` two `clk_28`
after `clk7n_en`). The consumers see them, and read `out` / `rx_data`, at
the `clk7_en` edge after that, 16 later. That makes at most 16 + 8 + 16 =
40 `clk_114` from t0. The next byte's or word's last edge must come later:
it overwrites `out` / `rx_data`, and its flag would merge with the
pending one. The SPI clock alone keeps this safe, because at speed 1 a
bit takes 6 `clk_114`, so 8 bits take 48 and 16 take 96, whatever the CPU
does. The firmware's minima are 57 and 117.

### Item 12: the RTC

`fw/ctrl_rv/rtc.c` does not name its part. The board's RTC is the NXP
PCF2123 (plan 7.1 item 12, `doc/hardware.md`, `rtl/openaars/pcf2123`).
`rtc.c` sends `0x92` = read, subaddress 001, register 2 (Seconds), then
reads Seconds, Minutes, Hours, Days, Weekdays, Months, Years. Its comment
says "register 0000"; the code reads from register 2. `rtc_model.v`
answers that protocol with the fixed BCD time 2026-01-01 00:00:00 (weekday
4) and records writes, so the RTC frame is the same in every run:
`80 92 ff ff ff ff ff ff ff / ff 00 00 00 01 04 01 26`. This is the
`milestones_boot.txt` line; `boot` at SLAT 8 (p4t5b) and the `rtc2` run
at SLAT 4 (p4t5rtcb, both frames) give the same bytes.

**Datasheet minimum: not found.** `doc/rtc` holds `OKI MSM6242B.pdf` (the
parallel clock-port RTC the PCF2123 is presented to the Amiga as), a clock
port manual and HTML pages; no PCF2123 datasheet. The bound is therefore
0, and the record is the firmware's own spacing. `HandleRTC()` reads the
RTC on the first main-loop pass and then every 8,192 passes
(`(c++&8191)==0`), so `boot` (20 passes) has one transfer and no gap.
`XARGS=+BOOT_END=rtc2` ends `boot` at the second RTC frame instead and
measures it: 363,982,789 ns = 41.3 M `clk_114` at SLAT 4 (p4t5rtcb), 389,857,255
ns = 44.2 M at SLAT 8 (p4t5r12b), TICKDIV 1. Both are 8,192 passes of the
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
at SPI speed 0. Its runs end at `TIMEOUT=46000000`, just after the probe,
so their verdict is FAIL (end event not reached); the MARGIN lines are what
counts.

| Item | Red case | RUNTAG | Result | Green |
|---|---|---|---|---|
| 1 | run copy: `832_bridge.vhd`'s `-- 4PHASE` line becomes `state <= waiting;` and `rv_hostcpu.v` gets the fast master (both exactly as `sim/host_bridge/run.sh` `mutant`'s gate leg), `boot_short`, `TIMEOUT=10000000` | p4t5r1a | `stale_acks min 1184 count (bound 0, LOW)` | p4t5b: 0 |
| 3, 4 | probe v2, `XARGS=+SCKDLY=1000` (the slaves see `sck` 1 us late) | p4t5r34b | `dmode_release min -4.4 LOW`, `paula_cs_release min -87.4 LOW`, `userio_cs_release min -102.4 LOW` | probe v2 without the plusarg, p4t5p35b: 108.8 / 25.8 / 10.8, `dmode_L` 6.0 |
| 4 spacing | probe v3 (SPI speed 0: 2 `clk_114` per bit) | p4t5r4s | `userio_byte_spacing min 24.0 (bound 40, LOW)`; `paula_word_spacing` 48.0 stays ok (16 bits cannot come closer than 32 plus the access) | p4t5b: 57.0 / 117.0 |
| 5 | run copy: cfide's support state machine acknowledges an SPI write while `SD_busy` (`IF SD_busy = '0' or wr = '1' THEN`), probe v1 (v2 without the paula frame) | p4t5r5a | `spi_write_busy min 92934 count (bound 0, LOW)`, from the boot ROM on | p4t5p35b: 0 (the probe's second write is held) |
| 12 | `XARGS="+BOOT_END=rtc2 +RTC_CSH_MIN=1000000000"`, `TIMEOUT=300000000` | p4t5r12b | `rtc_cs_high min 389857255.3 ns (bound 1000000000, LOW) over 1 gaps` | p4t5rtcb: 363982789.0, ok |
| 14 | `l3check.py order` on a copy of `run_p4t5/tb_boot_x0_s8_j0.log` with the last kickstart write moved to cycle 156,968,900 (after the release at 156,968,829) | offline | `FAIL order: the last kickstart-region SDRAM write (cycle 156968900, ...) is not before the last cpurst fall (cycle 156968829)` | `PASS order` on the log |
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

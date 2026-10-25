# L3 co-simulation bench

The L3 bench boots the OSD host CPU (`rv_hostcpu`, the VexRiscv RV32IMC)
with its real boot ROM and firmware against the real Minimig SPI slaves
(Phase 4 of the OSD host CPU migration), runs a scenario and checks it.
The EightThirtyTwo (832), the host CPU before the RV, was retired in Phase
9 (`doc/osd-riscv-plan.md`); the bench's 832 leg and its RV-vs-832
differential went with it (the last commit with them: 09f81bbe).
Sections: "Bench", "Run", "boot", "Trace files", "keys", "fdd_rd",
"fdd_wr", "hdd", "cd", "cdda", "akiko", "sdc", "Monitors", "Stress grid"
and "Cards". Every command is meant to be copied from the repository root of
a fresh Ubuntu 24.04 checkout, into bash or zsh; the sections after "Run"
assume the "Run" setup.

## Bench

`tb_l3.v` puts the host CPU against the real Minimig SPI slaves and boots
the committed boot ROM and the real firmware from an SD card image:

| Part | What | From |
|---|---|---|
| host CPU | `host_bridge` (`rv_hostcpu` + VexOsd, the boot ROM `fw/ctrl_boot/OSDBoot_rv_ROM.vhd`, `hostcache.v`) | `rtl/host` |
| SDRAM | `sdram_host_model.v` (`+SLAT`, `+SJIT`, `+SEED`; `+SDRAM_DUMP=<file>` writes its 8 MB before the verdict) | `sim/host_bridge` |
| cfide | the board's generics: `spimux` false, `havespirtc`, `havei2c`, `havevpos` true; no I2C slave (every ADV7511 transfer NACKs) | `rtl/host/cfide.vhd` |
| card | `sd_spi_model #(.IMG_SECTORS(65536))` on `sd_cs[1]`, a 32 MB card from `sim/l3/card`; with `SD_ENGINE` (the `sdc_*` scenarios) on `sdcard_spi`'s pins, section "sdc" | `sim/common` |
| RTC | `rtc_model.v` on `sd_cs[7]`: the SPI RTC `fw/ctrl/rtc.c` reads, a fixed time ("Monitors", item 12); its MISO shares cfide's `sd_dimm` with the card | `sim/l3` |
| OSD | `userio_osd` (instance `osd1`) on `sd_cs[5]`, `CORE_CAPS` 0xAD | `rtl/minimig` |
| floppy / HDD | `paula_floppy` on `sd_cs[4]`, direct mode on `~sd_cs[6]` from the card's MISO; `gayle #(.IDE_PORTS(2))` behind it on the `hdd_*` bus | `rtl/minimig` |
| reset | `minimig_syscontrol` (`mrst` = `usrrst`, `cnt` = sof); chipset reset = `sys_reset \| cpurst` | `rtl/minimig` |
| audio ring | `bfm_audio.v`: the ring position, cfide `audio_buf` = bit 15; with `+CDDA_DUMP` a copy of every half the player starts (section "cdda") | `sim/l3` |
| floppy's Amiga side | `bfm_floppy.v` (instance `fdd`): the CIA lines, Paula's disk registers and Agnus's disk DMA slots for paula_floppy, read and write (scenarios `fdd_rd` and `fdd_wr`, sections "fdd_rd" and "fdd_wr"; idle otherwise) | `sim/l3` |
| Gayle's Amiga side | `bfm_ide.v` (instance `ide`): a 68k IDE driver on gayle's task file, data, INTENA / INTREQ registers, `irq` and `nrdy` (scenarios `hdd`, `cd`, `cdda` and `cdda_load`, sections "hdd", "cd" and "cdda"; idle otherwise: every 68k input 0) | `sim/l3` |
| Akiko requester | `bfm_akiko.v` (instance `aki`): cfide's `amiga_req/addr/d/wr` in, `amiga_q/ack` out (scenario `akiko`, section "akiko"; idle otherwise) | `sim/l3` |

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

The Amiga side is idle outside `fdd_rd`, `fdd_wr`, `hdd`, `cd`, `cdda`, `cdda_load` and the key
scripts: the floppy is deselected (`_sel` 1111, `_motor` 1), no register or Gayle access,
`osd_ctrl` 0, `in_diag` 0. The CPU's
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
| `=== STATS@win_start`, `=== STATS@win_end` | the counters at the start and end of the scenario's measurement window (Task 20): `boot` the main-loop milestone to the end event, `fdd_rd` the first track DMA's start to the end event, `hdd` the first IDE command's start to the end event, `cdda` the player's flip 2 to flip 6, `keys` the first key event to the end event; sampled at the `clk_114` edge after the event |
| `=== RETIRED <n> (STATS@<event>, to cycle <c>)`, `=== RETIRED <n> (whole run)` | after every `STATS@` line and the whole-run `STATS`: the instructions the core retired (VexOsd's `writeBack_arbitration_isFiring`, through the wire `l3_retire` that `run.sh` adds to the run copy of `rv_hostcpu.v`: Verilator 5.020 does not resolve a bench reference into its `g_core` generate branch) |
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
sudo apt install build-essential make git curl python3 mtools dosfstools fdisk xorriso ghdl verilator ccache iverilog
bash tools/riscv/fetch-xpack.sh
bash tools/riscv/check-toolchain.sh
make -C fw/ctrl
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

`run.sh <scenario>` builds the firmware from `fw/ctrl` into the run
directory under a date shim (so two runs of one tree boot the same image;
`FW=<image>` takes another one; on the card it is `RV32OSDB.BIN`, the name
of `fw/ctrl/fwname.mk`), builds the card into it
(`sim/l3/card`), builds the bench, runs it and then the scenario's checks,
and prints `=== <scenario> PASS` or `FAILED` (exit 0 / 1). A step that
fails (firmware, card, conversion, build) ends the run at once with
`=== <scenario> FAILED`, and an offline check (`spitrace.py`, `l3check.py`,
run.sh's `l3_check`) counts only when it exits 0 and prints its pass line. `xpair` runs the
scenario and its `XRAND=1` twin in parallel (`run_<RUNTAG>`,
`run_<RUNTAG>_xr`) and compares them. `compare` diffs every `tb_*.log` and
`spi.txt` of two run directories (L2's rules). Environment: `SIM=xsim`
(default) or `verilator`, `RUNTAG`, `FW`, `L3_DATE`, `EXTRA_WS`,
`SLAT`, `SJIT`, `SEED`, `XARGS` (more plusargs), `TIMEOUT`, `NOKICK=1`,
`XRAND=1`, `XSEED`, `KEYS` (section "keys"), `RDY_MUT=1` (section "keys", teeth), `PAULA_TXPOP=1` (section "fdd_wr", the write-FIFO evidence fix in the run copy), `PATCH=<script>` (teeth: edits the run copies of the RTL) and `BUILD_FROM=<RUNTAG>` (another run's simulator when the build inputs are the same; section "Stress grid"). `TIMEOUT` is at most 2,147,483,647. Every log starts with `=== CPU rv`
(the bench's only CPU; `CPU=rv` in the environment is accepted, any other
`CPU` refused).

A run directory `sim/l3/run_<RUNTAG>/` holds `results.txt`, the log
`tb_<scenario>_x<EXTRA_WS>_s<SLAT>_j<SJIT>.log`, `spi.txt`,
`spi_summary.txt`, `spi_t.txt`, `hw.txt` and `uart.txt` (section
"Trace files"), `sdram.bin`, `memhash.txt`, `milestones.txt` (the check's
output), `kick.txt`, `order.txt` and `mmc.txt` (`boot`), `card/` and
`fwrv/`; `fdd_rd` adds the dumps and `fdd_rd.txt`, `fdd_wr` the
write streams `fdd_wr_<cyl>_<head>.hex`, `card_saved.img`,
`fdd_wr_saved.adf` and `fdd_wr.txt`.

## boot

`boot` boots the `boot` card (`RV32OSDB.BIN`, `MINMGAR.CFG`, the legacy
`MINMGAA.CFG`, `KICK.ROM`) with the TIMER at 1 (`TICKDIV` 1): the boot ROM
loads `RV32OSDB.BIN` (`RV32OSDA.BIN` until SD card engine Task 13b), the firmware runs `MMC_Init`, `LoadConfiguration`
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
  `Fatal error`, no `Overriding screenmode` (no key is held at ColdBoot's
  level read; final review I2)
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
  `fw/ctrl/test/gold/mmc_init_cmds.txt`, mmc_test's golden for the same
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

### Measured (2026-10-19, SLAT=8 SJIT=0, SCKDLY 1.5 / C28DLY 0.3, TICKDIV 1)

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
ok   no UART line contains 'Overriding screenmode'
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

## Trace files

Every L3 scenario writes, through `sim/common/hostmon.vh` (`+HW_LOG`,
`+UART_LOG`), two traces besides `spi.txt`:

| File | Lines |
|---|---|
| `spi.txt` | the SPI frames (section "Bench") |
| `hw.txt` | `<frames> <ev> <addr> <value16>` per hw-register write except SPI DATA / CS, the UART and the L2 bench registers 0x..00 / 04; `addr` = the 24 bits cfide decodes (0xFFFFFFB0 is `ffffb0`), `value16` = cfide's d (a byte write: 00 and its byte); at the end `MEM <region> <sha256>` per SDRAM region the CPU wrote (`kickstart` host 0x100000..0x17ffff, `audio_ring` 0x70000..0x7ffff), hashed from `sdram.bin` by `l3check.py memhash` |
| `uart.txt` | `<frames> <ev> <text>` per UART line |

`<frames>` is the number of `spi.txt` lines before the event and `<ev>`
one counter over both files: the order without the cycles. `l3check.py`
reads `hw.txt` (`memhash`, `akiko`); `run.sh compare` compares the logs
and `spi.txt`.

`sim/host_bridge/spitrace.py` also has `norm` and `diff` (a normalised
comparison of two runs' traces, the RV-vs-832 differential of Phase 4;
the syntax is in its help). No L3 target uses them any more;
`sim/l3/test/spitrace_test.sh` (a few seconds) still tests them and
`spitrace.py osd` on generated fixtures.

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
OSD writes that depends on the firmware's speed).

The script (`bfm_keys.v` has the syntax): `KEY <code> <hold>` (the code,
then 0 after the hold: two queue events), `BURST <code> ...` (one change
every 32 `clk_114`), `WAIT_OSD_IDLE <cycles>` (no `OSD_CMD_OSD_WR` frame
open or closing for that long, counted from the step's start),
`WAIT_KEYQ <n>`. `menu_tour.txt` opens the OSD (`KEY_MENU`), walks down
the main page over all six selectable lines and up again, enters the
Floppy page (down twice, `exit`) and the Harddisks page (`KEY_ESC` back),
sends one `BURST 4c 00 4d 00 4c 00` (three presses, up / down / up, each
with its release: six events) and closes the OSD with `KEY_MENU`.

Two rules keep the run independent of the firmware's speed, each enforced
by a bench error:

- Every `KEY` / `BURST` comes right after a KEYQ frame that drained
  nothing (`WAIT_OSD_IDLE`, then `WAIT_KEYQ 1`; `bfm_keys` checks the last
  frame's status byte). The next KEYQ frame then takes all of the step's
  events: a main-loop pass is at least 5,320 `clk_114`, the `BURST` takes
  192. While the firmware still hands
  out drained events (one per pass), `OSD_CMD_READ` could see a new code
  with no event to deliver, and `OsdGetCtrl` turns that into a key repeat
  when its TIMER says so.
- No `OSD_CMD_READ` frame while a key is held (`tb_l3.v`): the holds are 64
  `clk_114`, far shorter than the time to the next level read, so the key
  repeat never sees a held key.

Found on the way (`findings/osd-riscv/phase4.md` "Shared defects"): `OSD_CMD_READ`'s answer is the byte userio_osd_spi loads at the
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
- the OSD pages (decoded as `spitrace.py osd`) equal
  `osdtext_expect/keys.txt`

It prints `REPLY <cmd> byte <k>: <r> of <n> right` per reply byte, and the
bench `=== OSD REPLY <cmd> byte <k>: gap min <g> over <n> writes, early
<e> of <m> loads` (hostmon's OSD GAP and the OSD EARLY monitor per byte):
the "before" table of `findings/osd-riscv/phase4.md` (Task 8).

`osdtext_expect/keys.txt` is written by `osdtext_expect/osdpages.py keys`
from the sources, before any run: a model of `fw/ctrl/osd.c`'s
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

Run, setup as in "Run" (the RV firmware polls the reply-ready handshake
since Phase 4 Task 11, so no `+OSD_EARLY_OK=1`: `OSD EARLY` must be 0),
from the repository root:

```sh
SIM=verilator RUNTAG=k bash sim/l3/run.sh xpair keys
```

(`xpair` runs the scenario and its XRAND twin side by side, about 22
minutes with other runs on the machine.)

### The handshake's teeth (Phase 4 Task 12)

`RDY_MUT=1` makes the run copy of cfide (`<run>/src/cfide.vhd`, never the
tree's) answer `OSD_RDY` = 1 whatever the counts say, like `sim/spi_cdc/run.sh`'s
`RDY_MUT` (an exact-count check on the `-- OSD RDY` line). The firmware
without the poll is another image: a copy of `fw/ctrl` from git `HEAD`
outside the tree, built under `run.sh`'s date shim (`FWD`, the first
lines; `FWD/fwrv` is then the image a default run builds):

```sh
FWD=$PWD/sim/l3/run_fw
mkdir -p "$FWD/dateshim" "$FWD/fwrv"
printf '%s\n' '#!/bin/sh' 'TZ=UTC exec /bin/date -d "${L3_DATE:-2026-01-01} 00:00:00" "$@"' > "$FWD/dateshim/date"
chmod +x "$FWD/dateshim/date"
PATH="$FWD/dateshim:$PATH" make -s -C fw/ctrl B="$FWD/fwrv"
D=$FWD/nopoll
mkdir -p "$D"
git archive HEAD fw/ctrl tools/riscv | tar -x -C "$D"
sed -i 's/if (!(HOST_REQ & HOST_REQ_OSD_RDY)) {/if (0) {/' "$D/fw/ctrl/hardware.c"
grep -c 'if (0) {' "$D/fw/ctrl/hardware.c"
PATH="$FWD/dateshim:$PATH" make -s -C "$D/fw/ctrl" B="$D/build"
SIM=verilator RUNTAG=m1c RDY_MUT=1 XARGS=+FAST_HW=1 FW="$FWD/fwrv/RV32OSDA.BIN" bash sim/l3/run.sh keys
SIM=verilator RUNTAG=m2 FW="$D/build/RV32OSDA.BIN" bash sim/l3/run.sh keys
```

(`grep -c` must print 1.) Both must exit 1 (`=== keys FAILED`): `m1c` with
`OSD EARLY 1 of 450` and `version reply byte 2: 1a, want 0a`, `m2` with
`OSD EARLY 3 of 6`, the repeated VERSION bytes and no KEYQ frame. The
default-timing run of the cfide mutant fails on `OSD GAP min 27` alone
(`OSD EARLY 0`): the `FAST_HW` bus is what makes its one remaining poll
read too quick for the synchroniser. Figures: `findings/osd-riscv/phase4.md`,
"Task 12".

### Measured (2026-10-19, SLAT=8 SJIT=0, SCKDLY 1.5 / C28DLY 0.3, TICKDIV 1 then 643)

| | `p4t8`, `+OSD_EARLY_OK=1` |
|---|---|
| main-loop milestone (script start) | 158,045,126 |
| end of the script | 165,059,293 (+7.01 M) |
| KEYQ frames (with events) | 354 (22) |
| main-loop pass in the open menu, min / median (`p4t8d`) | 5,320 / 7,108 |
| `OSD EARLY` | 0 of 408 |
| `OSD GAP` min: VERSION / KEYQ status / per-key bytes | 44 / 295 / 56 |
| `l3check.py keys` | PASS: 48 events, BURST one frame, count 6, 24 pages |
| wall time (Verilator, 5 runs on the machine) | 1,281 s |

After the handshake (Task 12, `p4t12`, no `+OSD_EARLY_OK`): the script
ends at 164,861,841 (milestone 157,844,924), KEYQ frames 366, `OSD EARLY` 0
of 420, `OSD GAP` min 43, `l3check.py keys` PASS, wall 1,653 s (six runs on
the machine); the same `keys` with `+FAST_HW=1`, and in the skew pairs
0.3 / 4.0 and 9.5 / 0.3, also `OSD EARLY` 0. The per-byte before/after
table is in `findings/osd-riscv/phase4.md`, "Task 12".

`L3_KEYS_TO` = 247,400,000: 1.5 x the end of the script. The per-byte
figures are the "before" table of `findings/osd-riscv/phase4.md`.

XRAND: the twin `p4t8_xr` is SAME.

Teeth (not committed): `p4t8red`, a script that applies a key right after
the KEYQ frame that drained the previous one, fails with `BENCH ERROR:
bfm_keys ... key applied after a KEYQ frame that drained events`.
`l3check.py keys` on edited copies of the `p4t8d` log and `spi_t.txt`
fails for each of: a wrong per-key byte in the BURST frame, the BURST split
into two frames of three, a changed character column of an OSD row, an
`OSD_CMD_OSD_WR` frame before the first key, a frame one per-key byte
short, a stale status byte (00, the events read one frame later) and a
missing `=== KEYS ev` line; the unedited copy passes.

## fdd_rd

`fdd_rd` reads floppy tracks the way the Amiga does, against the real
`paula_floppy` and the firmware's `fdd.c`. It boots the `fdd` card (the
`boot` card plus `TEST.ADF` and `DRIVESND.BIN`). At the main-loop milestone
the key script `keys/insert_df0.txt` starts (`bfm_keys.v`, section "keys").
It opens the OSD and turns "Floppy disk sounds" on: the card's config has
`drivesounds` 0, and `DRIVESND.BIN` is loaded, so the line can be selected.
Then it opens df0's file selector, selects `TEST    ADF` (the card's only
ADF) and closes the OSD. At the end of the script `bfm_floppy.v` reads 10
tracks: cylinders 0, 1, 2, 39, 40, 41, 77, 78, 79 on head 0, then cylinder
79 on head 1. Each read is one full-track DMA of 6,334 words (`fdd.c`
`TRACK_SIZE` 12,668 bytes) with sync 0x4489. The end event is the
`blckint` of the last DMA (`=== STATS@fdd_rd`).

TIMER: `+TICKDIV=643 +TICKDIV_AT=scenario`, as `keys`. `fdd.c` uses no
TIMER: `ReadTrack` sends a sector whenever paula_floppy's status asks for
one. The drive sounds do use it. `drivesounds_fill` renders 256 samples per
TIMER count into the audio ring on every main-loop pass while the motor
loop plays (`drivesounds_render(TIMER)`). At `TICKDIV` 1 that would be 643
times the board's rendering load: one sample per 4 `clk_114`, so every pass
renders the cap of 32,512 samples and the main loop is mostly rendering.
At 643 the load is the board's (one sample per 2,572 `clk_114`). The menu
part needs 643 for the reasons given in "keys". (The brief said `TICKDIV`
1; it also said the drive sounds should run "as on the board", and only
643 gives that.)

### bfm_floppy: what the model reproduces

CIA side (`ciab` PRB as minimig.v wires it): `_sel[3:0]`, `_motor`,
`side` (the CIA's active-low `_SIDE`: paula_floppy's track byte is
`{cylinder, ~side}`), `_step` and `direc`. One CIA write is 10 clk7 cycles
(an E-clock period). Tasks:

- `fdd_select(drive)`: `_ready` must then be 0.
- `fdd_motor(on)`: deselect, set `_motor`, select again. paula_floppy
  latches the motor on the falling edge of `_sel`. Motor on: then 500 ms
  before anything else (the drive-ready waits below).
- `fdd_seek(cyl)`: trackdisk.device's default delays. First a
  recalibration (step out until `_track0` is 0, 4 ms apart), then step
  pulses 3 ms apart, then 15 ms settle after the last one. `_track0` must
  be 0 exactly at cylinder 0.
- `fdd_side(head)`: when the head changes, then 15 ms before the next
  DMA (the drive-ready waits below).
- `fdd_dma_read(words, sync)`, in this order:
  - `wordsync` (ADKCON WORDSYNC) and `enable` (DMACON DMAEN & DSKEN) on.
    These are Paula registers outside paula_floppy, set as trackdisk
    leaves them for a read.
  - `DSKSYNC` = sync.
  - `DSKLEN` = 0x4000 (DMA off).
  - `DSKLEN` = 0x8000 | words, twice. paula_floppy starts on the second
    write in a row with bit 15 set.

  A 68k register write is one clk7 cycle with `cck` low (the CPU's half of
  the colour clock, `minimig_m68k_bridge.v`). The idle register address is
  0xFF (Agnus's "no register"; the bench tied it to 0x00 before, and
  paula_floppy decodes neither).

Agnus (`agnus_diskdma.v`, `agnus.v`): a beam counter over the 227 colour
clocks of a PAL line (454 clk7 cycles). At normal floppy speed (the card's
config: `floppy.speed` 0; no turbo) the disk DMA engine has three slots per
line: `hpos[8:1]` = 0x0C, 0x0E, 0x10 with `hpos[0]` = 1 (Agnus's counter
runs 4 colour clocks ahead), one clk7 cycle each. In a slot where
paula_floppy's `dmal` is 1 (`dmaon & ~fifo_empty` for a read), the disk
channel gets the bus (it has the highest priority). `reg_address_in` is
then `DSKDATR` for that clk7 cycle, and the word on `data_out` is what
Agnus writes to chip RAM: the model collects it. paula_floppy pops its
FIFO at the end of the cycle (`fifo_rd = busrd & dmaon`).

A read continues until `blckint`: `DISKDMA_INT`, after `lenzero` (all
`words` written into the FIFO) and the FIFO drained. The collected words go
to `<run>/fdd_rd_<cylinder>_<head>.hex`, 16 words per line (`xxd -r -p`
reads it back). Not modelled:

- the DMA pointer and chip RAM
- the other DMA channels (the disk wins every slot it asks for)
- the refresh slots of `floppy_speed` 1

(Write DMA is section "fdd_wr". `dmas` = 1 in a read slot is a bench
error.)

Drive-ready waits (Task 14). Before them the model wrote `DSKLEN` about
100 clk7 cycles after the motor went on and after a head change, less
than one main-loop pass. On the Amiga trackdisk.device takes milliseconds
there, so the firmware's first status poll after the change sees the new
motor / track state without a DMA in it. The model now waits as
trackdisk does:

- after motor on, 500 ms (`MOTOR_CLK7` = 3,546,895 clk7 cycles).
  trackdisk.device waits after turning the motor on until the drive is up
  to speed, about half a second (ROM Kernel Reference Manual, `TD_MOTOR`;
  cited from memory, not from a source in this repository). paula_floppy holds `_ready` at 0 from the
  moment the drive is selected, so a model that polled `_ready` would not
  wait at all; the time itself is modelled.
- after a head change, 15 ms (`SETTLE_CLK7`), trackdisk's settle delay
  (its default, cited from memory like the step and calibration delays
  above): the wait the model already makes after the last step. The head
  switch counts as head movement.

Both are far longer than a main-loop pass of the firmware. They cost
about 59 M `clk_114` per run (one motor start, a few head changes).

With WORDSYNC on, Paula starts filling the FIFO with the word *after* the
sync word it matched (`trackrdok`). So a dump starts with the sector's
second 0x4489, at byte 6 of the firmware's stream.

### Checks

`l3check.py fdd_rd`:

- the 10 `=== FDD dma` lines are the scenario's tracks, in order, 6,334
  words each
- each dump, given the matched sync word in front, decodes with
  `fw/ctrl/test/gold/mfm.py`'s `decode_sector`. All 11 sectors decode,
  with header and data checksums, track `cyl * 2 + head`, sector numbers,
  "sectors to the gap", and data equal to `TEST.ADF`
- each dump is byte-equal to `mfm.py`'s `read_track` stream of that ADF
  track, read cyclically from the printed offset (6 = the WORDSYNC start
  at sector 0). A dump that does not start with the sync word would be
  decode-only, and the check says so
- tracks 0/0 and 79/1 are also byte-equal, read the same way, to exec-3
  Task 13's committed golden streams `fw/ctrl/test/gold/mfm_c00_s0.hex`
  and `mfm_c79_s1.hex`
- the OSD shows row 3 "Floppy disk sounds : on" and then row 0 "df0:
  TEST"
- no `OSD_CMD_OSD_WR` frame before the first key (an error page) and none
  after the first DMA started (the OSD is closed; `fdd.c`'s `FatalError`
  would draw one)
- no UART "Illegal track", "Fatal" or "Wrong header"

Also: boot's milestones, no `EXC` / `TRAP`, kick, order, every MARGIN line
with item 6 required (`MARGIN_REQ_fdd_rd`), and bench `=== PASS`.

Monitor item 6, `fdd_fifo_empty_dma` (`mon_l3.vh`), counts Agnus disk slots
with `dmaon` = 1 and an empty FIFO. Each slot is sampled in its clk7_en
`clk_28` cycle. The count runs per track, from the first slot at which the
FIFO has reached the firmware's working level to the track's last word
(`lenzero`). The working level is 1,024 words, where paula masks the read
request (`trackrd & ~fifo_cnt[10]`), so `ReadTrack` stops sending. Bound
0. The brief's literal count (any such slot from the starting `DSKLEN`
write on) is printed as information, and it cannot be 0. A DMA waits for
the firmware's first word: the transfer starts at the firmware's next
status frame, and the first sector follows a `FileRead`. Then come the
first lines, where a line's three slots, 4 clk7 cycles apart, come faster
than the SPI delivers words (about one per 120 `clk_114`). After the
working level, an empty FIFO means the host fell behind: a main-loop pass
longer than about 1,024 words x 2,421 `clk_114` (2.5 M; a line is 454
clk7 cycles = 7,264 `clk_114`, three words). Per track, `=== MARGIN
(info) 6 fdd track <c>/<h>` gives the minimum fill at the slots of the
window, the ramp, and the literal count. A track whose FIFO never reaches
1,024 words is a bench error.

### Run

Setup as in "Run". From the repository root:

```sh
SIM=verilator RUNTAG=f bash sim/l3/run.sh xpair fdd_rd
```

The two simulations take about 40 to 55 minutes side by side. The data
check alone, on a run directory:

```sh
python3 -I sim/l3/l3check.py fdd_rd sim/l3/run_f
```

### Measured (2026-10-19, SLAT=8 SJIT=0, SCKDLY 1.5 / C28DLY 0.3, TICKDIV 1 then 643)

| | `p4t13` |
|---|---|
| main-loop milestone (script start) | 193,536,684 |
| bfm_floppy starts (end of the script) | 201,236,597 |
| end event (the 10th `blckint`) | 393,222,555 |
| one track DMA, `DSKLEN` to `blckint` | 15.41 to 15.43 M |
| item 6: count / slots at the working level | 0 / 52,058 |
| item 6: FIFO minimum at the working level | 992 words |
| ramp (first word to 1,024 words): slots, of them empty | 129, 0 (156 on 77/0) |
| literal count (all 10 tracks) | 300 |
| `OSD EARLY` / `OSD GAP` min | 0 of 26,504 / 43 |
| `l3check.py fdd_rd` | PASS: 110 sectors, 10 streams = `read_track` from byte 6, both golden tracks |
| wall time (Verilator, four runs on the machine) | 2,490 s |

Each DMA takes about 15.4 M `clk_114`. That is 6,334 words at three slots
per line: 2,111 lines x 454 clk7 cycles x 16 = 15.3 M `clk_114`, plus the
wait for the firmware's first word. The firmware keeps the FIFO between
about 990 and 1,600 words. It refills when paula's request comes back
below 1,024, so the lowest fill at a slot is 992 words. That is about 330
lines of DMA, roughly 2.4 M `clk_114` of main-loop stall before an empty
slot. The boot is longer than `boot` (193.5 M against 158.0 M):
`drivesounds_init` loads `DRIVESND.BIN` (212,098 bytes) from the fdd card.
`L3_FDD_TO` = 680,000,000: 1.5 x the estimate 452 M (Task 13's end plus
the drive-ready waits of Task 14, below).

XRAND: the twin `p4t13_xr` is SAME (`tb_fdd_rd` log and `spi.txt`,
108,785 frames).

Task 14 added the drive-ready waits: `bfm_floppy` waits 500 ms after
motor on and 15 ms after a head change (section "bfm_floppy"), so the
first status poll after each sees the new motor / track without a DMA
already running. Before, the model wrote `DSKLEN` about 100 clk7 cycles
after the change, less than one main-loop pass, and whether the poll saw
the motor bits or the DMA in word 2 depended on the firmware's speed; the
difference is real firmware behaviour, not only trace bytes:
`HandleFpga` passes byte 5 to `HandleFDD` as the motor bits even when it
is `dsklen` (`findings/osd-riscv/phase4.md`, "Shared defects"). The re-run
`p4t14r` (3,568 s, end 453,368,475) passes `fdd_rd` with the same checks
(item 6: 0 of 52,056). With the RV image of Task 14's write fix
(17bf2563), `p4t14fr` also passes `fdd_rd` (5,328 s).

## fdd_wr

`fdd_wr` writes floppy tracks the way the Amiga does, against the real
`paula_floppy` and the firmware's `fdd.c` (`WriteTrack`: `FindSync`,
`GetHeader`, `GetData`, `FileWrite`), and checks the ADF the firmware
left on the card. It boots the `fdd` card and runs the key script of
`fdd_rd` (drive sounds on, `TEST.ADF` into df0, OSD closed). Then
`bfm_floppy.v` writes 10 tracks of drive 0: cylinders 0, 1, 2, 39, 41,
77, 78, 79 on head 0, cylinder 79 on head 1, and last cylinder 40 on head
0 (the cylinders of `fdd_rd`). Each write is one full-track DMA of the
words in `<run>/fdd_wr_<cyl>_<head>.hex`. At the end the card is saved
(`+SD_SAVE=<run>/card_saved.img`).

TIMER: `+TICKDIV=643 +TICKDIV_AT=scenario`, as `fdd_rd` (the drive sounds
render per TIMER count; `fdd.c` uses none).

### The write streams: `gen/mkwrtrack.py`

`run.sh` makes one stream per track from the card's `TEST.ADF`:

```sh
python3 -I sim/l3/gen/mkwrtrack.py <adf> <cylinder> <head> <out.hex> [--bad-header <sector>]
```

The stream is what the Amiga's write DMA sends when AmigaDOS writes a
whole track, built with `fw/ctrl/test/gold/mfm.py`'s encoder and the
real MFM clock bits:

- a gap of MFM zero data (0xAAAA words), then sectors 0 to 10 back to
  back, as trackdisk writes a track (each sector's "sectors until the
  gap", 11 - sector, counts down to the gap)
- each sector: two preamble words, the sync 0x4489 0x4489, header,
  label, header and data checksums, the data (odd bits, then even bits)
- every sector gets new data: `mfm.py`'s `new_sector(lba)`, tagged `W` `R`
  and the LBA, a pattern unlike `TEST.ADF`'s
- 6,334 words in all, one Minimig track (`fdd.c`'s `TRACK_SIZE`, 12,668
  bytes, the length `fdd_rd` reads), so the gap is 350 words.
  trackdisk's own gap length is not in this repository; `WriteTrack` does
  not depend on it (`FindSync` skips everything up to a sync word)

`--bad-header <s>` flips one data bit of sector s's header checksum (the
clock bits recomputed). Its header info, data checksum and data stay
right. `fdd_wr` uses it on the last track, sector 3. The file has one word
per line (`xxd -r -p` reads it back). A self-check decodes the stream
before it is written.

### bfm_floppy: the write DMA

`fdd_dma_write(file)` reads the file's words, then:

- `wordsync` off (trackdisk clears WORDSYNC for a write) and `enable` on
- `DSKLEN` = 0x4000, then `DSKLEN` = 0xC000 | words twice (bit 14 is the
  write direction; paula_floppy starts on the second write in a row with
  bit 15 set)

paula_floppy starts the transfer at the firmware's next status frame (as
for a read). From then on `dmal` = `dmas` = `dmaon & ~fifo_full`, and in
an Agnus disk slot with `dmal` (the three slots per line of "fdd_rd") the
model drives `reg_address_in` = `DSKDAT` and `data_in` = the file's next
word. The word is held through the clk7 edge that ends the slot (paula's
`fifo_wr = buswr & dmaon`) and the model moves to the next word at the
following `clk_28` falling edge. After the last word, paula_floppy waits
for the firmware to empty the FIFO, then raises `blckint`. Bench errors:
`dmas` = 0 in a write slot, a slot after the last word, a number of slots
other than the file's words.

### The bad-header track is the last

The bad header checksum takes `GetHeader`'s "Bad checksum" path
(`FatalError(ERROR_FDD, "Bad checksum", 26, 0)`, `fw/ctrl/fdd.c`). From
the code:

- `GetHeader` returns 0, so `WriteTrack` does not write that sector, and
  `FindSync` goes on to the next sync: sectors 4 to 10 are written
- `WriteTrack` returns at the end of the track (`blckint`)
- the main loop then shows the error page (`*** FATAL ERROR ***`,
  "Floppy emulation", "Bad checksum", `1A`, "Reboot") and stays in its
  error loop. With `ErrorFatal` set that loop calls no `HandleFpga`, so
  paula_floppy gets no more status frames and a later DMA would never
  start. The page's only way out is "Reboot" (`ColdBoot`).

So the bad-header track is written last; the brief's order had it fifth.
The end event is the first `OSD_CMD_OSD_WR` frame of row 7 (the error
page's last row) after the last `blckint`. If no error page came, it
would be the 20th `HandleFpga` frame after it.

### Checks

`l3check.py fdd_wr <run> [<reference run>]`:

- the 10 `=== FDD wdma` lines are the scenario's tracks, in order, 6,334
  words each
- `TEST.ADF`, copied out of `card_saved.img` with `mcopy` (the
  partition's offset from the MBR) to `fdd_wr_saved.adf`, differs from
  the card's original exactly in the written sectors, and each of them
  holds its new data (`mkwrtrack.py`'s `new_data`)
- the bad-header sector is classified as `skipped` (the original data),
  `written` (its new data) or `other` (anything else, which fails)
- `fsck.fat -n` of the saved card's partition is clean
- the OSD: as `fdd_rd` (sounds on, `df0: TEST`, no page before the first
  key), and no `OSD_CMD_OSD_WR` frame from the first write's start to the
  last `blckint`. The rows written after the last `blckint` are recorded
  (rows 0, 2, 3, 4: the error page's title, category, message and code)
- no UART "Illegal track", "Wrong header" or "Second sync"

It prints `HEADER track 80 sector 3 (LBA 883): <fate>; error page:
<rows>`. With a reference run (another run of `fdd_wr` on the same card,
e.g. at another grid point) the saved `TEST.ADF` must equal the
reference's byte for byte and the `HEADER` line must be the same: the
bad-header path is taken the same way in both runs. Also: boot's milestones, no `EXC` / `TRAP`, kick, order, every
MARGIN line with item 7 required (`MARGIN_REQ_fdd_wr`), and bench
`=== PASS`.

`sim/l3/test/fdd_wr_test.sh` (a few seconds) tests the tools offline:

- (a) `mkwrtrack.py`'s stream, decoded independently with `mfm.py`, gives
  back the 11 new sectors after the gap, obeys MFM's run-length rules, and
  with `--bad-header` breaks only that sector's header checksum
- (b) `l3check.py fdd_wr` on synthetic run directories (a card from
  `tools/sim/mkcard.sh`): PASS for the bad sector skipped and for it
  written; FAIL, each with its `BAD` line, for a written sector with one
  wrong byte, a changed sector outside the writes, the bad sector neither
  original nor new, a track missing from the log, an OSD page during the
  writes, and a reference run whose bad-header path differs

Monitor item 7, `fdd_fifo_full_write` (`mon_l3.vh`), counts Agnus disk
slots offered to the write DMA (`dmaon` = 1 with `DSKLEN` bit 14, i.e.
until the last word is in the FIFO) at which the FIFO is full. `dmal` is
then 0 and the slot goes unused: the firmware has not emptied the FIFO in
time. Bound 0. Per track `=== MARGIN (info) 7 fdd write track <c>/<h>`
gives the maximum fill (any clk7 cycle of the DMA, up to `blckint`) and
the slots; at the end, the maximum over all tracks (of 2,048).

### paula_floppy's write FIFO and the RV's gap (Task 14 finding)

During a track write the firmware reads the FIFO as word 3 onwards of a
status frame. paula_floppy loads each word's transmit register
(`spi_tx_data_3 = fifo_out`) at the word's first falling `sck` edge, but
pops the word just read only after it has been received. The pop goes
through the `rx_flag` synchroniser (about 1.5 clk7), the FIFO pointer
update (1 clk7) and the FIFO's registered output (1 clk7): about 56 to
64 `clk_114`. A host that starts the next word sooner gets the previous
word again, and the word it should have had is popped unseen.

- A slower host (the retired 832 firmware, `p4t14c`: 220 to 400
  `clk_114` per word, at least 85 of gap at the slave) read exactly the
  12,668 bytes Agnus wrote on each track and passed every check.
- The RV without a gap (`p4t14w`, image 0162e53f): about 124 `clk_114`
  per word, the 16 bits included. It reads stale words from byte 704 of
  track 0/0 (`aa aa` where the first `44 89` sync belongs). Every sector
  then fails `GetHeader` ("Second sync word missing...", error 21;
  "Wrong header"), nothing is written, and the fatal-error loop stops
  `HandleFpga`. The next DMA never starts, and the run ends at its timeout.
- Item 4's `paula_word_spacing` (bound 40, derived for the receive path)
  does not cover this transmit path: the RV's minimum was 117. Item 7 now
  measures it (`=== MARGIN (info) 7 fdd write FIFO word gap`: a FIFO
  word's last `sck` rise to the next word's first fall, during a track
  write; below 64 is a bench error).

The defect is in `rtl/minimig/paula_floppy.v`, which this phase does not
change (Decision 8; it stays on Paul's backlog,
`findings/osd-riscv/phase4.md` "Found by the L3 bench (Task 14)"). The fix
is the RV firmware's (Paul, 2026-10-19: "fix floppy write before I'll try
it"): `WRFIFO_GAP`, 16 TIMER reads before each word it reads from the
write FIFO, at least 8 `clk_114` each (two `clk_28` edges), the one
listed exception to "No new count-based delays" (`fw/ctrl/README.md`
"Write-FIFO gap"). With it (`p4t14f`, image 17bf2563) the gap at the
slave is at least 202 `clk_114` and `fdd_wr` passes.

An RTL fix also works (not taken): `PAULA_TXPOP=1` makes `run.sh` patch
its run copy of `paula_floppy.v` (never `rtl/`). A track write's FIFO
word is then popped when its transmission starts (`tx_flag` with
`tx_cnt` 3, as Gayle's `hdd_data_rd` pops its read FIFO), so the next
word's load, a whole word later, sees the next entry:

```
-	assign fifo_rd = (busrd & dmaon) | (trackwr & spidat);
+	assign fifo_rd = (busrd & dmaon) | (trackwr & cmd_fdd & tx_flag & tx_cnt==2'd3); // PAULA_TXPOP
```

With the patch, a unit bench (`bfm_floppy` and the RTL with an SPI
reader, not committed) reads all 6,334 words of a track right at every
gap it was tried with, from 128 down to 16 `clk_114` after a word.
Without it, the same bench gets about 3,500 wrong words at 48 `clk_114`
or less. No L3 run was made with the patch (the firmware fix was chosen
first).

### Run

Setup as in "Run":

```sh
SIM=verilator RUNTAG=w bash sim/l3/run.sh xpair fdd_wr
python3 -I sim/l3/l3check.py fdd_wr sim/l3/run_w
bash sim/l3/test/fdd_wr_test.sh
```

The two simulations take about 1.7 to 2.2 hours side by side.
`PAULA_TXPOP=1` (above) is the RTL variant:

```sh
SIM=verilator RUNTAG=we PAULA_TXPOP=1 bash sim/l3/run.sh fdd_wr
```

### Measured (2026-10-19/20, SLAT=8 SJIT=0, SCKDLY 1.5 / C28DLY 0.3, TICKDIV 1 then 643)

RV image 17bf2563 (with `WRFIFO_GAP`); the image without the gap
(0162e53f) for comparison:

| | `p4t14f` | without the gap `p4t14w` |
|---|---|---|
| bfm_floppy starts (end of the key script) | 201,661,805 | 201,236,597 |
| end event (the error page's row 7) | 470,697,752 | none (timeout 700 M) |
| one track write, `DSKLEN` to `blckint` | 15.57 to 15.58 M | 15.34 M (track 0/0) |
| `TEST.ADF` on the saved card | 109 sectors new, 1,650 unchanged | 0 written |
| bad-header sector (40/0 sector 3) | skipped, FATAL "Bad checksum" 1A | - |
| item 7: full at slots / FIFO max | 0 of 63,340 / 518 words | 0 of 6,334 |
| write-FIFO word gap min (bound 64) | 202 `clk_114` over 61,221 words | not measured (monitor added after) |
| `FindSync` / `GetData` per word | 379 / 454 `clk_114` | 124 / - |
| XRAND twin | `p4t14f_xr` SAME (log, 342,601 frames) | - |
| wall time (Verilator, 4 to 6 runs on the machine) | 6,377 s | 7,299 s |

`L3_FDDW_TO` = 700,000,000: 1.5 x the estimate 470 M.

## hdd

`hdd` drives the hard disk path the way an Amiga IDE driver does, against
the real `gayle` (both ports), `paula_floppy`'s HDD commands and direct
mode, and the firmware's `hdd.c`. It boots the `hdd` card (the `boot` card
plus `SYNTH.HDF` and `RDB.HDF`; section "Cards"). The card's configuration
puts the two hardfiles on IDE port 0 (`$DA2000`):

| Unit (`hdd.c` slot) | Drive | File | What |
|---|---|---|---|
| 0 | master | `RDB.HDF`, 4,096 blocks | a plain HDF with its own RDB (`rdb_Flags` 0x17): `hdd.c` patches block 0 for unit 0 only (`ATA_ReadSectors`: `rdb_Flags` 0x12, `rdb_ChkSum` + Flags - 0x12); CHS 16.4.63 |
| 1 | slave | `SYNTH.HDF`, 8,192 blocks | no RDB: `FakeRDB` synthesises an RDSK (LBA 0) and a PART (LBA 1) in the first cylinder; CHS 257.1.32 (more than 255 cylinders); drive LBA = file block + 32 |

(The plan's brief had the units the other way round. The own-RDB patch
applies to unit 0 only, so `RDB.HDF` is hardfile 0: Task 3's card layout.)

`bfm_ide.v` (instance `ide`) starts at the main-loop milestone, once the
chipset reset is low. `minimig_syscontrol` holds it for four frames after
userio_osd's `usrrst` falls, so the Amiga side is still in reset at the
milestone (the plan starts 6.4 M `clk_114` after it); a write then is
lost, as on the Amiga (a first gate attempt, `p4t15c2`, wrote IDENTIFY
into the reset and the firmware never saw a command).
The plan (`plan_hdd` in `bfm_ide.v`; `HDD_PLAN` in `l3check.py`):

| # | Command | Drive | CHS (LBA) | Count | What it checks |
|---|---|---|---|---|---|
| 1 | IDENTIFY DEVICE (EC) | slave | - | - | the 256 words = `fw/ctrl/test/gold/identify.py` (HDF_SYNTHRDB, 257.1.32) |
| 2 | READ SECTORS (20) | slave | 0/0/1 (0) | 2 | RDSK and PART = `gold/rdb.py` `rdsk` / `part` for 257.1.32 |
| 3 | READ SECTORS | slave | 3/0/5 (100) | 64 | the file's blocks 68..131 |
| 4 | SET MULTIPLE (C6) | slave | - | 16 | |
| 5 | READ MULTIPLE (C4) | slave | 255/0/1 (8,160) | 64 | four DRQ blocks of 16, from cylinder 255 into 256 (the last cylinder: 64 sectors cannot start there) |
| 6 | READ MULTIPLE | slave | 256/0/1 (8,192) | 32 | cylinder high = 1 |
| 7 | WRITE SECTORS (30) | slave | 62/0/17 (2,000) | 64 | |
| 8 | WRITE MULTIPLE (C5) | slave | 93/0/25 (3,000) | 32 | |
| 9, 10 | READ SECTORS, READ MULTIPLE | slave | as 7, 8 | 64, 32 | the written data read back |
| 11 | SET MULTIPLE | master | - | 16 | |
| 12 | READ MULTIPLE | master | 0/0/1 (0) | 16 | block 0 patched, 1..15 unchanged (exec-3 tested the patch through READ SECTORS only) |

Then the run's end saves the card (`+SD_SAVE=<run>/card_saved.img`).

TIMER: `TICKDIV` 1. `hdd.c` is status-driven: every wait is on paula's
request bits (`CMD_IDECMD`, `CMD_IDEDAT`). Its one TIMER user, in
`OpenHardfile` (`hdd.c`), bounds nothing: it measures
`BuildHardfileIndex` for the UART line `Hardfile indexed in <n> ms`. The
number is TIMER counts (one count = 256 `clk_28` at `TICKDIV` 1), so it
follows the firmware's speed (only its prefix is a milestone).

The firmware ignores the LBA bit of the device / head register
(`chs2lba` only), so `bfm_ide` addresses in CHS. `ata_cmd` converts an LBA
with the drive's geometry (`g_heads`, `g_spt`), and `l3check.py` checks
that IDENTIFY's words 1, 3 and 6 are that geometry.

Found while reading `hdd.c` (not run): a READ / WRITE
MULTIPLE before any SET MULTIPLE on that unit hangs the firmware.
`sectors_per_block` starts at 0, so each DRQ block is 0 sectors and the
loop never ends (ATA says abort). Every driver sends SET MULTIPLE first,
and so does the plan (also for the master).

### bfm_ide: the 68k side

`bfm_ide.v` reuses `sim/gayle/gayle_tb.v`'s bus tasks by copy (`en`,
`set_addr`, `bus_off`, `hwb`, `hww`, `hr`), on `clk_28` with the bench's
`clk7_en`. A read is one clk7 cycle of address setup, the nrdy stall if
any, and one with `rd`; a write is one clk7 cycle. The host side of ATA
PIO, as `gayle_port.v` and `hdd.c` implement the device side:

- PIO in (IDENTIFY, READ, READ MULTIPLE): per DRQ block, wait for the
  interrupt (Gayle INTENA on, INTREQ cleared after each), read the status
  (BSY 0, DRQ 1), read the block. A READ MULTIPLE block is 16 sectors
  (4,096 words); a read of an empty FIFO is held by `nrdy` while the
  firmware streams the block in direct mode.
- PIO out (WRITE, WRITE MULTIPLE): the first block after polling the status
  for DRQ (no interrupt, ATA), each later block and the end after an
  interrupt.
- No data (SET MULTIPLE): wait for the interrupt.
- Every command ends with the status polled until BSY and DRQ are 0: it
  must be 0x40, no ERR. Then the task file is read back for the log.

Each command logs `=== IDE cmd <k> ...` and `=== IDE end <k> ...`
(status, error, task file, words, the dump file, the waits) and writes its
words to `<run>/hdd_<k>.hex` (16 words per line, `xxd -r -p` gives the
bytes in the 68k's memory order). The write data is a pattern per sector:
`W`, `S` (WRITE) or `M` (WRITE MULTIPLE), the LBA's two bytes, then
`(LBA * 29 + j * 7 + 0x5A) & 255` for byte j (`l3check.py` `wpattern`).
`atapi_packet` (PACKET with 6 command words, then the data-in phases with
the device's byte count) is for the CD scenarios; `hdd` does not use it.

### Checks

`l3check.py hdd`:

- the commands in the log are `HDD_PLAN`, in order; each ends with status
  0x40 and error 0, has at least one interrupt or `nrdy` wait (item 8;
  every command waits for the firmware's interrupt), moved the words of its
  kind, and left the task file `hdd.c` writes: the CHS of the last sector
  for a read or write (its CHS advance, across cylinder 255 / 256 in
  command 5), the host's own registers for IDENTIFY and SET MULTIPLE
- IDENTIFY = `identify.py`'s stream. In the 68k's memory each ATA word is
  little-endian: the firmware sends the low byte first, and the first byte
  of a word lands in bits 15:8 (paula_floppy's shift register), as on an
  Amiga's Gayle (IDE drivers swap the words)
- every sector read = the drive: `SYNTH.HDF`'s blocks (tags `H` 2 n),
  `rdb.py`'s RDSK and PART, zeros for the rest of the RDB cylinder; for
  `RDB.HDF`, block 0 with `rdb_Flags` 0x12 and the checksum computed from
  scratch with `rdb.py` (which must equal `hdd.c`'s incremental one), its
  other blocks as on the card; a sector written earlier = the write
  pattern. The files' tags are checked first
- the WRITE dumps = the write pattern; `card_saved.img` holds each written
  sector in `SYNTH.HDF`'s cluster for its block (`spitrace.py`'s `Card` on
  `<run>/card/hdd.img`), and no other card sector differs from the card
  the run booted

Also, as `boot`: the milestones (`CARD=hdd` lines: both hardfiles found,
their `OpenHardfile` lines, the IDE port frame `20 54 07`), no `EXC` /
`TRAP`,
`kick`, `order`, memhash, every MARGIN line with item 3 required
(`MARGIN_REQ_hdd`: the HDF sectors come in direct mode), bench `=== PASS`.

Item 8, `=== MARGIN 8 ide_wait min <v> clk_114 (bound 0, rec) over <n>
waits`: the time the 68k side spent waiting on the firmware, recorded only
when it waited at all. An interrupt wait runs from the command's or the
block's start to the interrupt (none when it was already pending); a BSY
poll (the first WRITE block, the end of a command) from its start to the
status read that met it, when an earlier read had seen BSY (or DRQ at the
end); a data read held by `nrdy`, its stall. A status read that finds the
drive ready at once is no wait. The flow control is status-driven, with no
margin to violate (plan 7.1: latency only costs throughput), so the line is
`rec`. Each `=== IDE end` line has the command's waits, min / median /
max (the lower median) and the total.

### Run

Setup as in "Run". From the repository root:

```sh
SIM=verilator RUNTAG=h bash sim/l3/run.sh xpair hdd
```

(about 40 minutes side by side.) The data check alone, on a run
directory:

```sh
python3 -I sim/l3/l3check.py hdd sim/l3/run_h
```

### Measured (2026-10-19, SLAT=8 SJIT=0, SCKDLY 1.5 / C28DLY 0.3, TICKDIV 1)

| | `p4t15` (item 8: `p4t15f`) |
|---|---|
| main-loop milestone | 157,326,780 |
| `bfm_ide` starts (chipset reset low) | 163,701,501 |
| end event (the end of command 12) | 187,958,349 |
| `l3check.py hdd` | PASS: 12 commands, 274 sectors read, 96 written and read back, on the saved card and nowhere else |
| item 3 `dmode_release` min | 20.8 over 271 direct transfers |
| item 8 `ide_wait` | min 64.0 over 34,313 waits, `rec` |
| `OSD EARLY` / `OSD GAP` min | 0 of 1,232 / 63 |
| wall time (Verilator, 3 to 5 runs on the machine) | 2,289 s |

`L3_HDD_TO` = 300,000,000 (1.5 x the 200 M estimate; the end came at
188.0 M).

Item 8 per command (Task 15 fix round, run `p4t15f`: the same bench,
firmware and card as `p4t15`, with only the wait accounting changed; its
`spi.txt` and `hw.txt` are byte-identical to that run's). `clk_114`; waits = interrupt / poll / nrdy; min / median /
max; the command's wall in cycles:

| # | Command | waits | min / median / max | cycles |
|---|---|---|---|---|
| 1 | IDENTIFY | 1 / 0 / 0 | 60,464 / 60,464 / 60,464 | 69,024 |
| 2 | READ 2 (RDB) | 2 / 0 / 0 | 55,296 / 55,296 / 66,192 | 138,288 |
| 3 | READ 64 | 64 / 0 / 0 | 48,864 / 48,880 / 63,680 | 3,673,088 |
| 4 | SET MULTIPLE 16 | 1 / 0 / 0 | 210,400 / 210,400 / 210,400 | 210,768 |
| 5 | READ MULTIPLE 64 | 4 / 0 / 15,136 | 80 / 128 / 129,600 | 2,840,912 |
| 6 | READ MULTIPLE 32 | 2 / 0 / 7,568 | 96 / 128 / 70,272 | 1,399,872 |
| 7 | WRITE 64 | 64 / 1 / 0 | 16,736 / 98,768 / 160,928 | 6,666,752 |
| 8 | WRITE MULTIPLE 32 | 2 / 1 / 0 | 12,704 / 1,501,568 / 1,502,720 | 3,148,512 |
| 9 | READ 64 (back) | 64 / 0 / 0 | 48,848 / 48,864 / 66,800 | 3,674,816 |
| 10 | READ MULTIPLE 32 (back) | 2 / 0 / 7,568 | 96 / 128 / 60,192 | 1,389,776 |
| 11 | SET MULTIPLE 16 (master) | 1 / 0 / 0 | 217,872 / 217,872 / 217,872 | 218,240 |
| 12 | READ MULTIPLE 16 (RDB.HDF) | 1 / 0 / 3,831 | 64 / 128 / 119,584 | 826,368 |

No command ended with a BSY poll that had to wait: every end-of-command
status read found the drive ready (poll 0, except the first WRITE block's
wait for the firmware's DRQ: 16,736, and the WRITE MULTIPLE's 12,704). A
READ waits once per sector for the firmware to send it (interrupt; median
49 k: the card's read plus the firmware's turn-around), a READ MULTIPLE once per 16 sectors and then on
`nrdy` for nearly every word (the 68k reads faster than direct mode
delivers: 128, about one 16-bit SPI word at 6 `clk_114` a bit plus the
read; the smallest stalls are 64 to 128). A
WRITE waits per sector for the firmware to read and write it (99 k); a
WRITE MULTIPLE block of 16 sectors costs 1.5 M. SET
MULTIPLE's 210 k is the main loop's turn-around plus the `printf` of "Set
Multiple Mode 16". Item 8 has no bound: these are throughput figures. (In
the first gate run `p4t15` every status read that found the
drive ready counted as a 32-cycle wait, so the min was 32 everywhere: Task
15 review I1.)

XRAND: the first twin, `p4t15_xr` (seed 1,807,595,372), differed from
`p4t15` in one frame. The first IDE command's register read (`10 80`,
`spi.txt` line 6,593) returned gayle's never-written FIFO head word and
features register (`2c bc`, `39` instead of 0); the ATA path does not use
them, and everything else was SAME. `run.sh l3_pin_minimig` now also pins
`gayle_port.v`'s task file and `gayle_fifo.v`'s buffer to 0 at time 0
(`findings/osd-riscv/phase4.md`, "Found by the L3 bench (Task 15)"), and
the twin `p4t15_xr2` (seed 1,512,261,430, `=== XRAND pinned 8217 regs`) is
SAME as `p4t15` (log and 8,959 frames).

## cd

`cd` drives the CD-ROM data path the way an Amiga ATAPI driver does,
against the real `gayle` port 1 (IDE port 2, `$DA3000`) in packet mode,
`paula_floppy`'s HDD commands and direct mode, and the firmware's
`cdrom.c` / `atapi.c` / `cue.c`. It boots the `cd` card (the `boot` card
plus `TEST.CUE`, `TEST.BIN` and `TEST.ISO`; section "Cards"), whose
configuration puts the CD drive on IDE port 2 master with `TEST.CUE` in it
(`CDCFG=cue`, the default) or `TEST.ISO` (`CDCFG=iso`, image
`cd_iso.img`). One run per `CDCFG`; the plan is the same for both, the
answers are the disc's.

`bfm_ide.v` starts its plan `cd` at the main-loop milestone, once the
chipset reset is low (section "hdd"). The plan (`plan_cd`; `CD_PLAN` in
`l3check.py`), all on port 1 master, byte count limit 0xFFFE unless said:

| # | Command | Packet | What it checks |
|---|---|---|---|
| 1 | IDENTIFY PACKET DEVICE (A1) | - | the 256 words = `atapi_identify()` of `fw/ctrl/atapi.c`, read field by field from the source; word 0 0x8580 = ATAPI, CD-ROM, removable, 12-byte packets; the model field = the disc's name (`TEST`) |
| 2 | TEST UNIT READY | `00` | CHECK CONDITION, error 0x60: UNIT ATTENTION 06/29/00 (below) |
| 3 | REQUEST SENSE | `03`, 18 | that sense, fixed format |
| 4 | TEST UNIT READY | `00` | GOOD |
| 5 | INQUIRY | `12`, 36 | type 5, removable, `MINIMIG`, the disc's name, `1.00` |
| 6 | READ CAPACITY | `25` | the lead-out - 1, 2048 |
| 7 | READ TOC | `43`, format 0, LBA, all tracks, 804 | `CDCFG=cue`: the tracks of `TEST.CUE` (data at 0, audio at 214 and 364, lead-out 514, from a CUE reader in `l3check.py`); `iso`: one data track, lead-out = the ISO's blocks (311) |
| 8 | READ(10) | `28`, LBA 16, 32 | the disc's 2048-byte user data: `TEST.ISO`'s blocks 16..47 (the volume descriptors, the root directory, the path tables, `DATA.BIN` from LBA 33), or `TEST.BIN`'s MODE1/2352 sectors from byte 16 (their sync and header checked too) |
| 9 | READ(12) | `A8`, LBA 56, 8, limit 0x0400 | the same for LBA 56..63 (the CUE's last data sectors); the limit splits every phase below a sector |
| 10 | MODE SENSE(10) | `5A`, page 3F, 256 | the 52 bytes of `mode_sense()`: pages 01, 0E (volume FF FF), 2A (not locked) |
| 11 | READ CD MSF (B9) | `B9` | not supported (`atapi.c`'s default): CHECK CONDITION 05/20/00, error 0x54 (ILLEGAL REQUEST << 4, ABRT) |
| 12 | REQUEST SENSE | `03`, 18 | 05/20/00 |

The first command's UNIT ATTENTION is 06/29/00 (power on or reset), not the
insert's 06/28/00: gayle sets `rst_seen` while the chipset reset is high,
and the first task file read of port 1 (`HandleHDD` -> `ReadTaskFile(1)`)
passes it to `CD_Flags()`, whose `CD_Reset()` -> `atapi_reset()` replaces
the pending one.

Every PACKET command: the packet phase (DRQ, interrupt reason CoD, six
words), the data-in phases (an interrupt each, reason IO, the device's
byte count: `cd_send_sectors()` blocks of at most the limit and 8 KB for an
ISO, straight from the card in direct mode; `cd_send_raw()` one 2048-byte
sector per block for the CUE's MODE1/2352 track, split by the limit), then
the status phase (interrupt, status 0x40, or 0x41 where the plan expects
CHECK CONDITION). `l3check.py cd` also checks the error register
(`cd_error()`), the task file `cd_complete()` leaves (reason 03, the
host's limit in the byte count registers), the phases (reason 02, each at
most the limit and 8 KB, their bytes = the answer's length) and that the
dumps (`<run>/cd_<k>.hex`, as in "hdd") equal the answers.

TIMER: `TICKDIV` 643 from the scenario's start (`+TICKDIV_AT=scenario`),
the board's rate. `cdrom.c`'s `cd_wait()` aborts a phase whose host does
nothing for `CD_TIMEOUT` = 10000 TIMER counts, 58 s on the board (the
source says "ms": `GetTimer()` counts TIMER ticks). The scenario does not
wait 58 s (exec-3 hand-over item 9): it measures how far a normal READ(10)
stays from the timeout. Item 9 (`=== MARGIN 9 cd_timeout_left`, section
"Monitors") takes every phase window on port 1, from the firmware's
`CMD_IDE_XFER_WR` to gayle's `xfer_done`: `cd_wait()` polls inside it.
`l3check.py cd` requires one window per packet and data phase, prints the
longest one (`INFO`, with the command it was in and its share of
`CD_TIMEOUT`) and the firmware's longest service time: the longest wait of
the 68k side on the firmware (the `=== IDE end` lines' max: an interrupt,
a BSY poll or an `nrdy` stall).

Also, as `boot`: the milestones (`CARD=cd_cue` / `CARD=cd_iso` lines: no
drive sounds, no hardfiles, the disc's files found by `CD_Insert()`, the IDE
port frame `20 54 01`), no `EXC` / `TRAP`, `kick`, `order`, memhash,
every MARGIN line with item 9 required (and item 3 for `iso`), bench
`=== PASS`.

### Run

Setup as in "Run". From the repository root:

```sh
SIM=verilator RUNTAG=c CDCFG=cue bash sim/l3/run.sh xpair cd
SIM=verilator RUNTAG=ci CDCFG=iso bash sim/l3/run.sh cd
```

`xpair` runs the scenario and its XRAND twin side by side; on a busy
machine run them one after the other (`XRAND=0` and `XRAND=1` with the
RUNTAGs `c` and `c_xr`, then `bash sim/l3/run.sh compare c c_xr`).
The data check alone, on a run directory:

```sh
python3 -I sim/l3/l3check.py cd sim/l3/run_c
```

### Measured (2026-10-20, SLAT=8 SJIT=0, SCKDLY 1.5 / C28DLY 0.3, TICKDIV 1 then 643)

Runs `p4t16` (cue) and `p4t16i` (iso), `RV32OSDA.BIN` sha256
0162e53fc0b4ce4d. Cycles are `clk_114`:

| | cue | iso |
|---|---|---|
| main-loop milestone | 156,926,388 | 156,388,796 |
| `bfm_ide` starts (chipset reset low) | 163,701,501 | 163,701,501 |
| end event (the end of command 12) | 185,153,357 | 171,271,517 |
| `l3check.py cd` | PASS | PASS |
| READ(10) 32 / READ(12) 8 sectors | 32 x 2,048 / 16 x 1,024 bytes | 8 x 8,192 / 16 x 1,024 |
| READ(10) / READ(12), cycles | 16,835,376 / 4,277,056 | 5,644,624 / 1,588,288 |
| item 9: phase windows; the longest (in READ(10)) | 65; 161,376 = 0.245 counts | 41; 690,208 = 1.048 |
| its share of `CD_TIMEOUT` (6,584,320,000) | 2.5e-5 | 1.05e-4 |
| the longest 68k wait on the firmware (READ(10)) | 419,280 | 127,872 |
| item 3 `dmode_release` min | n/a | 20.8 over 160 |
| item 8 `ide_wait` min | 16.0 over 25,533 | 112.0 over 33,501 |
| `OSD EARLY` / `OSD GAP` min | 0 of 1,331 / 63 | 0 of 1,435 / 63 |
| wall time (Verilator) | 3,025 s | 1,129 s |

The ISO windows are the longest: a phase of 8 KB is set up, filled from
the card in direct mode (16 FAT sectors) and drained by the 68k inside one
window; a CUE sector is read into the CPU first and its window is only the
SPI copy into the FIFO and the drain. The firmware's longest service time is
the CUE's: the interrupt of a raw sector comes after four or five FAT-sector reads
through the CPU (`cd_file_read()`) and the copy, 419 k `clk_114`, 3.7 ms. Every window is at most about one TIMER count at the
board's rate, four orders of magnitude below `CD_TIMEOUT`.

`L3_CD_TO` = 315,000,000: 1.5 x the estimate 210 M; the end came at
185.2 M.

XRAND: the twin `p4t16_xr` (seed 816,455,678, `pinned 8217 regs`) is
`compare` SAME with `p4t16` (log and 7,642 frames).

## cdda

`cdda` plays CD audio the way an Amiga CD player program does, through
`atapi.c`'s audio commands and `cdaudio.c`'s player into the 64 KB ring,
at the board's TIMER rate. `cdda_load` is the same with an HDF transfer
during the play (plan 7.4 "HDF copy with CD audio", plan 1.2:
"underruns come from foreground jobs blocking the loop > 150 ms").

| | `cdda` | `cdda_load` |
|---|---|---|
| card | `cd` (`CDCFG=cue`: `TEST.CUE` in the CD drive, IDE port 2 master) | `cdhdd`: the same configs, plus the `hdd` card's `SYNTH.HDF` and `RDB.HDF` on IDE port 0 |
| plan (`bfm_ide.v` `plan_cdda`) | below | below, plus at flip 2 SET MULTIPLE 16 and READ MULTIPLE of 256 sectors of `SYNTH.HDF` (port 0 slave, LBA 1000) |
| TIMER | `TICKDIV` 643 from the scenario's start | the same |

The player (`bfm_audio.v`) takes one stereo frame per tick, so at 643 one
32 KB half (8,192 frames) lasts 186 ms = 21.1 M `clk_114`. The plan, on
IDE port 2 master, byte count limit 0xFFFE:

| # | Command | Packet | Then |
|---|---|---|---|
| 1 | TEST UNIT READY | `00` | CHECK CONDITION: the reset's UNIT ATTENTION (error 0x60), which would otherwise refuse the PLAY |
| 2 | PLAY AUDIO MSF | `47`, 00:04:64 .. 00:06:27 | LBA 214 .. 326: track 2 from its INDEX 01, 113 sectors = 66,444 frames (1.5 s). `cdaudio.c` `run()` fills both halves before the status phase |
| (3, 4) | `cdda_load`: SET MULTIPLE, READ MULTIPLE 256 | ATA, port 0 slave | at the player's flip 2; the data = `SYNTH.HDF` blocks 968..1223 |
| 3 | PAUSE | `4B`, byte 8 = 0 | at flip 6 |
| 4 | READ SUB-CHANNEL | `42`, SubQ, format 1, LBA, 16 bytes | the paused position |
| 5 | RESUME | `4B`, byte 8 = 1 | a new run from the position |
| 6 | STOP | `4E` | at flip 7 (the resumed run's first) |

After each flip the plan waits 500,000 `clk_114` (4.4 ms) more before its
next command. By then the firmware has seen the flip and started the
refill (`main()` calls `CD_AudioPoll()` before `HandleFpga()`), so it
serves the command after the refill.

**Ring snapshots.** With `+CDDA_DUMP=<run>/cdda_half` the model copies,
at every half start, the 32 KB half the player is about to play from the
SDRAM model (ring at host 0x70000, half h at 0x70000 + h x 0x8000) into
`<run>/cdda_half_<n>.bin`. A half starts at a run's start (ENA: half 0)
and at every flip (the tick that takes the play address into the other
half). The log has `=== CDDA half <n> run <r> k <k> ring half <h> at cycle
<c>: <file>` and per run `=== CDDA run <r> start` / `end ... <f> frames
played, <k> halves`. The PLAY's run has 7 halves (6 flips, then the
PAUSE), the RESUME's 2. The boot makes a run of its own before the
scenario: `main()`'s `audio_clear()` zeroes the ring, sets ENA for one
TIMER count and clears it again (the copy is in the log; `l3check.py`
counts only the runs from the PLAY on).

**Refill timing** (plan 4.4, `mon_l3.vh`):

- `=== CDDA fill <n> start <cycle> done <cycle> (<ms> ms at 113.4375 MHz)`:
  from flip n to the firmware's last SDRAM write into the half that is now
  free, before the next flip or the player's stop. `done none` means no
  write at all.
- `=== CDDA start fill run <r>`: `run()`'s own fill of both halves, from
  the CLEAR to ENA.
- `=== CDDA fills <n>`: min / median / max over the run.
- `=== CDDA main loop while playing`: the gaps between two main-loop
  frames (`HandleFpga`'s `10` + six 00 bytes) while the player runs: one
  pass of `main()`'s loop, refills and served IDE commands included.
- `=== CDDA writes into the playing half: <n>`: the firmware's underrun
  response (`cda_poll` zeroes the late half) or a defect.

### Checks

`l3check.py cdda <run>` (both scenarios; the script's docstring has the details):

- the commands in order, each with its status, error register and task
  file (`cd`'s rules); `cdda_load`'s 256 sectors = `SYNTH.HDF`
- two runs of 7 and 2 halves, ring half k mod 2
- every half = what `cdaudio.c` `fill()` puts there: range frame f =
  base + k x 8,192, `TEST.BIN`'s bytes of the CUE's track 2 (LE 16-bit
  stereo; gaps, data sectors, past the file or the range: zeros), scaled
  with `scale()` when the volume is not 255 / 255 (`cda_init`'s volume,
  read from `fw/ctrl/cdaudio.c`; the scenario sends no MODE SELECT). The CUE is read by `l3check.py`'s own reader, not `cue.c`. base
  is 0 for the PLAY's run. For the RESUME's it is the firmware's paused
  position: a multiple of 256 frames (TIMER units) inside the sector READ
  SUB-CHANNEL reports, and within one half of the frames the player had
  played at the PAUSE
- a half that differs is an **underrun** (a late refill) when each frame
  is the expected one, that ring half's earlier content (two halves
  before in the run) or zero. Anything else, or any difference in a run's
  first two halves (filled before ENA), is a **wrong** half, which fails
  both scenarios. `cdda`: no underrun and no write into the playing half.
  `cdda_load`: the underruns are counted (`INFO`) and recorded (0 in every
  run so far, "Measured")
- READ SUB-CHANNEL: 16 bytes, audio status 12 (paused), adr/control 10,
  track 2 index 1, LBA 214 + pos / 588, relative LBA
- one `=== CDDA fill` line per flip (7), each with a write; the min /
  median / max ms and the main-loop gaps as `INFO`
- `TICKDIV` 643 from the scenario's start
- the ring is all zero at the end (`sdram.bin`, host 0x70000..0x7ffff):
  the STOP's `release()` clears it, so the drive sounds do not start on a
  remnant of the music. The ring held TEST.BIN frames at the STOP
  (the RESUME's halves), so the zeros are the STOP's

Also, as `cd`: the milestones (`CARD=cd_cue`; `cdda_load`: `CARD=cdhdd`,
the `hdd` card's hardfile lines and `cd_cue`'s disc lines, the IDE port
frame `20 54 07`), no `EXC` / `TRAP`, `kick`, `order`, memhash, every
MARGIN line with item 9 required (`cdda_load`: also 3), bench `=== PASS`.

The per-half check against the BIN and the zero ring at the end are the
ring's content gates.

### Run

Setup as in "Run". From the repository root:

```sh
SIM=verilator RUNTAG=a bash sim/l3/run.sh xpair cdda
SIM=verilator RUNTAG=al bash sim/l3/run.sh cdda_load
```

Each run is long, because the board's TIMER rate makes the play last
1.5 s of simulated time. See "Measured" for the wall times. The data check
alone, on a run directory:

```sh
python3 -I sim/l3/l3check.py cdda sim/l3/run_a
```

### Measured (2026-10-20, SLAT=8 SJIT=0, SCKDLY 1.5 / C28DLY 0.3, TICKDIV 1 then 643)

Runs `p4t17` / `p4t17_xr` (`cdda` and its twin) and `p4t17l`
(`cdda_load`), `RV32OSDA.BIN` sha256 0162e53fc0b4ce4d. Cycles are
`clk_114`, ms at 113.4375 MHz:

| | `cdda` | `cdda_load` |
|---|---|---|
| `l3check.py cdda` | PASS | PASS |
| PLAY's `run()` (both halves, CLEAR to ENA) | 84.1 ms | 84.1 ms |
| refill after a flip, min / median / max (7 fills) | 4.65 / 42.40 / 42.42 ms | 4.66 / 42.39 / 42.96 ms |
| RESUME's `run()` | 80.6 ms | 80.6 ms |
| main loop while playing: gaps, median / max | 17,163, 0.063 / 42.44 ms | 15,585, 0.063 / 42.97 ms |
| underruns (late halves) / writes into the playing half | 0 / 0 | 0 / 0 |
| paused at (READ SUB-CHANNEL) / RESUME from | LBA 300 / frame 50,944 | LBA 300 / 50,944 |
| the player at the PAUSE | 51,030 frames | 51,029 |
| READ MULTIPLE 256 (`cdda_load`) | - | 11.20 M cycles, = `SYNTH.HDF` |
| item 3 `dmode_release` min | n/a | 20.8 over 256 |
| `OSD EARLY` | 0 of 18,487 | 0 of 16,996 |
| end event (STOP's end) | 337,017,061 | 337,077,525 |
| wall time (Verilator) | 2,665 s | 2,646 s |

A refill is 64 TEST.BIN sectors read through the CPU (`cda_port_read`, 128
SD blocks for 32 KB) and copied into the ring. The minimum is the last
fill after the RESUME, which lies past the range's end (all zeros, no SD
read). Each refill blocks the main loop (`cda_poll` runs inside it): the
longest main-loop gap is one refill, plus a block of the HDF transfer
under load. The PAUSE comes 4.4 ms after flip 6 and is served after that
refill, so the paused position is TIMER-quantised and follows the refill
time; `l3check.py` checks it, and the RESUME's fill, against TEST.BIN.

XRAND: the twin `p4t17_xr` (`pinned 8217 regs`) is `compare` SAME with
`p4t17` (log and 93,557 frames).

`L3_CDDA_TO` = 520,000,000 (`cdda` and `cdda_load`): 1.5 x the estimate
345 M; the ends came at 337.0 M / 337.1 M.

The underrun gate is weak: 0 underruns. With the 256-sector READ MULTIPLE
the longest main-loop gap is 43 ms, against the half's 186 ms, so plan
1.2's > 150 ms foreground job would need a longer transfer.

### Slow host (`+IDE_HOST_DELAY`, the board deadlock of 2026-10-20)

On the board, CD audio playing plus an HDF READ MULTIPLE of more than 16
sectors hung the firmware (GDB: `ATA_ReadSectors` -> `CD_AudioPoll` ->
`ReadIDEFlags(1)`). `cdda_load` passed with that firmware: `bfm_ide.v`
reads each block while the firmware is still sending it (the reads stream
behind the SD transfer, `nrdy` holds them), so at the firmware's first
"drained" poll after a block (`10 f0 08`, then `10 00 ..` answering `14`)
the FIFO is already empty and the drain-wait loop of `hdd.c` never calls
the poll (`run_p4t17l`: 0 flag reads there). A real Amiga with other work
(the CD player program, the OS) reads later.

`XARGS=+IDE_HOST_DELAY=<n>` makes the model wait n `clk_114` after each
PIO-in block's interrupt before reading it (default 0: every other run is
unchanged; the log says `=== IDE host delay <n> ...`). n must be longer
than the firmware takes to send a block (~700 K cycles for 16 sectors):
200,000 still streamed (0 flag reads in the loop, PASS on the old
firmware); 2,000,000 (17.6 ms per block) leaves the FIFO full when the
firmware polls, so the loop runs. With the old poll the loop's
`ReadIDEFlags(1)` (`10 81`) re-latches the Gayle's firmware port to
port 2: the run shows the board's signature, `10 00` (status `10`, no
IDECMD) and `10 81` alternating after the second block's status write,
and the Amiga's second block never comes. The fix (`CD_AudioRefill` in
the transfer loops, no flags read; `fw/ctrl/cdrom.h`) leaves the port
alone.

```sh
SIM=verilator RUNTAG=cdf_new XARGS="+IDE_HOST_DELAY=2000000" bash sim/l3/run.sh cdda_load
```

Measured 2026-10-20 (Verilator, SLAT 8, `+IDE_HOST_DELAY=2000000`; runs
`cdf_old` / `cdf_new`, kept only locally):

| | old firmware (6ea1b76 build, sha256 17bf2563) | fixed (05e8780, sha256 1c6bbd5a) |
|---|---|---|
| `10 81` frames in the READ MULTIPLE's drain waits | 420 after the 2nd block's status write, then for ever | 0 (3,644+ status polls: the loop ran) |
| READ MULTIPLE 256 data | 240 of 256 sectors wrong (only the first block right), task file 00 07 2f (want 00 08 27) | = `SYNTH.HDF` blocks 968..1223 |
| firmware after it | stuck: `10 00` / `10 81` alternating (6,586 each) and the audio refill's SD reads to the end, no OSD frame | main loop, the plan goes on |
| verdict | FAIL (`TIMEOUT=290000000`: commands 1..4 only) | `cdda_load` PASS, 337.3 M cycles, 2,684 s wall |

## akiko

`akiko` exercises the host's Akiko request service, the legacy interrupt
path (plan 7.1 item 13). In this build the host side of Akiko is a logging
stub: `akiko_inthandler()` (`fw/ctrl/akiko.c`) reads
cfide's ADDR and DATA registers (`0xFFFFFF80`, `0xFFFFFF84`), prints
"Akiko write: <addr>, <data>" or "Akiko read: <addr>" (hex), and writes
DATA = 0, which is the ack (`amiga_ack`, one `clk_28` cycle, and `amiga_q`
= 0). There is no C2P in the host: the C2P is `rtl/minimig/akiko.v` on the
Amiga side, and `rtl/soc/minimig_virtual_top.v` ties the host request path
off. The scenario therefore checks the request / ack / print path and its
latency, not a conversion.

`bfm_akiko.v` is the requester. A request sets `amiga_addr`, `amiga_d`,
`amiga_wr`, raises `amiga_req` and holds all of them to `amiga_ack`; it
drives and samples on the falling `clk_28` edge. After the ack it waits for
the firmware's `EnableInterrupts` (an `0xFFFFFFA0` write with bit 0 set)
and `+AKI_GAP=<n>` more `clk_28` cycles (default 4): a request raised before
that sets no interrupt flag (cfide `int_legacy_nx` needs `interrupt_ena`)
and would be lost, so the model keeps out of that window and logs its length
as "rearm" (`findings/osd-riscv/phase4.md` Task 18). One block is 32 write
requests, then 32 read requests: `addr = 0x20 + 0x80 b + i`, write data
`((i + 1) * 0x9E37) & 0xFFFF` (xor `0xC3A5` in block 1).

Scenario: the `fdd` card (as `fdd_rd`), TICKDIV 643 from the main-loop
milestone. Block 0 runs at the 20th HandleFpga frame after the milestone
(`AKIKO_PASSES`), in the idle main loop, after the main loop's first passes
(the first drive status, OsdHide): during the ISR's UART-bound burst the
main loop does not advance, so block 0 is kept clear of those first frames
(Task 19). When it is done the key script `keys/insert_df0.txt`
starts, then `bfm_floppy.v` reads 2 tracks (cylinders 0 and 1, head 0;
`AKIKO_TRACKS` in `scenarios.vh`), and block 1 starts at the first track
DMA's DSKLEN write. The end event is the first HandleFpga frame after block
1 and the last track DMA are done (`=== STATS@akiko`): it is a frame's close,
so no frame is in flight when the run ends.

`l3check.py akiko <run>` checks: the 128 requests in order, none lost or
repeated (the log's `=== AKIKO req` lines), each with the bench's pattern
(recomputed in Python) and acked; every read answered 0; the UART lines
equal to the pattern (upper-case hex, `%X`); exactly 128 DATA writes of 0 in `hw.txt`; block 1's
first request and at least 16 of its requests inside the DMA; both track
dumps decode to `TEST.ADF`; the OSD pages of `fdd_rd` (no error page); and
prints the latency table (min / median / max of `amiga_req` to `amiga_ack`,
and of the ack to `EnableInterrupts`). Test first:
`bash sim/l3/test/akiko_check_test.sh` builds synthetic run directories from
the bench's and the firmware's line formats; the good ones pass, and the
mutants (one wrong UART word, a lost, a repeated and an unacked request, a
read that returns data, a missing DATA write, a line with lower-case hex) each fail
with their own `BAD` line.

Run (from the repository root; toolchain and packages as in "Run"):

```sh
SIM=verilator RUNTAG=p4t18 bash sim/l3/run.sh akiko
```

`XRAND=1` with another `RUNTAG` is the twin (or `run.sh xpair akiko`).
Verilator wall time 2,611 s (259.9 M cycles) on a loaded machine.
`L3_AKIKO_TO` = 520,000,000. The MARGIN 6 monitor stays required: the
ISR's UART prints stall the main loop, and the floppy FIFO never ran empty
(0 slots, fifo min 995 words).

## sdc

The SD card engine (`findings/sdcard-engine/design.md`): `sdcard_spi` on
cfide's ext port with the card model on its pins, `sdcard_gayle` + the mux
between paula_floppy and gayle (`tb_l3.v` `SD_ENGINE`, wired as
`minimig_virtual_top` / `minimig.v` with `SD_ENGINE = 1`). The boot ROM
(since plan Task 12) and the firmware (since Task 10) reach the card only
through it, so on this tree the scenarios without the engine stop in the
ROM's `SD init` (VERSION 0): `sdc_boot`, `sdc_boot_short` and `sdc_hdd` are
`boot`, `boot_short` and `hdd` on the engine, the full-system test of the
lock-step pair (the committed boot ROM and `RV32OSDB.BIN` from the same
tree, with its `SDCV` trailer; the name is `fw/ctrl/fwname.mk`'s since Task
13b, the ROM's line `file "RV32OSDBBIN" found`).

| run.sh | bench `+SCENARIO` | card | timeout (`clk_114`) |
|---|---|---|---|
| `sdc_boot` | `boot` (+`SD_LOG=1`) | `boot` | `L3_SDC_BOOT_TO` 197,700,000 |
| `sdc_boot_short` | `boot_short` (the xsim cross-check; no `SD_LOG`: the model's log lines differ in a space between the simulators) | `boot` | `L3_SDC_SHORT_TO` 42,000,000 |
| `sdc_hdd` | `hdd` (+`SD_LOG=1`) | `hdd` | `L3_SDC_HDD_TO` 248,600,000 |

`SD_ENGINE` is always 1 there (`SD_ENGINE=0` is refused). The card model
checks CRCs once the firmware sends CMD59 (both the ROM and the firmware
do), and answers CMD10 with a CID (`tools/sim/README.md`). Checks: the
base scenario's (milestones, kick, order, mmc for `sdc_boot`, `l3check.py
hdd` for `sdc_hdd`, memhash, the MARGIN lines, the bench verdict) with

- `milestones_boot.txt`'s `SDE=1` lines instead of its `SDE=0` ones (`run.sh
  milestones`; until the Task 13 fix round the filter dropped every `SDE=`
  line, of both values, so these were not checked in the first runs): the
  ROM's `SD init: VERSION ...`, `CMD0 01` ... `CMD59 00`, `SD card: SDHC`,
  the lock-step line `Firmware SDC <v>, bitstream SDC <v>`; the firmware's
  `sd_init` lines (`ACMD41 00, 3 polls`, `OCR c0ff8000, type 3`, `CMD59
  00`, `SCK div 2`)
- MARGIN item 3 not required (`MARGIN_REQ_sdc_hdd` = boot's): there is no
  direct-mode transfer
- `run.sh sdc_check`:
  - lock-step: `fw/ctrl/sdc.h`'s `SDC_VERSION` is the firmware file's
    trailer (`SDCV 00 00 <v>`), the VERSION the ROM read (`SD init: VERSION
    <v>, card 1`) and both sides of `Firmware SDC <v>, bitstream SDC <v>`
  - no frame with `sd_cs[1]` low in `spi.txt` and item 3 without events:
    the card is not on cfide's SPI
  - `=== SPI SCK period after the firmware's start (no RTC frame): min <a>
    max <b> clk_114 over <n> bits` (`tb_l3.v`): `b` at most 6, cfide's
    `SPI_fast` (Task 13 finding, below)
  - the SD error lines on the UART (each UART line also cut at the
    firmware's `\r`): the ROM's `SD CMD<n>: R1 ..., try <t>` and `SD read
    <lba>: <what> <v>, try <t>`, the firmware's `SD: ...` lines (the retry
    table's `SD: <row>, row <r>, retry <k> of <n>, lba <l>`, `retries out`,
    `op failed`, `CMD13 probe`, `SCK one step slower`), `SD init: CMD10 /
    CMD9 <err>`, `card changed`, `CID unreadable`: none unless `XARGS`
    injects (`+SD_ERR_`); with an injection the leg says which retry it
    must give: exactly `EXPECT_RETRY_N` (default 1) retry lines (the
    firmware's row lines and the ROM's `try` lines together), all matching
    the ERE `EXPECT_RETRY` (required with an injection), and no `retries
    out`, `op failed`, `CMD13 probe`, `card changed`, `CID unreadable`
  - `=== SDC gayle to_gayle <n> ops <w> words, from_gayle <n> ops <w>
    words, g_err <e>, ended by g_ack <a>; irq rises <i>` (`tb_l3.v`): no
    `g_err`; `sdc_hdd`: to_gayle 69,376 words (271 sectors: the plan reads
    274, three of them built by the CPU: the FakeRDB RDSK and PART and
    RDB.HDF's patched block 0) and from_gayle 24,576 (96 sectors), so every
    card sector the plan moves passes the bridge (READ / READ MULTIPLE
    to_gayle, WRITE / WRITE MULTIPLE from_gayle with the 68k as PIO master);
    `sdc_boot`: no Gayle op

Error injection: the model's `+SD_ERR_<kind>=n` (`tools/sim/README.md`)
counts from time 0, so `XARGS=+SD_ERR_RDCRC=3` hits the boot ROM's third
block (the directory sector). `XARGS="+SD_ERR_AT=scenario ..."` (`tb_l3.v`)
holds the injection off until the main-loop milestone and counts n from
there (`=== SD_ERR armed at the scenario start ...` gives the absolute
numbers): `+SD_ERR_RDCRC=70` hits a block of command 5 (READ MULTIPLE),
`+SD_ERR_WRREJ=67` the third block of command 8's first CMD25 (WRITE
MULTIPLE). The legs and their expected retry line:

| Leg | `XARGS` | `EXPECT_RETRY` (exactly one) |
|---|---|---|
| the ROM's read retry | `+SD_ERR_RDCRC=3` | `^SD read [0-9]+: CRC [0-9A-F]{2}, try 1$` |
| the firmware's read retry (row 1) | `+SD_ERR_AT=scenario +SD_ERR_RDCRC=70` | `^SD: read CRC, row 1, retry 1 of 4, lba [0-9]+$` |
| the firmware's write resend (row 2) | `+SD_ERR_AT=scenario +SD_ERR_WRREJ=67` | `^SD: write CRC \(0B\), row 2, retry 1 of 4, lba [0-9]+$` |

### Run

Setup as in "Run". From the repository root, one at a time. Every run
needs a RUNTAG of its own that no earlier run used (`<t>` below: put a new
tag for each line, e.g. the date and a letter; a reused run directory is
deleted and its results can be mistaken for the new ones). `BUILD_FROM`
takes the simulator of the second line's run (`<t2>`):

```sh
SIM=verilator RUNTAG=<t1> bash sim/l3/run.sh sdc_boot
SIM=verilator RUNTAG=<t2> bash sim/l3/run.sh sdc_hdd
SIM=verilator RUNTAG=<t3> BUILD_FROM=<t2> XARGS=+SD_ERR_RDCRC=3 \
  EXPECT_RETRY='^SD read [0-9]+: CRC [0-9A-F]{2}, try 1$' bash sim/l3/run.sh sdc_hdd
SIM=verilator RUNTAG=<t4> BUILD_FROM=<t2> XARGS="+SD_ERR_AT=scenario +SD_ERR_RDCRC=70" \
  EXPECT_RETRY='^SD: read CRC, row 1, retry 1 of 4, lba [0-9]+$' bash sim/l3/run.sh sdc_hdd
SIM=verilator RUNTAG=<t5> BUILD_FROM=<t2> XARGS="+SD_ERR_AT=scenario +SD_ERR_WRREJ=67" \
  EXPECT_RETRY='^SD: write CRC \(0B\), row 2, retry 1 of 4, lba [0-9]+$' bash sim/l3/run.sh sdc_hdd
SIM=verilator RUNTAG=<t6> BUILD_FROM=<t2> bash sim/l3/run.sh sdc_boot_short
RUNTAG=<t7> bash sim/l3/run.sh sdc_boot_short
bash sim/l3/run.sh compare <t7> <t6>
```

(`sdc_boot_short` under xsim: 677 s; Verilator 139 s.)

### Measured (2026-10-25, SLAT=8 SJIT=0, SCKDLY 1.5 / C28DLY 0.3, TICKDIV 1)

| Event | `sdc_boot` (`sdcb`) | `sdc_hdd` (`sdch`) | `boot` / `hdd` on cfide's SPI (2026-10-19, before Tasks 10-12) |
|---|---|---|---|
| the ROM jumps to the firmware (first read of 0x2000) | 12,124,992 | 12,124,992 | 43,190,675 |
| the Amiga released after the kickstart upload | 130,496,541 | 129,923,501 | 156,968,829 |
| main-loop milestone (first HandleFpga frame) | 131,554,090 | 130,980,654 | 158,044,038 / 157,326,780 |
| end event | 131,750,230 | 165,090,989 | 158,155,012 / 187,958,349 |
| wall time (Verilator, alone on the machine) | 538 s | 689 s | 412 s / 2,289 s (3 to 5 runs) |

`sdc_boot_short` (`sdcs`) ends at 27,971,124 (139 s); the timeouts are 1.5 x
these ends (`sdc_hdd`'s with the write retry of `sdch_wrrej`, 165,702,565).
The kickstart upload (1,024 sectors read one at a time into SDRAM) takes
107 M cycles from the first CPU reset to the release, about 105 k a sector.

`sdc_hdd` per command (`clk_114`; waits = interrupt / poll / nrdy, min /
median / max; the command's cycles), against `hdd`'s on cfide's direct
mode (`p4t15f`, section "hdd"):

| # | Command | waits | min / median / max | cycles | cfide (`p4t15f`) cycles |
|---|---|---|---|---|---|
| 1 | IDENTIFY | 1 / 0 / 0 | 66,720 / 66,720 / 66,720 | 75,280 | 69,024 |
| 2 | READ 2 (RDB) | 2 / 0 / 0 | 64,160 / 64,160 / 81,584 | 162,544 | 138,288 |
| 3 | READ 64 | 64 / 0 / 0 | 72,432 / 72,608 / 173,696 | 5,280,704 | 3,673,088 |
| 4 | SET MULTIPLE 16 | 1 / 0 / 0 | 219,984 | 220,352 | 210,768 |
| 5 | READ MULTIPLE 64 | 4 / 0 / 60 | 25,504 / 29,728 / 162,208 | 2,868,976 | 2,840,912 |
| 6 | READ MULTIPLE 32 | 2 / 0 / 30 | 25,904 / 29,728 / 106,912 | 1,421,648 | 1,399,872 |
| 7 | WRITE 64 | 64 / 1 / 0 | 33,504 / 96,720 / 191,760 | 6,589,488 | 6,666,752 |
| 8 | WRITE MULTIPLE 32 | 2 / 1 / 0 | 15,168 / 964,432 / 973,248 | 2,084,368 | 3,148,512 |
| 9 | READ 64 (back) | 64 / 0 / 0 | 72,576 / 72,592 / 100,496 | 5,207,136 | 3,674,816 |
| 10 | READ MULTIPLE 32 (back) | 2 / 0 / 30 | 25,904 / 29,728 / 91,584 | 1,406,320 | 1,389,776 |
| 11 | SET MULTIPLE 16 (master) | 1 / 0 / 0 | 232,848 | 233,216 | 218,240 |
| 12 | READ MULTIPLE 16 (RDB.HDF) | 1 / 0 / 15 | 29,584 / 29,648 / 146,048 | 848,976 | 826,368 |

The bridge moves a READ MULTIPLE block's words as the 68k reads them
(`nrdy` waits of one sector, 26 to 30 k, instead of one per word); a
single-sector READ costs 72.6 k (median) against 48.9 k on direct mode, a
WRITE MULTIPLE group of 16 0.96 M against 1.5 M. These are simulation
figures of the card model (`SD_TOKEN_DLY` 4, `SD_BUSY` 8): the board's
card latency decides (plan Task 14).

Injection legs (`sdc_hdd`, all PASS with the same data checks):

| RUNTAG | XARGS | Where it hit | UART | Then |
|---|---|---|---|---|
| `sdch_rdcrc3` | `+SD_ERR_RDCRC=3` | the boot ROM's directory sector, LBA 2120 | `SD read 2120: CRC 08, try 1` | the ROM read it again; boot, lock-step and every check as `sdch` |
| `sdch_rdfw` | `+SD_ERR_AT=scenario +SD_ERR_RDCRC=70` | block 1,603: command 5 (READ MULTIPLE), LBA 11,011 in a CMD18 from 11,008 | `SD: read CRC, row 1, retry 1 of 4, lba 11011` | CMD12, CMD18 from 11,011 (the failed block); the 64 sectors right |
| `sdch_wrrej` | `+SD_ERR_AT=scenario +SD_ERR_WRREJ=67` | written block 67: command 8 (WRITE MULTIPLE), LBA 5,850, the third block of the CMD25 from 5,848 | `SD: write CRC (0B), row 2, retry 1 of 4, lba 5850` | stop token, ACMD22, CMD25 from 5,850 (TX_REWIND); the card image right |

### Found by these runs (Task 13)

- **cfide's SPI ran at the boot ROM's slow setting until the main loop.**
  The ROM sets `SPI_slow` (0xef, about 960 `clk_114` a bit) for its own
  frames; before Task 12 its card init and the firmware's `MMC_Init` (the
  card on that SPI) set it fast again. On the engine neither touches it,
  so every OSD / FPGA / floppy frame of the firmware ran at the ROM's speed
  until the first `HandleRTC` (the version frame 54,374 `clk_114` instead
  of 1,026, first run `t13x1`; its OSD GAP fell to 28, a bench error).
  Fixed in the firmware (`fw/ctrl/main.c`: `SPI_fast()` at the start of
  `main()`); the SCK monitor and `sdc_check` hold it.
- **The L3 xsim build had failed since Phase 4 Task 14:** `bfm_floppy.v`
  set `data_cpu` in an `initial` block above its declaration (xvlog
  VRFC 10-3380; Verilator accepts it). It now gets its 0 at the
  declaration, so `SIM=xsim` builds again (`sdcsx`).
- **The main loop's first pass reads the FPGA before the RTC** since Task
  11a (`PollDisks()` -> `HandleFpga()`, then `HandleRTC()`):
  `milestones_boot.txt` has the first HandleFpga frame before the RTC
  frame and 20 more after it.

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
| `rec` | events seen, record only: the value cannot violate its bound. `dmode_L` (the request always follows the ack), `rtc_cs_high` with the default bound 0 (a gap is never negative) and `ide_wait` (no margin to violate) |

`run.sh` fails a scenario unless all fourteen lines are there and none is
`LOW`. Each scenario also lists the lines that must have seen events
(`MARGIN_REQ_<scenario>` in `run.sh`); for those, `n/a` or `rec` fails it
too. A monitor that stops seeing its events therefore cannot pass in
silence:

| Scenario | Lines that must be `ok` | `n/a` there, and why |
|---|---|---|
| `boot` | 1, 4 (all four), 5, 14 | 3 (no direct transfer), 12 (one RTC transfer, no gap) |
| `boot_short` | 1, `userio_cs_release`, `userio_byte_spacing`, 5 | 3, 12, the paula lines (no paula frame before the cut); its `kick_order` is fpga_init's reset pulse, not a kickstart release, so it is not required |
| `keys` | as `boot` | as `boot` |
| `fdd_rd` | as `boot`, and 6 | 3 as `boot`; 7 (no write); 8, 9 (no IDE command); 12 is `rec` (3 RTC gaps, the shortest 558 ms) |
| `fdd_wr` | as `boot`, and 7 | 3, 12 as `boot`; 6 (no read); 8, 9 (no IDE command) |
| `hdd` | as `boot`, and 3 (`dmode_release`: the HDF sectors come in direct mode) | 6, 7, 12; 8 is `rec` (no bound), `l3check.py hdd` requires its per-command waits |
| `cd` | as `boot`, and 9; with `CDCFG=iso` also 3 (`dmode_release`: the ISO's sectors come in direct mode; a CUE's MODE1/2352 sectors go through the CPU) | 6, 7, 12; 3 with `CDCFG=cue`; 8 is `rec` |
| `cdda` | as `boot`, and 9 (every packet's command phase) | 3, 6, 7, 12; 8 is `rec` |
| `cdda_load` | as `cdda`, and 3 (the HDF sectors in direct mode) | 6, 7, 12; 8 is `rec` |

Item 6 (`fdd_fifo_empty_dma`) is `n/a` in every scenario without a floppy
read DMA, item 7 (`fdd_fifo_full_write`) in every scenario without a
floppy write DMA, item 8 (`ide_wait`) in every scenario without an IDE
command, item 9 (`cd_timeout_left`) in every scenario without an ATAPI
data phase. Lines printed before Task 13 (the measured outputs above)
have ten MARGIN lines, those of Task 13 eleven; item 6 came with
`fdd_rd`, item 7 with `fdd_wr`, item 8 with `hdd`, item 9 with `cd`.
The lane runs of Tasks 14 to 18 have twelve or thirteen (each lane's
items only), the runs of the merged bench (merge 2, `p4m2*`) fourteen.

Times are taken at the slave pins: an `sck` edge reaches the slaves
`+SCKDLY` ns after cfide's pin, `sd_cs` undelayed.

| Item | Name | What | Bound | `boot` (p4t5e) |
|---|---|---|---|---|
| 1 | `stale_acks` | hostmon's stale-ack count (an ack no `clk_28` edge saw the request for) | 0 | 0 of 1,685,611 hw accesses |
| 3 | `dmode_release` | a direct-mode transfer (`sd_cs[6]` low): its last (4096th) `sck` rising edge at paula to `direct_scs` released (`sd_cs[6]` rising), `clk_114` | 0 | n/a (`boot` has no direct transfer); 108.8 ok in the probe run below |
| 3 | `dmode_L` | the RDSPI ack (a DATA read acked while `sd_cs[6]` is low) to the DisableDMode request (CS write 41), `clk_114` | 0, `rec` | n/a; 6.0 rec in the probe run |
| 4 | `paula_cs_release`, `userio_cs_release` | per slave (`sd_cs[4]` paula, `sd_cs[5]` userio_osd): the last `sck` rising edge of a frame at the slave to its select rising, `clk_114` | 0 (derived below) | 10.8 over 41 frames; 10.8 over 72 frames |
| 4 | `paula_word_spacing`, `userio_byte_spacing` | the last edge of one received word (paula, 16 bits, `sd_cs[4]` or `[6]`) / byte (userio, 8) to the last edge of the next, `clk_114` | 40 (derived below) | 117.0 over 82 words; 57.0 over 129 bytes |
| 5 | `spi_write_busy` | SPI DATA writes acknowledged without starting a transfer of their own (no `SD_busy` rise from the request to the cycle after its ack): taken while the shifter was busy | 0 | 0 of 829,924 |
| 6 | `fdd_fifo_empty_dma` | floppy read DMA: Agnus disk slots with paula_floppy's `dmaon` = 1 and its FIFO empty, per track from the first slot at which the FIFO has reached the firmware's working level (1,024 words) to the track's last word (section "fdd_rd") | 0 | n/a (no floppy DMA) |
| 7 | `fdd_fifo_full_write` | floppy write DMA: Agnus disk slots offered to the write DMA (`dmaon` = 1, `DSKLEN` bit 14) at which paula_floppy's FIFO is full, so the slot goes unused (section "fdd_wr") | 0 | n/a (no floppy DMA) |
| 8 | `ide_wait` | IDE PIO flow control (`bfm_ide`): the time the 68k side spent waiting on the firmware, `clk_114`, only when it waited: an interrupt not yet pending, a BSY poll that saw BSY, a data read held by `nrdy`; per command min / median / max in the `=== IDE end` lines (section "hdd") | 0, `rec` (status-driven, no margin) | n/a (no IDE command) |
| 9 | `cd_timeout_left` | ATAPI phases on gayle's port 1 (IDE port 2): each window from the firmware's `CMD_IDE_XFER_WR` (`hdd_xfer_wr_p`, a phase set up) to `xfer_done` (the host is through), `clk_114`; `cdrom.c`'s `cd_wait()` polls inside it and gives up after `CD_TIMEOUT` = 10000 TIMER counts (1024 x `TICKDIV` `clk_114` each: 58 s at 643). The value is that timeout minus the longest window; an `(info) 9` line has the longest window, also in TIMER counts (section "cd") | 0; `ok` is required but cannot turn LOW: the longest window is four orders of magnitude under the timeout and `L3_CD_TO` ends the run first, so the line is `rec` in effect (the real teeth are `l3check.py cd`'s status, sense and window checks) | n/a (no ATAPI phase) |
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

`fw/ctrl/rtc.c` does not name its part. The board's RTC is the NXP
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
on a copy of a log. The "probe" firmware is `fw/ctrl` built with one
bench-only constructor linked in (`make -C fw/ctrl EXTRA_OBJS=probe.o`,
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
| 1 | run copy: `host_bridge.vhd`'s `-- 4PHASE` line becomes `state <= waiting;` and `rv_hostcpu.v` gets the fast master (both exactly as `sim/host_bridge/run.sh` `mutant`'s gate leg), `boot_short`, `TIMEOUT=10000000` | p4t5r1e | `stale_acks min 1184 count (bound 0, LOW)` | p4t5e: 0 |
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

## Stress grid

`grid.sh` runs a list of `run.sh` runs (Phase 4 Task 19: plan 7.2's
timing-stress mode), at most `MAXSIM` (6) simulations on the machine at once
and one Verilator build per build configuration. From the repository root,
after the "Run" setup:

```sh
LIST=1 bash sim/l3/grid.sh p4g
nohup bash sim/l3/grid.sh p4g > sim/l3/grid_p4g.out 2>&1 &
python3 -I sim/l3/margins.py sim/l3/run_p4g_*
```

The first line prints the run list only. The grid of Task 19 (60 runs,
the RV's 46 of the default list below and the retired 832's 14) took 19.2
hours on a 4-core, 8-thread machine (with Vivado builds and the teeth on
the same slots), so it runs in the background; do not edit
`grid.sh` or the bench while it runs (bash reads a running script as it
goes, and the bench files are build inputs); its runs are
`sim/l3/run_p4g_<name>`, each with `run.out` (run.sh's output), and
`sim/l3/grid_p4g.txt` lists every run with its verdict, wall time,
simulated seconds and cycles as it ends. Every run takes the same
firmware image. Without `FW`, `grid.sh` builds it from the tree at its
start, as `run.sh` does (`fw/ctrl` under the `L3_DATE` date shim), into
`sim/l3/run_<tag>_fw/fwrv`, and refuses to start if that directory
exists. To reuse an image, pass its path: `FW=<image> bash
sim/l3/grid.sh <tag>`. `grid_<tag>.txt` names the image, whether it was
built or given, and its sha256 (the Phase 4 tree built `RV32OSDA.BIN`
17bf2563..., the image of Task 19's `p4g`; Task 19's run directories are
named `run_p4g_<cpu>_<name>`, from before the CPU column was dropped).

The default list (`grid.sh` `default_list`):

| Phase | Grid point | Scenarios |
|---|---|---|
| 1 | default (`EXTRA_WS` 0, SCKDLY 1.5 / C28DLY 0.3, SLAT 8, SJIT 0) | `boot`, `keys`, `fdd_rd`, `fdd_wr`, `hdd`, `cd` (cue), `cd` (`CDCFG=iso`), `cdda`, `cdda_load`, `akiko` |
| 2 | `EXTRA_WS` 4, 16, 64 | `boot`, `fdd_rd`, `fdd_wr`, `hdd`, `cdda` |
| 2 | skew (0.5, 0.2), (0.2, 0.5), (4.0, 0.3), (0.3, 4.0), (9.5, 0.3) (`XARGS="+SCKDLY=<a> +C28DLY=<b>"`) | `fdd_rd`, `hdd`, `keys` |
| 2 | `+FAST_HW=1` | `boot`, `hdd`, `cd`, `keys` |
| 2 | `SJIT=8` | `hdd`, `cdda` |

A phase-2 run starts when every phase-1 run has started. `EXTRA_WS` n
(and `SJIT` 8) runs get `TIMEOUT` = run.sh's default plus n (8) x the
scenario's bus accesses at `EXTRA_WS` 0 (`grid.sh`'s comment): the time if
every access waited n cycles longer.

Slots: a run starts only while fewer than `MAXSIM` simulations run on the
machine (every `sim/l3/run.sh` of any lane, a build included, and every
other `Vtb*`); while Vivado runs the cap is `VIVADO_CAP` (2) and the grid's
own simulators beyond it are stopped (`SIGSTOP`) until Vivado ends.
Builds: the first run of a configuration (`EXTRA_WS`, `XRAND`,
`PATCH`, `RDY_MUT`, `PAULA_TXPOP`) builds; the others start when its
`buildkey_<snapshot>` is there and run with `BUILD_FROM=<its RUNTAG>`, which
copies its simulator when the build keys (a sha256 of every build input)
are equal and builds otherwise. So a bench file edited while a grid runs
gives the later runs their own build (and their `results.txt` says so):
do not edit the bench under a running grid. A list file
(`bash sim/l3/grid.sh <tag> <list>`) has one run per line,
`<phase> <name> <scenario> [VAR=value ...]` (`sim/l3/teeth/teeth.list`
is one); its runs are `run_<tag>_<name>`.

`margins.py <run dirs>` prints the margin table: one row per measurement
of plan 7.1 (the `=== MARGIN` lines, `OSD GAP` / `OSD EARLY` for item 2,
the floppy FIFO's lowest fill and the write FIFO's word gap, the CD-DA
underruns and longest fill, the Akiko request latency, the `keys` check),
one column per grid point, each cell the worst value over that
point's runs with its verdict and scenario; `--long` adds one line per run
and measurement. A run that has no verdict yet or ended at its `TIMEOUT`
is listed as incomplete and left out.

### Teeth (Task 19)

Each must fail. `PATCH=<script>` (run.sh) edits the run copies of the RTL;
`teeth/fwmut.sh <dir> <file> <sed>` builds a firmware run copy with one
changed line (with an empty sed it reproduces the tree's image):

```sh
bash sim/l3/teeth/fwmut.sh sim/l3/run_p4t19fwc fdd.c '0,/i = DATA_SIZE \/ 2;/s//i = DATA_SIZE \/ 2 - 1;/'
bash sim/l3/teeth/fwmut.sh sim/l3/run_p4t19fwf cdaudio.c 's/^\tcda\.cursor += CDA_HALF_FRAMES;$/\tcda.cursor += CDA_HALF_FRAMES - 1;/'
nohup bash sim/l3/grid.sh p4t19 sim/l3/teeth/teeth.list > sim/l3/grid_p4t19.out 2>&1 &
```

| Tooth | How | Must fail on |
|---|---|---|
| (a) | `teeth/paula_202e077.sh`: 202e077 reverted in `paula_floppy.v` | `hdd` (direct-mode reads): data check or item 3 |
| (b) | `teeth/bridge_2phase.sh`: the bridge without the four-phase handshake plus the fast master (`sim/host_bridge/run.sh mutant`'s gate leg), `boot_short`, `TIMEOUT=10000000` | item 1 `stale_acks` |
| (c) | `fwmut.sh` on `fdd.c`: `SendSector` one word short | `fdd_rd` data check |
| (d) | `RDY_MUT=1` (cfide's `osd_rdy` forced 1), `+FAST_HW=1` (Task 12's run `p4t12m1c`, section "keys") | `OSD EARLY` |
| (e) | `teeth/gayle_shared.sh`: `GAYLE_MUT_SHARED` in `gayle.v` | `cdda_load` (`hdd` uses gayle port 0 only, both units on it, so the shared register file does not show there: the brief's `hdd` run passes) |
| (f) | `fwmut.sh` on `cdaudio.c`: the cursor one frame short per half | `cdda` data check |
| (h) | the RV image before the write-FIFO fix (`run_fw12/fwrv/RV32OSDA.BIN`, 0162e53f) | `fdd_wr`: item 7's word-gap monitor |

The results are in `findings/osd-riscv/phase4.md` "Teeth" (with tooth
(g), an SD data byte changed in a trace, which tested the RV-vs-832
differential and went with it).

## Cards

`sim/l3/card` builds the SD card images the L3 scenarios boot, and
`sim/l3/gen` holds the generators of everything on them. Nothing on a card is
copyrighted: the kickstart is a synthetic 256 KB file, the drive sounds file
is the project's own (`sw/mkdrivesounds/drivesnd.bin`). Images are built,
never committed; `sim/l3/card/manifest.txt` lists name, size and sha256 of
every generated file and image, so a generator change shows in review.

Setup on a fresh Ubuntu 24.04, bash or zsh, from the repository root:

```sh
sudo apt install build-essential make git curl python3 mtools dosfstools fdisk xorriso ghdl verilator ccache iverilog
bash tools/riscv/fetch-xpack.sh
bash tools/riscv/check-toolchain.sh
make -C fw/ctrl
```

The cards need `fw/ctrl/build/RV32OSDB.BIN` (the last line).

Build the cards and run the proof (one minute; output in
`sim/l3/card/build/`, `B=<dir>` puts it elsewhere):

```sh
make -C sim/l3/card cards FWRV=fw/ctrl/build/RV32OSDB.BIN
make -C sim/l3/card check FWRV=fw/ctrl/build/RV32OSDB.BIN
```

`check` builds every card twice, two seconds apart, in two directories and
compares the bytes; runs `fsck.fat -n` on each image; lists each root
directory with `mdir` against the names the card should hold; reads the config
files back from the images and compares `cfgconv --check` with the field
table `gen/mkcfg.py` was given; prints the CHS of `SYNTH.HDF` and requires
more than 255 cylinders; and compares `manifest.txt` with a fresh build
with a stand-in `RV32OSDB.BIN` (`gen/mkblob.py`, so the manifest does not
change with a firmware build; its content seed is still `STANDIN-RV32OSDA`,
so its line kept its size and sha256 when Task 13b renamed the file, and the
card images differ from the earlier ones only in that directory entry). It ends with `check PASS`. The bytes of `TEST.ISO` depend on the xorriso version (the committed manifest was made with 1.5.6): on another version `check` can fail with "manifest.txt is stale", and `make -C sim/l3/card manifest` regenerates it. After a change to a generator,
`make -C sim/l3/card manifest` rewrites `manifest.txt`.

One card, with another firmware image: put it in its own `B=` directory
(`make` does not rebuild an image whose name has not changed):

```sh
make -C sim/l3/card hdd B=build_real FWRV=path/to/RV32OSDB.BIN
mdir -i sim/l3/card/build_real/hdd.img@@1048576 ::
```

| Card | Files (all cards also hold the firmware as `RV32OSDB.BIN`, the name of `fw/ctrl/fwname.mk`, and `KICK.ROM`) |
|---|---|
| `boot` | `MINMGAR.CFG` (RISC-V, little-endian), `MINMGAA.CFG` (the previous firmware's, big-endian: the RV firmware loads `MINMGAR.CFG` and converts `MINMGAA.CFG` only when that is missing) |
| `bootbecfg` | only `MINMGAA.CFG`: the RISC-V first-boot conversion path (no scenario boots it yet) |
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
| `TEST.ADF` | `mkadf.py` | 901,120 bytes; sector s (LBA) tagged `L` `B` s>>8 s&0xff, then the pattern of `fw/ctrl/test/gold/mfm.py` |
| `SYNTH.HDF` | `mkhdf.py` | 4 MB, no RDB (the firmware synthesises one); CHS 257.1.32 (`mkhdf.py --chs SYNTH.HDF`); block n tagged `H` 2 n>>8 n&0xff |
| `RDB.HDF` | `mkhdf.py` | 2 MB, own RDSK at block 0 with `rdb_Flags` 0x17 (not 0x12) and a PART at block 1; other blocks tagged `H` 1 n>>8 n&0xff |
| `TEST.ISO` | `mkiso.sh` | one file `DATA.BIN`, 256 KB, block n of 2048 bytes tagged `L` `B` n>>8 n&0xff |
| `TEST.BIN`, `TEST.CUE` | `mkcue.py` | 364 raw sectors: 64 MODE1/2352 data, then two AUDIO tracks of 2 s; track 2 has the 2 s PREGAP; audio frame f (from track 2) is left `f & 0xFFFF`, right `~f & 0xFFFF` |
| `MINMGAA.CFG`, `MINMGAR.CFG` | `mkcfg.py`, `cfgconv --to-rv` | 212 bytes: kickstart `KICK`, IDE on, one floppy at normal speed, hardfile 0 = `RDB` (plain file, own RDB: unit 0, so the firmware patches its `rdb_Flags`), hardfile 1 = `SYNTH` (synthesised RDB), IDE port 2 master = CD with `TEST` (CUE or ISO), the rest the defaults of `fw/ctrl/test/gold/mkcfgbe.py` |

Disc map of `TEST.CUE`: LBA 0..63 data, 64..213 silent pregap of track 2,
214..363 track 2, 364..513 track 3, lead-out 514.

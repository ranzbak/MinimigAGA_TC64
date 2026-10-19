# OSD host CPU migration, Phase 4 findings

## Measurements

### Task 1: failure edge of the real `userio_osd` reply (E_osd)

Bench `sim/spi_cdc/tb_spi_cdc.v` (xsim 2023.2, RTL of the tree at the time of the run, `git status rtl` clean), `osd` test only.
Reference first: `RUNTAG=p4t1ref bash sim/spi_cdc/run.sh` gave `=== PASS` in all seven (SCKDLY, C28DLY) pairs of the default grid (wall 2 min 24 s; the osd failures it prints are below OSD_MIN_GAP=40 and not counted).
Sweep: `RUNTAG=p4t1 XARGS="+SWEEP=1 +TESTS=8 +OSD_MIN_GAP=0 +REPS=10" bash sim/spi_cdc/run.sh` (wall 48 s, seed 1). Every even gap 2..80, 10 repetitions each, every failure counted. Each pair ends `=== FAIL` as expected with OSD_MIN_GAP=0.
`+GAP` adds a random 0..3 `clk_114` cycles per access (`jitter = $urandom % 4`), so the gap value in the table is the minimum; the real gap is gap..gap+3 and the edge is a band.

Failures out of 10 by gap (`clk_114` cycles; 2..22 fail 10/10 in all pairs, 34..80 fail 0/10 in all pairs):

| SCKDLY / C28DLY (ns) | 24 | 26 | 28 | 30 | 32 | 34 | largest failing gap | smallest gap, all larger pass |
|---|---|---|---|---|---|---|---|---|
| 0.5 / 0.2 | 9 | 9 | 10 | 5 | 2 | 0 | 32 | 34 |
| 0.2 / 0.5 | 9 | 9 | 10 | 5 | 2 | 0 | 32 | 34 |
| 1.5 / 0.3 | 9 | 9 | 8 | 4 | 1 | 0 | 32 | 34 |
| 4.0 / 0.3 | 9 | 9 | 8 | 4 | 1 | 0 | 32 | 34 |
| 0.3 / 4.0 | 9 | 9 | 7 | 0 | 0 | 0 | 28 | 30 |
| 8.0 / 0.3 | 9 | 9 | 8 | 4 | 1 | 0 | 32 | 34 |
| 9.5 / 0.3 | 9 | 9 | 8 | 7 | 3 | 0 | 32 | 34 |

**E_osd = 34** (smallest `+GAP` at which `osd` passes 10/10 in every pair, and at every larger gap up to 80). With the 0..3 jitter that is an effective gap of 34..37 cycles; in the pair 0.3 / 4.0 alone the edge is 30.
**Band:** the transition is gradual, not a cliff: failures are 10/10 up to gap 22, 7..10/10 at 24..28, and fall to 0..7/10 at 30 and 0..3/10 at 32. Treat gaps below 34 as unsafe, and 34..37 as the first fully passing band (no failure in 10 reps x 7 pairs at any gap >= 34, so the margin to the firmware's 40 is 3..6 cycles plus jitter).
Consistent with commit 1e135e7 (stale replies below ~32): the largest failing gap is 32, no failure at any gap >= 34 and none at >= 40, so the 40-cycle reply gap of the RV firmware measured in L2 (Phase 3) sits 6 cycles above E_osd. One seed only; a lower tail below 34 at other seeds is not excluded (default grid, REPS=3, saw 1/3 failures at gap 32 in three pairs, same as here).

### Task 4: L3 boot of the RV firmware against the real `userio_osd` (OSD EARLY, version reply)

Bench `sim/l3` (Verilator 5.020, SLAT=8 SJIT=0, SCKDLY 1.5 / C28DLY 0.3, TICKDIV 1), boot card with KICK.ROM, the RV firmware of the tree built under the date shim (92,732 bytes, sha256 fd3b3c6a0b8ca273).

| Quantity | `boot` (main loop + 20 passes) | `NOKICK=1` (fatal-error loop to the cycle limit) |
|---|---|---|
| `OSD_CMD_VERSION` reply | `20 88 ff ff ff ff ff ff / 00 01 1a 0a 02 a4 fd`: correct (minimig_version.vh 1 / 26 / 10 / 2, magic a4, caps 0xFD) | the same |
| `OSD EARLY` | **0 of 26** reply bytes | 0 of 1532 |
| `OSD GAP` min | 44 over 26 bytes (the version frame, reply byte 2) | 40 over 1532 bytes (KEYQ, reply byte 0) |
| `STACK low` | 0x1950 (1712 bytes) | 0x1950 (1712 bytes) |

No "before" finding: no reply byte was loaded before the previous byte was through userio_osd's synchroniser, and the version reply is right, so the plan order stays (Tasks 9-11 after Task 5). The gap of 40 in the error loop is the SPI_reply() SPIN floor (L2 measured the same 40); E_osd = 34 (Task 1), so the margin is 6 cycles there.
STACK low with the first kickstart card equals the Phase 3 figure (0x1950, 1712 bytes): the kickstart path does not go deeper.
Cycles: jump to 0x2000 at 43,190,675; the first HandleFpga frame (main loop) at 158,044,038; the 20th after it at 158,155,012.

### Task 5: margin monitors on the L3 boot (plan 7.1 items 1, 3, 4, 5, 12, 14)

`sim/l3` `boot`, RV, Verilator, SLAT=8 SJIT=0, SCKDLY 1.5 / C28DLY 0.3, TICKDIV 1, gate pair `p4t5b` / `p4t5b_xr` (SAME). Method, bounds and red cases: `sim/l3/README.md` "Monitors".

| Item | Measured (min) | Bound | Note |
|---|---|---|---|
| 1 stale acks | 0 of 1,685,611 hw accesses | 0 | red: L2 mutant bridge + fast master, 1,184 |
| 3 direct mode, last sck edge -> `direct_scs` release | none in `boot`; 108.8 `clk_114` (probe firmware, one `MMC_Read(0, 0)`) | 0 | RDSPI ack -> DisableDMode request (`L`) 6 `clk_114` |
| 4 last sck edge -> select rise | paula 10.8, userio 10.8 `clk_114` | 0 (corrected from 32: no state the last byte needs is cleared by the select) | byte / word spacing 57.0 / 117.0 against the synchroniser's 40 |
| 5 SPI DATA write taken while busy | 0 of 829,924 | 0 | the boot ROM's back-to-back writes are held, not taken |
| 12 RTC CS high | one transfer in `boot`; 363,982,789 ns between the first two (`+BOOT_END=rtc2`, SLAT 4) | datasheet not found (0) | 8,192 main-loop passes |
| 14 last kickstart write -> CPU release | 6,829,787 `clk_114` (write 150,139,042, release 156,968,829) | 1 | `l3check.py order` PASS |

The firmware's `MMC_Init` sends the same 9 card commands as `fw/ctrl_rv/test`'s mmc_test golden (`l3check.py mmc` PASS). The RTC frame is `80 92 ff ff ff ff ff ff ff / ff 00 00 00 01 04 01 26` at SLAT 8 and SLAT 4 (the model's fixed time).

## Shared defects

(none yet)

## Findings for Paul (RTL outside Phase 4 scope)

Found by the X-sensitivity twin of Task 2 (`XRAND=1`, sim/host_bridge, 2026-10-18); not fixed, rtl/ is untouched.

**Five flops have no reset and rely on the FPGA's power-up 0.**

| signal | file | where it is written |
|---|---|---|
| `cache_req` | `rtl/host/832_bridge.vhd` (decl. line 62) | lines 359, 373; the reset branch (335-337) sets only `state`, `hw_req`, `wr` |
| `cpu_ack` | `rtl/host/832_bridge.vhd` (55) | lines 341, 368, 376, 386 |
| `rom_wr` | `rtl/host/832_bridge.vhd` (73) | lines 342, 353, 367 |
| `sdram_req` | `rtl/host/hostcache.v` (output reg, line 18) | lines 144, 158, 173, 193; the `!reset_n` branch (line 244) sets only `zstate`, `zreadword_burst` |
| `ack` | `rtl/host/hostcache.v` (line 16) | `ack <= #1 1'b0` default and the states that set it |

**Failure under random init** (`--x-initial unique`, `+verilator+rand+reset+2`): if `cache_req` or `sdram_req` starts at 1, the SDRAM model sees a request with a garbage address from cycle 0 (`BUS VIOLATION sdram model: request outside 0..0x7FFFFF`), the request never drops (the states that clear it are not reached), and the host CPU never boots (boot: no `ErrorCode`, `=== FAIL timeout`; fwboot: 4300 bench errors). About half of the seeds fail; `ack`/`cpu_ack`/`rom_wr` at 1 give the same class of false accesses.

**Why the board is fine at power-up:** FPGA configuration initialises every flop to 0 (no INIT attribute is needed), so the flops start at 0 exactly as the 2-state simulations assume.

**Warm-`nReset` risk:** `nReset` is also an in-system reset. Asserting it while a cache fill or a write is in flight resets `zstate` / `state` but leaves `sdram_req` / `cache_req` at 1; the SDRAM controller's ack then arrives with no state machine waiting, and the request stays high. Not reproduced on the board; the bench cannot show it either (it asserts reset only at time 0).

**Minimal fix (a decision for Paul):** clear `cache_req`, `cpu_ack`, `rom_wr` in the `nReset='0'` branch of `832_bridge.vhd` (and give them `:= '0'` initial values), and clear `sdram_req`, `ack` in hostcache's `!reset_n` branch. Four to six lines, behaviour after the first reset unchanged.

**Which builds:** `832_bridge.vhd` and `hostcache.v` are in the 832 build too: `rtl/soc/minimig_virtual_top.v` instantiates `EightThirtyTwo_Bridge` (generic `cpu_riscv` selects the CPU) for both firmwares, and `hostcache` sits behind the bridge for either CPU. An RTL change is therefore a change to the 832 bitstream (reference `build/stage_spicdc_49b1868`).

**Bench handling:** `XRAND=1` pins exactly these five flops to 0 at time 0 (declaration initialisers in the run copy of `hostcache.v` and in the GHDL-converted bridge, `hs_pin_hostcache`, `hs_pin_bridge` in `sim/common/hostsim.sh`), prints `=== XRAND pinned 5 regs`, and randomises everything else. The pin models the FPGA configuration; remove it when the RTL resets them.

### Found by the L3 bench (Task 4, 2026-10-19)

**`rtl/minimig/paula_floppy.v` `dsktrack[3:0]` (line 137) has no reset and no initial value.** It is the four drives' head positions; `track = {dsktrack[sel], ~side}` is byte 1 of every HandleFpga reply. Under random init (`XRAND=1`, sim/l3 run `p4t4_xr`, seed 872887896) the first L3 XRAND twin differed from the normal run in every HandleFpga frame: `10 00 00 00 00 00 00 / 10 b9 44 89 00 00` instead of `/ 10 01 44 89 00 00` (track 0x5c instead of 0), and the firmware's following `10 10 00` frame echoed it. The board starts it at 0 (configuration), and keeping it across a chipset reset is what a real drive does (the heads do not move on reset), so this is not a board defect; it only means the RTL relies on the FPGA's power-up 0 for the track an Amiga reads before its first seek. Minimal fix if wanted: `initial` values of 0 (or a reset at power-up). Bench handling: `XRAND=1` in sim/l3 pins the four elements to 0 at time 0 in the run copy (`run.sh l3_pin_minimig`, `=== XRAND pinned 9 regs` = the five above + four); with the pin the twin is SAME (`p4t4f` / `p4t4f_xr`, and the gate pair `p4t4g` / `p4t4g_xr`).

### Found while modelling the RTC (Task 5, 2026-10-19)

**On the board the firmware's RTC read reaches no chip.** `rtl/soc/minimig_openaars_top.v` leaves `minimig_virtual_top`'s `RTC_CS` (= `SPI_CS[7]`, line 1122 there) unconnected (`.RTC_CS()`, line 652); the PCF2123 sits on its own pins and is read by `rtl/openaars/pcf2123/rtc_spi_clock.sv` (the OKI MSM6242 bridge in `minimig.v`). `HandleRTC()` (`rtc.c`, identical in `fw/ctrl_832` and `fw/ctrl_rv`) still selects `sd_cs[7]` every 8,192 main-loop passes. With that select low, cfide samples `sd_dimm`, the SD card's MISO, while the card is deselected, and writes what it reads into its RTC registers (`HW_RTC`). Both firmwares do this, so it is not a parity item; L3 models a PCF2123 on `sd_cs[7]` so that the frame is checked. `rtc.c`'s comment "start reading at register 0000" does not match the command 0x92, which selects register 2 (Seconds); the code reads registers 2..8, which is right, so only the comment is wrong.

**`rtl/minimig/gayle_port.v` line 139 uses the wire `err` before its declaration (line 143).** xvlog refuses it (VRFC 10-3380) unless `--relax` is given; Vivado synthesis and Verilator accept it. sim/l3 compiles the slaves with `xvlog --relax`. Cosmetic; moving the declaration up would make the file plain Verilog-2001.


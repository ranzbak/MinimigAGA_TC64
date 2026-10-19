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

`sim/l3` `boot`, RV, Verilator, SLAT=8 SJIT=0, SCKDLY 1.5 / C28DLY 0.3, TICKDIV 1, gate pair `p4t5e` / `p4t5e_xr` (SAME; review round 1: the verdicts ok / LOW / n/a / rec and the async-reset pins, same figures as the first gate `p4t5b`). Method, bounds and red cases: `sim/l3/README.md` "Monitors".

| Item | Measured (min) | Bound | Note |
|---|---|---|---|
| 1 stale acks | 0 of 1,685,611 hw accesses | 0 | red: L2 mutant bridge + fast master, 1,184 |
| 3 direct mode, last sck edge -> `direct_scs` release | n/a in `boot`; 108.8 `clk_114` (probe firmware, one `MMC_Read(0, 0)`) | 0 | RDSPI ack -> DisableDMode request (`L`) 6 `clk_114` |
| 4 last sck edge -> select rise | paula 10.8, userio 10.8 `clk_114` | 0 (corrected from 32: no state the last byte needs is cleared by the select) | byte / word spacing 57.0 / 117.0 against the synchroniser's 40 |
| 5 SPI DATA write taken while busy | 0 of 829,924 | 0 | the boot ROM's back-to-back writes are held, not taken |
| 12 RTC CS high | one transfer in `boot` (n/a); 363,982,789 ns between the first two (`+BOOT_END=rtc2`, SLAT 4, rec) | datasheet not found (0) | 8,192 main-loop passes |
| 14 last kickstart write -> CPU release | 6,829,787 `clk_114` (write 150,139,042, release 156,968,829) | 1 | `l3check.py order` PASS |

The firmware's `MMC_Init` sends the same 9 card commands as `fw/ctrl_rv/test`'s mmc_test golden (`l3check.py mmc` PASS). The RTC frame is `80 92 ff ff ff ff ff ff ff / ff 00 00 00 01 04 01 26` at SLAT 8 and SLAT 4 (the model's fixed time).

### Task 6: the 832 in L3 (`CPU=832`)

`sim/l3` with the EightThirtyTwo, `fw/ctrl_boot_832` and `832OSDAD.BIN` built from a copy of the unchanged `fw/ctrl_832` (`sim/l3/fw832`, two builds byte-identical, sha256 768c765d57deb1a0, 107,479 bytes). Verilator, SLAT=8 SJIT=0, TICKDIV 1; gate pair `p4t6` / `p4t6_xr` SAME, `boot_short` `p4t6s` (Verilator) / `p4t6x` (xsim). Details: `sim/l3/README.md` "832".

| Event | 832 | RV (Task 4) | 832 / RV |
|---|---|---|---|
| jump to 0x2000 | 54,832,554 | 43,190,675 | 1.270 |
| `boot_short` end | 74,525,542 | 57,659,090 | 1.293 |
| main loop (first HandleFpga frame) | 202,610,912 | 158,044,038 | 1.282 |

`OSD EARLY 0 of 26`, `OSD GAP min 254` (RV 44): the 832's four `SPIN`s per reply byte keep it far behind the synchroniser. kick, order and mmc PASS: the 832's `MMC_Init` sends the same 9 card commands as the RV's golden. All MARGIN lines ok (release 3.8 `clk_114` at both slaves, byte spacing 49.0 against the 40 bound; the RV 10.8 / 57.0).

Speed: Verilator 0.29 M `clk_114` cycles/s (`boot_short`), 0.106 M/s with seven simulations on the machine (`boot` 1,918 s); xsim 33 k cycles/s (`boot_short` 2,282 s, `X 0`, SAME against `p4t6s`). xsim used by the task: about 45 min (that run, two builds and two runs of under 20 k / 200 k cycles that found the register-file X).

Tool finding (not RTL): **GHDL 4.1 `--synth` mis-converts `eightthirtytwo_cpu.vhd`.** In the main process (async reset), the `thread` record has some fields reset (`pc`, `setpc`, `d_ex_op`, the hazard flags, `pause`) and some not (`d_imm`, `d_reg`, `d_alu_op`, `d_alu_reg1`, `d_alu_reg2`, `d_read_tmp`, `d_read_reg`); GHDL then emits no flops for any field from `d_imm` on (the clock edge becomes `1'b0`, each field a mux of its own value), so the decoded op never reaches the ALU and the CPU runs straight through its boot ROM (Verilator and iverilog agree on the netlist; GHDL's own simulation of the VHDL agrees with xsim). Found by a bus-trace comparison with xsim (first 20 k cycles). The bench's conversion copy resets those seven fields too (`hs_ghdl_convert`); with it the bus trace equals xsim's and the xsim `boot_short` is SAME. Also: the instance label `alu` collides with GHDL's net names (`alu_q1` ...), renamed in the copy. Nothing to change in the RTL: Vivado builds the board's 832.

Bench notes: the 832 boot ROM's RAM (`OSDBoot_832_ROM.vhd`) is a `signal` with two writing processes, which simulates as two drivers (writes read back X) and which GHDL refuses; the run copy uses the RV ROM's shared-variable form (`hs_rom832`). The 832's register file data registers have no reset and the boot ROM's first prologue stores them: xsim pins them to 0 (the FPGA's start value; the XRAND twin, which randomises them, is SAME). Two hostmon monitors assumed the RV's access pattern (UART at 0xFFFFFFF0 only; the command byte's read-back in OSD reply frames, which vbcc drops) and now decode as cfide does; L2 `boot` / `fwboot` and the RV L3 `boot` are unchanged by it (SAME / only the new `=== CPU rv` line).

### Task 7: the differential, `boot` RV vs 832

Runs `p4t7r2` (RV, 699 s) and `p4t7c2` (832, 990 s), Verilator, side by side, both cards byte-identical (`FW` = RV32OSDA.BIN sha256 fd3b3c6a0b8ca273, `FW832` = 832OSDAD.BIN 768c765d57deb1a0, built once). `bash sim/l3/run.sh diff --unused-rules p4t7r2 p4t7c2` with the first 7 rules (firmware file, config file, `fmt_diff_expected.txt` line 275) left two differences outside exec-3's list; by the controller's ruling they got rules 8 and 9, and the diff is now empty with `rules: all 9 used`:

1. **The 832's spurious "Overriding screenmode." pass** (a `DROPBLOCK` from that UART line to the following `##End result : 0`): an 832-only firmware defect, "Findings for Paul" below.
2. **`HW ffff34 0000`, RV only (twice):** `SetIntHandler()` (`fw/ctrl_rv/arch/irq.c:22`) writes the RV interrupt controller's `IRQ_MASK` (cfide 0xFFFFFF34, exec-1's memory map 0xFFFFFF3x) to 0 for a legacy handler; the 832 has no such register. Structural, not a parity defect: `DROP hw ^ffff34\x20`.

Bench fixes found by the first pair (`p4t7r` / `p4t7c`): a byte write's value16 differed by the bridge's lanes (the RV puts the byte on all four lanes, `efef`; the 832 on one, `00ef`); hw.txt now logs a one-lane write as `00` and its byte (cfide's byte registers take d(7 downto 0)). The second pair's `spi.txt` and logs are SAME as the first's (`run.sh compare p4t7r p4t7r2`, `p4t7c p4t7c2`).

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

### Found by the L3 differential (Task 7, 2026-10-19)

**The 832 firmware takes ColdBoot's "Overriding screenmode." path on every cold boot, with no key held (an 832-only firmware defect; not fixed: `fw/ctrl_832` is read-only).**

- **What the bench shows** (`boot`, run `p4t7c2` against the RV's `p4t7r2`, the same card): `OsdGetKeyLevel()` reads level 00 (`20 00 / 00`), yet the 832 prints `Overriding screenmode.` and runs `ApplyConfiguration(0,0)` a second time: the config frames `20 14 .. 20 64`, the VIDEOSCALE, I2C (ADV7511) and PLATFORM writes, `##End result : 0`. The RV does neither (right per the source: `override` stays 0 when the key is none of F1..F4).
- **Probe** (run `p4t7probe`: a scratch copy of the 832 sources with two `printf`s in `main.c` ColdBoot, not committed): `L3PROBE1 key=0 override=0` right after the key read, `L3PROBE2 key=0 override=6F6E2036` just before `if(override)`. Between them only `sprintf(s,"Got key: %x\n",key)` and the empty `BootPrint(s)` run; `override` then holds four ASCII bytes ("on 6"). In the unprobed build vbcc832 keeps `override` in the callee-saved r4 from before `ChangeDirectory` to the test (vbcc832 `-O=1343` asm of `main.c`). Suspect: lib832's `sprintf` (or vbcc832 code around the call) not preserving the caller's state; the root cause was not pinned further.
- **Board effect:** on every cold boot one extra configuration pass with the values just applied (chipset, CPU, memory, floppy, video frames to userio_osd; VIDEOSCALE; the ADV7511 I2C writes; PLATFORM) and the line "Overriding screenmode." on the boot screen. The four F-key bodies did not run (no key matched), so `config` is unchanged: the resent frames equal the first pass. The corrupted value reaches nothing else in ColdBoot (`override` is only tested once); a different corruption elsewhere in the 832 build by the same `sprintf` would not show in this test.
- **Bench handling:** `sim/l3/expected_diff.txt` rule `DROPBLOCK uart ^Overriding\x20screenmode\.$ ^##End\x20result\x20:\x200$` (comment names this entry and the probe).

### Found by the L3 bench (Task 4, 2026-10-19)

**`rtl/minimig/paula_floppy.v` `dsktrack[3:0]` (line 137) has no reset and no initial value.** It is the four drives' head positions; `track = {dsktrack[sel], ~side}` is byte 1 of every HandleFpga reply. Under random init (`XRAND=1`, sim/l3 run `p4t4_xr`, seed 872887896) the first L3 XRAND twin differed from the normal run in every HandleFpga frame: `10 00 00 00 00 00 00 / 10 b9 44 89 00 00` instead of `/ 10 01 44 89 00 00` (track 0x5c instead of 0), and the firmware's following `10 10 00` frame echoed it. The board starts it at 0 (configuration), and keeping it across a chipset reset is what a real drive does (the heads do not move on reset), so this is not a board defect; it only means the RTL relies on the FPGA's power-up 0 for the track an Amiga reads before its first seek. Minimal fix if wanted: `initial` values of 0 (or a reset at power-up). Bench handling: `XRAND=1` in sim/l3 pins the four elements to 0 at time 0 in the run copy (`run.sh l3_pin_minimig`, `=== XRAND pinned 9 regs` = the five above + four); with the pin the twin is SAME (`p4t4f` / `p4t4f_xr`, and the gate pair `p4t4g` / `p4t4g_xr`).

### Found while modelling the RTC (Task 5, 2026-10-19)

**`userio_osd_spi.v` `bit_cnt` / `first_byte` at time 0: a simulation-model artefact, not a board risk (corrected in Task 5's review round 1).**

- **What the twin showed.** Twin `p4t5c_xr` (seed 820757315) answered the boot's first OSD frame (the boot ROM's `20 08 06`, cycle 1948) with `a8 00` instead of `00 00`. Nothing after that frame differed.
- **The RTL.** Both registers are written in `always @(posedge sck or posedge _scs) if (_scs) ...`. paula_floppy.v's `spi_bit_cnt`, `spi_tx_cnt` (`negedge scs`) and `spi_rx_cnt_rst` (`negedge scs1`) are written the same way.
- **Why the board is fine.** Synthesis makes these level-sensitive asynchronous preset / clear flops (FDPE / FDCE). `_scs` is a direct wire from cfide, and `sd_cs = NOT scs` is 1 from configuration on: cfide's reset clears `scs`. So on the board, from the start, `bit_cnt` is held at 0, `first_byte` at 1, `spi_bit_cnt` / `spi_tx_cnt` at 0 and `spi_rx_cnt_rst` at 1. They do not depend on power-up values, and the boot's first OSD frame is decoded normally.
- **Why simulation differed.** A Verilog simulator applies such a set / clear only on an edge of the select.
  - xsim sees X -> 1 at time 0 as an edge, so it gives the board's values.
  - Verilator's two-state build does not. Probed with a run copy, p4t5t0: `first_byte` 0 at 50 ns, and the first frame's command byte was taken as data (its write was the reset value anyway, so nothing visible followed).
  - Under `XRAND` the registers start random.
- **Bench handling.** `sim/l3/run.sh l3_pin_async`, in every run for both simulators, initialises the five registers to the held state in the run copies. Probe p4t5t0b then shows `first_byte` 1 and command `08` decoded in the first frame; the twins are SAME (sim/l3 README, "boot"). The earlier entry here said the board relied on power-up 0 and might drop that frame: that was wrong. No RTL change is suggested.

**On the board the firmware's RTC read reaches no chip.** `rtl/soc/minimig_openaars_top.v` leaves `minimig_virtual_top`'s `RTC_CS` (= `SPI_CS[7]`, line 1122 there) unconnected (`.RTC_CS()`, line 652); the PCF2123 sits on its own pins and is read by `rtl/openaars/pcf2123/rtc_spi_clock.sv` (the OKI MSM6242 bridge in `minimig.v`). `HandleRTC()` (`rtc.c`, identical in `fw/ctrl_832` and `fw/ctrl_rv`) still selects `sd_cs[7]` every 8,192 main-loop passes. With that select low, cfide samples `sd_dimm`, the SD card's MISO, while the card is deselected, and writes what it reads into its RTC registers (`HW_RTC`). Both firmwares do this, so it is not a parity item; L3 models a PCF2123 on `sd_cs[7]` so that the frame is checked. `rtc.c`'s comment "start reading at register 0000" does not match the command 0x92, which selects register 2 (Seconds); the code reads registers 2..8, which is right, so only the comment is wrong.

**`rtl/minimig/gayle_port.v` line 139 uses the wire `err` before its declaration (line 143).** xvlog refuses it (VRFC 10-3380) unless `--relax` is given; Vivado synthesis and Verilator accept it. sim/l3 compiles the slaves with `xvlog --relax`. Cosmetic; moving the declaration up would make the file plain Verilog-2001.


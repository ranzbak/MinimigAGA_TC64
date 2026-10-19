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

### Task 8: OSD keys (`keys`), the "before" OSD reply table

`sim/l3` scenario `keys` (README "keys"): the boot card, from the main-loop milestone the key script `sim/l3/keys/menu_tour.txt` (open the OSD, walk the main page down and up, the Floppy and the Harddisks page in and out, one `BURST` of six events, close) at TICKDIV 643; Verilator, SLAT=8 SJIT=0, SCKDLY 1.5 / C28DLY 0.3. Both legs on the same card (`FW` RV32OSDA.BIN sha256 fd3b3c6a0b8ca273, `FW832` 832OSDAD.BIN 768c765d57deb1a0). RV: `p4t8` / `p4t8_xr` with `+OSD_EARLY_OK=1` (the RV keeps its `SPIN`s until Task 11); 832: `p4t8c` / `p4t8c_xr`.

"Before" table (the reply-ready handshake, Tasks 9-12, is compared against it). Per command and reply byte (0 = the first byte after the command): `OSD GAP` min (`clk_114` from the previous SPI DATA access's ack to the request of this byte's write: what the firmware leaves userio_osd's synchroniser), `OSD EARLY` (the byte loaded while the previous one was still in the synchroniser) of the loads, and the bytes that were right (`l3check.py keys`: VERSION against the milestone, KEYQ against userio_osd's queue modelled as a FIFO). **E_osd = 34** (Task 1).

| Reply byte | RV `OSD GAP` min | RV `OSD EARLY` | RV right | RV margin to E_osd | 832 `OSD GAP` min | 832 `OSD EARLY` | 832 right |
|---|---|---|---|---|---|---|---|
| `OSD_CMD_VERSION` (0x88) byte 0 | 211 | 0 of 1 | 1 of 1 | +177 | 286 | 0 of 1 | 1 of 1 |
| VERSION byte 1 | 128 | 0 of 1 | 1 of 1 | +94 | 254 | 0 of 1 | 1 of 1 |
| VERSION byte 2 | **44** | 0 of 1 | 1 of 1 | **+10** | 286 | 0 of 1 | 1 of 1 |
| VERSION byte 3 | 44 | 0 of 1 | 1 of 1 | +10 | 266 | 0 of 1 | 1 of 1 |
| VERSION byte 4 | 44 | 0 of 1 | 1 of 1 | +10 | 286 | 0 of 1 | 1 of 1 |
| VERSION byte 5 | 44 | 0 of 1 | 1 of 1 | +10 | 254 | 0 of 1 | 1 of 1 |
| `OSD_CMD_KEYQ` (0x98) byte 0 (status) | 295 | 0 of 354 | 354 of 354 | +261 | 306 | 0 of 144 | 144 of 144 |
| KEYQ byte 1 (first event) | **56** | 0 of 22 | 22 of 22 | **+22** | 370 | 0 of 22 | 22 of 22 |
| KEYQ byte 2 | 60 | 0 of 22 | 22 of 22 | +26 | 358 | 0 of 22 | 22 of 22 |
| KEYQ byte 3 | 60 | 0 of 1 | 1 of 1 | +26 | 338 | 0 of 1 | 1 of 1 |
| KEYQ byte 4 | 60 | 0 of 1 | 1 of 1 | +26 | 338 | 0 of 1 | 1 of 1 |
| KEYQ byte 5 | 60 | 0 of 1 | 1 of 1 | +26 | 338 | 0 of 1 | 1 of 1 |
| KEYQ byte 6 | 60 | 0 of 1 | 1 of 1 | +26 | 338 | 0 of 1 | 1 of 1 |

(`clk_114` cycles. VERSION: one frame per run, `fpga_init`. KEYQ byte 0: every KEYQ frame, 354 on the RV, 144 on the 832; bytes 1-2: the 21 `KEY` frames (two events each) and the `BURST`; bytes 3-6: the `BURST` alone. The RV's twin `p4t8_xr` has the same figures; the 832's twin, see below.)

The per-key loop (`osd.c` `OsdNextEvent`, `kq_buf[i] = SPI_reply()`, exec-3 hand-over item 8) is now measured: the BURST frame `20 98 ff ff ff ff ff ff ff / 00 06 4c 00 4d 00 4c 00` read all six events right on both CPUs. The RV's smallest per-key gap is 56 (byte 1) and 60 (bytes 2..6), 22 and 26 `clk_114` above E_osd; the firmware's smallest gap anywhere in the run stays the version reply's 44. No `OSD EARLY` on either CPU, every reply byte right: **no "before" defect in the key path**, the handshake is a margin (and SPIN-removal) change, not a fix of an observed failure.

Coverage (Task 4 minor M2): the `OSD EARLY` monitor (`tb_l3.v`) checks every byte after the command of a 0x88 / 0x98 frame, so a KEYQ frame's per-key bytes 1..n are covered, and so is the status byte 0; hostmon's `OSD GAP` takes every reply write of those frames (per-key ones included). The new `=== OSD REPLY <cmd> byte <k>` lines split both per byte. The two commands are the only users of `SPI_reply()` in either firmware.

X-sensitivity: the RV twin `p4t8_xr` is SAME. The 832 twin `p4t8c_xr` (seed 505647130) has the same `spi.txt` (2,698 frames) but other cycles from the very first frame on: the 832 host CPU's random start state changes its timing (finding below, "Found by the L3 bench (Task 8)"); with `XSEED=4`, a seed whose 832 start matches, the twin `p4t8c_xs4` is SAME. The diff `run.sh diff p4t8 p4t8c` is empty with `boot`'s 9 rules, all used: no new `expected_diff.txt` rule.

Scenario figures: the script ends at cycle 165,059,293 on the RV (7.01 M cycles after the main-loop milestone at 158,045,126) and 215,391,641 (12.78 M after its milestone at 202,610,912) on the 832; a main-loop pass in the open menu is at least 5,320 `clk_114` on the RV (median 7,108) and 11,244 on the 832 (median 13,324) (runs p4t8d / p4t8dc), the `BURST` 192.

## Shared defects

- **The OSD menu's key repeat cannot start: the level read answers with the key queue, not the key (both firmwares since the KEYQ in userio_osd; found by Task 8, not fixed: parity, and the cause is in the command order plus the RTL's read path).**
  - **Mechanism.** `OsdGetCtrl()` (`fw/ctrl_rv/osd.c`, the same in `fw/ctrl_832`) reads the level with `OsdGetKeyLevel()`: a one-byte `OSD_CMD_READ` frame whose answer is the byte userio_osd_spi loads at the frame's start (`sdo_reg <= in` at the first falling `sck` edge), i.e. `userio_osd.v`'s `rddat` under the *previous* command's `cmd_dat`: the new command byte is decoded only after it has been shifted in. Before the KEYQ, the previous OSD command in an idle main loop was the previous pass's `OSD_CMD_READ` (`rddat` = `osd_ctrl`), so it worked. Now it is the previous pass's `OSD_CMD_KEYQ`, and `rddat` is `kq_rddat`: the queue's head, or 00 when the queue is empty. Only a pass right after a redraw (last command `OSD_CMD_OSD_WR`, default `rddat` = `osd_ctrl`) sees the real level.
  - **Evidence.** `keys` run `p4t8` (spi.txt line 1877): `20 00 / 4d` 6,325 `clk_114` after `KEY_DOWN` was released, just before the KEYQ frame that drains it (the queue's head, not the level 00). Probe (scratch, not committed: the `p4t8red` binary, a script that holds `KEY_DOWN` for 500,000 `clk_114` at TICKDIV 643): with `osd_ctrl` = 4d throughout, the `OSD_CMD_READ` frame right after the redraw answers 4d, and every later one in the idle passes (from cycle 158,718,390 on, one per pass of 7,108 cycles) answers **00**; the KEYQ frames' first MISO byte is 4d (that frame's command-time byte is the READ's `rddat`, which is the level, and the firmware discards it).
  - **Board effect (inferred from the above and the source, not seen on the board).** The repeat needs a level read showing the held key when `REPEATDELAY` (100 TIMER counts, about 580 ms) has run out; at that time the menu is idle and the level read gives 00, so holding up / down in the OSD menu does not auto-repeat. Rarely (when the free-running repeat timer, re-armed every `REPEATRATE` = 25 counts, about 145 ms, runs out during the redraw pass of a key, about 1 % of presses) one press moves two lines. At TICKDIV 1 (L2 / L3 boot speed) the timer is 643 x faster and the repeat can fire in the pass after a redraw, which is why the first probe at TICKDIV 1 did see one repeat.
  - **Fix options for Paul.** Firmware: read the level as the reply byte after the command (`SPI(OSD_CMD_READ); level = SPI_reply();`: by then `cmd_dat` is READ and `rddat` is `osd_ctrl`), in both firmwares (a reply byte, so it follows the reply-gap / handshake rules). Or RTL: have userio_osd answer the first byte of every frame from `osd_ctrl` rather than from the stale selection. The `keys` scenario's rules keep the run independent of this (no level read while a key is held, README "keys").

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

### Found by the L3 bench (Task 8, 2026-10-19)

**The 832 host CPU depends on power-up values of state that has no reset (not pinned by the bench, not investigated to the flop).** Under random initial state (`XRAND=1`) the EightThirtyTwo build's first hw access (the boot ROM's SPI write, before any SDRAM or card access) moves with the seed, and one seed hangs:

| binary | seed | first hw access (`clk_114`) |
|---|---|---|
| `p4t6` (no XRAND) / `p4t8c` (no XRAND) | - | 2,641 |
| `p4t6_xr` (Task 6) | 639498575 (its twin's), 505647130, 1, 2, 3, 4, 6, 7 | 2,641, 2,644, 2,644, 2,644, 2,659, 2,644, 2,644, **none in 400,000 cycles** |
| `p4t8c_xr` (Task 8) | 505647130 (its twin's), 1..8 | 2,644, 2,659, 2,644, 2,644, 2,641, none by 3,178, 2,644, 2,662, 2,644 |

(Each run with `+VERBOSE=1 +TIMEOUT=3000`, seed 7 of `p4t6_xr` with 400,000; the seed's mapping to the state changes with the binary.) Until the first hw access only the bridge, the 832 core and its boot ROM BRAM run; the bridge's three reset-less flops of Task 2 (`cache_req`, `cpu_ack`, `rom_wr`) are pinned, so the cause is other reset-less state in the EightThirtyTwo (`E832` RTL: the register file and the `thread` fields the reset leaves alone, beyond the seven the GHDL conversion copy resets; the decoder / fetch state) or in the 832 path of `832_bridge.vhd`. The board starts every flop at 0 (configuration), so power-up is fine; a warm `nReset` while the CPU runs is the open question, as for Task 2's five flops. Task 6's `boot` twin was SAME only because its seed happened to give the normal start. Bench handling: none yet; the 832 twins of later tasks will differ in timing the same way unless the state is found and pinned (a later task's or Paul's call). Task 8 shows the `keys` path X-insensitive with `XSEED=4` (`p4t8c_xs4` SAME).

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


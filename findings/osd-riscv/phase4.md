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

### Task 13: floppy read on L3 (`fdd_rd`, plan 7.1 item 6)

Ten full-track read DMAs (6,334 words, sync 0x4489, WORDSYNC) by `sim/l3/bfm_floppy.v` against the real `paula_floppy`, after the OSD inserts `TEST.ADF` into df0 with the drive sounds on (TICKDIV 643 from the script's start). RV `p4t13` and 832 `p4t13c`: every dump decodes to the ADF's 110 sectors and equals `mfm.py`'s `read_track` stream from byte 6 (the WORDSYNC start), tracks 0/0 and 79/1 also the golden streams of exec-3 Task 13. Item 6 (`fdd_fifo_empty_dma`, from the firmware's working level of 1,024 words to the track's last word): 0 of 52,058 slots (RV) and 0 of 50,913 (832); the FIFO's lowest fill there 992 / 949 words, about 300 lines of DMA (550,000 `clk_114`) of main-loop stall away from an empty slot. Details and the remaining timing-only differences of the RV-vs-832 diff: `sim/l3/README.md` "fdd_rd".

## Handshake design

The OSD "reply byte ready" handshake (decision 12.13 (a), plan 6.4 P1): the firmware starts a reply byte only once `userio_osd` has taken every byte before it, instead of waiting a counted `SPIN`. Task 9 is the RTL half in the Minimig (**RTL: Paul reviews before any bitstream**); Task 10 adds cfide's half (`osd_tx_seq`, `HOST_REQ` at `0xFFFFFFB4`, also **RTL: Paul reviews before any bitstream**).

### Task 9: `userio_osd.osd_rx_seq`

**Interface.** `userio_osd` output `reg [1:0] osd_rx_seq = 2'd0`, `clk` (`CLK_28`) domain, passed through `userio` and `minimig` as an output port of the same name. It steps +1 (mod 4) at the `clk7_en` edge at which `userio_osd_spi`'s `rx` is 1: the edge at which `cmd_dat`, `dat_cnt`, `ver_cnt` and `kq_rptr` take that byte. One step per byte received while `_scs` is low (`rx` fires once per byte). Nothing in the Minimig reads it; until Task 10 wires it to cfide, every top leaves it unconnected.

**The rx window (`rtl/minimig/userio_osd_spi.v`).** `new_byte` is set by the byte's 8th rising `sck` edge (asynchronous to `clk`). `rx_sync <= new_byte` at the next `clk7n_en` (up to 4 `clk` = 16 `clk_114` later), `rx <= rx_sync` at the following `clk7_en` (2 `clk` = 8 `clk_114`); `rx` high clears `new_byte` asynchronously, so `rx_sync` is 0 again at the next `clk7n_en` and `rx` is high for exactly one `clk7` period. The consuming edge is the `clk7_en` that ends that period (4 `clk` = 16 `clk_114`): there `userio_osd` takes the byte, `rddat` moves on to the reply for the next byte, and `osd_rx_seq` steps. Last `sck` edge to consuming edge: at most 16 + 8 + 16 = **40 `clk_114`** (Task 5's figure; E_osd = 34 is where the measured failures stop, Task 1). `userio_osd_spi` loads `rddat` into `sdo_reg` at the next byte's first falling `sck` edge, so a host that starts the next byte only after it has seen the step loads the right reply, with no extra wait.

**Why a sequence, not a "byte done" flag.** The window ends up to 40 `clk_114` after a byte's last edge, and nothing in it depends on `_scs`: the last byte of a frame is taken after the select has risen, possibly after the next frame's command byte has started. A flag set by that late pulse reads "done" while the new command byte is still in the synchroniser, and the first reply byte would be loaded from the old selection (Review Focus 1). A count cannot be fooled that way: the host counts the bytes it starts, and "ready" means both counts agree, so the late byte and the new command byte must both have been taken.

**Why 2 bits.** At SPI speed 1 a byte lasts 48 `clk_114`, longer than the 40-cycle window, so at most one byte of a frame is ever outstanding when the next starts. Across a frame boundary there can be two: the previous frame's last byte (still in its window) and the new command byte (bench check (d) below: `tx_seq - osd_rx_seq` = 1 when the new frame's select falls, 2 once its command byte has started). A 1-bit toggle would read 2 outstanding as 0, i.e. "ready" in exactly the cross-frame case; 2 bits tell 0 apart from 1, 2 and 3. Wider buys nothing: four or more outstanding bytes means the synchroniser has already merged bytes (a byte ending inside the previous one's window is lost, `rx` fires once), which the count cannot repair and the firmware's byte spacing (Task 5: 57 against the 40 bound) never produces.

**Why no reset, and what the absolute value means.** Only increments matter: cfide compares its own count of started bytes with `osd_rx_seq`, and Task 10 resyncs `osd_tx_seq <= osd_rx_seq` once the OSD select has been high for 64 `sysclk` cycles (longer than the 40-cycle window, so every earlier byte has been counted). The start value is therefore irrelevant, and a reset would only add a way for the count to move without a byte: the Minimig's `reset` is asserted by the OSD itself (`usrrst` / `cpurst`, a reset-control frame), and clearing the count while a frame's bytes are still in flight would look like lost bytes until the next idle resync. The declaration initialiser `= 2'd0` is plain Verilog (FPGA configuration value, vendor-neutral) and is there only so 4-state simulators do not start at X.

**XRAND.** `--x-initial unique` randomises only variables without an initial value; `osd_rx_seq` has a declaration initialiser, so the L3 / L2 X-sensitivity builds start it at 0 like the default build. It needs no pin in `sim/common/hostsim.sh` or `sim/l3/run.sh` (`l3_pin_minimig` / `l3_pin_async`, which pin reset-less or asynchronously preset/cleared flops whose start value the board defines), and it would not need one even without the initialiser, because only its increments are used (Task 10's resync takes whatever value it has).

**832 build unchanged.** A new output port and a 2-bit counter that drives nothing inside the Minimig; no existing signal changes value (the counter's only inputs are `clk`, `clk7_en` and `rx`, which it reads and does not drive). `minimig_virtual_top` leaves `minimig.osd_rx_seq` unconnected until Task 10, so the 832 bitstream (reference `build/stage_spicdc_49b1868`, md5 28b07e8c) has no logic reading it (an unloaded counter, which synthesis is free to remove; checked when Phase 5.1 builds the bitstream); Task 10's register reading it is read-only and the 832 firmware never reads it.

**Bench (`sim/osd_keyq`, iverilog).** New sections 9-12 of `osd_keyq_tb.v`, the fast host modelled as cfide at `SPI_fast()` (speed 1: `sck` half period 3 `clk_114`, everything on `clk_114` edges): (a) one step per byte for VERSION (command + 10), KEYQ (command + count + 6 events) and a 40-byte `OSD_CMD_OSD_WR` frame (0x0c, 00 00 00 line, 35 characters); (b) polling `osd_rx_seq` against its own byte count and starting at the first `clk_114` edge that sees it caught up (gap 0): all 10 VERSION bytes and the KEYQ count, 6 events and past-the-end byte right; (c) the same host not polling: 17 of 17 bytes wrong (the check bites); (d) a 3-byte `OSD_WR` frame, CS up, the KEYQ frame's first `sck` edge 8 `clk_114` after CS rose: the `OSD_WR` frame's last byte is provably still in the synchroniser when the KEYQ select falls, and polling reads count 02, both events and 00 right; (e) `run.sh mutant_seq` (run copy of `userio_osd.v`, the step taken on `spi0.rx_sync`, one `clk7` period early): (b) fails (all 18 bytes one behind) and so does (d). The existing checks and the `KEYQ_MUTANT` teeth are unchanged. Commands and results: `.superpowers/sdd/osd-riscv-exec-4/task-9-report.md`.

**L3 (the port unconnected, `tb_l3.v` names it `.osd_rx_seq()`).** `boot` on Verilator, both CPUs on the Task 7 cards (`FW` sha256 fd3b3c6a0b8ca273, `FW832` 768c765d57deb1a0): `p4t9r2` (RV, 636 s) and `p4t9c2` (832, 942 s) PASS, `spi.txt` and `hw.txt` byte-identical (`cmp`) to Task 7's gate runs `p4t7r2` / `p4t7c2`; the logs differ only by the `=== OSD REPLY` lines Task 8 added to the bench; `run.sh diff --unused-rules p4t9r2 p4t9c2` empty, `rules: all 9 used`.

### Task 10: cfide `HOST_REQ` (`0xFFFFFFB4`) and the wiring

**RTL: Paul reviews before any bitstream.** Files: `rtl/host/cfide.vhd` (port, counter, register), `rtl/soc/minimig_virtual_top.v` (`minimig.osd_rx_seq` -> `mycfide.osd_rx_seq`, a new `wire [1:0] osd_rx_seq`; `HOSTONLY` builds tie it to 0).

**Register.** `HOST_REQ` = a read of `0x0FFFFFB4` (the audio window `addr(7 downto 4) = X"B"`, `addr(3 downto 2) = "01"`): bit 0 `OSD_RDY`, bits 15..1 read 0 (reserved for P1). Reads of the window at `addr(3 downto 2) /= "01"` (`0xFFFFFFB0..B3`, `B8..BF`) return `audio_q` as before; writes anywhere in the window are unchanged (no new write register). The read value is a `clk_28` register, `host_req_q`, loaded with `OSD_RDY` at every `clk_28` edge, with no load enable; the `q` mux takes it for `"01"` only. The value the bridge reads is therefore the one loaded at the edge that raised `ack`. (Task 10's first version loaded it only at edges that saw `req` with the window selected, like `keyboard_q`. `req` and `addr` are `clk_114` registers, so that enable was a `clk_114` -> `dll_28` crossing timed only to `wizard.xdc`'s 4-cycle multicycle; if `ack`'s D path saw `req` at an edge where the enable did not, the bridge would return the previous poll's 1, a false `OSD_RDY`. Task 10 review I1.) Why a register and not the comparison itself: see the clock-domain statement.

**Counter rules.**
- cfide port `osd_rx_seq : in std_logic_vector(1 downto 0) := "00"` (`clk_28`): `userio_osd`'s count of the bytes it has taken (Task 9).
- `osd_tx_seq` (2 bits, `sysclk`, initial `"00"`, no reset): +1 at the `sysclk` edge that starts a byte, i.e. accepts a DATA write (`spi_dat_go`: the SPI process's own start condition `SPI_select`, `req`, `wr`, `SD_busy = '0'`, `addr(3 downto 2) = "00"`), while the OSD is selected. Selected is `scs(5) = '1'` in cfide's internal polarity (`EnableOsd()` writes `0x20`, `scs(5) <= not d(0)`; the pin `sd_cs(5) = NOT scs(5)` is `userio_osd`'s `_scs`, low). The brief's "`scs(5)` is '0'" names the select line's level; the code uses the register.
- Resync: `osd_idle` (7 bits) is cleared while the OSD is selected and counts `sysclk` cycles while it is not, stopping at 64; from then on (deselected for 64 consecutive cycles) `osd_tx_seq <= osd_rx_seq` every cycle. 64 > the ~40-cycle rx window (Task 9), counted from the deselect, which comes after the last byte's last `sck` edge, so every byte has been taken by then. It heals a byte `userio_osd` never took (a lost byte reads "not ready" only until the next idle frame boundary) and sets the start value: `scs` is cleared by `n_reset`, so the counts agree 64 cycles into any reset. The increment needs the OSD selected and the resync needs it deselected, so they never meet.
- `OSD_RDY = '1'` when `osd_tx_seq = osd_rx_seq`. Two bits tell "all taken" from 1, 2 and 3 outstanding; across a frame boundary there can be 2 (Task 9, "Why 2 bits").
- Unchanged: the SPI process, `scs`, `SD_busy`, the ack, every other register. The new logic drives only `host_req_q`, which reaches `q` for `"01"` only.

**Clock-domain statement.** Nets checked in `rtl/soc/minimig_virtual_top.v`: `amiga_clk` (`rtl/clock/amiga_clk.v` -> `amiga_clk_xilinx`, one `MMCME2_ADV`) drives `CLK_114` (`CLKOUT0` /10 -> `BUFG_114`) and `CLK_28` (`CLKOUT2` /40 -> `BUFG_28`); `minimig .clk(CLK_28)` (so `userio_osd`'s `clk` and `osd_rx_seq`'s domain), `mycfide .clk_28(CLK_28)` and `mycfide .sysclk(CLK_114)`; the bridge `hostcpu .clk(CLK_114)`; the new net `osd_rx_seq` runs from `minimig` to `mycfide` with nothing in between. The constraints (`fpga/openaars/aars_v5.0/xc7a100t`): `clocks.xdc` generates `clk_114` and `dll_28` from the two `CLKOUT`s; `ddr3.xdc`'s `set_clock_groups -asynchronous` keeps them in one group (timed against each other); `wizard.xdc` lines 14-18 relax every `dll_28` -> `clk_114` path to a 4-cycle setup (`-end 4`, hold `-end 3`) and every `clk_114` -> `dll_28` path to `-start 4` (hold `-start 3`), with cell-scoped single-cycle exceptions for the crossings whose consumer samples every cycle.

(a) `osd_rx_seq` is a binary counter and crosses with no synchroniser. That is safe only because `CLK_28` and `CLK_114` come from one MMCM, phase aligned, and every path the counter takes is timed by STA, not because the counter is slow. But the STA on a `dll_28` -> `clk_114` path only guarantees arrival within 4 `clk_114` cycles (35.3 ns), so a `sysclk` register that samples `osd_rx_seq` in an arbitrary cycle could catch it changing; for a 2-bit binary count a sample mid-change can be a third value (`01` -> `10` read as `11` or `00`), and in the cross-frame case (`osd_tx_seq` = `osd_rx_seq` + 2 = `11`) `11` reads as ready: Review Focus 1. So cfide never compares in `sysclk`:
- `osd_rx_seq` -> `osd_rdy` -> `host_req_q`: `dll_28` to `dll_28`, single cycle.
- `osd_tx_seq` (`clk_114`) -> `host_req_q` (`dll_28`): the register loads at every `clk_28` edge, but only the value loaded at the edge that raises the read's `ack` is returned, so `osd_tx_seq` must be stable for 4 `clk_114` cycles before that edge (the `-start 4` multicycle); a load at any other edge may catch it changing and is overwritten at the next edge. It changes (1) at a DATA write's accept edge W, in an earlier bus access: the ack of that access is a `clk_28` edge >= W+1, the bridge sees it one `clk_114` cycle later and drops `req`, the next request (the HOST_REQ read) comes >= 1 cycle after that, and the `clk_28` edge that sees it is the next one, >= 4 cycles after the ack edge, so >= W+5; (2) at the resync, only after 64 deselected cycles, where the firmware does not poll (it polls before reply bytes, inside a frame: Task 11), and where both the old and the new value are right answers (every byte has been taken; 0 means "poll again").
- `osd_rx_seq` -> `osd_tx_seq` (the resync, `dll_28` -> `clk_114`): sampled only while static, >= 64 cycles after the deselect and so >= 24 after the last possible step; a static value has no setup or hold problem whatever the path delay.
- `host_req_q` -> `q` -> the bridge's read register: launched at the `clk_28` edge that raises `ack`, as `ack` itself and the other registered cfide reads (`irq_q`, `keyboard_q`, `amigatohost`); the bridge takes `q` in the `clk_114` cycle in which it sees `ack`.
- No load enable: no `clk_114` signal (`req`, `addr`) decides which `clk_28` edge loads `host_req_q`. Such an enable would be a second `clk_114` -> `dll_28` crossing next to `ack`'s own D path (`req`), both timed only to 4 cycles, and if the two resolved at different edges the read would return a value loaded at an earlier edge (the previous poll's 1).
No new timing exception is needed: each path is covered by the clock-level multicycles for exactly the stability shown above. For an asynchronous pair (the host CPU on a clock of its own MMCM or PLL) this would not hold: `osd_rx_seq` would have to be Gray coded (one bit changes per step, so a sample taken mid-change is the old or the new count) and pass a 2-FF synchroniser in the reading domain. Phase 5.1 check: `report_timing` from `osd_rx_seq_reg` and `osd_tx_seq_reg` shows them under those multicycles and met.

(b) The settle path. At the `clk_28` edge E at which `osd_rx_seq` steps, `userio_osd`'s `cmd_dat` / `dat_cnt` / `ver_cnt` / `kq_rptr` step too and `rddat` (the reply mux, with `kq_mem[kq_rptr]`, an asynchronous read) settles; `userio_osd_spi` loads `sdo_reg <= in` (`rddat`) at the next byte's first falling `SPI_SCK` edge, which is cfide's DATA write accept edge W (`sck_pin <= '1'`, `SPI_SCK = NOT sck_pin`) plus the `sck` routing delay. Until Task 11 the `SPIN`s of `SPI_reply()` put >= 44 `clk_114` (RV, Task 5/8 measurements) between them; with the handshake the minimum is set by the poll: `host_req_q` loaded at E still holds the old count, so the first read that can show the step is loaded at the next `clk_28` edge, E+4 `clk_114`, its ack is seen by the bridge at E+5, the DATA write's request comes >= 2 cycles later (the bus contract; `tb_spi_cdc`'s GAP 2) and is accepted at the next edge: W >= E+8, 70.5 ns. The path `rddat` -> `sdo_reg` (`dll_28` -> `spi_sck`) is bounded by `sd_card.xdc`'s `set_max_delay -datapath_only 17.630` between `{clk_114 dll_28 clk_38}` and `spi_sck`, and `SPI_SCK` reaches `sdo_reg` after W (its routing, ~1.5 ns), which only adds margin: covered by STA with more than 50 ns to spare. In simulation `tb_spi_cdc +RDY=1` starts every reply byte at the earliest the poll allows (GAP 2) in all seven skew pairs (`sck` up to 9.5 ns late against `clk_28`, both edge orders) and gets every byte right.

**832 unchanged.**
- Firmware sources: `grep -rn 'fffffb[4-9a-f]\|AUDIO *+' fw/ctrl_832 fw/ctrl_boot_832` is empty (exit 1). The 832's only audio-window address is `fw/ctrl_832/hardware.h:27`, `#define AUDIO (*(volatile unsigned char *)0x0fffffb3)`: `addr(3 downto 2) = "00"`, still `audio_q`.
- Binary: `832d` disassembly of `832OSDAD.BIN` (sha256 768c765d57deb1a0, the L3 image built from `fw/ctrl_832` = the sources of `build/stage_spicdc_49b1868`). `li` chains ending at `0x0fffffb3`: 9, all `AUDIO` (byte stores `stbinc` / `byt; st`, byte loads `byt; ldt`); ending at `0x0fffffb4..b7`: none. The values `0xffffffb4..b7` (-76..-73, also bit 23 set) occur 18 times as `li` values, every one a branch offset (`add r7`), a stack adjustment (`add` / `sub r6`), a prefix of a longer chain, or (once, 0x16fa8) `addt r0` on `r0 = 0x26f94`, giving the SDRAM address 0x26f48. No access to the `HOST_REQ` address.
- RTL: reads at `"00"`, `"10"`, `"11"` and every write behave as before; `host_req_q` loads at every `clk_28` edge but reaches `q` only at `"01"`, which the 832 never reads. The defaulted port means a top without the wiring (none is built: QMTech only) reads `OSD_RDY` 0 after its first OSD byte until the next resync; only firmware that polls `HOST_REQ` sees it.
- Benches (below): `sim/spi_cdc/host832` (the real 832 + bridge + cfide, direct mode) logs identical to the base tree's; L3 `CPU=832` `boot` and `keys` `spi.txt` / `hw.txt` byte-identical to Task 9's / Task 8's; `tb_spi_cdc`'s default grid with the old bench gives identical logs on the base and the new RTL.

**Benches.**
- `sim/spi_cdc/tb_spi_cdc.v` (xsim): cfide's `osd_rx_seq` from the bench's `userio_osd`; `+RDY=1` polls `HOST_REQ` before each OSD reply byte (each read an ordinary bus access with the same gap; a 100,000-cycle watchdog ends the run); `+TESTS` bit 16 `xframe`: a 3-byte `OSD_CMD_OSD_WR` frame (`0c 00 00`), CS up and down at gap 2, then the VERSION read, the bench also counting the runs in which the `OSD_WR` frame's last byte was still not taken when the VERSION command started (a run with `xframe` fails if that never happens). `run.sh` `RDY_MUT=1`: a run copy of cfide with the `-- OSD RDY` line replaced by `osd_rdy <= '1'`.
- `sim/host_bridge` `t_osdrdy` (`sw/t_osdrdy.S`, not in `all`): the bench drives cfide's `osd_rx_seq` per checkpoint; 17 checks (after reset 1; a byte to `sd_cs[1]` not counted; one OSD byte 0 until the bench steps the sequence; `0xFFFFFFB0` half and byte, `B8`, `BC` still `audio_q`; two outstanding 0, also with one taken; a byte never taken: 0, still 0 right after the deselect, 1 after the resync; counting goes on from the resynced value; byte, half and word reads), and the bench checks that the resync came >= 64 cycles after the deselect.
- `sim/l3/tb_l3.v`: `osd1.osd_rx_seq` -> `mycfide.osd_rx_seq`, as the board top, so Task 11's poll works in L3.

**Results** (2026-10-19; commands and logs in `.superpowers/sdd/osd-riscv-exec-4/task-10-report.md`).

| Run | What | Result |
|---|---|---|
| `p4t10red` (xsim) | `tb_spi_cdc +RDY=1 +TESTS=8`, one pair, cfide with the port only (`HOST_REQ` still `audio_q`) | RED: `=== FAIL (watchdog: HOST_REQ read 00 for 100000 cycles ...)` |
| `p4t10lred` (Verilator) | L2 `t_osdrdy`, port only | RED: `=== FAIL code 3` (`HOST_REQ` = `audio_q` = 1 after an OSD byte) |
| `p4t10` (xsim, 42 s) | `+RDY=1 +TESTS=24 +OSD_MIN_GAP=0`, 7 pairs x 16 gaps from 2 | PASS in all 7 pairs: `osd` and `xframe` 0 failures at every gap; at gap 2, 222..260 of 282..320 `HOST_REQ` reads per pair read 0 (the poll waits); the `xframe` case live (the `OSD_WR` byte not yet taken at the VERSION command) in 3 of 3 runs at gap 2 in every pair, in 1..3 up to gap 8..12, never from gap 16 |
| `p4t10m` (xsim, 41 s) | `RDY_MUT=1`, `+RDY=1 +TESTS=8 +OSD_MIN_GAP=0` | FAIL in all 7 pairs: `osd` fails at gaps 2..12 (22-24 failing runs per pair); not above 12 (the extra `HOST_REQ` read adds an access and a gap, below `E_osd` = 34) |
| `p4t10d` (xsim, 132 s) | default grid | PASS in all 7 pairs; the counted lines (`wr`, `rd`, `direct` at every gap, `osd` at 40/48/64, verdict) identical to Task 1's `p4t1ref` |
| scratch (xsim, 2 x 135 s) | Task 9's bench (`35218e3`) on the base RTL and on the new RTL | identical logs in all 7 pairs (the RTL does not move the default grid; the uncounted `osd` failure details below gap 40 move with the bench change) |
| `p4t10l` / `p4t10lx` | L2 `t_osdrdy`, Verilator / xsim (35 s) | PASS; resync at +65 cycles after the deselect; `compare` SAME |
| `p4t10a` / `p4t10ax` | L2 `all`, Verilator (96 s) / xsim (451 s) | ALL PASS (42 runs) each; `compare` SAME with Task 2's `p4t2an` (42 of 42) and with each other |
| `p4t10hb` / `p4t10h` (xsim, 205 / 206 s) | `sim/spi_cdc/host832`, base tree (`REV=35218e3`) / new | PASS 7/7, the same `L` histograms (`45:19 57:1`, ..., `SLAT=4 SJIT=32` 17 bins up to 125), logs identical |
| `p4t10c` (Verilator, 1,232 s) | L3 `CPU=832 boot`, Task 7 cards (`FW` fd3b3c6a0b8ca273, `FW832` 768c765d57deb1a0) | `=== boot PASS`; `spi.txt` (1,937 frames) and `hw.txt` `cmp`-identical to `p4t9c2`; `run.sh compare p4t9c2 p4t10c` SAME; `results.txt` differs only in the wall time |
| `p4t10k` (Verilator, 1,296 s) | L3 `CPU=832 keys`, the same images | `=== keys PASS`, OSD EARLY 0 of 198; `spi.txt` (2,698 frames) and `hw.txt` `cmp`-identical to `p4t8c`; `run.sh compare p4t8c p4t10k` SAME; `results.txt` differs only in the wall time |

### Task 12: the "after" OSD reply measurement on L3, and the handshake's teeth

Tree: `osd-riscv` at 2c377f2 (Tasks 9-11 in), Verilator, SLAT=8 SJIT=0, SCKDLY 1.5 / C28DLY 0.3 unless stated, `EXTRA_WS` 0, no `+OSD_EARLY_OK`. One RV image (`RV32OSDA.BIN` sha256 0162e53fc0b4ce4d, built once from this tree) and one 832 image (`832OSDAD.BIN` 768c765d57deb1a0, the "before" one) on every card.

| Run (RUNTAG) | Scenario | Verdict |
|---|---|---|
| `p4t12` + `p4t12_xr` (xpair) | `keys` | PASS, `OSD EARLY 0 of 420`, `l3check.py keys` PASS (48 events, BURST one frame, 24 pages), twin SAME (3523 frames) |
| `p4t12b` + `p4t12b_xr` (xpair) | `boot` | PASS, `OSD EARLY 0 of 26`, twin SAME (1874 frames) |
| `p4t12f` (`+FAST_HW=1`) | `keys` | PASS, `OSD EARLY 0 of 450` |
| `p4t12s1` (`+SCKDLY=0.3 +C28DLY=4.0`) | `keys` | PASS, `OSD EARLY 0 of 420` |
| `p4t12s2` (`+SCKDLY=9.5 +C28DLY=0.3`) | `keys` | PASS, `OSD EARLY 0 of 420` |
| `p4t12c` (`CPU=832`, same cards) | `keys` | PASS, `OSD EARLY 0 of 198`; `run.sh diff p4t12 p4t12c` empty (exit 0, `boot`'s 9 rules) |

`EXTRA_WS` is 0 in every run (the default; the L3 `EXTRA_WS` sweep is Task 19).

**Before / after** (RV; `clk_114`; `OSD GAP` min per command and reply byte, 0 = the first byte after the command; E_osd = 34; "before" = `p4t8`, the `SPIN`s, `+OSD_EARLY_OK=1`; "after" = `p4t12`; all bytes right and `OSD EARLY` 0 of the loads in both, the 832's figures from `p4t12c`, which equal `p4t8c`'s (unchanged firmware)):

| Reply byte | RV gap before | RV gap after | `OSD EARLY` before / after | 832 gap | 832 `OSD EARLY` |
|---|---|---|---|---|---|
| VERSION (0x88) byte 0 | 211 | 192 | 0 of 1 / 0 of 1 | 286 | 0 of 1 |
| VERSION byte 1 | 128 | 111 | 0 / 0 of 1 | 254 | 0 of 1 |
| VERSION byte 2 | 44 | 147 | 0 / 0 of 1 | 286 | 0 of 1 |
| VERSION byte 3 | 44 | 111 | 0 / 0 of 1 | 266 | 0 of 1 |
| VERSION byte 4 | 44 | 63 | 0 / 0 of 1 | 286 | 0 of 1 |
| VERSION byte 5 | 44 | 63 | 0 / 0 of 1 | 254 | 0 of 1 |
| KEYQ (0x98) byte 0 (status) | 295 | 196 | 0 of 354 / 0 of 366 | 306 | 0 of 144 |
| KEYQ byte 1 | 56 | 203 | 0 of 22 / 0 of 22 | 370 | 0 of 22 |
| KEYQ byte 2 | 60 | 43 | 0 of 22 / 0 of 22 | 358 | 0 of 22 |
| KEYQ byte 3 | 60 | 43 | 0 of 1 / 0 of 1 | 338 | 0 of 1 |
| KEYQ byte 4 | 60 | 43 | 0 of 1 / 0 of 1 | 338 | 0 of 1 |
| KEYQ byte 5 | 60 | 43 | 0 of 1 / 0 of 1 | 338 | 0 of 1 |
| KEYQ byte 6 | 60 | 43 | 0 of 1 / 0 of 1 | 338 | 0 of 1 |
| whole run `OSD GAP` min / `OSD EARLY` | 44 / 0 of 408 | 43 / 0 of 420 | | 254 / 0 of 198 | |

The gap column is no longer the safety margin: with the handshake the gap is whatever the poll leaves (the minimum 43 is the poll read's own round trip, 9 above E_osd and 3 above `OSD_MIN_GAP`), and the guarantee is the `OSD_RDY` poll itself. The measured fact is that every reply byte is loaded after the previous one passed the synchroniser (`OSD EARLY` 0), in the default timing, with `FAST_HW`, and in the two extreme skew pairs; the same figures in the skew runs (`p4t12s1/s2` gaps equal `p4t12`'s).

**Teeth** (run copies only; `rtl/` and `fw/` untouched):

- `p4t12m1c`, cfide's `OSD_RDY` forced '1' (`RDY_MUT=1`, `sim/l3/run.sh`) with the RV firmware, `+FAST_HW=1`: **FAILS** with `OSD EARLY 1 of 450` and its bench error, `version reply byte 2: 1a, want 0a` (`REPLY 88 byte 2: 0 of 1 right`), `l3check.py keys` FAIL, milestones 49 of 51 (the version frame). In the default timing the same mutant (`p4t12m1`, and `p4t12m1a/b` in the two skew pairs) fails only on `OSD GAP min 27` below `OSD_MIN_GAP` 40, with `OSD EARLY 0 of 420` and every reply byte right: the one poll read that still happens leaves 27 cycles, which at those timings is enough for the synchroniser. So the default-timing mutant is caught by the gap monitor, not by EARLY, and the EARLY/wrong-byte tooth needs the faster `FAST_HW` bus.
- `p4t12m2`, the firmware with the `HOST_REQ` poll removed (`sed` on `hardware.c` in a copy built from git `HEAD` outside the tree, `grep -c 'if (0) {'` = 1, no `SPIN` in `SPI_reply()`): **FAILS** with `OSD EARLY 3 of 6 reply bytes`, `OSD GAP min 14`, the VERSION reply `00 01 1a 1a 0a a4 a4` (bytes repeated) instead of `01 1a 0a 02 a4 fd`, milestones 48 of 51, and no KEYQ frame at all in the run (the wrong caps byte 0xa4 lacks `CAPS_KEYQ`, so the firmware never uses the queue), the run ends at the cycle limit. So the KEYQ-byte leg of the stated failure cannot show here: the mutant breaks `fpga_init`'s version reply first, and `l3check.py keys` fails on the missing steps/events instead of on KEYQ bytes.

**Plan 7.1 item 2** (the firmware's `SPI_reply()` timing against `userio_osd`'s reply synchroniser): closed in simulation by the handshake; board confirmation in Phase 6.

## Shared defects

- **The OSD menu's key repeat cannot start: the level read answers with the key queue, not the key (both firmwares since the KEYQ in userio_osd; found by Task 8, not fixed: parity, and the cause is in the command order plus the RTL's read path).**
  - **Mechanism.** `OsdGetCtrl()` (`fw/ctrl_rv/osd.c`, the same in `fw/ctrl_832`) reads the level with `OsdGetKeyLevel()`: a one-byte `OSD_CMD_READ` frame whose answer is the byte userio_osd_spi loads at the frame's start (`sdo_reg <= in` at the first falling `sck` edge), i.e. `userio_osd.v`'s `rddat` under the *previous* command's `cmd_dat`: the new command byte is decoded only after it has been shifted in. Before the KEYQ, the previous OSD command in an idle main loop was the previous pass's `OSD_CMD_READ` (`rddat` = `osd_ctrl`), so it worked. Now it is the previous pass's `OSD_CMD_KEYQ`, and `rddat` is `kq_rddat`: the queue's head, or 00 when the queue is empty. Only a pass right after a redraw (last command `OSD_CMD_OSD_WR`, default `rddat` = `osd_ctrl`) sees the real level.
  - **Evidence.** `keys` run `p4t8` (spi.txt line 1877): `20 00 / 4d` 6,325 `clk_114` after `KEY_DOWN` was released, just before the KEYQ frame that drains it (the queue's head, not the level 00). Probe (scratch, not committed: the `p4t8red` binary, a script that holds `KEY_DOWN` for 500,000 `clk_114` at TICKDIV 643): with `osd_ctrl` = 4d throughout, the `OSD_CMD_READ` frame right after the redraw answers 4d, and every later one in the idle passes (from cycle 158,718,390 on, one per pass of 7,108 cycles) answers **00**; the KEYQ frames' first MISO byte is 4d (that frame's command-time byte is the READ's `rddat`, which is the level, and the firmware discards it).
  - **Board effect (inferred from the above and the source, not seen on the board).** The repeat needs a level read showing the held key when `REPEATDELAY` (100 TIMER counts, about 580 ms) has run out; at that time the menu is idle and the level read gives 00, so holding up / down in the OSD menu does not auto-repeat. Rarely (when the free-running repeat timer, re-armed every `REPEATRATE` = 25 counts, about 145 ms, runs out during the redraw pass of a key, about 1 % of presses) one press moves two lines. At TICKDIV 1 (L2 / L3 boot speed) the timer is 643 x faster and the repeat can fire in the pass after a redraw, which is why the first probe at TICKDIV 1 did see one repeat.
  - **Fix options for Paul.** Firmware: read the level as the reply byte after the command (`SPI(OSD_CMD_READ); level = SPI_reply();`: by then `cmd_dat` is READ and `rddat` is `osd_ctrl`), in both firmwares (a reply byte, so it follows the reply-gap / handshake rules). Or RTL: have userio_osd answer the first byte of every frame from `osd_ctrl` rather than from the stale selection. The `keys` scenario's rules keep the run independent of this (no level read while a key is held, README "keys").

- **The drive sounds write `AUDIO = AUDIOF_ENA` on every main-loop pass once the ring's second half is rendered (both firmwares; found by Task 13, not fixed: parity).** `drivesounds_render()` (`fw/ctrl_rv/drivesounds.c:302`, `fw/ctrl_832/drivesounds.c:295`) calls `audio_start()` while `drivesounds.active && !drivesounds.playing && cursor & 0x4000`, and nothing ever sets `drivesounds.playing` to 1 (it is only cleared). Evidence: `fdd_rd` runs `p4t13` (RV) / `p4t13c` (832), `hw.txt`: 12,083 / 4,569 writes of `ffffb0 0001`, one per pass while the motor sound plays. Board effect: a redundant register write per pass (the player is already enabled), harmless as far as the source shows; it makes the count of hw writes depend on the CPU's speed. Fix option: set `drivesounds.playing = 1` next to `audio_start()`.

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

(Each run with `+VERBOSE=1 +TIMEOUT=3000`, seed 7 of `p4t6_xr` with 400,000; the seed's mapping to the state changes with the binary.) Task 13 adds one more: the `fdd_rd` twin `p4t13c_xr` (seed 1528826596) made no hw access and no SDRAM read in 660 M cycles; `run_p4t13c_hang` (`boot_short`, `XSEED=1528826596`, `TIMEOUT=3000000`) reproduces it in 16 s (`HW accesses 0`). Until the first hw access only the bridge, the 832 core and its boot ROM BRAM run; the bridge's three reset-less flops of Task 2 (`cache_req`, `cpu_ack`, `rom_wr`) are pinned, so the cause is other reset-less state in the EightThirtyTwo (`E832` RTL: the register file and the `thread` fields the reset leaves alone, beyond the seven the GHDL conversion copy resets; the decoder / fetch state) or in the 832 path of `832_bridge.vhd`. The board starts every flop at 0 (configuration), so power-up is fine; a warm `nReset` while the CPU runs is the open question, as for Task 2's five flops. Task 6's `boot` twin was SAME only because its seed happened to give the normal start. Bench handling: none yet; the 832 twins of later tasks will differ in timing the same way unless the state is found and pinned (a later task's or Paul's call). Task 8 shows the `keys` path X-insensitive with `XSEED=4` (`p4t8c_xs4` SAME).

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


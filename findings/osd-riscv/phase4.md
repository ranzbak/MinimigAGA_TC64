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

Ten full-track read DMAs (6,334 words, sync 0x4489, WORDSYNC) by `sim/l3/bfm_floppy.v` against the real `paula_floppy`, after the OSD inserts `TEST.ADF` into df0 with the drive sounds on (TICKDIV 643 from the script's start). RV `p4t13` and 832 `p4t13c`: every dump decodes to the ADF's 110 sectors and equals `mfm.py`'s `read_track` stream from byte 6 (the WORDSYNC start), tracks 0/0 and 79/1 also the golden streams of exec-3 Task 13. Item 6 (`fdd_fifo_empty_dma`, from the firmware's working level of 1,024 words to the track's last word): 0 of 52,058 slots (RV) and 0 of 50,913 (832); the FIFO's lowest fill there 992 / 949 words, about 300 lines of DMA (2.2 M `clk_114`, 7,264 per line) of main-loop stall away from an empty slot. Details and the remaining timing-only differences of the RV-vs-832 diff: `sim/l3/README.md` "fdd_rd".

### Task 14: floppy write on L3 (`fdd_wr`, plan 7.1 item 7)

Ten full-track write DMAs by `sim/l3/bfm_floppy.v` against the real `paula_floppy`: `sim/l3/gen/mkwrtrack.py`'s MFM streams with new data in every sector, the last track (cylinder 40 head 0) with a bad header checksum in sector 3, after the OSD inserts `TEST.ADF` (TICKDIV 643 from the script's start). `TEST.ADF` is then copied off the saved card. 832 `p4t14fc` (on the same card as the RV run; earlier `p4t14c` on the card with the old RV image, and its `XSEED=4` twin, normalised diff empty) and RV `p4t14f` (the fixed firmware; twin SAME; `run.sh diff` against `p4t14fc` empty): 109 sectors hold their new data, the other 1,650 are unchanged; the bad-header sector is skipped, and `GetHeader`'s FatalError ("Bad checksum", 26) shows the FATAL page, the same on both CPUs. Item 7 (`fdd_fifo_full_write`): 0 of 63,340 slots on both, FIFO max 518 words. The RV without the gap (`p4t14w`) wrote nothing: "Found by the L3 bench (Task 14)" below. `bfm_floppy` now waits for the drive after motor on (500 ms) and after a head change (15 ms), so Task 13's two remaining `fdd_rd` diff lines are gone (`p4t14r` / `p4t14rc`: empty, all 13 rules used). Details: `sim/l3/README.md` "fdd_wr".

### Task 15: hard disk on L3 (`hdd`, plan 7.1 item 8)

Twelve ATA commands by `sim/l3/bfm_ide.v` (a 68k IDE driver on `gayle`'s 68k side) against the real two-port `gayle`, `paula_floppy`'s HDD path and direct mode, on the `hdd` card (`RDB.HDF` unit 0 = port 0 master, own RDB; `SYNTH.HDF` unit 1 = slave, synthesised RDB, CHS 257.1.32): IDENTIFY, READ SECTORS of the RDSK / PART blocks and 64 sectors, SET MULTIPLE 16, READ MULTIPLE 64 across cylinder 255 / 256 and 32 from cylinder 256, WRITE SECTORS 64, WRITE MULTIPLE 32, both read back, and READ MULTIPLE 16 of `RDB.HDF` from LBA 0. RV `p4t15` and 832 `p4t15c`: every read equals the drive (IDENTIFY = `fw/ctrl_rv/test/gold/identify.py`, RDSK / PART = `rdb.py`, `RDB.HDF` block 0 patched as `hdd.c` does), the end-of-command task file is the last sector's CHS (cylinder high 1 where it should be), the 96 written sectors are in the saved card's `SYNTH.HDF` clusters and no other card sector changed. Item 8 (`ide_wait`, `rec`: status-driven, no margin; fix-round runs `p4t15f` / `p4t15cf`, traces byte-identical to `p4t15` / `p4t15c`): the time the 68k side spent waiting on the firmware, min 64 `clk_114` over 34,313 (RV) / 34,362 (832) waits; per sector of a READ the interrupt comes after a median 48,880 / 58,464 `clk_114`, per sector of a WRITE 98,768 / 128,544, per 16-sector WRITE MULTIPLE block 1.50 M / 1.98 M; per command min / median / max in `sim/l3/README.md` "hdd". The RV-vs-832 diff is empty with three new UART rules (two `fmt_diff_expected.txt` cases, the index time in TIMER counts) and one normaliser addition (the first polls after a served IDE request).

### Task 16: CD-ROM data on L3 (`cd`, plan 7.1 item 9)

Eleven ATAPI packets and IDENTIFY PACKET DEVICE by `sim/l3/bfm_ide.v` on IDE port 2 master (`gayle` port 1 in packet mode) against `cdrom.c` / `atapi.c`, with `TEST.CUE` + `TEST.BIN` (`CDCFG=cue`) or `TEST.ISO` (`iso`) in the drive, TICKDIV 643 from the scenario's start. RV `p4t16` / `p4t16i` and 832 `p4t16c` / `p4t16ci`: IDENTIFY PACKET = `atapi_identify()` field by field (0x8580: ATAPI, CD-ROM, removable, 12-byte packets; model `TEST`), TEST UNIT READY CHECK CONDITION 06/29/00 (the Amiga reset seen at the first task file read replaces the insert's 06/28/00), REQUEST SENSE, INQUIRY, READ CAPACITY, READ TOC (the CUE's three tracks and lead-out 514; the ISO's one track, lead-out 311), MODE SENSE(10) 3F, READ CD MSF CHECK CONDITION 05/20/00 (error 0x54) = `atapi.c`'s bytes; READ(10) 32 sectors from LBA 16 and READ(12) 8 from LBA 56 = the ISO's blocks / the BIN's MODE1 user data; all twelve dumps byte-identical between the CPUs. Item 9 (`cd_timeout_left`): `CD_TIMEOUT` = 10000 TIMER counts = 6,584,320,000 `clk_114` at TICKDIV 643; the longest phase window (from the firmware's `CMD_IDE_XFER_WR` to `xfer_done`, where `cd_wait()` polls) is 161,376 / 180,112 `clk_114` (cue, RV / 832) and 690,208 / 714,144 (iso, an 8 KB direct-mode block): at most 1.1 TIMER counts, 1e-4 of the timeout; the firmware's longest service time (the 68k's longest wait on it) 419,280 / 602,464 `clk_114` (cue: four or five FAT-sector reads through the CPU per raw sector) and 127,872 / 166,400 (iso). The RV-vs-832 diff has two timing-only lines per disc (MISO byte 0 of `cd_wait()`'s first `ReadIDEFlags()` frame after the INQUIRY and MODE SENSE data phases: the IDE command bit, sampled before / after the 68k's last data read; the firmware discards that byte); with the Task 16 ruling's normaliser mask (MISO byte 0's IDE request bits in `ReadIDEFlags()` frames) the diff is empty for both discs. Details: `sim/l3/README.md` "cd".

### Task 17: CD audio on L3 (`cdda`, `cdda_load`, plan 4.1 / 4.4)

`bfm_ide.v` plays TEST.CUE's track 2 through `atapi.c` and `cdaudio.c` at the board's TIMER rate (TICKDIV 643): PLAY AUDIO MSF of 1.5 s (LBA 214..326), PAUSE at the player's 6th flip, READ SUB-CHANNEL, RESUME, STOP at the 7th. `cdda_load` adds a READ MULTIPLE of 256 `SYNTH.HDF` sectors from the 2nd flip (cdhdd card). `bfm_audio.v` copies every half the player starts out of the SDRAM model, and `l3check.py cdda` compares each one with TEST.BIN at the firmware's position. RV `p4t17` / `p4t17l` and 832 `p4t17c` / `p4t17lc`: all 9 halves equal on both CPUs; 0 underruns and 0 writes into the playing half, in `cdda_load` too. The 256 HDF sectors = the file. READ SUB-CHANNEL: paused, track 2 index 1, within 86 frames of the player.

Ring refill after a flip (plan 4.4, the firmware's last write into the free half), median: **RV 42.40 ms, 832 88.15 ms** (`cdda_load` 42.39 / 88.14, max 42.96 / 96.69). The gate RV <= 832 holds. `run()`'s fill of both halves at PLAY: 84.1 / 175.3 ms. Each refill blocks the main loop: its longest gap while playing is 42.4 / 88.2 ms (`cdda_load` 43.0 / 95.2). The 832 refill uses 47 % of a half's 186 ms, the RV's 23 %.

Boot behaviour seen on both CPUs: `main()`'s `audio_clear()` enables the player for one TIMER count before the main loop (a player run of its own; `l3check.py` counts runs only from the PLAY on). The RV-vs-832 differential had two timing-only sources: the per-pass `ReadIDEFlags()` of `CD_AudioPoll()` (RV 17,174 frames, 832 7,228) and the paused position (RV LBA 300 / frame 50,944, 832 LBA 304 / 52,992: the PAUSE is served after the refill, 46 ms = 8 TIMER units apart). Per the Task 17 ruling, they are now a flag-poll repeat drop in `spitrace.py norm` and a `DROPBLOCK` from READ SUB-CHANNEL to the RESUME's ENA; the diffs `p4t17`/`p4t17c`, `p4t17l`/`p4t17lc` and `p4t17c`/`p4t17c_xs1` are empty, and the `cd`/`hdd` pairs are unchanged. Note: the underrun gate (RV <= 832) is weak as run, 0 vs 0, because the 256-sector HDF read never stalls even the 832 for a whole half (longest main-loop gap 95 ms of 186 ms); a load that separates the CPUs needs a longer foreground job (plan 1.2's > 150 ms). XRAND: the RV twin `p4t17_xr` is `compare` SAME. The 832 twins of seed 931,151,620 (default) and 4 never started (no hw access, the EightThirtyTwo's reset-less state, as `p4t13c_xr`); the twin with `XSEED=1`, `p4t17c_xs1`, passes with halves 1..8 identical. Details: `sim/l3/README.md` "cdda".

### Task 18: Akiko request service on L3 (`akiko`, plan 7.1 item 13)

`sim/l3/bfm_akiko.v` drives cfide's `amiga_req/addr/d/wr` and takes `amiga_q/ack`, as the TG68 side would. Each block is 32 write requests then 32 read requests (one at a time, `amiga_req` held to `amiga_ack`); block 0 runs in the idle main loop, block 1 from the first track DMA's start (`fdd` card, 2 track reads, TICKDIV 643 from the scenario start). RV `p4t18`, 832 `p4t18c3`: all 128 requests acked once, every UART line equal to the pattern computed in Python, every read answered 0, 128 DATA writes, both track reads decode to TEST.ADF, block 1 entirely inside the DMA (64 of 64), MARGIN 6 ok (0 empty slots; FIFO min 995 words RV, 981 words 832), OSD EARLY 0.

Latency, `amiga_req` rise to `amiga_ack`, clk_114 cycles (113.4375 MHz; 1 ms = 113,437 cycles), n = 32 each:

| CPU | block | type | min | median | max | ack to EnableInterrupts (min / median / max) |
|---|---|---|---|---|---|---|
| RV | 0 | write | 224052 | 234004 | 235904 | 4062 / 4082 / 21118 |
| RV | 0 | read | 163856 | 163876 | 163876 | 4062 / 4062 / 4082 |
| RV | 1 | write | 224124 | 234024 | 238856 | 4062 / 4062 / 4598 |
| RV | 1 | read | 163856 | 163876 | 163880 | 4062 / 4062 / 4082 |
| 832 | 0 | write | 209112 | 228736 | 229128 | 22790 / 22914 / 90366 |
| 832 | 0 | read | 158836 | 158956 | 159968 | 22790 / 22814 / 22934 |
| 832 | 1 | write | 218136 | 228100 | 229084 | 22790 / 22834 / 22994 |
| 832 | 1 | read | 158856 | 158960 | 159944 | 22790 / 22814 / 22934 |

The latency is the ISR's `printf` to the UART (115200 baud: ~9,840 `clk_114` per character, 25 characters for a write line, 16 for a read), not the CPU: both CPUs are within ~3 % of each other, and the track DMA changes nothing (block 0 idle loop vs block 1 in the DMA). Median write ~2.0 ms, read ~1.4 ms.

**Finding for Paul: the host Akiko path is a logging stub and is tied off.** `fw/ctrl_rv/akiko.c` (and `fw/ctrl_832/akiko.c`) only print "Akiko write: <addr>, <data>" / "Akiko read: <addr>" and write DATA = 0 (the ack); a read request therefore returns 0. There is no C2P in the host. The real C2P is `rtl/minimig/akiko.v` (Amiga side, `havec2p` in TG68K). `rtl/soc/minimig_virtual_top.v` ties `tg68_host_addr/_d/_wr` to 0 (lines 671-673) and `amigahost_req` is never raised in this build, so on the board the path is unused. Task 18's brief ("C2P output equals the planar conversion") cannot hold; the approved reinterpretation checks the request/ack/print path and the latency.

**Finding for Paul (from the RTL and firmware, NOT confirmed by a run): a request raised between the ISR's DATA write and `EnableInterrupts` is lost.** `inthandler()` (`fw/ctrl_rv/main.c`, the 832's the same) does `DisableInterrupts(); akiko_inthandler(); c64keys_inthandler(); EnableInterrupts();`. cfide's `int_legacy_nx` sets the flag on an `amiga_req` rising edge only when `interrupt_ena` is 1, so a request whose edge comes after the DATA write (the ack of its predecessor) and before the EnableInterrupts write sets no flag, and with `amiga_req` held and no new edge the requester waits forever. The window, measured as ack to the EnableInterrupts write: RV 4,062 cycles (36 us), 832 22,790 cycles (200 us). `bfm_akiko` does not enter the window (it waits for the re-arm, +AKI_GAP 4 clk_28), so the run neither shows nor refutes the loss; a requester that issues the next request sooner than that (a 68k loop, ~1 us per access) would hit it. Only relevant if the host Akiko path is ever connected.

**Differential: empty since Task 19's scenario change (Task 19 ruling).** Task 18's lane pair `p4t18` / `p4t18c3` had 6 timing hunks; after merge 1 (Task 14's drive-ready waits in `bfm_floppy`) 3 were left (`p4m1a` / `p4m1ac`, and Task 19's default-grid pair `p4g_rv_def_akiko` / `p4g_832_def_akiko` on the bench before the change):

- the first drive-status frame `SPI 10 10 00 / 10 01` among block 0's Akiko lines on the 832 (after "C035"), after them on the RV;
- the first key event vs the OSD frames: RV `SPI 20 28 00 / 69 69` (OsdHide, its first MISO byte the KEYQ head) then the KEYQ frame; 832 `20 28 00 / 00 00` before the key, `20 00 / 69` (the level read answers the KEYQ head, "Shared defects"), then the KEYQ frame;
- an end-cut frame: the RV run ended while a status poll frame was in flight (`SPI 10 00 00 00 00 00 / 10 02 44 89 00`, its last byte missing).

Cause (`spi_t.txt`, `uart.txt` of `p4m1a` / `p4m1ac`): block 0 started at the main-loop milestone, before the main loop's first passes. During the ISR's UART-bound burst the RV's main loop does not advance at all (all 64 Akiko lines at frame 2,178: the next request comes 16 `clk_114` after `EnableInterrupts` and the RV takes it at once), while the 832's runs a few frames between requests (lines at frames 2,241 to 2,244). So the first pass's drive status and OsdHide fell inside block 0 on the 832 and after it on the RV (hunks 1 and 2); the end event was not tied to a frame (hunk 3). The change (`scenarios.vh`): block 0 at the 20th HandleFpga frame after the milestone (`AKIKO_PASSES`), the end event at the first HandleFpga frame after block 1 and the last track DMA. Runs `p4t19ak_rv_akiko` (5,746 s, 318.9 M cycles) and `p4t19ak_832_akiko` (7,006 s, 369.8 M cycles): both PASS (128 requests, 64 of block 1 in the DMA, both tracks decode, MARGIN lines), both end on a complete HandleFpga frame, and `run.sh diff --unused-rules` is empty (UNUSED: the hdd and cdda rules only). No normaliser rule was added, so every earlier tooth of the differential still applies.

**XRAND twins.** RV `p4t18_xr` (2,270 s) PASS and `compare p4t18 p4t18_xr` SAME (log, spi.txt: 20,721 frames). 832 `p4t18c3_xr` (3,817 s) PASS with its data checks; `compare` DIFF (cycle numbers) and the normalised `diff p4t18c3 p4t18c3_xr` has one hunk: the 64 `HW ffff84 0000` lines of block 1 sit after rather than before their UART lines around the "Inserting floppy" text (an ordering of the UART printer vs the DATA write, timing only). Accepted per scenario-rulings.md (the 832's reset-less start-up state), recorded here. Note: the 832 UART prints hex in upper case although its source says `%x` (lib832), so no SUBST rule for the "Akiko" lines was needed; `diff --unused-rules p4t18 p4t18c3` reports `rules: all 13 used`.

### Task 19: differential, stress grid, margins, teeth (plan 4.1 / 4.2 gate)

Tree `osd-riscv` 23b86db (the RETIRED instrumentation 1b4da86 and the grid tooling 23b86db in), Verilator, one RV image (`RV32OSDA.BIN` 17bf2563, `run_fw14`) and one 832 image (`832OSDAD.BIN` 768c765d, `run_fw12`) on every card. `bash sim/l3/grid.sh p4g` (README "Stress grid"): 60 runs, six simulations at most on the machine (the cap was 2 while Vivado ran: 10:10-11:12 and from 21:54, when the grid stopped its own simulators), one Verilator build per configuration (five: RV `EXTRA_WS` 0, 4, 16, 64 and the 832). Wall time 69,004 s (19.2 h, 07:34 to 02:44, with the teeth and the akiko evidence runs on the same slots); simulation ran at 0.04 to 0.12 M cycles/s per run with six on the machine (4 cores, 8 threads).

**Gate: every grid run PASS.** 59 of 60 on the first pass; the 60th, `p4g_rv_ws64_fdd_rd`, ended at cycle 178 because its `TIMEOUT` bound (2,261 M) wrapped the bench's 32-bit integer (a bench fault: run.sh now refuses a `TIMEOUT` above 2,147,483,647, 249508e) and passed when re-run with 2,147 M as `p4gx_rv_ws64_fdd_rd`. No run has an `EXC` / `TRAP`, a MARGIN `LOW` or a data check failure; no latency-bound item went `LOW`, not even at `EXTRA_WS` 64.

#### Differential

`run.sh diff --unused-rules` of every RV / 832 pair of the same scenario and grid point (both runs on the same card):

| Pair | Diff |
|---|---|
| default: `boot`, `keys`, `fdd_rd`, `fdd_wr`, `hdd`, `cd` (cue), `cd` (iso), `cdda`, `cdda_load` | empty |
| default: `akiko` (`p4g_rv_def_akiko` / `p4g_832_def_akiko`, the bench before 31a54db) | 3 timing hunks (Task 18 above: the first main-loop pass inside block 0 on the 832 only, an end-cut frame) |
| `akiko` with 31a54db's scenario (`p4t19ak_rv_akiko` / `p4t19ak_832_akiko`) | empty |
| skew (0.3, 4.0) and (9.5, 0.3): `fdd_rd`, `hdd` | empty |

Unused rules: each pair's `UNUSED` list names only other scenarios' rules (`hdd`'s three UART rules, the floppy rules, the cdda `DROPBLOCK`); no rule of `expected_diff.txt` is unused in all ten default pairs, so none is removed (Task 7 ruling). `p4g_rv_def_boot` is byte-identical to `p4m2b` in `spi.txt`, `hw.txt` and `uart.txt`, and `p4g_rv_def_fdd_wr` to `p4t14f`: the RETIRED counter changes no trace.

#### Stress grid

Runs (RUNTAG, verdict, wall s, simulated s, end cycle):

| RUNTAG | verdict | wall | sim | cycles |
|---|---|---|---|---|
| p4g_832_def_akiko | akiko PASS | 7212 | 7194 | 369621955 |
| p4g_832_def_boot | boot PASS | 3455 | 3407 | 202841141 |
| p4g_832_def_cd | cd PASS | 4124 | 4071 | 233680101 |
| p4g_832_def_cdda | cdda PASS | 11684 | 11662 | 407815893 |
| p4g_832_def_cdda_load | cdda_load PASS | 11435 | 11381 | 407912613 |
| p4g_832_def_cdiso | cd PASS | 3756 | 3720 | 212934613 |
| p4g_832_def_fdd_rd | fdd_rd PASS | 7627 | 7591 | 502284387 |
| p4g_832_def_fdd_wr | fdd_wr PASS | 10469 | 9400 | 520161170 |
| p4g_832_def_hdd | hdd PASS | 4182 | 4146 | 233511253 |
| p4g_832_def_keys | keys PASS | 3762 | 3723 | 215391649 |
| p4g_832_sk0340_fdd_rd | fdd_rd PASS | 8283 | 8260 | 502284387 |
| p4g_832_sk0340_hdd | hdd PASS | 10397 | 10381 | 233511253 |
| p4g_832_sk9503_fdd_rd | fdd_rd PASS | 10166 | 10149 | 502284387 |
| p4g_832_sk9503_hdd | hdd PASS | 3940 | 3878 | 233511269 |
| p4g_rv_def_akiko | akiko PASS | 4841 | 4823 | 318788355 |
| p4g_rv_def_boot | boot PASS | 2610 | 2569 | 158213821 |
| p4g_rv_def_cd | cd PASS | 2612 | 2578 | 185264325 |
| p4g_rv_def_cdda | cdda PASS | 5690 | 5628 | 337251973 |
| p4g_rv_def_cdda_load | cdda_load PASS | 5569 | 5508 | 337317973 |
| p4g_rv_def_cdiso | cd PASS | 2368 | 2342 | 171314533 |
| p4g_rv_def_fdd_rd | fdd_rd PASS | 8415 | 8358 | 453775267 |
| p4g_rv_def_fdd_wr | fdd_wr PASS | 7442 | 7388 | 470697761 |
| p4g_rv_def_hdd | hdd PASS | 2726 | 2705 | 188076757 |
| p4g_rv_def_keys | keys PASS | 2730 | 2722 | 165068169 |
| p4g_rv_fast_boot | boot PASS | 1445 | 1387 | 151181149 |
| p4g_rv_fast_cd | cd PASS | 1751 | 1742 | 177045413 |
| p4g_rv_fast_hdd | hdd PASS | 1814 | 1800 | 180641269 |
| p4g_rv_fast_keys | keys PASS | 1508 | 1450 | 157997173 |
| p4g_rv_sj8_cdda | cdda PASS | 11605 | 11579 | 343480325 |
| p4g_rv_sj8_hdd | hdd PASS | 3033 | 3005 | 193039381 |
| p4g_rv_sk0205_fdd_rd | fdd_rd PASS | 7141 | 7071 | 453775267 |
| p4g_rv_sk0205_hdd | hdd PASS | 3035 | 2985 | 188076757 |
| p4g_rv_sk0205_keys | keys PASS | 2430 | 2364 | 165068169 |
| p4g_rv_sk0340_fdd_rd | fdd_rd PASS | 7445 | 7404 | 453775267 |
| p4g_rv_sk0340_hdd | hdd PASS | 3093 | 3049 | 188076757 |
| p4g_rv_sk0340_keys | keys PASS | 2369 | 2320 | 165067341 |
| p4g_rv_sk0502_fdd_rd | fdd_rd PASS | 7078 | 7058 | 453775267 |
| p4g_rv_sk0502_hdd | hdd PASS | 3034 | 2975 | 188076757 |
| p4g_rv_sk0502_keys | keys PASS | 2431 | 2403 | 165068169 |
| p4g_rv_sk4003_fdd_rd | fdd_rd PASS | 7507 | 7463 | 453775267 |
| p4g_rv_sk4003_hdd | hdd PASS | 3159 | 3109 | 188076757 |
| p4g_rv_sk4003_keys | keys PASS | 2369 | 2344 | 165068169 |
| p4g_rv_sk9503_fdd_rd | fdd_rd PASS | 7690 | 7621 | 453775267 |
| p4g_rv_sk9503_hdd | hdd PASS | 3220 | 3146 | 188076757 |
| p4g_rv_sk9503_keys | keys PASS | 2183 | 2128 | 165068169 |
| p4g_rv_ws16_boot | boot PASS | 2851 | 2803 | 200665364 |
| p4g_rv_ws16_cdda | cdda PASS | 5813 | 5759 | 391054373 |
| p4g_rv_ws16_fdd_rd | fdd_rd PASS | 9680 | 8637 | 511349731 |
| p4g_rv_ws16_fdd_wr | fdd_wr PASS | 8417 | 8335 | 530137717 |
| p4g_rv_ws16_hdd | hdd PASS | 3395 | 3358 | 233647925 |
| p4g_rv_ws4_boot | boot PASS | 2491 | 2478 | 167680228 |
| p4g_rv_ws4_cdda | cdda PASS | 9550 | 9485 | 349345941 |
| p4g_rv_ws4_fdd_rd | fdd_rd PASS | 8292 | 6981 | 466734243 |
| p4g_rv_ws4_fdd_wr | fdd_wr PASS | 7379 | 7341 | 484070981 |
| p4g_rv_ws4_hdd | hdd PASS | 2902 | 2837 | 198620485 |
| p4g_rv_ws64_boot | boot PASS | 4668 | 4615 | 324131704 |
| p4g_rv_ws64_cdda | cdda PASS | 8706 | 8684 | 547160773 |
| p4g_rv_ws64_fdd_rd | fdd_rd FAILED | 1031 | 3 | 178 |
| p4g_rv_ws64_fdd_wr | fdd_wr PASS | 11196 | 11181 | 705763493 |
| p4g_rv_ws64_hdd | hdd PASS | 5868 | 5847 | 366586213 |
| p4gx_rv_ws64_fdd_rd | fdd_rd PASS | 9153 | 9087 | 679671139 |


What the grid points change (the RV unless named): `EXTRA_WS` 64 roughly doubles the boot (main loop at about 404 M cycles on the `fdd` card instead of 194 M) and slows every latency-bound path, yet the floppy read FIFO keeps 892 words at least (item 6, 0 empty slots), the write FIFO is never full (item 7), and every CD-DA half is refilled in time. The skew pairs change nothing the firmware sees: `fdd_rd` and `hdd` end at the same cycle on all five pairs (453,775,267 and 188,076,757), `keys` within 828 cycles. `+FAST_HW=1` shortens `boot` to 151.2 M cycles; OSD GAP stays 43 and OSD EARLY 0. `SJIT` 8 costs `hdd` 5 M cycles and `cdda` 2.5 ms per fill.

CD-DA (ruling 5: the underrun gate gets its teeth from the `EXTRA_WS` sweep). A half is 8,192 frames, 185.8 ms at 44.1 kHz:

| Run | underruns | fill min / median / max (ms) |
|---|---|---|
| RV `cdda` `EXTRA_WS` 0 | 0 | 4.667 / 42.811 / 42.847 |
| RV `cdda` `EXTRA_WS` 4 | 0 | 5.789 / 47.627 / 47.679 |
| RV `cdda` `EXTRA_WS` 16 | 0 | 9.262 / 64.109 / 64.394 |
| RV `cdda` `EXTRA_WS` 64 | 0 | 23.552 / 126.168 / 126.332 |
| RV `cdda` `SJIT` 8 | 0 | 5.836 / 45.308 / 45.346 |
| 832 `cdda` default | 0 | 21.732 / 88.147 / 88.156 |
| RV `cdda_load` default | 0 | 4.664 / 42.818 / 43.355 |
| 832 `cdda_load` default | 0 | 21.791 / 88.139 / 96.694 |

The RV at `EXTRA_WS` 16 still fills faster than the 832 at default; at 64 it is 43 % slower than the 832 and keeps 59 ms of a half. The 832 has no `EXTRA_WS`.

#### Margins

`python3 -I sim/l3/margins.py sim/l3/run_p4g*` (60 runs; the overflowed `p4g_rv_ws64_fdd_rd` is left out as incomplete, its re-run `p4gx` counts). Rows: plan 7.1 items (and CD-DA); columns: CPU x grid point; a cell is the worst value over that point's runs, its verdict and the scenario. Counts (1, 2 early, 5, 6, 7, underruns): the largest; times: the smallest. Units: items 3, 4, 7 gap, 8, 9, 14 `clk_114`; 12 ns; CD-DA ms; 13 `clk_114`; 6 words.

| item | measurement | rv default | 832 default | rv FAST_HW | rv SJIT 8 | rv sk 0.2/0.5 | rv sk 0.3/4 | rv sk 0.5/0.2 | rv sk 4/0.3 | rv sk 9.5/0.3 | rv ws16 | rv ws4 | rv ws64 | 832 sk 0.3/4 | 832 sk 9.5/0.3 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | stale_acks | 0 ok (akiko) | 0 ok (akiko) | 0 ok (boot) | 0 ok (cdda) | 0 ok (fdd_rd) | 0 ok (fdd_rd) | 0 ok (fdd_rd) | 0 ok (fdd_rd) | 0 ok (fdd_rd) | 0 ok (boot) | 0 ok (boot) | 0 ok (boot) | 0 ok (fdd_rd) | 0 ok (fdd_rd) |
| 2 | osd_gap | 43 ok (akiko) | 254 ok (akiko) | 43 ok (keys) | 59 ok (cdda) | 43 ok (fdd_rd) | 43 ok (fdd_rd) | 43 ok (fdd_rd) | 43 ok (fdd_rd) | 43 ok (fdd_rd) | 55 ok (boot) | 51 ok (fdd_rd) | 151 ok (boot) | 254 ok (fdd_rd) | 254 ok (fdd_rd) |
| 2 | osd_early | 0 ok (akiko) | 0 ok (akiko) | 0 ok (boot) | 0 ok (cdda) | 0 ok (fdd_rd) | 0 ok (fdd_rd) | 0 ok (fdd_rd) | 0 ok (fdd_rd) | 0 ok (fdd_rd) | 0 ok (boot) | 0 ok (boot) | 0 ok (boot) | 0 ok (fdd_rd) | 0 ok (fdd_rd) |
| 3 | dmode_release | 20.8 ok (cdda_load) | 42.8 ok (cdda_load) | 20.8 ok (hdd) | 20.8 ok (hdd) | 21 ok (hdd) | 21 ok (hdd) | 20.9 ok (hdd) | 20.5 ok (hdd) | 19.9 ok (hdd) | 53.8 ok (hdd) | 30.8 ok (hdd) | 150.8 ok (hdd) | 43 ok (hdd) | 41.9 ok (hdd) |
| 3 | dmode_L | 6 rec (cdda_load) | 34 rec (cdda_load) | 6 rec (hdd) | 6 rec (hdd) | 6 rec (hdd) | 6 rec (hdd) | 6 rec (hdd) | 6 rec (hdd) | 6 rec (hdd) | 22 rec (hdd) | 10 rec (hdd) | 70 rec (hdd) | 34 rec (hdd) | 34 rec (hdd) |
| 4 | paula_cs_release | 10.8 ok (akiko) | 3.8 ok (akiko) | 10.8 ok (boot) | 10.8 ok (cdda) | 11 ok (fdd_rd) | 11 ok (fdd_rd) | 10.9 ok (fdd_rd) | 10.5 ok (fdd_rd) | 9.9 ok (fdd_rd) | 26.8 ok (boot) | 14.8 ok (boot) | 97.8 ok (cdda) | 4 ok (fdd_rd) | 2.9 ok (fdd_rd) |
| 4 | userio_cs_release | 10.8 ok (akiko) | 3.8 ok (akiko) | 10.8 ok (boot) | 10.8 ok (cdda) | 11 ok (fdd_rd) | 11 ok (fdd_rd) | 10.9 ok (fdd_rd) | 10.5 ok (fdd_rd) | 9.9 ok (fdd_rd) | 24.8 ok (boot) | 12.8 ok (boot) | 96.8 ok (boot) | 4 ok (fdd_rd) | 2.9 ok (fdd_rd) |
| 4 | paula_word_spacing | 114 ok (akiko) | 98 ok (akiko) | 115 ok (boot) | 114 ok (cdda) | 114 ok (fdd_rd) | 114 ok (fdd_rd) | 114 ok (fdd_rd) | 114 ok (fdd_rd) | 114 ok (fdd_rd) | 142 ok (boot) | 118 ok (boot) | 160 ok (hdd) | 98 ok (fdd_rd) | 98 ok (fdd_rd) |
| 4 | userio_byte_spacing | 57 ok (akiko) | 49 ok (akiko) | 57 ok (boot) | 57 ok (cdda) | 57 ok (fdd_rd) | 57 ok (fdd_rd) | 57 ok (fdd_rd) | 57 ok (fdd_rd) | 57 ok (fdd_rd) | 70 ok (boot) | 58 ok (boot) | 141 ok (boot) | 49 ok (fdd_rd) | 49 ok (fdd_rd) |
| 5 | spi_write_busy | 0 ok (akiko) | 0 ok (akiko) | 0 ok (boot) | 0 ok (cdda) | 0 ok (fdd_rd) | 0 ok (fdd_rd) | 0 ok (fdd_rd) | 0 ok (fdd_rd) | 0 ok (fdd_rd) | 0 ok (boot) | 0 ok (boot) | 0 ok (boot) | 0 ok (fdd_rd) | 0 ok (fdd_rd) |
| 6 | fdd_fifo_empty_dma | 0 ok (akiko) | 0 ok (akiko) | n/a | n/a | 0 ok (fdd_rd) | 0 ok (fdd_rd) | 0 ok (fdd_rd) | 0 ok (fdd_rd) | 0 ok (fdd_rd) | 0 ok (fdd_rd) | 0 ok (fdd_rd) | 0 ok (fdd_rd) | 0 ok (fdd_rd) | 0 ok (fdd_rd) |
| 6 | fdd_fifo_min_words | 995 rec (akiko) | 955 rec (fdd_rd) | - | - | 995 rec (fdd_rd) | 995 rec (fdd_rd) | 995 rec (fdd_rd) | 995 rec (fdd_rd) | 995 rec (fdd_rd) | 980 rec (fdd_rd) | 984 rec (fdd_rd) | 892 rec (fdd_rd) | 955 rec (fdd_rd) | 955 rec (fdd_rd) |
| 7 | fdd_fifo_full_write | 0 ok (fdd_wr) | 0 ok (fdd_wr) | n/a | n/a | n/a | n/a | n/a | n/a | n/a | 0 ok (fdd_wr) | 0 ok (fdd_wr) | 0 ok (fdd_wr) | n/a | n/a |
| 7 | fdd_wr_word_gap | 202 ok (fdd_wr) | 85 ok (fdd_wr) | - | - | - | - | - | - | - | 473 ok (fdd_wr) | 269 ok (fdd_wr) | 1,313.1 ok (fdd_wr) | - | - |
| 8 | ide_wait | 32 rec (hdd) | 64 rec (cdda_load) | 48 rec (hdd) | 48 rec (hdd) | 32 rec (hdd) | 32 rec (hdd) | 32 rec (hdd) | 32 rec (hdd) | 32 rec (hdd) | 48 rec (hdd) | 16 rec (hdd) | 48 rec (hdd) | 64 rec (hdd) | 64 rec (hdd) |
| 9 | cd_timeout_left | 6,583,629,248 ok (cd iso) | 6,583,605,856 ok (cd iso) | 6,584,159,632 ok (cd cue) | 6,584,315,680 ok (cdda) | n/a | n/a | n/a | n/a | n/a | 6,584,313,760 ok (cdda) | 6,584,315,344 ok (cdda) | 6,584,306,256 ok (cdda) | n/a | n/a |
| CD-DA | cdda_underruns | 0 ok (cdda) | 0 ok (cdda) | - | 0 ok (cdda) | - | - | - | - | - | 0 ok (cdda) | 0 ok (cdda) | 0 ok (cdda) | - | - |
| CD-DA | cdda_fill_max_ms | 43.355 rec (cdda_load) | 96.694 rec (cdda_load) | - | 45.346 rec (cdda) | - | - | - | - | - | 64.394 rec (cdda) | 47.679 rec (cdda) | 126.332 rec (cdda) | - | - |
| 12 | rtc_cs_high | 558,460,866.2 rec (fdd_rd) | 1,317,505,453.8 rec (fdd_rd) | n/a | 786,723,292.4 rec (cdda) | 558,460,866.2 rec (fdd_rd) | 558,452,191.2 rec (fdd_rd) | 558,460,866.2 rec (fdd_rd) | 558,460,866.2 rec (fdd_rd) | 558,460,866.2 rec (fdd_rd) | 1,445,592,271.4 rec (fdd_rd) | 760,634,315.2 rec (fdd_rd) | n/a | 1,317,505,453.8 rec (fdd_rd) | 1,317,505,453.8 rec (fdd_rd) |
| 13 | akiko_req_ack_max | 238,392 rec (akiko) | 229,128 rec (akiko) | - | - | - | - | - | - | - | - | - | - | - | - |
| 14 | kick_order | 6,864,999 ok (boot) | 13,589,729 ok (boot) | 5,835,953 ok (boot) | 7,535,459 ok (hdd) | 6,864,999 ok (keys) | 6,864,999 ok (keys) | 6,864,999 ok (keys) | 6,864,999 ok (keys) | 6,864,999 ok (keys) | 10,285,699 ok (hdd) | 7,662,367 ok (boot) | 20,275,707 ok (boot) | 13,594,665 ok (fdd_rd) | 13,594,665 ok (fdd_rd) |
| 15 | keys_check | PASS (keys) | PASS (keys) | PASS (keys) | - | PASS (keys) | PASS (keys) | PASS (keys) | PASS (keys) | PASS (keys) | - | - | - | - | - |
| 10 | - | SD protocol waits: closed in Phase 3 (TIMER waits); no L3 monitor |
| 11 | - | SPIN / delays: grep gate (Phase 3, Task 11); no L3 monitor |

runs: 60; LOW: none

Notes: item 2 is the OSD reply gap (bound 40, OSD EARLY 0 required); since Task 11 the RV waits on `OSD_RDY`, so 43 is the handshake's spacing, not a margin to an edge. Item 3 at default: RV 20.8, 832 42.8 `clk_114` from the 4,096th edge to the release (bound 0 since 202e077; tooth (a) shows the race without it). Item 4's release figures are bound 0 (README "Item 4"); the 832 at skew (9.5, 0.3) has the smallest, 2.9. Item 8 is status-driven (`rec`); item 9 keeps 99.99 % of `CD_TIMEOUT` in every run. Item 12: the PCF2123 datasheet minimum is unknown (bound 0, `rec`). Item 13 (Akiko) is UART-bound: 238,392 vs 229,128 `clk_114`. Items 10 and 11 have no L3 monitor (Phase 3 closed them).

#### Teeth

Each must fail; all do.

| Tooth | Run | Result |
|---|---|---|
| (a) 202e077 reverted in `paula_floppy.v` (`teeth/paula_202e077.sh`) | `p4t19_rv_ta`, `hdd` | FAILS: the data check (command 3 READ: LBA 101 differs at byte 510, the following sectors shifted; the plan stops after command 7 with BSY/DRQ errors, `TIMEOUT`). Item 3 itself reads 20.8 ok: it measures the release, which the revert does not move; the data check is this tooth's evidence, at the default point (no escalation needed) |
| (b) bridge without the four-phase handshake + fast master (`teeth/bridge_2phase.sh`) | `p4t19_rv_tb`, `boot_short`, `TIMEOUT` 10 M | FAILS: `MARGIN 1 stale_acks min 1184 count (bound 0, LOW)` over 2,510 hw accesses (as Task 5's p4t5r1e) |
| (c) `fdd.c` `SendSector` one word short (`teeth/fwmut.sh`, image 91c96027) | `p4t19_rv_tc`, `fdd_rd` | FAILS: `l3check.py fdd_rd` 122 problems (data checksum of every sector) |
| (d) cfide `osd_rdy` forced 1 + `FAST_HW` | Task 12's `p4t12m1c` (reused, ruling) | FAILS: `OSD EARLY 1 of 450`, keys check |
| (e) `GAYLE_MUT_SHARED` (`teeth/gayle_shared.sh`) | `p4t19_rv_te`, `hdd`; `p4t19e_rv_te2`, `cdda_load` | `hdd` PASSES, trace byte-identical to `p4m2h`: the plan uses gayle port 0 only (both units on it), so a shared register file is not seen. `cdda_load` (CD on port 1, HDFs on port 0) FAILS: the CD's packet phase gets ERR / no DRQ, the plan never ends (`TIMEOUT`) |
| (f) `cdaudio.c` cursor one frame short per half (image 552dfa26) | `p4t19_rv_tf`, `cdda` | FAILS: 7 wrong halves (`l3check.py cdda`: half 3 on differs from byte 0) |
| (g) one SD data byte changed in the 832 run's `spi.txt` (`teeth/sdbyte.sh`) | offline, `p4g_rv_def_hdd` / `p4g_832_def_hdd` | FAILS: the diff shows the CMD17 of LBA 0x80c with another block hash |
| (h) the RV image before the write-FIFO fix (0162e53f) | `p4t19_rv_th`, `fdd_wr` | FAILS: item 7's word-gap monitor, `min 22.0 clk_114 over 4287 words (bound 64), 4284 below`, bench errors, `TIMEOUT` |

The firmware copies of (c) and (f) are built by `teeth/fwmut.sh`; the same procedure without the sed reproduces the tree's 17bf2563.

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

- **`HandleFpga()` hands byte 5 of the status frame to `HandleFDD()` as the drives' motor bits even while paula puts the DMA length there (both firmwares; found by Task 13, not fixed: parity).** `fw/ctrl_rv/main.c` `HandleFpga` (the same in `fw/ctrl_832`) reads six bytes and passes the 5th and 6th as `c3`, `c4`. paula_floppy's word 2 is `{12'd0, motor_on}` only without a DMA; during a track read it is `{dmaen, dsklen}` (`spi_tx_data_2`). When the status shows no request (the FIFO above 1,024 words, or the frame that starts the DMA), `HandleFDD` takes `c4` = `dsklen`'s low byte as the motor bits: `df[].motor` follows bits of the remaining length, and `drivesounds_queueevent(MOTORSTART / MOTORSTOP)` fires on them. Evidence: `fdd_rd` `p4t13` / `p4t13c`, the status polls `10 02 44 89 92 61`, `.. 90 41`, ... during a read (bit 0 of `61` = motor on, of `be` = off); the RV's DMA-start frame `10 00 44 89 98 be` (motor "off") where the 832's shows `00 01` (README "fdd_rd", the two lines left in the diff). Board effect (from the source): spurious motor start / stop drive sounds during floppy reads. Fix option: use `c3` / `c4` as motor bits only when `c3` bit 7 (dmaen) is 0, or have paula report the motor in a byte of its own.
- **A READ / WRITE MULTIPLE before any SET MULTIPLE on its unit hangs the firmware (both firmwares; found by reading `hdd.c` for Task 15, not run, not fixed: parity).** `hdf[unit].sectors_per_block` is 0 until `ATA_SetMultipleMode` sets it, and `ATA_ReadSectors` / `ATA_WriteSectors` (`fw/ctrl_rv/hdd.c:521`, `:633`; `fw/ctrl_832/hdd.c:503`, `:615`) clamp each DRQ block to it: a block of 0 sectors, `sector_count -= 0`, so the loop never ends and the main loop stops (OSD, floppy, CD dead) until the Amiga is reset. ATA says such a command is aborted. Board effect: only with a driver that skips SET MULTIPLE (scsi.device and the usual IDE drivers send it first; the L3 `hdd` plan does too, for both units). Fix option: treat `sectors_per_block` 0 as 1, or abort (`IDE_STATUS_ERR`, error ABRT) as for an unknown command.

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

### Found by the L3 bench (Task 14, 2026-10-19)

**paula_floppy's write FIFO sends a stale word to a host that reads it quickly: without a gap the RV firmware cannot write a floppy track on this RTL (the 832 can). RTL not changed (Decision 8); fixed in the RV firmware (option (b) below, chosen 2026-10-19 22:10: Paul "fix floppy write before I'll try it", controller ruling), the RTL defect stays on Paul's backlog.**

- **Mechanism (`rtl/minimig/paula_floppy.v`, `paula_floppy_fifo.v`).** During a track write the host reads the FIFO through word 3 of a status frame: `spi_tx_data_3 = fifo_out` is loaded into `spi_sdo_reg` at the first falling `sck` edge of each word (`spi_bit_cnt == 0`), and the word just read is popped by `fifo_rd = trackwr & spidat`, i.e. after the received word has gone through the `rx_flag` synchroniser (`clk7n_en`, then `clk7_en`: up to about 1.5 clk7), then the pointer update (1 clk7), then the FIFO's registered `out = mem[out_ptr]`, which reads the old pointer (1 more clk7). If the host starts the next word before that (about 56 to 64 `clk_114` after the last edge of the previous word), the next word's register gets the previous word again; the FIFO still pops one word per word read, so that word is lost. The read path (`fdd_rd`) is not affected (the host writes the FIFO there), and item 4's `paula_word_spacing` bound (40, derived for the receive synchroniser) does not cover this transmit path.
- **Unit evidence (scratch iverilog bench, not committed: `bfm_floppy.v` + the RTL + an SPI reader that reads exactly the FIFO's count per frame, one track of `mkwrtrack.py`'s stream):** a gap of 64 `clk_114` or more between words: 6,334 of 6,334 words right; 48 or less: about 3,500 wrong, each the previous word repeated.
- **L3 evidence (`fdd_wr`, the same card and images):** the 832 (`p4t14c`, about 220 to 400 `clk_114` per word in its `WriteTrack` frames) reads all 10 tracks exactly (the stream it read = the stream Agnus wrote, 12,668 bytes on track 0/0; `TEST.ADF` on the saved card right). The RV (`p4t14w`, about 124 `clk_114` per word including the 16 bits) reads 12,670 bytes on track 0/0 with stale words from byte 704 (`aa aa` where the first `44 89` sync is, `aa a5` again where `55 2a` is): `GetHeader` fails on every sector ("Second sync word missing...", error 21; "Wrong header: 221.2.2..."), no sector of the track is written, and the FatalError loop (no `HandleFpga` while `ErrorFatal`) stops the floppy, so the next DMA never starts (timeout at 700 M).
- **Board effect (from the bench; board not tested):** with the RV firmware an Amiga floppy write (any trackdisk write, a format, a save to df0:) ends in a FATAL ERROR page and writes nothing, at least at the bench's CPU speed (`EXTRA_WS` 0). The 832 is slow enough not to see it.
- **Evidence fix (bench run copy only, `sim/l3/run.sh PAULA_TXPOP=1`; `rtl/` untouched):** pop a track write's FIFO word when its transmission starts instead of after it was received, as Gayle's `hdd_data_rd` does: `assign fifo_rd = (busrd & dmaon) | (trackwr & cmd_fdd & tx_flag & tx_cnt==2'd3);` in place of `... | (trackwr & spidat);`. The next word's load then comes a whole word after the pop. Unit bench with the patch: 6,334 of 6,334 words right at every gap tried, 128 down to 16 `clk_114`. The L3 run with this patch (planned as `p4t14e`) was dropped when option (b) was chosen.
- **Chosen: (b), firmware pacing** (commits `6ea1b76`, `17dcb50`): `WRFIFO_GAP` in `fw/ctrl_rv/hardware.h`, 16 TIMER reads (each a cfide access, at least two `clk_28` edges = 8 `clk_114`, so at least 128 `clk_114` whatever the CPU's speed) before every word `fdd.c` reads from the write FIFO, 20 sites; the one listed exception to "No new count-based delays" (`fw/ctrl_rv/README.md` "Write-FIFO gap"). Evidence: `p4t14f` (RV, the fixed image 17bf2563) `fdd_wr` PASS, the gap measured at the slave at least 202 `clk_114` over 61,221 words (bound 64), the twin `p4t14f_xr` SAME. The image is on the board card set `build/ab_card_87577e2` (bitstream B unchanged).
- **The options:** (b), the RV firmware's gap between the words it reads from the write FIFO, was chosen on 2026-10-19 22:10 by Paul and the controller and made the listed exception to "No new count-based delays" (the bullet above). (a) and (c) stay open on Paul's backlog: (a) RTL: give `spi_tx_data_3` the word after the one being popped (a first-word-fall-through FIFO output, `assign out = mem[out_ptr]`, or pop on `tx_flag` at the start of the word as `hdd_data_rd` does for Gayle), or hold the next load until the pop is through; (c) a handshake bit as for userio_osd (Tasks 9-11). Either would let the firmware gap go.

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

(Each run with `+VERBOSE=1 +TIMEOUT=3000`, seed 7 of `p4t6_xr` with 400,000; the seed's mapping to the state changes with the binary.) Task 13 adds one more: the `fdd_rd` twin `p4t13c_xr` (seed 1528826596) made no hw access and no SDRAM read in 660 M cycles; `run_p4t13c_hang` (`boot_short`, `XSEED=1528826596`, `TIMEOUT=3000000`) reproduces it in 16 s (`HW accesses 0`). The `XSEED=4` twin `p4t13c_xs4` started like the plain run, was cycle-identical up to `spi.txt` frame 31,795 (cycle 389,813,554, during track 78/0's DMA) and then 4 `clk_114` late to the end, with `hw.txt`, every MOSI byte and the floppy dumps equal (33 sector frames differ in paula's `dsklen` MISO bytes only; the normalised diff is empty). Not traced to the flop. Candidate: `fw/ctrl_832/drivesounds.c` `pickstep()` reads its local `count` before setting it (`while(count>maxactive)`, a known -Wextra warning), so the number of loop passes, and the 832's timing, depends on whatever the stack slot or register held, which XRAND randomises. Until the first hw access only the bridge, the 832 core and its boot ROM BRAM run; the bridge's three reset-less flops of Task 2 (`cache_req`, `cpu_ack`, `rom_wr`) are pinned, so the cause is other reset-less state in the EightThirtyTwo (`E832` RTL: the register file and the `thread` fields the reset leaves alone, beyond the seven the GHDL conversion copy resets; the decoder / fetch state) or in the 832 path of `832_bridge.vhd`. The board starts every flop at 0 (configuration), so power-up is fine; a warm `nReset` while the CPU runs is the open question, as for Task 2's five flops. Task 6's `boot` twin was SAME only because its seed happened to give the normal start. Bench handling: none yet; the 832 twins of later tasks will differ in timing the same way unless the state is found and pinned (a later task's or Paul's call). Task 8 shows the `keys` path X-insensitive with `XSEED=4` (`p4t8c_xs4` SAME).

### Found by the L3 bench (Task 15, 2026-10-19)

**`rtl/minimig/gayle_port.v` `tfr[7:0]` (the task file, line 149) and `rtl/minimig/gayle_fifo.v` `mem` (the sector buffer, line 19) have no reset and no initial value.** The firmware's `ReadTaskFile()` of the first IDE command reads all eight registers: register 0 is the FIFO's head word (`fifo_data_out`) and register 1 the features register, which an ATA host does not write. Under random init the RV `hdd` twin `p4t15_xr` (seed of RUNTAG `p4t15_xr`) differed from `p4t15` in that one frame only: `10 80 ... / 14 01 44 89 00 00 2c bc 2c 39 ...` instead of `/ ... 00 00 2c 00 ...` (`spi.txt` line 6,593); everything else, the log included, was SAME. The ATA path ignores both values (`hdd.c` uses registers 2..7), so the data was right in both runs. The board starts the registers and the BRAM at 0 (configuration); not a board defect, like `dsktrack` below. Bench handling: `XRAND=1` pins both arrays to 0 at time 0 in the run copies (`run.sh l3_pin_minimig`, 8 + 4,096 entries per port: `=== XRAND pinned` grows by 8,208); the twin is then SAME (`p4t15_xr2`, sim/l3 README "hdd").

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


## Task 20 / I-cache

Status: done. The plan 4.5 gate tripped (Decision 7) and Paul ruled on it (see the decision line); nothing regenerated, no RTL change, no new simulation (every figure below is read from the existing Task 19 default-grid runs).

Source: default-grid RV runs `sim/l3/run_p4g_rv_def_{boot,fdd_rd,hdd,cdda,keys}`: `STATS@win_start` / `STATS@win_end`
in `run.out`, `=== RETIRED` in the run's `*.log` (instrumentation 1b4da86). A refill is one iBus command (size 5 = 8 words).

| Scenario (window) | Run dir | refills | retired | refills / retired | 8 x refills / retired | window cycles | retired / cycle |
|---|---|---|---|---|---|---|---|
| boot (1st..21st HandleFpga frame) | run_p4g_rv_def_boot | 748 | 8,298 | **9.01 %** | 0.721 | 113,224 | 0.073 |
| fdd_rd (1st..last track DMA) | run_p4g_rv_def_fdd_rd | 1,108,249 | 14,617,607 | **7.58 %** | 0.607 | 193,659,710 | 0.075 |
| cdda (flip 2..6) | run_p4g_rv_def_cdda | 427,808 | 5,887,507 | **7.27 %** | 0.581 | 84,279,296 | 0.070 |
| keys (1st..last key) | run_p4g_rv_def_keys | 19,258 | 682,199 | 2.82 % | 0.226 | 6,963,988 | 0.098 |
| hdd (1st..last command) | run_p4g_rv_def_hdd | 8,622 | 950,312 | 0.91 % | 0.073 | 24,375,168 | 0.039 |

Decision line: **4 KB kept (Paul 2026-10-21: match the original 68040's 4 KB I-cache) at main-loop miss ratios boot 9.0 %, fdd_rd 7.6 %, cdda 7.3 %** (gate: above 5 % on any scenario; keys 2.8 %, hdd 0.9 %).
The boot window is short (8.3 k instructions) and cold, so cold misses weigh heavily; fdd_rd and cdda are long
steady-state windows and are the real signal. A real 68040 has 4 KB I + 4 KB D, so the I-cache stays 4 KB: no 8 KB regeneration, no OOC, no RTL change.

STATS cut at the end condition (exec-3 hand-over item 10): satisfied by the `STATS@win_start` / `STATS@win_end` lines and the `=== RETIRED` lines printed with them (commit 1b4da86); the tables here use the window deltas, not the whole-run `=== STATS` line.

Ring fill (Task 19, CD-DA): RV max fill 42.85 ms at default against 88.16 ms for the 832 (half = 185.8 ms), 0 underruns:
RV <= 832 holds.

## Speed (plan 4.4)

`python3 -I sim/l3/speed.py sim/l3/run_p4g_rv_def_<scenario> sim/l3/run_p4g_832_def_<scenario>` reads `spi_t.txt`, the run's `tb_*.log` and `results.txt` of the existing default-grid runs (Task 19, `SLAT=8 SJIT=0`, same card and same firmware images for both CPUs per scenario); self-test `python3 -I sim/l3/speed.py --selftest`. Cycles are `clk_114` (113.4375 MHz).

| Figure | RV | 832 | Source and definition |
|---|---|---|---|
| SPI byte loop, ns per byte | **1,018** (min 913 in fdd_rd, max 3,032) | 1,299 (min 1,200, max 3,540) | median over the firmware-loop SD reads (CMD17 frames on cs 02, 527/528 bytes) of `boot`: frame duration / frame bytes, so command, card wait and data are all in it. Runs: boot, fdd_rd, hdd, cdda, cdda_load, keys give the same medians (+-0.1 ns); max = the first read of a run (cold I$ / card init) |
| SD sector read end to end, CMD17 | **537.6 us** (536.2 .. 1,598) | 685.8 us (682.5 .. 1,866) | one CMD17 frame, start to the last data byte, median of boot (n 1,569 / 1,597) |
| SD sector read end to end, CMD18 | **421.5 us** (418.8 .. 569.9) | 481.7 us (479.6 .. 733.2) | `hdd`, n 147 each: the CMD18 command frame start to the end of the direct-mode data frame (cs 42, 512 bytes) that follows it without a gap |
| 32 KB ring fill (`cdda`, Task 17) | **42.81 ms median, 42.85 max** | 88.15 ms median, 88.16 max | `CDDA fill` lines, the three fills of the measured halves plus the PLAY-time fills (n 7; the min of 4.67 / 21.73 ms is the PLAY-time partial fill, not a refill after a flip). `cdda_load`: RV median 42.82, max 43.35; 832 median 88.14, max 96.69 |
| Menu redraw (`keys`, Task 8's tour) | **1.708 ms median** (1.706 .. 5.218) | 4.210 ms median (3.784 .. 12.744) | key-down event (`KEYS ev`) to the end of the last `20 0c` frame before the next key-down, n 21 each; the max is the first open of a page |

Gate (plan 4.4, from Task 17): **RV ring fill <= 832 holds** (42.85 ms max vs 88.16 ms, 0.49x); every other figure is also lower on the RV (SPI byte 0.78x, sector read 0.78x / 0.88x, menu redraw 0.41x). `fdd_rd` has an incidental menu redraw too (n 13: RV median 1.826 ms, 832 4.211 ms), same ratio.

### I-cache per window (RV; the 832 has neither I$ nor STATS lines)

Window events per scenario as in the Task 20 brief (boot: 1st..21st HandleFpga frame; fdd_rd: first..last track DMA; hdd: first..last command; cdda: flip 2..6; keys: first..last key). `refills / retired` and `8 x refills / retired` are measured; the last two columns are not:

| Scenario | refills | retired | refills / retired | 8 x refills / retired | busy cycles (I$ port, all requests) | window cycles | refill share of busy, ESTIMATE L=30 (L=20 .. 40) |
|---|---|---|---|---|---|---|---|
| boot | 748 | 8,298 | 9.01 % | 0.721 | 91,581 | 113,224 | 24.5 % (16.3 .. 32.7) |
| fdd_rd | 1,108,249 | 14,617,607 | 7.58 % | 0.607 | 156,229,789 | 193,659,710 | 21.3 % (14.2 .. 28.4) |
| cdda | 427,808 | 5,887,507 | 7.27 % | 0.581 | 70,199,943 | 84,279,296 | 18.3 % (12.2 .. 24.4) |
| keys | 19,258 | 682,199 | 2.82 % | 0.226 | 5,049,253 | 6,963,988 | 11.4 % (7.6 .. 15.3) |
| hdd | 8,622 | 950,312 | 0.91 % | 0.073 | 21,840,927 | 24,375,168 | 1.2 % (0.8 .. 1.6) |

**The refill share is an estimate, not a measurement.** The STATS lines carry the refill count and the port's busy-cycle total (all requests: refills, data reads and writes) but no refill latency, and the three request counts do not separate (a least-squares fit of busy cycles on refills, reads and writes over the five windows gives a negative refill weight, so the busy total is dominated by something else, most likely the slow peripheral accesses). The estimate is `refills x L / busy cycles` with an assumed refill latency of L = 30 `clk_114` per 8-word refill (bracket 20 and 40); it scales linearly with L. A measured figure needs a per-refill latency counter in the bench.

`cdda_load` has no `win_start` / `win_end` lines (n/a: window line missing in run_p4g_rv_def_cdda_load and run_p4g_832_def_cdda_load, not re-run); the other scenarios of the grid (`fdd_wr`, `cd`, `cdiso`, `akiko`) are outside the brief's window list.

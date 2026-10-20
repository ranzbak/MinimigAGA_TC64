# OSD host CPU migration, Phase 5.4: debug bring-up (lab bitstream, rv_debug = 1)

- Status: the lab build is recorded below, the simulation proof is summarised, the board session is **not yet held**.
- The **lab bitstream** is a separate image from B (the shipping RISC-V image). It adds the RISC-V debug module and is for Paul's board session only.
  - Built from C2 = `42f7cbb735da8f7cd9951b307edc82c25e5ba3f3` on `p5-build` (`build_ap040.tcl` with `RV_DEBUG=1`), Vivado 2023.2, `xc7a100tfgg676-2`.
  - Outputs: `MinimigAGA_TC64-riscv/build/stage_p5dbg_42f7cbb/` (`$OUT`).
  - Bitstream md5: `990199ce7b0ca771b5c83c1c59192814` (`bit.md5`, re-checked against the `.bit`).
- **B** is `build/stage_p5b_87577e2` (C1 = `87577e2`, `rv_debug = 0`, md5 `4065f272991c6800dd4e19640be5dcb9`); its record is `findings/osd-riscv/phase5.md`. B is not rebuilt or touched.
- Sources of every number: the reports in `$OUT` and in B's directory, `task-6-report.md`, `task-6-review.md`, `findings/osd-riscv/ooc-2023.2.md`. No Vivado was run for this record.

## Verdict

**Lab only; not fatal.** Task 8 (the board-session document) may be written.

| Fatal condition (brief) | Lab build | Result |
|---|---|---|
| Failing endpoint in the debug path: `rv_tck` intra-clock | `rv_tck` setup WNS +43.977 ns, hold WHS +0.121 ns, 0 failing of 395 endpoints | clear |
| Failing endpoint in the `BSCANE2` paths | `failing.rpt` holds 16 paths; none has a `BSCANE2` or `u_bscan` start or end point | clear |
| Failing endpoint under `hostcpu` with a `VexOsd_DMT` debug-module start or end point | All 16 are `dr_d[n]` (input port) -> `openaars_virtual_top/sdram/sdata_reg_reg[n]/D`; none is under `hostcpu` | clear |
| Unconstrained `rv_tck` | `rv_tck` is a defined 50 ns clock (`clocks.rpt`, `timing_summary.rpt`); `check_timing`: `no_clock` 0, `unconstrained_internal_endpoints` 0 | clear |

- The clk_114 WNS question: the lab's design WNS is -0.484 ns, **better** than B's -0.544 ns, and its clk_114 intra WNS is +0.058 ns against B's +0.019 ns. So the "clk_114 WNS below B's is recorded, not fatal" case does not even arise.
- The failing set equals B's known set (see "Failing endpoints").
- The lab image is not a shipping candidate and nothing here changes B's 5.1 result.

## Lab build

### Build

| Item | Lab | Source |
|---|---|---|
| Commit | `42f7cbb735da8f7cd9951b307edc82c25e5ba3f3` | `COMMIT` |
| Generics | B's string + `" HOSTCPU_RVDEBUG=1"` exactly | `generics.txt`, Task 6 report and review |
| Synthesis | `rv_debug` bound to 1, `hostcpu_riscv` 1, `rv_hostcpu` bound to `myrv`; `VexOsd_DMT.v` elaborated; `rv_debug.xdc` parsed; no `eightthirtytwo_cpu` or `OSDBoot_832`; no black box | Task 6 report |
| Host CPU file switch | `host CPU = RISC-V, DEBUG MODULE (rv_debug = 1, LAB BUILD)`; 3 RV files enabled, 14 832 files disabled; debug module in `VexOsd_DMT.v` and `rv_bscane2.v`, `rv_debug.xdc` (LATE); 18 project changes, all restored (`6 added RV files removed, 12 enable flags reset`) | `vivado.log` |
| Wall time | ~62 min, 10:10:45 -> 11:12 on 2026-10-20 | Task 6 report |
| `ERROR` lines | 0 | `vivado.log`, `impl_1/runme.log` |
| `CRITICAL WARNING` lines | 8, same kinds and counts as B: `Designutils 20-1280` x4, `20-1281` x1, `Timing 38-282` x1, `Vivado 12-4739` x2. None names `rv_debug.xdc`, `rv_tck`, `create_clock`, `get_pins` or `BSCANE2` | Task 6 review |
| IP `.xcix` md5 before/after | equal (`ila_cpu040` 363cddce..., `ila_fastram` 145662ee..., `vio_ddr3` 0bb29680...), also equal to B's | `ip_md5_{before,after}.txt` |
| Worktree after the build | clean (`git status --porcelain` empty), HEAD `42f7cbb` | Task 6 review |
| One CPU per image | `eightthirtytwo_cpu*` 0, `OSDBoot_832_ROM*` 0, `debug_bridge_jtag*` 0, `rv_hostcpu*` 1, `OSDBoot_rv_ROM*` 1, `EightThirtyTwo_Bridge*` 1 | `hostcpu_cells.txt` |
| Debug module cells | `VexOsd_DMT` 1 (+9 `VexOsd_DMT_*` submodules), `rv_bscane2` 1, `VexOsd` 0, `VexOsd_DMJ` 0, `BSCANE2` 1 (`JTAG_CHAIN 4`, `u_bscan/u_bscane2`) | `rv_debug.rpt`, `hostcpu_cells.txt` |

### Fit: totals (`utilization.rpt`, routed; device 63,400 LUT / 126,800 FF / 135 BRAM tiles / 240 DSP / 15,850 slices)

| Resource | Lab | B | Lab - B | Phase 1 OOC (`rv1` - `rv0`, `ooc-2023.2.md`) |
|---|---|---|---|---|
| Slice LUTs | 54,560 (86.06 %) | 54,052 (85.26 %) | **+508** | +499 |
| of which LUT as Logic | 53,826 | 53,343 | +483 | -- |
| of which LUT as Memory (distributed RAM + SRL) | 734 (432 + 302) | 709 (410 + 299) | +25 | -- |
| Slice registers (FF) | 27,103 (21.37 %) | 26,469 (20.87 %) | **+634** | +680 |
| Block RAM tiles | 91 (67.41 %): 76 RAMB36 + 30 RAMB18 | 91 (67.41 %): 76 RAMB36 + 30 RAMB18 | 0 | 0 (4 / 3, 5.5 tiles both) |
| DSP48E1 | 50 (20.83 %) | 50 (20.83 %) | 0 | 0 |
| Slices | 15,678 (**98.91 %**) | 15,531 (97.99 %) | +147 | -- |
| BSCANE2 | 1 (25.00 %) | 0 | +1 | +1 |
| BUFGCTRL | 12 (37.50 %) | 12 (37.50 %) | 0 | +1 |

- **LUT and FF** land on the Phase 1 OOC expectation for `rv1` over `rv0`: -9 LUT and -46 FF against `ooc-2023.2.md` (+499 LUT, +680 FF).
  - The brief quoted "~+470 LUT, +844 FF"; those two figures do not appear in `ooc-2023.2.md`. This record uses the file's own `rv1` row (2031 LUT, 22 LUTRAM, 1932 FF against `rv0` 1532 / 0 / 1252, hence +499 / +680).
  - Against the brief's figures, the lab is +38 LUT and -210 FF.
- **BRAM and DSP** are unchanged: the debug module adds none.
- **Slices are at 98.91 %** of the device, up from 97.99 %. The route still closed, but this is the thinnest fit margin of any image so far. It does not matter for a lab image; it would for anything built on top of it.
- **BUFGCTRL** reads 12 in both builds, although the OOC run counted +1 BUFG for `u_bufg_tck` and `rv_debug.rpt` shows `u_bufg_tck` placed as `BUFGCTRL_X0Y10`. The reports do not say which BUFG B uses less or differently. This is an unexplained observation, not a failure; the BUFG exists in the lab netlist and drives the `rv_tck` net (fanout 206).

### Fit: `hostcpu` hierarchy (`util_hostcpu.rpt`, depth 3; B from `phase5.md`)

| Instance | Module | Lab LUT / FF | B LUT / FF | Lab - B (LUT / FF) |
|---|---|---|---|---|
| `hostcpu` (total) | `EightThirtyTwo_Bridge` | **2,113** / 1,917 | 1,630 / 1,269 | **+483** / +648 |
| `hostcpu` (own level) | `EightThirtyTwo_Bridge` | 89 / 98 | 95 / 98 | -6 / 0 |
| `genrv.bootrom` | `OSDBoot_rv_ROM` | 2 / 0 | 18 / 0 | -16 / 0 |
| `genrv.myrv` | `rv_hostcpu` | 1,944 / 1,744 | 1,457 / 1,096 | +487 / +648 |
| `genrv.myrv` (own level) | `rv_hostcpu` | 54 / 102 | 51 / 102 | +3 / 0 |
| `genrv.myrv/g_core.u_bscan` | `rv_bscane2` | 24 / 0 | -- | +24 / 0 |
| `genrv.myrv/g_core.u_core` | `VexOsd_DMT` (lab) / `VexOsd` (B) | 1,866 / 1,642 | 1,406 / 994 | +460 / +648 |
| `hostcache_inst` | `hostcache` | 78 / 75 | 61 / 75 | +17 / 0 |

- BRAM and DSP under `hostcpu` are 4 RAMB36 + 3 RAMB18 + 4 DSP in both (`u_core` 1 / 3 / 4, `bootrom` 2, `hostcache` 1).
- The lab has 22 LUTRAM and 3 SRL under `u_core`; B has 0 and 0 (B: "LUTRAM and SRL are 0 throughout"). (Inferred: they belong to the debug module; not attributed cell by cell.)
- **Lab vs OOC `rv1`** (2,031 LUT / 1,932 FF): the lab's `hostcpu` total is 2,113 / 1,917, so +82 LUT (+4.0 %) and -15 FF. Within the in-context offset B also showed over `rv0` (+98 LUT), so no explanation is needed.
- The 24 LUT under `u_bscan` are the DTM's `dmi`/`dtmcs` shift-register enables that the flattening pushed into that level, as in the OOC run (`ooc-2023.2.md`); `rv_bscane2` itself is two primitives. `VexOsd_DMT` is 1,866 LUT / 1,642 FF here against 1,868 / 1,642 OOC.
- The bootrom's 16 LUT difference (18 -> 2) is a mapping difference of the same ROM; the hostcache's +17 LUT likewise. Neither is attributed cell by cell (inferred).
- The whole-design delta (+508 LUT, +634 FF) is almost entirely the `hostcpu` delta (+483 LUT, +648 FF). The remaining +25 LUT / -14 FF outside it is placement-dependent mapping noise.

### Timing (`timing_summary.rpt`)

| | Lab | B |
|---|---|---|
| WNS / TNS (setup) | **-0.484** / -5.990 ns, 16 failing of 77,692 | -0.544 / -7.139 ns, 16 failing of 76,359 |
| WHS / THS (hold) | +0.036 / 0.000 ns, 0 failing of 77,143 | +0.032 / 0.000 ns, 0 failing of 75,810 |
| WPWS (pulse width) | +0.264, 0 failing | +0.264, 0 failing |
| `check_timing` | `no_clock` 0, `constant_clock` 0, `pulse_width_clock` 0, `unconstrained_internal_endpoints` 0, `multiple_clock` 0, `generated_clocks` 0, `loops` 0; `no_input_delay` 31, `no_output_delay` 67 | same counts in B (`phase5.md`) |

The total endpoint count is +1,333 setup and +1,333 hold over B: the debug module's registers and the `rv_tck` domain.

### Intra-clock WNS / WHS (ns)

| Clock | Lab WNS | B WNS | Lab WHS | B WHS |
|---|---|---|---|---|
| clk_114 | **+0.058** | +0.019 | +0.048 | +0.055 |
| dll_28 | +15.416 | +13.214 | +0.036 | +0.071 |
| clk_38 | +0.217 | +0.237 | +0.080 | +0.075 |
| clk_148 | +0.250 | +0.261 | +0.088 | +0.061 |
| clk_ddr100 | +2.466 | +1.879 | +0.115 | +0.097 |
| spi_sck | +17.508 | +18.835 | +0.257 | +0.240 |
| max_sclk_OBUF (I2S) | +612.192 | +611.619 | +0.257 | +0.261 |
| **rv_tck** | **+43.977** | -- (clock absent) | **+0.121** | -- |

- The clk_114 intra setup and hold margins stay positive (+0.058 / +0.048). Its endpoint count is 14,805 against B's 13,960.
- `rv_tck`: 395 endpoints, WPWS +24.146 ns, recovery/removal (`async_default`, `rv_tck -> rv_tck`): +48.731 / +0.434, 4 endpoints.
- The thinnest `rv_tck` hold paths are the 2-FF synchroniser chains in the tunnel's `FlowCCByToggle` blocks (`buffers_0_reg -> buffers_1_reg`, +0.121 ns, source clock delay 1.249 ns). The value matches the OOC run's `tck` WHS +0.121.
- The OOC run's `tck` WNS was +46.297 ns; in context it is +43.977 ns, a 2.3 ns difference from the BUFG-to-FF routing in a full design.

### `rv_tck` clock and crossings

`report_clocks` (`clocks.rpt`, `rv_debug.rpt`):

```
rv_tck  50.000  {0.000 25.000}  P  {openaars_virtual_top/hostcpu/genrv.myrv/g_core.u_bscan/u_bscane2/TCK}
```

It is a 50 ns (20 MHz) propagated clock on the `BSCANE2` TCK pin, created by `tools/vivado/rv_debug.xdc`, plus `set_clock_groups -asynchronous` between `rv_tck` and `clk_114` (`exceptions.rpt` position 86, both directions).

`report_clock_interaction` (`clock_interaction.rpt`), the only rows that name `rv_tck`:

```
clk_114   rv_tck   0  35   0  35   Ignored   Asynchronous Groups
rv_tck    clk_114  0  41   0  41   Ignored   Asynchronous Groups
rv_tck    rv_tck   rise - rise  43.98  0.00  0  399   50.00 rise - rise  0.12  0.00  0  399   0.00  Clean  Timed
```

- `rv_tck` talks to `clk_114` only (35 paths one way, 41 the other) and to itself. Every crossing is covered by the asynchronous group, and no other clock pair names `rv_tck`.
- `cdc.rpt`: `rv_tck -> clk_114` 41 endpoints and `clk_114 -> rv_tck` 34 endpoints, CDC type `No Common Primary Clock`, exception `Asynch Clock Groups`, severity **Warning**, all safe, 0 unsafe, 0 unknown. These are the tunnel's toggle-synchroniser crossings (`FlowCCByToggle` with `BufferCC`), which are the intended async crossings.

### Failing endpoints vs B's known set

`failing.rpt` (`report_timing -setup -hold -max_paths 100 -nworst 1 -slack_lesser_than 0`) holds exactly 16 paths. All are setup, all in path group `clk_114`, 0 hold. Every start point is an input port `dr_d[n]` and every end point is `openaars_virtual_top/sdram/sdata_reg_reg[n]/D`, n = 0..15 once each.

- **The start/end point list is identical to B's `failing.rpt`** (sorted `diff` of start and end points: no difference). It is therefore also B's known set of 16 (the 16 `clk_gen_sdram -> clk_114` endpoints, the same set as the reference A).
- Slack per bit, lab: -0.484 (worst), -0.477, -0.453, -0.426, -0.425, -0.375, -0.352, -0.351, -0.347, -0.342, -0.340, -0.339, -0.335, -0.334, -0.316, -0.293. B's range was -0.544 to -0.352.
- The `clk_gen_sdram -> clk_114` row of the inter-clock table: lab -0.484 / -5.990, 16 of 16 failing; hold +10.204, 0 failing. B: -0.544 / -7.139, 16 of 16; hold +10.232. It is the same input-capture path (IBUF into FF, requirement 11.791 ns, input delay 5.570 ns, 1 logic level) that no host CPU logic touches; the slack difference between builds is placement variation.
- No other clock pair or path group has a failing endpoint, for setup or hold.

### Exceptions and CDC, lab vs B

| Report | Result |
|---|---|
| `exceptions_ignored.rpt` | body identical to B's (the same six lines: `dv_clk_gnd`, `js_inta`, the two `dr_d[*] -> clk_114` multicycles, the two `clk_ddr*` clock groups). No new ignored exception. |
| `exceptions.rpt` | identical except for two added lines, position 86: `[get_clocks {rv_tck}] <-> [get_clocks {clk_114}]` as `clock_group` (both directions). |
| `cdc.rpt` and `cdc_with_waivers.rpt` | identical to B except: two added Warning lines (`rv_tck <-> clk_114`, above) and `Info dll_28 -> clk_114 Safely Timed` 2,405 -> **2,396** (-9, same rule, different netlist). |
| `cdc_28_to_100`, `cdc_100_to_114`, `cdc_114_to_100` | identical to B's. |
| `waivers.rpt` | total CDC row 1,499 -> **1,574** (+75, matching 41 + 34 new `rv_tck` endpoints); unsafe 4 and waived 4 unchanged, 274 remaining unchanged. |

Waived-endpoint counts at the top of `cdc_with_waivers.rpt`: CDC-1 114, CDC-10 16, CDC-13 144. No crossing changed from Safely Timed to unsafe or unknown.

## Simulation proof

Debug chain proof so far, by task. Numbers are quoted from the task reports; no simulation was run for this record. Detail, logs and run commands are in `sim/rv_dbg/README.md` and in the reports under `.superpowers/sdd/osd-riscv-exec-5b/`.

| Task | Commit | What it proves | Result (from the report) |
|---|---|---|---|
| 1: Verilator debug bench, OpenOCD over `remote_bitbang` (`task-1-report.md`) | `30d9a706` | `rv_hostcpu` with `DEBUG` 2 (own TAP) and 1 (BSCANE2 USER4 tunnel behind a hand-written XC7 TAP model `xc7_tap.v`) is halted, read and resumed by OpenOCD 0.12 | `attach2` PASS (`pc 0x00002004` in the loop, TAP `0x10002fff`); `attach1` PASS (TAP `0x03631093`, same pc); `teeth` PASS (USER4 = 0x22: `Unsupported DTM version: 15`, hart not examined, exit 1); `xvc_loop` PASS (IDCODE `0x03631093`, IR capture `0x11`, BYPASS delay 1); `dm_smoke` 6 runs PASS; `run.sh all` PASS, 113 s cold. |
| 1: TAP model cross-check (`xcheck`, xsim) | `30d9a706` | `xc7_tap.v` + `xc7_bscane2` behave like Vivado's `JTAG_SIME2` + `BSCANE2` (chains 4 and 1) | 20,006 TCK cycles, 79,984 comparisons, **0 mismatches**; teeth (USER4 = 0x22) 18,448 mismatches. Extra run, seed 7: 60,056 cycles, 240,192 comparisons, 0 mismatches. The unisim `JTAG_SIME2.v` itself does not run in Verilator 5.020 (procedural `1'bz`), hence the hand model. |
| 2: scripted GDB session (`task-2-report.md`) | `547693f9` | halt, registers, memory, software and hardware breakpoints, `load` of a second image and `fence.i` through GDB 16.3 + OpenOCD, both transports | 9 checks each: `gdb2` PASS at TCK_HALF 4 and 16; `gdb1` PASS at TCK_HALF 4 and 16 (44 s); `gdb_teeth` (I-cache flush suppressed in a bench-only copy of `VexOsd_DMT.v`): FAIL at `mailbox` (0xa5a50001 instead of 0xb5b50002) as designed = PASS; `run.sh all` PASS, 93 s. Status DONE_WITH_CONCERNS: three deviations from the brief's literal steps (`break *main`, an extra reset, `hbreak work`), explained in the report. |
| 3: hw_server JTAG-scan bridge (`task-3-report.md`) | `d08de01f` | `tools/rvdebug/rbb_core.tcl` maps OpenOCD's remote_bitbang stream onto Vivado's `scan_ir_hw_jtag`/`scan_dr_hw_jtag`/`run_state_hw_jtag`/`runtest_hw_jtag` calls without changing the TAP-visible behaviour | Unit and equivalence suite: 46 passed, 0 failed (seeds 101 and 202, 1,000 random streams each, ~5 min; also 46/46 inside Vivado 2023.2's Tcl 8.5.14, 200 streams, no hardware command); `HEX TEST` 359 vectors. `bridge_sim` (the scripted GDB session through the bridge into the harness): `GDB PASS DEBUG=1 ... through the bridge: 9 checks`, 37 s; scans 18,278, partial 0, longest 672 bits, IDCODE read-ahead 1,530 (0 bad). `bridge_teeth`: FAIL at `mailbox` as designed = PASS. Vivado batch check: Tcl loads, hex test passes, no hw_server started. **Review pending**: the controller updates these numbers after Task 3's review. |
| 4: XVC rehearsal with real Vivado | -- | the bridge's hex format, bit order and end-state semantics meet Vivado's own `*_hw_jtag` commands, over XVC and a private `hw_server` on `tcp::3131` | **Not run yet.** Everything the bridge assumes about Vivado (end-state after a scan, `-state` path form, TDO hex format and bit order) is until then exercised by the shim's reading of the documentation only. |

Findings that bear on the board session (Task 3 report; review pending):
- A pause split inside a DMI shift corrupts the tunnel (`Unsupported DTM version: 9`), because VexRiscv's `JtagTunnel` delays TDI by 9 and TDO by 4 TCKs; the bridge therefore never splits a shift except at the 255th owed `R`.
- OpenOCD's 672-bit autoprobe needs the IDCODE read-ahead (without it: `Unexpected idcode after end of chain` and `double-check your JTAG setup`). Whether silicon reloads IDCODE outside Shift-DR as `JTAG_SIME2` does is unknown; with the read-ahead it does not matter.
- Speed: 2 Vivado commands and 1 scan per DMI access (36.5k gotos for 18.3k scans in the GDB session). The first GDB session through hw_server may take minutes; Task 4 is to measure it.

## Board session

(empty: filled after Paul's session on the board with `stage_p5dbg_42f7cbb`; the procedure is Task 8's document, `findings/osd-riscv/debug-board-session.md`.)

## Files and paths

- Lab outputs: `/home/paul/work/fpga/Xilinx/artix7/MinimigAGA_TC64-riscv/build/stage_p5dbg_42f7cbb/` (`minimig_openaars_top.bit`, `bit.md5`, `COMMIT`, `generics.txt`, `utilization.rpt`, `util_hostcpu.rpt`, `util_hier.rpt`, `hostcpu_cells.txt`, `rv_debug.rpt`, `clocks.rpt`, `clock_interaction.rpt`, `timing_summary.rpt`, `failing.rpt`, `exceptions.rpt`, `exceptions_ignored.rpt`, `cdc*.rpt`, `waivers.rpt`, `drc.rpt`, `ip_md5_{before,after}.txt`, `vivado.log`).
- B outputs: `.../build/stage_p5b_87577e2/` (same file names).
- Build worktree of the lab image: `MinimigAGA_TC64-p5dbg` (detached at `42f7cbb`).
- OOC expectation: `findings/osd-riscv/ooc-2023.2.md` (`rv1` row).

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>

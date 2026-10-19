# OSD host CPU migration, Phase 5: fit and timing of bitstream B (plan 5.1 gate)

- **B** is the RISC-V host CPU image. It was built from C1 = `87577e2` on `p5-build` in the build worktree `MinimigAGA_TC64-p5b`.
  - Outputs: `MinimigAGA_TC64-riscv/build/stage_p5b_87577e2/`.
  - Bitstream md5: `4065f272991c6800dd4e19640be5dcb9`.
- **A** is the reference and the board fallback: the 832 host CPU image `build/stage_spicdc_49b1868` in the main checkout.
  - Commit: `49b1868` on `5.0-040-pipelined`.
  - Bitstream md5: `28b07e8caf8345b25365018ef00753a2`.
  - Only flat reports were written for A.
- Both builds use Vivado 2023.2 on `xc7a100tfgg676-2` and have the same generics.

**A is not "B minus the CPU".** A also lacks the bridge, `cfide` and `userio_osd` changes of Phases 1-4:
- the IRQ controller;
- the `osd_rx_seq`/`osd_tx_seq` OSD handshake;
- the `HOST_REQ` OSD_RDY bit.

So every B - A delta below includes those changes as well as the CPU swap.

## Build

| Item | B | Source |
|---|---|---|
| Commit | `87577e2992773ac5012b5d83f45d2e8d689de0e9` | `COMMIT` |
| Generics | identical to A's `.last_generics` (no `HOSTCPU` token; the CPU comes from the top's `HOSTCPU_RISCV = 1` default) | `generics.txt` |
| Host CPU file switch | `build_ap040.tcl: host CPU = RISC-V (3 RV files enabled, 14 832 files disabled)`; restored afterwards (14 changes undone) | `vivado.log`, Task 2 |
| Synthesis | `hostcpu_riscv` bound to 1, `cpu_riscv` 1, `rv_debug` 0; `rv_hostcpu` bound to `myrv`; no `eightthirtytwo_cpu`, `OSDBoot_832`, `debug_bridge`, or black box | Task 2 synth-log check |
| Wall time | ~73 min, 17:24 -> 18:37 on 2026-10-19 (Phase 4 Verilator jobs ran alongside); the reference took ~46 min | Task 2 |
| `ERROR` lines | 0 | `vivado.log` |
| `CRITICAL WARNING` lines | 8, none new in kind (detail below) | `vivado.log` |
| IP `.xcix` md5 before/after | equal | `ip_md5_{before,after}.txt` |
| DRC (routed) | 0 errors; warnings only (DPIP/DPOP/REQP-1839/1840 etc.) | `drc.rpt` |

The 8 critical warnings:
- `Designutils 20-1280/1281` x5: the absent `vio_ddr3`/`ila_*` IP XDCs. These cores are switched off by generics.
- `Vivado 12-4739` x2: `wizard.xdc:41-42`, `tg68k/lds2_reg` (no such cell in this core).
- `Timing 38-282` x1: the known `clk_gen_sdram -> clk_114` violation.

A has no stored `vivado.log`, so no one-to-one comparison of the warnings was possible. The `hostcpu/hw_req_reg` and `hostcpu/wr_reg` multicycle rules (`wizard.xdc:29-32`) raise no warning, so both cells exist in B.

## Fit

### Totals (`utilization.rpt`, routed; device 63,400 LUT / 126,800 FF / 135 BRAM tiles / 240 DSP / 15,850 slices)

| Resource | B | A | B - A | Phase 1 OOC expectation (rv0 - 832, `ooc-2023.2.md`) |
|---|---|---|---|---|
| Slice LUTs | 54,052 (85.26 %) | 53,409 (84.24 %) | **+643** | +661 |
| Slice registers (FF) | 26,469 (20.87 %) | 26,066 (20.56 %) | **+403** | +278 |
| Block RAM tiles | 91 (67.41 %): 76 RAMB36 + 30 RAMB18 | 88.5 (65.56 %): 75 RAMB36 + 27 RAMB18 | **+2.5** (+1 RAMB36, +3 RAMB18) | +2.5 |
| DSP48E1 | 50 (20.83 %) | 50 (20.83 %) | 0 | 0 (both CPUs use 4) |
| Slices | 15,531 (97.99 %) | 15,460 (97.54 %) | +71 | -- |
| BSCANE2 | 0 | 0 | 0 | -- (no debug tunnel in B) |

- **LUT and BRAM** land on the OOC expectation: -18 LUT and exactly +2.5 tiles.
- **FF** is +125 over the OOC delta. The hostcpu block itself accounts for only +17 of that (1,269 in context vs 1,252 OOC). The rest lies outside `hostcpu`, which is consistent with the Phase 1-4 `cfide` additions in A's absence (inferred, not measured):
  - IRQ controller: synchronisers, pending, mask and mode registers;
  - `osd_tx_seq`, `osd_idle` and `host_req_q`.
- **Slices** are at 97.99 %, against 97.54 % in A.

### `hostcpu` hierarchy (`util_hostcpu.rpt`, `report_utilization -cells openaars_virtual_top/hostcpu -hierarchical -hierarchical_depth 3`)

| Instance | Module | LUT | FF | RAMB36 | RAMB18 | DSP |
|---|---|---|---|---|---|---|
| `hostcpu` (total) | `EightThirtyTwo_Bridge` | **1,630** | 1,269 | 4 | 3 | 4 |
| `hostcpu` (own level) | `EightThirtyTwo_Bridge` | 95 | 98 | 0 | 0 | 0 |
| `genrv.bootrom` | `OSDBoot_rv_ROM` | 18 | 0 | 2 | 0 | 0 |
| `genrv.myrv` | `rv_hostcpu` | 1,457 | 1,096 | 1 | 3 | 4 |
| `genrv.myrv` (own level) | `rv_hostcpu` | 51 | 102 | 0 | 0 | 0 |
| `genrv.myrv/g_core.u_core` | `VexOsd` | 1,406 | 994 | 1 | 3 | 4 |
| `hostcache_inst` | `hostcache` | 61 | 75 | 1 | 0 | 0 |

LUTRAM and SRL are 0 throughout.

A's `hostcpu` hierarchy is **unavailable**:
- The reference build wrote flat reports only.
- Filling it needs a ~10 min read-only report on the reference DCP: `MinimigAGA_TC64-v2023/project_1/project_1.runs/impl_1/minimig_openaars_top_routed.dcp`. Its mtime is 2026-10-17 16:14:43, which is the reference run; A's `.bit` is from 16:18.
- That run was not made for this record (see the Verdict).

For orientation only, and not a measurement of A: the Phase 1 OOC run of the 832 bridge gave 871 LUT / 974 FF / 3 RAMB36 / 4 DSP (`ooc-2023.2.md`).

**B against the OOC `rv0` figure:** 1,630 LUT vs 1,532, which is **+98 LUT (+6.4 %)**. That is under the 15 % threshold (1,762), so no explanation is required.
- The children match OOC closely:

  | Child | B | OOC rv0 |
  |---|---|---|
  | `rv_hostcpu` | 1,457 | 1,450 |
  | `VexOsd` | 1,406 | 1,400 |
  | boot ROM | 18 | 18 |
  | `hostcache` | 61 | 65 |

- The extra LUTs sit in the bridge's own level: 95 LUT here. In OOC the children summed to the total, so this level held about 0 LUT.
- `832_bridge.vhd` is unchanged since that OOC run (`git diff 628d21a 87577e2`). The difference is therefore the in-context netlist: real `cfide`/`minimig` neighbours instead of unconstrained OOC ports, and different cross-boundary optimisation. This is inferred, not attributed cell by cell.

## Timing

### Design summary (`timing_summary.rpt`)

| | B | A |
|---|---|---|
| WNS / TNS (setup) | -0.544 / -7.139 ns, 16 failing of 76,359 | -0.525 / -7.036 ns, 16 failing of 75,457 |
| WHS / THS (hold) | +0.032 / 0.000 ns, 0 failing of 75,810 | +0.011 / 0.000 ns, 0 failing of 74,908 |
| WPWS (pulse width) | +0.264, 0 failing | +0.264, 0 failing |
| `check_timing` | 0 no_clock, 0 unconstrained internal endpoints, 0 loops; 31 no_input_delay / 67 no_output_delay | identical text |

The only differences in the methodology summary are:
- `SYNTH-10` (wide multiplier) 24 -> 20;
- `TIMING-46` (multicycle path with tied CE pins) 9 -> 11.

Both are explained under "Exceptions and CDC" below.

### Intra-clock WNS / WHS (ns)

| Clock | B WNS | A WNS | B WHS | A WHS |
|---|---|---|---|---|
| **clk_114** | **+0.019** | **+0.101** | +0.055 | +0.056 |
| dll_28 | +13.214 | +14.522 | +0.071 | +0.035 |
| clk_38 | +0.237 | +0.418 | +0.075 | +0.051 |
| clk_148 | +0.261 | +0.056 | +0.061 | +0.081 |
| clk_ddr100 | +1.879 | +2.793 | +0.097 | +0.077 |
| spi_sck | +18.835 | +19.166 | +0.240 | +0.348 |
| max_sclk_OBUF (I2S) | +611.619 | +612.608 | +0.261 | +0.272 |

The clk_114 TNS endpoint count is 13,960 in B and 13,365 in A.

**5.1 WNS gate:** clk_114 intra WNS of B is +0.019 ns, against the gate of reference - 0.1 ns = +0.001 ns. **Met, with a margin of 18 ps.** It is 82 ps below A's figure.

The thinnest inter-clock setup slacks in B are:
- `clk_38 -> clk_114`: +0.067 (A +0.231);
- `clk_114 -> clk_38`: +0.200 (A +0.527);
- `dll_28 -> clk_38`: +0.410 (A +0.209).

The thinnest inter-clock hold slacks in B are:
- `clk_114 -> clk_38`: +0.032 (A +0.081);
- `clk_114 -> dll_28`: +0.033 (A +0.011).

All of them pass.

### `report_clocks` (`clocks.rpt`)

```
spi_sck                           52.893      {0.000 26.446}   P,G         {openaars_virtual_top/mycfide/sck_pin_reg/Q}
```

`spi_sck` is present: a generated clock from `mycfide/sck_pin_reg/Q` with a 52.893 ns period (18.906 MHz), the same as A's clock summary.

### Failing endpoints vs the reference's known set

**B, measured** (`failing.rpt` = `report_timing -setup -hold -max_paths 100 -nworst 1 -slack_lesser_than 0`):
- The report holds exactly 16 paths, all of them setup and none of them hold.
- Every path has path group `clk_114`, source an input port `dr_d[n]` clocked by `clk_gen_sdram`, and destination `openaars_virtual_top/sdram/sdata_reg_reg[n]/D` (FDRE, clk_114).
- Each path has 1 logic level (IBUF), a requirement of 11.791 ns and an input delay of 5.570 ns.

| Endpoint (`openaars_virtual_top/sdram/sdata_reg_reg[n]/D`), n = | 2 | 12 | 3 | 0 | 15 | 1 | 10 | 7 | 8 | 11 | 6 | 9 | 5 | 14 | 4 | 13 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Slack (ns) | -0.544 | -0.493 | -0.484 | -0.482 | -0.480 | -0.477 | -0.473 | -0.468 | -0.461 | -0.448 | -0.439 | -0.434 | -0.380 | -0.371 | -0.352 | -0.352 |

`n` covers 0..15, all 16 bits once.

**Proven from the reports** (inter-clock table and per-group detail of both `timing_summary.rpt` files):

| Clock pair `clk_gen_sdram -> clk_114` | B | A |
|---|---|---|
| Setup WNS / TNS | -0.544 / -7.139 | -0.525 / -7.036 |
| Setup failing / total endpoints | **16 / 16** | **16 / 16** |
| Hold WHS, failing / total | +10.232, 0 / 16 | +10.239, 0 / 16 |

- **Design-wide**, B has 16 setup failures and 0 hold failures. These are the 16 of this pair. Every other row of B's intra, inter and "Other Path Groups" (`async_default`) tables shows 0 failing endpoints, for setup and for hold. Pulse width has 0 failing.
- **In both builds** the failing count equals the total endpoint count of the pair, so the failing set is "every endpoint of `clk_gen_sdram -> clk_114`" in A as well as in B.
- **A's report names one endpoint**, `dr_d[5] -> openaars_virtual_top/sdram/sdata_reg_reg[5]/D` at -0.525 ns. Its summary prints only the worst path per group. That endpoint is in B's list, at -0.380 ns.

**Inferred (strong; A's endpoint names were not listed by a tool):** A's 16 endpoints are the same 16 `sdata_reg_reg[0..15]/D`. The capture path is the same in both commits:
- `git diff --stat 49b1868 87577e2 -- '*.xdc' rtl/sdram` is empty, so the board XDC set and `sdram_ctrl.v` are unchanged.
- The only top-level change is the two `HOSTCPU_*` parameters, and `minimig_virtual_top.v` changes only in the host CPU, the OSD handshake and the IRQ wiring.
- The pair has exactly 16 endpoints, which is the width of the `dr_d` bus.

**Conclusion:** B's failing endpoints, setup and hold over all clocks and path groups, are a subset of the reference's known set. They equal it. The count and pair equality is proven; the per-name equality for A is inferred as above. B's worst slack is 19 ps worse than A's (-0.544 vs -0.525), and TNS is 0.103 ns worse. These are placement variation on an IBUF-to-FF input path that no host CPU logic touches.

### Exceptions and CDC, B vs A

**`exceptions_ignored.rpt`:** the body is **identical** (`diff` after the 11-line header is empty). B adds no ignored exception. The six lines that both builds share:
- `dv_clk_gnd`;
- `js_inta`;
- two `dr_d[*] -> clk_114` multicycles;
- two `clk_ddr*` clock-group lines.

**`exceptions.rpt`:** the body is identical too. The handshake is covered by the existing clock-scoped rules (positions 18-21, `wizard.xdc:14-18`), and no exception was added for it:
- `dll_28 -> clk_114`: setup `cycles=4(end)`, hold `cycles=3(end)`;
- `clk_114 -> dll_28`: setup `cycles=4(start)`, hold `cycles=3(start)`.

**`cdc.rpt`** (`cdc_with_waivers.rpt` is the same):

| Line | A | B | Explanation |
|---|---|---|---|
| Critical, `input port clock -> dll_28`, No Common Primary Clock, False Path: endpoints / unknown | 21 / 14 | **22 / 15** | One new false-pathed input into a `dll_28` register. **Inferred:** `dv_int` (ADV7511 INT, `set_false_path -from [get_ports dv_int]`, `adv7511_video.xdc:51`) now also feeds `cfide`'s new IRQ controller. It enters as `i2c_ext_int`, bit 3 of `irq_in`, into the `irq_sync1` 2-FF synchroniser on `clk_28` (`cfide.vhd:450` and the IRQ process). In A it reached only `i2c_master_mmio`. The endpoint name was not listed by a tool. This crossing is the intended asynchronous input, synchronised; it is not part of the handshake. `waivers.rpt` shows the same +1 as CDC-1 "1-bit unknown CDC circuitry", 414 -> 415 total and 300 -> 301 remaining. |
| Info, `dll_28 -> clk_114`, Safely Timed | 2,436 | 2,405 (-31) | Same rule, different netlist. The 832 core is gone and the VexRiscv plus `cfide` changes are in. This line includes the handshake's `osd_rx_seq[1:0] -> osd_tx_seq[1:0]` (2 endpoints, see below). |
| Info, `clk_114 -> dll_28`, Safely Timed | 9,526 | 9,680 (+154) | As above. This line includes `osd_tx_seq -> host_req_q` (1 endpoint) and the IRQ registers written by the CPU. |

No other `cdc.rpt` line changed. `cdc_28_to_100`, `cdc_100_to_114` and `cdc_114_to_100` are identical. No crossing changed from Safely Timed to unsafe or unknown, apart from the one input-port line above.

**Other path groups (`async_default`, recovery/removal), endpoints A -> B:**
- `clk_114 -> dll_28` 18 -> 84 (+66). This matches, bit for bit, the live async-reset registers of the new `cfide` IRQ process on `clk_28`: 4 live bits each of `irq_sync1`, `irq_sync2`, `irq_prev` and `irq_pend`; 16 each of `irq_mask`, `irq_mode` and `irq_q`; plus `irq_seen` and `int_out`. The count is inferred from the RTL, not listed by a tool.
- `clk_114 -> clk_114` 149 -> 279. Not attributed.
- All of them pass, with WNS >= +1.117 and WHS >= +0.134.

**Methodology counts:**
- `TIMING-46` 9 -> 11: two more tied-CE multicycle paths. Inferred to be the handshake registers under the 1:4 clock rules, but not listed.
- `SYNTH-10` 24 -> 20: the 832's wide multipliers are gone, and VexOsd's 4 DSPs replace the 832's 4.

## Handshake paths

Source: `handshake_timing.rpt` (`report_timing -setup -hold -max_paths 4 -nworst 1`, two sections). The header gives the cell counts: 2 `osd_rx_seq_reg*` sources and 3 destinations (`osd_tx_seq_reg[1:0]`, `host_req_q_reg`). The match is therefore not empty.

| From (clock) | To (clock) | Check | Exception applied | Slack (ns) |
|---|---|---|---|---|
| `minimig/USERIO1/osd1/osd_rx_seq_reg[1]` (dll_28) | `mycfide/osd_tx_seq_reg[1]/D` (clk_114) | hold | MultiCycle Setup -end 4, Hold -end 3 | +0.128 |
| `osd_rx_seq_reg[0]` (dll_28) | `mycfide/osd_tx_seq_reg[0]/D` (clk_114) | hold | MultiCycle Setup -end 4, Hold -end 3 | +0.178 |
| `osd_rx_seq_reg[0]` (dll_28) | `mycfide/osd_tx_seq_reg[0]/D` (clk_114) | setup, requirement 35.262 = 4 x 8.815 | MultiCycle Setup -end 4 | +33.006 |
| `osd_rx_seq_reg[0]` (dll_28) | `mycfide/host_req_q_reg/D` (dll_28) | hold | none (same clock, single cycle) | +0.618 |
| `mycfide/osd_tx_seq_reg[0]` (clk_114) | `mycfide/host_req_q_reg/D` (dll_28) | hold | MultiCycle Setup -start 4, Hold -start 3 | +0.125 |
| `mycfide/osd_tx_seq_reg[1]` (clk_114) | `mycfide/host_req_q_reg/D` (dll_28) | setup, requirement 35.262 | MultiCycle Setup -start 4 | +33.046 |

- Every reported crossing between `dll_28` and `clk_114` carries the `wizard.xdc` 1:4 rule:

  ```
  set_multicycle_path -setup -end 4 -from [get_clocks dll_28] -to [get_clocks clk_114]
  set_multicycle_path -hold  -end 3 -from [get_clocks dll_28] -to [get_clocks clk_114]
  set_multicycle_path -setup -start 4 -from [get_clocks clk_114] -to [get_clocks dll_28]
  set_multicycle_path -hold  -start 3 -from [get_clocks clk_114] -to [get_clocks dll_28]
  ```

  That is setup 4, hold 3 in the direction-appropriate edge sense. No cell-scoped exception overrides it.
- `osd_rx_seq -> host_req_q` is a same-clock `dll_28` path, as designed: `host_req_q` samples `osd_rdy` on `clk_28`.
- **None is unconstrained.** Every path has a real requirement and a clock on both ends. `check_timing` reports 0 unconstrained internal endpoints. Every row is met.
- Not every setup path appears in the report. With `-setup -hold -max_paths 4` together, Vivado keeps the 4 worst paths across both checks, and the hold paths sort first. The setup paths not shown fall in clock pairs whose worst setup slack is +2.326 ns (`dll_28 -> clk_114`) and +3.800 ns (`clk_114 -> dll_28`), with 0 failing endpoints (inter-clock table).

## Netlist CPU check

Source: `hostcpu_cells.txt` (routed netlist). Every hierarchical cell below `openaars_virtual_top/hostcpu`, with its `REF_NAME`:

```
openaars_virtual_top/hostcpu/genrv.bootrom OSDBoot_rv_ROM
openaars_virtual_top/hostcpu/genrv.myrv rv_hostcpu
openaars_virtual_top/hostcpu/genrv.myrv/g_core.u_core VexOsd
openaars_virtual_top/hostcpu/genrv.myrv/g_core.u_core/IBusCachedPlugin_cache VexOsd_InstructionCache
openaars_virtual_top/hostcpu/hostcache_inst hostcache
openaars_virtual_top/hostcpu/hostcache_inst/hostcache bytewrite_tdp_ram_rf__parameterized2
```

The whole-design counts of non-primitive cells by `REF_NAME` (case-insensitive) are:
- `eightthirtytwo*` 1
- `OSDBoot_832_ROM*` 0
- `debug_bridge_jtag*` 0
- `VexOsd*` 2
- `rv_hostcpu*` 1
- `OSDBoot_rv_ROM*` 1

B was written with C1's pattern set:
- **`eightthirtytwo*` = 1 is the bridge cell itself.** `hostcpu` has `REF_NAME` `EightThirtyTwo_Bridge`: In the depth-4 hierarchy report `util_hier.rpt`, the only `EightThirtyTwo` matches are lines 65-66: the `hostcpu` row and its own-level row. That one count is therefore used up by the bridge. **0 cells of the 832 CPU (`eightthirtytwo_cpu*`)** remain, and none of its sub-entities either, since they all live inside `eightthirtytwo_cpu`.
- The pattern was fixed for future builds in `04808bf`: it counts `eightthirtytwo_cpu*` and `EightThirtyTwo_Bridge*` separately. Ledger R8.

**Result:**

| Group | Cells in B |
|---|---|
| 832 CPU (`eightthirtytwo_cpu*`) | 0 |
| `OSDBoot_832_ROM` | 0 |
| `debug_bridge*` | 0 |
| `VexOsd` | 1 |
| `VexOsd_InstructionCache` | 1 |
| `rv_hostcpu` | 1 |
| `OSDBoot_rv_ROM` | 1 |

- BSCANE2 is 0 in `utilization.rpt`: no `rv_bscane2`, no DMT/DMJ core.
- One CPU per bitstream (12.10) holds.

## Verdict (plan 5.1 gate)

| 5.1 item | Required | B | Result |
|---|---|---|---|
| clk_114 intra WNS | >= +0.001 ns (A +0.101 - 0.1) | +0.019 ns | **met** (margin 18 ps) |
| Failing endpoints, setup and hold, all clocks | subset of A's known `clk_gen_sdram -> clk_114` set | the 16 `dr_d[n] -> sdata_reg_reg[n]/D` setup endpoints; 0 hold | **met** (equal to the known set: counts proven, A's names inferred, see Timing) |
| `report_clocks` lists `spi_sck` | yes | yes, 52.893 ns, from `mycfide/sck_pin_reg/Q` | **met** |
| `hostcpu` hierarchical utilisation recorded | B and A | B recorded; A unavailable (flat reports only) | **B met; A recorded as unavailable** (the brief's fallback) |

**B meets the 5.1 gate, so Task 4 (5.2 / recovery) is skipped.** B's `hostcpu` is 1,630 LUT, within 15 % of the OOC `rv0` figure (1,532). Of the margins, two are thin and one item is open:
- **clk_114 setup:** 18 ps over the gate.
- **Slices:** 97.99 % of the device.
- **A's `hostcpu` column:** it needs a ~10 min read-only `open_checkpoint` report on the reference routed DCP named above (mtime 2026-10-17 16:14, the reference run). A's failing endpoint names would then be measured instead of inferred.

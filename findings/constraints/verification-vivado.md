# Vivado verification of the constraint findings

Run on 2026-09-04 with Vivado 2023.2 against the routed checkpoint
`project_1/project_1.runs/impl_1/minimig_openaars_top_routed.dcp` (built
28 Apr 2024, speed grade -2). Script: [vivado-reports/verify.tcl](vivado-reports/verify.tcl).
Raw reports: [vivado-reports/](vivado-reports/).

Method: phase 1 reads the design as built. Phase 2 applies the proposed
constraint changes **in memory only** (no file touched) and re-times the same
paths, so every number below is a like-for-like before/after on identical
placement and routing.

Caveat: the checkpoint predates the working-tree XDC by two commits. Known
differences: `uart.xdc` false paths and `sdram.xdc` comment edits. Nothing that
changes the conclusions.

## Scorecard

| # | Claim | Verdict | Evidence |
|---|---|---|---|
| 1 | SDRAM output delay 3.0 ns optimistic | **Confirmed** | Output delay −1.330 → +1.670; worst DQ slack 3.672 → **0.672 ns** |
| 1 | SDRAM input delay uses tOH instead of tAC | **Confirmed, worse than stated** | With tAC and the pin-referenced clock: 8.124 → **−1.295 ns VIOLATED**, 16 endpoints |
| 2 | `dll_28 → clk_114` hold check switched off | **Confirmed, and it was hiding real violations** | 78.999 → **−0.340 ns VIOLATED**, 49 endpoints, THS −8.826 |
| 3 | HDMI outputs unconstrained | **Confirmed** | `report_timing -to dv_*`: `Slack: inf`; clock interaction `clk_148 → VIRTUAL_clk_148  Ignored / Asynchronous Groups`, 16 endpoints |
| 4 | Blanket multicycle lands on single-cycle paths | **Confirmed but not currently harmful** | The 4 `TIMING-46` pairs checked carry 1.7–2.3 ns of delay against a 35.3 ns requirement — they would pass single-cycle. One of them *does* appear in the newly exposed hold violations |
| 5 | `wizard.xdc:46-47` are dead | **Confirmed** | `report_exceptions -ignored`: positions 29 (`max=1.8`) and 30 (`cycles=2(end)`) — "Totally overridden path by FP 26" |
| 6 | Unpaired setup multicycle | **Confirmed; becomes moot after fix 1** | Position 21 "Totally overridden path by MCP 47"; after moving the input reference to `clk_gen_sdram`, `clk_sd_114 → clk_114` has "No timing paths found" |
| 9 | Unconstrained ports are SD card + `dv_cecclk` | **Wrong** | HIGH ports in this build: `uart0_cts`, `uart0_rxd` in; `uart0_rts`, `uart0_txd`, `uart1_txd` out. The working-tree `uart.xdc:23-24` already covers them. Corrected in [fix-09](fix-09-unconstrained-ports.md) |
| — | TG68K cannot close single-cycle at 113 MHz | **Confirmed** | Worst kernel→kernel path: **19.4 ns**, 30 logic levels, 74 % routing, against a 26.4 ns (3-cycle) requirement |
| — | CDC into `clk_148` has an unsynchronised path | **Confirmed, and a bigger one found** | 148 Critical rows from one source: `myReset/nresetLoc_reg` (28 MHz reset) driving R/CE pins across the HDMI pipeline. New [fix-11](fix-11-reset-into-clk148.md) |

## The headline number: hold violations on the video path

Applying only `set_multicycle_path -hold -end 3` to the `dll_28 → clk_114` pair
([fix 2](fix-02-dll28-hold-multicycle.md)) — no other change — the report goes
from

```
dll_28 -> clk_114   WHS  78.999 ns   0 failing / 2701
```

to

```
dll_28 -> clk_114   WHS  -0.340 ns  49 failing / 2701   THS -8.826 ns
```

The worst five, from [vivado-reports/30_hold_dll28_clk114_AFTER.rpt](vivado-reports/30_hold_dll28_clk114_AFTER.rpt):

```
-0.340  AMBER1/blue_out_reg[7]  -> blue_reg_reg[7]     data 0.305  clock skew 0.315
-0.325  AMBER1/green_out_reg[1] -> green_reg_reg[1]    data 0.336  clock skew 0.319
-0.310  AMBER1/green_out_reg[4] -> green_reg_reg[4]    data 0.338  clock skew 0.319
-0.310  autoconfig/board_configured_reg[3] -> tg68k/z3ram3_ena_reg
-0.290  AMBER1/red_out_reg[4]   -> red_reg_reg[4]      data 0.390  clock skew 0.322
```

Requirement is `0.000 ns (clk_114 rise@0 - dll_28 rise@0)` — the two clocks
share an edge, the capture clock arrives 0.32 ns later than the launch clock,
and the data only takes 0.31 ns. The capture register sees the *new* value on
the edge that should have captured the *old* one.

Why this matters more than a generic hold miss: `blue_reg_reg` etc. are the
top-level VGA RGB registers that feed `pal_to_ddr`, and the upsampler samples
them on `clk_114` at DDS-driven instants that are unrelated to the 28 MHz pixel
edge ([adv7511/fix-08](../adv7511/fix-08-line-length-divider.md)). A sample
landing on the racing edge gets a bit-mixed pixel. This is a plausible
contributor to the sparkle/flicker the RTL investigation set out to explain.

The router fixes hold violations automatically by adding delay — but only for
checks it can see. Re-running implementation with the corrected constraint
should clear all 49 without RTL changes. Verify with the command in fix 2.

## SDRAM: the numbers

Output side ([11](vivado-reports/11_sdram_out_BEFORE.rpt) → [31](vivado-reports/31_sdram_out_AFTER.rpt), [31b](vivado-reports/31b_sdram_dq_out_AFTER.rpt)):

```
                          before        after      delta
Output Delay (dr_we_n)    -1.330        1.670      +3.000   (exactly the predicted error)
Slack, control lines       6.358        3.358      -3.000
Slack, worst DQ            3.672        0.672      -3.000
```

0.672 ns on `sdata_out_reg[9] → dr_d[9]` is still met, but it is now a real
number, and a marginal one. Expect placement to move once the placer is
optimising for the right target.

Input side ([12](vivado-reports/12_sdram_in_BEFORE.rpt) → [32](vivado-reports/32_sdram_in_AFTER.rpt)):

```
                                 before                   after
Reference clock                  clk_sd_114 (internal)    clk_gen_sdram (at pin)
Input Delay                      3.170 (tOH-based)        5.570 (tAC 5.4 + trace)
Requirement                      11.791 (2 cycles)        11.791 (2 cycles)
Slack                            8.124                   -1.295  VIOLATED, 16 endpoints
```

The 9.4 ns swing comes from two things the original constraint omitted: the
tAC-vs-tOH substitution (+2.4 ns) and the clock path from `BUFG_SDR` through
`dr_clk_OBUF` to the pin (+5.5 ns: BUFG 0.08, net 2.52, OBUF 2.98), which the
internal-clock reference did not model at all.

Two readings are possible and the RTL decides between them:

* If `sdram_ctrl.v` actually consumes `sdata_reg` **three** `clk_114` cycles
  after the launch edge, the multicycle should be 3 and the path has ~7.5 ns
  of margin.
* If it really is two cycles, the read path is 1.3 ns short at tAC = 5.4 ns and
  the interface is working on silicon margin.

Either way the existing constraint is not describing the physical path. The
tAC value used (5.4 ns) is the AS4C16M16SA CL3 figure; substitute the fitted
speed grade's datasheet number before deciding.

**Update:** resolved by simulation with the vendor model —
[sdram-sim-results.md](sdram-sim-results.md). It is *both*: at the slow corner
the data is one edge late (the multicycle-2 view), at the fast corner it is on
time (the RTL table's view). `chipRD` is wrong at the slow corner.

## HDMI output

[13_dv_out.rpt](vivado-reports/13_dv_out.rpt):

```
Slack:                    inf
Path Type:                Max at Slow Process Corner
```

for every `dv_d[*]`, `dv_de`, `dv_hsync`, `dv_vsync`. And from
[02_clock_interaction.rpt](vivado-reports/02_clock_interaction.rpt):

```
clk_148   VIRTUAL_clk_148   0   16   Ignored   Asynchronous Groups
```

Sixteen endpoints, all ignored. The interface is not timed.

## Exceptions overriding each other

[03_exceptions_ignored.rpt](vivado-reports/03_exceptions_ignored.rpt):

```
Pos  From                        To               Setup     Hold           Status
21   [get_clocks clk_sd_114]     clk_114          cycles=2  -              Totally overridden path by MCP 47
29   CLKOUT0 (clk_114)           clk_hdmi/CLKOUT0 max=1.8   -              Totally overridden path by FP 26
30   CLKOUT0 (clk_114)           clk_hdmi/CLKOUT0 -         cycles=2(end)  Totally overridden path by FP 26
36   [get_ports js_inta]         *                false     false          Non-existent path
47   [get_ports {dr_d[*]}]       clk_114          cycles=2  -              Non-existent path
48   [get_ports {dr_d[*]}]       clk_114          -         cycles=2       Non-existent path
```

Positions 29/30 are `wizard.xdc:46-47`, exactly as [fix 5](fix-05-cdc-false-path.md)
says. Positions 21 and 47/48 are the two overlapping read-path multicycles
(`wizard.xdc:27` and `sdram.xdc:74-75`) — the tool reports each as
displaced by the other. After fix 1 only the `sdram.xdc` pair matters; delete
`wizard.xdc:27`.

## TG68K

[20_tg68k_kernel_to_kernel.rpt](vivado-reports/20_tg68k_kernel_to_kernel.rpt),
1013 sequential cells in the kernel:

```
Source:        pf68K_Kernel_inst/memaddr_delta_regb_reg[0]
Destination:   pf68K_Kernel_inst/regfile_reg_0_15_0_0/DP/I
Requirement:   26.446 ns  (3 cycles - the memaddr.* rule at wizard.xdc:10-12)
Data Path:     19.376 ns  (logic 4.897  route 14.479)
Logic Levels:  30  (CARRY4=10 LUT4=3 LUT5=4 LUT6=13)
```

19.4 ns against an 8.8 ns period: the kernel needs at least three cycles as
placed, and the multicycle scheme is not optional. Note the 74 % routing share —
a relaxed path gets spread across the die by the placer, so the exceptions are
also degrading placement.

The four `TIMING-46` pairs ([21_timing46_pairs.rpt](vivado-reports/21_timing46_pairs.rpt))
all sit at 1.7–2.3 ns against 35.3 ns. The exception is wrongly applied to them
but they would close single-cycle regardless. One of that family
(`board_configured_reg[3] → z3ram3_ena_reg`) *is* in the hold-violation list
above — via the `dll_28 → clk_114` rule, not the TG68K one.

## CDC

[06_cdc.rpt](vivado-reports/06_cdc.rpt), 365 Critical rows. Grouped by root cause:

| Rows | Crossing | Root cause | Covered by |
|---|---|---|---|
| ~194 | anything ↔ `mycfide/sck_reg_n_0` | A data flop declared as a clock; the tool sees a CDC on every path touching it | [fix 8](fix-08-generated-clocks.md) |
| **148** | `dll_28 → clk_148` | `myReset/nresetLoc_reg` driving R/CE of the HDMI pipeline, unsynchronised | **[fix 11](fix-11-reset-into-clk148.md)** (new) |
| 12 | input ports → `dll_28` | Unsynchronised inputs (PS/2, buttons, etc.) | [fix 9](fix-09-unconstrained-ports.md) |
| 8 | `cfide/scs_reg` → `PAULA1`/`USERIO1` async CLR/PRE | SPI chip-select used as an asynchronous reset across domains | RTL, outside this scope |
| 3 | `clk_114 → clk_148` | `s_pal_vsync_reg[1]` fans out to **three** separate synchronisers (CDC-11) | [adv7511/fix-13](../adv7511/fix-13-housekeeping.md) |
| 1 | `dll_28 → clk_148` | `AGNUS1/beamcon0_reg[6]` → `adv_ddr/vsync_s` through combinational logic (CDC-10) | [adv7511/fix-13](../adv7511/fix-13-housekeeping.md) |
| 2 (Warning) | `clk_114 → clk_148` | `s_next_buf_reg` synchroniser missing `ASYNC_REG` | [adv7511/fix-13](../adv7511/fix-13-housekeeping.md) |

Once the fake SPI clock is removed and the reset is synchronised, the Critical
count drops from 365 to roughly 25, all of them nameable.

The `hoffset`/`voffset` crossing that [adv7511/fix-03](../adv7511/fix-03-offset-cdc.md)
describes did not appear in `report_cdc`, so it was queried directly
([verify2.tcl](vivado-reports/verify2.tcl), [50_posdata_paths.rpt](vivado-reports/50_posdata_paths.rpt)):

```
pos_data_q cells: 16     clock = dll_28
Source:       mycfide/vpos_interface.pos_data_q_reg[11]/C
Destination:  my_pal_to_ddr/my50hzupsample/r_addrb_reg[13]/D
Slack:        inf
Data Path:    3.423 ns (logic 1.390  route 2.033)
```

Confirmed, with one correction: the offset registers are clocked by **`dll_28`**
(cfide's `vpos_interface` runs on `clk_28`), not `clk_114`. The crossing is
`dll_28 → clk_148`, still inside the false-pathed group, still unsynchronised,
still combinational into the read address. `pos_data_q[11]` is a *voffset* bit
and it lands in the 50 Hz instance's horizontal read address — the crossed-port
wiring of [adv7511/fix-01](../adv7511/fix-01-crossed-offset-ports.md) is visible
in the routed netlist.

## Re-running

```bash
cd findings/constraints/vivado-reports
mkdir -p shim && ln -sf /lib/x86_64-linux-gnu/libtinfo.so.6 shim/libtinfo.so.5
LD_LIBRARY_PATH=$PWD/shim:$LD_LIBRARY_PATH \
  /opt/Xilinx/Vivado/2023.2/bin/vivado -stack 6000 -mode batch -nolog -nojournal -source verify.tcl
```

The `libtinfo.so.5` shim is needed on this machine — Vivado 2023.2 links
against ncurses 5, and Mint 22 ships only 6. The symlink is the standard
workaround and lives only in that directory.

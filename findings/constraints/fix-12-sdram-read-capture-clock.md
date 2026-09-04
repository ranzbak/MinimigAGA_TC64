# Fix 12 — Give the SDRAM read path its own capture clock

> **STATUS 2026-09-04: reverted from the working tree — does not run on hardware.**
> Implemented at +144 deg and +22.5 deg, and swept over the whole clock period with a
> runtime MMCM phase shift (`CLKOUT3_USE_FINE_PS` + a VIO, 15.7 ps steps) plus JTAG reset:
> **every phase from 0 to +8.8 ns gives a white screen.** A read-capture-timing fault would
> have a working phase window; this has none, so the dedicated capture clock is **not** the
> read-timing fix it was designed to be, or it introduces a second, phase-independent fault.
>
> An ILA on the SDRAM bus and host port (storage-qualified, triggered after a reset) shows the
> boot host writing the diagnostic program into SDRAM with the correct data and DQM, i.e. the
> write path and command stream are intact; the core still never runs. Simulation of the chip,
> CPU-cache and HOST ports with the real controller passes at all four corners, and Vivado
> static timing is clean (read setup +0.78, hold +0.54). So the failure is invisible to both
> simulation and static timing.
>
> Bisect: **HEAD RTL + the new constraints boots to Workbench**, so the constraint cleanup is
> good and the fix-12 RTL is the sole cause. The four RTL files were reverted to HEAD; the full
> fix-12 diff is kept at `scratchpad/fix12_keep/fix12_full.patch` and the RTL below documents
> the intent. **Do not re-apply without first explaining the phase-independent failure** — most
> likely the ILOGIC IFF on the bidirectional DQ pins, or the two-stage retime interacting with
> the write/output path, neither of which the unit sim exercises. Suggested next isolation
> steps: (a) keep the 2-stage + phase-table shift but clock `sdata_cap` on `clk_114` (no new
> clock, no IOB) - if that boots, the clk_sd_rd domain is the problem; (b) capture on clk_sd_rd
> but in fabric (drop `IOB=TRUE`) - if that boots, the IOB flop on the shared bidir pin is.


**Severity: High · Files: `rtl/clock/amiga_clk_xilinx.v`, `rtl/sdram/sdram_ctrl.v`,
`sdram.xdc`, `wizard.xdc:27` · Effect: read data lands on a different `clk_114`
edge depending on process corner and temperature — one word late at the slow
corner, on time at the fast corner**

## Implemented 2026-09-04 — first attempt failed on hardware, corrected

**Hardware result of the +144° build: red screen (Kickstart checksum).** Simulation
(chip and CPU/cache ports, all four corners) was clean, so the controller logic was
not the problem; the capture *phase* was. Two mistakes, both now fixed:

1. **The bench's fast corner was far too slow.** It assumed the clock-forwarding path
   (MMCM → BUFG → OBUF → `dr_clk`) is ~1.5 ns faster at the fast corner than at the
   slow one; Vivado's routed min/max say 3.62 vs 9.68 ns — a 6 ns spread. With the real
   spread the data window at a typical chip closes just *before* the +3.5 ns edge, so the
   flop caught the next word or the transition. Bench corners now come from Vivado's
   routed report (source clock delay − destination clock delay, IBUF only).
2. **The hold companion `-hold -end 1` was wrong and hid it.** N−1 assumes the launching
   register launches only every N cycles; the SDRAM launches a word every cycle in a
   burst, so the hold edge must stay one cycle before the setup edge (Vivado's default
   once setup is 2). With `-end 1` the check moved to the edge before the launch
   (requirement −2.3 ns, slack +6.4 ns, meaningless) and a ~2 ns fast-corner hold
   violation went unreported. `sdram.xdc` now has the setup multicycle only.

Balancing Vivado's extreme corners puts the capture edge at **+0.551 ns (22.5°)** after
`clk_114`: about +0.7 ns setup at the slow corner and +0.7 ns hold at the fast corner.
The phase-table shift (consumers one phase later) is unchanged — the capture still
lands on the second `clk_sd_rd` edge after the SDRAM edge, retimed to `clk_114`.
Bench with the corrected corners: `READ OK` / `CPU READ OK` everywhere; tightest
margins slow-corner setup 1.04 ns (−7 grade), fast-corner word-7 hold 0.63 ns (tHZ).

**+22.5° also fails on hardware** (host firmware dies before its first SD access;
solid white/green/yellow = its progress colours). Bisect: HEAD RTL + the new
constraints boots to Workbench, so the constraint work is sound and the fix-12 RTL
is what fails on this board — at two phases 2.9 ns apart, while the bench (chip, CPU
cache and HOST ports, real RTL) and Vivado's min/max analysis both pass. The real
data window on this SDRAM module is therefore narrower or elsewhere than modelled;
the original fabric capture (clk_114 + ~1.5 ns route) happens to sit inside it,
marginally ("a few resets, then stable").

Next: measure instead of model — diagnostic build with `CLKOUT3_USE_FINE_PS` and a
VIO to step the capture phase (15.7 ps/step) and reset the system over JTAG, sweep
on the board, take the centre of the working range.

The +144° section below is kept as the record of the first attempt.

### First attempt (+144°) — superseded

Done as described below, with two deviations. Build reports in
[impl-reports-fix12/](impl-reports-fix12/), post-fix bench logs
`sim-logs/fix12_*.log`, bitstream
`project_1/project_1.runs/impl_1/minimig_openaars_top.bit`.

* `CLKOUT3_PHASE` is **144°** (+3.526 ns), not 143° — the closest value on the
  MMCM's phase grid for a /10 output. `clk_sd_rd` is declared in `clocks.xdc`,
  passed as `clk_sd_rd` through `amiga_clk.v` (simulation path: `clk_114`
  delayed 3.526 ns) and `minimig_virtual_top.v` into `sdram_ctrl` port `rdclk`.
* The read path is **not** single-cycle in Vivado's terms. The launch edge is
  the SDRAM clock at the pin (5.84 ns, `clk_gen_sdram` includes the −121.5°
  shift and the BUFG→OBUF path) and the intended capture edge is the second
  `clk_sd_rd` edge (21.16 ns), so `sdram.xdc` keeps
  `set_multicycle_path -setup -end 2 / -hold -end 1` — now to `clk_sd_rd`.
* Consumers moved by one phase: `cache_fill_1/2` are used through a registered
  copy (`cache_fill_1_d/_2_d`), chip taps are ph10–ph13. The comment table in
  `sdram_ctrl.v` was updated.

Results (routed, −2 speed grade):

| Path | Before | After |
|---|---|---|
| `clk_gen_sdram → clk_sd_rd` (dr_d → `sdata_cap`, in IOB) | `→ clk_114` **−0.349**, 16/16 failing | **+3.757** setup / +6.383 hold, 0 failing |
| `clk_sd_rd → clk_114` (`sdata_cap → sdata_reg` retime) | — | +2.672 setup / +3.461 hold |
| `clk_114 → clk_gen_sdram` (write/command) | +0.834 | +0.609 |
| `clk_114` intra | +1.258 | +1.130 |
| Design WNS / WHS | −0.349 / +0.027 | **+0.345 / +0.027**, all constraints met |

Vendor-model bench: `READ OK` at all four corner/grade combinations, word 0
on ph8 everywhere (before: ph9 at the slow corner). LUTs 14,412 (−7), 16 more
flip-flops. `TIMING-47` count 10 → 12 from adding `clk_sd_rd` to the two
`-datapath_only` lists. `report_exceptions -ignored` still shows the `dr_d`
multicycle as "non-existent path" while `report_timing` applies it — the same
port-scoped quirk as before.

Hardware: **failed** (red screen) — see the top of this section.

---

## Evidence

Static: with correct delay formulas ([fix 1](fix-01-sdram-delay-formulas.md))
the read path reports **−1.295 ns** while the write path has only **+0.672 ns**
spare — the one shared phase (`CLKOUT1_PHASE`) cannot serve both
([sdram-read-path.md](sdram-read-path.md)).

Dynamic: vendor-model simulation, controller unmodified
([sdram-sim-results.md](sdram-sim-results.md), logs in [sim-logs/](sim-logs/)):

```
                      chipRD   chip48              word 0 lands on
slow corner, -7 part  ZZZZ     A000 A111 A222      ph9   <- one word LATE
slow corner, -6 part  ZZZZ     A000 A111 A222      ph9   <- one word LATE
fast corner, -7 part  A000     A111 A222 A333      ph8   <- correct
fast corner, -6 part  A000     A111 A222 A333      ph8   <- correct
```

Word 0 arrives 1.12 ns **after** the intended edge at the slow corner and
1.49 ns **before** it at the fast corner. Real hardware sits between the two;
the crossover moves with temperature. Every previous phase value (−146.25°,
−144°, −121.5°) moved the crossover, none removed it.

The write side raised no setup/hold violation at either corner — the current
phase is right for writes and must stay.

## Root cause

`rtl/sdram/sdram_ctrl.v:329-331`:

```verilog
always @ (posedge sysclk) begin
    sdata_reg <= #1 sdata;
```

Read data is sampled on the same edge that launches commands and write data.
There is no independent adjustment for the read sample point, so the round
trip (≈ 9.7 ns clock-out + 5.4 ns tAC + 3 ns in ≈ 18 ns, more than two periods)
has to land on a `clk_114` edge by luck.

## Fix

### 1. Fourth MMCM output, `rtl/clock/amiga_clk_xilinx.v`

```verilog
    .CLKOUT3_DIVIDE(10),          // 113.4375 MHz, same as clk_114
    .CLKOUT3_PHASE(143.0),        // +3.5 ns after clk_114 — see derivation below
    ...
    .CLKOUT3(sdr_rd_clk),
    ...
BUFG BUFG_SDR_RD (.I(sdr_rd_clk), .O(c3));
```

Route `c3` through `amiga_clk.v` to `minimig_virtual_top.v` and into
`sdram_ctrl` as a new input `rdclk`.

Derivation: measured data window at `sdata_reg/D` is [24.1, 29.9] ns at the
slow corner and ≈ [20.3, 26.0] at the fast corner against a sample edge at
22.8 / 21.1. Centring both gives +3.5 ns = 143°. Simulated margins with +3.5 ns:
setup ≥ 2.38 ns, hold ≥ 0.93 ns (word 7, fast corner, limited by tHZ), word 0
on **ph8 in every run**. +3.2 ns (131°) balances the fast-corner tHZ case a
little better. Confirm once with `report_timing` after the change; it is a
derived number, not a tuned one.

### 2. IOB capture flop plus retime, `rtl/sdram/sdram_ctrl.v`

Replace the single `sdata_reg` stage:

```verilog
(* IOB = "TRUE" *) reg [15:0] sdata_cap;
always @ (posedge rdclk)  sdata_cap <= sdata;        // sits in the data window
always @ (posedge sysclk) sdata_reg <= sdata_cap;    // sibling-clock hop, timed automatically
```

`rdclk` and `sysclk` come from one MMCM with a fixed phase, so the second stage
is an ordinary synchronous path with 8.815 − 3.5 = 5.3 ns available.

### 3. Shift the phase table by one

`sdata_reg` now holds word 0 one cycle later than the current fast-corner
behaviour. Move the consumers one state:

| Consumer | today | after |
|---|---|---|
| `cache_fill_1` first raised | ph8 (`:660`) | ph9 |
| `chipRD <= sdata_reg` | ph9 (`:311`) | ph10 |
| `chip48_1..3` | ph10–12 | ph11–13 |
| `cache_fill_2` first raised | ph0 (`:566`) | ph1 |
| slot-2 read taps | as listed at `:760-776` | +1 |

Update the comment table at `:760-776` from the constraint, not the other way
round. Re-run [sim/sdram_timing/](../../sim/sdram_timing/) on the modified
controller — `chipRD` must read `A000` at all four corner/grade combinations
before touching hardware.

### 4. Constraints, `sdram.xdc` and `wizard.xdc`

Single-cycle from the SDRAM edge to `rdclk`; no multicycle:

```tcl
set sdram_tac_max 5.4          ;# datasheet, fitted speed grade
set sdram_toh_min 2.5
set sdram_tr_dly  0.17

set_input_delay -clock [get_clocks clk_gen_sdram] -max \
    [expr {$sdram_tac_max + $sdram_tr_dly}] [get_ports {dr_d[*]}]
set_input_delay -clock [get_clocks clk_gen_sdram] -min \
    [expr {$sdram_toh_min + $sdram_tr_dly}] [get_ports {dr_d[*]}]
```

Delete `sdram.xdc:73-75` (the `-setup 2` / `-hold 2` pair) and `wizard.xdc:27`.
Add the generated-clock rename for CLKOUT3 next to the others in `clocks.xdc`.

### 5. Leave `CLKOUT1_PHASE` alone

It serves only the write/command side now. It has +0.67 ns; do not move it
until the read side is independent, then only if the write side needs it.

## Diagnostic before committing to the MMCM work

One-build experiment on a board that fails warm:

```verilog
reg [15:0] sdata_neg;
always @ (negedge sysclk) sdata_neg <= sdata;       // +4.4 ns
always @ (posedge sysclk) sdata_reg <= sdata_neg;
```

with the phase-table shift from step 3. Simulation says this passes the slow
corner cleanly and fails word 7 at the fast corner by 0.02 ns — good enough to
prove the diagnosis, not good enough to ship.

## Verify

* [sim/sdram_timing/run.sh](../../sim/sdram_timing/run.sh) at all four
  combinations: `chipRD == A000`, `chip48 == A111 A222 A333`, word 0 on the
  same edge everywhere, no `HD!`/`SU!` in the as-built column.
* `report_timing -from [get_ports {dr_d[*]}]`: single-cycle requirement, slack
  ≥ +1 ns at the slow corner.
* `report_exceptions -ignored`: nothing left on the read path.
* Hardware: memory test (e.g. `SysTest`/`AmigaTestKit` RAM test) at cold start
  and after 30 minutes in a closed case.

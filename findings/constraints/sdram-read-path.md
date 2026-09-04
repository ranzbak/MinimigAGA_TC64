# The SDRAM read path, edge by edge

Companion to [fix-01-sdram-delay-formulas.md](fix-01-sdram-delay-formulas.md).
Explains *why* the read side cannot be tuned into reliability with the current
structure, using Vivado's routed numbers
([vivado-reports/32_sdram_in_AFTER.rpt](vivado-reports/32_sdram_in_AFTER.rpt)).

## The structure

`rtl/sdram/sdram_ctrl.v`:

```verilog
// commands, addresses, write data: launched on posedge sysclk (clk_114)
always @ (posedge sysclk) begin
    ...
    sd_cmd  <= #1 CMD_READ;         // in state ph4  -> on the pins during ph5
    ...
end

// read data: captured on the SAME edge
always @ (posedge sysclk) begin     // :329
    sdata_reg <= #1 sdata;
end
```

`dr_clk` to the SDRAM is `clk_sd_114` = `clk_114` shifted by `CLKOUT1_PHASE`
(`rtl/clock/amiga_clk_xilinx.v:37`, currently −121.5°, was −144° and −146.25°
in earlier revisions). Mode register: CL = 3, burst 8
(`sdram_ctrl.v:498`).

There is exactly one adjustable timing parameter — the phase — and it is shared
by:

* the **write/command** relationship (FPGA launches on `clk_114`, SDRAM
  samples on `dr_clk`), and
* the **read** relationship (SDRAM launches on `dr_clk`, FPGA samples on
  `clk_114`).

Moving `dr_clk` earlier helps reads (data comes back sooner) and hurts writes
(less setup at the SDRAM). Moving it later does the reverse.

## Where the two sides stand today

After correcting the delay formulas (fix 1), Vivado reports, slow corner:

| Direction | Worst path | Slack |
|---|---|---|
| Write / command | `sdata_out_reg[9] → dr_d[9]` | **+0.672 ns** |
| Read | `dr_d[9] → sdata_reg_reg[9]` | **−1.295 ns** |

Total shortfall across both sides ≈ 0.6 ns if one phase had to serve both.
There is no value of `CLKOUT1_PHASE` that closes both at the slow corner.

## The read timeline

All times in ns from the MMCM output, slow corner, taken from the report:

```
 5.840   dr_clk edge, nominal  (the "launch" Vivado picks: E1 - 2.975)
10.022   after BUFG_SDR                            (+4.18 clock insertion)
12.540   after routing to the IOB                  (+2.52)
15.519   at the dr_clk pin                         (+2.98 OBUF)
21.089   SDRAM output valid                        (+tAC 5.57 = 5.4 + 0.17 trace)
22.534   after IBUF                                (+1.445)
24.11    at sdata_reg/D                            (+route ~1.58)

22.82    required time = capture edge E2 (17.631) + insertion (~5.2)
```

Arrival 24.11 vs required 22.82 → **−1.3 ns**. That is the reported violation.

The valid window does not close until the SDRAM's *next* edge plus tOH:

```
24.33    next dr_clk edge at the pin (15.519 + 8.815)
26.83    SDRAM output changes                      (+tOH 2.5)
~29.9    at sdata_reg/D                            (+IBUF 1.45 + route 1.58)
```

So at the slow corner the data is stable at the flop over **[24.1, 29.9]** — a
5.8 ns window — and the available capture edges are at **22.8** (1.3 ns before
it opens) and **31.6** (1.7 ns after it closes). No `clk_114` edge is inside.

### Fast corner (estimated)

Clock insertion ≈ 3.5, OBUF ≈ 2.0, IBUF ≈ 0.9, route ≈ 1.0, net ≈ 1.8; tAC and
tOH unchanged:

```
window at sdata_reg/D   ≈ [20.3, 26.0]
capture edge            ≈  21.1
```

Inside the window, 0.8 ns from its leading edge.

### Reading the two corners together

Works on a cold board, marginal on a warm one, fails on a hot one or a slower
die. This is the signature of a sampling edge that sits at the *edge* of the
window rather than in its middle, and it is what a fixed-phase single-clock
scheme will always produce once the round-trip delay (≈ 9.7 ns clock out +
5.4 ns tAC + 3 ns in ≈ 18 ns) exceeds two clock periods.

## The RTL and the constraint disagree by one cycle

`sdram_ctrl.v` comment table (`:760-776`):

```
// ph4   CAS, auto p/c
// ...
// ph9   read0
```

and the consumers agree with it — `chipRD <= sdata_reg` in state ph9
(`:311`), `cache_fill_1` raised from state ph8 (`:660`) so the cache samples
`sdr_dat_r` from the end of ph9.

For that to hold, `sdata_reg` must capture word 0 at the edge that ends ph8.
Counting from the READ command: set in ph4 → on the pins in ph5 → sampled by
the SDRAM at the `dr_clk` edge Vivado pairs with it (5.84 ns after the ph5
launch edge) → CL 3 → data launched three SDRAM edges later → arrives at the
flop 24.1 ns after *that* edge → captured **two** `clk_114` cycles after the
launching SDRAM edge. That is what the `-setup 2` multicycle in `sdram.xdc:74`
says, and it puts word 0 in `sdata_reg` one cycle *later* than the comment
table.

Commit ae11724 introduced the multicycle and the −121.5° phase together. The
constraint was fitted to the report, not derived from the RTL, and at this
point neither the comment table nor the exception can be trusted to say which
edge the data really lands on. That is not a criticism — it is exactly the
situation a single-phase read/write clock forces you into.

## Fix: a dedicated read-capture clock

Decouple the read sample point from the command clock. This is the standard
7-series SDR SDRAM pattern and it removes the multicycle entirely.

### 1. Add a capture clock

`rtl/clock/amiga_clk_xilinx.v` — add a fourth MMCM output:

```verilog
    .CLKOUT3_DIVIDE(10),          // 113.4375 MHz, same as clk_114
    .CLKOUT3_PHASE(143.0),        // +3.5 ns: centre of the slow-corner window, see below
    ...
    .CLKOUT3(sdr_rd_clk),
    ...
BUFG BUFG_SDR_RD (.I(sdr_rd_clk), .O(c3));
```

Phase derivation: slow-corner window centre at the flop ≈ (24.1 + 29.9)/2 =
27.0; current capture edge 22.8; shift ≈ +4.2 ns. Fast-corner window centre
≈ 23.2 vs edge 21.1; shift ≈ +2.1 ns. Split the difference: **+3.5 ns**
= 3.5 / 8.815 × 360° ≈ **+143°**. Confirm with `report_timing` after the
change and adjust once; the point is that it becomes a *derived* number.

### 2. Capture in the IOB on that clock, retime to sysclk

```verilog
// sdram_ctrl.v — replace the single sdata_reg stage
(* IOB = "TRUE" *) reg [15:0] sdata_cap;
always @ (posedge sdr_rd_clk) sdata_cap <= sdata;      // sits in the data window
always @ (posedge sysclk)     sdata_reg <= sdata_cap;  // sibling-clock transfer, timed automatically
```

`sdr_rd_clk` and `clk_114` come from the same MMCM with a fixed phase, so the
`sdata_cap → sdata_reg` path is an ordinary synchronous path: with +3.5 ns of
phase it gets 8.815 − 3.5 = 5.3 ns, ample for a register-to-register hop.

### 3. Constrain honestly, single cycle

`sdram.xdc` — replace lines 73-75 and 92-97:

```tcl
set sdram_tac_max 5.4          ;# from the fitted part's datasheet
set sdram_toh_min 2.5
set sdram_tr_dly  0.17

set_input_delay -clock [get_clocks clk_gen_sdram] -max \
    [expr {$sdram_tac_max + $sdram_tr_dly}] [get_ports {dr_d[*]}]
set_input_delay -clock [get_clocks clk_gen_sdram] -min \
    [expr {$sdram_toh_min + $sdram_tr_dly}] [get_ports {dr_d[*]}]
# no multicycle: one SDRAM edge -> one sdr_rd_clk edge
```

and delete `wizard.xdc:27`.

### 4. Leave `CLKOUT1_PHASE` to the write side

It has +0.67 ns today. Reads no longer depend on it, so it can be nudged later
if the write side needs margin, without a read-side penalty.

### 5. Re-derive the phase table

`sdata_reg` now holds word 0 one cycle later than it did (two register stages
instead of one). Shift the consumers by one state: `cache_fill_1` from ph9
instead of ph8, `chipRD` tap at ph10, `chip48_*` at ph11–13, and the slot-2
equivalents. Update the comment table at `:760-776` to match — and this time
it will be derived from the constraint rather than the other way round.

## A five-minute experiment first

Before the MMCM work, prove the diagnosis on hardware:

```verilog
reg [15:0] sdata_neg;
always @ (negedge sysclk) sdata_neg <= sdata;       // +4.4 ns
always @ (posedge sysclk) sdata_reg <= sdata_neg;
```

That samples at 22.8 + 4.4 = 27.2 — dead centre of the slow-corner window
[24.1, 29.9] — and at ≈ 25.5 in the fast-corner window [20.3, 26.0], only
0.5 ns from its trailing edge. Not a production answer, but if a board that
fails warm starts passing with this change, the diagnosis is confirmed and the
proper +143° capture clock is worth doing. Shift the consumers by one phase as
in step 5.

## Settled by simulation

The vendor-model testbench in [sim/sdram_timing/](../../sim/sdram_timing/)
reproduces both corners — see [sdram-sim-results.md](sdram-sim-results.md).
Slow corner: word 0 arrives 1.12 ns *after* the ph8 edge, is captured on ph9,
and `chipRD` returns Hi-Z. Fast corner: word 0 arrives 1.49 ns *before* ph8 and
everything is correct. The +3.5 ns capture clock lands word 0 on ph8 at every
corner and grade with ≥ 2.4 ns setup / ≥ 0.9 ns hold; the negedge shortcut
fails word 7 at the fast corner by 0.02 ns.

## What would have settled the remaining doubt (now done)

A gate-level or RTL simulation with a timing-accurate SDRAM model — the vendor
Verilog models for AS4C16M16SA / W9825G6KH carry tAC and tOH — driven at the
slow-corner delays above. `sim/cpu_cache_sdram/` currently has no such model.
Ten minutes of setup; it would show unambiguously which `clk_114` edge word 0
lands on at each corner and end the guesswork for good.

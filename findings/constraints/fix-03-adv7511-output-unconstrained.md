# Fix 3 — The ADV7511 output interface is completely unconstrained

**Severity: High · Files: `clocks.xdc:8, :25`, `adv7511_video.xdc:65-66` ·
Effect: `dv_d[11:0]`, `dv_de`, `dv_hsync`, `dv_vsync` have no setup or hold check
against `dv_clk`**

## Evidence

`adv7511_video.xdc:64-66` sets output delays against a virtual clock:

```tcl
# Set output delays for the high speed ADV7511 ports
set_output_delay -clock [get_clocks VIRTUAL_clk_148] -min -add_delay -1.000 [get_ports {{dv_d[*]} dv_clk dv_de dv_hsync dv_vsync dv_vsync}]
set_output_delay -clock [get_clocks VIRTUAL_clk_148] -max -add_delay 0.700 [get_ports {{dv_d[*]} dv_clk dv_de dv_hsync dv_vsync dv_vsync}]
```

`clocks.xdc:25` then deletes every path they create:

```tcl
set_clock_groups -asynchronous -group [get_clocks clk_148] -group [get_clocks VIRTUAL_clk_148]
```

The launch clock is `clk_148`; the capture clock is `VIRTUAL_clk_148`. Declaring
those two asynchronous removes the entire path group. Confirmed twice in the
routed report:

```
TIMING-47#2  A Clock Group timing constraint is set between synchronous clocks
             clk_148 and VIRTUAL_clk_148 (constraint position 7).
             Masking entire synchronous clock domains via set_false_path,
             set_clock_groups or set_max_delay -datapath_only may result in
             failure in hardware.

User Ignored Path Table:
  (none)   clk_148   VIRTUAL_clk_148
```

## Four compounding problems

1. **The async group masks everything** (above).
2. **`dv_clk` has no generated clock.** It is driven from a plain fabric
   flip-flop, `adv_ddr.v:159`:
   ```verilog
       clk_pixel_out <= clk_pixel_s[1];
   ```
   No `create_generated_clock` exists on the port, so the data-to-clock
   relationship at the pin is never expressed.
3. **`dv_clk` is in the *data* list** of both `set_output_delay` calls. A
   forwarded clock is the reference, not a constrained datum.
4. **`dv_vsync` appears twice** in each list, and `dv_cecclk` has a pin
   assignment (`adv7511_video.xdc:41`) but no constraint of any kind.

## Fix

Delete `clocks.xdc:25` and the `VIRTUAL_clk_148` declaration at `clocks.xdc:8`.
Replace with a real forwarded-clock model:

```tcl
# dv_clk is the pixel clock forwarded to the ADV7511 (74.25 MHz, clk_148 / 2)
create_generated_clock -name dv_clk_out -divide_by 2 \
  -source [get_pins my_pal_to_ddr/myadr_ddr/clk_pixel_out_reg/C] \
  [get_ports dv_clk]

set dv_data [get_ports {dv_d[*] dv_de dv_hsync dv_vsync}]

# ADV7511 input setup/hold, plus board trace delay. CHECK against the datasheet.
set adv_tsu   0.70
set adv_th    1.00
set adv_trace 0.10

set_output_delay -clock dv_clk_out -max [expr { $adv_tsu + $adv_trace}] -add_delay $dv_data
set_output_delay -clock dv_clk_out -min [expr {-$adv_th  + $adv_trace}] -add_delay $dv_data
set_output_delay -clock dv_clk_out -max [expr { $adv_tsu + $adv_trace}] -clock_fall -add_delay $dv_data
set_output_delay -clock dv_clk_out -min [expr {-$adv_th  + $adv_trace}] -clock_fall -add_delay $dv_data
```

**The `-clock_fall` pair is mandatory.** The bus is 12-bit DDR: `data_out` is
driven on every `clk_148` edge (148.5 MHz) against a 74.25 MHz `dv_clk`, so both
clock edges capture data at the sink. Without `-clock_fall` only half the
transfers are checked.

The `0.70` / `1.00` above are what the existing constraint implies
(`-max 0.700`, `-min -1.000`). Confirm them against the ADV7511 datasheet for
the input mode configured by `i2c_sender.vhd`, and add the real board trace
delay.

## Strongly recommended: forward `dv_clk` through an ODDR

`clk_pixel_out` is an ordinary FDRE, so the clock reaches the pad through a
fabric route that is neither matched to the data paths nor deterministic across
builds. The standard 7-series pattern:

```verilog
ODDR #(
  .DDR_CLK_EDGE("OPPOSITE_EDGE"),
  .INIT(1'b0),
  .SRTYPE("SYNC")
) dv_clk_oddr (
  .Q  (dv_clk),
  .C  (clk_pixel_int),   // the 74.25 MHz clock, on a BUFG
  .CE (1'b1),
  .D1 (1'b1),
  .D2 (1'b0),
  .R  (1'b0),
  .S  (1'b0)
);
```

This puts the clock through the same IOB structure as the data, makes the
`create_generated_clock` above exact, and lets the tool balance clock and data
skew rather than leaving it to routing luck.

If the ODDR is adopted, source the generated clock from the ODDR's `C` pin
instead of a fabric register output.

## Why this is worth doing before the RTL work

An unconstrained source-synchronous output can produce artefacts that look
exactly like the RTL bugs in [../adv7511/](../adv7511/) — intermittent wrong
pixels, edge-dependent colour errors, a sink that occasionally loses lock.
Closing this first means the remaining symptoms are attributable.

## Verify

```tcl
report_timing -to [get_ports {dv_d[*]}] -max_paths 20 -delay_type min_max
check_timing -verbose -override_defaults {no_output_delay}
```

The first must return real paths with real requirements rather than "No paths
found". The User Ignored Path Table must no longer contain
`clk_148 → VIRTUAL_clk_148`.

## Verified in Vivado (2026-09-04)

[13_dv_out.rpt](vivado-reports/13_dv_out.rpt): every `dv_d[*]`, `dv_de`,
`dv_hsync`, `dv_vsync` path reports `Slack: inf`.
[02_clock_interaction.rpt](vivado-reports/02_clock_interaction.rpt):
`clk_148 → VIRTUAL_clk_148  16 endpoints  Ignored  Asynchronous Groups`.

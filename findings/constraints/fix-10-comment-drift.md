# Fix 10 — Comments that contradict the values beside them

**Severity: Cosmetic · Effect: every future audit has to re-derive which of the
two is right**

None of these changes behaviour. All of them cost time the next time somebody
reads the file.

## 1. Phase shift comment is wrong by 22.5 degrees

`rtl/clock/amiga_clk_xilinx.v:37`:

```verilog
    .CLKOUT1_PHASE(-121.5), // -144.00' phase shift
```

The value is −121.5°. The Clock Summary confirms it propagated correctly:

```
clk_sd_114   {-2.975 1.433}   8.815   113.438
```

−121.5° of 8.815 ns is −2.975 ns. Fix the comment.

## 2. Phase shift restated in nanoseconds, also wrong

`fpga/openaars/aars_v5.0/xc7a100t/sdram.xdc:57-62`:

```tcl
# Input clocks
# A safe amount of phase shift is at least the output hold time of your far-end device,
# plus your best-case (fastest) calculated round-trip flight time, entered as your set_output_delay -min value (entered as a negative number for hold time.)
# output hold time sdram = 2.5 ns
# 60mm trace length = 0.7ns 6ns/meter * 0.06m *2
# Phase shift SDRAM = 3.2 ns
```

The actual shift is 2.975 ns, not 3.2 ns.

Note also that this comment block correctly describes the `set_output_delay -min`
convention — "entered as a negative number for hold time" — which is exactly what
the code below it fails to do. See
[fix-01-sdram-delay-formulas.md](fix-01-sdram-delay-formulas.md).

The trace-delay arithmetic is also inconsistent with the code: the comment
derives 0.7 ns for a 60 mm round trip, but `sdram_tr_dly` is set to `0.17`.
Decide which is right and make both agree.

## 3. A comment reading "Incorrect" above live constraints

`fpga/openaars/aars_v5.0/xc7a100t/wizard.xdc:17-20`:

```tcl
# # Dram to cache line constraints
# Incorrect
set_multicycle_path -from [get_pins -hier -regexp openaars_virtual_top/sdram/cpu_cache/dtram/.*] -to [get_pins -hier -regexp openaars_virtual_top/sdram/cpu_cacheline_.*] -setup 2
set_multicycle_path -from [get_pins -hier -regexp openaars_virtual_top/sdram/cpu_cache/dtram/.*] -to [get_pins -hier -regexp openaars_virtual_top/sdram/cpu_cacheline_.*] -hold 1
```

Either fix them or delete them. A known-wrong exception left enabled is worse
than no exception, because it silences a check nobody knows is silenced.

(The `-setup 2` / `-hold 1` pair itself uses mismatched default options —
`-setup` defaults to `-end`, `-hold` to `-start`. See
[fix-06-missing-hold-companion.md](fix-06-missing-hold-companion.md).)

## 4. Misleading MMCM output comment

`rtl/soc/minimig_openaars_top.v:292`:

```verilog
  .CLKOUT0(clk_148), //  100 MHz HDMI base clock
```

It is 148.5 MHz — `50 × 37.125 / 2 / 6.25`. The `.CLKOUT0_DIVIDE_F(6.25)` line
two lines above says so correctly.

## 5. Stale commented-out constraints

`adv7511_video.xdc` carries three separate abandoned attempts at the output
constraint (`:48-50`, `:53-56`, `:58-60`), including a `fw_clk_148` clock that no
longer exists and `set_output_delay ... 4+1.5` which is not valid Tcl in that
position. `clocks.xdc:19-20` and `i2s.xdc:15` have similar leftovers.

Delete them. Git holds the history; commented-out constraints in a live file
read as "this might be needed" and get copied forward.

## 6. Missing trailing newline

`fpga/openaars/aars_v5.0/xc7a100t/clocks.xdc` ends without a newline after line
25. Harmless to Vivado, annoying in diffs.

## Suggested cleanup pass

Once fixes 1–9 are in, do one commit that:

* corrects the four comments above,
* deletes every commented-out constraint,
* adds a one-line rationale above each `set_false_path` (see
  [fix-09-unconstrained-ports.md](fix-09-unconstrained-ports.md)),
* settles on a single style for referencing MMCM clocks (see
  [fix-08-generated-clocks.md](fix-08-generated-clocks.md)).

# Fix 2 — `dll_28 → clk_114` hold check is switched off

**Severity: High · File: `fpga/openaars/aars_v5.0/xc7a100t/wizard.xdc:23-24` ·
Effect: 79 ns of fake hold slack across 2701 endpoints on an edge-aligned MMCM
crossing**

## Evidence

`wizard.xdc:22-24`:

```tcl
# From 28 -> 114 MHz four cycles in the 114 network
set_multicycle_path -setup -from [get_clocks dll_28] -to [get_clocks clk_114] 4
set_multicycle_path -hold -from [get_clocks dll_28] -to [get_clocks clk_114] 3
```

Neither line states `-start` or `-end`. The SDC defaults are **not the same for
the two**:

* `-setup` defaults to `-end` — moves the **capture** edge.
* `-hold` defaults to `-start` — moves the **launch** edge.

Vivado flags the mismatch:

```
TIMING-29#1  Inconsistent pair of multicycle paths
Setup and hold multicycle path constraints should typically reference the same
-start pair for SLOW-to-FAST synchronous clocks or -end pair for FAST-to-SLOW
```

## The arithmetic

`dll_28` = 28.359 MHz (35.262 ns), `clk_114` = 113.438 MHz (8.815 ns), ratio 4,
edges aligned at t = 0.

| Check | Launch | Capture | Requirement |
|---|---|---|---|
| Default setup | 0 | +8.815 | 8.815 ns |
| Default hold | 0 | 0 | 0 ns |
| With `-setup 4` (= `-end 4`) | 0 | +35.262 | 35.262 ns ✔ intended |
| With `-hold 3` (= `-start 3`) | −105.786 | +26.447 | **−79.3 ns** ✘ |

The intended relaxation moves the *capture* edge; `-start` moved the *launch*
edge three **slow** periods into the past instead. The report confirms it to
within rounding:

```
From Clock   To Clock   WHS(ns)    THS Total Endpoints
dll_28       clk_114     78.999                   2701
```

3 × 35.262 − 3 × 8.815 = 79.3 ns. A hold slack of 79 ns is not a margin; it is a
check that is not being performed, on 2701 endpoints.

## Why this matters

`dll_28` and `clk_114` are outputs of the **same MMCM** with aligned edges. The
real hold requirement at t = 0 is near zero, and the real margin depends entirely
on BUFG-to-BUFG skew and routing. That is precisely the case where a hold
violation is plausible — and precisely the check that has been disabled.

For contrast, the fast→slow pair at `wizard.xdc:43-44` gets this right and
reports a sane number:

```tcl
set_multicycle_path -setup -start -from ...CLKOUT0 -to ...CLKOUT2 4
set_multicycle_path -hold  -start -from ...CLKOUT0 -to ...CLKOUT2 3
```

```
clk_114 → dll_28   WHS = 0.069 ns
```

## Fix

```tcl
# From 28 -> 114 MHz: SLOW to FAST, relax the capture edge
set_multicycle_path -setup -end -from [get_clocks dll_28] -to [get_clocks clk_114] 4
set_multicycle_path -hold  -end -from [get_clocks dll_28] -to [get_clocks clk_114] 3
```

`-setup -end 4` is what the file already gets by default; the change is adding
`-end` to the hold line. Stating both explicitly also documents the intent.

## The recipes, for reference

| Direction | Setup | Hold |
|---|---|---|
| Slow → Fast (ratio N) | `-setup -end N` | `-hold -end N-1` |
| Fast → Slow (ratio N) | `-setup -start N` | `-hold -start N-1` |

`wizard.xdc:43-44` (fast→slow) already follows row two. `wizard.xdc:23-24`
(slow→fast) needs row one.

## What to expect

After the fix, `dll_28 → clk_114` WHS will drop from 79 ns to something in the
tens or hundreds of picoseconds. **If it goes negative, that is a real hold
violation that has been hidden since the constraint was written**, and it must be
fixed in the design — an extra pipeline stage, a proper 2-FF synchroniser, or
`ASYNC_REG` on the capture registers.

The multicycle itself is legitimate. The data is genuinely stable for four
`clk_114` cycles because it comes from a quarter-rate clock. Only the hold
option is wrong.

## Verify

```tcl
report_timing -hold -from [get_clocks dll_28] -to [get_clocks clk_114] -max_paths 20
```

Check the "Requirement" line reads something near 0 ns, not −79 ns, and inspect
the worst paths that appear.

## Verified in Vivado (2026-09-04)

Applied only `-hold -end 3` in memory and re-timed
([30_hold_dll28_clk114_AFTER.rpt](vivado-reports/30_hold_dll28_clk114_AFTER.rpt)):

```
before   WHS  78.999 ns    0 failing / 2701
after    WHS  -0.340 ns   49 failing / 2701    THS -8.826 ns

-0.340  AMBER1/blue_out_reg[7]  -> blue_reg_reg[7]    req 0.000  data 0.305  clock skew 0.315
-0.325  AMBER1/green_out_reg[1] -> green_reg_reg[1]
-0.310  AMBER1/green_out_reg[4] -> green_reg_reg[4]
-0.310  autoconfig/board_configured_reg[3] -> tg68k/z3ram3_ena_reg
-0.290  AMBER1/red_out_reg[4]   -> red_reg_reg[4]
```

Real hold violations, hidden since the constraint was written, on the VGA RGB
registers that feed the HDMI upsampler. The router will fix these once it can
see them — re-implement with the corrected constraint and confirm WHS ≥ 0.

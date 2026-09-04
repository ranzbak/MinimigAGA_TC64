# Fix 6 — `clk_sd_114 → clk_114` setup relaxed with no hold companion

**Severity: Medium · File: `fpga/openaars/aars_v5.0/xc7a100t/wizard.xdc:26-27`**

## Evidence

```tcl
# The returning signals from SDRAM can take 2 cycles
set_multicycle_path -setup -from [get_clocks clk_sd_114] -to [get_clocks clk_114] 2
```

There is no matching hold constraint. Vivado:

```
XDCH-1#1  Hold option missing in multicycle path constraint
```

## Why it matters

`set_multicycle_path -setup N` moves the setup capture edge N periods later. The
hold check then defaults to the edge one before that — N−1 periods after launch.
For `N = 2` on same-frequency clocks that is a **positive hold requirement of one
full 8.815 ns period**, which no ordinary path can satisfy.

The reported `clk_sd_114 → clk_114  WHS = 15.990 ns` shows the check is passing,
but on 16 endpoints with an implausibly large margin — the reference edge is not
where a designer would expect it. Either way, an unpaired setup multicycle is
never intentional.

## Fix

```tcl
# The returning signals from SDRAM can take 2 cycles
set_multicycle_path -setup -end -from [get_clocks clk_sd_114] -to [get_clocks clk_114] 2
set_multicycle_path -hold  -end -from [get_clocks clk_sd_114] -to [get_clocks clk_114] 1
```

`clk_sd_114` and `clk_114` are the same frequency with a −121.5° phase offset, so
neither the slow→fast nor fast→slow rule strictly applies; use `-end` on both so
the pair is consistent and only the capture edge moves.

## The general rule

Every `set_multicycle_path -setup N` needs a `-hold N-1` with the **same**
`-start`/`-end` option. Grep the constraint set for setup multicycles and check
each has a partner:

```bash
grep -n "multicycle" fpga/openaars/aars_v5.0/xc7a100t/*.xdc
```

Current state of every pair in the tree:

| Location | Setup | Hold | Verdict |
|---|---|---|---|
| `wizard.xdc:7-8` | `-start 4` | `-start 3` | consistent |
| `wizard.xdc:11-12` | `-start 3` | `-start 2` | consistent |
| `wizard.xdc:14-15` | `-start 3` | `-start 2` | consistent |
| `wizard.xdc:19-20` | `2` (default `-end`) | `1` (default `-start`) | inconsistent options |
| `wizard.xdc:23-24` | `4` (default `-end`) | `3` (default `-start`) | **see [fix 2](fix-02-dll28-hold-multicycle.md)** |
| `wizard.xdc:27` | `2` | *(none)* | **this fix** |
| `wizard.xdc:31-32` | `-start 2` | `-start 2` | hold should be 1 |
| `wizard.xdc:34-35` | `-start 2` | `-start 2` | hold should be 1 |
| `wizard.xdc:43-44` | `-start 4` | `-start 3` | correct (fast→slow) |
| `sdram.xdc:74-75` | `2` | `2` | hold should be 1 |

Six of the ten need attention. Fixes
[2](fix-02-dll28-hold-multicycle.md), [4](fix-04-tg68k-blanket-multicycle.md) and
[1](fix-01-sdram-delay-formulas.md) cover the rest of the table.

## Verify

```tcl
report_methodology                     ;# XDCH-1 and TIMING-29 counts should be 0
report_timing -hold -from [get_clocks clk_sd_114] -to [get_clocks clk_114] -max_paths 20
```

## Verified in Vivado (2026-09-04)

`report_exceptions -ignored` shows position 21 (`wizard.xdc:27`) as "Totally
overridden path by MCP 47" and the `sdram.xdc:74-75` pair as displacing it. After
[fix 1](fix-01-sdram-delay-formulas.md) moves the input reference to
`clk_gen_sdram`, `report_timing -hold -from clk_sd_114 -to clk_114` returns
"No timing paths found" — `wizard.xdc:27` becomes dead. Delete it and keep the
single `-from [get_ports dr_d[*]]` pair in `sdram.xdc`.

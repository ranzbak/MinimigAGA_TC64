# Fix 5 — False path used for CDC, silently killing two other constraints

**Severity: Medium · File: `fpga/openaars/aars_v5.0/xc7a100t/wizard.xdc:39-47` ·
Effect: three constraints, one survivor, and the survivor checks nothing**

## Evidence

`wizard.xdc:39-47`:

```tcl
# All datapaths from the Minimig core to the HDMI output module use double flip flop transitions
# set_false_path -from [get_clocks -of_objects [get_pins .../CLKOUT2]] -to [get_clocks -of_objects [get_pins clk_hdmi/CLKOUT0]]
set_false_path -from [get_clocks {dll_28 clk_114 clk_sd_114}] -to [get_clocks clk_148]

set_multicycle_path -setup -start -from [...CLKOUT0] -to [...CLKOUT2] 4
set_multicycle_path -hold -start -from [...CLKOUT0] -to [...CLKOUT2] 3

set_max_delay -from [get_clocks -of_objects [get_pins .../CLKOUT0]] -to [get_clocks -of_objects [get_pins clk_hdmi/CLKOUT0]] 1.800
set_multicycle_path -hold -end -from [...CLKOUT0] -to [get_clocks -of_objects [get_pins clk_hdmi/CLKOUT0]] 2
```

SDC exception priority is `false_path` > `max_delay`/`min_delay` >
`multicycle_path`. Line 41 covers `clk_114 → clk_148`, which is exactly the scope
of line 46 and line 47. So:

* Line 41 — **applies**, and removes the paths entirely.
* Line 46 (`set_max_delay 1.800`) — **dead**.
* Line 47 (`-hold -end 2`) — **dead**.

Someone wrote a bounded crossing constraint and it has never had any effect.

Vivado reports the masking three times:

```
TIMING-47#6  A False Path timing constraint is set between synchronous clocks clk_114 and clk_148
TIMING-47#7  ... clk_sd_114 and clk_148
TIMING-47#8  ... dll_28 and clk_148
```

and the routed report's User Ignored Path Table confirms:

```
(none)   clk_114   clk_148
(none)   dll_28    clk_148
```

## Why a false path is the wrong tool here

`set_false_path` says "these paths can never matter". For a CDC that is not true
— the paths do carry data, they just cannot be timed conventionally. The
consequence is that placement is free to stretch the crossing to any length,
which breaks the assumption a two-flop synchroniser relies on: that the source
value is stable at the first capture flop's input for the whole clock period.

The correct expression is:

* `set_clock_groups -asynchronous` to say the domains are unrelated, plus
* `set_max_delay -datapath_only` to keep the net short enough that the
  synchroniser works.

## Fix

Replace line 41 and delete lines 46-47:

```tcl
set_clock_groups -asynchronous \
  -group [get_clocks {dll_28 clk_114 clk_sd_114}] \
  -group [get_clocks clk_148]

# Keep the crossing routed tightly so the 2-FF synchronisers have a full period
set_max_delay -datapath_only \
  -from [get_clocks {dll_28 clk_114 clk_sd_114}] -to [get_clocks clk_148] 6.734
```

`-datapath_only` is what makes `set_max_delay` legal alongside a clock group: it
bounds the data path without imposing a clock relationship. `6.734` is one
`clk_148` period; tighten it if the crossing routes easily.

## The two CDC warnings that go with this

```
TIMING-9#1   Unknown CDC Logic
  One or more asynchronous Clock Domain Crossing has been detected between 2
  clock domains through a set_false_path or a set_clock_groups or
  set_max_delay -datapath_only constraint but no double-registers logic
  synchronizer has been found on the side of the capture clock.

TIMING-10#1  Missing property on synchronizer
  One or more logic synchronizer has been detected between 2 clock domains but
  the synchronizer does not have the property ASYNC_REG defined on one or both
  registers.
```

`TIMING-9` is the serious one: somewhere a signal crosses this boundary with **no
synchroniser at all**. The comment on `wizard.xdc:39` claims "All datapaths from
the Minimig core to the HDMI output module use double flip flop transitions" —
the tool disagrees.

The offset buses documented in
[../adv7511/fix-03-offset-cdc.md](../adv7511/fix-03-offset-cdc.md) are one known
instance: `hoffset` / `voffset` are produced by `cfide` on `clk_114`
(`minimig_virtual_top.v:968`) and consumed combinationally in the `clk_148` read
address logic (`pal_to_hd_upsample.v:388-405`) with no synchroniser.

Name the rest with:

```tcl
report_cdc -details -file cdc.rpt
```

and fix each in RTL — a two-flop synchroniser carrying `ASYNC_REG = "TRUE"` for
single bits, a gray code or a request/acknowledge handshake for buses.

## Verify

* `report_cdc` shows no Critical or Warning severities on the `* → clk_148`
  crossings.
* `TIMING-9` and `TIMING-10` are gone from `report_methodology`.
* `report_exceptions -ignored` no longer lists the `set_max_delay` at
  `wizard.xdc:46` as overridden — because it is gone.

## Verified in Vivado (2026-09-04)

[03_exceptions_ignored.rpt](vivado-reports/03_exceptions_ignored.rpt):

```
29  CLKOUT0 -> clk_hdmi/CLKOUT0   max=1.8          Totally overridden path by FP 26
30  CLKOUT0 -> clk_hdmi/CLKOUT0   cycles=2(end)    Totally overridden path by FP 26
```

`report_cdc` on the false-pathed crossings ([06_cdc.rpt](vivado-reports/06_cdc.rpt)):
`clk_114 → clk_148` has 3 Critical (`s_pal_vsync_reg[1]` fanning out to three
synchronisers) and 2 Warning (`s_next_buf` without `ASYNC_REG`);
`dll_28 → clk_148` has 149 Critical, 148 of them the unsynchronised reset — see
[fix 11](fix-11-reset-into-clk148.md). The offset bus crossing is on
`dll_28 → clk_148` too, not `clk_114 → clk_148`
([50_posdata_paths.rpt](vivado-reports/50_posdata_paths.rpt)).

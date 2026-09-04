# Fix 1 — SDRAM input/output delay formulas are swapped

**Severity: High · File: `fpga/openaars/aars_v5.0/xc7a100t/sdram.xdc` · Effect:
the write-path setup check carries ~3.0 ns of fictitious budget on an 8.815 ns
period (34 % of a clock cycle)**

## Evidence — output side

`sdram.xdc:77-90`:

```tcl
set sdram_outputs [get_ports {dr_a[*] dr_ba[*] dr_d[*] dr_dqm[*] dr_cas_n dr_cs_n dr_ras_n dr_we_n }]
set sdram_inputs  [get_ports {dr_d[*]}]

# SDRAM setup/hold
set sdram_tsu 1.5
set sdram_thd -0.8
# Trace delay min/max
set sdram_tr_dly 0.17

set sdram_dly_max [expr {$sdram_tr_dly - $sdram_tsu}]
set sdram_dly_min [expr {$sdram_tr_dly + $sdram_tsu}]

set_output_delay -clock [get_clocks clk_gen_sdram] -min -add_delay $sdram_dly_min $sdram_outputs
set_output_delay -clock [get_clocks clk_gen_sdram] -max -add_delay $sdram_dly_max $sdram_outputs
```

Evaluate it:

| Variable | Expression | Value | Applied to |
|---|---|---|---|
| `sdram_dly_max` | `0.17 - 1.5` | **−1.33** | `-max` |
| `sdram_dly_min` | `0.17 + 1.5` | **+1.67** | `-min` |

`-min` is larger than `-max`, which is never valid. And `sdram_thd` is declared
and **never referenced anywhere in the file**.

## The correct formulas

For a system-synchronous output captured by an external device:

```
set_output_delay -max  =  tSU(device)  + trace_max
set_output_delay -min  = -tH(device)   + trace_min
```

With this board's numbers (`sdram_thd` is already stored as a negative):

```tcl
set_output_delay -clock [get_clocks clk_gen_sdram] -max -add_delay \
    [expr {$sdram_tsu + $sdram_tr_dly}] $sdram_outputs        ;#  1.5 + 0.17 =  1.67
set_output_delay -clock [get_clocks clk_gen_sdram] -min -add_delay \
    [expr {$sdram_thd + $sdram_tr_dly}] $sdram_outputs        ;# -0.8 + 0.17 = -0.63
```

## What the current values cost

| Check | Constrained as | Should be | Error |
|---|---|---|---|
| Setup | −1.33 | +1.67 | **3.00 ns too optimistic** |
| Hold | +1.67 | −0.63 | 2.30 ns too conservative |

The setup error is the dangerous one: the tool believes it has 3.0 ns more budget
than the SDRAM actually gives it, on an 8.815 ns cycle. The reported
`clk_114 → clk_gen_sdram  WNS = 3.672` therefore corresponds to a real margin of
roughly 0.67 ns.

The hold error is safe in direction but not free — it over-constrains the placer
and burns effort that belongs on the real setup check.

## Evidence — input side, same shape plus a wrong parameter

`sdram.xdc:92-97`:

```tcl
set sdram_toh_min 2.5
set sdram_toh_max 3.0
set sdram_dly_in_max [expr {$sdram_toh_min + $sdram_tr_dly}]   ;# 2.67
set sdram_dly_in_min [expr {$sdram_toh_max + $sdram_tr_dly}]   ;# 3.17
set_input_delay -clock [get_clocks clk_sd_114] -min -add_delay $sdram_dly_in_max [get_ports {dr_d[*]}]
set_input_delay -clock [get_clocks clk_sd_114] -max -add_delay $sdram_dly_in_min [get_ports {dr_d[*]}]
```

The variable named `_max` is applied to `-min` and vice versa. More importantly,
**both values derive from tOH**. The `-max` value must come from **tAC**, the
access time from clock — which never appears in the file at all.

For the AS4C16M16SA, tAC is roughly 5.4 ns and tOH roughly 2.5–3.0 ns. Take the
exact figures from the datasheet for the speed grade actually fitted.

```
set_input_delay -max  =  tAC_max + trace_max
set_input_delay -min  =  tOH_min + trace_min
```

```tcl
set sdram_tac_max 5.4          ;# CHECK against the fitted part's datasheet
set sdram_toh_min 2.5

set_input_delay -clock [get_clocks clk_gen_sdram] -max -add_delay \
    [expr {$sdram_tac_max + $sdram_tr_dly}] $sdram_inputs      ;# 5.57
set_input_delay -clock [get_clocks clk_gen_sdram] -min -add_delay \
    [expr {$sdram_toh_min + $sdram_tr_dly}] $sdram_inputs      ;# 2.67
```

Read-path setup is currently about 2.4 ns optimistic. It is partly masked by the
`-setup 2` multicycle at `:74`, which grants a whole extra 8.815 ns, so this one
is unlikely to be biting today — but the numbers should still be right.

## Two more on the same interface

**Wrong reference clock.** `sdram.xdc:96-97` uses `-clock [get_clocks clk_sd_114]`,
the internal MMCM output. The clock that actually accompanies the returning data
is the one at the pin, `clk_gen_sdram` (created at `:71`). Referencing the
internal clock omits the BUFG→IOB delay of the forwarded clock. Use
`clk_gen_sdram` for both input delays, as in the snippet above.

**Hold companion off by one.** `sdram.xdc:74-75`:

```tcl
set_multicycle_path -setup  -from [get_ports {dr_d[*]}] -to [get_clocks clk_114] 2
set_multicycle_path -hold -from [get_ports {dr_d[*]}] -to [get_clocks clk_114] 2
```

The hold companion to `-setup N` is always `N-1`. Change the second to `1`.

## Note on `dr_clk`

`rtl/soc/minimig_virtual_top.v:274` drives the SDRAM clock straight from a BUFG
net to the pad:

```verilog
assign SDRAM_CLK        = clk_sdram;
```

`sdram.xdc:71` models it correctly with
`create_generated_clock -name clk_gen_sdram -source ... -divide_by 1 [get_ports dr_clk]`,
and the Clock Summary confirms the phase came through as `{-2.975 1.433}`
(−121.5° of 8.815 ns). So it is constrained — but an ODDR would give a
deterministic, IOB-matched delay instead of a fabric-to-pad route. Worth doing if
the interface stays marginal after this fix.

## Verify

Re-run implementation and check `clk_114 → clk_gen_sdram` in the inter-clock
table. Expect WNS to drop by about 3 ns — if it goes negative, that is the real
state of the interface and the placer now has the right target. Confirm
`sdram_thd` is actually referenced, and that

```tcl
report_timing -to [get_ports {dr_a[*]}] -max_paths 10
```

shows a required time consistent with `tSU + trace`, not with `trace − tSU`.

## Verified in Vivado (2026-09-04)

In-memory re-time on the routed checkpoint, [verification-vivado.md](verification-vivado.md):

```
Output side (dr_we_n)         before      after
  Output Delay                 -1.330      1.670      +3.000 ns, exactly the predicted error
  Slack, control lines          6.358      3.358
  Slack, worst DQ (dr_d[9])     3.672      0.672      still met, now marginal

Input side (dr_d[9])          before      after
  Reference clock              clk_sd_114  clk_gen_sdram
  Input Delay                   3.170      5.570      (tAC 5.4 + 0.17)
  Slack                         8.124     -1.295      VIOLATED, 16 endpoints, TNS -12.5
```

The read-side swing is larger than predicted because the internal-clock
reference also omitted the 5.5 ns clock path `BUFG_SDR → net → dr_clk_OBUF`.
Whether −1.3 ns is a real shortfall or a wrong cycle count depends on which
`sysclk` edge `sdram_ctrl.v` consumes `sdata_reg` on — check the state machine
before choosing between `-setup 2` and `-setup 3`. The full edge-by-edge trace,
and why a single shared phase cannot fix it, is in
[sdram-read-path.md](sdram-read-path.md); the vendor-model simulation that
confirms it (read burst one word late at the slow corner) is in
[sdram-sim-results.md](sdram-sim-results.md).

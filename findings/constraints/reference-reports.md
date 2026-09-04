# Reference: what the reports actually say

Source: `project_1/project_1.runs/impl_1/minimig_openaars_top_timing_summary_routed.rpt`
and `minimig_openaars_top_methodology_drc_routed.rpt`, Vivado 2023.2,
`7a100t-fgg676` speed grade `-2`, design state Routed.

## Headline slack

```
    WNS(ns)   TNS(ns)  Failing   Total     WHS(ns)   THS(ns)  Failing   Total
      0.833     0.000        0   30718       0.041     0.000        0   30718

All user specified timing constraints are met.
```

Read that last line as *user specified*. See the ignored-path table below for
what was not specified.

## Clock summary

```
Clock                                         Waveform(ns)      Period(ns)   Frequency(MHz)
VIRTUAL_clk_148                               {0.000 3.367}     6.734        148.500
clk_50                                        {0.000 10.000}    20.000        50.000
  clk_114                                     {0.000 4.408}     8.815        113.438
    my_i2s_transmitter/max_sclk_OBUF          {0.000 308.540}   617.080        1.621
    openaars_virtual_top/mycfide/sck_reg_n_0  {0.000 308.540}   617.080        1.621
  clk_148                                     {0.000 3.367}     6.734        148.500
  clk_fb_main                                 {0.000 20.000}    40.000        25.000
  clk_fb_main_1                               {0.000 20.000}    40.000        25.000
  clk_sd_114                                  {-2.975 1.433}    8.815        113.438
    clk_gen_sdram                             {-2.975 1.433}    8.815        113.438
  dll_28                                      {0.000 17.631}    35.262       28.359
```

The three `create_generated_clock` renames in `clocks.xdc:15-17` give
`-master_clock` but no `-source`. Vivado inferred the correct periods here, but
see [fix-08-generated-clocks.md](fix-08-generated-clocks.md).

`clk_fb_main` / `clk_fb_main_1` are the two MMCM feedback nets promoted to
clocks. They appear in the Unconstrained Path Table. Harmless, but noisy.

## Inter-clock table — note the hold column

```
From Clock   To Clock                WNS(ns)   Endpoints   WHS(ns)    Endpoints
clk_sd_114   clk_114                   8.124          16   15.990           16
dll_28       clk_114                  13.978        2701   78.999         2701     <-- fix 2
dll_28       my_i2s_transmitter/...    4.559          49    6.116           49
clk_114      clk_gen_sdram             3.672          37    3.287           37     <-- fix 1
clk_114      dll_28                    9.898       11284    0.069        11284     <-- correct form
```

A hold slack of 78.999 ns is not margin, it is a switched-off check.
3 × 35.262 − 3 × 8.815 = 79.3 ns — see
[fix-02-dll28-hold-multicycle.md](fix-02-dll28-hold-multicycle.md). Compare
`clk_114 → dll_28` at 0.069 ns, which uses the correct `-start` pair.

## User Ignored Path Table

```
Path Group   From Clock                                To Clock
(none)       clk_148                                   VIRTUAL_clk_148          <-- fix 3
(none)       clk_114                                   clk_148                  <-- fix 5
(none)       dll_28                                    clk_148                  <-- fix 5
(none)       openaars_virtual_top/mycfide/sck_reg_n_0  clk_114                  <-- fix 8
(none)       clk_114                                   openaars_virtual_top/mycfide/sck_reg_n_0
(none)       dll_28                                    openaars_virtual_top/mycfide/sck_reg_n_0
```

`clk_148 → VIRTUAL_clk_148` being here is the whole of
[fix-03-adv7511-output-unconstrained.md](fix-03-adv7511-output-unconstrained.md):
every `set_output_delay` on the HDMI bus creates paths in exactly that group.

## check_timing

```
5. checking no_input_delay (15)
    2 input ports with no input delay specified.                        (HIGH)
   13 input ports with no input delay but user has a false path.        (MEDIUM)

6. checking no_output_delay (26)
    3 ports with no output delay specified.                             (HIGH)
   21 ports with no output delay but user has a false path.             (MEDIUM)
    2 ports with no output delay but with a timing clock on it.         (LOW)
```

See [fix-09-unconstrained-ports.md](fix-09-unconstrained-ports.md).

## Regenerating this evidence

```tcl
open_run impl_1
report_timing_summary -report_unconstrained -file ts.rpt
report_methodology -file meth.rpt
report_cdc -file cdc.rpt
check_timing -verbose -override_defaults {no_input_delay no_output_delay}
report_exceptions -ignored -file exc_ignored.rpt
```

`report_exceptions -ignored` is the fastest way to see which constraints are
being overridden by other constraints — that is how
[fix-05-cdc-false-path.md](fix-05-cdc-false-path.md) was found.

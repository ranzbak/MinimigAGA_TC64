# Reference: clocks, output modes, drift budget

Numbers verified from the RTL and the MMCM instantiations.

## Clocks

| Quantity | Value | Source |
|---|---|---|
| `clk_148` | 148.500 MHz exact — 50 × 37.125 / 2 / 6.25 | `rtl/soc/minimig_openaars_top.v:277-294` |
| HDMI pixel clock | 74.250 MHz exact (`clk_148` ÷ 2) | `rtl/openaars/adv7511/signal_generator.sv:118-131` |
| `clk_28` (Amiga) | 28.359375 MHz — 50 × 45.375 / 2 / 40 | `rtl/clock/amiga_clk_xilinx.v:31-38` |
| `clk_114` (Amiga) | 113.4375 MHz | same |

Both MMCMs are fed from the same 50 MHz board oscillator, so the two domains are
frequency-related — the drift below is deterministic, not random.

## Output modes

720p50 and 720p60 share pixel clock, sync width, back porch, DE window **and**
vertical total. Only the horizontal front porch differs.

| Mode | HACT | HFP | HSW | HBP | HTOTAL | VACT | VFP | VSW | VBP | VTOTAL | Pixel clk |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 720p50 | 1280 | 440 | 40 | 220 | **1980** | 720 | 5 | 5 | 20 | 750 | 74.25 MHz |
| 720p60 | 1280 | 110 | 40 | 220 | **1650** | 720 | 5 | 5 | 20 | 750 | 74.25 MHz |

This is why [fix-11-collapse-pipelines.md](fix-11-collapse-pipelines.md) is
worth doing: one generator with a runtime HTOTAL replaces two of everything.

## Frame periods and drift

| Source | Period | Sink period | Difference |
|---|---|---|---|
| Amiga PAL, 313 lines × 1816 `clk_28` | 20.043 ms | 720p50 = 20.000 ms | source 0.21 % slower |
| Amiga NTSC, 262 lines | ≈ 16.65 ms | 720p60 = 16.667 ms | same order |

A PAL frame lasts about **751.6 HD lines**, not 750. That 1.6 line/frame
difference is the drift budget that
[fix-06-hcount-reset-genlock.md](fix-06-hcount-reset-genlock.md) has to absorb.
Free-running at exactly 750 lines gives one repeated or dropped frame roughly
every 470 frames (≈ 9.4 s).

The source and sink **cannot** be frame-locked without either an adaptive
vertical total or a pullable pixel clock. Do not try to solve it by resetting the
horizontal counter — that is precisely the current bug.

## Constraint state (as built)

`fpga/openaars/aars_v5.0/xc7a100t/wizard.xdc:41`:

```tcl
set_false_path -from [get_clocks {dll_28 clk_114 clk_sd_114}] -to [get_clocks clk_148]
```

The `set_max_delay ... 1.800` on line 46 is overridden by that false path.
Confirmed in `project_1/project_1.runs/impl_1/minimig_openaars_top_timing_summary_routed.rpt`,
*User Ignored Path Table*, row `clk_114 → clk_148`. See
[fix-03-offset-cdc.md](fix-03-offset-cdc.md).

# Verification plan

Most of these faults are one line in 750, or one frame in several hundred. Do
not rely on looking at a TV.

## Simulation

`sim/` already has a testbench tree. Add one for `pal_to_ddr` driven by a
synthetic Amiga source with parameters for line count, line length, vsync width,
and interlace on/off. Then assert continuously:

| Assertion | Catches |
|---|---|
| HSYNC period constant to the cycle, across frame boundaries | [fix 6](fix-06-hcount-reset-genlock.md) |
| VSYNC period within `[VT_MIN, VT_MAX]`, changing by at most 1 line/frame | [fix 6](fix-06-hcount-reset-genlock.md) |
| `r_addra[13:11]` equals the write index latched at line start; `r_addra[10:0]` never wraps mid-line | [fix 5](fix-05-write-address-runaway.md) |
| No write occurs while `i_pal_vsync` is high | [fix 5](fix-05-write-address-runaway.md) |
| `r_addrb[13:11] == r_cur_read_buf` for every cycle of every line, for all `hoffset` in 0–255 | [fix 4](fix-04-read-address-underflow.md) |
| `r_pix_en` count per line equals `H_ACT_WIDTH` ± 1 | [fixes 7](fix-07-dds-increment.md), [8](fix-08-line-length-divider.md), [9](fix-09-geometry-hres.md) |
| `r_pix_clock_dev != 0` at all times, including blanking and power-up | [fix 8](fix-08-line-length-divider.md) |
| Sweeping source line length gives monotonic `dev` with no line-to-line alternation | [fix 8](fix-08-line-length-divider.md) |
| Read count per line exactly `H_ACT_WIDTH`, both modes | [fix 9](fix-09-geometry-hres.md) |
| `r_addrb` identical at the start of every line within one frame while `hoffset` changes once per frame | [fix 3](fix-03-offset-cdc.md) |
| `r_mode_60` changes at most once during a slow 18–21 ms period sweep, and only on a vsync boundary | [fix 10](fix-10-mode-detect-hysteresis.md) |
| `r_field` alternates every frame on an interlaced source | [fix 12](fix-12-interlace-multidriver.md) |

## Hardware

**Modes to cover.** PAL and NTSC, lores and hires, interlaced and
non-interlaced, at least two RTG modes, and the 31 kHz productivity mode. The
31 kHz modes are the ones where the divider quantisation of
[fix 8](fix-08-line-length-divider.md) is coarsest, so they are the best
regression test.

**Offsets.** Sweep each control end to end and back while watching for tearing.
Both must move the picture on the correct axis, monotonically, with no flashes
while the key is held.

**Slow drift.** Leave a static high-contrast pattern up for several minutes. The
source/sink beat is about 9.4 s free-running (see
[reference-timing.md](reference-timing.md)), so a short look will miss it.

**Sync robustness.** Push the vertical offset to both extremes and confirm the
display never reports a sync loss.

**Mode switching.** Alternate between a PAL and an NTSC source repeatedly; the
transition must land on a frame boundary with no torn frame.

## After synthesis

Check `project_1/project_1.runs/impl_1/minimig_openaars_top_timing_summary_routed.rpt`:

* The *User Ignored Path Table* must no longer list `clk_114 → clk_148` as an
  unbounded ignore ([fix 3](fix-03-offset-cdc.md)).

Check `project_1/project_1.runs/synth_1/runme.log`:

* The `Synth 8-6014` "unused sequential element" warnings for `r_v_count_reg`,
  `r_long_frame_reg`, `r_v_count_prev_reg`, `r_passthrough_reg`, `hz_in_count_reg`
  and `r_60hz_reg` should all be gone — either because the logic now works, or
  because it was deleted ([fixes 10](fix-10-mode-detect-hysteresis.md),
  [12](fix-12-interlace-multidriver.md), [13](fix-13-housekeeping.md)).
* The `Synth 8-689` port-width warning on `o_freq` should be gone
  ([fix 10](fix-10-mode-detect-hysteresis.md)).

Treat any new `Synth 8-6014` warning in this module as a bug report: it means
logic you wrote is not connected to anything.

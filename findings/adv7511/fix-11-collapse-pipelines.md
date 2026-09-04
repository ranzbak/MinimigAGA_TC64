# Fix 11 — Collapse the duplicated 50 Hz / 60 Hz pipelines

**Finding A6 / C · Effort: medium · Benefit: deletes the output mux, the
cross-wiring bugs, and half the line-buffer BRAM**

## The observation

720p50 and 720p60 differ in **one** number:

| Mode | HACT | HFP | HSW | HBP | HTOTAL | VTOTAL | Pixel clk |
|---|---|---|---|---|---|---|---|
| 720p50 | 1280 | **440** | 40 | 220 | 1980 | 750 | 74.25 MHz |
| 720p60 | 1280 | **110** | 40 | 220 | 1650 | 750 | 74.25 MHz |

Same pixel clock, same sync width, same back porch, same DE window, same
vertical total. There is no reason for two `pal_to_hd_upsample` instances, two
`signal_generator` instances, two sets of wires
(`pal_to_ddr.sv:163-188`), and a seven-signal combinational mux
(`pal_to_ddr.sv:314-328`).

## Fix

Turn the two horizontal `localparam`s into inputs, size the counters for the
larger mode, and instantiate once:

```systemverilog
signal_generator hd_gen (
    .clk       (clk_148),
    .reset     (reset),
    .i_htotal  (r_mode_60 ? 12'd1650 : 12'd1980),
    .i_hfp     (r_mode_60 ? 12'd110  : 12'd440),
    .i_frame_end (w_frame_end),
    ...
);

pal_to_hd_upsample my_upsample (
    .clk_in    (clk_114),
    .clk_out   (clk_148),
    ...
    .i_hd_hsync(w_hd_hsync),      // its OWN generator's hsync
    .i_hd_vsync(w_hd_vsync),
    .i_hd_clk  (w_adv_clk),       // its OWN generator's pixel clock
    .i_hd_hoffset(i_hoffset),
    .i_hd_voffset(i_voffset)
);
```

`r_mode_60` comes from
[fix-10-mode-detect-hysteresis.md](fix-10-mode-detect-hysteresis.md).

This removes finding A6 by construction: a mode change becomes a change of one
horizontal total at a frame boundary, not a swap between two live pipelines.

## Cross-wiring bugs this deletes

If the two instances are kept for now, these must be fixed by hand:

* **`pal_to_ddr.sv:275`** — the 60 Hz upsampler is given `.i_hd_hsync(o_hsync)`,
  the **muxed, `adv_ddr`-retimed** output hsync, instead of its own
  `w_60_hd_hsync`. In PAL mode it therefore receives 50 Hz timing.
* **`pal_to_ddr.sv:277`** — the 60 Hz upsampler is given
  `.i_hd_clk(w_50_adv_clk)`, the *50 Hz* generator's pixel clock.
* **`pal_to_ddr.sv:220`** — `.i_rtg_enable()` is left unconnected on the 50 Hz
  instance while it selects a mux at `pal_to_hd_upsample.v:503`. Tie it to
  `i_rtg_enable`.

## Resource saving

Each upsampler holds 16384 × 24 bits of line buffer — roughly 11 BRAM36 each.
Collapsing to one instance frees about 11 BRAM36 plus the duplicated counters
and sync logic.

## Order

Do this **after** fixes 1–10 are working on the 50 Hz path. Restructuring first
makes it harder to attribute any remaining artefact to a specific cause.

## Verify

Both 50 Hz and 60 Hz sources must produce correct geometry from the single
instance. Switch between a PAL and an NTSC source repeatedly and confirm the
transition takes effect at a frame boundary with no torn frame.

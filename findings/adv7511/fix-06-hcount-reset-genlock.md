# Fix 6 — `hz_count` is reset mid-line; replace with adaptive VTOTAL genlock

**Finding A2 · Effort: medium · Symptom: second major cause of line flicker;
per-frame sync jitter that some displays show as a shimmer or a rolling band**

## Evidence

`rtl/openaars/adv7511/signal_generator.sv:194-199`:

```verilog
        if(r_frame_end) begin
                r_frame_end <= 1'b0;
                vt_count <= 0;
                hz_count <= 0;      // fires at an arbitrary point in the HD line
                r_frame <= 1'b1;
        end
```

`r_frame_end` derives from `i_frame_end`, which is `o_frame_end` from the
upsampler — a pulse on the **source** vsync negedge
(`pal_to_hd_upsample.v:205-213`), asynchronous to the HD line grid. This block
is not gated by `r_vid_enable`, so it fires on any `clk_148` cycle.

The safety net is also commented out at `:186`:

```verilog
            //if(vt_count == PAL_VT_TOTAL || r_frame_end) begin
            if(r_frame_end) begin
```

## Why it flickers

1. **One runt HD line per frame**, of a length that varies frame to frame
   depending on where the source vsync landed.
2. `hz_count` jumps back below `PAL_HZ_FRONT_PORCH`, so the sync generator at
   `:213` emits an **extra HSYNC pulse** a few hundred pixels later. The
   upsampler counts that as a line advance (`hd_hsync_negedge`,
   `pal_to_hd_upsample.v:372`), shifting the line-duplication phase every frame.
   It also miscounts `pos_y_cnt` / `neg_y_cnt` in the vertical translate block,
   moving the picture up or down by a line.
3. A PAL frame is 20.043 ms and an HD line is 26.68 µs, so a frame spans about
   **751.6 HD lines**. The line count alternates 751 / 752 and the sink's PLL is
   re-pulled every frame.
4. With no terminal-count wrap, a single missed `frame_end` runs `vt_count` free
   until its 11-bit width wraps at 2048 lines — a full-screen flash.

See [reference-timing.md](reference-timing.md) for the drift arithmetic.

## Fix: free-running horizontal, adaptive vertical total

The horizontal counter defines the HDMI line rate and must never be disturbed.
Absorb the source/sink frequency difference in the vertical total, adjusted only
at the end of a frame.

```verilog
localparam integer VT_NOM = PAL_VT_TOTAL;      // 750
localparam integer VT_MIN = PAL_VT_TOTAL - 8;  // 742
localparam integer VT_MAX = PAL_VT_TOTAL + 8;  // 758

reg              r_src_frame  = 1'b0;   // a source vsync arrived this HD frame
reg [11:0]       r_vt_total   = VT_NOM;
reg [11:0]       r_lines_seen = 0;

always @(posedge clk) begin
    // Horizontal counter: NEVER reset from anything but its own terminal count
    if (r_vid_enable) begin
        hz_count <= hz_count + 1'b1;
        if (hz_count == (PAL_HZ_TOTAL - 1)) begin   // note -1, see below
            hz_count        <= 0;
            vt_count_enable <= 1'b1;
        end
    end

    // Latch that the source frame ended; act on it at end of HD frame
    if (i_frame_end) r_src_frame <= 1'b1;

    if (vt_count_enable) begin
        vt_count_enable <= 1'b0;
        vt_count        <= vt_count + 1'b1;
        r_lines_seen    <= r_lines_seen + 1'b1;

        if (vt_count == (r_vt_total - 1)) begin
            vt_count <= 0;
            r_frame  <= 1'b1;

            // Genlock: lengthen or shorten the NEXT frame by one line
            if (r_src_frame && (r_lines_seen < VT_NOM))
                r_vt_total <= (r_vt_total > VT_MIN) ? r_vt_total - 1'b1 : r_vt_total;
            else if (!r_src_frame)
                r_vt_total <= (r_vt_total < VT_MAX) ? r_vt_total + 1'b1 : r_vt_total;
            else
                r_vt_total <= VT_NOM;

            r_src_frame  <= 1'b0;
            r_lines_seen <= 0;
        end
    end
end
```

Properties:

* HSYNC period is constant to the cycle.
* VSYNC period changes by at most one line per frame and stays within ±8 lines
  of nominal — well inside what any HDMI sink tolerates.
* The 1.6 line/frame drift is tracked with no runt lines and no extra pulses.
* With PAL in, `r_vt_total` settles around 751–752.

Also remove the now-dead `i_frame_end` handling at `:176-178`, `:187-191` and
`:223-225` (`if (i_frame_end) r_vsync <= !SYNC_POL;` — forcing vsync from an
asynchronous pulse is the same class of bug).

## Cheaper alternative

Let the generator free-run at exactly 750 lines and accept one duplicated or
dropped source frame roughly every 470 frames (≈ 9.4 s). This is what an
ordinary non-genlocked scaler does and is still far better than the current
behaviour. It is a one-line change: delete the `hz_count <= 0` / `vt_count <= 0`
on `r_frame_end` and restore the terminal-count wrap.

## Not recommended: pull the pixel clock

Retuning the `clk_hdmi` MMCM to 74.25 × 20.000/20.043 ≈ 74.09 MHz would give an
exact 750-line lock, but needs a second MMCM configuration to switch between
50 Hz and 60 Hz sources, plus a reconfiguration glitch on every mode change.
Prefer the adaptive VTOTAL.

## Off-by-one, while you are in this block

`signal_generator.sv:169`:

```verilog
            if(hz_count == PAL_HZ_TOTAL) begin
```

Counting `0 … PAL_HZ_TOTAL` inclusive is 1981 states, not 1980 — the line rate
is 0.05 % low. The snippet above already uses `PAL_HZ_TOTAL - 1`.

## Verify

In simulation, assert that the interval between successive HSYNC rising edges is
constant across the whole run, including the frame boundary. Assert that
`r_vt_total` stays within `[VT_MIN, VT_MAX]` and changes by at most 1 per frame.
Run a source whose frame period is deliberately 1 % fast and 1 % slow and
confirm the loop tracks both without leaving the clamp.

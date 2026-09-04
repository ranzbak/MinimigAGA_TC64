# Fix 10 — The 50/60 Hz decision can flip mid-frame

**Finding A6 · Effort: small · Symptom: on sources near the threshold the entire
timing generator swaps every frame**

## Evidence

`rtl/openaars/adv7511/pal_to_ddr.sv:146-161`:

```systemverilog
  always @(posedge clk_148)
  begin
    r_50hz <= 1'b0;
    r_60hz <= 1'b0;
    if (fps_valid == 1'b1)
    begin
      if (cur_fps < 53) r_50hz <= 1'b1;
      else              r_60hz <= 1'b1;
    end
  end
```

`r_50hz` is recomputed on **every** `clk_148` cycle, and `:315-328` mux hsync,
vsync, pixel clock and pixel data combinationally off it.

The threshold `cur_fps < 53` sits **exactly on a table value** —
`frame_freq.v:179-180` returns 53 for a 19 ms period:

```verilog
      'd19:
      r_freq <= 53; // 1000/19 = 53
```

A source near 19.5 ms alternates between latching 19 and 20 ms, so `cur_fps`
alternates 53 / 50 and `r_50hz` toggles every frame. Because the mux is
combinational and ungated, the swap lands mid-frame.

`r_60hz` is dead — the mux only uses `r_50hz`. Synthesis confirms:

```
WARNING: [Synth 8-6014] Unused sequential element r_60hz_reg was removed. ...pal_to_ddr.sv:149
```

An unrecognised period returns `r_freq = 0` (`frame_freq.v:187-188`), which also
reads as 50 Hz — so an unsupported mode silently selects the PAL pipeline
instead of being reported.

## Fix

Move the threshold off a table value, add hysteresis, require stability, and gate
the switch to a frame boundary:

```systemverilog
  localparam FPS_TO_60 = 56;   // must clear 53 (19 ms) with margin
  localparam FPS_TO_50 = 52;
  localparam STABLE_N  = 3;

  reg       r_mode_60   = 1'b0;
  reg [1:0] r_agree_cnt = 0;
  wire      w_want_60   = r_mode_60 ? (cur_fps > FPS_TO_50) : (cur_fps >= FPS_TO_60);

  always @(posedge clk_148) begin
    if (w_vsync_negedge) begin              // decide once per frame only
      if (!fps_valid) begin
        r_agree_cnt <= 0;
      end else if (w_want_60 != r_mode_60) begin
        r_agree_cnt <= r_agree_cnt + 1'b1;
        if (r_agree_cnt == (STABLE_N - 1)) begin
          r_mode_60   <= w_want_60;
          r_agree_cnt <= 0;
        end
      end else begin
        r_agree_cnt <= 0;
      end
    end
  end
```

`w_vsync_negedge` is the existing source vsync edge detector
(`pal_to_ddr.sv:119`). Delete `r_50hz` / `r_60hz` and drive the mux from
`r_mode_60`.

## Also in `frame_freq.v`

**Typo.** `:185-186` returns 40 while the comment says 45:

```verilog
      'd22:
      r_freq <= 40; // 1000/22 = 45
```

Harmless today because both are below the threshold. Correct it to 45.

**Clock constant.** `CLK_FREQ_IN` defaults to 148 (`:23`) and is compared at
`:81`, but the clock is 148.5 MHz — a 0.34 % measurement bias, enough to matter
right at a millisecond boundary. Either pass a numerator/denominator pair or
count 297 half-microseconds.

**Port width.** `pal_to_ddr.sv:133` declares `cur_fps` one bit wider than
`o_freq`, producing:

```
WARNING: [Synth 8-689] width (8) of port connection 'o_freq' does not match port width (7)
```

Match them.

## Best fix

[fix-11-collapse-pipelines.md](fix-11-collapse-pipelines.md) removes the mux
entirely — `r_mode_60` then selects an HTOTAL value inside one generator rather
than switching between two parallel pipelines, so a mis-timed decision can no
longer glitch the output.

## Verify

Drive a source whose frame period sweeps slowly across 18–21 ms and assert that
`r_mode_60` changes at most once, and only on a vsync boundary. Confirm an
unsupported period leaves the previous mode latched rather than falling back to
50 Hz.

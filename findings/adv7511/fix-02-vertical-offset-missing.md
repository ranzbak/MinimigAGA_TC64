# Fix 2 — Vertical offset is not implemented

**Finding B1 · Effort: small · Symptom: the vertical position control has no
effect**

## Evidence

`rtl/openaars/adv7511/pal_to_hd_upsample.v:56` declares the port:

```verilog
  input [7:0]     i_hd_voffset
```

It is referenced nowhere in the module body. Vertical position is instead a
compile-time constant, `pal_to_hd_upsample.v:442`:

```verilog
localparam Y_TRANS=10;
```

`Y_TRANS` is the number of HD lines by which `o_hd_vsync` is delayed relative to
the generator's vsync (`pal_to_hd_upsample.v:448-493`), which is what shifts the
picture vertically.

## Fix

Make the delay a runtime value. Treat the offset as signed around a centre so
the control moves the picture both ways:

```verilog
// Vertical translate: 0x80 = neutral
localparam integer Y_TRANS_BASE = 10;
wire signed [9:0] w_y_trans_raw = Y_TRANS_BASE + $signed({1'b0, r_voff_active}) - 10'sd128;

// Clamp into the vertical blanking budget: 0 .. (VTOTAL - VACT - VSW) = 0..25
wire [4:0] w_y_trans = (w_y_trans_raw < 0)       ? 5'd0  :
                       (w_y_trans_raw > 10'sd25) ? 5'd25 :
                                                   w_y_trans_raw[4:0];
```

Then compare against `w_y_trans` instead of `Y_TRANS` at
`pal_to_hd_upsample.v:466` and `:487`, and widen `pos_y_cnt` / `neg_y_cnt` to
hold the maximum value:

```verilog
reg [4:0] pos_y_cnt = 0;
reg [4:0] neg_y_cnt = 0;
...
if (pos_y_cnt == w_y_trans) begin ... end
...
if (neg_y_cnt == w_y_trans) begin ... end
```

`r_voff_active` is the synchronised, frame-latched offset from
[fix-03-offset-cdc.md](fix-03-offset-cdc.md).

## Why the clamp matters

720p has 5 lines of front porch, 5 of sync and 20 of back porch. Delaying vsync
by more than `VTOTAL - VACT - VSW` = 25 lines pushes it into the active region:
the picture does not shift further, the sync breaks. Clamp, do not wrap.

## If a wider range is needed

Do not extend the vsync delay past 25 lines. Instead bias the **read buffer
index** at frame start — `pal_to_hd_upsample.v:419-437` already resets
`r_cur_read_buf` on the source vsync:

```verilog
  if (r_pal_vneg) begin
    r_cur_read_buf <= w_line_offset[2:0];   // instead of a hardcoded 0
  end
```

That shifts the picture in *source* lines, which is unlimited in range and does
not touch the output sync at all. The two mechanisms compose: coarse shift by
buffer index, fine shift by vsync delay.

## Verify

Sweep the vertical control end to end. The picture must move vertically,
monotonically, one line per step, with no frame showing a torn or doubled edge,
and the display must never report a sync loss at either extreme.

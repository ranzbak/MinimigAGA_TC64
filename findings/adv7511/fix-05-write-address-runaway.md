# Fix 5 — Write address runs free through vertical blanking

**Finding A1 · Effort: small · Symptom: this is the primary cause of the line
flicker, and it is mode-dependent**

## Evidence

`rtl/openaars/adv7511/pal_to_hd_upsample.v:273-279`:

```verilog
  // Write to dual port ram
  if (r_pix_en && ~i_pal_hsync)
  begin
    r_addra <= r_addra+1;
    r_wea <= 1'b1;
    r_dina <= {i_pal_b, i_pal_g, i_pal_r};
  end
```

Two things are missing: the write is not gated on vsync, and `r_addra` is not
bounded to its 2048-word window.

The buffer base is reloaded only at `:282`, inside a condition that excludes
vertical blanking:

```verilog
  // End of input line
  if (r_pal_hneg_in && ~i_pal_vsync)
  begin
    ...
    case (r_cur_write_buf) ... endcase   // reloads r_addra
  end
```

## Why it flickers

While `i_pal_vsync` is high:

* hsync keeps running, so `r_line_active` keeps toggling,
* `r_pix_en` keeps firing at roughly 1300 samples per line,
* `r_addra` keeps incrementing with **no base reload and no bound**.

Over a 3–5 line vsync that is 4000–6700 words, marching straight through
buffers 5, 6, 7, 0, 1 … which the read side is displaying at the top of the
frame.

Vsync length differs per video mode and, in interlaced modes, between the two
fields. The corruption therefore lands on different output lines every frame,
which is exactly what "lines flicker on some resolutions" looks like.

At `:321-324` the vsync negedge sets `r_cur_write_buf <= 4` but **not**
`r_addra`, so the runaway value persists until the first hsync negedge after
blanking ends.

## Fix

Three changes in the `always @(posedge clk_in)` block at `:246`.

**1. Do not sample during vertical blanking.**

```verilog
  if (r_pix_en && ~i_pal_hsync && ~i_pal_vsync)
  begin
    ...
  end
```

**2. Saturate the address inside its buffer.** Saturating is better than
wrapping — an over-long line then pads its own tail instead of overwriting its
own start:

```verilog
    if (r_addra[10:0] != 11'h7FF)
      r_addra <= r_addra + 1'b1;
    r_wea  <= 1'b1;
    r_dina <= {i_pal_b, i_pal_g, i_pal_r};
```

**3. Reset the address explicitly at the vsync negedge**, alongside the write
buffer index at `:321-324`:

```verilog
  if (r_pal_vneg_in)
  begin
    r_cur_write_buf <= 4;
    r_addra         <= {3'd4, 11'd0};
  end
```

While here, replace the eight-way `case` at `:298-317` with the same
index-concatenation used in
[fix-04-read-address-underflow.md](fix-04-read-address-underflow.md):

```verilog
    r_addra <= {r_cur_write_buf, 11'd0};
```

Note this reads the pre-increment value of `r_cur_write_buf`, matching the
existing behaviour — the read side does the same, so the two stay in step.

## Interaction with fix 8

A `dev` value of 0 from the broken divider makes `r_pix_en` fire on **every**
clock — about 7000 writes in one line. The address bound above contains the
damage, but the root cause is
[fix-08-line-length-divider.md](fix-08-line-length-divider.md). Do both.

## Verify

In simulation, assert continuously that
`r_addra[13:11] == r_cur_write_buf_at_line_start` and that `r_addra[10:0]` never
wraps from `0x7FF` to `0x000` mid-line. Drive a source with a 3-line and a
5-line vsync and confirm the top-of-frame lines are identical in both cases.

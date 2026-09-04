# Fix 4 — Read address underflows its line buffer

**Finding B2 · Effort: small · Symptom: past roughly offset 48 the horizontal
control produces tearing and garbage instead of a shift**

## Evidence

`rtl/openaars/adv7511/pal_to_hd_upsample.v:388-405`:

```verilog
    case (r_cur_read_buf)
      0: r_addrb <= 14'h0000 - (PAL_OFFSET_HZ + i_hd_hoffset);
      1: r_addrb <= 14'h0800 - (PAL_OFFSET_HZ + i_hd_hoffset);
      ...
      7: r_addrb <= 14'h3800 - (PAL_OFFSET_HZ + i_hd_hoffset);
    endcase
```

`PAL_OFFSET_HZ` is `'hd0` = 208 on the 50 Hz instance
(`pal_to_ddr.sv:195`, confirmed in the synthesis log: `Parameter PAL_OFFSET_HZ
bound to: 208`) and `'h80` = 128 on the 60 Hz instance. `i_hd_hoffset` is 8 bits,
so the subtrahend reaches 463.

The buffers are 0x800 = 2048 words apart. Once
`PAL_OFFSET_HZ + i_hd_hoffset` exceeds the amount of the buffer the read has not
yet consumed, the address crosses the base and reads out of the **previous**
buffer — which is one of the buffers currently being written. For
`r_cur_read_buf == 0` the 14-bit address wraps to `0x3FFF`, i.e. into buffer 7.

The increment at `:357` has the same problem in the other direction:

```verilog
      r_addrb <= r_addrb + 1;
```

Nothing stops a long read window from walking out of the top of the buffer.

## Fix

Keep the buffer index and the in-buffer offset separate. The offset wraps within
the 2048-word buffer; the index never changes mid-line.

```verilog
localparam BUF_BITS = 11;                    // 0x800 words per line buffer

wire [10:0] w_start_lo = 11'd0 - (PAL_OFFSET_HZ + r_hoff_active);

always @(posedge clk_out) begin
  if (hd_hsync_negedge) begin
    // replaces the whole 8-way case statement
    r_addrb <= {r_cur_read_buf, w_start_lo};
    r_h_pos <= 0;
    ...
  end

  // in-buffer increment, cannot leave the buffer
  if (<read window active>) begin
    r_addrb <= {r_addrb[13:11], r_addrb[10:0] + 11'd1};
    ...
  end
end
```

`r_hoff_active` is the synchronised, frame-latched offset from
[fix-03-offset-cdc.md](fix-03-offset-cdc.md).

The eight-way `case` disappears. Do the same on the write side —
`pal_to_hd_upsample.v:298-317` has the identical structure and the identical
problem (see [fix-05-write-address-runaway.md](fix-05-write-address-runaway.md)).

## Note on what the offset then does

Wrapping inside the buffer means an extreme offset shows the line's own tail at
the left edge rather than another line's content. That is a benign artefact at
the ends of the control's travel. If even that is unwanted, clamp instead of
wrap, and let the offset saturate.

Once [fix-09-geometry-hres.md](fix-09-geometry-hres.md) is applied,
`PAL_OFFSET_HZ` becomes a small centring trim rather than a load-bearing fudge
factor, and the usable offset range widens considerably.

## Verify

In simulation, sweep `i_hd_hoffset` across 0–255 and assert
`r_addrb[13:11] == r_cur_read_buf` on every cycle of every line. On hardware,
sweep the horizontal control end to end and back: monotonic movement, no
tearing.

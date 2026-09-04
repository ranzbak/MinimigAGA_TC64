# Fix 8 — The line-length divider is too coarse and can underflow

**Finding A4 · Effort: medium · Symptom: picture width jumps between two values
on some input modes; `dev = 0` causes a catastrophic buffer overrun**

## Evidence

`rtl/openaars/adv7511/pal_to_hd_upsample.v:177-184`:

```verilog
  if (r_pal_hpos_in)
  begin
    r_line_active   <= 1'b0;
    r_line_count    <= 0;
    r_v_count       <= r_v_count + 1;
    v_div_var        = (r_line_count[13:6] / (PAL_HD_H_RES>>8)) - 1;
    r_pix_clock_dev <= v_div_var[5:0];
  end
```

`r_line_count` is the number of `clk_114` cycles from the end of one hsync to the
start of the next.

## Three separate problems

**1. Resolution.** `PAL_HD_H_RES>>8` is 6 on the 50 Hz instance (1685) and 7 on
the 60 Hz instance (1980). The quotient lands around 18 for a 15 kHz line and
around 8 for a 31 kHz line, so **one LSB of `dev` is a 5–12 % step in picture
width**. There is nothing in between. A 31 kHz mode gets the coarser end.

**2. Quantisation of the measurement.** `r_line_count[13:6]` throws away the
bottom 6 bits, quantising to 64-clock bins. A source line whose length sits on a
bin boundary makes the numerator alternate, and one in six of those alternations
changes the quotient — so `dev` flips between two values line to line. This is
the direct mechanism behind "flickers on *some* resolutions".

**3. Underflow.** If the quotient is 0 — a short line, a mode change, blanking,
no signal — the `- 1` underflows to `12'hFFF`. Truncated by `v_div_var[5:0]` that
gives 63, and in the wrap case **`dev = 0`**, which makes
`r_pix_clock_count >= r_pix_clock_dev` true on every clock. `r_pix_en` then fires
continuously: about 7000 writes in one line, straight through several buffers.
See [fix-05-write-address-runaway.md](fix-05-write-address-runaway.md).

## Fix

Use the full measurement, a fixed-point result, and a sanity gate. `N_SAMPLES`
is the exact number of reads performed per output line — see
[fix-09-geometry-hres.md](fix-09-geometry-hres.md), where it becomes
`H_ACT_WIDTH`.

```verilog
// dev in 6.6 fixed point.  Want: 4 * r_line_count / N_SAMPLES
// Precompute the reciprocal once at elaboration, then multiply.
localparam [17:0] RECIP = (18'd4 * 18'd256 * 18'd64) / N_SAMPLES;

reg [11:0] r_pix_clock_dev = 12'd0;    // 6.6 fixed point
reg [29:0] r_dev_mult;

always @(posedge clk_in) begin
  if (r_pal_hpos_in) begin
    // Sanity gate: ignore absurd lines, hold the last good value
    if (r_line_count > 14'd1024 && r_line_count < 14'd12000)
      r_pix_clock_dev <= (r_line_count * RECIP) >> 8;
  end
end
```

A DSP48 does the multiply in one cycle at 113 MHz. The per-line divide the code
does today is not needed at all.

Widen `r_pix_clock_count` to the same 6.6 format and change the increment in
[fix-07-dds-increment.md](fix-07-dds-increment.md) from `4` to `4 << 6`.

## Two properties this buys

* **The sanity gate** means a short or absurd line — mode change, blanking, no
  signal — leaves the previous good value in place instead of producing
  `dev = 0`. Pick the bounds from the range of source line lengths actually
  supported: 1024 `clk_114` cycles is about 9 µs, 12000 is about 106 µs.
* **Fractional resolution** means a line length near a bin boundary changes
  `dev` by one LSB of 1/64, not by 5–12 %.

## Optional: damp the measurement

If per-line noise still modulates the width, only accept a new value when it
differs from the running one by more than one LSB, or average over 8 lines:

```verilog
    if (|(r_new_dev ^ r_pix_clock_dev) & ~12'd1)
      r_pix_clock_dev <= r_new_dev;
```

## Note on `PAL_HD_H_RES`

That parameter is being used here to mean "samples per line" and at `:355` to
mean "HD line total in pixel clocks". Those are two different quantities and one
of the two uses is wrong on each instance —
[fix-09-geometry-hres.md](fix-09-geometry-hres.md) separates them.

## Verify

In simulation, sweep the source line length continuously across the supported
range and assert that `r_pix_clock_dev` is monotonic and never alternates
between adjacent lines. Assert `r_pix_clock_dev != 0` at all times, including
during blanking and at power-up.

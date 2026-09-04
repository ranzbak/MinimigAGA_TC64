# Fix 7 — The pixel-rate DDS drops its increment

**Finding A3 · Effort: 1 line · Symptom: about 18 % fewer samples written per
line than intended; picture width wrong, and the `PAL_OFFSET_HZ` fudge exists to
paper over it**

## Evidence

`rtl/openaars/adv7511/pal_to_hd_upsample.v:224-234`:

```verilog
  else if (r_line_active)
  begin
    r_pix_clock_count <= r_pix_clock_count + 3'b100;

    r_pix_en <= 1'b0;
    if (r_pix_clock_count >= r_pix_clock_dev)
    begin
      r_pix_clock_count <= r_pix_clock_count - r_pix_clock_dev;
      r_pix_en <= 1'b1;
    end
  end
```

Both assignments target `r_pix_clock_count` in the same always block. The second
wins, so on every emit cycle the `+ 4` is discarded.

## Arithmetic

A correct fractional accumulator adds `K` each clock and subtracts `M` on
overflow, giving an output rate of `K/M`. Here the subtract branch *replaces*
the add, so the accumulator's net motion per emitted sample is `4n - dev - 4`
rather than `4n - dev`. Steady state: `4n = dev + 4`, i.e.

```
actual rate = 4 / (dev + 4)     instead of     4 / dev
```

With the typical `dev` of 18 for a 15 kHz line that is 0.1818 instead of 0.2222
— **18 % fewer samples per line**.

## Fix

```verilog
    r_pix_en <= 1'b0;
    if (r_pix_clock_count >= r_pix_clock_dev) begin
      r_pix_clock_count <= r_pix_clock_count + 6'd4 - r_pix_clock_dev;
      r_pix_en          <= 1'b1;
    end else begin
      r_pix_clock_count <= r_pix_clock_count + 6'd4;
    end
```

Widen `r_pix_clock_count` to match whatever fixed-point format
[fix-08-line-length-divider.md](fix-08-line-length-divider.md) settles on.

## Expect the picture to change width

This fix alone makes the image about 18 % wider. Do not re-trim `PAL_OFFSET_HZ`
to compensate — apply fixes 8 and 9 first, which set the sample count from the
actual read window, then trim once at the end.

## Verify

In simulation, count `r_pix_en` pulses per source line and compare against
`4 * r_line_count / dev`. Before the fix the count is low by `dev/(dev+4)`;
after, it matches to within one sample.

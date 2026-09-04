# Fix 12 — The interlace logic is multi-driven and was optimised away

**Finding A5 · Effort: medium · Symptom: interlaced modes shimmer — both fields
land on the same output lines**

## Evidence

`r_v_count` is assigned from **two different clock domains**:

`rtl/openaars/adv7511/pal_to_hd_upsample.v:181`, inside
`always @(posedge clk_in)`:

```verilog
    r_v_count       <= r_v_count + 1;
```

`rtl/openaars/adv7511/pal_to_hd_upsample.v:421-422`, inside
`always @(posedge clk_out)`:

```verilog
    r_v_count_prev <= r_v_count;
    r_v_count <= 0;
```

And both branches of the decision it feeds are identical
(`pal_to_hd_upsample.v:427-436`):

```verilog
    if(r_long_frame)
    begin
      r_cur_read_buf  <= 0;
      // r_cur_write_buf <= 4;
    end
    else
    begin
      r_cur_read_buf  <= 0;
      // r_cur_write_buf <= 6;
    end
```

So it would do nothing even if the counter worked. Synthesis removed all of it:

```
WARNING: [Synth 8-6014] Unused sequential element r_v_count_reg was removed.      ...:181
WARNING: [Synth 8-6014] Unused sequential element r_long_frame_reg was removed.   ...:414
WARNING: [Synth 8-6014] Unused sequential element r_v_count_prev_reg was removed. ...:412
```

Interlaced modes therefore get no field offset: the odd and even fields are
written to the same buffer positions and displayed on the same output lines.

## Option A: delete it

If interlaced modes are out of scope, remove `r_v_count`, `r_v_count_prev`,
`r_long_frame` and the `r_pal_vpos` edge detector at `:110`/`:124-127` (also
already removed by synthesis). That is honest and removes a trap for the next
reader.

## Option B: implement it properly

1. **Count source lines entirely in `clk_in`.** One driver, one always block.
   The counter belongs with the write-side logic, next to `r_line_active`.

   ```verilog
   always @(posedge clk_in) begin
     if (r_pal_hpos_in) r_v_count <= r_v_count + 1'b1;
     if (r_pal_vneg_in) begin
       r_v_count_prev <= r_v_count;
       r_field        <= (r_v_count > r_v_count_prev);   // long field = odd
       r_v_count      <= 0;
     end
   end
   ```

2. **Cross only the result.** A single bit through a two-flop synchroniser, and
   sample it in `clk_out` only at the frame boundary:

   ```verilog
   (* ASYNC_REG = "TRUE" *) reg [1:0] s_field;
   reg r_field_out = 1'b0;
   always @(posedge clk_out) begin
     s_field <= {s_field[0], r_field};
     if (r_pal_vneg) r_field_out <= s_field[1];
   end
   ```

3. **Use it.** Bias the read buffer index by one at frame start so the odd field
   is displayed one output line lower, at `pal_to_hd_upsample.v:419-437`:

   ```verilog
     if (r_pal_vneg) begin
       r_cur_read_buf <= r_field_out ? 3'd1 : 3'd0;
     end
   ```

   With the [fix-02](fix-02-vertical-offset-missing.md) buffer-index offset in
   place, add the two together and let the sum wrap modulo 8.

## Check for the same pattern elsewhere

Multi-driving a `reg` from two always blocks is silently accepted here and
resolved by deleting the register. Worth a sweep of the whole file — any `reg`
assigned in more than one `always` block is suspect, and the `Synth 8-6014`
warnings in `project_1/project_1.runs/synth_1/runme.log` are the fastest way to
spot the survivors.

## Verify

Run an interlaced source in simulation and assert that `r_field` alternates every
frame and that the read buffer index at frame start differs by one between
consecutive frames. On hardware, a single-pixel horizontal line in an interlaced
mode must sit still rather than vibrate.

# Fix 9 — `PAL_HD_H_RES` is wrong on both instances; restructure the read window

**Effort: medium · Symptom: geometry only works because two errors partly cancel;
`PAL_OFFSET_HZ` is load-bearing and the aspect ratio is not expressible**

## Evidence

`rtl/openaars/adv7511/pal_to_hd_upsample.v:352-361`:

```verilog
  if (r_hd_clk_ == 1'b1 && i_hd_clk == 1'b0 && ~i_hd_hsync)
  begin
    r_h_pos <= r_h_pos + 1;
    if (r_h_pos > PAL_HD_H_FP && r_h_pos < (PAL_HD_H_RES-PAL_HD_H_FP))
```

`r_h_pos` counts pixel clocks from the HSYNC falling edge, so here
`PAL_HD_H_RES` means "HD line total in pixel clocks". As instantiated:

| Instance | `PAL_HD_H_RES` | Generator HTOTAL | Correct value |
|---|---|---|---|
| `my50hzupsample` (`pal_to_ddr.sv:194`) | 1685 | 1980 (720p50) | 1980 |
| `my60hzupsample` (`pal_to_ddr.sv:255`) | 1980 | 1650 (720p60) | 1650 |

Both are wrong. The 50 Hz one is wrong in the direction that partly cancels its
`PAL_OFFSET_HZ` of 208, which is why the picture looks roughly right today.

The same parameter also feeds the divider at `:182`, where it means "samples per
line" — a different quantity entirely.

## The two counters are already aligned

`adv_ddr` opens DE at `px_count == PX_TO_DE` and closes it 1280 pixels later
(`adv_ddr.v:139-142`), and `px_count` resets on the same HSYNC edge as `r_h_pos`
(`adv_ddr.v:154-155`). So the read window can be stated directly in DE
coordinates instead of being trimmed by hand.

## Fix

Give the aspect ratio its own parameter and make the read window exactly the
visible window:

```verilog
parameter H_DE_START  = 280;    // must match adv_ddr PX_TO_DE
parameter H_ACT_WIDTH = 960;    // 4:3 at 720 lines => 720*4/3 = 960; 1280 for 16:9

localparam H_PILLAR   = (1280 - H_ACT_WIDTH) / 2;
localparam H_RD_START = H_DE_START + H_PILLAR;
localparam H_RD_END   = H_RD_START + H_ACT_WIDTH;

if (r_h_pos >= H_RD_START && r_h_pos < H_RD_END) begin
  r_addrb <= {r_addrb[13:11], r_addrb[10:0] + 11'd1};
  r_hd_r  <= w_doutb[ 0 +: 8];
  r_hd_g  <= w_doutb[ 8 +: 8];
  r_hd_b  <= w_doutb[16 +: 8];
end else begin
  {r_hd_r, r_hd_g, r_hd_b} <= 24'd0;   // pillarbox
end
```

Then `N_SAMPLES` for [fix-08-line-length-divider.md](fix-08-line-length-divider.md)
is simply `H_ACT_WIDTH` — write exactly as many samples per source line as are
read per output line.

`PAL_HD_H_RES` and `PAL_HD_H_FP` can be deleted. `PAL_OFFSET_HZ` becomes a small
centring trim rather than a structural fudge factor.

## Check `PX_TO_DE` while you are here

`adv_ddr` is instantiated with `PX_TO_DE(280)` (`pal_to_ddr.sv:332`) but the back
porch is 220 — a 60-pixel discrepancy currently absorbed by the offsets. Pin it
down on a real display once the read window is deterministic, and keep
`H_DE_START` equal to whatever `PX_TO_DE` ends up being.

## Aspect ratio

`H_ACT_WIDTH = 960` gives a true 4:3 picture pillarboxed inside 720p, matching
the intent of commit 4c6c0ca ("Make video aspect ratio closer to 4x3"). Setting
it to 1280 gives full-width 16:9 stretch. Exposing it as a module parameter
makes it a build-time choice rather than a magic constant, and it could
reasonably become a runtime input alongside the offsets.

## Verify

Count reads per line in simulation: exactly `H_ACT_WIDTH`, every line, both
modes. Display a known test pattern with vertical bars at the source's extreme
left and right columns and confirm both are visible and equidistant from the
pillarbox edges with the offset at its neutral value.

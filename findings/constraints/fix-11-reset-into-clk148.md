# Fix 11 — Reset enters the `clk_148` domain unsynchronised

**Severity: High · Found by: `report_cdc` during verification · Effect: 148
Critical CDC rows from one source; every reset-sensitive register in the HDMI
pipeline can leave reset on a different cycle**

## Evidence

[vivado-reports/06_cdc.rpt](vivado-reports/06_cdc.rpt), section
`dll_28 → clk_148`:

```
 13  CDC-1  Critical  1-bit unknown CDC circuitry  0  False Path  myReset/nresetLoc_reg/C  my_pal_to_ddr/hd_50hz_gen/hz_region_act_reg/R
 14  CDC-1  Critical  1-bit unknown CDC circuitry  0  False Path  myReset/nresetLoc_reg/C  my_pal_to_ddr/hd_50hz_gen/r_b_reg[0]/CE
 15  CDC-1  Critical  1-bit unknown CDC circuitry  0  False Path  myReset/nresetLoc_reg/C  my_pal_to_ddr/hd_50hz_gen/r_b_reg[0]/R
 ...
```

148 rows, all from `myReset/nresetLoc_reg`. Plus 130 `CDC-15` warnings
("clock-enable controlled CDC structure") from the same source onto the
`hz_count` / `vt_count` counters.

The source is `gen_reset` in `rtl/soc/minimig_openaars_top.v:311-320`, clocked
on `clk_28`:

```verilog
gen_reset #(
  .resetCycles(524284)
) myReset (
  .clk(clk_28), // Needs to be crystal clock
  ...
  .nreset(reset_n)
);
```

`reset_n` then goes straight into `pal_to_ddr` at `:393` as `.reset(~reset_n)`,
where `signal_generator`, `adv_ddr`, `frame_freq` and both upsamplers use it as
a synchronous reset and as a clock enable on `clk_148` — with the whole
`dll_28 → clk_148` crossing false-pathed (`wizard.xdc:41`).

## Why it matters

A synchronous reset released asynchronously to the destination clock arrives at
different registers on different `clk_148` edges — the net has 148+ endpoints
spread across the die, and no timing check bounds the skew. The video timing
generators and the line-buffer pointers can therefore start one cycle apart from
each other. With `hz_count` free-running from a skewed release, the first frame
after reset has arbitrary line phase, and nothing in the current design re-aligns
it except the source-vsync reset that [adv7511/fix-06](../adv7511/fix-06-hcount-reset-genlock.md)
removes.

It also means every one of these 148 endpoints is a CDC that `report_cdc` cannot
classify — which is why the report is too noisy to be useful today.

## Fix

Synchronise the reset into `clk_148` once, at the top, and feed the HDMI block
from that:

```verilog
// minimig_openaars_top.v — one synchroniser for the whole clk_148 island
wire reset_148_n;
xpm_cdc_sync_rst #(
  .DEST_SYNC_FF (3),
  .INIT         (0)      // asserted (0 = reset active) until the first clk_148 edges
) sync_rst_148 (
  .dest_clk (clk_148),
  .src_rst  (reset_n),
  .dest_rst (reset_148_n)
);

pal_to_ddr my_pal_to_ddr (
  .clk_148 (clk_148),
  .clk_114 (clk_114),
  .reset   (~reset_148_n),
  ...
```

If XPM is not wanted, the same thing by hand:

```verilog
(* ASYNC_REG = "TRUE" *) reg [2:0] rst148_sync = 3'b000;
always @(posedge clk_148) rst148_sync <= {rst148_sync[1:0], reset_n};
wire reset_148_n = rst148_sync[2];
```

Then, in `wizard.xdc`, the crossing stays in the asynchronous group from
[fix 5](fix-05-cdc-false-path.md) and needs no further exception — the
synchroniser is the constraint.

The same pattern applies to the `clk_114` side: `pal_to_ddr` also takes
`reset` into `clk_114` logic (`pal_to_hd_upsample` DDS block). Either derive a
`reset_114_n` the same way or, since `clk_28` and `clk_114` are phase-aligned
MMCM siblings, leave it timed by the existing (corrected) multicycle.

## Verify

```tcl
report_cdc -from [get_cells myReset/nresetLoc_reg] -details
```

should show every destination as `CDC-3 Info  1-bit synchronized with
ASYNC_REG property` and nothing Critical. The `dll_28 → clk_148` section of the
full report should shrink from 148 Critical rows to about 1 (the `beamcon0`
path in [adv7511/fix-13](../adv7511/fix-13-housekeeping.md)).

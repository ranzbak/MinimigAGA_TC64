# Fix 1 — Crossed offset ports on the 50 Hz instance

**Finding B1 · Effort: 1 line · Symptom: the vertical offset control moves the
picture horizontally, the horizontal control does nothing**

## Evidence

`rtl/openaars/adv7511/pal_to_ddr.sv:217-219`, instance `my50hzupsample`:

```systemverilog
    // horizontal and vertical offsets
    .i_hd_hoffset(i_voffset),   // BUG: vertical value drives the horizontal shift
    .i_hd_voffset(i_voffset),
```

`i_hoffset` is never connected on this instance. Since PAL input selects this
pipeline, this is what the user sees in normal use.

`rtl/openaars/adv7511/pal_to_ddr.sv:278-280`, instance `my60hzupsample`, is
wrong in a different way — it truncates an 8-bit value to one bit:

```systemverilog
    .i_hd_hoffset(i_hoffset),
    .i_hd_voffset(i_voffset[0]),   // BUG: 1 bit of an 8-bit value
```

## Verified in the routed netlist

`report_timing -from pos_data_q_reg` on the April-2024 checkpoint shows
`pos_data_q_reg[11]` — bit 3 of **`voffset`** — driving
`my50hzupsample/r_addrb_reg[13:11]`, the *horizontal* read address of the 50 Hz
instance ([../constraints/vivado-reports/50_posdata_paths.rpt](../constraints/vivado-reports/50_posdata_paths.rpt)).

## Fix

50 Hz instance:

```systemverilog
    .i_hd_hoffset(i_hoffset),
    .i_hd_voffset(i_voffset),
```

60 Hz instance:

```systemverilog
    .i_hd_hoffset(i_hoffset),
    .i_hd_voffset(i_voffset),
```

## Note

After this fix the vertical offset is correctly *routed* but still has no
effect, because the port is unused inside the upsampler. That is
[fix-02-vertical-offset-missing.md](fix-02-vertical-offset-missing.md).

## Verify

Sweep the horizontal control end to end: the picture must move horizontally and
the vertical control must not. Expect the horizontal sweep to still break up
past roughly offset 48 until
[fix-04-read-address-underflow.md](fix-04-read-address-underflow.md) is applied.

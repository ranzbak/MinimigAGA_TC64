# Fix 3 — Offset buses cross clock domains unsynchronised

**Finding B3 · Effort: small · Symptom: adjusting either offset produces flashes
of wrong lines; the picture "gets unstable quickly" while the key is held**

## Evidence

The offsets are produced on **`clk_28`** (`dll_28`):

* `rtl/soc/minimig_openaars_top.v:507-508` — `assign hoffset = vpos_data[7:0];`
  / `assign voffset = vpos_data[15:8];`
* `rtl/soc/minimig_virtual_top.v:968` — `.pos_data_q(VPOS_DATA)` on `cfide`.
  `cfide` takes both `sysclk` (`CLK_114`) and `clk_28`; the routed netlist shows
  `vpos_interface.pos_data_q_reg[*]` clocked by `dll_28`
  ([../constraints/vivado-reports/50_posdata_paths.rpt](../constraints/vivado-reports/50_posdata_paths.rpt)).

They are consumed combinationally on **clk_148**, inside the read-address
calculation at `rtl/openaars/adv7511/pal_to_hd_upsample.v:388-405`:

```verilog
      0: r_addrb <= 14'h0000 - (PAL_OFFSET_HZ + i_hd_hoffset);
```

There is no synchroniser. Worse, the path is explicitly untimed —
`fpga/openaars/aars_v5.0/xc7a100t/wizard.xdc:41` (the false path covers
`dll_28` as well as `clk_114`):

```tcl
set_false_path -from [get_clocks {dll_28 clk_114 clk_sd_114}] -to [get_clocks clk_148]
```

The `set_max_delay ... 1.800` on line 46 is overridden by the false path.
Confirmed in
`project_1/project_1.runs/impl_1/minimig_openaars_top_timing_summary_routed.rpt`,
*User Ignored Path Table*:

```
(none)   clk_114   clk_148
```

Verified in Vivado 2026-09-04: `pos_data_q_reg[11]/C → my50hzupsample/r_addrb_reg[13]/D`,
`Slack: inf`, 3.4 ns of combinational subtractor in between, no synchroniser.

Individual bits of the 8-bit bus therefore land on different `clk_148` cycles
while the value is changing. A transition from 0x0F to 0x10 can be sampled as
0x1F or 0x00 — a swing of 16 or 31 pixels for one line.

## Fix, part 1: synchronise and latch on the frame boundary

In `pal_to_hd_upsample.v`, in the `clk_out` domain:

```verilog
(* ASYNC_REG = "TRUE" *) reg [7:0] s_hoff_meta, s_hoff_sync;
(* ASYNC_REG = "TRUE" *) reg [7:0] s_voff_meta, s_voff_sync;
reg [7:0] r_hoff_active = 8'd0;
reg [7:0] r_voff_active = 8'd0;

always @(posedge clk_out) begin
  s_hoff_meta <= i_hd_hoffset;  s_hoff_sync <= s_hoff_meta;
  s_voff_meta <= i_hd_voffset;  s_voff_sync <= s_voff_meta;

  // Only ever change the live value between frames
  if (r_frame_end) begin
    r_hoff_active <= s_hoff_sync;
    r_voff_active <= s_voff_sync;
  end
end
```

Use `r_hoff_active` / `r_voff_active` everywhere downstream — the read address
(fix 4), and the vertical translate (fix 2).

The frame latch is the important half. Two flip-flops stop metastability but not
bit skew; latching only at `r_frame_end` means a mid-transfer bit mix can at
worst place one *frame* at the wrong position, never one line.

## Fix, part 2: bound the path instead of ignoring it

Replace `wizard.xdc:41` and delete line 46:

```tcl
set_clock_groups -asynchronous \
  -group [get_clocks {dll_28 clk_114 clk_sd_114}] \
  -group [get_clocks clk_148]

# Bound the synchroniser input paths so placement cannot stretch them
set_max_delay -datapath_only \
  -from [get_clocks {dll_28 clk_114}] -to [get_clocks clk_148] 6.734
```

`set_clock_groups -asynchronous` is the correct way to express "these are
unrelated"; the `-datapath_only` max delay keeps the crossing routed tightly so
the two-flop synchroniser actually has a full cycle to settle.

## Verify

* After synthesis, the *User Ignored Path Table* must no longer list
  `clk_114 → clk_148` as an unbounded ignore.
* In simulation, drive the offset input with a value that changes one step per
  frame and assert that `r_addrb` at the start of every line in a frame is
  identical.
* On hardware, hold the offset key down and sweep end to end: no flashes.

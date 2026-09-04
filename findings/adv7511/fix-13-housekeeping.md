# Fix 13 — Housekeeping

**Finding C · Effort: small · Latent bugs and dead logic found while tracing the
two main symptoms. None is the primary cause, all are worth clearing.**

## Unconnected RAM write port

`rtl/openaars/adv7511/pal_to_hd_upsample.v:145-148`:

```verilog
  .b_addr(r_addrb),
  .b_din(),
  .b_dout(w_doutb),
  .b_wr()
```

`b_wr` is a write enable left floating. Tie both:

```verilog
  .b_din(24'd0),
  .b_wr(1'b0),
```

## CDC findings from `report_cdc` (verified 2026-09-04)

From [../constraints/vivado-reports/06_cdc.rpt](../constraints/vivado-reports/06_cdc.rpt),
crossings into `clk_148`:

* **CDC-11 Critical ×3** — `pal_to_ddr/s_pal_vsync_reg[1]` fans out to three
  separate synchronisers: `my50hzupsample/s_pal_vsync_reg[0]`,
  `my60hzupsample/s_pal_vsync_reg[0]`, `myfreq/vsync_buf_reg[0]`. Each can
  resolve on a different cycle. Synchronise once in `pal_to_ddr` and distribute
  the synchronised signal — [fix-11](fix-11-collapse-pipelines.md) removes two
  of the three consumers anyway.
* **CDC-10 Critical** — `AGNUS1/bc1/beamcon0_reg[6]` (`dll_28`) reaches
  `adv_ddr/vsync_s_reg[0]` through combinational logic. A synchroniser input
  must be a register output, not a LUT.
* **CDC-2 Warning ×2** — `s_next_buf_reg[0..1]` in both upsamplers lack
  `ASYNC_REG`. `pal_to_hd_upsample.v:242` declares `reg [3:0] s_next_buf`
  without the attribute.
* The 28 MHz reset into the whole block — 148 Critical rows — is
  [../constraints/fix-11](../constraints/fix-11-reset-into-clk148.md).

## Bypassed input synchronisers

`rtl/openaars/adv7511/pal_to_ddr.sv:96-104`:

```systemverilog
  // assign w_pal_r = s_pal_r[1];
  // assign w_pal_g = s_pal_g[1];
  // assign w_pal_b = s_pal_b[1];
  assign w_pal_hsync = s_pal_hsync[1];
  assign w_pal_vsync = s_pal_vsync[1];

  assign w_pal_r = i_pal_r;
  assign w_pal_g = i_pal_g;
  assign w_pal_b = i_pal_b;
```

The RGB synchronisers are built at `:91-93` and then bypassed. Raw `clk_28`
data is sampled by `clk_114`, and it is skewed about two `clk_114` cycles from
the synchronised hsync — a sub-pixel shift, but the metastability exposure is
real. Use `s_pal_r[1]` etc., and delay the hsync by the matching amount so the
line start stays aligned.

## Dead passthrough detection

`rtl/openaars/adv7511/pal_to_ddr.sv:108-130` computes `r_passthrough` from a
line count and never uses it, so VGA/RTG passthrough does not exist. Synthesis
removes it:

```
WARNING: [Synth 8-6014] Unused sequential element hz_in_count_reg was removed.   ...:116
WARNING: [Synth 8-6014] Unused sequential element r_passthrough_reg was removed. ...:121
```

Implement it or delete it.

## Blocking assignments in clocked blocks

`rtl/openaars/adv7511/signal_generator.sv:120` — `r_dev_cnt = 0;` in reset while
the same register uses `<=` at `:124`. And `:171` / `:182` —
`vt_count_enable = 1'b1;` / `vt_count_enable = 1'b0;` mixed with nonblocking
assignments in the same always block. Both work today only because of statement
ordering. Use `<=` throughout; this is a simulation/synthesis mismatch waiting
to happen.

## Dead registers in the upsampler

`rtl/openaars/adv7511/pal_to_hd_upsample.v:190-195` computes `r_pal_h_pos` and
`r_act_active`, neither of which is read. Confirmed removed by synthesis
(`Synth 8-6014` at `:193` and `:194`). Delete.

## Missing reset

In `pal_to_hd_upsample.v`, `reset` reaches only the DDS block at `:220`.
`r_cur_read_buf`, `r_cur_write_buf`, `r_addra` and `r_addrb` rely on
initialisation values and are never reset, so after a warm reset the read/write
buffer separation is whatever it happened to be. Add them to a synchronous reset.

## `frame_freq` typo and clock constant

Covered in [fix-10-mode-detect-hysteresis.md](fix-10-mode-detect-hysteresis.md):
`'d22` returns 40 instead of 45 (`frame_freq.v:185-186`), `CLK_FREQ_IN` is 148
for a 148.5 MHz clock (`:23`, `:81`), and `cur_fps` is declared one bit wider
than `o_freq` (`pal_to_ddr.sv:133`).

## Stale `.bak` files

`rtl/openaars/adv7511/` carries `pal_to_hd_upsample.v.bak`,
`signal_generator.sv.bak`, `i2c_sender.vhd.bak`, `adv_ddr.v.bak` and
`floppy_buf.v.bak`. Git already holds the history. They make grepping the module
noisy and risk being picked up by a file-glob in the project file. Delete them.

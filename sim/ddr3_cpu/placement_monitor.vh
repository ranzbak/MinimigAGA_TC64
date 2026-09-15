// placement_monitor.vh -- where chip-RAM acknowledges land in the SDRAM round.
//
// Stage E1 (findings/ap68040/stage-e/2026-09-15-stage-e-design.md §5). The
// hardware rule, measured with TG68K.vhd's dbg_phist: with Turbo chip RAM the
// CPU's chip-RAM acknowledges must land on SDRAM round phases 2/6/10/14 (13
// also appears in clean runs); 3/7/11/15 corrupts.
//
//   ph16   <= 0 when ena7WRreg else ph16 + 1   (the controller's own ena7WR)
//   ack_r  <= ramready AND the chip-RAM select
//   bin ph16 on (ack_r AND NOT ack_d AND chip)
//
// CALIBRATED, NOT ABSOLUTE (Paul, 2026-09-15). This bench places chip-RAM
// acknowledges exactly one phase LATER than the hardware: with the shipping
// gate (delay 3) it peaks on 3/7/11/15, where dbg_phist on the board peaks on
// 2/6/10/14; with the gate as first built (delay 0) it peaks on 0/4/8/12,
// where the board peaks on 3/7/11/15. Two anchors, both +1. The cause is not
// found -- binning with dbg_phist's own formula (ramready AND a registered
// address decode, no select) moved no peak and only added a floor of edges
// the board does not show -- and MUST be explained with a hardware capture
// before Stage E2 changes the port (findings/ap68040/stage-e/e0-e1-results.md).
// So acknowledges are judged against the hardware grid shifted by
// PLACEMENT_OFFSET, with the select-gated formula, whose peaks are sharp.
//
// PLACEMENT_STRAY_PPM: the bench scatters about 5 % of acknowledges off its
// peaks at the shipping gate (94 of 1953), against 0.4 % on the board. 10 %
// passes that and still fails the delay-0 mutant, which lands ~94 % off.
// Included only under REALSDRAM: the enables must come from the real
// controller, not from the bench's own cadence model.
`ifndef PLACEMENT_OFFSET
`define PLACEMENT_OFFSET 1              // bench phase = hardware phase + 1
`endif
`ifndef PLACEMENT_STRAY_PPM
`define PLACEMENT_STRAY_PPM 100000      // 10 %
`endif

reg  [3:0] pm_ph16   = 4'd0;
reg        pm_ack_r  = 1'b0;
reg        pm_ack_d  = 1'b0;
reg        pm_chip_r = 1'b0;
longint    pm_bin [0:15];
longint    pm_total = 0, pm_stray = 0;
integer    pm_i;
initial for (pm_i = 0; pm_i < 16; pm_i = pm_i + 1) pm_bin[pm_i] = 0;

// Stage E step 2 (the bench-vs-board one-phase offset): the same bins split by
// the access type at the acknowledge -- a write (cpustate[1:0] = 11) or not.
// If reads and writes land one phase apart, a write-heavy workload on the
// board (Way Too Rude) and the pattern program's mix here would show different
// peaks with nothing wrong in either.  Reported only; the judgement below
// still uses pm_bin.
reg        pm_wr_r = 1'b0;
longint    pm_bin_rd [0:15];
longint    pm_bin_wr [0:15];
integer    pm_j;
initial for (pm_j = 0; pm_j < 16; pm_j = pm_j + 1) begin
  pm_bin_rd[pm_j] = 0;
  pm_bin_wr[pm_j] = 0;
end

// The phase the hardware would report for this bench phase (4-bit wrap).
wire [3:0] pm_hw   = pm_ph16 - `PLACEMENT_OFFSET;
// Chip RAM is the bottom 2 MB of ramaddr (bits 25:21 zero).
wire       pm_chip = !ramcs_n && (tg68_cad[25:21] == 5'd0);

always @(posedge clk) begin
  pm_ph16   <= ena7WR_real ? 4'd0 : pm_ph16 + 4'd1;
  pm_ack_r  <= ramready_real && !ramcs_n;
  pm_ack_d  <= pm_ack_r;
  pm_chip_r <= pm_chip;
  pm_wr_r   <= ram_wr;
  if (pm_ack_r && !pm_ack_d && pm_chip_r) begin
    pm_bin[pm_ph16] = pm_bin[pm_ph16] + 1;
    if (pm_wr_r) pm_bin_wr[pm_ph16] = pm_bin_wr[pm_ph16] + 1;
    else         pm_bin_rd[pm_ph16] = pm_bin_rd[pm_ph16] + 1;
    pm_total        = pm_total + 1;
    if (!(pm_hw == 4'd2 || pm_hw == 4'd6 || pm_hw == 4'd10 ||
          pm_hw == 4'd14 || pm_hw == 4'd13))
      pm_stray = pm_stray + 1;
  end
end

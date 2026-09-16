// placement_monitor.vh -- where chip-RAM acknowledges land in the SDRAM round.
//
// Stage E1 (findings/ap68040/stage-e/2026-09-15-stage-e-design.md §5). The
// hardware rule, measured with TG68K.vhd's dbg_phist: with Turbo chip RAM the
// CPU's chip-RAM WRITE acknowledges must land on SDRAM round phases 2/6/10/14
// (13 also appears in clean runs); 3/7/11/15 corrupts.
//
//   ph16   <= 0 when ena7WRreg else ph16 + 1   (the controller's own ena7WR)
//   ack_r  <= the SDRAM unit port's acknowledge (only ever high with its req)
//   bin ph16 on (ack_r AND NOT ack_d AND chip), split by the unit's cpu_we
//
// JUDGED PER ACCESS TYPE (Stage E2, decision D7).  Split by type the bench
// lands exactly where the board does (findings/ap68040/stage-e/e0-e1-results.md,
// "Stage E step 2"):
//
//   writes  2/6/10/14, plus 13     -- the board's grid, phase 13 included
//   reads   0/4/8/12               -- re-baselined for the unit port
//
// so each is judged against its own grid and the old single calibrated
// PLACEMENT_OFFSET (a fit to the pattern program's read mix) is gone.
//
// The READ grid moved with E2 and was re-baselined with Paul's OK
// (2026-09-16, plan D7).  At E4a reads landed on 3/7/11/15 (+4), one phase
// after writes; the unit port removed cpu_cache_new's answer-before-select
// line-buffer path, and reads now land two phases after writes (full --ap040
// leg, e2t4b: 6146 of 6558 on 0/4/8/12, 412 on 3/7/11/15).  The hardware
// evidence is about WRITES, which stayed exactly on 2/6/10/14/13.  A split
// access (ap040_ram_seq, two units) acknowledges twice; each unit is binned,
// because each is launched through the gate.
//
// PLACEMENT_STRAY_PPM: the bench scatters about 5 % of acknowledges off its
// peaks at the shipping gate, against 0.4 % on the board.  10 % per type
// passes that and still fails the gate mutant, which moves both grids.
`ifndef PLACEMENT_STRAY_PPM
`define PLACEMENT_STRAY_PPM 100000      // 10 %
`endif

reg  [3:0] pm_ph16   = 4'd0;
reg        pm_ack_r  = 1'b0;
reg        pm_ack_d  = 1'b0;
reg        pm_chip_r = 1'b0;
reg        pm_wr_r   = 1'b0;
longint    pm_bin    [0:15];
longint    pm_bin_rd [0:15];
longint    pm_bin_wr [0:15];
longint    pm_total = 0;
longint    pm_rd_total = 0, pm_rd_stray = 0;
longint    pm_wr_total = 0, pm_wr_stray = 0;
integer    pm_i;
initial for (pm_i = 0; pm_i < 16; pm_i = pm_i + 1) begin
  pm_bin[pm_i]    = 0;
  pm_bin_rd[pm_i] = 0;
  pm_bin_wr[pm_i] = 0;
end

// Chip RAM is the bottom 2 MB of the mapped address (word address bits 25:21 zero).
wire       pm_chip  = ram_req && (ram_wadr[25:21] == 5'd0);
wire       pm_rd_ok = (pm_ph16 == 4'd0 || pm_ph16 == 4'd4 || pm_ph16 == 4'd8 ||
                       pm_ph16 == 4'd12);
wire       pm_wr_ok = (pm_ph16 == 4'd2 || pm_ph16 == 4'd6 || pm_ph16 == 4'd10 ||
                       pm_ph16 == 4'd14 || pm_ph16 == 4'd13);

always @(posedge clk) begin
  pm_ph16   <= ena7WR_real ? 4'd0 : pm_ph16 + 4'd1;
  pm_ack_r  <= ram_ack && ram_req;
  pm_ack_d  <= pm_ack_r;
  pm_chip_r <= pm_chip;
  pm_wr_r   <= ram_we;
  if (pm_ack_r && !pm_ack_d && pm_chip_r) begin
    pm_bin[pm_ph16] = pm_bin[pm_ph16] + 1;
    pm_total        = pm_total + 1;
    if (pm_wr_r) begin
      pm_bin_wr[pm_ph16] = pm_bin_wr[pm_ph16] + 1;
      pm_wr_total        = pm_wr_total + 1;
      if (!pm_wr_ok) pm_wr_stray = pm_wr_stray + 1;
    end else begin
      pm_bin_rd[pm_ph16] = pm_bin_rd[pm_ph16] + 1;
      pm_rd_total        = pm_rd_total + 1;
      if (!pm_rd_ok) pm_rd_stray = pm_rd_stray + 1;
    end
  end
end

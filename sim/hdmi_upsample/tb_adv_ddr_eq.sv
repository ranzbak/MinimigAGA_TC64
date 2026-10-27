// tb_adv_ddr_eq: adv_ddr.sv (the clean-up, 9e189a4e) against the module it
// replaced, ref/adv_ddr_ref.v (d52bebae's adv_ddr.v).  Both get the same
// inputs; every output -- the internal twins clk_pixel_out, de_out,
// vsync_out, hsync_out, data_out and the pad registers pad_clk, pad_de,
// pad_vsync, pad_hsync, pad_data -- is compared with !== (X included) after
// every clk_out posedge and every negedge, from time 0, resets included.
// Stimulus, changed after the negedge (clk_out-synchronous, as on the board):
// clk_in toggling every clock with random phase slips, hsync / vsync on a
// small raster (LL pixels x FL lines) with random glitches, random data,
// random resets (~1 in 10000 clocks).  Parameters PTD / PAD / PY / ACT are
// the DE window (PX_TO_DE, PX_ACT_DE, PY_TO_DE, ACT_720P), set to fit the
// small raster; +n=N clocks (default 4 M).  Prints ALL TESTS PASSED on 0
// mismatches.  run.sh runs it (iverilog -g2012) with two parameter sets.
module tb_adv_ddr_eq;
  parameter int PTD = 10, PAD = 40, PY = 3, ACT = 20;
  localparam int LL = 70, FL = 30;   // pixels per line, lines per frame

  logic        clk = 1'b0, clk_in = 1'b0, reset = 1'b1, vsync = 1'b0, hsync = 1'b0;
  logic [23:0] data = '0;
  wire         o_cp, o_de, o_vs, o_hs, p_c, p_de, p_vs, p_hs;
  wire  [11:0] o_d, p_d;
  wire         n_cp, n_de, n_vs, n_hs, q_c, q_de, q_vs, q_hs;
  wire  [11:0] n_d, q_d;

  adv_ddr_ref #(.PX_TO_DE(PTD), .PX_ACT_DE(PAD), .PX_TOTAL(1980), .PY_TO_DE(PY), .ACT_720P(ACT),
                .V_LINES_TOTAL(750)) r
   (.clk_out(clk), .clk_in(clk_in), .reset(reset), .vsync(vsync), .hsync(hsync), .data(data),
    .clk_pixel_out(o_cp), .de_out(o_de), .vsync_out(o_vs), .hsync_out(o_hs), .data_out(o_d),
    .pad_clk(p_c), .pad_de(p_de), .pad_vsync(p_vs), .pad_hsync(p_hs), .pad_data(p_d));
  adv_ddr #(.PX_TO_DE(PTD), .PX_ACT_DE(PAD), .PX_TOTAL(1980), .PY_TO_DE(PY), .ACT_720P(ACT),
            .V_LINES_TOTAL(750)) n
   (.clk_out(clk), .clk_in(clk_in), .reset(reset), .vsync(vsync), .hsync(hsync), .data(data),
    .clk_pixel_out(n_cp), .de_out(n_de), .vsync_out(n_vs), .hsync_out(n_hs), .data_out(n_d),
    .pad_clk(q_c), .pad_de(q_de), .pad_vsync(q_vs), .pad_hsync(q_hs), .pad_data(q_d));

  wire [31:0] ov = {o_cp, o_de, o_vs, o_hs, o_d, p_c, p_de, p_vs, p_hs, p_d};
  wire [31:0] nv = {n_cp, n_de, n_vs, n_hs, n_d, q_c, q_de, q_vs, q_hs, q_d};

  int n_clk, i, err = 0, cmp = 0, hx = 0, ln = 0, dehi = 0, rst = 0;

  task automatic check(input string edge_name);
    cmp = cmp + 1;
    if (ov !== nv) begin
      err = err + 1;
      if (err <= 10) $display("FAIL %s clock %0d: ref %h new %h", edge_name, i, ov, nv);
    end
  endtask

  initial begin
    if (!$value$plusargs("n=%d", n_clk)) n_clk = 4000000;
    for (i = 0; i < n_clk; i = i + 1) begin
      #1 clk = 1'b1;
      #1 check("posedge");
      clk = 1'b0;
      #1 check("negedge");
      clk_in = ~clk_in;
      if ($urandom % 97 == 0) clk_in = ~clk_in;          // phase slip
      hx = hx + 1;
      if (hx == 2 * LL) begin
        hx = 0;
        ln = (ln == FL - 1) ? 0 : ln + 1;
      end
      hsync = (hx < 8) ^ ($urandom % 5000 == 0);
      vsync = (ln < 2) ^ ($urandom % 20000 == 0);
      data  = 24'($urandom);
      reset = (i < 10) || ($urandom % 10000 == 0);
      if (reset) rst = rst + 1;
      if (q_de) dehi = dehi + 1;
    end
    $display("PTD=%0d PAD=%0d PY=%0d ACT=%0d: %0d compares, %0d mismatches, pad_de high %0d clocks, reset %0d clocks",
             PTD, PAD, PY, ACT, cmp, err, dehi, rst);
    if (err == 0) $display("ALL TESTS PASSED");
    else $display("FAILURES");
    $finish;
  end
endmodule

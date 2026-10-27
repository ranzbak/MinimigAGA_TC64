`timescale 1ps / 1ps
// osd_text_tb -- rtl/openaars/adv7511/osd_text.v on the 720p generator
// (signal_generator.sv, 720p50; +hz60: 720p60), as pal_to_ddr.sv will wire it in Phase 2:
// the generator's video, syncs, pixel enable (~o_adv_clk) and frame pulse
// into osd_text.
// Run it in a leg directory made by model.py gen (run.sh does all of it):
//
//   cells_g.hex  2048 x 16  pass 1, both lanes (garbage)
//   cells_c.hex  2048 x 16  pass 2, lane 0 only: [7:0] the final char
//   cells_a.hex  2048 x 16  pass 3, lane 1 only: [15:8] the final attr
//   font_w.hex   2048 x 20  font writes {adr[11:0], byte}
//   pal_a.hex, pal_b.hex   64 x 8  staging palette bytes 0..63
//   cfg.hex      2 x 40     txt_cfg A, B
//   osd_font.mem            the font RAM's power-up content
//
// Sequence: frame 0 writes everything (cells in three lane passes, font,
// palette A, cfg A) and toggles txt_commit; frame 1 shows A and, from line
// 300 on, gets palette B and cfg B written plus a commit toggle (it must
// still show A: live copy only at the frame pulse); frame 2 shows B.
// in_<f>.hex / out_<f>.hex (f = 1, 2): the 1280 x 720 pixels at osd_text's
// input and output, "rrggbb" per line, one per pixel: the first clock of
// each pixel (pe low) with DE high.  model.py renders out_<f> from in_<f>.
//
// Checks here, every clock:
//   * o_hs, o_vs, o_de = the inputs 2*LAT clocks earlier
//   * each captured pixel holds for both of its clocks (in and out)
//   * outside the captured pixels, o_r/g/b = the input 2*LAT clocks earlier
//   * +off: o_r/g/b = the input 2*LAT clocks earlier on every clock
// The input video is a random value per pixel, changing at the pixel
// boundary (one clock before the generator registers it).
module osd_text_tb;

parameter LAT = 3;
localparam D = 2 * LAT;
localparam DD = (D > 0) ? D : 1;    // LAT 0: no delay line, the checks use the input as it is
localparam NPIX = 1280 * 720;

reg clk = 1'b0, wclk = 1'b0, reset = 1'b1;
always #3367 clk = ~clk;      // 148.5 MHz
always #17620 wclk = ~wclk;   // 28.375 MHz (dll_28)

// ---- the generator ------------------------------------------------------------------
reg  [7:0] vi_r = 8'd0, vi_g = 8'd0, vi_b = 8'd0;
reg        frame_end = 1'b0;
wire [7:0] g_r, g_g, g_b;
wire       g_hs, g_vs, g_de, g_frame, g_clk;
wire       g_pe = ~g_clk;       // the pixel enable (r_vid_enable)
signal_generator #(
  .PAL_HZ_ACT_PIX(1280), .PAL_HZ_FRONT_PORCH(440), .PAL_HZ_FRONT_PORCH60(110),
  .PAL_HZ_SYNC_WIDTH(40), .PAL_HZ_BACK_PORCH(220),
  .PAL_VT_ACT_LN(720), .PAL_VT_FRONT_PORCH(5), .PAL_VT_SYNC_WIDTH(5), .PAL_VT_BACK_PORCH(20)
) hd_gen (
  .clk(clk), .reset(reset), .i_hz60(hz60), .i_frame_end(frame_end),
  .i_r(vi_r), .i_g(vi_g), .i_b(vi_b),
  .o_hsync(g_hs), .o_vsync(g_vs), .o_x(), .o_y(),
  .o_frame(g_frame), .o_r(g_r), .o_g(g_g), .o_b(g_b), .o_adv_clk(g_clk), .o_adv_de(g_de)
);

// ---- the layer ---------------------------------------------------------------------------
reg        txt_we = 1'b0, font_we = 1'b0, pal_we = 1'b0, txt_commit = 1'b0;
reg [1:0]  txt_lane = 2'd0;
reg [10:0] txt_adr = 11'd0;
reg [15:0] txt_dat = 16'd0;
reg [11:0] font_adr = 12'd0;
reg [7:0]  font_dat = 8'd0;
reg [5:0]  pal_adr = 6'd0;
reg [7:0]  pal_dat = 8'd0;
reg [39:0] txt_cfg = 40'd0;
wire [7:0] o_r, o_g, o_b;
wire       o_hs, o_vs, o_de;
osd_text #(.LAT(LAT)) dut (
  .clk(clk), .i_pe(g_pe), .i_frame(g_frame),
  .i_r(g_r), .i_g(g_g), .i_b(g_b), .i_hs(g_hs), .i_vs(g_vs), .i_de(g_de),
  .o_r(o_r), .o_g(o_g), .o_b(o_b), .o_hs(o_hs), .o_vs(o_vs), .o_de(o_de),
  .wclk(wclk),
  .txt_we(txt_we), .txt_lane(txt_lane), .txt_adr(txt_adr), .txt_dat(txt_dat),
  .font_we(font_we), .font_adr(font_adr), .font_dat(font_dat),
  .pal_we(pal_we), .pal_adr(pal_adr), .pal_dat(pal_dat),
  .txt_cfg(txt_cfg), .txt_commit(txt_commit)
);

// ---- leg data ----------------------------------------------------------------------------
reg [15:0] cells_g [0:2047];
reg [15:0] cells_c [0:2047];
reg [15:0] cells_a [0:2047];
reg [19:0] font_w [0:2047];
reg [7:0]  pal_a [0:63];
reg [7:0]  pal_b [0:63];
reg [39:0] cfg [0:1];
reg        off, hz60;
integer    FRAME_CLK;         // one frame_end pulse per 750 lines
integer    errs = 0;
initial begin
  $readmemh("cells_g.hex", cells_g);
  $readmemh("cells_c.hex", cells_c);
  $readmemh("cells_a.hex", cells_a);
  $readmemh("font_w.hex", font_w);
  $readmemh("pal_a.hex", pal_a);
  $readmemh("pal_b.hex", pal_b);
  $readmemh("cfg.hex", cfg);
  off = $test$plusargs("off");
  hz60 = $test$plusargs("hz60");
  FRAME_CLK = 750 * (hz60 ? 1651 : 1981) * 2;
end

// ---- frame pacing: one frame_end pulse per 750 lines of 1981 pixels (+hz60: 1651) --
integer clkn = 0;
integer frames = 0;           // generator frame pulses seen
integer g_ny = 0;             // hsyncs since the frame pulse (the line, for the writes)
reg     hs_q = 1'b0;
always @(posedge clk) begin
  hs_q <= g_hs;
  if (g_frame) g_ny <= 0;
  else if (g_hs && !hs_q) g_ny <= g_ny + 1;
end
always @(posedge clk) begin
  clkn <= clkn + 1;
  if (clkn == 8) reset <= 1'b0;
  frame_end <= (clkn % FRAME_CLK) == 40;
  if (g_frame) frames <= frames + 1;
end

// input video: a new random value per pixel, at the edge before the
// generator takes it (g_pe low), so it changes at the pixel boundary
reg [31:0] lfsr = 32'h1234_5678;
always @(posedge clk) if (!g_pe) begin
  lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
  {vi_r, vi_g, vi_b} <= {lfsr[7:0], lfsr[15:8], lfsr[23:16]} ^ {lfsr[31:24], lfsr[31:24], lfsr[31:24]};
end

// ---- write side (driven on the falling edge of wclk) ---------------------------------
integer k;
task wr_cells(input integer pass);
  begin
    for (k = 0; k < 2048; k = k + 1) begin
      @(negedge wclk);
      txt_we = 1'b1;
      txt_adr = k;
      txt_lane = (pass == 0) ? 2'b11 : (pass == 1) ? 2'b01 : 2'b10;
      txt_dat = (pass == 0) ? cells_g[k] : (pass == 1) ? cells_c[k] : cells_a[k];
    end
    @(negedge wclk) txt_we = 1'b0;
  end
endtask
task wr_font;
  begin
    for (k = 0; k < 2048; k = k + 1) begin
      @(negedge wclk);
      font_we = 1'b1;
      font_adr = font_w[k][19:8];
      font_dat = font_w[k][7:0];
    end
    @(negedge wclk) font_we = 1'b0;
  end
endtask
task wr_pal(input integer which);
  begin
    for (k = 0; k < 64; k = k + 1) begin
      @(negedge wclk);
      pal_we = 1'b1;
      pal_adr = k;
      pal_dat = which ? pal_b[k] : pal_a[k];
    end
    @(negedge wclk) pal_we = 1'b0;
  end
endtask

initial begin
  wait (frames == 1);
  wr_cells(0);
  wr_cells(1);
  wr_cells(2);
  wr_font;
  wr_pal(0);
  @(negedge wclk) txt_cfg = cfg[0];
  @(negedge wclk) txt_commit = ~txt_commit;
  wait (frames == 2);
  wait (g_ny == 300);
  wr_pal(1);
  @(negedge wclk) txt_cfg = cfg[1];
  @(negedge wclk) txt_commit = ~txt_commit;
end

// ---- checks and capture --------------------------------------------------------------
reg [26:0] dl [0:DD-1];       // {rgb, hs, vs, de} of the input, D clocks
integer j;
always @(posedge clk) begin
  dl[0] <= {g_r, g_g, g_b, g_hs, g_vs, g_de};
  for (j = 1; j < D; j = j + 1) dl[j] <= dl[j-1];
end
wire [23:0] din = (D > 0) ? dl[DD-1][26:3] : {g_r, g_g, g_b};
wire [2:0]  dsy = (D > 0) ? dl[DD-1][2:0] : {g_hs, g_vs, g_de};

integer fi = -1, fo = -1;     // capture files
integer ni = 0, no = 0;       // pixels captured in this frame
integer capf = 0;             // frame being captured (1, 2), 0 = none
reg [23:0] li = 0, lo = 0;    // last captured pixel (in, out)
reg        hi = 0, ho = 0;    // second clock of a captured pixel
reg        act_o = 0;         // output: this clock belongs to a captured pixel
reg        live = 0;          // delay line filled
always @(posedge clk) begin
  if (clkn > D + 20) live <= 1'b1;
  // new frame
  if (g_frame && (frames == 1 || frames == 2)) begin
    if (fi >= 0) begin $fclose(fi); $fclose(fo); end
    capf <= frames + 1;
    fi = $fopen((frames == 1) ? "in_1.hex" : "in_2.hex", "w");
    fo = $fopen((frames == 1) ? "out_1.hex" : "out_2.hex", "w");
    ni = 0; no = 0;
  end
  if (live) begin
    if ({o_hs, o_vs, o_de} !== dsy) begin
      errs = errs + 1;
      if (errs < 10) $display("FAIL clk %0d: syncs %b, expected %b", clkn, {o_hs, o_vs, o_de}, dsy);
    end
    if (off && {o_r, o_g, o_b} !== din) begin
      errs = errs + 1;
      if (errs < 10) $display("FAIL clk %0d: off, rgb %h, expected %h", clkn, {o_r, o_g, o_b}, din);
    end
    // input pixels
    if (hi && {g_r, g_g, g_b} !== li) begin
      errs = errs + 1;
      if (errs < 10) $display("FAIL clk %0d: input pixel changes within its two clocks", clkn);
    end
    hi <= 1'b0;
    if (!g_pe && g_de && capf != 0 && ni < NPIX) begin
      $fdisplay(fi, "%h", {g_r, g_g, g_b});
      ni = ni + 1;
      li <= {g_r, g_g, g_b};
      hi <= 1'b1;
    end
    // output pixels (the delay is an even number of clocks: same pe phase)
    if (ho && {o_r, o_g, o_b} !== lo) begin
      errs = errs + 1;
      if (errs < 10) $display("FAIL clk %0d: output pixel changes within its two clocks", clkn);
    end
    ho <= 1'b0;
    if (!g_pe) act_o <= o_de;
    if (!g_pe && o_de && capf != 0 && no < NPIX) begin
      $fdisplay(fo, "%h", {o_r, o_g, o_b});
      no = no + 1;
      lo <= {o_r, o_g, o_b};
      ho <= 1'b1;
    end
    if (!(g_pe ? act_o : o_de) && {o_r, o_g, o_b} !== din) begin
      errs = errs + 1;
      if (errs < 10) $display("FAIL clk %0d: outside the picture, rgb %h, expected %h", clkn, {o_r, o_g, o_b}, din);
    end
  end
  if (frames == 3 && no == NPIX) begin
    $fclose(fi); $fclose(fo);
    if (ni != NPIX) begin errs = errs + 1; $display("FAIL: %0d input pixels in frame 2", ni); end
    if (errs == 0) $display("=== PASS osd_text_tb (LAT %0d, %0d clocks)", LAT, clkn);
    else $display("=== FAIL osd_text_tb: %0d errors", errs);
    $finish;
  end
  if (clkn > 4 * FRAME_CLK) begin
    $display("=== FAIL osd_text_tb: watchdog (frames %0d, pixels in %0d out %0d)", frames, ni, no);
    $finish;
  end
end

endmodule

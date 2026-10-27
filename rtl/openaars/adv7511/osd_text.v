`timescale 1ns / 1ps
// osd_text -- the OSD's native 720p text layer (findings/osd-redesign/plan.md
// 3.2-3.5, 4.2).  It sits on the HD stream after the CRT effects
// (signal_generator -> osd_text -> adv_ddr), so the menu is drawn
// pixel-exact on the 1280x720 raster, whatever the Amiga mode and the
// scaler do.  clk_148; one HD pixel = two clocks.  Vendor-neutral Verilog:
// inferred RAMs, no primitives.
//
// Picture
//   A window of cols x rows character cells, 8x16 pixels each (scale 1) or
//   16x32 (scale 2), top left at (x0*8, y0*8) on the 720p raster, clipped
//   to the raster.  Cell (c, r) of the window is cell RAM word r*64 + c
//   (stride 64: 64 x 32 cells addressable).  Cell word {attr, char}:
//   attr[3:0] foreground, attr[7:4] background palette index.  Glyph n row
//   l is font byte n*16 + l, bit 7 = left pixel.  Palette entry
//   {mode[1:0], r, g, b}:
//     mode 0  opaque: the entry's colour
//     mode 1  the video dimmed: video >> 1
//     mode 2  the video unchanged (transparent)
//     mode 3  50/50: (colour + video) >> 1, per channel, rounded down
//   Outside the window (and with the layer disabled) the video passes
//   unchanged.  cols 0 or rows 0 = no window; cols > 64 counts as 64,
//   rows > 32 as 32.
//
// Write side (wclk: dll_28, userio_osd.v; plan 4.1)
//   txt_we/txt_lane/txt_adr/txt_dat  cell RAM, lane 0 = char [7:0],
//                                    lane 1 = attr [15:8]
//   font_we/font_adr/font_dat        font RAM (power-up content: FONT_FILE,
//                                    made by fw/ctrl/tools/mkfontmem.py)
//   pal_we/pal_adr/pal_dat           staging palette, byte pal_adr[1:0] of
//                                    entry pal_adr[5:2]: 0 = mode in bits
//                                    7:6, 1 = r, 2 = g, 3 = b
//   txt_cfg[39:0]                    staging window: byte 0 ctrl {bit 0
//                                    enable, bit 1 scale 2}, byte 1 x0/8,
//                                    byte 2 y0/8, byte 3 cols, byte 4 rows
//   txt_commit                       toggle: copy the staging palette and
//                                    txt_cfg to the live ones at the next
//                                    i_frame.  2-FF synchroniser on the
//                                    toggle only; the staging values must
//                                    be static from the toggle to that frame
//                                    pulse (the firmware writes them first)
//   A cell or glyph rewritten while it is displayed shows one wrong pixel
//   for one frame (accepted, plan 7.3); palette and window never tear.
//
// Position (the layer needs nothing from the generator but its outputs)
//   i_pe is the pixel enable: high on the second clock of each pixel, so a
//   pixel's video changes at the edge that samples i_pe high (pal_to_ddr:
//   ~w_adv_clk, signal_generator's r_vid_enable).  At those edges the layer
//   samples i_hs and i_de and keeps two counters:
//     nx  the next pixel's x, 0-based on the raster, counting on through the
//         blanking modulo 4096: the pixel whose video reaches i_r/g/b one
//         pixel later.  Set at the hsync's start to 1 - cal, + 1 per pixel.
//     cal pixels from the hsync's start to the DE's start, measured on each
//         line with DE (HS_DE until the first one): no porch constants, the
//         same in 720p50 and 720p60.
//     ny  the line, 0 = the first line with DE after i_frame: set at
//         i_frame to -1 - vcal, + 1 at each hsync start, so it is valid
//         from the line's hsync on, well before its first pixel.
//     vcal hsyncs from i_frame to the first line with DE (its hsync
//         included) less one, measured in each frame (VS_DE until the
//         first one): row 0 follows the DE wherever the generator puts
//         its active lines (signal_generator PAL_VT_TOP: DE from vt_count
//         15), no vertical porch constants either.
//   This reproduces the generator's own counters (hz_count - c_act - 1,
//   vt_count - the first active line) exactly; signal_generator's DE rises
//   one clock before the pixel's video, which is what cal's "+ 1" takes
//   into account.
//
// Timing
//   The video, i_hs, i_vs and i_de leave LAT pixels (2*LAT clocks) later, so
//   the relative timing of syncs and data is unchanged.  The overlay
//   pipeline is longer than that (PIPE clocks); it works on the position
//   LEAD pixels ahead of nx instead, so its result meets the pixel it
//   belongs to at the output.  Every clock is a pipeline stage (the inputs
//   hold for the two clocks of a pixel), one LUT level each:
//
//   +1  xi, yi        the counters nx, ny copied
//   +2  dx, dy        position in the window (x + LEAD - x0*8, y - y0*8),
//                     x_ok / y_ok: on the 1280x720 raster
//   +3  col, row, glyph column/line (dx, dy >> scale), hin/vin: dx < width,
//                     dy < height; {row, col} is the cell RAM address
//   +4  cell RAM read, win = hin & vin & on the raster & enable
//   +5  cell RAM output register; {char, line} is the font RAM address
//   +6  font RAM read
//   +7  font RAM output register
//   +8  the glyph bit
//   +9  palette index: bit ? attr[3:0] : attr[7:4]
//   +10 palette entry (16:1 mux)
//   +11 effective mode (2 outside the window), colour + video sum
//   +12 o_r/g/b
//
//   LAT 0 (pal_to_ddr.sv): no delay at all.  The overlay's mode and colour
//   are registered once more (+12) and blended with the input video
//   combinationally (mode 3: an 8-bit add per channel); the syncs and DE
//   pass through as wires.  The chain behind the layer sees exactly the
//   generator's timing, and with the layer off exactly its video.
//
// Bench: sim/osd_text (model.py renders the same frames; LAT check with the
// layer off).  OOC size/timing: tools/vivado/ooc_osd.
module osd_text #(
  parameter FONT_FILE = "osd_font.mem",
  parameter LAT   = 3,          // video and sync delay, pixels (0..5; 0: see "LAT 0")
  parameter H_ACT = 1280,       // the raster
  parameter V_ACT = 720,
  parameter HS_DE = 261,        // cal at power-up (720p50/60: sync 40 + back porch 220, + 1)
  parameter VS_DE = 0           // vcal at power-up (the first line with DE after i_frame)
)(
  input             clk,        // clk_148
  input             i_pe,       // pixel enable (~signal_generator o_adv_clk)
  input             i_frame,    // signal_generator o_frame: line 0; live <- staging here
  input      [7:0]  i_r,
  input      [7:0]  i_g,
  input      [7:0]  i_b,
  input             i_hs,
  input             i_vs,
  input             i_de,
  output     [7:0]  o_r,
  output     [7:0]  o_g,
  output     [7:0]  o_b,
  output            o_hs,
  output            o_vs,
  output            o_de,
  // write side, wclk (dll_28)
  input             wclk,
  input             txt_we,
  input      [1:0]  txt_lane,
  input      [10:0] txt_adr,
  input      [15:0] txt_dat,
  input             font_we,
  input      [11:0] font_adr,
  input      [7:0]  font_dat,
  input             pal_we,
  input      [5:0]  pal_adr,
  input      [7:0]  pal_dat,
  input      [39:0] txt_cfg,    // staging, static around a commit
  input             txt_commit  // toggle
);

localparam PIPE = 12;                 // clocks from nx to o_r/g/b
localparam LEAD = PIPE / 2 - 1 - LAT; // pixels; nx leads its video by one
localparam [11:0] LEADV = LEAD;
localparam D1   = 2 * LAT - 2;        // video registers before the blend's two
localparam [11:0] XEND = H_ACT - LEADV;    // xi on the raster: [4096-LEAD, 4096) U [0, XEND)
localparam [11:0] XWRAP = 12'd0 - LEADV;

// ---- staging palette (wclk) -----------------------------------------------------------------
reg [1:0] stg_m [0:15];
reg [7:0] stg_r [0:15];
reg [7:0] stg_g [0:15];
reg [7:0] stg_b [0:15];
integer i;
initial for (i = 0; i < 16; i = i + 1) begin
  stg_m[i] = 2'd0; stg_r[i] = 8'd0; stg_g[i] = 8'd0; stg_b[i] = 8'd0;
end
always @(posedge wclk) if (pal_we) begin
  case (pal_adr[1:0])
    2'd0: stg_m[pal_adr[5:2]] <= pal_dat[7:6];
    2'd1: stg_r[pal_adr[5:2]] <= pal_dat;
    2'd2: stg_g[pal_adr[5:2]] <= pal_dat;
    2'd3: stg_b[pal_adr[5:2]] <= pal_dat;
  endcase
end

// ---- commit: staging -> live at the frame pulse ---------------------------------------
(* ASYNC_REG = "TRUE" *) reg [1:0] s_commit = 2'b00;
reg        r_ack    = 1'b0;
reg [39:0] live_cfg = 40'd0;          // enable 0 until the first commit
reg [1:0]  live_m [0:15];
reg [23:0] live_c [0:15];             // {r, g, b}
initial for (i = 0; i < 16; i = i + 1) begin
  live_m[i] = 2'd2; live_c[i] = 24'd0;
end
always @(posedge clk) begin
  s_commit <= {s_commit[0], txt_commit};
  if (i_frame && (s_commit[1] != r_ack)) begin
    r_ack    <= s_commit[1];
    live_cfg <= txt_cfg;
    for (i = 0; i < 16; i = i + 1) begin
      live_m[i] <= stg_m[i];
      live_c[i] <= {stg_r[i], stg_g[i], stg_b[i]};
    end
  end
end

// the window, from the live copy (static for a frame; two registers so the
// clamps stay one LUT level)
reg        c_en = 1'b0, c_s2 = 1'b0;
reg [11:0] c_x0 = 12'd0;              // x0*8 - LEAD
reg [11:0] c_y0 = 12'd0;              // y0*8
reg        c_cgt = 1'b0, c_rgt = 1'b0;    // cols > 64, rows > 32
reg [10:0] c_wid = 11'd0;             // window width, pixels
reg [10:0] c_hei = 11'd0;             // window height, lines
always @(posedge clk) begin
  c_en  <= live_cfg[0];
  c_s2  <= live_cfg[1];
  c_x0  <= {1'b0, live_cfg[15:8], 3'b000} - LEADV;
  c_y0  <= {1'b0, live_cfg[23:16], 3'b000};
  c_cgt <= live_cfg[31] | (live_cfg[30] & (|live_cfg[29:24]));
  c_rgt <= (|live_cfg[39:38]) | (live_cfg[37] & (|live_cfg[36:32]));
  c_wid <= c_cgt ? (c_s2 ? 11'd1024 : 11'd512) :
           (c_s2 ? {live_cfg[30:24], 4'b0000} : {1'b0, live_cfg[30:24], 3'b000});
  c_hei <= c_rgt ? (c_s2 ? 11'd1024 : 11'd512) :
           (c_s2 ? {live_cfg[37:32], 5'b00000} : {1'b0, live_cfg[37:32], 4'b0000});
end

// ---- RAMs ----------------------------------------------------------------------------------------
(* ram_style = "block" *) reg [15:0] cells [0:2047];
(* ram_style = "block" *) reg [7:0]  font  [0:4095];
initial for (i = 0; i < 2048; i = i + 1) cells[i] = 16'd0;
initial $readmemh(FONT_FILE, font);
always @(posedge wclk) if (txt_we) begin
  if (txt_lane[0]) cells[txt_adr][7:0]  <= txt_dat[7:0];
  if (txt_lane[1]) cells[txt_adr][15:8] <= txt_dat[15:8];
end
always @(posedge wclk) if (font_we) font[font_adr] <= font_dat;

// ---- position: the next pixel, from the pixel enable and the syncs -----------------
reg        hs_p = 1'b0, de_p = 1'b0;      // i_hs, i_de at the last pixel edge
reg [11:0] hcnt = 12'd0;                  // pixels since the hsync's start
reg [11:0] cal  = HS_DE;                  // pixels from the hsync's start to the DE's
reg [11:0] nx0  = 12'd1 - HS_DE;          // nx at the hsync's start
reg [11:0] nx   = 12'd0;
reg [11:0] ny   = 12'hfff;
reg [11:0] lcnt = 12'hfff;                // hsyncs since i_frame, less one
reg [11:0] vcal = VS_DE;                  // lcnt at the frame's first DE
reg        vseen = 1'b1;                  // vcal measured in this frame (none before the first i_frame)
always @(posedge clk) begin
  if (i_pe) begin
    hs_p <= i_hs;
    de_p <= i_de;
    hcnt <= hcnt + 1'b1;
    nx   <= nx + 1'b1;
    if (i_hs && !hs_p) begin
      hcnt <= 12'd0;
      nx   <= nx0;
      ny   <= ny + 1'b1;
      lcnt <= lcnt + 1'b1;
    end
    if (i_de && !de_p) begin
      cal <= hcnt + 1'b1;
      if (!vseen) begin
        vcal  <= lcnt;
        vseen <= 1'b1;
      end
    end
  end
  nx0 <= 12'd1 - cal;
  if (i_frame) begin
    ny    <= ~vcal;                       // -1 - vcal: 0 at the hsync of the first DE line
    lcnt  <= 12'hfff;
    vseen <= 1'b0;
  end
end

// ---- overlay pipeline ----------------------------------------------------------------------
// +1
reg [11:0] xi = 12'd0, yi = 12'd0;
// +2
reg [11:0] dx = 12'd0, dy = 12'd0;
reg        x_ok = 1'b0, y_ok = 1'b0;
// +3
reg [5:0]  col = 6'd0;
reg [4:0]  row = 5'd0;
reg [2:0]  gcol3 = 3'd0;
reg [3:0]  glin3 = 4'd0;
reg        hin = 1'b0, vin = 1'b0, ok3 = 1'b0;
// +4 .. +10
reg [15:0] c_q = 16'd0, c_qq = 16'd0;     // cell RAM read, output register
reg [7:0]  f_q = 8'd0, f_qq = 8'd0;       // font RAM read, output register
reg        win4 = 1'b0;
reg [3:0]  glin4 = 4'd0, glin5 = 4'd0;
reg [2:0]  gcol4 = 3'd0, gcol5 = 3'd0, gcol6 = 3'd0, gcol7 = 3'd0;
`ifdef OSD_TEXT_MUTANT
// MUTANT (bench only): the colours one pixel late -- the first pixel of each
// cell takes the previous cell's attribute, as a missing prefetch would
localparam ADLY = 5;
`else
localparam ADLY = 3;
`endif
reg [7:0]  attr [1:ADLY];                 // attr[k]: the cell word's attr, +5+k
reg        win5 = 1'b0, win6 = 1'b0, win7 = 1'b0, win8 = 1'b0, win9 = 1'b0, win10 = 1'b0;
reg        bit8 = 1'b0;
reg [3:0]  idx9 = 4'd0;
reg [1:0]  pm10 = 2'd0;
reg [23:0] pc10 = 24'd0;
// +11
reg [1:0]  me11 = 2'd2;
reg [23:0] pc11 = 24'd0;
initial for (i = 1; i <= ADLY; i = i + 1) attr[i] = 8'd0;

always @(posedge clk) begin
  // +1
  xi <= nx;
  yi <= ny;
  // +2
  dx   <= xi - c_x0;
  dy   <= yi - c_y0;
  x_ok <= (xi < XEND) || (xi >= XWRAP && LEAD != 0);
  y_ok <= yi < V_ACT;
  // +3
  hin   <= dx < {1'b0, c_wid};
  vin   <= dy < {1'b0, c_hei};
  ok3   <= x_ok & y_ok & c_en;
  col   <= c_s2 ? dx[9:4] : dx[8:3];
  row   <= c_s2 ? dy[9:5] : dy[8:4];
  gcol3 <= c_s2 ? dx[3:1] : dx[2:0];
  glin3 <= c_s2 ? dy[4:1] : dy[3:0];
  // +4 / +5: cell RAM, two registers
  c_q   <= cells[{row, col}];
  c_qq  <= c_q;
  win4  <= hin & vin & ok3;
  glin4 <= glin3;
  glin5 <= glin4;
  gcol4 <= gcol3;
  gcol5 <= gcol4;
  // +6 / +7: font RAM, two registers
  f_q   <= font[{c_qq[7:0], glin5}];
  f_qq  <= f_q;
  gcol6 <= gcol5;
  gcol7 <= gcol6;
  attr[1] <= c_qq[15:8];
  for (i = 2; i <= ADLY; i = i + 1) attr[i] <= attr[i-1];
  win5  <= win4;
  win6  <= win5;
  win7  <= win6;
  // +8: the glyph bit
  bit8  <= f_qq[3'd7 - gcol7];
  win8  <= win7;
  // +9: palette index
  idx9  <= bit8 ? attr[ADLY][3:0] : attr[ADLY][7:4];
  win9  <= win8;
  // +10: palette entry
  pm10  <= live_m[idx9];
  pc10  <= live_c[idx9];
  win10 <= win9;
  // +11: the effective mode (2 outside the window)
  me11 <= win10 ? pm10 : 2'd2;
  pc11 <= pc10;
end

// +12: the blend with the video
generate if (LAT == 0) begin : g_lat0
  // the overlay registered once more, then combinational with the input
  reg  [1:0]  me12 = 2'd2;
  reg  [23:0] pc12 = 24'd0;
  always @(posedge clk) begin
    me12 <= me11;
    pc12 <= pc11;
  end
  wire [8:0] sr = {1'b0, pc12[23:16]} + {1'b0, i_r};
  wire [8:0] sg = {1'b0, pc12[15:8]}  + {1'b0, i_g};
  wire [8:0] sb = {1'b0, pc12[7:0]}   + {1'b0, i_b};
  assign {o_r, o_g, o_b} = (me12 == 2'd0) ? pc12 :
                           (me12 == 2'd1) ? {1'b0, i_r[7:1], 1'b0, i_g[7:1], 1'b0, i_b[7:1]} :
                           (me12 == 2'd2) ? {i_r, i_g, i_b} :
                                            {sr[8:1], sg[8:1], sb[8:1]};
  assign {o_hs, o_vs, o_de} = {i_hs, i_vs, i_de};
end else begin : g_lat
  // the video: D1 registers, then +11 (with the sum) and +12; the syncs 2*LAT
  reg  [23:0] vdl [0:(D1 > 0 ? D1 - 1 : 0)];
  wire [23:0] vdel = (D1 > 0) ? vdl[(D1 > 0 ? D1 - 1 : 0)] : {i_r, i_g, i_b};
  reg  [2:0]  sdl [0:(LAT > 0 ? 2*LAT-1 : 0)];
  reg  [23:0] vd11 = 24'd0;
  reg  [8:0]  sr11 = 9'd0, sg11 = 9'd0, sb11 = 9'd0;
  reg  [23:0] orgb = 24'd0;
  integer k;
  initial for (k = 0; k < (D1 > 0 ? D1 : 1); k = k + 1) vdl[k] = 24'd0;
  initial for (k = 0; k < 2*LAT; k = k + 1) sdl[k] = 3'd0;
  always @(posedge clk) begin
    vd11 <= vdel;
    sr11 <= pc10[23:16] + vdel[23:16];
    sg11 <= pc10[15:8]  + vdel[15:8];
    sb11 <= pc10[7:0]   + vdel[7:0];
    case (me11)
      2'd0: orgb <= pc11;
      2'd1: orgb <= {1'b0, vd11[23:17], 1'b0, vd11[15:9], 1'b0, vd11[7:1]};
      2'd2: orgb <= vd11;
      2'd3: orgb <= {sr11[8:1], sg11[8:1], sb11[8:1]};
    endcase
    vdl[0] <= {i_r, i_g, i_b};
    for (k = 1; k < D1; k = k + 1) vdl[k] <= vdl[k-1];
    sdl[0] <= {i_hs, i_vs, i_de};
    for (k = 1; k < 2*LAT; k = k + 1) sdl[k] <= sdl[k-1];
  end
  assign {o_r, o_g, o_b} = orgb;
  assign {o_hs, o_vs, o_de} = sdl[(LAT > 0 ? 2*LAT-1 : 0)];
end endgenerate

endmodule

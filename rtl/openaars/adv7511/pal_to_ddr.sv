`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 01/02/2020 06:22:06 PM
// Design Name:
// Module Name: aars_video_top
// Project Name:
// Target Devices:
// Tool Versions:
// Description:
//
// Dependencies:
//
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
//
//////////////////////////////////////////////////////////////////////////////////
module pal_to_ddr #(
  // CRT emulation tables (crt_post.v); design sources next to this file
  parameter CRT_WROM_FILE = "crt_wrom.mem",
  parameter CRT_LUT_FILE  = "crt_lut.mem",
  parameter CRT_BLOOM_FILE = "crt_bloom.mem",
  // horizontal beam spot tables (crt_beamh.v)
  parameter CRT_HDEC_FILE = "crt_hdec.mem",
  parameter CRT_HENC_FILE = "crt_henc.mem",
  parameter CRT_HK_FILE   = "crt_hk.mem"
)(
  input clk_148,
  input clk_114,
  input reset,
  // VGA input
  input vga_clk_pixel,
  // Pal input
  input i_pal_hsync,
  input i_pal_vsync,
  input [7:0] i_pal_r,
  input [7:0] i_pal_g,
  input [7:0] i_pal_b,
  // Offset
  input [7:0] i_hoffset,
  input [7:0] i_voffset,
  // RTG
  input       i_rtg_enable,
  // CRT emulation (CLK_28 domain): the OSD video config as userio_osd
  // latches it, {beam[1:0], bloom[1:0], mask[1:0], hr_filter[1:0],
  // lr_filter[1:0], scanline[1:0]}, and Denise's BPLCON0 HIRES / SHRES for
  // the per-line filter choice
  input [11:0] i_crt_cfg,
  input       i_pal_hires,
  input       i_pal_shres,
  // OUTPUT
  output o_clk_pixel, // Output pixel clock after synchronization to clk_ddr
  output o_de, // Data enable signal
  output o_vsync,
  output o_hsync,
  output [11:0] o_data // DDR data stream out
);
  // Generated RGB values
  wire [7:0] w_r;
  wire [7:0] w_g;
  wire [7:0] w_b;
  wire       w_vsync;

  // Upsample routine
  wire [6:0] w_vblank_width;
  wire w_hd_hsync;
  wire w_hd_vsync;

  // enable to indicate the next data point is needed
  wire w_adv_de;
  wire w_adv_clk;

  // RGB signal in 720p@50Hz before DDR
  wire [7:0] w_o_r;
  wire [7:0] w_o_g;
  wire [7:0] w_o_b;
  wire [7:0] w_50_o_r;
  wire [7:0] w_50_o_g;
  wire [7:0] w_50_o_b;
  wire [7:0] w_60_o_r;
  wire [7:0] w_60_o_g;
  wire [7:0] w_60_o_b;

  (* ASYNC_REG = "TRUE" *) reg [2:0] s_pal_hsync;
  wire       w_pal_hsync;
  (* ASYNC_REG = "TRUE" *) reg  [2:0] s_pal_vsync;
  wire       w_pal_vsync;
  (* ASYNC_REG = "TRUE" *) reg  [7:0] s_pal_r [0:1];
  wire [7:0] w_pal_r;
  (* ASYNC_REG = "TRUE" *) reg  [7:0] s_pal_g [0:1];
  wire [7:0] w_pal_g;
  (* ASYNC_REG = "TRUE" *) reg  [7:0] s_pal_b [0:1];
  wire [7:0] w_pal_b;

  // Synchronize the signal
  wire [2:0] w_pal_hsync_next = {s_pal_hsync[1], s_pal_hsync[0], i_pal_hsync};
  wire [2:0] w_pal_vsync_next = {s_pal_vsync[1], s_pal_vsync[0], i_pal_vsync};
  always @(posedge clk_114)
  begin
    // Hsync/Vsync
    s_pal_hsync <= w_pal_hsync_next;
    s_pal_vsync <= w_pal_vsync_next;
    // Red/Green/Blue
    s_pal_r     <= { s_pal_r[0], i_pal_r };
    s_pal_g     <= { s_pal_g[0], i_pal_g };
    s_pal_b     <= { s_pal_b[0], i_pal_b };
  end

  // assign w_pal_r = s_pal_r[1];
  // assign w_pal_g = s_pal_g[1];
  // assign w_pal_b = s_pal_b[1];
  assign w_pal_hsync = s_pal_hsync[1];
  assign w_pal_vsync = s_pal_vsync[1];

  assign w_pal_r = i_pal_r;
  assign w_pal_g = i_pal_g;
  assign w_pal_b = i_pal_b;
  // assign w_pal_hsync = i_pal_hsync;
  // assign w_pal_vsync = i_pal_vsync;

  // Detect number of horizontal lines in video in
  reg [$clog2(1000):0] hz_in_count = 0;
  reg                  r_passthrough = 1'b0;

  always @(posedge clk_148)
  begin
    if (s_pal_hsync[2] == 1'b0 && s_pal_hsync[1] == 1'b1)
    begin
      hz_in_count <= hz_in_count + 1;
    end

    if (s_pal_vsync[2] == 1'b1 && s_pal_vsync[1] == 1'b0)
    begin
      r_passthrough <= 1'b0;
      // When there are more than 400 lines in the video signal,
      // Assume it's VGA and pass it through
      if (hz_in_count > 700)
      begin
        r_passthrough <= 1'b1;
      end
      hz_in_count <= 0;
    end
  end

  // Detect FPS
  wire [$clog2(100):0] cur_fps;
  wire                 fps_valid;
  reg                  r_50hz = 1'b0;
  reg                  r_60hz = 1'b0;
  frame_freq myfreq(
    .clk(clk_148),
    .reset(reset),
    .i_vsync(w_pal_vsync),
    .o_freq(cur_fps), // 7 bits frequency, 2 bits fraction
    .o_valid(fps_valid) //
  );

  // Depending on frame rate switch 50/60Hz
  always @(posedge clk_148)
  begin
    r_50hz <= 1'b0;
    r_60hz <= 1'b0;
    if (fps_valid == 1'b1)
    begin
      if (cur_fps < 53)
        begin
          r_50hz <= 1'b1;
        end
      else
        begin
          r_60hz <= 1'b1;
        end
    end
  end

  // Switch wires 50 Hz
  wire        w_50_hd_vsync;
  wire        w_50_hd_hsync;
  wire [11:0] w_50_x;
  wire [11:0] w_50_y;
  wire [7:0]  w_50_r;
  wire [7:0]  w_50_g;
  wire [7:0]  w_50_b;
  wire        w_50_adv_clk;
  wire        w_50_hsync;
  wire        w_50_vsync;
  wire        w_50_frame_end;
  wire        w_50_adv_de;
  // Switch wires 50 Hz
  wire        w_60_hd_hsync;
  wire        w_60_hd_vsync;
  wire [11:0] w_60_x;
  wire [11:0] w_60_y;
  wire [7:0]  w_60_r;
  wire [7:0]  w_60_g;
  wire [7:0]  w_60_b;
  wire        w_60_adv_clk;
  wire        w_60_hsync;
  wire        w_60_vsync;
  wire        w_60_frame_end;
  wire        w_60_adv_de;

  // -------------------------------------------------------------------------
  // CRT emulation (2026-10-09).  One crt_post after a 50/60 Hz select of the
  // two upsamplers' streams; its output feeds both signal generators (only
  // the selected one is shown).  crt_post delays the stream by CRT_LAT
  // pixels, and both upsamplers read CRT_LAT pixels earlier (PAL_OFFSET_HZ),
  // so with every effect off the picture is bit-identical to the design
  // without it (sim/hdmi_upsample/crt_run.sh, bypass legs).
  //
  // OSD mapping (the Video page):
  //   Scanlines   off / dim / black -> beam profile 0 / 2 / 3 and the
  //               brightness LUT page of the same number (page 0 = identity)
  //   Lores/Hires Filter, per input line by its resolution (lowres: the
  //   Lores item, hires and superhires: the Hires item):
  //     bit 0 (H) -> horizontal blur, [1 2 1]/4 lowres, [1 6 1]/8 hires
  //     bit 1 (V) -> two-line beam (with scanlines off: linear blend)
  //   CRT mask    off / grille / grille strong / shadow -> crt_post i_mask
  //               (3-px R G B stripes, 30 / 55 % gaps; 2-px magenta / green,
  //               40 %; the LUT divides each mode's mean light back out)
  //   Bloom       off / low / high -> crt_post i_bloom: bright pixels fill
  //               their scanline gap (needs scanlines or the V filter); with
  //               the beam on also crt_beamh's horizontal bloom
  //   Beam width  off / sharp / medium / soft -> crt_beamh (2026-10-09): the
  //               horizontal beam spot on the Amiga stream BEFORE the
  //               upsamplers (clk_114), gaussian sigma 0.5 / 0.6 / 0.8
  //               lowres pixels, the same on screen in every resolution.
  //               It has its own synchronisers and frame latch in clk_114
  //               and the same 15 kHz / no-RTG condition; off, the
  //               upsamplers get the input unchanged.
  // The effects need 15 kHz input (one input line = 2.4 HD lines): minimig.v
  // turns amber's scandoubler off while any of them is selected
  // (MINIMIG_OPENAARS), and here they apply only while the last input frame
  // had fewer than 400 lines and RTG is off -- otherwise today's picture.
  // The OSD bits are static: 2-FF synchronisers into clk_148, then a latch
  // at the frame end, so a change applies from the next frame on.  The
  // crossings are bounded by wizard.xdc (set_max_delay -datapath_only from
  // dll_28/clk_114 to clk_148).
  // -------------------------------------------------------------------------
  localparam CRT_LAT = 9;   // crt_post pipeline, HD pixels

  // The OSD Video Pos HPOS (signed HD pixels; static, written by the host
  // through VPOS_DATA): one 2-FF synchroniser into clk_148 for both
  // upsamplers.  VPOS: the same into clk_114.
  (* ASYNC_REG = "TRUE" *) reg [7:0] s_hoff0 = 8'd0;
  (* ASYNC_REG = "TRUE" *) reg [7:0] s_hoff1 = 8'd0;
  always @(posedge clk_148) begin
    s_hoff0 <= i_hoffset;
    s_hoff1 <= s_hoff0;
  end
  // VPOS (signed 64 us steps, positive down): a 2-FF synchroniser into
  // clk_114, where both upsamplers take it at each input hsync and decide
  // where the HD raster restarts (pal_to_hd_upsample.v, "Video Pos VPOS");
  // their clk_148 side only follows that decision.  The register is in
  // CLK_28 (cfide), a phase-aligned sibling of clk_114 (wizard.xdc's
  // multicycle paths time the crossing), but the value is static and the
  // synchroniser costs nothing.
  (* ASYNC_REG = "TRUE" *) reg [7:0] s_voff0 = 8'd0;
  (* ASYNC_REG = "TRUE" *) reg [7:0] s_voff1 = 8'd0;
  always @(posedge clk_114) begin
    s_voff0 <= i_voffset;
    s_voff1 <= s_voff0;
  end

  wire [23:0] w_50_next, w_60_next;
  wire        w_50_stb, w_60_stb;
  wire        w_50_lstart, w_60_lstart;
  wire [6:0]  w_50_phase, w_60_phase;
  wire        w_50_lhires, w_60_lhires;
  wire [7:0]  w_crt_r, w_crt_g, w_crt_b;

  (* ASYNC_REG = "TRUE" *) reg [9:0] s_crt_cfg0 = 10'd0;   // crt_post's bits; the beam's: crt_beamh
  (* ASYNC_REG = "TRUE" *) reg [9:0] s_crt_cfg1 = 10'd0;
  (* ASYNC_REG = "TRUE" *) reg [1:0] s_crt_rtg  = 2'b00;
  (* ASYNC_REG = "TRUE" *) reg [2:0] s_crt_hs   = 3'b000;
  reg  [9:0] r_crt_cfg   = 10'd0;  // frame-latched OSD bits
  reg        r_crt_ok    = 1'b0;   // last frame: 15 kHz and no RTG
  reg  [9:0] r_crt_lines = 10'd0;  // input lines in this frame
  wire       w_crt_fend  = r_50hz ? w_50_frame_end : w_60_frame_end;
  always @(posedge clk_148) begin
    s_crt_cfg0 <= i_crt_cfg[9:0];
    s_crt_cfg1 <= s_crt_cfg0;
    s_crt_rtg  <= {s_crt_rtg[0], i_rtg_enable};
    s_crt_hs   <= {s_crt_hs[1:0], w_pal_hsync};
    if (s_crt_hs[2:1] == 2'b01 && r_crt_lines != 10'h3FF)
      r_crt_lines <= r_crt_lines + 1'b1;
    if (w_crt_fend) begin
      r_crt_cfg   <= s_crt_cfg1;
      r_crt_ok    <= (r_crt_lines < 10'd400) && !s_crt_rtg[1];
      r_crt_lines <= 10'd0;
    end
  end

  // the selected upsampler's stream
  wire [23:0] w_m_cur    = r_50hz ? {w_50_b, w_50_g, w_50_r} : {w_60_b, w_60_g, w_60_r};
  wire [23:0] w_m_nxt    = r_50hz ? w_50_next   : w_60_next;
  wire        w_m_stb    = r_50hz ? w_50_stb    : w_60_stb;
  wire        w_m_lstart = r_50hz ? w_50_lstart : w_60_lstart;
  wire [6:0]  w_m_phase  = r_50hz ? w_50_phase  : w_60_phase;
  wire        w_m_lhires = r_50hz ? w_50_lhires : w_60_lhires;

  // controls: static per frame (OSD) and per HD line (resolution, latched
  // by the upsampler at the HD hsync); registered, they change in hblank
  wire [1:0] w_crt_filt = w_m_lhires ? r_crt_cfg[5:4] : r_crt_cfg[3:2];
  wire [1:0] w_crt_scan = (r_crt_cfg[1:0] == 2'd0) ? 2'd0 :
                          (r_crt_cfg[1:0] == 2'd1) ? 2'd2 : 2'd3;
  reg  [1:0] r_ctl_scan  = 2'd0;
  reg        r_ctl_vb    = 1'b0;
  reg  [1:0] r_ctl_hblur = 2'd0;
  reg  [1:0] r_ctl_mask  = 2'd0;
  reg  [1:0] r_ctl_bloom = 2'd0;
  reg        r_ctl_hz60  = 1'b0;
  always @(posedge clk_148) begin
    r_ctl_scan  <= r_crt_ok ? w_crt_scan : 2'd0;
    r_ctl_vb    <= r_crt_ok & w_crt_filt[1];
    r_ctl_hblur <= (r_crt_ok & w_crt_filt[0]) ? (w_m_lhires ? 2'd1 : 2'd2) : 2'd0;
    r_ctl_mask  <= r_crt_ok ? r_crt_cfg[7:6] : 2'd0;
    r_ctl_bloom <= r_crt_ok ? r_crt_cfg[9:8] : 2'd0;
    r_ctl_hz60  <= ~r_50hz;
  end

  wire [23:0] w_crt_rgb;
  crt_post #(
    .HAS_VBLEND(1), .HAS_HBLUR(1), .HAS_MASK(1), .HAS_BLOOM(1), .HAS_LUT(1),
    .WROM_FILE(CRT_WROM_FILE), .LUT_FILE(CRT_LUT_FILE), .BLOOM_FILE(CRT_BLOOM_FILE)
  ) my_crt_post (
    .clk(clk_148),
    .i_stb(w_m_stb),
    .i_line_start(w_m_lstart),
    .i_phase(w_m_phase),
    .i_cur(w_m_cur),
    .i_nxt(w_m_nxt),
    .i_hz60(r_ctl_hz60),
    .i_scan(r_ctl_scan),
    .i_vblend(r_ctl_vb),
    .i_hblur(r_ctl_hblur),
    .i_mask(r_ctl_mask),
    .i_bloom(r_ctl_bloom),
    .i_lut(r_ctl_scan),       // the LUT page that goes with the beam profile
    .i_wwe(1'b0),
    .i_wwa(11'd0),
    .i_wwd(18'd0),
    .o_rgb(w_crt_rgb)
  );
  assign {w_crt_b, w_crt_g, w_crt_r} = w_crt_rgb;

  // Horizontal beam spot on the Amiga stream, before both upsamplers.  Off
  // (OSD Beam width off, 31 kHz, RTG): w_bh_* = the input, bit for bit.
  wire [7:0] w_bh_r, w_bh_g, w_bh_b;
  wire       w_bh_hs, w_bh_vs, w_bh_hires, w_bh_shres;
  crt_beamh #(
    .HAS_BLOOM(1),
    .DEC_FILE(CRT_HDEC_FILE), .ENC_FILE(CRT_HENC_FILE), .K_FILE(CRT_HK_FILE)
  ) my_beamh (
    .clk(clk_114),
    .i_r(w_pal_r), .i_g(w_pal_g), .i_b(w_pal_b),
    .i_hs(w_pal_hsync), .i_vs(w_pal_vsync),
    .i_hires(i_pal_hires), .i_shres(i_pal_shres),
    .i_width(i_crt_cfg[11:10]),
    .i_bloom(i_crt_cfg[9:8]),
    .i_rtg(i_rtg_enable),
    .o_r(w_bh_r), .o_g(w_bh_g), .o_b(w_bh_b),
    .o_hs(w_bh_hs), .o_vs(w_bh_vs),
    .o_hires(w_bh_hires), .o_shres(w_bh_shres)
  );

  // Upscale the video signal using a line buffer
  // 'h80 -> 4cm -> right border
  // 'h00 -> 8cm -> right border
  pal_to_hd_upsample #(
  .PAL_HD_H_RES(1685),
  .PAL_OFFSET_HZ('hd0 - CRT_LAT)
  ) my50hzupsample(
    .clk_in(clk_114),
    .clk_out(clk_148),
    .reset(reset),
    // Pal input
    .i_pal_hsync(w_bh_hs),
    .i_pal_vsync(w_bh_vs),
    .i_pal_r(w_bh_r),
    .i_pal_g(w_bh_g),
    .i_pal_b(w_bh_b),
    // HD upsampled output
    .o_hd_r(w_50_r),
    .o_hd_g(w_50_g),
    .o_hd_b(w_50_b),
    .o_hd_vsync(w_50_vsync),
    //.o_vblank_width(w_50_vblank_width),
    .o_frame_end(w_50_frame_end),
    // HD sync pulse
    .i_hd_hsync(w_50_hd_hsync),
    .i_hd_vsync(w_50_hd_vsync),
    .i_hd_clk(w_50_adv_clk),
    // horizontal and vertical offsets
    .i_hd_hoffset(s_hoff1),
    .i_hd_voffset(s_voff1),
    .i_rtg_enable(),
    // CRT
    .i_pal_hires(w_bh_hires),
    .i_pal_shres(w_bh_shres),
    .o_hd_next(w_50_next),
    .o_pix_stb(w_50_stb),
    .o_line_start(w_50_lstart),
    .o_line_phase(w_50_phase),
    .o_line_hires(w_50_lhires)
  );

  // Generate the 720p Hsync and Vsync signals
  signal_generator #(
  .PAL_HZ_ACT_PIX(1280),
  .PAL_HZ_FRONT_PORCH(440),
  .PAL_HZ_SYNC_WIDTH(40),
  .PAL_HZ_BACK_PORCH(220),
  .PAL_VT_ACT_LN(720),
  .PAL_VT_FRONT_PORCH(5),
  .PAL_VT_SYNC_WIDTH(5),
  .PAL_VT_BACK_PORCH(20)
  ) hd_50hz_gen(
    .clk(clk_148),
    .reset(reset),
    .i_frame_end(w_50_frame_end),
    .i_r(w_crt_r),
    .i_g(w_crt_g),
    .i_b(w_crt_b),
    // Output signals
    .o_x(w_50_x),
    .o_y(w_50_y),
    .o_r(w_50_o_r),
    .o_g(w_50_o_g),
    .o_b(w_50_o_b),
    .o_adv_clk(w_50_adv_clk),
    .o_hsync(w_50_hd_hsync),
    .o_vsync(w_50_hd_vsync),
    .o_adv_de(w_50_adv_de),
    .o_frame()
  );

  // Upscale the video signal using a line buffer
  pal_to_hd_upsample #(
  .PAL_HD_H_RES(1980), // Total pixels in a line
  .PAL_OFFSET_HZ('h80 - CRT_LAT)
  ) my60hzupsample (
    .clk_out(clk_148),
    .clk_in(clk_114),
    .reset(reset),
    // Pal input
    .i_pal_hsync(w_bh_hs),
    .i_pal_vsync(w_bh_vs),
    .i_pal_r(w_bh_r),
    .i_pal_g(w_bh_g),
    .i_pal_b(w_bh_b),
    // RTG
    .i_rtg_enable(i_rtg_enable),
    // HD upsampled output
    .o_hd_r(w_60_r),
    .o_hd_g(w_60_g),
    .o_hd_b(w_60_b),
    .o_hd_vsync(w_60_vsync),
    .o_frame_end(w_60_frame_end),
    // HD sync pulse
    .i_hd_hsync(o_hsync),
    .i_hd_vsync(w_60_hd_vsync),
    .i_hd_clk(w_50_adv_clk),
    // horizontal and vertical offsets
    .i_hd_hoffset(s_hoff1),
    .i_hd_voffset(s_voff1),
    // CRT
    .i_pal_hires(w_bh_hires),
    .i_pal_shres(w_bh_shres),
    .o_hd_next(w_60_next),
    .o_pix_stb(w_60_stb),
    .o_line_start(w_60_lstart),
    .o_line_phase(w_60_phase),
    .o_line_hires(w_60_lhires)
  );

  // Generate the 720p Hsync and Vsync signals
  signal_generator #(
  .PAL_HZ_ACT_PIX(1280),
  .PAL_HZ_FRONT_PORCH(110),
  .PAL_HZ_SYNC_WIDTH(40),
  .PAL_HZ_BACK_PORCH(220),
  .PAL_VT_ACT_LN(720),
  .PAL_VT_FRONT_PORCH(5),
  .PAL_VT_SYNC_WIDTH(5),
  .PAL_VT_BACK_PORCH(20)
  ) hd_60hz_gen (
    .clk(clk_148),
    .reset(reset),
    .i_frame_end(w_60_frame_end),
    .i_r(w_crt_r),
    .i_g(w_crt_g),
    .i_b(w_crt_b),
    // Output signals
    .o_x(w_60_x),
    .o_y(w_60_y),
    .o_r(w_60_o_r),
    .o_g(w_60_o_g),
    .o_b(w_60_o_b),
    .o_adv_clk(w_60_adv_clk),
    .o_hsync(w_60_hd_hsync),
    .o_vsync(w_60_hd_vsync),
    .o_adv_de(w_60_adv_de),
    .o_frame()
  );


  // Switch between 50 and 60 Hz video conversion
  assign w_adv_clk  =
  (r_50hz ? w_50_adv_clk : w_60_adv_clk);
  assign w_hd_vsync =
  (r_50hz ? w_50_hd_vsync : w_60_hd_vsync);
  assign w_hd_hsync =
  (r_50hz ? w_50_hd_hsync : w_60_hd_hsync);
  assign w_vsync   =
  (r_50hz ? w_50_vsync : w_60_vsync);
  assign w_o_r     =
  (r_50hz ? w_50_o_r : w_60_o_r);
  assign w_o_g     =
  (r_50hz ? w_50_o_g : w_60_o_g);
  assign w_o_b     =
  (r_50hz ? w_50_o_b : w_60_o_b);

  // ADV DDR output
  adv_ddr #(
  .PX_TO_DE(280),
  .PX_ACT_DE(1280),
  .PX_TOTAL(1980),

  .PY_TO_DE(5),
  .ACT_720P(720),
  .V_LINES_TOTAL(750)
  ) myadr_ddr (
    // INPUT
    .clk_out(clk_148), // DDR clock at 4xpixel clock
    .clk_in(w_adv_clk), // Pixel clock

    .reset(reset),

    // .de_in(w_adv_de),       // Used to generate DE
    .hsync(w_hd_hsync),
    .vsync(w_vsync),
    .data({w_o_r, w_o_g, w_o_b}), // Pixel data in 24-bpp

    // OUTPUT
    .clk_pixel_out(o_clk_pixel), // Output pixel clock after synchronization to clk_ddr
    .de_out(o_de), // Data enable signal
    .vsync_out(o_vsync),
    .hsync_out(o_hsync),
    .data_out(o_data) // DDR data stream out
  );
endmodule

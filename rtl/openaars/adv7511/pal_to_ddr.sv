`timescale 1ns / 1ps
// pal_to_ddr: the HDMI output chain.  Amiga video (PAL / NTSC, 15 / 31 kHz,
// RTG) to 720p50 / 720p60 for the ADV7511, 12-bit DDR at the pins:
//   crt_beamh -> pal_to_hd_upsample -> crt_post -> signal_generator -> adv_ddr,
// with frame_freq choosing the 50 / 60 Hz raster from the input frame period.
// Clock domains:
//   clk_114  the Amiga stream: input delay, crt_beamh, the upsampler's write
//            side and its VPOS decision
//   CLK_28   Denise's HIRES / SHRES and the OSD / RTG bits (phase-aligned
//            with clk_114; the static bits get 2-FF synchronisers anyway)
//   clk_148  720p: frame_freq, upsampler read side, crt_post, generator, adv_ddr
// Design notes: findings/scaler/plan.md (one chain, exact-ratio scaling),
// findings/adv7511/.  Benches: sim/hdmi_upsample (crt_build.sh, golden.sh,
// crt_run.sh, scaler_run.sh, run.sh).
module pal_to_ddr #(
  // crt_post tables (design sources next to this file)
  parameter CRT_WROM_FILE  = "crt_wrom.mem",
  parameter CRT_LUT_FILE   = "crt_lut.mem",
  parameter CRT_BLOOM_FILE = "crt_bloom.mem",
  // crt_beamh's horizontal beam spot tables
  parameter CRT_HDEC_FILE  = "crt_hdec.mem",
  parameter CRT_HENC_FILE  = "crt_henc.mem",
  parameter CRT_HK_FILE    = "crt_hk.mem",
  // crt_post's linear-light tables (sim/hdmi_upsample/scl_mkroms.py)
  parameter CRT_SDEC_FILE  = "crt_sdec.mem",
  parameter CRT_SENC_FILE  = "crt_senc.mem",
  parameter CRT_SWROM_FILE = "crt_swrom.mem"
) (
  // clk_114: the Amiga video stream
  input  logic        clk_114,
  input  logic        vga_clk_pixel,  // RTG pixel strobe (VGA_PIXEL): the RTG 1:1 write
  input  logic        i_pal_hsync,
  input  logic        i_pal_vsync,
  input  logic [7:0]  i_pal_r,
  input  logic [7:0]  i_pal_g,
  input  logic [7:0]  i_pal_b,
  // CLK_28 / static: Denise's resolution per line, OSD settings, RTG
  input  logic        i_pal_hires,    // BPLCON0 HIRES
  input  logic        i_pal_shres,    // BPLCON0 SHRES
  input  logic [7:0]  i_hoffset,      // OSD Video Pos HPOS: signed HD pixels
  input  logic [7:0]  i_voffset,      // OSD Video Pos VPOS: signed 64 us steps, positive down
  input  logic [7:0]  i_hoffset_rtg,  // the same pair for the RTG picture (RTG 1:1 applies
  input  logic [7:0]  i_voffset_rtg,  //   these instead; 0: centred), same encodings
  input  logic        i_rtg_enable,
  input  logic [13:0] i_crt_cfg,      // OSD Video page, as osd_cfg_t below
  // clk_148: 720p to the ADV7511 (adv_ddr's pad registers); reset: system reset
  input  logic        clk_148,
  input  logic        reset,
  output logic        o_clk_pixel,
  output logic        o_de,
  output logic        o_vsync,
  output logic        o_hsync,
  output logic [11:0] o_data
);
  // The OSD Video page as userio_osd latches it, msb first (bit 13 down)
  typedef struct packed {
    logic [1:0] scaling;  // 0 line rate, 1 sharp, 2 area (3 as 1)
    logic [1:0] beam;     // beam width off / sharp / medium / soft
    logic [1:0] bloom;    // off / low / high
    logic [1:0] mask;     // off / grille / grille strong / shadow
    logic [1:0] hr_filt;  // Hires Filter {V, H}
    logic [1:0] lr_filt;  // Lores Filter {V, H}
    logic [1:0] scan;     // scanlines off / dim / black
  } osd_cfg_t;
  // Its clk_148 part (the beam goes to crt_beamh in clk_114), 12 bits
  typedef struct packed {
    logic [1:0] scaling;
    logic [1:0] bloom;
    logic [1:0] mask;
    logic [1:0] hr_filt;
    logic [1:0] lr_filt;
    logic [1:0] scan;
  } crt_cfg_t;

  osd_cfg_t w_osd_cfg;
  assign w_osd_cfg = i_crt_cfg;

  // The input in its own clock: hsync / vsync two clk_114 later, RGB as it
  // comes.  A delay, not a CDC; its depth sets the input-side edge latency,
  // which decides the ring buffer each HD line shows.
  logic [1:0] r_pal_hs_dly;
  logic [1:0] r_pal_vs_dly;
  always_ff @(posedge clk_114) begin
    r_pal_hs_dly <= {r_pal_hs_dly[0], i_pal_hsync};
    r_pal_vs_dly <= {r_pal_vs_dly[0], i_pal_vsync};
  end
  logic       w_pal_hsync, w_pal_vsync;
  logic [7:0] w_pal_r, w_pal_g, w_pal_b;
  assign w_pal_hsync = r_pal_hs_dly[1];
  assign w_pal_vsync = r_pal_vs_dly[1];
  assign w_pal_r     = i_pal_r;
  assign w_pal_g     = i_pal_g;
  assign w_pal_b     = i_pal_b;

  // 50 / 60 Hz raster from the input frame period (12.5 .. 19.5 ms: 60 Hz).
  // r_50hz is what tb_crt_frame.v reads (its +force60 forces myfreq.r_hz60).
  logic w_freq_hz60, r_50hz, w_hz60;
  assign r_50hz = ~w_freq_hz60;
  assign w_hz60 = ~r_50hz;
  frame_freq myfreq (
    .clk(clk_148),
    .reset(reset),
    .i_vsync(w_pal_vsync),
    .o_hz60(w_freq_hz60)
  );

  // CRT emulation, OSD Video page -> hardware (frame-latched; applied only
  // while the last input frame had < 400 lines and RTG is off):
  //   Scanlines    off / dim / black -> crt_post beam profile and LUT page 0 / 2 / 3
  //   Lores/Hires Filter, by the line's resolution: H blur / V two-line beam
  //   CRT mask     off / grille / grille strong / shadow -> crt_post i_mask
  //   Bloom        off / low / high -> crt_post i_bloom (+ crt_beamh's, beam on)
  //   Beam width   off / sharp / medium / soft -> crt_beamh (clk_114, before the upsampler)
  //   Scaling      line rate / sharp / area -> exact 2.5x / 3x (ring16, crt_post i_lin)
  // crt_post delays the stream CRT_LAT pixels and the upsampler reads CRT_LAT
  // earlier: everything off is the picture without it (crt_run.sh bypass legs).
  localparam CRT_LAT = 9;   // crt_post pipeline, HD pixels
  localparam LIN_LAT = 3;   // ... its linear-light path's extra (the exact-ratio modes)

  // Static settings into their clock, 2-FF synchronisers (wizard.xdc bounds
  // the crossings with set_max_delay -datapath_only): HPOS into clk_148;
  // VPOS into clk_114, where the upsampler decides at each input hsync where
  // the HD raster restarts (pal_to_hd_upsample.sv, "Video Pos VPOS").
  (* ASYNC_REG = "TRUE" *) logic [7:0] s_hoff0 = 8'd0;
  (* ASYNC_REG = "TRUE" *) logic [7:0] s_hoff1 = 8'd0;
  (* ASYNC_REG = "TRUE" *) logic [7:0] s_hoffr0 = 8'd0;
  (* ASYNC_REG = "TRUE" *) logic [7:0] s_hoffr1 = 8'd0;
  always_ff @(posedge clk_148) begin
    s_hoff0  <= i_hoffset;
    s_hoff1  <= s_hoff0;
    s_hoffr0 <= i_hoffset_rtg;
    s_hoffr1 <= s_hoffr0;
  end
  (* ASYNC_REG = "TRUE" *) logic [7:0] s_voff0 = 8'd0;
  (* ASYNC_REG = "TRUE" *) logic [7:0] s_voff1 = 8'd0;
  (* ASYNC_REG = "TRUE" *) logic [7:0] s_voffr0 = 8'd0;
  (* ASYNC_REG = "TRUE" *) logic [7:0] s_voffr1 = 8'd0;
  always_ff @(posedge clk_114) begin
    s_voff0  <= i_voffset;
    s_voff1  <= s_voff0;
    s_voffr0 <= i_voffset_rtg;
    s_voffr1 <= s_voffr0;
  end
  // RTG into clk_114: the upsampler's write side takes one word per RTG
  // pixel (vga_clk_pixel) while it is on
  (* ASYNC_REG = "TRUE" *) logic [1:0] s_rtg_114 = 2'b00;
  always_ff @(posedge clk_114)
    s_rtg_114 <= {s_rtg_114[0], i_rtg_enable};

  // the upsampler's stream and line / frame marks (clk_148)
  logic [7:0]  w_up_r, w_up_g, w_up_b;
  logic [23:0] w_m_nxt;
  logic        w_m_stb;
  logic        w_m_lstart;
  logic [6:0]  w_m_phase;
  logic        w_m_lhires;
  logic [7:0]  w_m_vphase;
  logic        w_vsync;
  logic        w_frame_end;
  logic [7:0]  w_crt_r, w_crt_g, w_crt_b;

  // OSD bits and RTG into clk_148, latched at the frame end (a change applies
  // from the next frame); r_crt_ok: the last frame had < 400 input lines and
  // RTG off, the condition of the CRT effects and the exact-ratio scaling.
  (* ASYNC_REG = "TRUE" *) crt_cfg_t   s_crt_cfg0 = '0;
  (* ASYNC_REG = "TRUE" *) crt_cfg_t   s_crt_cfg1 = '0;
  (* ASYNC_REG = "TRUE" *) logic [1:0] s_crt_rtg  = 2'b00;
  (* ASYNC_REG = "TRUE" *) logic [2:0] s_crt_hs   = 3'b000;
  crt_cfg_t   r_crt_cfg   = '0;     // frame-latched OSD bits
  logic       r_crt_ok    = 1'b0;   // last frame: 15 kHz and no RTG
  logic [9:0] r_crt_lines = 10'd0;  // input lines in this frame
  logic       w_crt_fend;
  assign w_crt_fend = w_frame_end;
  always_ff @(posedge clk_148) begin
    s_crt_cfg0 <= {w_osd_cfg.scaling, w_osd_cfg.bloom, w_osd_cfg.mask,   // crt_cfg_t order
                   w_osd_cfg.hr_filt, w_osd_cfg.lr_filt, w_osd_cfg.scan};
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

  // the upsampler's stream
  logic [23:0] w_m_cur;
  assign w_m_cur = {w_up_b, w_up_g, w_up_r};

  // Exact-ratio scaling (findings/scaler/plan.md steps 4, 5) under r_crt_ok:
  // the upsampler's 16-line ring and exact 2.5x / 3x steps, crt_post's
  // linear-light two-line blend; otherwise the line-rate picture.
  logic r_ratio = 1'b0;
  always_ff @(posedge clk_148)
    r_ratio <= r_crt_ok && (r_crt_cfg.scaling != 2'd0);

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
  reg  [1:0] r_ctl_kern  = 2'd0;   // the exact-ratio modes' kernel: sharp, area, beam dim, beam black
  always @(posedge clk_148) begin
    r_ctl_scan  <= r_crt_ok ? w_crt_scan : 2'd0;
    r_ctl_kern  <= (w_crt_scan == 2'd0) ? {1'b0, r_crt_cfg[11:10] == 2'd2} :
                   (w_crt_scan == 2'd3) ? 2'd3 : 2'd2;
    r_ctl_vb    <= r_crt_ok & !r_ratio & w_crt_filt[1];
    r_ctl_hblur <= (r_crt_ok & w_crt_filt[0]) ? (w_m_lhires ? 2'd1 : 2'd2) : 2'd0;
    r_ctl_mask  <= r_crt_ok ? r_crt_cfg[7:6] : 2'd0;
    r_ctl_bloom <= r_crt_ok ? r_crt_cfg[9:8] : 2'd0;
    r_ctl_hz60  <= ~r_50hz;
  end

  wire [23:0] w_crt_rgb;
  crt_post #(
    .HAS_VBLEND(1), .HAS_HBLUR(1), .HAS_MASK(1), .HAS_BLOOM(1), .HAS_LUT(1),
    .WROM_FILE(CRT_WROM_FILE), .LUT_FILE(CRT_LUT_FILE), .BLOOM_FILE(CRT_BLOOM_FILE),
    .HAS_LIN(1), .SDEC_FILE(CRT_SDEC_FILE), .SENC_FILE(CRT_SENC_FILE), .SWROM_FILE(CRT_SWROM_FILE)
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
    .i_lin(r_ratio),
    .i_kern(r_ctl_kern),
    .i_vphase(w_m_vphase),    // static per HD line, like w_m_phase
    .i_wwe(1'b0),
    .i_wwa(11'd0),
    .i_wwd(18'd0),
    .o_rgb(w_crt_rgb)
  );
  assign {w_crt_b, w_crt_g, w_crt_r} = w_crt_rgb;

  // Horizontal beam spot on the Amiga stream (off, 31 kHz, RTG: w_bh_* = the input)
  logic [7:0] w_bh_r, w_bh_g, w_bh_b;
  logic       w_bh_hs, w_bh_vs, w_bh_hires, w_bh_shres;
  crt_beamh #(
    .HAS_BLOOM(1),
    .DEC_FILE(CRT_HDEC_FILE), .ENC_FILE(CRT_HENC_FILE), .K_FILE(CRT_HK_FILE)
  ) my_beamh (
    .clk(clk_114),
    .i_r(w_pal_r), .i_g(w_pal_g), .i_b(w_pal_b),
    .i_hs(w_pal_hsync), .i_vs(w_pal_vsync),
    .i_hires(i_pal_hires), .i_shres(i_pal_shres),
    .i_width(w_osd_cfg.beam),
    .i_bloom(w_osd_cfg.bloom),
    .i_rtg(i_rtg_enable),
    .o_r(w_bh_r), .o_g(w_bh_g), .o_b(w_bh_b),
    .o_hs(w_bh_hs), .o_vs(w_bh_vs),
    .o_hires(w_bh_hires), .o_shres(w_bh_shres)
  );

  // HD hsync the upsampler samples: 50 Hz the generator's, 60 Hz adv_ddr's hsync_out
  logic w_hd_gen_hsync, w_hd_vsync, w_adv_clk, w_adv_hsync;
  // line-buffer ring: 8 at line rate, 16 in the exact-ratio modes (tb +ring16 forces 16)
  logic r_ring16 = 1'b0;
  // Line buffer upsampler, clk_114 in, clk_148 out (offsets: 'hd0 50 Hz, 'h80 60 Hz,
  // less DE_X: the pin DE is the generator's window since 2026-10-27, DE_X pixels
  // left of the old regenerated one, and the picture stays where it was on screen)
  localparam DE_X = 60;
  // RTG 1:1 (pal_to_hd_upsample.sv "RTG 1:1"; calibrated by scaler_run.sh's
  // rtg* legs): the read offset that puts an RTG line's first pixel at HD
  // x 0 of the window, per path, and the restart's move (input lines) that
  // puts line 0 of a 750-line mode with its vsync 5 lines after the
  // picture on HD row 0
  localparam RTG_BASE50 = 157;
  localparam RTG_BASE60 = 155;
  localparam signed [7:0] RTG_VB = -8'sd9;
  pal_to_hd_upsample #(
    .PAL_HD_H_RES(1685),
    .PAL_HD_H_RES60(1980),
    .PAL_OFFSET_HZ('hd0 - CRT_LAT - DE_X),
    .PAL_OFFSET_HZ60('h80 - CRT_LAT - DE_X),
    .RATIO_RDX(LIN_LAT),
    .RTG_1TO1(1),
    .RTG_BASE50(RTG_BASE50),
    .RTG_BASE60(RTG_BASE60),
    .RTG_VB50(RTG_VB),
    .RTG_VB60(RTG_VB)
  ) myupsample (
    .clk_in(clk_114),
    .clk_out(clk_148),
    .reset(reset),
    .i_pal_hsync(w_bh_hs),
    .i_pal_vsync(w_bh_vs),
    .i_pal_r(w_bh_r),
    .i_pal_g(w_bh_g),
    .i_pal_b(w_bh_b),
    .i_pix_stb(vga_clk_pixel),
    .i_rtg_1to1(s_rtg_114[1]),
    .i_hz60(w_hz60),
    .i_ring16(r_ring16 | r_ratio),
    .i_ratio(r_ratio),
    .o_hd_r(w_up_r),
    .o_hd_g(w_up_g),
    .o_hd_b(w_up_b),
    .o_hd_vsync(w_vsync),
    .o_frame_end(w_frame_end),
    .i_hd_hsync(r_50hz ? w_hd_gen_hsync : w_adv_hsync),
    .i_hd_vsync(w_hd_vsync),
    .i_hd_clk(w_adv_clk),
    .i_hd_hoffset(s_hoff1),
    .i_hd_voffset(s_voff1),
    .i_hd_hoffset_rtg(s_hoffr1),
    .i_hd_voffset_rtg(s_voffr1),
    .i_pal_hires(w_bh_hires),
    .i_pal_shres(w_bh_shres),
    .o_hd_next(w_m_nxt),
    .o_pix_stb(w_m_stb),
    .o_line_start(w_m_lstart),
    .o_line_phase(w_m_phase),
    .o_line_hires(w_m_lhires),
    .o_vphase(w_m_vphase)
  );

  // the generator's active window: the pin DE (adv_ddr); tb_crt_frame.v's DE probe (n_dee)
  logic       w_adv_de;
  logic [7:0] w_o_r, w_o_g, w_o_b;
  // 720p50 / 720p60 raster (front porch by w_hz60), restarted at the upsampler's frame end.
  // Vertically: 15 blank lines, the 720 active ones (the rows the display showed when
  // adv_ddr made its own DE), vsync right after them, the back porch: 750 lines.  No
  // front porch: VPOS can end a frame after 307 input lines (737 HD lines at 50 Hz),
  // and every frame needs its vsync.
  /* verilator lint_off PINCONNECTEMPTY */
  signal_generator #(
    .PAL_HZ_ACT_PIX(1280),
    .PAL_HZ_FRONT_PORCH(440),
    .PAL_HZ_FRONT_PORCH60(110),
    .PAL_HZ_SYNC_WIDTH(40),
    .PAL_HZ_BACK_PORCH(220),
    .PAL_VT_TOP(15),
    .PAL_VT_ACT_LN(720),
    .PAL_VT_FRONT_PORCH(0),
    .PAL_VT_SYNC_WIDTH(5),
    .PAL_VT_BACK_PORCH(25)
  ) hd_gen (
    .clk(clk_148),
    .reset(reset),
    .i_hz60(w_hz60),
    .i_frame_end(w_frame_end),
    .i_r(w_crt_r),
    .i_g(w_crt_g),
    .i_b(w_crt_b),
    .o_x(),
    .o_y(),
    .o_r(w_o_r),
    .o_g(w_o_g),
    .o_b(w_o_b),
    .o_adv_clk(w_adv_clk),
    .o_hsync(w_hd_gen_hsync),
    .o_vsync(w_hd_vsync),
    .o_adv_de(w_adv_de),
    .o_frame()
  );

  // 12-bit DDR to the ADV7511; DE the generator's window, the pins from IOB pad registers
  adv_ddr myadr_ddr (
    .clk_out(clk_148),
    .clk_in(w_adv_clk),
    .reset(reset),
    .hsync(w_hd_gen_hsync),
    .vsync(w_vsync),
    .de_in(w_adv_de),
    .data({w_o_r, w_o_g, w_o_b}),
    .clk_pixel_out(),
    .de_out(),
    .vsync_out(),
    .hsync_out(w_adv_hsync),
    .data_out(),
    .pad_clk(o_clk_pixel),
    .pad_de(o_de),
    .pad_vsync(o_vsync),
    .pad_hsync(o_hsync),
    .pad_data(o_data)
  );
  /* verilator lint_on PINCONNECTEMPTY */
endmodule

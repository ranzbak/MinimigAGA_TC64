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
module pal_to_ddr(
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

  // Upscale the video signal using a line buffer
  pal_to_hd_upsample #(
  .PAL_HD_H_RES(1980)
  ) my50hzupsample(
    .clk_in(clk_114),
    .clk_out(clk_148),
    .reset(reset),
    // Pal input
    .i_pal_hsync(w_pal_hsync),
    .i_pal_vsync(w_pal_vsync),
    .i_pal_r(w_pal_r),
    .i_pal_g(w_pal_g),
    .i_pal_b(w_pal_b),
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
    .i_hd_hoffset(i_voffset),
    .i_hd_voffset(i_voffset),
    .i_rtg_enable()
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
    .i_r(w_50_r),
    .i_g(w_50_g),
    .i_b(w_50_b),
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
  .PAL_HD_H_RES(1980) // Total pixels in a line
  ) my60hzupsample (
    .clk_out(clk_148),
    .clk_in(clk_114),
    .reset(reset),
    // Pal input
    .i_pal_hsync(w_pal_hsync),
    .i_pal_vsync(w_pal_vsync),
    .i_pal_r(w_pal_r),
    .i_pal_g(w_pal_g),
    .i_pal_b(w_pal_b),
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
    .i_hd_hoffset(i_hoffset),
    .i_hd_voffset(i_voffset[0])
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
    .i_r(w_60_r),
    .i_g(w_60_g),
    .i_b(w_60_b),
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

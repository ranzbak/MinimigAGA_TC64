`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 05/13/2020 09:08:37 PM
// Design Name:
// Module Name: pal_to_hd_upsample
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

// Video formats to upscale
// NTSC 752*525*60Hz = 23688000 Hz
// PAL  752*625*50Hz = 23500000 Hz

module pal_to_hd_upsample #(
  parameter PAL_OFFSET_HZ = 'h80,
  parameter PAL_OFFSET_VT = 0,
  parameter PAL_HD_H_RES  = 1980,
  parameter PAL_HD_H_FP   = 50
)(
  input           clk_out,
  input           clk_in,
  input           reset,
  // Pal input
  input           i_pal_hsync,
  input           i_pal_vsync,
  input  [7:0]    i_pal_r,
  input  [7:0]    i_pal_g,
  input  [7:0]    i_pal_b,
  // RTG
  input           i_rtg_enable,
  // HD upsampled output
  output [7:0]    o_hd_r,
  output [7:0]    o_hd_g,
  output [7:0]    o_hd_b,
  output          o_hd_vsync,
  //output [6:0]    o_vblank_width,
  output          o_frame_end,
  // HD sync pulse
  input           i_hd_hsync,
  input           i_hd_vsync,
  input           i_hd_clk,
  // Horizontal and Vertical offsets
  input [7:0]     i_hd_hoffset,
  input [7:0]     i_hd_voffset
);

// PAL TV signal
// |sync|back porch| active |
// Horizontal sync = 4us , Back Porch 8us, 64us total, 52us active
// |sync0|Frame|sync1
// 5 sync lines, 304 lines active, 3 sync lines

// Output registers
reg [7:0]   r_hd_r;
reg [7:0]   r_hd_g;
reg [7:0]   r_hd_b;

reg   [2:0] r_cur_read_buf  = 3'b000; // Number of the current read buffer
reg   [2:0] r_cur_write_buf = 3'b100; // Number of the current write buffer
reg         r_next_buf      = 1'b0; // signal when to swap buffer

(* ASYNC_REG = "TRUE" *) reg   [1:0] s_hd_hsync;
(* ASYNC_REG = "TRUE" *) reg   [1:0] s_hd_vsync;
reg         r_frame_end;


// Buffer to hold 2 lines of data
reg         r_wea;
reg         r_ena;
reg  [13:0] r_addra = 0;
reg  [23:0] r_dina;
reg  [13:0] r_addrb = 0;
wire [23:0] w_doutb;

// Detect edges in Vsync and Hsync
reg r_pal_hpos;
reg r_pal_hneg;
reg r_pal_vpos;
reg r_pal_vneg;

// Sync to 148Mhz clock
(* ASYNC_REG = "TRUE" *) reg   [2:0] s_pal_hsync;
(* ASYNC_REG = "TRUE" *) reg   [2:0] s_pal_vsync;
wire [2:0] s_pal_hsync_next = {s_pal_hsync[1], s_pal_hsync[0], i_pal_hsync};
wire [2:0] s_pal_vsync_next = {s_pal_vsync[1], s_pal_vsync[0], i_pal_vsync};
always @(posedge clk_out) begin
  // Sync registers
  s_pal_hsync <= s_pal_hsync_next;
  s_pal_vsync <= s_pal_vsync_next;
end

// Detect edges in Vsync and Hsync
always @(posedge clk_out)
begin
  // Reset registers
  r_pal_hpos <= 1'b0;
  r_pal_hneg <= 1'b0;
  r_pal_vpos <= 1'b0;
  r_pal_vneg <= 1'b0;

  // Hsync
  if (s_pal_hsync[2:1] == 2'b01)
  begin
    r_pal_hpos<= 1'b1;
  end
  if (s_pal_hsync[2:1] == 2'b10)
  begin
    r_pal_hneg <= 1'b1;
  end

  // Vsync
  if (s_pal_vsync[2:1] == 2'b01)
  begin
    r_pal_vpos <= 1'b1;
  end
  if (s_pal_vsync[2:1] == 2'b10)
  begin
    r_pal_vneg <= 1'b1;
  end
end

// Line buffer
bram_tdp #(
  .DATA(24),
  .ADDR(14)
) upsample_blk_ram (
  .a_clk(clk_in), // input wire clka
  .a_wr(r_wea), // input wire [0 : 0] wea
  .a_addr(r_addra), // input wire [11 : 0] addra
  .a_din(r_dina), // input wire [23 : 0] dina
  .a_dout(),
  .b_clk(clk_out), // input wire clkb
  .b_addr(r_addrb), // input wire [11 : 0] addrb
  .b_din(),
  .b_dout(w_doutb), // output wire [23 : 0] doutb
  .b_wr()
);


// Calculate the sample interval on the input stream
// To sample the same amount of pixels as wanted on the output stream
// results in v_div_var >> 2
reg         r_line_active = 1'b0;
reg         r_act_active = 1'b0;
reg [13:0]  r_line_count = 14'b0;
reg         r_long_frame = 1'b0;
reg [10:0]  r_v_count = 0;
reg [10:0]  r_v_count_prev = 0;
reg [5:0]   r_pix_clock_dev = 6'd0;
reg [13:0]  r_pal_h_pos = 14'b0;
reg [11:0]  v_div_var = 12'b0;
reg         r_pal_hpos_in = 1'b0;
reg         r_pal_hneg_in = 1'b0;
always @(posedge clk_in)
begin
  // start of the horizontal line
  if (r_pal_hneg_in)
  begin
    // Data should be captured
    r_line_active <= 1'b1;
  end

  // end of the horizontal line
  // if (r_pal_hsync_ == 1'b0 && i_pal_hsync == 1'b1) begin
  if (r_pal_hpos_in)
  begin
    r_line_active   <= 1'b0; // Stop counter
    r_line_count    <= 0; // Reset counter
    r_v_count       <= r_v_count + 1;
    v_div_var        = (r_line_count[13:6] / (PAL_HD_H_RES>>8)) - 1; // Shift numbers to make devider circuit faster
    r_pix_clock_dev <= v_div_var[5:0]; // Get the pixel clock relative to the system clock
  end

  // when active inclease counter
  if (r_line_active == 1'b1)
  begin
    r_line_count <= r_line_count + 1;
    // active part of the horiz0ntal line
    if (r_line_count > 300)
    begin
      r_pal_h_pos <= r_pal_h_pos + 1;
      r_act_active <= 1'b1;
    end
  end
  else
  begin
    r_line_count <= 0;
    r_act_active <= 0;
  end
end

// Generate Frame end signal, to reset read loop
always @(posedge clk_out)
begin
  r_frame_end <= 1'b0;
  if (r_pal_vneg)
  begin
    r_frame_end <= 1'b1;
  end
  // Provide end of sync signal
end

// Generate sample enable
reg [5:0]   r_pix_clock_count = 6'b0;
reg         r_pix_en = 1'b0;
always @(posedge clk_in)
begin
  if (reset)
  begin
    r_pix_clock_count <= 1'b0;
  end
  else if (r_line_active)
  begin
    r_pix_clock_count <= r_pix_clock_count + 3'b100;

    r_pix_en <= 1'b0;
    if (r_pix_clock_count >= r_pix_clock_dev)
    begin
      r_pix_clock_count <= r_pix_clock_count - r_pix_clock_dev;
      r_pix_en <= 1'b1;
    end
  end
  else
  begin
    r_pix_clock_count <= 0;
  end
end

// Write input to buffer
reg [3:0] s_next_buf = 0;
reg [1:0] s_pal_hsync_in = 0;
reg       r_pal_vneg_in = 1'b0;
reg [1:0] s_pal_vsync_in = 0;
always @(posedge clk_in)
begin

  // write the pixel
  r_wea <= 1'b0;
  r_ena <= 1'b1;

  // Detect negative edge on horizontal sync
  s_pal_hsync_in <= {s_pal_hsync_in[0], i_pal_hsync};
  r_pal_hneg_in <= 1'b0;
  if (s_pal_hsync_in[1:0] == 2'b10)
  begin
    r_pal_hneg_in <= 1'b1;
  end
  r_pal_hpos_in <= 1'b0;
  if (s_pal_hsync_in[1:0] == 2'b01)
  begin
    r_pal_hpos_in <= 1'b1;
  end
  // vsync
  s_pal_vsync_in <= {s_pal_vsync_in[0], i_pal_vsync};
  r_pal_vneg_in <= 1'b0;
  if (s_pal_vsync_in[1:0] == 2'b10)
  begin
    r_pal_vneg_in <= 1'b1;
  end

  // Write to dual port ram
  if (r_pix_en && ~i_pal_hsync)
  begin
    r_addra <= r_addra+1;
    r_wea <= 1'b1;
    r_dina <= {i_pal_b, i_pal_g, i_pal_r};
  end

  // End of input line
  if (r_pal_hneg_in && ~i_pal_vsync)
  begin
    // Invert signal to signal next buf
    s_next_buf[0] <= ~s_next_buf[0]; // Switch buffer

    // Switch to next write buffer
    if (r_cur_write_buf != 3'b111)
    begin
      r_cur_write_buf <= (r_cur_write_buf + 1);
    end
    else
    begin
      r_cur_write_buf <= 0;
    end

    // Switch the current write buffer
    case (r_cur_write_buf)
      0:
        r_addra <= 14'h0000;
      1:
        r_addra <= 14'h0800;
      2:
        r_addra <= 14'h1000;
      3:
        r_addra <= 14'h1800;
      4:
        r_addra <= 14'H2000;
      5:
        r_addra <= 14'H2800;
      6:
        r_addra <= 14'H3000;
      7:
        r_addra <= 14'H3800;
      default:
        r_addra <= 14'h0000;
    endcase
  end

  // Handle Vsync negative edge
  if (r_pal_vneg_in)
  begin
    r_cur_write_buf <= 4;
  end
end

// edge trigger hd_hsync
reg hd_hsync_posedge;
reg hd_hsync_negedge;
always @(posedge clk_out) begin
  s_hd_hsync <= {s_hd_hsync[0], i_hd_hsync};
  hd_hsync_negedge <= 1'b0;
  if (s_hd_hsync[1:0] == 2'b10) hd_hsync_negedge <= 1'b1;
  hd_hsync_posedge <= 1'b0;
  if (s_hd_hsync[1:0] == 2'b01) hd_hsync_posedge <= 1'b1;
end

// Sample PAL input stream
reg         r_hd_clk_;
reg [11:0]  r_h_pos = 12'b0;
always @(posedge clk_out)
begin
  // Receive next buffer signal
  s_next_buf[3:1] <= {s_next_buf[2], s_next_buf[1], s_next_buf[0]};
  if (s_next_buf[3] != s_next_buf[2])
  begin
    r_next_buf <= 1'b1;
  end

  // Read from buffer
  r_hd_clk_ <= i_hd_clk;
  if (r_hd_clk_ == 1'b1 && i_hd_clk == 1'b0 && ~i_hd_hsync)
  begin
    r_h_pos <= r_h_pos + 1;
    if (r_h_pos > PAL_HD_H_FP && r_h_pos < (PAL_HD_H_RES-PAL_HD_H_FP))
    begin
      r_addrb <= r_addrb + 1;
      r_hd_r <= w_doutb[0 +: 8];
      r_hd_g <= w_doutb[8 +: 8];
      r_hd_b <= w_doutb[16 +: 8];
    end
    else
    begin
      r_hd_r <= 8'b0;
      r_hd_g <= 8'b0;
      r_hd_b <= 8'b0;
    end
  end

  // Handle next line
  // if (s_hd_hsync[1:0] == 2'b01)
  if (hd_hsync_negedge)
  begin
    if (r_next_buf)
    begin
      r_next_buf <= 1'b0;

      if (r_cur_read_buf != 3'b111)
      begin
        r_cur_read_buf <= r_cur_read_buf + 1;
      end
      else
      begin
        r_cur_read_buf <= 0;
      end
    end
    r_h_pos <= 0; // Reset horizontal counter
    case (r_cur_read_buf)
      0:
        r_addrb <= 14'h0000 - (PAL_OFFSET_HZ + i_hd_hoffset);
      1:
        r_addrb <= 14'h0800 - (PAL_OFFSET_HZ + i_hd_hoffset);
      2:
        r_addrb <= 14'h1000 - (PAL_OFFSET_HZ + i_hd_hoffset);
      3:
        r_addrb <= 14'h1800 - (PAL_OFFSET_HZ + i_hd_hoffset);
      4:
        r_addrb <= 14'h2000 - (PAL_OFFSET_HZ + i_hd_hoffset);
      5:
        r_addrb <= 14'h2800 - (PAL_OFFSET_HZ + i_hd_hoffset);
      6:
        r_addrb <= 14'h3000 - (PAL_OFFSET_HZ + i_hd_hoffset);
      7:
        r_addrb <= 14'h3800 - (PAL_OFFSET_HZ + i_hd_hoffset);
    endcase
  end


  // posedge vsync
  if (r_pal_vpos)
  begin
    if(r_v_count > r_v_count_prev)
    begin
      r_long_frame <= 1'b0;
    end
  end

  // Neg edge vsync
  if (r_pal_vneg)
  begin
    r_v_count_prev <= r_v_count;
    r_v_count <= 0;
    r_long_frame <= 1'b0;
    // Reset the read and write buffer to start
    // When the current frame is long the next frame needs to
    // be moved down one line to overlap the interlaced video
    if(r_long_frame)
    begin
      r_cur_read_buf  <= 0;
      // r_cur_write_buf <= 4;
    end
    else
    begin
      r_cur_read_buf  <= 0;
      // r_cur_write_buf <= 6;
    end
  end
end


// Translate the vsync and de signals down or up
localparam Y_TRANS=10;
reg   [$clog2(Y_TRANS):0] pos_y_cnt = 0;
reg                       pos_y_en = 1'b0;
reg   [$clog2(Y_TRANS):0] neg_y_cnt = 0;
reg                       neg_y_en = 1'b0;
reg                       r_del_vsync = 1'b0;
always @(posedge clk_out)
begin
  s_hd_vsync <= {s_hd_vsync[0], i_hd_vsync};

  // Pos edge V
  if (s_hd_vsync == 2'b01)
  begin
    pos_y_en <= 1'b1;
  end

  // Pos edge h
  // if (s_hd_hsync == 2'b01 && pos_y_en == 1'b1)
  if (hd_hsync_posedge && pos_y_en == 1'b1)
  begin
    pos_y_cnt <= pos_y_cnt + 1;
  end

  // Switch on delayed vsync
  if (pos_y_cnt == Y_TRANS)
  begin
    pos_y_cnt <= 0;
    pos_y_en <= 1'b0;
    r_del_vsync <= 1'b1;
  end

  // Neg edge V
  if (s_hd_vsync == 2'b10)
  begin
    neg_y_en <= 1'b1;
  end

  // Pos edge h
  // if (s_hd_hsync == 2'b10 && neg_y_en == 1'b1)
  if (hd_hsync_negedge && neg_y_en == 1'b1)
  begin
    neg_y_cnt <= neg_y_cnt + 1;
  end

  // Switch off delayed vsync
  if (neg_y_cnt== Y_TRANS)
  begin
    neg_y_cnt <= 0;
    neg_y_en <= 1'b0;
    r_del_vsync <= 1'b0;
  end
end

// output assignments
assign o_hd_r = r_hd_r;
assign o_hd_g = r_hd_g;
assign o_hd_b = r_hd_b;
assign o_frame_end = r_frame_end;
//assign o_vblank_width = r_vblank_width;

// assign o_hd_vsync = i_hd_vsync;
assign o_hd_vsync = i_rtg_enable ? s_hd_vsync[1] : r_del_vsync;
endmodule

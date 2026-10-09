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
  parameter PAL_HD_H_FP   = 50,
  // CRT emulation (2026-10-09, crt_post.v): 1 adds the next-line read for the
  // two-line beam on port B (in the clk_out cycle the picture path leaves
  // idle), the line phase and the per-line resolution.  The picture on
  // o_hd_r/g/b is the same either way.
  parameter CRT           = 1
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
  input [7:0]     i_hd_voffset,
  // CRT emulation.  Resolution of the input picture (Denise BPLCON0 HIRES and
  // SHRES, CLK_28 = dll_28, a phase-aligned sibling of clk_in: timed, no
  // synchroniser needed), sampled once per input line.
  input           i_pal_hires,
  input           i_pal_shres,
  // CRT outputs, clk_out domain
  output [23:0]   o_hd_next,     // {b,g,r} of the NEXT input line, same x
  output          o_pix_stb,     // o_hd_* and o_hd_next hold a new pixel this clock
  output          o_line_start,  // one clock at the start of each HD line
  output [6:0]    o_line_phase,  // time from this HD line's buffer toggle, /128 clk_out
  output          o_line_hires   // the input line this HD line shows was hires or superhires
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
// (2026-10-09) The write address drives all 12 line-buffer BRAMs of its
// instance; in stage_combo1 that was one register with 8.1 ns of pure
// routing to a far BRAM (clk_114 -0.147 ns).  max_fanout lets Vivado copy
// it next to each BRAM group (Quartus ignores the attribute).
(* max_fanout = 4 *) reg  [13:0] r_addra = 0;
reg  [23:0] r_dina;
reg  [13:0] r_addrb = 0;
wire [23:0] w_doutb;
wire [13:0] w_addrb;   // port B address: r_addrb, or the next line's word (CRT)

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
  .b_addr(w_addrb), // r_addrb, or the next line's word in the update clock (CRT)
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

// How far each line buffer was written (2026-10-07).  The buffers are never
// cleared, and the read side reads a fixed stretch from a fixed offset, so
// wherever the write side wrote less -- a shorter line, another screen mode,
// the read offset reaching back into the previous buffer -- the buffer's old
// contents reached the screen: static stripes in the border after a mode
// change, one pattern per buffer (sim/hdmi_upsample).  r_wend[k] is the
// highest offset the last line written into buffer k reached; a line's
// pixels sit at offsets 1..r_wend (r_addra steps before it writes).  The
// read side shows black outside that range.  r_wend is written ~4 lines
// before buffer k is read, so the clk_114 -> clk_148 crossing sees a
// settled value (wizard.xdc bounds the path).
reg [2:0]  r_wslot = 3'b100;   // the buffer the current input line goes to
reg [10:0] r_wcnt  = 11'd0;    // pixels written into it so far
reg [10:0] r_wend [0:7];
integer    k_wend;
initial for (k_wend = 0; k_wend < 8; k_wend = k_wend + 1) r_wend[k_wend] = 11'd0;

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
    if (r_wcnt != 11'h7FF)
      r_wcnt <= r_wcnt + 1'b1;
  end

  // End of input line
  if (r_pal_hneg_in && ~i_pal_vsync)
  begin
    // the line just ended went to r_wslot; the next goes to r_cur_write_buf
    r_wend[r_wslot] <= r_wcnt;
    r_wslot         <= r_cur_write_buf;
    r_wcnt          <= 11'd0;

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
// the buffer this output line reads, and how far it was written (r_wend)
reg [2:0]   r_rslot = 3'b000;
reg [10:0]  r_rend  = 11'd0;
// the word w_doutb holds belongs to r_addrb (one-clock BRAM read, and
// r_addrb moves only every other clk_out): inside this line's buffer and
// inside what the write side reached?
wire        w_rd_valid = (r_addrb[13:11] == r_rslot) && (r_addrb[10:0] != 11'd0) &&
                         (r_addrb[10:0] <= r_rend);
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
      // black (border) for a word this line's input did not write
      r_hd_r <= w_rd_valid ? w_doutb[0 +: 8]  : 8'b0;
      r_hd_g <= w_rd_valid ? w_doutb[8 +: 8]  : 8'b0;
      r_hd_b <= w_rd_valid ? w_doutb[16 +: 8] : 8'b0;
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
    // the buffer read this line (the case below), and its written extent
    r_rslot <= r_cur_read_buf;
    r_rend  <= r_wend[r_cur_read_buf];
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

// ---------------------------------------------------------------------------
// CRT emulation (2026-10-09; study and bench: sim/hdmi_upsample/crt_*)
//
// 1. Next-line read for the two-line beam.  r_addrb moves every other
//    clk_out (one HD pixel = two clk_out); the read in the update clock
//    (w_upd) is never used by the picture path (its data arrives after
//    r_addrb has moved), so it fetches the same x from the NEXT buffer
//    (+0x800 wraps 7 -> 0 like the ring).  Captured one clock later into
//    r_hd_next; black where the next buffer was not written (r_wend).
// 2. Line phase.  The vertical position of an HD line inside the input
//    line it shows, measured in time: r_c_new counts clk_out since the
//    latest buffer toggle (the write side finished a line), r_c_old since
//    the one before.  The read side switches buffers at the HD hsync after a
//    toggle, so an HD line whose hsync sees r_next_buf (toggle pending) still
//    shows the older buffer -> r_c_old, else r_c_new.  Range T_hd .. T_hd +
//    T_line (PAL 50: 3960 .. 13464 clk_out).  Interlaced long fields end
//    vsync half a line later; the HD frame restarts there, so every HD
//    line's phase moves by ~0.5 input line in those fields by itself, and
//    the two fields' scanlines interleave.
// 3. Resolution per input line: HIRES|SHRES sampled 512 pixels into the
//    line (mid-screen, past any hblank), stored next to r_wend.
// ---------------------------------------------------------------------------
reg  [1:0]  r_res_s    = 2'b00;
reg         r_res_line = 1'b0;
reg         r_wres [0:7];
integer     k_wres;
initial for (k_wres = 0; k_wres < 8; k_wres = k_wres + 1) r_wres[k_wres] = 1'b0;
always @(posedge clk_in) begin
  r_res_s <= {i_pal_shres, i_pal_hires};
  if (r_wcnt == 11'd512) r_res_line <= |r_res_s;
  // same moment and slot as r_wend (end of the input line)
  if (r_pal_hneg_in && ~i_pal_vsync) r_wres[r_wslot] <= r_res_line;
end

wire w_hdfall = (r_hd_clk_ == 1'b1 && i_hd_clk == 1'b0);   // the update clock, sync or not
wire w_upd    = w_hdfall && ~i_hd_hsync;
wire w_in_win = (r_h_pos > PAL_HD_H_FP && r_h_pos < (PAL_HD_H_RES-PAL_HD_H_FP));
reg  [10:0] r_rend2 = 11'd0;   // written extent of the next buffer
always @(posedge clk_out)
  if (hd_hsync_negedge) r_rend2 <= r_wend[r_cur_read_buf + 3'd1];
wire w_rd_valid2 = (r_addrb[13:11] == r_rslot) && (r_addrb[10:0] != 11'd0) &&
                   (r_addrb[10:0] <= r_rend2);
// The second read goes out in every update clock, hsync or not: the
// picture path never uses that clock's read, and leaving i_hd_hsync out
// keeps the 60 Hz path's hsync (from adv_ddr, far away) off the line
// buffer's address pins (1.4 ns OOC slack with it, 2026-10-09).  The
// capture below is still qualified with w_upd.
assign w_addrb = (CRT && w_hdfall) ? (r_addrb + 14'h0800) : r_addrb;

reg        r_nxt_cap = 1'b0;   // w_doutb holds the next line's word this clock
reg        r_nxt_ok  = 1'b0;   // ... and it is inside window and written extent
reg [23:0] r_hd_next = 24'd0;
always @(posedge clk_out) begin
  r_nxt_cap <= CRT && w_upd;
  r_nxt_ok  <= w_in_win && w_rd_valid2;
  if (r_nxt_cap) r_hd_next <= r_nxt_ok ? w_doutb : 24'd0;
end
// in the update clock both r_hd_* (this line) and r_hd_next hold the pixel
// made one update earlier; crt_post samples them here
assign o_pix_stb = w_upd;
assign o_hd_next = CRT ? r_hd_next : 24'd0;

wire       w_toggle = (s_next_buf[3] != s_next_buf[2]);
reg [13:0] r_c_new = 14'h3FFF, r_c_old = 14'h3FFF, r_lphase = 14'd0;
reg        r_line_start = 1'b0;
reg        r_lres = 1'b0;
always @(posedge clk_out) begin
  if (w_toggle) begin
    r_c_old <= (r_c_new == 14'h3FFF) ? r_c_new : r_c_new + 1'b1;
    r_c_new <= 14'd0;
  end else begin
    if (r_c_new != 14'h3FFF) r_c_new <= r_c_new + 1'b1;
    if (r_c_old != 14'h3FFF) r_c_old <= r_c_old + 1'b1;
  end
  r_line_start <= hd_hsync_negedge;
  if (hd_hsync_negedge) begin
    r_lphase <= r_next_buf ? r_c_old : r_c_new;
    r_lres   <= r_wres[r_cur_read_buf];   // the buffer this line reads (r_rslot)
  end
end
assign o_line_phase = r_lphase[13:7];
assign o_line_start = r_line_start;
assign o_line_hires = CRT ? r_lres : 1'b0;

// output assignments
assign o_hd_r = r_hd_r;
assign o_hd_g = r_hd_g;
assign o_hd_b = r_hd_b;
assign o_frame_end = r_frame_end;
//assign o_vblank_width = r_vblank_width;

// assign o_hd_vsync = i_hd_vsync;
assign o_hd_vsync = i_rtg_enable ? s_hd_vsync[1] : r_del_vsync;
endmodule

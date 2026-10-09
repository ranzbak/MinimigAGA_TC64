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
  // Horizontal and Vertical offsets (OSD Video Pos), both signed.
  // i_hd_hoffset (clk_out domain): HD pixels, positive moves the picture
  // right, negative left.  i_hd_voffset (clk_in domain): 64 us steps (one
  // 15 kHz input line), positive moves the picture down, negative up; see
  // "Video Pos VPOS" below.
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

// Generate Frame end signal, to reset read loop: the input vsync negedge,
// or with VPOS the virtual one (w_vp_ev_o, below)
wire w_vp_ev_o, w_vp_virt_o;
always @(posedge clk_out)
begin
  r_frame_end <= 1'b0;
  if (w_vp_ev_o)
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
wire      w_vp_wr_reset;   // the write side's vsync reset (Video Pos VPOS, below)
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

  // Handle Vsync negative edge (or the virtual one, VPOS != 0)
  if (w_vp_wr_reset)
  begin
    r_cur_write_buf <= 4;
  end
end

// ---------------------------------------------------------------------------
// Video Pos VPOS (2026-10-09; bench sim/hdmi_upsample/crt_run.sh, legs vpos*)
//
// The HD raster restarts at the input's vsync negedge (r_frame_end ->
// signal_generator i_frame_end, the genlock), and both sides of the line
// buffer ring restart with it (write buffer 4, read buffer 0), so where the
// picture sits vertically is when that restart happens.  VPOS s (signed,
// clk_in, from pal_to_ddr's synchroniser) moves the restart -- a "virtual
// vsync" -- by s x 64 us (s 15 kHz lines; at 31 kHz input 2s lines), the
// picture by s x 2.40 HD lines at 50 Hz, s x 2.86 at 60 Hz (NTSC lines):
//   s < 0 (up):   |s| lines after the real vsync negedge, at the same
//                 clk_in offset from that line's hsync as the negedge had
//                 from its own (r_vp_p0), so the field's half-line offset in
//                 interlace is kept: the two fields still interleave;
//   s > 0 (down): s lines BEFORE the next negedge, predicted from the field
//                 two fields back (hsync count r_vp_n2, offset r_vp_p1) --
//                 interlaced fields alternate 312 / 313 lines and the
//                 negedge's half-line position, progressive repeats anyway.
// Both resets move together, so the ring lag (four buffers) is unchanged;
// input lines inside vsync still do not advance the writer.
//
// VPOS 0 is today's path, bit for bit: the real negedge resets the write
// side here (r_pal_vneg_in) and the read side in clk_out (r_pal_vneg),
// gated by r_vp_real, which is 1 throughout with VPOS 0 -- unless the last
// restart was a virtual one (VPOS just set back to 0): then the rules below
// apply until the next real one.  Other restarts (r_vp_fire) toggle
// r_vp_tgl into clk_out.
//
// A VPOS change moves the restart, so one HD frame comes out longer or
// shorter.  The HD vsync (signal_generator: HD lines 726..729) must still
// come out in it, and a 50/60 Hz frame is only ~749 HD lines: no restart
// is allowed less than N - M input lines after the last one (N: last
// field's lines, M = VP_M (2 x at 31 kHz); PAL 307 lines = 737 HD lines,
// NTSC 257 lines = 735), nor waits more than N + M.  A target that comes
// too early is deferred to N - M, one that does not come is replaced at
// N + M (both at the target's place in the line), and one less than N / 2
// after the last restart belongs to the field already restarted and is
// ignored.  So a change of up to M lines costs one HD frame of another
// length, a larger one glides there M lines a frame, every frame complete
// and a clean picture.  r_vp_real and every decision input are taken at
// input hsyncs (r_vp_since counts them), never near a vsync edge, so
// clk_out sees a settled r_vp_real when r_pal_vneg comes.  The first three
// fields after power-up restart at the real negedge (nothing measured).
// ---------------------------------------------------------------------------
localparam signed [11:0] VP_M = 12'sd5;
reg  [7:0]  r_vp_s     = 8'd0;     // VPOS, taken at each input hsync
reg  [1:0]  r_vp_seen  = 2'd0;     // real vsync negedges seen (to 3)
reg  [1:0]  r_vp_seenl = 2'd0;     // ... taken at each input hsync
reg  [10:0] r_vp_cnt   = 11'd0;    // input hsyncs since the real negedge
reg  [12:0] r_vp_cyc   = 13'h1FFF; // clk_in since the last input hsync
reg  [10:0] r_vp_n1    = 11'd0;    // input hsyncs in the last field
reg  [10:0] r_vp_n2    = 11'd0;    // ... in the one before
reg  [12:0] r_vp_p0    = 13'd0;    // this field's negedge, clk_in after its line's hsync
reg  [12:0] r_vp_p1    = 13'd0;    // ... the last field's
reg  [10:0] r_vp_n     = 11'd0;    // r_vp_n1 taken at each input hsync
reg         r_vp_dbl   = 1'b0;     // 31 kHz input (> 400 lines a field)
reg  [10:0] r_vp_since = 11'h7FF;  // input hsyncs since the restart's line
reg         r_vp_fline = 1'b0;     // a restart happened in this input line
reg         r_vp_pend  = 1'b0;     // a restart deferred (frame too short)
reg         r_vp_hsd   = 1'b0;     // the clock after an input hsync
reg         r_vp_real  = 1'b1;     // the next restart is the real negedge
reg         r_vp_vlast = 1'b0;     // the last restart was a virtual one
reg  signed [11:0] r_vp_tgt = 12'sd0;  // target: input hsyncs since the negedge
reg  [12:0] r_vp_ph    = 13'd0;    // ... and clk_in after that hsync
reg         r_vp_lvl   = 1'b0;     // at or past the target
reg         r_vp_fire  = 1'b0;     // a restart other than the real negedge
reg         r_vp_tgl   = 1'b0;     // toggles with r_vp_fire, to clk_out
reg  signed [11:0] r_vp_lo = 12'sd0, r_vp_hi = 12'sd0, r_vp_half = 12'sd0;

wire signed [9:0]  w_vp_su   = r_vp_dbl ? {r_vp_s[7], r_vp_s, 1'b0} : {{2{r_vp_s[7]}}, r_vp_s};
wire               w_vp_zero = (r_vp_s == 8'd0) || (r_vp_seenl != 2'd3);
wire               w_vp_free = w_vp_zero && !r_vp_vlast;   // today's path, no rules
wire signed [11:0] w_vp_g    = {1'b0, r_vp_since};
wire               w_vp_ok   = w_vp_g >= r_vp_lo;                        // late enough
wire               w_vp_wd   = (w_vp_g >= r_vp_hi) && (r_vp_seenl >= 2'd2) && !w_vp_free; // waited too long
wire               w_vp_lvl  = ($signed({1'b0, r_vp_cnt}) > r_vp_tgt) ||
                               ($signed({1'b0, r_vp_cnt}) == r_vp_tgt && r_vp_cyc >= r_vp_ph);
// this field's target: the real negedge (VPOS 0), or the virtual one
wire               w_vp_x    = w_vp_zero ? r_pal_vneg_in : (w_vp_lvl && !r_vp_lvl);
wire               w_vp_realf = r_pal_vneg_in && r_vp_real;
assign w_vp_wr_reset = w_vp_realf || r_vp_fire;

always @(posedge clk_in) begin
  // where the input is: hsyncs since the real negedge, clk_in since the hsync
  r_vp_cyc <= (r_vp_cyc != 13'h1FFF) ? r_vp_cyc + 1'b1 : r_vp_cyc;
  if (r_pal_hneg_in) begin
    r_vp_cyc <= 13'd0;
    if (r_vp_cnt != 11'h7FF) r_vp_cnt <= r_vp_cnt + 1'b1;
  end
  if (r_pal_vneg_in) begin
    r_vp_cnt  <= 11'd0;
    r_vp_n1   <= r_vp_cnt;
    r_vp_n2   <= r_vp_n1;
    r_vp_p0   <= r_vp_cyc;
    r_vp_p1   <= r_vp_p0;
    if (r_vp_seen != 2'd3) r_vp_seen <= r_vp_seen + 1'b1;
  end

  // the decision inputs, taken at each input hsync
  r_vp_hsd <= r_pal_hneg_in;
  if (r_pal_hneg_in) begin
    r_vp_s     <= i_hd_voffset;
    r_vp_seenl <= r_vp_seen;
    r_vp_n     <= r_vp_n1;
    r_vp_dbl   <= (r_vp_n1 > 11'd400);
    r_vp_fline <= 1'b0;
    r_vp_since <= r_vp_fline ? 11'd0 : (r_vp_since != 11'h7FF) ? r_vp_since + 1'b1 : r_vp_since;
  end
  // r_vp_since counts from the line after the restart's: a restart in the
  // line where it reaches X is X + 1 lines after the last one
  r_vp_lo   <= $signed({1'b0, r_vp_n}) - (r_vp_dbl ? 2 * VP_M + 1 : VP_M + 1);   // N - M - 1
  r_vp_hi   <= $signed({1'b0, r_vp_n}) + (r_vp_dbl ? 2 * VP_M - 1 : VP_M - 1);   // N + M - 1
  r_vp_half <= $signed({2'b0, r_vp_n[10:1]});
  if (r_vp_hsd)
    r_vp_real <= w_vp_free || (w_vp_zero && w_vp_ok && !w_vp_wd);

  // the target
  if (r_vp_s[7]) begin
    r_vp_tgt <= -$signed({{2{w_vp_su[9]}}, w_vp_su});
    r_vp_ph  <= r_vp_p0;
  end else begin
    r_vp_tgt <= $signed({1'b0, r_vp_n2}) - $signed({{2{w_vp_su[9]}}, w_vp_su});
    r_vp_ph  <= r_vp_p1;
  end
  r_vp_lvl <= w_vp_lvl;

  // restarts
  r_vp_fire <= 1'b0;
  // a deferred or replaced restart keeps the target's place in the line
  // (r_vp_ph), so every frame sits a whole number of lines from it (and
  // interlaced fields keep their half-line offset while gliding)
  if (!r_vp_fline && !r_vp_fire && !w_vp_realf &&
      ((w_vp_x && !w_vp_zero && w_vp_ok) ||
       ((r_vp_pend && w_vp_ok || w_vp_wd) && r_vp_cyc >= r_vp_ph)))
    r_vp_fire <= 1'b1;
  if (w_vp_x && !w_vp_ok && w_vp_g >= r_vp_half && !w_vp_free)
    r_vp_pend <= 1'b1;
  if (w_vp_realf || r_vp_fire) begin
    r_vp_pend  <= 1'b0;
    r_vp_fline <= 1'b1;
    r_vp_vlast <= r_vp_fire;
  end
  if (r_vp_fire) r_vp_tgl <= ~r_vp_tgl;
end

// clk_out: the real negedge while r_vp_real, or a toggle of r_vp_tgl
(* ASYNC_REG = "TRUE" *) reg [1:0] s_vp_real_o = 2'b11;
(* ASYNC_REG = "TRUE" *) reg [2:0] s_vp_tgl_o  = 3'b000;
always @(posedge clk_out) begin
  s_vp_real_o <= {s_vp_real_o[0], r_vp_real};
  s_vp_tgl_o  <= {s_vp_tgl_o[1:0], r_vp_tgl};
end
assign w_vp_virt_o = (s_vp_tgl_o[2] != s_vp_tgl_o[1]);
assign w_vp_ev_o   = (r_pal_vneg && s_vp_real_o[1]) || w_vp_virt_o;

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

// where a line's read starts: the fixed offset plus the OSD's signed one,
// registered (static), so each line starts at {buffer, 11'b0} - r_rd_off.
reg  [13:0] r_rd_off = PAL_OFFSET_HZ;
always @(posedge clk_out)
  r_rd_off <= PAL_OFFSET_HZ + {{6{i_hd_hoffset[7]}}, i_hd_hoffset};

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
    // the buffer read this line (r_addrb below), and its written extent
    r_rslot <= r_cur_read_buf;
    r_rend  <= r_wend[r_cur_read_buf];
    r_addrb <= {r_cur_read_buf, 11'b0} - r_rd_off;
  end


  // Neg edge vsync (or the virtual one, VPOS != 0): the read side starts
  // at buffer 0, four behind the write side (r_cur_write_buf <= 4)
  if (w_vp_ev_o)
  begin
    r_cur_read_buf  <= 0;
  end
  // A virtual restart can follow an input line end closely (at 31 kHz the
  // bench's comes 32 clk_in after one); that line's buffer toggle, still
  // pending, would move the reader to buffer 1 at once and the picture
  // one input line up.  The real negedge's line end lies inside vsync (no
  // toggle), so only the virtual path drops it.
  if (w_vp_virt_o)
    r_next_buf <= 1'b0;
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

`timescale 1ns / 1ps
// crt_post -- CRT look for the HDMI upsampler's pixel stream (study
// 2026-10-08, in the design 2026-10-09).  One instance after pal_to_ddr's
// 50/60 Hz mux; clk_148, one pixel per i_stb (every other clock).  Every
// effect is a run-time control; all controls 0 = the input stream
// unchanged, delayed by 8 pixels (pal_to_ddr reads the line buffers 8
// pixels earlier to take that back: the picture is then bit-identical).
//
//   stage A  inputs, and the line's beam weights w0/w1 from WROM
//            (address {hz60, vblend, scan, line phase[6:0]}: the line phase is
//            static for a whole HD line, so the ROM read is off the pixel path)
//   stage B  v = cur*w0 + next*w1           (DSP48: 3 or 6 multipliers)
//   stage C  v >> 8, saturated to 8 bits
//   stage D  horizontal 3-tap on v: v0 + (v-1 + v+1 - 2 v0) >>> s
//            s = 3 ([1 6 1]/8) or 2 ([1 2 1]/4); two registers (the
//            laplacian, then add + saturate) to keep clk_148 slack
//   stage E  mask state per channel and column, then LUT
//            {page, mask state, value} -> out: brightness / gamma
//            compensation and the mask's dimming in one block-RAM read
//
// WROM entry: {w1[8:0], w0[8:0]}, weights 0..256 (256 = 1.0).
// LUT entry : 8 bits.  Both made by sim/hdmi_upsample/crt_mkroms.py; the
// files (crt_wrom.mem, crt_lut.mem) are design sources next to this file.
module crt_post #(
  parameter HAS_VBLEND = 1,          // 0: next-line input and w1 ignored (3 DSP, not 6)
  parameter HAS_HBLUR  = 1,
  parameter HAS_MASK   = 0,          // T4 shadow mask: not in the design (2026-10-09)
  parameter HAS_LUT    = 1,
  parameter WROM_FILE  = "crt_wrom.mem",
  parameter LUT_FILE   = "crt_lut.mem"
)(
  input             clk,
  input             i_stb,          // new pixel on i_cur / i_nxt this clock
  input             i_line_start,   // start of an HD line (mask column reset)
  input      [6:0]  i_phase,        // the line's phase (pal_to_hd_upsample_crt)
  input      [23:0] i_cur,          // {b,g,r} this Amiga line
  input      [23:0] i_nxt,          // {b,g,r} next Amiga line, same x
  // controls (OSD), static
  input             i_hz60,         // 60 Hz path (other HD line length in WROM)
  input      [1:0]  i_scan,         // scanlines: 0 off, 1 light, 2 medium, 3 strong
  input             i_vblend,       // two-line beam (with i_scan = 0: linear blend)
  input      [1:0]  i_hblur,        // 0 off, 1 [1 6 1]/8, 2/3 [1 2 1]/4
  input      [1:0]  i_mask,         // 0 off, 1 RGB stripes (3 px), 2 magenta/green (2 px)
  input      [1:0]  i_lut,          // LUT page: 0 identity, 1..3 compensation
  // WROM write port (firmware-tunable beam profiles; tie off for a ROM).
  // Being writable also makes Vivado put it in block RAM: as a pure ROM it
  // goes to ~240 LUTs whatever rom_style says.
  input             i_wwe,
  input      [10:0] i_wwa,
  input      [17:0] i_wwd,
  output     [23:0] o_rgb
);

// ---- weights table, block RAM 2048 x 18 (one RAMB36) ---------------------------------------------
(* ram_style = "block" *) reg [17:0] wrom [0:2047];
initial $readmemh(WROM_FILE, wrom);
// w_q is the block RAM's own output register; w_r a second stage, kept
// apart so Vivado cannot fold w_q into the DSPs' B registers (that leaves an
// asynchronous read, which only LUTRAM can do: 768 LUTs) and so the BRAM ->
// DSP route gets a whole clock.  The weights are static per HD line.
reg [17:0] w_q;
(* keep = "true" *) reg [17:0] w_r;
always @(posedge clk) begin
  if (i_wwe) wrom[i_wwa] <= i_wwd;
  w_q <= wrom[{i_hz60, (HAS_VBLEND ? i_vblend : 1'b0), i_scan, i_phase}];
  w_r <= w_q;
end
wire [8:0] w0 = w_r[8:0];
wire [8:0] w1 = HAS_VBLEND ? w_r[17:9] : 9'd0;

// ---- A: input registers ----------------------------------------------------
reg [23:0] a_cur = 0, a_nxt = 0;
always @(posedge clk) if (i_stb) begin
  a_cur <= i_cur;
  a_nxt <= HAS_VBLEND ? i_nxt : 24'd0;
end

// ---- B/C: vertical beam, per channel ------------------------------------------
wire [7:0] c_v [0:2];
genvar ch;
generate for (ch = 0; ch < 3; ch = ch + 1) begin : g_v
  (* use_dsp = "yes" *) reg [16:0] b_m0 = 0;
  (* use_dsp = "yes" *) reg [16:0] b_m1 = 0;
  reg [7:0]  c_r  = 0;
  wire [17:0] sum = {1'b0, b_m0} + {1'b0, b_m1};
  always @(posedge clk) if (i_stb) begin
    b_m0 <= a_cur[8*ch +: 8] * w0;
    b_m1 <= HAS_VBLEND ? a_nxt[8*ch +: 8] * w1 : 17'd0;
    c_r  <= (sum[17:16] != 2'b00) ? 8'hFF : sum[15:8];
  end
  assign c_v[ch] = c_r;
end endgenerate

// ---- D: horizontal 3-tap ---------------------------------------------------------
// the window: c_v = v[n+1], d_1 = v[n], d_2 = v[n-1]; output v[n] filtered
wire [7:0] d_out [0:2];
generate for (ch = 0; ch < 3; ch = ch + 1) begin : g_h
  reg [7:0] d_1 = 0, d_2 = 0, d_r = 0, d_c = 0;
  reg signed [10:0] d_adj = 0;
  wire signed [10:0] lap = $signed({3'b000, d_2}) + $signed({3'b000, c_v[ch]})
                         - $signed({2'b00, d_1, 1'b0});
  wire signed [10:0] res = $signed({3'b000, d_c}) + d_adj;
  always @(posedge clk) if (i_stb) begin
    d_1 <= c_v[ch];
    d_2 <= d_1;
    d_c <= d_1;                                   // the centre pixel, aligned with d_adj
    d_adj <= (HAS_HBLUR && i_hblur != 2'd0) ? ((i_hblur == 2'd1) ? (lap >>> 3) : (lap >>> 2)) : 11'sd0;
    d_r <= res[10] ? 8'd0 : (res[9:8] != 2'b00) ? 8'hFF : res[7:0];
  end
  assign d_out[ch] = d_r;
end endgenerate

// ---- E: mask state, LUT -------------------------------------------------------------
// column counters, reset at each line start; the mask sits at fixed screen x
reg [1:0] col3 = 0;
reg       col2 = 0;
always @(posedge clk) begin
  if (i_line_start) begin col3 <= 2'd0; col2 <= 1'b0; end
  else if (i_stb) begin
    col3 <= (col3 == 2'd2) ? 2'd0 : col3 + 2'd1;
    col2 <= ~col2;
  end
end
// mask state: 0 off, 1 on and this channel lit, 2 on and this channel dimmed
function [1:0] mstate(input [1:0] mode, input [1:0] c3, input c2, input [1:0] chn);
  begin
    case (mode)
      2'd1: mstate = (c3 == chn) ? 2'd1 : 2'd2;                 // R G B stripes
      2'd2: mstate = ((chn == 1) ^ c2) ? 2'd2 : 2'd1;          // even: R+B, odd: G
      default: mstate = 2'd0;
    endcase
  end
endfunction

wire [7:0] e_out [0:2];
generate for (ch = 0; ch < 3; ch = ch + 1) begin : g_lut
  localparam [1:0] CH = ch;
  if (HAS_LUT) begin : g_on
    (* rom_style = "block" *) reg [7:0] lut [0:4095];
    initial $readmemh(LUT_FILE, lut);
    wire [1:0] ms = HAS_MASK ? mstate(i_mask, col3, col2, CH) : 2'd0;
    reg [11:0] e_a = 0;
    reg [7:0]  e_q = 0, e_r = 0;
    always @(posedge clk) begin
      if (i_stb) e_a <= {i_lut, ms, d_out[ch]};
      e_q <= lut[e_a];                 // block RAM read every clock
      if (i_stb) e_r <= e_q;
    end
    assign e_out[ch] = e_r;
  end else begin : g_off
    reg [7:0] e_r = 0;
    always @(posedge clk) if (i_stb) e_r <= d_out[ch];
    assign e_out[ch] = e_r;
  end
end endgenerate

assign o_rgb = {e_out[2], e_out[1], e_out[0]};
endmodule

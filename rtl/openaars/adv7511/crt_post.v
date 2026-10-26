`timescale 1ns / 1ps
// crt_post -- CRT look for the HDMI upsampler's pixel stream (study
// 2026-10-08, in the design 2026-10-09).  One instance after pal_to_ddr's
// 50/60 Hz mux; clk_148, one pixel per i_stb (every other clock).  Every
// effect is a run-time control; all controls 0 = the input stream
// unchanged, delayed by 9 pixels (pal_to_ddr reads the line buffers 9
// pixels earlier to take that back: the picture is then bit-identical).
//
//   stage A  inputs, and the line's beam weights w0/w1 from WROM
//            (address {hz60, vblend, scan, line phase[6:0]}: the line phase is
//            static for a whole HD line, so the ROM read is off the pixel path)
//   stage B  v = cur*w0 + next*w1           (DSP48: 3 or 6 multipliers)
//   stage C  v >> 8, saturated to 8 bits
//   stage F  bloom (2026-10-09): BTAB {level, Wq, v} -> v', per channel.  A
//            bright beam is wider, so its scanline gap fills in: Wq is the
//            line's total beam weight w0 + w1 (static per HD line), v / W
//            the pixel's own brightness; the table lifts v toward the
//            no-gap value by an amount that grows with that brightness
//   stage D  horizontal 3-tap on v: v0 + (v-1 + v+1 - 2 v0) >>> s
//            s = 3 ([1 6 1]/8) or 2 ([1 2 1]/4); two registers (the
//            laplacian, then add + saturate) to keep clk_148 slack
//   stage E  mask state per channel and column, then LUT
//            {page, mask state, value} -> out: brightness / gamma
//            compensation and the mask's dimming (each mode's mean light
//            divided back out) in one block-RAM read
//
// Linear light (2026-10-13, findings/scaler/plan.md step 5): with i_lin
// (the exact-ratio modes) stages B/C are replaced by the same blend in
// LINEAR light -- per channel
//   L1  decode  SDEC[cur], SDEC[nxt]: 8-bit code -> 18-bit linear (2.4)
//   L2  multiply by the line's linear weights lw0 / lw1 (32768 = 1.0) from
//       SWROM {hz60, kernel, phase}, + 16384 (rounding)
//   L3  y = (sum) >> 15, saturated to 18 bits
//   L4  encode index: y < 2048 ? y : 2032 + (y >> 7)
//   L5  SENC[index] -> 8-bit code
// kernel (i_kern): 0 sharp-bilinear 0.5, 1 area, 2 / 3 the two-line beam
// for scanlines dim / black; phase (i_vphase): the HD line's centre below
// the cur line's, 1/256 line.  The linear path is 3 pixels longer (12 in
// all): with i_lin the upsampler reads 3 pixels earlier (pal_to_ddr,
// LIN_LAT), so the gamma path -- and with it the line-rate picture -- keeps
// its 9 pixels, bit for bit.  The bloom stage takes its gap measure from
// SWROM's wq in this mode.  Tables: scl_mkroms.py.
//
// WROM entry: {w1[8:0], w0[8:0]}, weights 0..256 (256 = 1.0).
// LUT entry : 8 bits.  BTAB entry: 8 bits.  All three made by
// sim/hdmi_upsample/crt_mkroms.py; the files (crt_wrom.mem, crt_lut.mem,
// crt_bloom.mem) are design sources next to this file.
module crt_post #(
  parameter HAS_VBLEND = 1,          // 0: w1 ignored (3 DSP, not 6); HAS_LIN still takes the next line
  parameter HAS_HBLUR  = 1,
  parameter HAS_MASK   = 1,          // phosphor mask (needs HAS_LUT)
  parameter HAS_BLOOM  = 1,
  parameter HAS_LUT    = 1,
  parameter WROM_FILE  = "crt_wrom.mem",
  parameter LUT_FILE   = "crt_lut.mem",
  parameter BLOOM_FILE = "crt_bloom.mem",
  parameter HAS_LIN    = 1,          // the linear-light path (6 more DSP48; tables 3 RAMB18 + 5 RAMB36)
  parameter SDEC_FILE  = "crt_sdec.mem",
  parameter SENC_FILE  = "crt_senc.mem",
  parameter SWROM_FILE = "crt_swrom.mem"
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
  input      [1:0]  i_mask,         // 0 off, 1 grille (R G B stripes, 3 px), 2 grille strong,
                                    // 3 shadow (magenta / green, 2 px)
  input      [1:0]  i_bloom,        // 0 off, 1 low, 2/3 high (needs a vertical effect)
  input      [1:0]  i_lut,          // LUT page: 0 identity, 1..3 compensation
  // linear-light vertical blend (exact-ratio modes; static per HD line)
  input             i_lin,
  input      [1:0]  i_kern,         // 0 sharp, 1 area, 2 beam dim, 3 beam black
  input      [7:0]  i_vphase,       // the line's phase, 1/256 line
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
// With no vertical effect (scan 0, no blend) w_r is the table's bypass
// entry {0, 256} without reading it, so the plain picture never depends on
// the table having been loaded (a build that lost crt_wrom.mem keeps it).
reg [17:0] w_q;
(* keep = "true" *) reg [17:0] w_r;
wire w_bypass = (i_scan == 2'd0) && !(HAS_VBLEND && i_vblend);
always @(posedge clk) begin
  if (i_wwe) wrom[i_wwa] <= i_wwd;
  w_q <= wrom[{i_hz60, (HAS_VBLEND ? i_vblend : 1'b0), i_scan, i_phase}];
  w_r <= w_bypass ? 18'd256 : w_q;
end
wire [8:0] w0 = w_r[8:0];
wire [8:0] w1 = HAS_VBLEND ? w_r[17:9] : 9'd0;

// ---- A: input registers ----------------------------------------------------
reg [23:0] a_cur = 0, a_nxt = 0;
always @(posedge clk) if (i_stb) begin
  a_cur <= i_cur;
  a_nxt <= (HAS_VBLEND || HAS_LIN) ? i_nxt : 24'd0;
end

// ---- linear weights table, block RAM 2048 x 36 -----------------------------------
// address {hz60, kernel, phase}, entry {wq[3:0], lw1[15:0], lw0[15:0]}; static
// per HD line like w_r (two registers, the second kept apart from the DSPs)
(* ram_style = "block" *) reg [35:0] swrom [0:2047];
initial if (HAS_LIN) $readmemh(SWROM_FILE, swrom);
reg [35:0] s_q = 0;
(* keep = "true" *) reg [35:0] s_r = 0;
reg        r_lin = 1'b0;
always @(posedge clk) begin
  s_q   <= swrom[{i_hz60, i_kern, i_vphase}];
  s_r   <= s_q;
  r_lin <= HAS_LIN && i_lin;
end
wire [15:0] lw0 = s_r[15:0];
wire [15:0] lw1 = s_r[31:16];
wire [3:0]  lwq = s_r[35:32];

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
  if (HAS_LIN) begin : g_lin
    // L1: decode, a block RAM read every clock (a_* move on i_stb), taken
    // at the next i_stb
    (* ram_style = "block" *) reg [17:0] sdec [0:255];
    initial $readmemh(SDEC_FILE, sdec);
    reg [17:0] l_qc = 0, l_qn = 0, l_c = 0, l_n = 0;
    // L2, L3: the weighted sum
    (* use_dsp = "yes" *) reg [33:0] l_m0 = 0;
    (* use_dsp = "yes" *) reg [33:0] l_m1 = 0;
    reg [17:0] l_y = 0;
    wire [34:0] l_sum = {1'b0, l_m0} + {1'b0, l_m1};
    // L4, L5: encode
    reg [11:0] l_i = 0;
    (* ram_style = "block" *) reg [7:0] senc [0:4095];
    initial $readmemh(SENC_FILE, senc);
    reg [7:0]  l_eq = 0, l_e = 0;
    always @(posedge clk) begin
      l_qc <= sdec[a_cur[8*ch +: 8]];
      l_qn <= sdec[a_nxt[8*ch +: 8]];
      l_eq <= senc[l_i];
      if (i_stb) begin
        l_c  <= l_qc;
        l_n  <= l_qn;
        l_m0 <= l_c * lw0 + 34'd16384;
        l_m1 <= l_n * lw1;
        l_y  <= (l_sum[34:33] != 2'b00) ? 18'h3FFFF : l_sum[32:15];
        l_i  <= (l_y[17:11] == 7'd0) ? {1'b0, l_y[10:0]} : 12'd2032 + {1'b0, l_y[17:7]};
        l_e  <= l_eq;
      end
    end
    assign c_v[ch] = r_lin ? l_e : c_r;
  end else begin : g_nolin
    assign c_v[ch] = c_r;
  end
end endgenerate

// ---- F: bloom ------------------------------------------------------------------------
// Wq = clamp((w0 + w1 - 128) / 8, 0, 15), static per HD line like w_r.
// Off, or no vertical effect (no gap to fill): v itself, not the table --
// as for w_r, the plain picture never depends on a table.
wire [9:0] w_sum = {1'b0, w0} + {1'b0, w1};
reg  [3:0] f_wq = 4'd15;
reg        f_en = 1'b0;
always @(posedge clk) begin
  f_wq <= r_lin ? lwq : (w_sum < 10'd128) ? 4'd0 : (w_sum >= 10'd248) ? 4'd15 : w_sum[6:3];
  f_en <= HAS_BLOOM && (i_bloom != 2'd0) && (r_lin || !w_bypass);
end
wire [7:0] f_v [0:2];
generate for (ch = 0; ch < 3; ch = ch + 1) begin : g_f
  if (HAS_BLOOM) begin : g_on
    (* ram_style = "block" *) reg [7:0] btab [0:8191];
    initial $readmemh(BLOOM_FILE, btab);
    reg [7:0] f_q = 0, f_r = 0;
    always @(posedge clk) begin
      f_q <= btab[{i_bloom[1], f_wq, c_v[ch]}];   // block RAM read every clock
      // c_v moved on the last i_stb; f_q is its entry now
      if (i_stb) f_r <= f_en ? f_q : c_v[ch];
    end
    assign f_v[ch] = f_r;
  end else begin : g_off
    reg [7:0] f_r = 0;
    always @(posedge clk) if (i_stb) f_r <= c_v[ch];
    assign f_v[ch] = f_r;
  end
end endgenerate

// ---- D: horizontal 3-tap ---------------------------------------------------------
// the window: f_v = v[n+1], d_1 = v[n], d_2 = v[n-1]; output v[n] filtered
wire [7:0] d_out [0:2];
generate for (ch = 0; ch < 3; ch = ch + 1) begin : g_h
  reg [7:0] d_1 = 0, d_2 = 0, d_r = 0, d_c = 0;
  reg signed [10:0] d_adj = 0;
  wire signed [10:0] lap = $signed({3'b000, d_2}) + $signed({3'b000, f_v[ch]})
                         - $signed({2'b00, d_1, 1'b0});
  wire signed [10:0] res = $signed({3'b000, d_c}) + d_adj;
  always @(posedge clk) if (i_stb) begin
    d_1 <= f_v[ch];
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
// mask state (the LUT's, see crt_mkroms.py): 0 off; this channel lit /
// dimmed: 1 / 2 grille, 3 / 4 grille strong, 1 / 5 shadow
function [2:0] mstate(input [1:0] mode, input [1:0] c3, input c2, input [1:0] chn);
  begin
    case (mode)
      2'd1: mstate = (c3 == chn) ? 3'd1 : 3'd2;                // R G B stripes
      2'd2: mstate = (c3 == chn) ? 3'd3 : 3'd4;                // the same, deeper
      2'd3: mstate = ((chn == 1) ^ c2) ? 3'd5 : 3'd1;          // even: R+B, odd: G
      default: mstate = 3'd0;
    endcase
  end
endfunction

wire [7:0] e_out [0:2];
generate for (ch = 0; ch < 3; ch = ch + 1) begin : g_lut
  localparam [1:0] CH = ch;
  if (HAS_LUT) begin : g_on
    (* rom_style = "block" *) reg [7:0] lut [0:8191];
    initial $readmemh(LUT_FILE, lut);
    wire [2:0] ms = HAS_MASK ? mstate(i_mask, col3, col2, CH) : 3'd0;
    reg [12:0] e_a = 0;
    reg [7:0]  e_q = 0, e_r = 0;
    // page 0 without mask is the identity: take the value itself (e_b,
    // aligned with e_a), not the table -- as for w_r above
    reg [7:0]  e_b = 0;
    reg        e_id = 1'b1;
    always @(posedge clk) begin
      if (i_stb) begin
        e_a  <= {i_lut, ms, d_out[ch]};
        e_b  <= d_out[ch];
        e_id <= (i_lut == 2'd0) && (ms == 3'd0);
      end
      e_q <= lut[e_a];                 // block RAM read every clock
      if (i_stb) e_r <= e_id ? e_b : e_q;
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

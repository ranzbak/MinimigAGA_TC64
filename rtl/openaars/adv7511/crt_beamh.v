`timescale 1ns / 1ps
// crt_beamh -- horizontal CRT beam spot on the Amiga RGB stream, before the
// HDMI upsamplers capture it (study 2026-10-09, sim/hdmi_upsample/crt_beamh.py
// is the bit-exact model).  clk_114; the stream carries one superhires
// sample per CLK_28 = 4 clk_114 in every screen mode (amber passes Denise's
// 28 MHz pixels through with the scandoubler off), a lowres pixel is 4 equal
// samples, a hires pixel 2.  The spot is a gaussian of constant width on
// screen, so one kernel serves every resolution: no per-line or per-pixel
// resolution choice.
//
// Per channel, in linear light (gamma 2.4):
//   decode   DEC {level, v} -> {B, L}: L = 16-bit linear, B its bloom share
//   pre      P = L[-2] + 2 L[-1] + 2 L + 2 L[+1] + L[+2]     (tap spacing 4)
//              = 2 (L[-1] + 2 L + L[+1])                      (tap spacing 2)
//            (sum 8 either way), PB the same on B
//   FIR      acc = sum_{j=-4..4} kn[|j|] P[n + s j] + dk[|j|] PB[n + s j]
//   out      y = (acc + 2^10) >> 11, clamped; ENC[idx(y)] -> 8 bit
// kn (narrow spot, sums to 256), dk (wide minus narrow, sums to 0) and the
// spacing s come from KTAB by {bloom, width}.
//
// Channel-serial: the three channels take turns, one per clk_114 (the
// fourth clock of each sample is idle), so one decode read, one encode read
// and one DSP cascade serve all three.  The FIR is the symmetric systolic
// form (UG479): the forward delay line has D + 1 clocks between taps, the
// backward one D - 1 (D = 4 s), each DSP48 pre-adds its tap pair and adds
// its product onto the previous DSP's P (PCIN cascade, no fabric adders).
// The delay segments are SRLs whose length the frame-static s selects.
//
// The capture phase locks to the hsync's rising edge (a CLK_28 edge, as the
// RGB's), so it is the same every power-up.  Hsync, vsync, HIRES and SHRES
// are delayed by the filter's latency (36 + 16 s clk_114 from the sample's
// first clock to its filtered value, in the bench's timing; on the board
// the picture may sit one clk_114 off), so the picture does not move.
//
// Controls (CLK_28 / RTG side): 2-FF synchronisers, then a latch 128 clocks
// after the vsync's rising edge -- in the vertical blank, where no sync edge
// is within the delay line's reach, so changing the delay cannot add or
// lose one.  The filter is on only while the last frame had fewer than 400
// lines and RTG is off (not after the first, partial frame either);
// otherwise, or with width 0, o_* = i_* exactly.
//
// Tables (made by sim/hdmi_upsample/crt_beamh.py, design sources next to
// this file): DEC_FILE 1024 x 32, ENC_FILE 4096 x 8, K_FILE 16 x 96.  The
// bypass never reads them.
module crt_beamh #(
  parameter HAS_BLOOM = 1,                 // 0: no horizontal bloom (5 DSP, not 10)
  parameter DEC_FILE  = "crt_hdec.mem",
  parameter ENC_FILE  = "crt_henc.mem",
  parameter K_FILE    = "crt_hk.mem"
)(
  input            clk,                    // clk_114
  input      [7:0] i_r,
  input      [7:0] i_g,
  input      [7:0] i_b,
  input            i_hs,                   // active high, as the upsamplers take them
  input            i_vs,
  input            i_hires,
  input            i_shres,
  // OSD (CLK_28) and RTG, asynchronous here
  input      [1:0] i_width,                // 0 off, 1 sharp, 2 medium, 3 soft
  input      [1:0] i_bloom,                // 0 off, 1 low, 2/3 high
  input            i_rtg,
  output     [7:0] o_r,
  output     [7:0] o_g,
  output     [7:0] o_b,
  output           o_hs,
  output           o_vs,
  output           o_hires,
  output           o_shres
);

localparam NS = HAS_BLOOM ? 10 : 5;        // DSP stages
localparam PH0 = 2'd0;                     // phase after the hsync edge (see the header)
localparam LSYNC_BASE = 35;                // latency - 4 D, bench timing

// ---- controls -------------------------------------------------------------------
(* ASYNC_REG = "TRUE" *) reg [3:0] s_cfg0 = 4'd0;
(* ASYNC_REG = "TRUE" *) reg [3:0] s_cfg1 = 4'd0;
(* ASYNC_REG = "TRUE" *) reg [1:0] s_rtg  = 2'b00;
reg        hs_d = 1'b0, vs_d = 1'b0;
reg  [9:0] lines = 10'd0;
reg        ok = 1'b0;
reg        vseen = 1'b0;                  // lines counts a whole frame
reg  [7:0] lcnt = 8'd0;
reg        lpend = 1'b0;
reg        on_n = 1'b0, lset = 1'b0;
reg        r_on = 1'b0;
reg  [1:0] r_width = 2'd0;
reg  [1:0] r_bloom = 2'd0;
wire       hs_rise = i_hs & ~hs_d;
always @(posedge clk) begin
  s_cfg0 <= {i_bloom, i_width};
  s_cfg1 <= s_cfg0;
  s_rtg  <= {s_rtg[0], i_rtg};
  hs_d   <= i_hs;
  vs_d   <= i_vs;
  if (i_vs & ~vs_d) begin
    ok    <= vseen && (lines < 10'd400) && !s_rtg[1];
    vseen <= 1'b1;
    lines <= 10'd0;
    lcnt  <= 8'd0;
    lpend <= 1'b1;
  end else begin
    if (hs_rise && lines != 10'h3FF) lines <= lines + 1'b1;
    if (lpend) lcnt <= lcnt + 1'b1;
    if (lpend && lcnt == 8'd127) begin
      lpend   <= 1'b0;
      on_n    <= ok && (s_cfg1[1:0] != 2'd0);
      r_width <= s_cfg1[1:0];
      r_bloom <= !HAS_BLOOM ? 2'd0 : (s_cfg1[3:2] == 2'd3) ? 2'd2 : s_cfg1[3:2];
    end
  end
  // the kernel (k_r, below) follows r_width / r_bloom a clock later; r_on
  // one more, so the sync delay is the new one when the outputs switch
  lset <= lpend && lcnt == 8'd127;
  if (lset) r_on <= on_n;
end

// kernel: {s4, kn0..kn4 (9 b), dk0..dk4 (10 b signed)}, static per frame
reg [95:0] ktab [0:15];
initial $readmemh(K_FILE, ktab);
reg [95:0] k_r = 96'd0;
always @(posedge clk) k_r <= ktab[{r_bloom, r_width}];
wire s4 = k_r[95];
function signed [17:0] wsel(input [95:0] k, input integer i);   // i 0..4 kn, 5..9 dk
  begin
    if (i < 5) wsel = {9'd0, k[94 - 9 * i -: 9]};
    else       wsel = {{8{k[49 - 10 * (i - 5)]}}, k[49 - 10 * (i - 5) -: 10]};
  end
endfunction

// ---- capture and channel slots -------------------------------------------------
reg  [1:0]  ph = 2'd0;
reg  [23:0] x = 24'd0;                    // {r, g, b} of the sample in the pipe
always @(posedge clk) begin
  ph <= hs_rise ? PH0 : ph + 2'd1;
  if (ph == 2'd0) x <= {i_r, i_g, i_b};
end
wire [7:0] v_sel = (ph == 2'd1) ? x[23:16] : (ph == 2'd2) ? x[15:8] : (ph == 2'd3) ? x[7:0] : 8'd0;

// ---- decode (block RAM, output register) -----------------------------------------
(* rom_style = "block" *) reg [31:0] dec [0:1023];
initial $readmemh(DEC_FILE, dec);
reg [31:0] dec_q = 32'd0, dec_r = 32'd0;
always @(posedge clk) begin
  dec_q <= dec[{r_bloom, v_sel}];
  dec_r <= dec_q;
end

// ---- pre-stage, per path (0: L, 1: B) ----------------------------------------------
// history at 4-clock spacing (one sample, same channel); centre L[-2] for both s
wire [18:0] pre_out [0:1];
genvar g;
generate for (g = 0; g < (HAS_BLOOM ? 2 : 1); g = g + 1) begin : g_pre
  wire [15:0] l0 = dec_r[16 * g +: 16];
  reg  [15:0] lh [0:15];
  genvar i;
  always @(posedge clk) lh[0] <= l0;
  for (i = 1; i < 16; i = i + 1) begin : g_lh
    always @(posedge clk) lh[i] <= lh[i - 1];
  end
  wire [15:0] l1 = lh[3], l2 = lh[7], l3 = lh[11], l4 = lh[15];
  reg  [16:0] q13 = 17'd0, q04 = 17'd0;
  reg  [17:0] q2 = 18'd0;
  reg  [18:0] p = 19'd0;
  always @(posedge clk) begin
    q13 <= l1 + l3;
    q04 <= s4 ? (l0 + l4) : 17'd0;
    q2  <= s4 ? {1'b0, l2, 1'b0} : {l2, 2'b00};
    p   <= q04 + {q13, 1'b0} + q2;
  end
  assign pre_out[g] = p;
end
if (!HAS_BLOOM) begin : g_nob
  assign pre_out[1] = 19'd0;
end
endgenerate

// ---- FIR delay lines, per path ------------------------------------------------------
// fw[0] = P (registered); fw[k+1] = fw[k] delayed D + 1; bw[3] = fw[4]
// delayed D - 1, bw[k] = bw[k+1] delayed D - 1.  The B path starts 5 clocks
// later than the L path: its DSPs sit 5 further down the cascade.
wire [18:0] opa [0:NS-1];
wire [18:0] opd [0:NS-1];
// The SRL addresses are registers (kept, reset value 0) so synthesis sees a
// real dynamic address and maps each segment bit to one SRL16E; from the
// constant low bits it otherwise builds two fixed SRLs, flops and a mux.
(* keep = "true" *) reg [3:0] fsel = 4'd0;   // forward:  D + 1 = 2 + fsel
(* keep = "true" *) reg [3:0] bsel = 4'd0;   // backward: D - 1 = 2 + bsel
always @(posedge clk) begin
  fsel <= s4 ? 4'd15 : 4'd7;
  bsel <= s4 ? 4'd13 : 4'd5;
end
generate for (g = 0; g < (HAS_BLOOM ? 2 : 1); g = g + 1) begin : g_fir
  reg [18:0] fw [0:4];
  reg [18:0] bw [0:3];
  genvar k, i;
  if (g == 0) begin : g_in0
    always @(posedge clk) fw[0] <= pre_out[0];
  end else begin : g_in1
    reg [18:0] dly [0:4];
    always @(posedge clk) dly[0] <= pre_out[1];
    for (i = 1; i < 5; i = i + 1) begin : g_d
      always @(posedge clk) dly[i] <= dly[i - 1];
    end
    always @(posedge clk) fw[0] <= dly[4];
  end
  for (k = 0; k < 4; k = k + 1) begin : g_seg
    reg [18:0] fsh [0:15];               // SRL16, length 1 + fsel
    reg [18:0] bsh [0:15];               // SRL16, length 1 + bsel
    wire [18:0] b_in;                    // the backward line starts at fw[4]
    if (k == 3) begin : g_b3
      assign b_in = fw[4];
    end else begin : g_bk
      assign b_in = bw[k + 1];
    end
    always @(posedge clk) begin
      fsh[0]    <= fw[k];
      fw[k + 1] <= fsh[fsel];
      bsh[0]    <= b_in;
      bw[k]     <= bsh[bsel];
    end
    for (i = 1; i < 16; i = i + 1) begin : g_sh
      always @(posedge clk) begin
        fsh[i] <= fsh[i - 1];
        bsh[i] <= bsh[i - 1];
      end
    end
  end
  for (k = 0; k < 5; k = k + 1) begin : g_op
    assign opa[5 * g + k] = fw[k];
    if (k < 4) begin : g_pair
      assign opd[5 * g + k] = bw[k];
    end else begin : g_ctr
      assign opd[5 * g + k] = 19'd0;
    end
  end
end endgenerate

// ---- DSP cascade -------------------------------------------------------------------------
// stage 5 g + k (k 0..3): taps k and 8 - k, weight index 4 - k; k = 4: the
// centre, weight index 0.  g = 0: kn on P, g = 1: dk on PB.
wire signed [47:0] pc [0:NS];
assign pc[0] = 48'sd1024;                 // + half of 2^11
generate for (g = 0; g < NS; g = g + 1) begin : g_dsp
  localparam integer KK = g % 5;
  localparam integer WI = (g / 5) * 5 + ((KK < 4) ? 4 - KK : 0);
  (* use_dsp = "yes" *) reg signed [24:0] a_r = 25'sd0, d_r = 25'sd0, ad_r = 25'sd0;
  (* use_dsp = "yes" *) reg signed [17:0] b_r = 18'sd0;
  (* use_dsp = "yes" *) reg signed [42:0] m_r = 43'sd0;
  (* use_dsp = "yes" *) reg signed [47:0] p_r = 48'sd0;
  always @(posedge clk) begin
    a_r  <= $signed({6'd0, opa[g]});
    d_r  <= $signed({6'd0, opd[g]});
    b_r  <= wsel(k_r, WI);
    ad_r <= a_r + d_r;
    m_r  <= ad_r * b_r;
    p_r  <= pc[g] + m_r;
  end
  assign pc[g + 1] = p_r;
end endgenerate

// without bloom the sum is ready 5 clocks earlier: keep the timing the same
wire signed [47:0] acc;
generate if (HAS_BLOOM) begin : g_acc10
  assign acc = pc[NS];
end else begin : g_acc5
  reg signed [47:0] ad [0:4];
  genvar i;
  always @(posedge clk) ad[0] <= pc[NS];
  for (i = 1; i < 5; i = i + 1) begin : g_ad
    always @(posedge clk) ad[i] <= ad[i - 1];
  end
  assign acc = ad[4];
end endgenerate

// ---- round, clamp, encode index, encode --------------------------------------------
reg  [15:0] y_r = 16'd0;
reg  [11:0] idx_r = 12'd0;
always @(posedge clk) begin
  y_r   <= acc[47] ? 16'd0 : (acc[46:27] != 20'd0) ? 16'hFFFF : acc[26:11];
  idx_r <= (y_r[15:11] == 5'd0) ? {1'b0, y_r[10:0]} : {1'b0, y_r[15:5]} + 12'd1984;
end
(* rom_style = "block" *) reg [7:0] enc [0:4095];
initial $readmemh(ENC_FILE, enc);
reg [7:0] enc_q = 8'd0, enc_r = 8'd0;
always @(posedge clk) begin
  enc_q <= enc[idx_r];
  enc_r <= enc_q;
end

// ---- the three channels back together, once per sample ---------------------------
// enc_r holds R, G, B in the clocks after ph 2, 3, 0 (crt_beamh.py and the
// bench's beam legs check the order)
reg [7:0]  r_o = 8'd0, g_o = 8'd0;
reg [23:0] f_rgb = 24'd0;
reg        o_stb = 1'b0;                  // f_rgb moved (bench: +sdump)
always @(posedge clk) begin
  if (ph == 2'd3) r_o <= enc_r;
  if (ph == 2'd0) g_o <= enc_r;
  if (ph == 2'd1) f_rgb <= {r_o, g_o, enc_r};
  o_stb <= (ph == 2'd1);
end

// ---- syncs and resolution, delayed alike ---------------------------------------------
wire [6:0] w_sdly = LSYNC_BASE + (s4 ? 7'd64 : 7'd32);
reg  [3:0] sd [0:127];
always @(posedge clk) sd[0] <= {i_hs, i_vs, i_hires, i_shres};
generate for (g = 1; g < 128; g = g + 1) begin : g_sd
  always @(posedge clk) sd[g] <= sd[g - 1];
end endgenerate
// the tap one clock early, then a register: only that register and the
// r_on mux sit in front of the upsamplers, as the synchroniser does today
reg  [3:0] sd_o = 4'd0;
always @(posedge clk) sd_o <= sd[w_sdly - 7'd2];

assign {o_r, o_g, o_b}                 = r_on ? f_rgb : {i_r, i_g, i_b};
assign {o_hs, o_vs, o_hires, o_shres}  = r_on ? sd_o  : {i_hs, i_vs, i_hires, i_shres};
endmodule

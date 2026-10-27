`timescale 1ns / 1ps
// pal_to_hd_upsample: the line-buffer ring between the Amiga picture (clk_in,
// clk_114, 15 / 31 kHz lines) and the 720p raster (clk_out, clk_148).
//
// The write side samples each input line into one of 16 line buffers
// (bram_tdp, 2048 words each) at a step from the measured line length; the
// read side shows each HD line the buffer the writer finished last but two
// (line rate), or source lines floor(y) and floor(y) + 1 of an exact 2.5x /
// 3x step (i_ratio).  Both restart at the input vsync, or at the virtual one
// VPOS moves; o_frame_end restarts the HD raster with them.  The CRT outputs
// (next line, line phase, resolution) feed crt_post.  Design notes:
// findings/scaler/plan.md; benches: sim/hdmi_upsample (golden.sh, run.sh,
// crt_run.sh, scaler_run.sh).
module pal_to_hd_upsample #(
  // One instance serves both HD rates (plan.md step 2): i_hz60 selects the
  // 60 Hz sample step / read window (H_RES) and read offset at run time.
  // H_RES keeps the old, odd values (1685 / 1980, backlog item 8): changing
  // them changes the picture.
  parameter PAL_OFFSET_HZ = 'h80,     // read offset, 50 Hz (i_hz60 = 0)
  parameter PAL_OFFSET_HZ60 = 'h80,   // ... 60 Hz
  parameter PAL_HD_H_RES  = 1980,     // sample step and read window, 50 Hz
  parameter PAL_HD_H_RES60 = 1980,    // ... 60 Hz
  parameter PAL_HD_H_FP   = 50,
  // CRT emulation (crt_post.v): 1 adds the next-line read for the two-line
  // beam on port B (in the clk_out cycle the picture path leaves idle), the
  // line phase and the per-line resolution.  o_hd_r/g/b are the same either way.
  parameter CRT           = 1,
  // Exact-ratio vertical stepping (plan.md step 4): source lines per HD line
  // and the y of HD line 0 (YB, see "Exact-ratio stepping"), in 1/2^20 line,
  // and the restart's move that centres the window (VPOS units, input lines;
  // negative = later)
  parameter [29:0] RATIO_STEP50 = 30'd419430,   // 2/5: 288 -> 720 (2.5x)
  parameter [29:0] RATIO_STEP60 = 30'd349525,   // 1/3: 240 -> 720 (3x)
  parameter signed [29:0] RATIO_YB50 = -30'sd2230230,   // -2.1269 lines
  parameter signed [29:0] RATIO_YB60 = -30'sd2195286,   // -2.0936
  parameter signed [7:0]  RATIO_VB50 = -8'sd20,
  parameter signed [7:0]  RATIO_VB60 = -8'sd18,
  // clk_out per input line, as 2^24 / T_line: T = 7264 clk_in (227 CCK,
  // PAL and NTSC alike on this core) = 9509.3 clk_out
  parameter [23:0] RATIO_TPH = 24'd1764,
  // the exact-ratio mode's read offset is this many HD pixels smaller
  // (crt_post's linear-light path is that much longer than its gamma path:
  // the picture then sits where the line-rate one does)
  parameter RATIO_RDX = 0,
  // RTG 1:1 (see "RTG 1:1"): 1 builds the per-pixel RTG path, 0 leaves RTG
  // on the time-based one; the pixel's latency after its strobe, in clk_in
  parameter RTG_1TO1 = 0,
  parameter int unsigned RTG_STB_LAT = 3,
  // ... where its picture sits: RTG_BASE* the read offset that puts a
  // line's first pixel at HD x 0 (holds pal_to_ddr's CRT_LAT and the
  // generator's window; the rtg* legs of scaler_run.sh calibrate it),
  // RTG_VB* the restart's move, in input lines (negative: later, the
  // picture up), that puts source line 0 of a 750-line mode with its vsync
  // 5 lines after the last active line (Picasso96 vert. sync pos 5) on HD
  // row 0 (the ring's lag otherwise puts it lower)
  parameter RTG_BASE50 = 0,
  parameter RTG_BASE60 = 0,
  parameter signed [7:0] RTG_VB50 = 8'sd0,
  parameter signed [7:0] RTG_VB60 = 8'sd0
)(
  // clocks
  input  logic        clk_in,        // the input picture (clk_114)
  input  logic        clk_out,       // the HD raster (clk_148)

  // clk_in domain: the input picture
  input  logic        reset,         // the sample enable's
  input  logic        i_pal_hsync,
  input  logic        i_pal_vsync,
  input  logic [7:0]  i_pal_r,
  input  logic [7:0]  i_pal_g,
  input  logic [7:0]  i_pal_b,
  // Denise BPLCON0 HIRES / SHRES (CLK_28 = dll_28, a phase-aligned sibling
  // of clk_in: timed, no synchroniser), sampled once per input line (CRT)
  input  logic        i_pal_hires,
  input  logic        i_pal_shres,
  // OSD Video Pos VPOS, signed: 64 us steps (one 15 kHz input line),
  // positive moves the picture down (see "Video Pos VPOS")
  input  logic [7:0]  i_hd_voffset,
  // ... the RTG 1:1 picture's own VPOS (same encoding), instead of i_hd_voffset there
  input  logic [7:0]  i_hd_voffset_rtg,
  // RTG 1:1 (see "RTG 1:1"): the RTG pixel strobe (minimig_virtual_top.v
  // VGA_PIXEL, one clock per pixel, blank-gated) and RTG on, synchronised
  input  logic        i_pix_stb,
  input  logic        i_rtg_1to1,

  // clk_out domain, inputs (i_hz60 / i_ring16 / i_ratio static, synchronised
  // into clk_in where the write side uses them)
  input  logic        i_hz60,        // 60 Hz HD timing
  input  logic        i_ring16,      // 1: all 16 line buffers, 0: the first 8 (line rate)
  input  logic        i_ratio,       // exact-ratio mode (needs i_ring16), static per frame
  input  logic        i_hd_hsync,
  input  logic        i_hd_vsync,
  input  logic        i_hd_clk,      // the HD pixel clock (one pixel = two clk_out)
  // OSD Video Pos HPOS, signed HD pixels: positive moves the picture right
  input  logic [7:0]  i_hd_hoffset,
  // ... the RTG 1:1 picture's own HPOS, instead of i_hd_hoffset there
  input  logic [7:0]  i_hd_hoffset_rtg,

  // clk_out domain, outputs
  output logic [7:0]  o_hd_r,
  output logic [7:0]  o_hd_g,
  output logic [7:0]  o_hd_b,
  output logic        o_hd_vsync,
  output logic        o_frame_end,   // restart the HD raster (signal_generator)
  output logic [23:0] o_hd_next,     // CRT: {b,g,r} of the NEXT input line, same x
  output logic        o_pix_stb,     // o_hd_* and o_hd_next hold a new pixel this clock
  output logic        o_line_start,  // one clock at the start of each HD line
  output logic [6:0]  o_line_phase,  // time from this HD line's buffer toggle, /128 clk_out
  output logic        o_line_hires,  // the input line this HD line shows was hires or superhires
  // exact-ratio mode: the HD line's centre below the centre of the line on
  // o_hd_r/g/b, in 1/256 line (the line on o_hd_next is the one below)
  output logic [7:0]  o_vphase
);

// ---------------------------------------------------------------------------
// Line-buffer ring (plan.md step 3; bench scaler_run.sh, ring legs): 16
// buffers of 2048 words, buffer k at {k, 11'b0}.  i_ring16 0 (line rate)
// keeps to buffers 0..7 and wraps every address in 14 bits: bit for bit the
// old 8-line ring, which matters for the lines inside vsync -- they do not
// advance the writer, their samples run on into the next buffers (7 -> 0 ->
// 1 -> 2), and the top of the next HD frame shows those.  A restart puts the
// writer at buffer 4 and the reader at 0 (line rate: four buffers apart);
// the exact-ratio reader keeps 2 <= lag <= 15 ("Exact-ratio stepping").
// ---------------------------------------------------------------------------
typedef logic [3:0] slot_t;

// the next buffer of a ring pointer: +1, wrapping 15 -> 0 (ring of 16) or
// 7 -> 0 (ring of 8)
function automatic slot_t next_slot(slot_t s, logic ring16);
  next_slot = (s != (ring16 ? 4'd15 : 4'd7)) ? s + 4'd1 : 4'd0;
endfunction

// where a line's read starts in buffer s: {s, 11'b0} - off, a 15-bit
// subtract in the ring of 16, a 14-bit one (zero-extended) in the ring of 8
function automatic logic [14:0] rd_start(slot_t s, logic [13:0] off, logic ring16);
  rd_start = ring16 ? {s, 11'b0} - {1'b0, off} : {1'b0, {s[2:0], 11'b0} - off};
endfunction

// the mode bits in clk_in
(* ASYNC_REG = "TRUE" *) logic [1:0] s_r16_in = 2'b00;
(* ASYNC_REG = "TRUE" *) logic [1:0] s_rat_in = 2'b00;
// (2026-10-15) A plain copy after the synchroniser: the line-end reload of
// r_addra depends on it, so it reaches every copy of r_addra next to every
// BRAM (stage_cdscaler2: s_rat_in[1] 264 loads, clk_114 -0.202 ns), and
// Vivado does not replicate an ASYNC_REG flop.  One clk_in more on a bit
// that only changes with the OSD setting.
(* max_fanout = 16 *) logic r_rat_in = 1'b0;
always_ff @(posedge clk_in) begin
  s_r16_in <= {s_r16_in[0], i_ring16};
  s_rat_in <= {s_rat_in[0], i_ratio};
  r_rat_in <= s_rat_in[1];
end
logic w_r16_in, w_rat_in, w_r16_o, w_rat_o;
assign w_r16_in = s_r16_in[1];     // clk_in
assign w_rat_in = r_rat_in;        // clk_in
assign w_r16_o  = i_ring16;        // clk_out
assign w_rat_o  = i_ratio;         // clk_out

// The line buffers: port A writes (clk_in), port B reads (clk_out)
logic        r_wea;
// (2026-10-09) The write address drives all line-buffer BRAMs; in
// stage_combo1 that was one register with 8.1 ns of pure routing to a far
// BRAM (clk_114 -0.147 ns).  max_fanout lets Vivado copy it next to each
// BRAM group (Quartus ignores the attribute).
(* max_fanout = 4 *) logic [14:0] r_addra = 15'd0;
logic [23:0] r_dina;
logic [14:0] r_addrb = 15'd0;
logic [14:0] w_addrb;     // port B address: r_addrb, or the next line's word (CRT)
logic [23:0] w_doutb;
logic [23:0] w_douta_unused;
bram_tdp #(
  .DATA(24),
  .ADDR(15)
) upsample_blk_ram (
  .a_clk(clk_in),
  .a_wr(r_wea),
  .a_addr(r_addra),
  .a_din(r_dina),
  .a_dout(w_douta_unused),
  .b_clk(clk_out),
  .b_wr(1'b0),
  .b_addr(w_addrb),
  .b_din(24'd0),
  .b_dout(w_doutb)
);

// The ring pointers, and the writer's line-end toggle into clk_out:
// s_next_buf[0] (clk_in) toggles at each input line end, [3:1] follow it in
// clk_out; a change of [3:2] is a buffer toggle (w_toggle)
slot_t      r_cur_write_buf = 4'd4;   // clk_in: the buffer the next input line goes to
slot_t      r_cur_read_buf  = 4'd0;   // clk_out: the line-rate read buffer
logic       r_next_buf      = 1'b0;   // clk_out: a toggle seen, the reader moves at the next HD line
logic       r_nb_tgl        = 1'b0;   // clk_in
(* ASYNC_REG = "TRUE" *)
logic [2:0] s_nb_o          = 3'd0;   // clk_out
logic [3:0] s_next_buf;
assign s_next_buf = {s_nb_o, r_nb_tgl};
logic       w_toggle;
assign w_toggle = (s_next_buf[3] != s_next_buf[2]);

// ---------------------------------------------------------------------------
// Write side (clk_in)
// ---------------------------------------------------------------------------
// input sync edges
logic [1:0] s_pal_hsync_in = 2'd0;
logic [1:0] s_pal_vsync_in = 2'd0;
logic       r_pal_hneg_in  = 1'b0;   // input hsync falling edge: a line ends
logic       r_pal_hpos_in  = 1'b0;   // ... rising edge
logic       r_pal_vneg_in  = 1'b0;   // input vsync falling edge
always_ff @(posedge clk_in) begin
  s_pal_hsync_in <= {s_pal_hsync_in[0], i_pal_hsync};
  s_pal_vsync_in <= {s_pal_vsync_in[0], i_pal_vsync};
  r_pal_hneg_in  <= (s_pal_hsync_in == 2'b10);
  r_pal_hpos_in  <= (s_pal_hsync_in == 2'b01);
  r_pal_vneg_in  <= (s_pal_vsync_in == 2'b10);
end

// The sample step: as many samples per input line as the output reads.
// r_line_count counts clk_in from the hsync's falling edge to its rising
// edge; there r_pix_clock_dev = (count / 64) / (H_RES >> 8) - 1, in quarter
// clk_in (the sample enable below steps 4 a clock).
localparam int unsigned DIV50 = PAL_HD_H_RES >> 8;
localparam int unsigned DIV60 = PAL_HD_H_RES60 >> 8;
// i_hz60 into clk_in: it only picks the divisor, read at input line ends
(* ASYNC_REG = "TRUE" *) logic [1:0] s_hz60_in = 2'b00;
logic        w_hz60_in;
assign w_hz60_in = s_hz60_in[1];
logic        r_line_active   = 1'b0;
logic [13:0] r_line_count    = 14'd0;
logic [5:0]  r_pix_clock_dev = 6'd0;
// the quotient kept mod 64 (6 bits): only the low six bits of quotient - 1
// were ever used (the old 12-bit v_div_var), and a difference's low bits do
// not depend on the width it is computed in
logic [7:0]  w_lc64;
logic [5:0]  w_div;
assign w_lc64 = r_line_count[13:6];
always_comb
  w_div = 6'(32'(w_lc64) / (w_hz60_in ? DIV60 : DIV50));
always_ff @(posedge clk_in) begin
  s_hz60_in <= {s_hz60_in[0], i_hz60};
  if (r_pal_hneg_in)
    r_line_active <= 1'b1;
  if (r_pal_hpos_in) begin
    r_line_active   <= 1'b0;
    r_line_count    <= 14'd0;
    r_pix_clock_dev <= w_div - 6'd1;
  end
  if (r_line_active)
    r_line_count <= r_line_count + 14'd1;
  else
    r_line_count <= 14'd0;
end

// the sample enable
logic [5:0] r_pix_clock_count = 6'd0;
logic       r_pix_en          = 1'b0;
always_ff @(posedge clk_in) begin
  if (reset)
    r_pix_clock_count <= 6'd0;
  else if (r_line_active) begin
    r_pix_clock_count <= r_pix_clock_count + 6'd4;
    r_pix_en <= 1'b0;
    if (r_pix_clock_count >= r_pix_clock_dev) begin
      r_pix_clock_count <= r_pix_clock_count - r_pix_clock_dev;
      r_pix_en <= 1'b1;
    end
  end else
    r_pix_clock_count <= 6'd0;
end

// How far each line buffer was written (2026-10-07): the buffers are never
// cleared and the reader reads a fixed stretch, so where the writer wrote
// less (a shorter line, another mode, the read offset reaching back into
// the previous buffer) old contents reached the screen.  r_wend[k] is the
// highest offset the last line written into buffer k reached; its pixels
// sit at offsets 1..r_wend (r_addra steps before it writes); the reader
// shows black outside.  r_wend is written ~4 lines before buffer k is read,
// so the clk_114 -> clk_148 crossing sees a settled value (wizard.xdc
// bounds the path).
slot_t       r_wslot = 4'd4;    // the buffer the current input line goes to
logic [10:0] r_wcnt  = 11'd0;   // pixels written into it so far
// r_wend and r_wres (below) power up 0 through a declaration initialiser:
// an always_ff variable may not be written by another process, an initial
// loop included (IEEE 1800 9.2.2.4).  iverilog 12 and Yosys 0.33 cannot
// parse an unpacked-array initialiser and do not check that rule, so they
// keep the loop.
`ifdef __ICARUS__
 `define P2HU_ARRAY_INIT_LOOP
`elsif YOSYS
 `define P2HU_ARRAY_INIT_LOOP
`endif
`ifdef P2HU_ARRAY_INIT_LOOP
logic [10:0] r_wend [0:15];
initial for (int k = 0; k < 16; k++) r_wend[k] = 11'd0;
`else
logic [10:0] r_wend [0:15] = '{default: 11'd0};
`endif

// ---------------------------------------------------------------------------
// RTG 1:1 (bench scaler_run.sh rtg* legs, rtg_check.py).  With RTG_1TO1
// and i_rtg_1to1 the write side takes one word per RTG pixel instead of
// sampling by time: the RTG pixel strobe, delayed by RTG_STB_LAT, writes;
// the DDA above runs on unused, and the line_active / hsync gates do not
// apply (the strobe only comes in the active area).  The pixel is in
// minimig_virtual_top's red/green/blue_reg 3 clk_114 after its strobe in
// the 16-bit modes, 4 in the CLUT modes (one more register stage): those
// show one pixel to the right, the first column black (known, pinned by the
// rtglat4 leg).  (A reading of VideoStream.vhd gives 1 for the 16-bit
// modes: the board decides; 3 as briefed.)  crt_beamh is bypassed with
// RTG, combinationally (no delay).  The line's words are W = the widest
// line of the frame (r_wcnt at the line ends, latched at the frame's
// restart); the read side centres them ("RTG read").  Vertically the
// line-rate ring as before; the restart moves by RTG_VB* input lines plus
// the RTG picture's own VPOS (i_hd_voffset_rtg instead of the chipset's;
// "Video Pos VPOS").
// ---------------------------------------------------------------------------
logic [RTG_STB_LAT-1:0] r_stb_d = '0;
always_ff @(posedge clk_in)
  r_stb_d <= RTG_STB_LAT'({r_stb_d, i_pix_stb});
logic w_rtg_1to1;   // the per-pixel path is built in (RTG_1TO1) and asked for
assign w_rtg_1to1 = (RTG_1TO1 != 0) && i_rtg_1to1;
logic w_wr;   // write the sample now
assign w_wr = w_rtg_1to1 ? r_stb_d[RTG_STB_LAT-1] : (r_pix_en && ~i_pal_hsync);

logic w_vp_wr_reset;   // the write side's restart (Video Pos VPOS, below)
logic w_line_end;      // an input line ends (in the exact-ratio mode every
                       // line, vsync or not: its reader counts lines by time)
assign w_line_end = r_pal_hneg_in && (~i_pal_vsync || w_rat_in);

// The written extent W (clk_in): r_rtg_wmax the widest line so far in this
// frame, r_rtg_w / r_rtg_on the last frame's W and whether it was written
// 1:1.  Both change only at the write side's restart (and W only with the
// mode); clk_out reads them through r_rd_off at the HD lines' starts.  An
// HD line that starts within the clock or two of the change is the old
// frame's last, in the HD vertical blank (the read side restarts the HD
// raster a 2-3 clk_out synchroniser later): like r_wend they are settled
// wherever they are shown (wizard.xdc bounds the clk_114 -> clk_148 path).
logic [10:0] r_rtg_wmax = 11'd0;
logic [10:0] r_rtg_w    = 11'd0;
logic        r_rtg_on   = 1'b0;
always_ff @(posedge clk_in) begin
  if (w_line_end && r_wcnt > r_rtg_wmax)
    r_rtg_wmax <= r_wcnt;
  if (w_vp_wr_reset) begin
    r_rtg_w    <= r_rtg_wmax;
    r_rtg_on   <= w_rtg_1to1;
    r_rtg_wmax <= 11'd0;
  end
end

always_ff @(posedge clk_in) begin
  r_wea <= 1'b0;
  if (w_wr) begin
    // (2026-10-15) Bits 13:0 count the same in both rings; only bit 14
    // (the ring of 16's carry) depends on w_r16_in.  Written as a mux of
    // two 15-bit sums, the synchroniser flop fed every copy of r_addra next
    // to every BRAM (stage_cdscaler clk_114 -0.403 ns, 23 endpoints, 8.3 ns
    // of routing from s_r16_in[1]).
    r_addra <= {w_r16_in & (r_addra[14] ^ &r_addra[13:0]), r_addra[13:0] + 14'd1};
    r_wea   <= 1'b1;
    r_dina  <= {i_pal_b, i_pal_g, i_pal_r};
    if (r_wcnt != 11'h7FF)
      r_wcnt <= r_wcnt + 11'd1;
  end
  if (w_line_end) begin
    // the line just ended went to r_wslot; the next goes to r_cur_write_buf
    r_wend[r_wslot] <= r_wcnt;
    r_wslot         <= r_cur_write_buf;
    r_wcnt          <= 11'd0;
    r_nb_tgl        <= ~r_nb_tgl;
    r_cur_write_buf <= next_slot(r_cur_write_buf, w_r16_in);
    r_addra         <= {r_cur_write_buf, 11'b0};
  end
  if (w_vp_wr_reset)
    r_cur_write_buf <= 4'd4;
end

// ---------------------------------------------------------------------------
// Video Pos VPOS (bench crt_run.sh legs vpos*; golden.sh vp*, vm*, vchg).
// VPOS s moves the restart by s input lines (2s at 31 kHz): s < 0 |s| lines
// after the real negedge at its offset in the line (r_vp_p0), s > 0 s lines
// before the next one, predicted from two fields back (r_vp_n2, r_vp_p1), so
// interlaced fields still interleave.  The HD frame (~749 lines) must still
// hold its vsync: a restart under N - M input lines after the last one is
// deferred there, none waits past N + M, and one under N / 2 is ignored (N:
// the last field's lines, M = VP_M, 2M at 31 kHz); bigger moves glide M
// lines a frame.  VPOS 0 is the real negedge (r_vp_real) unless the last
// restart was virtual; the first three fields use it (nothing measured).
// Decisions are taken at input hsyncs, never near a vsync edge, so clk_out
// sees a settled r_vp_real; other restarts toggle r_vp_tgl into clk_out.
// ---------------------------------------------------------------------------
localparam signed [11:0] VP_M = 12'sd5;
// the exact-ratio modes add their centring move to VPOS (step 4)
logic [7:0]  r_vp_bias  = 8'd0;
always_ff @(posedge clk_in)
  r_vp_bias <= !w_rat_in ? 8'd0 : w_hz60_in ? RATIO_VB60 : RATIO_VB50;
// RTG 1:1 adds its move in input lines, after VPOS's 31 kHz doubling
logic [7:0]  r_vp_lb    = 8'd0;
always_ff @(posedge clk_in)
  r_vp_lb <= !w_rtg_1to1 ? 8'd0 : w_hz60_in ? RTG_VB60 : RTG_VB50;
logic [7:0]  r_vp_s     = 8'd0;     // VPOS, taken at each input hsync
logic [1:0]  r_vp_seen  = 2'd0;     // real vsync negedges seen (to 3)
logic [1:0]  r_vp_seenl = 2'd0;     // ... taken at each input hsync
logic [10:0] r_vp_cnt   = 11'd0;    // input hsyncs since the real negedge
logic [12:0] r_vp_cyc   = 13'h1FFF; // clk_in since the last input hsync
logic [10:0] r_vp_n1    = 11'd0;    // input hsyncs in the last field
logic [10:0] r_vp_n2    = 11'd0;    // ... in the one before
logic [12:0] r_vp_p0    = 13'd0;    // this field's negedge, clk_in after its line's hsync
logic [12:0] r_vp_p1    = 13'd0;    // ... the last field's
logic [10:0] r_vp_n     = 11'd0;    // r_vp_n1 taken at each input hsync
logic        r_vp_dbl   = 1'b0;     // 31 kHz input (> 400 lines a field)
logic [10:0] r_vp_since = 11'h7FF;  // input hsyncs since the restart's line
logic        r_vp_fline = 1'b0;     // a restart happened in this input line
logic        r_vp_pend  = 1'b0;     // a restart deferred (frame too short)
logic        r_vp_hsd   = 1'b0;     // the clock after an input hsync
logic        r_vp_real  = 1'b1;     // the next restart is the real negedge
logic        r_vp_vlast = 1'b0;     // the last restart was a virtual one
logic signed [11:0] r_vp_tgt = 12'sd0;  // target: input hsyncs since the negedge
logic [12:0] r_vp_ph    = 13'd0;    // ... and clk_in after that hsync
logic        r_vp_lvl   = 1'b0;     // at or past the target
logic        r_vp_fire  = 1'b0;     // a restart other than the real negedge
logic        r_vp_tgl   = 1'b0;     // toggles with r_vp_fire, to clk_out
logic signed [11:0] r_vp_lo = 12'sd0, r_vp_hi = 12'sd0, r_vp_half = 12'sd0;

logic signed [10:0] w_vp_su;   // the move in input lines
logic               w_vp_zero, w_vp_free, w_vp_ok, w_vp_wd, w_vp_lvl, w_vp_x, w_vp_realf;
logic signed [11:0] w_vp_g;
assign w_vp_su    = (r_vp_dbl ? {{2{r_vp_s[7]}}, r_vp_s, 1'b0} : {{3{r_vp_s[7]}}, r_vp_s}) +
                    {{3{r_vp_lb[7]}}, r_vp_lb};
assign w_vp_zero  = (w_vp_su == 11'sd0) || (r_vp_seenl != 2'd3);
assign w_vp_free  = w_vp_zero && !r_vp_vlast;   // the real negedge, no rules
assign w_vp_g     = {1'b0, r_vp_since};
assign w_vp_ok    = w_vp_g >= r_vp_lo;                                          // late enough
assign w_vp_wd    = (w_vp_g >= r_vp_hi) && (r_vp_seenl >= 2'd2) && !w_vp_free;  // waited too long
assign w_vp_lvl   = ($signed({1'b0, r_vp_cnt}) > r_vp_tgt) ||
                    ($signed({1'b0, r_vp_cnt}) == r_vp_tgt && r_vp_cyc >= r_vp_ph);
// this field's target: the real negedge (VPOS 0), or the virtual one
assign w_vp_x     = w_vp_zero ? r_pal_vneg_in : (w_vp_lvl && !r_vp_lvl);
assign w_vp_realf = r_pal_vneg_in && r_vp_real;
assign w_vp_wr_reset = w_vp_realf || r_vp_fire;

// Measure: where the input is (hsyncs since the real negedge, clk_in since
// the hsync), and at each real negedge the last two fields
always_ff @(posedge clk_in) begin
  r_vp_cyc <= (r_vp_cyc != 13'h1FFF) ? r_vp_cyc + 13'd1 : r_vp_cyc;
  if (r_pal_hneg_in) begin
    r_vp_cyc <= 13'd0;
    if (r_vp_cnt != 11'h7FF) r_vp_cnt <= r_vp_cnt + 11'd1;
  end
  if (r_pal_vneg_in) begin
    r_vp_cnt  <= 11'd0;
    r_vp_n1   <= r_vp_cnt;
    r_vp_n2   <= r_vp_n1;
    r_vp_p0   <= r_vp_cyc;
    r_vp_p1   <= r_vp_p0;
    if (r_vp_seen != 2'd3) r_vp_seen <= r_vp_seen + 2'd1;
  end
end

// Decide: the decision inputs, taken at each input hsync; the window, the
// choice of the real negedge (r_vp_real), the target
always_ff @(posedge clk_in) begin
  r_vp_hsd <= r_pal_hneg_in;
  if (r_pal_hneg_in) begin
    r_vp_s     <= (w_rtg_1to1 ? i_hd_voffset_rtg : i_hd_voffset) + r_vp_bias;
    r_vp_seenl <= r_vp_seen;
    r_vp_n     <= r_vp_n1;
    r_vp_dbl   <= (r_vp_n1 > 11'd400);
    r_vp_fline <= 1'b0;
    r_vp_since <= r_vp_fline ? 11'd0 : (r_vp_since != 11'h7FF) ? r_vp_since + 11'd1 : r_vp_since;
  end
  // r_vp_since counts from the line after the restart's: a restart in the
  // line where it reaches X is X + 1 lines after the last one
  r_vp_lo   <= $signed({1'b0, r_vp_n}) - (r_vp_dbl ? 2 * VP_M + 1 : VP_M + 1);   // N - M - 1
  r_vp_hi   <= $signed({1'b0, r_vp_n}) + (r_vp_dbl ? 2 * VP_M - 1 : VP_M - 1);   // N + M - 1
  r_vp_half <= $signed({2'b0, r_vp_n[10:1]});
  if (r_vp_hsd)
    r_vp_real <= w_vp_free || (w_vp_zero && w_vp_ok && !w_vp_wd);

  // the target
  if (w_vp_su[10]) begin
    r_vp_tgt <= -$signed({w_vp_su[10], w_vp_su});
    r_vp_ph  <= r_vp_p0;
  end else begin
    r_vp_tgt <= $signed({1'b0, r_vp_n2}) - $signed({w_vp_su[10], w_vp_su});
    r_vp_ph  <= r_vp_p1;
  end
  r_vp_lvl <= w_vp_lvl;

  // a restart in this line (after the hsync's clear above: it wins)
  if (w_vp_realf || r_vp_fire)
    r_vp_fline <= 1'b1;
end

// Fire: the restarts other than the real negedge
always_ff @(posedge clk_in) begin
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
    r_vp_vlast <= r_vp_fire;
  end
  if (r_vp_fire) r_vp_tgl <= ~r_vp_tgl;
end

// ---------------------------------------------------------------------------
// Read side (clk_out)
// ---------------------------------------------------------------------------
// the input vsync's falling edge (the read side's restart, r_vp_real)
(* ASYNC_REG = "TRUE" *) logic [2:0] s_pal_vsync;
logic r_pal_vneg = 1'b0;
always_ff @(posedge clk_out) begin
  s_pal_vsync <= {s_pal_vsync[1:0], i_pal_vsync};
  r_pal_vneg  <= (s_pal_vsync[2:1] == 2'b10);
end

// the restart: the real negedge while r_vp_real, or a toggle of r_vp_tgl
(* ASYNC_REG = "TRUE" *) logic [1:0] s_vp_real_o = 2'b11;
(* ASYNC_REG = "TRUE" *) logic [2:0] s_vp_tgl_o  = 3'b000;
logic w_vp_virt_o, w_vp_ev_o;
logic r_frame_end = 1'b0;
always_ff @(posedge clk_out) begin
  s_vp_real_o <= {s_vp_real_o[0], r_vp_real};
  s_vp_tgl_o  <= {s_vp_tgl_o[1:0], r_vp_tgl};
  r_frame_end <= w_vp_ev_o;
end
assign w_vp_virt_o = (s_vp_tgl_o[2] != s_vp_tgl_o[1]);
assign w_vp_ev_o   = (r_pal_vneg && s_vp_real_o[1]) || w_vp_virt_o;

// HD hsync's falling edge (the next line)
(* ASYNC_REG = "TRUE" *) logic [1:0] s_hd_hsync;
logic hd_hsync_negedge = 1'b0;
always_ff @(posedge clk_out) begin
  s_hd_hsync       <= {s_hd_hsync[0], i_hd_hsync};
  hd_hsync_negedge <= (s_hd_hsync == 2'b10);
end

// where a line's read starts: the fixed offset plus the OSD's signed one,
// registered (static), so each line starts at {buffer, 11'b0} - r_rd_off;
// the read window's end (H_RES - FP), registered alike.  The sums are taken
// in the registers' widths (their low bits do not depend on wider ones).
localparam logic [13:0] OFF50 = 14'(PAL_OFFSET_HZ);
localparam logic [13:0] OFF60 = 14'(PAL_OFFSET_HZ60);
localparam logic [13:0] RDX   = 14'(RATIO_RDX);
localparam logic [11:0] WIN50 = 12'(PAL_HD_H_RES - PAL_HD_H_FP);
localparam logic [11:0] WIN60 = 12'(PAL_HD_H_RES60 - PAL_HD_H_FP);
// RTG read (RTG 1:1 above): RTG_BASE* puts ring word 1 (a line's first
// pixel) at HD x 0; the frame's W words then start at HD x0 = (1280 - W) /
// 2, so the offset grows by x0 (W > 1280: x0 < 0, a centred crop; the read
// window and r_wend black the rest), and by the RTG picture's own HPOS
// (i_hd_hoffset_rtg) instead of the chipset's.
localparam logic [13:0] RB50 = 14'(RTG_BASE50);
localparam logic [13:0] RB60 = 14'(RTG_BASE60);
logic signed [12:0] w_rtg_x0;
assign w_rtg_x0 = $signed(13'd1280 - {2'b00, r_rtg_w}) >>> 1;
logic [13:0] r_rd_off  = OFF50;
logic [11:0] r_win_end = WIN50;
always_ff @(posedge clk_out) begin
  r_rd_off  <= r_rtg_on ? (i_hz60 ? RB60 : RB50) + {w_rtg_x0[12], w_rtg_x0}
                         + {{6{i_hd_hoffset_rtg[7]}}, i_hd_hoffset_rtg}
                       : (i_hz60 ? OFF60 : OFF50) + {{6{i_hd_hoffset[7]}}, i_hd_hoffset}
                         - (i_ratio ? RDX : 14'd0);
  r_win_end <= i_hz60 ? WIN60 : WIN50;
end

// ---------------------------------------------------------------------------
// Exact-ratio stepping (plan.md step 4; bench scaler_run.sh).  i_ratio 1
// shows 2.5x (PAL 288 -> 720) or 3x (NTSC 240 -> 720): y, in input lines
// since the restart's first written line, steps RATIO_STEP (2/5, 1/3) per HD
// line; the line shows a = floor(y) (o_hd_*) and a + 1 (o_hd_next) at phase
// frac(y) (o_vphase) from slot (4 + a) mod 16 -- in this mode the writer
// advances on every input line, so a line's slot is its number; a < 0 is
// black.  Down a frame the reader falls ~12 lines behind (60 Hz ~10) and
// must keep 2 <= lag <= 15: y0 = YB - p, p = 1 - r_tph the restart's time to
// the next line, keeps the lag the same in every field and interleaves them.
// ---------------------------------------------------------------------------
logic [23:0]        r_tph     = 24'd0;    // input-line fraction since the last toggle
logic signed [29:0] r_y0      = 30'sd0;   // y of HD line 0 if the restart were now
logic signed [29:0] r_yn      = 30'sd0;   // y of the next HD line
logic [4:0]         r_ryg     = 5'd0;     // clocks since a restart, to 31
slot_t              r_ry_slot = 4'd0;     // r_yn's slot
logic               r_yn_neg  = 1'b0;     // r_yn < 0 (line a before the frame)
logic               r_yn_neg2 = 1'b0;     // r_yn < -1 (line a + 1 too)
logic               r_cblank  = 1'b0;     // this HD line: o_hd_* black
logic               r_nblank  = 1'b0;     // ... o_hd_next black
logic [7:0]         r_vph     = 8'd0;     // this HD line's phase
`ifndef SYNTHESIS
// this HD line's y, for sim/hdmi_upsample/tb_crt_frame only (a = r_yl[29:20])
/* verilator lint_off UNUSEDSIGNAL */
logic [29:0]        r_yl      = 30'd0;
/* verilator lint_on UNUSEDSIGNAL */
`endif
always_ff @(posedge clk_out) begin
  r_tph <= w_toggle ? 24'd0 : r_tph + RATIO_TPH;
  r_y0  <= (i_hz60 ? RATIO_YB60 : RATIO_YB50) - (30'sd1 <<< 20) + $signed({10'd0, r_tph[23:4]});
  if (r_ryg != 5'd31) r_ryg <= r_ryg + 5'd1;
  r_ry_slot <= 4'd4 + r_yn[23:20];
  r_yn_neg  <= r_yn[29];
  r_yn_neg2 <= (r_yn < -30'sd1048576);
  // The restart's first HD hsync falling edge belongs to line 0 -- except a
  // spurious one a few clocks after the restart (the generator restarts mid
  // hsync), which must not use up line 0's y: none counts within 31 clocks.
  if (w_vp_ev_o) begin
    r_yn  <= r_y0;
    r_ryg <= 5'd0;
  end else if (hd_hsync_negedge && r_ryg == 5'd31)
    r_yn  <= r_yn + $signed(i_hz60 ? RATIO_STEP60 : RATIO_STEP50);
  if (hd_hsync_negedge) begin
    r_cblank <= w_rat_o && r_yn_neg;
    r_nblank <= w_rat_o && r_yn_neg2;
    r_vph    <= r_yn[19:12];
`ifndef SYNTHESIS
    r_yl     <= r_yn;
`endif
  end
end
assign o_vphase = r_vph;

// The read: the buffer this HD line reads (r_yn's slot in the exact-ratio
// mode, else the read pointer), and how far it was written (r_wend)
slot_t       w_rd_slot;
assign w_rd_slot = w_rat_o ? r_ry_slot : r_cur_read_buf;
logic        r_hd_clk_;
logic        w_hdfall, w_upd, w_in_win;
logic [11:0] r_h_pos = 12'd0;
slot_t       r_rslot = 4'd0;
logic [10:0] r_rend  = 11'd0;
logic [7:0]  r_hd_r, r_hd_g, r_hd_b;
assign w_hdfall = (r_hd_clk_ == 1'b1 && i_hd_clk == 1'b0);   // the update clock, sync or not
assign w_upd    = w_hdfall && ~i_hd_hsync;
assign w_in_win = (r_h_pos > PAL_HD_H_FP && r_h_pos < r_win_end);
// the word w_doutb holds belongs to r_addrb (one-clock BRAM read, and
// r_addrb moves only every other clk_out): inside this line's buffer and
// inside what the write side reached?
logic w_rd_valid;
assign w_rd_valid = (r_addrb[14:11] == r_rslot) && (r_addrb[10:0] != 11'd0) &&
                    (r_addrb[10:0] <= r_rend);
always_ff @(posedge clk_out) begin
  // the writer's line-end toggle
  s_nb_o <= s_next_buf[2:0];
  if (w_toggle)
    r_next_buf <= 1'b1;

  r_hd_clk_ <= i_hd_clk;
  if (w_upd) begin
    r_h_pos <= r_h_pos + 12'd1;
    if (w_in_win) begin
      r_addrb <= w_r16_o ? r_addrb + 15'd1 : {1'b0, r_addrb[13:0] + 14'd1};
      // black (border) for a word this line's input did not write, and
      // in the exact-ratio mode for a line before the frame's first
      r_hd_r <= (w_rd_valid && !r_cblank) ? w_doutb[0 +: 8]  : 8'd0;
      r_hd_g <= (w_rd_valid && !r_cblank) ? w_doutb[8 +: 8]  : 8'd0;
      r_hd_b <= (w_rd_valid && !r_cblank) ? w_doutb[16 +: 8] : 8'd0;
    end else begin
      r_hd_r <= 8'd0;
      r_hd_g <= 8'd0;
      r_hd_b <= 8'd0;
    end
  end

  // the next HD line
  if (hd_hsync_negedge) begin
    if (r_next_buf) begin
      r_next_buf     <= 1'b0;
      r_cur_read_buf <= next_slot(r_cur_read_buf, w_r16_o);
    end
    r_h_pos <= 12'd0;
    r_rslot <= w_rd_slot;
    r_rend  <= r_wend[w_rd_slot];
    // the ring of 8 starts from the read pointer even with i_ratio (which
    // needs i_ring16), exactly as before
    r_addrb <= rd_start(w_r16_o ? w_rd_slot : r_cur_read_buf, r_rd_off, w_r16_o);
  end

  // the restart: the read side starts at buffer 0, four behind the writer
  if (w_vp_ev_o)
    r_cur_read_buf <= 4'd0;
  // A virtual restart can follow an input line end closely (at 31 kHz the
  // bench's comes 32 clk_in after one); that line's buffer toggle, still
  // pending, would move the reader to buffer 1 at once and the picture
  // one input line up.  The real negedge's line end lies inside vsync (no
  // toggle), so only the virtual path drops it.
  if (w_vp_virt_o)
    r_next_buf <= 1'b0;
end
assign o_hd_r = r_hd_r;
assign o_hd_g = r_hd_g;
assign o_hd_b = r_hd_b;
assign o_frame_end = r_frame_end;

// ---------------------------------------------------------------------------
// CRT emulation (2026-10-09; study and bench: sim/hdmi_upsample/crt_*)
//
// 1. Next-line read for the two-line beam.  r_addrb moves every other
//    clk_out (one HD pixel = two clk_out); the read in the update clock
//    (w_upd) is never used by the picture path (its data arrives after
//    r_addrb has moved), so it fetches the same x from the NEXT buffer
//    (+0x800 wraps 15 -> 0, or 7 -> 0, like the ring).  Captured one clock
//    later into r_hd_next; black where the next buffer was not written.
// 2. Line phase: the HD line's vertical position inside the input line it
//    shows, in time.  r_c_new counts clk_out since the latest buffer toggle,
//    r_c_old since the one before; an HD line whose hsync sees r_next_buf
//    (toggle pending) still shows the older buffer -> r_c_old, else r_c_new.
//    Range T_hd .. T_hd + T_line (PAL 50: 3960 .. 13464 clk_out).
//    Interlaced long fields restart half a line later, so their lines'
//    phases move by ~0.5 input line and the fields' scanlines interleave.
// 3. Resolution per input line: HIRES|SHRES sampled 512 pixels into the
//    line (mid-screen, past any hblank), stored next to r_wend.
// ---------------------------------------------------------------------------
logic [1:0] r_res_s    = 2'b00;
logic       r_res_line = 1'b0;
`ifdef P2HU_ARRAY_INIT_LOOP
logic       r_wres [0:15];
initial for (int k = 0; k < 16; k++) r_wres[k] = 1'b0;
`undef P2HU_ARRAY_INIT_LOOP
`else
logic       r_wres [0:15] = '{default: 1'b0};
`endif
always_ff @(posedge clk_in) begin
  r_res_s <= {i_pal_shres, i_pal_hires};
  if (r_wcnt == 11'd512) r_res_line <= |r_res_s;
  // same moment and slot as r_wend (end of the input line)
  if (w_line_end) r_wres[r_wslot] <= r_res_line;
end

// The next buffer: in the ring of 16 (and the exact-ratio mode) slot + 1
// wraps 15 -> 0 by its width, which is next_slot(s, 1).  In the ring of 8
// {0, slot[2:0] + 1} is next_slot(s, 0) only for slots 0..7 and 15: a
// pointer left at 8..14 by an i_ring16 change gives 1..7 here, where
// next_slot would give 9..15.  Kept as it was.
logic [10:0] r_rend2 = 11'd0;   // written extent of the next buffer
always_ff @(posedge clk_out)
  if (hd_hsync_negedge) r_rend2 <= r_wend[(w_rat_o || w_r16_o) ? next_slot(w_rd_slot, 1'b1) :
                                          {1'b0, r_cur_read_buf[2:0] + 3'd1}];
logic w_rd_valid2;
assign w_rd_valid2 = (r_addrb[14:11] == r_rslot) && (r_addrb[10:0] != 11'd0) &&
                     (r_addrb[10:0] <= r_rend2);
// The second read goes out in every update clock, hsync or not: the
// picture path never uses that clock's read, and leaving i_hd_hsync out
// keeps the 60 Hz path's hsync (from adv_ddr, far away) off the line
// buffer's address pins (1.4 ns OOC slack with it, 2026-10-09).  The
// capture below is still qualified with w_upd.
assign w_addrb = (CRT && w_hdfall) ? (w_r16_o ? r_addrb + 15'h0800 : {1'b0, r_addrb[13:0] + 14'h0800}) : r_addrb;

logic        r_nxt_cap = 1'b0;   // w_doutb holds the next line's word this clock
logic        r_nxt_ok  = 1'b0;   // ... and it is inside window and written extent
logic [23:0] r_hd_next = 24'd0;
always_ff @(posedge clk_out) begin
  r_nxt_cap <= CRT && w_upd;
  r_nxt_ok  <= w_in_win && w_rd_valid2 && !r_nblank;
  if (r_nxt_cap) r_hd_next <= r_nxt_ok ? w_doutb : 24'd0;
end
// in the update clock both r_hd_* (this line) and r_hd_next hold the pixel
// made one update earlier; crt_post samples them here
assign o_pix_stb = w_upd;
assign o_hd_next = CRT ? r_hd_next : 24'd0;

logic [13:0] r_c_new = 14'h3FFF, r_c_old = 14'h3FFF;
logic [6:0]  r_lphase = 7'd0;   // the line's phase, /128 (bits 13:7 of the count)
logic        r_line_start = 1'b0;
logic        r_lres = 1'b0;
always_ff @(posedge clk_out) begin
  if (w_toggle) begin
    r_c_old <= (r_c_new == 14'h3FFF) ? r_c_new : r_c_new + 14'd1;
    r_c_new <= 14'd0;
  end else begin
    if (r_c_new != 14'h3FFF) r_c_new <= r_c_new + 14'd1;
    if (r_c_old != 14'h3FFF) r_c_old <= r_c_old + 14'd1;
  end
  r_line_start <= hd_hsync_negedge;
  if (hd_hsync_negedge) begin
    r_lphase <= r_next_buf ? r_c_old[13:7] : r_c_new[13:7];
    r_lres   <= r_wres[w_rd_slot];   // the buffer this line reads (r_rslot)
  end
end
assign o_line_phase = r_lphase;
assign o_line_start = r_line_start;
assign o_line_hires = CRT ? r_lres : 1'b0;

// ---------------------------------------------------------------------------
// o_hd_vsync: the HD vsync, two clk_out later (the generator's vsync lines sit
// against its active window as the display needs them; until 2026-10-27 this
// delayed it 10 HD lines to suit adv_ddr's own regenerated DE)
// ---------------------------------------------------------------------------
(* ASYNC_REG = "TRUE" *) logic [1:0] s_hd_vsync;
always_ff @(posedge clk_out)
  s_hd_vsync <= {s_hd_vsync[0], i_hd_vsync};
assign o_hd_vsync = s_hd_vsync[1];

endmodule

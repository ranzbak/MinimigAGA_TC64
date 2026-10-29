// tb_frame_freq.v -- frame_freq.sv (pal_to_ddr's 50/60 Hz decision) against
// the chain it replaced: ref/frame_freq_ref.v (the old frame_freq.v) plus a
// copy of pal_to_ddr.sv's old r_50hz / r_60hz block.  Both see the same
// i_vsync.  At EVERY clock, reset included, o_hz60 must equal ~r_50hz of the
// old chain (pal_to_ddr's w_hz60; before its first decision r_50hz is 0),
// and after the old chain's first decision of a run exactly one of r_50hz /
// r_60hz must be set (o_valid stays 1).  Any difference = FAIL with the
// period and the clock -- with two modelled artefacts of the old counter
// that frame_freq.sv does not reproduce:
//
// - it did not clear r_us_en at a frame end, so after a frame whose period
//   was a multiple of 149 clocks it counted one "us" (149 clocks) too many;
// - one clock after its us counter wrapped (1000 -> 0) its ms count was not
//   yet incremented, so a frame end on that clock read one ms low.
// The bench computes the old latch exactly from the period P and the
// previous period Pp (old_lat below), takes the old decision from it, and
// where that differs from the plain window (new_60) expects the new level to
// be the old one inverted for exactly that decision; it lists each such
// frame.  Everything else must match as it is.  run.sh's sweeps have two
// such frames each: lo / hi the 149*k case, lo13 / hi20 (+center=1937003 /
// 2980003) the wrap case.  The model also covers both at once (1936854 /
// 2979854 after a 149*k frame), which no leg drives.
//
// Legs (+leg=NAME, one run each, reset at the start):
//   lo, hi   every period from C-H to C+H clocks around C (+center=N, default
//            the lower / upper window edge HZ60_MIN / HZ60_MAX; +half=H,
//            default 400, at most 400), each period for two frames: the
//            first one follows a frame one clock shorter, the second one an
//            equal frame
//   std      PAL 20.0 ms, NTSC 16.68 ms, 55, 70, 100, 48, 23 and 30 Hz, four
//            frames each
//   switch   PAL -> NTSC -> PAL, five frames each
// The old chain's decision moments are printed: every change of its level
// with the measured period (std, switch), and for lo / hi the periods at
// which its decision for each of the two frame kinds changes.
//
// clk is clk_148 (148.5 MHz); one clock per 2 ns here, the rate itself does
// not matter.  i_vsync is high for VS_W clocks at the start of each frame.
// A boundary sweep is 3-5 G clocks: run.sh builds it with Verilator and
// -DTB_EXT_CLK (clk from a C++ loop, ~17 M clocks/s); it also builds under
// iverilog -g2012 (about 0.3 M clocks/s: std / switch only).
`timescale 1ns/1ps
`ifdef TB_EXT_CLK
module tb_frame_freq (input clk);   // run.sh: Verilator, clk from a C++ loop
reg reset = 1'b1, vs = 1'b0;
`else
module tb_frame_freq;
reg clk = 1'b0, reset = 1'b1, vs = 1'b0;
always #1 clk = ~clk;
`endif

localparam VS_W  = 1000;
localparam HALF  = 400;       // the largest +half
integer    half  = HALF;
// The old chain's 60 Hz window in clocks of period (this bench's lo / hi
// sweeps print it; frame_freq.sv's HZ60_MIN / HZ60_MAX), and its "us".
localparam OLD_MIN = 1862651;
localparam OLD_MAX = 2905651;
localparam OLD_US  = 149;

// The old chain: frame_freq_ref and pal_to_ddr.sv's block, as they were.
wire [7:0] cur_fps;
wire       fps_valid;
reg        r_50hz = 1'b0;
reg        r_60hz = 1'b0;
frame_freq_ref old_ff (
  .clk(clk),
  .reset(reset),
  .i_vsync(vs),
  .o_freq(cur_fps[6:0]),
  .o_valid(fps_valid)
);
assign cur_fps[7] = 1'b0;
always @(posedge clk)
begin
  r_50hz <= 1'b0;
  r_60hz <= 1'b0;
  if (fps_valid == 1'b1)
  begin
    if (cur_fps < 53)
      r_50hz <= 1'b1;
    else
      r_60hz <= 1'b1;
  end
end

// The new module.
wire hz60;
frame_freq dut (
  .clk(clk),
  .reset(reset),
  .i_vsync(vs),
  .o_hz60(hz60)
);

// The frame sequence of the leg: period_of(n) is frame n's period in clocks
// (frame 0 starts 4 clocks after reset), 0 after the last frame.
//   lo / hi: frame 0 = C-H-1, frames 2i+1 and 2i+2 = C-H+i (i = 0 .. 2H),
//   then one frame C+H+1 (its start ends the last measured frame)
integer leg_id = 0;      // 0 lo / hi, 1 std, 2 switch
integer center = 0;
integer stds [0:7];      // clk_148 periods of the standards (148.5 MHz)
initial
begin
  stds[0] = 2970000;     // PAL 20.0 ms
  stds[1] = 2476980;     // NTSC 16.68 ms
  stds[2] = 2700000;     // 55 Hz
  stds[3] = 2121429;     // 70 Hz
  stds[4] = 1485000;     // 100 Hz
  stds[5] = 3093750;     // 48 Hz
  stds[6] = 6456522;     // 23 Hz
  stds[7] = 4950000;     // 30 Hz
end
integer nsw = 2 * (2 * HALF + 1);      // the sweep's frames 1 .. nsw
function integer period_of(input integer n);
begin
  period_of = 0;
  case (leg_id)
  0: if (n == 0)            period_of = center - half - 1;
     else if (n <= nsw)     period_of = center - half + (n - 1) / 2;
     else if (n == nsw + 1) period_of = center + half + 1;
  1: if (n < 32)            period_of = stds[n / 4];
     else if (n == 32)      period_of = stds[0];
  2: if (n < 15)            period_of = (n / 5 == 1) ? stds[1] : stds[0];
     else if (n == 15)      period_of = stds[0];
  default: period_of = 0;
  endcase
end
endfunction

// The modelled exception (see the top): the old chain's decision about a
// frame of period p after one of period pp differs from the plain window.
function in60(input integer p);
  in60 = (p >= OLD_MIN) && (p < OLD_MAX);
endfunction
// The old chain's latch for a frame of p clocks after one of pp: the whole
// us it counted (one more after a 149*k frame), as ms + (us > 500), one ms
// less when the frame end fell on the clock after a us wrap.  p = 0 is the
// stretch from reset (not modelled).
function integer old_lat(input integer p, input integer pp);
  integer m;
begin
  m = (p - 2) / OLD_US + (((pp > 0) && (pp % OLD_US == 0)) ? 1 : 0);
  old_lat = m / 1000 + ((m % 1000 > 500) ? 1 : 0);
  if ((p - 2) % OLD_US == 1 && m > 0 && m % 1000 == 0)
    old_lat = old_lat - 1;
end
endfunction
function old_60(input integer p, input integer pp);
  old_60 = (old_lat(p, pp) >= 13) && (old_lat(p, pp) <= 19);
endfunction
function known(input integer p, input integer pp);
  known = (p > 2) && (old_60(p, pp) != in60(p));
endfunction

// Frame driver: frame fn lasts cur_p clocks, i_vsync is high for its first
// VS_W.  meas_p is the frame that ended at the last vsync edge, prev_p the
// one before it.  The old chain shows its decision about meas_p 6 clocks
// after that edge; dec_p / dec_pp / flip (the modelled exception) change
// with it.  20 clocks into frame n the old chain's level is its decision
// about frame n-1.
reg     run = 1'b0;
integer t = 0;
integer dec_p = 0, dec_pp = 0, nknown = 0;
reg     flip = 1'b0;
integer fn = 0, ph = 0, cur_p = 0, meas_p = 0, prev_p = 0;
reg     d1 [0:2*HALF];   // lo / hi: decision about the frame after a 1 shorter one
reg     d2 [0:2*HALF];   //          ... about the frame after an equal one
always @(posedge clk)
begin
  if (t < 8)
    t = t + 1;
  if (t == 4)
    reset <= 1'b0;
  if (t == 7)
  begin
    cur_p = period_of(0);
    run   = 1'b1;
  end
  if (run)
    drive;
end
task drive;
begin
  if (ph == 0)
  begin
    vs <= 1'b1;
    prev_p = meas_p;
    meas_p = (fn == 0) ? 0 : period_of(fn - 1);
  end
  if (ph == 6)
  begin
    dec_p  = meas_p;
    dec_pp = prev_p;
    flip  <= known(meas_p, prev_p);
    if (known(meas_p, prev_p))
    begin
      nknown = nknown + 1;
      $display("  modelled: period %0d after %0d (%0s): old latch %0d, %0s Hz; new %0s Hz",
               meas_p, prev_p, (prev_p > 0 && prev_p % OLD_US == 0) ? "149*k" : "not 149*k",
               old_lat(meas_p, prev_p), old_60(meas_p, prev_p) ? "60" : "50",
               in60(meas_p) ? "60" : "50");
    end
  end
  if (ph == VS_W)
    vs <= 1'b0;
  if (ph == 20 && leg_id == 0 && fn >= 2 && fn <= nsw + 1)
  begin
    if ((fn - 2) % 2 == 0) d1[(fn - 2) / 2] = r_60hz;
    else                   d2[(fn - 2) / 2] = r_60hz;
  end
  if (ph == cur_p - 1)
  begin
    fn = fn + 1;
    ph = 0;
    cur_p = period_of(fn);
    if (cur_p == 0)
      done_run;
  end
  else
    ph = ph + 1;
end
endtask

// The checker, at each edge on the values before it, from the first clock
// on (reset included: before its first decision the old chain has
// r_50hz = 0, i.e. pal_to_ddr's w_hz60 = 1, and the new module must agree).
reg        verbose = 1'b1;
reg        started = 1'b0;
reg [63:0] mism = 0;
reg [63:0] clk_n = 0;
reg        last60 = 1'b0;
always @(posedge clk)
begin
  clk_n = clk_n + 1;
  if (hz60 !== (~r_50hz ^ flip))
  begin
    mism = mism + 1;
    if (mism <= 20)
      $display("FAIL clk %0d: period %0d (prev %0d): old r_50hz %b, new o_hz60 %b%0s",
               clk_n, dec_p, dec_pp, r_50hz, hz60, flip ? " (modelled exception)" : "");
  end
  if (!started && (r_50hz || r_60hz))
  begin
    started = 1'b1;
    last60  = r_60hz;
    $display("  old first decision %0s Hz at clk %0d", r_60hz ? "60" : "50", clk_n);
  end
  if (started)
  begin
    if (r_50hz == r_60hz)
    begin
      mism = mism + 1;
      if (mism <= 20)
        $display("FAIL clk %0d: old r_50hz %b r_60hz %b (both or neither)", clk_n, r_50hz, r_60hz);
    end
    if (r_60hz != last60)
    begin
      if (verbose)
        $display("  old -> %0s Hz at clk %0d, measured period %0d (prev %0d)",
                 r_60hz ? "60" : "50", clk_n, dec_p, dec_pp);
      last60 = r_60hz;
    end
  end
end

// The end of a leg: the old chain's decision moments of a sweep, the verdict.
task done_run;
  integer k;
begin
  if (leg_id == 0)
  begin
    $display("  old chain, frame after a 1 shorter one: %0s Hz from %0d",
             d1[0] ? "60" : "50", center - half);
    for (k = 1; k <= 2 * half; k = k + 1)
      if (d1[k] != d1[k - 1])
        $display("    %0s Hz from %0d", d1[k] ? "60" : "50", center - half + k);
    $display("  old chain, frame after an equal one:    %0s Hz from %0d",
             d2[0] ? "60" : "50", center - half);
    for (k = 1; k <= 2 * half; k = k + 1)
      if (d2[k] != d2[k - 1])
        $display("    %0s Hz from %0d", d2[k] ? "60" : "50", center - half + k);
  end
  if (!started)
  begin
    $display("FAIL the old chain never decided");
    mism = mism + 1;
  end
  $display("%0d clocks compared, %0d mismatches, %0d modelled frames", clk_n, mism, nknown);
  if (mism == 0)
    $display("ALL TESTS PASSED");
  else
    $display("FAILURES");
  $finish;
end
endtask

reg [8*16-1:0] leg;
initial
begin
  if (!$value$plusargs("leg=%s", leg)) leg = "switch";
  if (leg == "lo" || leg == "hi")
  begin
    leg_id = 0;
    if (!$value$plusargs("center=%d", center))
      center = (leg == "lo") ? OLD_MIN : OLD_MAX;
    if (!$value$plusargs("half=%d", half) || half > HALF || half < 1)
      half = HALF;
    nsw = 2 * (2 * half + 1);
    verbose = 1'b0;
    $display("leg %0s: periods %0d .. %0d, two frames each", leg, center - half, center + half);
  end
  else if (leg == "std")
  begin
    leg_id = 1;
    $display("leg std: PAL, NTSC, 55, 70, 100, 48, 23, 30 Hz, four frames each");
  end
  else if (leg == "switch")
  begin
    leg_id = 2;
    $display("leg switch: PAL -> NTSC -> PAL, five frames each");
  end
  else
  begin
    $display("FAIL unknown leg %0s", leg);
    $finish;
  end
end

endmodule

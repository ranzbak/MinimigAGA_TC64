`timescale 1ns / 1ps
// frame_freq -- picks pal_to_ddr's 720p60 path (o_hz60 = 1) or 720p50 path
// (0) from the input frame period: one counter of clk cycles between
// consecutive vsync rising edges, compared with HZ60_MIN / HZ60_MAX.
// Paul Honig, deFEEST 8-bit entertainment, 2021.

module frame_freq (
    input  logic clk,       // clk_148
    input  logic reset,
    input  logic i_vsync,   // clk_114 domain
    output logic o_hz60     // level: 1 = the 60 Hz path
);

// The 60 Hz window in clocks of period P, as the old frame_freq.v + pal_to_ddr
// chain decided (sim/hdmi_upsample/tb_frame_freq.v): it counted "us" of 149
// clocks and "ms" of 1000 us (its us counter shows 1000 for one clock only),
// latched ms + (us > 500) and took the 60 Hz path for 13..19, i.e. for
// 12501 <= M <= 19500 whole us; M = floor((P - 2) / 149): the count starts
// one clock after the frame end and each us is counted one clock late.
//   M >= 12501  <=>  P - 2 >= 12501 * 149 = 1862649  <=>  P >= 1862651
//   M <= 19500  <=>  P - 2 <  19501 * 149 = 2905649  <=>  P <  2905651
// (12.5 / 19.5 ms at 149 clocks per us: 1862500 / 2905500, +151 here.)
// Not reproduced, two artefacts of the old counter (the bench models both):
// - after a frame of 149 * k clocks it counted one us too many (r_us_en
//   survived the frame end), so for that one frame its window was 149
//   clocks lower;
// - one clock after its us counter wrapped (1000 -> 0) the ms count was not
//   yet incremented, so a frame end on that clock read one ms low: a frame
//   of exactly 13.000 / 20.000 of its ms (P = 13000 * 149 + 3 = 1937003,
//   20000 * 149 + 3 = 2980003; 149 lower after a 149 * k frame) went to the
//   50 / 60 Hz path.
localparam int HZ60_MIN = 1862651;
localparam int HZ60_MAX = 2905651;
localparam int PW = 28;     // 2^28 clocks = 1.8 s at 148.5 MHz; saturates

(* ASYNC_REG = "TRUE" *) logic [2:0] vsync_buf = '0;
logic          r_frame_end = 1'b0;
logic [PW-1:0] r_period = '0;
logic          r_win = 1'b0;
logic          r_win_d = 1'b1;
logic          r_hz60 = 1'b1;   // 1 from power-up to 2 clocks after reset, as the old r_50hz = 0

assign o_hz60 = r_hz60;

always_ff @(posedge clk) begin
    vsync_buf   <= {vsync_buf[1:0], i_vsync};
    r_frame_end <= ~reset & (vsync_buf[2:1] == 2'b01);
end

always_ff @(posedge clk) begin
    if (reset || r_frame_end)
        r_period <= PW'(1);
    else if (~&r_period)
        r_period <= r_period + 1'b1;
end

always_ff @(posedge clk) begin
    if (reset)
        r_win <= 1'b0;
    else if (r_frame_end)
        r_win <= (r_period >= PW'(HZ60_MIN)) && (r_period < PW'(HZ60_MAX));
    r_win_d <= reset | r_win;
    r_hz60  <= r_win_d;
end

endmodule

`timescale 1ns / 1ps
// signal_generator -- the 720p50 / 720p60 raster of the HDMI output (i_hz60
// selects the 720p60 front porch), genlocked to the input: every i_frame_end
// restarts the frame (hz_count, vt_count).  Pixel enable = clk / 2
// (o_adv_clk); o_adv_de rises one clock before the pixel's video.
// Sync watchdog: without an i_frame_end for WD_LINES lines (two frames) the
// frame restarts and the raster free-runs (r_freerun) with frames of 749 lines
// + 2 clocks (the normal frame length as the bench counts it) until the next
// i_frame_end, so the display keeps its 50/60 Hz vsync.
// vsync: PAL_VT_SYNC_WIDTH lines from the line after the front porch, switched
// at hsync starts.  Every frame gets exactly one: a restart before the frame's
// vsync line (a short frame: the 50/60 Hz splice, VPOS gliding) puts it on the
// new frame's first lines (blank above the window, PAL_VT_TOP), and a restart
// inside a vsync lets it finish its lines in the new frame.
// One generator for both rates: findings/scaler/plan.md (step 2).
// Paul Honig, deFEEST 8-bit entertainment, 2020.

module signal_generator
#(
    // Horizontal parameters
    parameter PAL_HZ_ACT_PIX = 1280,
    parameter PAL_HZ_FRONT_PORCH = 440,     // i_hz60 = 0 (720p50)
    parameter PAL_HZ_FRONT_PORCH60 = 110,   // i_hz60 = 1 (720p60)
    parameter PAL_HZ_SYNC_WIDTH = 40,
    parameter PAL_HZ_BACK_PORCH = 220,
    // Vertical parameters
    parameter PAL_VT_ACT_LN = 720,
    parameter PAL_VT_FRONT_PORCH = 3,
    parameter PAL_VT_SYNC_WIDTH = 5,
    parameter PAL_VT_BACK_PORCH = 20,
    // blank lines at the frame's start, before the active lines (part of the
    // back porch: PAL_VT_TOP <= PAL_VT_BACK_PORCH; the frame stays PAL_VT_TOTAL),
    // 0 or at least PAL_VT_SYNC_WIDTH (checks below); pal_to_ddr.sv sets 15.
    // 0 (the window from line 0) suits fixed-length frames only: osd_text.v
    // and its bench sim/osd_text count the picture's rows from line 0
    parameter PAL_VT_TOP = 0
)(
    input  logic       clk,
    input  logic       reset,
    // 720p60 line (front porch PAL_HZ_FRONT_PORCH60) instead of 720p50 --
    // the only difference between the two (findings/scaler/plan.md step 2:
    // one generator for both, switched at run time)
    input  logic       i_hz60,
    // Input RGB
    input  logic [7:0] i_r,
    input  logic [7:0] i_g,
    input  logic [7:0] i_b,
    input  logic       i_frame_end,
    output logic       o_hsync,     // Sync signals to the HDMI encoder
    output logic       o_vsync,
    output logic [11:0] o_x,        // Output the X and Y positions of the video beam
    output logic [11:0] o_y,        // When not within the active range 0, 0 is returned
    output logic       o_frame,     // Pulse
    output logic [7:0] o_r,         // Outgoing RGB signal
    output logic [7:0] o_g,
    output logic [7:0] o_b,
    output logic       o_adv_clk,   // Video pixel clock
    output logic       o_adv_de     // Data valid strobe
);

localparam PAL_HZ_TOTAL = PAL_HZ_ACT_PIX + PAL_HZ_FRONT_PORCH + PAL_HZ_SYNC_WIDTH + PAL_HZ_BACK_PORCH;
localparam PAL_HZ_TOTAL60 = PAL_HZ_ACT_PIX + PAL_HZ_FRONT_PORCH60 + PAL_HZ_SYNC_WIDTH + PAL_HZ_BACK_PORCH;
localparam PAL_VT_TOTAL = PAL_VT_ACT_LN + PAL_VT_FRONT_PORCH + PAL_VT_SYNC_WIDTH + PAL_VT_BACK_PORCH;
// Geometry checks.  An instance of a module that does not exist stops the
// elaboration of a bad parameter set in every tool, its name the rule
// broken; $error in a generate block is not portable (Quartus 20.1 rejects
// it as a syntax error, 10170).
//  - the top blank lines are part of the back porch;
//  - when there are any, they hold a whole vsync (a restart before a
//    frame's vsync line gives the vsync on the new frame's first lines,
//    above the window).  0 top lines is the window from line 0, for frames
//    of the full length (sim/osd_text; a short frame's late vsync then
//    lies on the first picture lines);
//  - the vsync lines end inside the frame (follows from the first while the
//    frame is the sum below; kept should that change).
generate
if (PAL_VT_TOP > PAL_VT_BACK_PORCH) begin : g_chk_top_in_back_porch
    PARAM_ERROR_pal_vt_top_must_not_exceed_back_porch u_param_error ();
end
if (PAL_VT_TOP != 0 && PAL_VT_TOP < PAL_VT_SYNC_WIDTH) begin : g_chk_top_holds_vsync
    PARAM_ERROR_pal_vt_top_must_be_ge_sync_width u_param_error ();
end
if (PAL_VT_TOP + PAL_VT_ACT_LN + PAL_VT_FRONT_PORCH + PAL_VT_SYNC_WIDTH > PAL_VT_TOTAL) begin : g_chk_vsync_in_frame
    PARAM_ERROR_vsync_must_end_inside_the_frame u_param_error ();
end
endgenerate

// Watchdog: the chipset's syncs can stop (RTG mode with its sync start past the
// frame size, agnus_beamcounter.v:412-424); without this the counter ran past
// 750 forever and the display saw no vsync and slept.
localparam WD_LINES = 2*PAL_VT_TOTAL - 1;

// SYNC POLARITY
localparam SYNC_POL = 1'b1; // Sync polarity 1'b1 = active high, 1'b0 is active low
localparam DE_POL   = 1'b1; // Sync polarity 1'b1 = positive, 1'b0 is negative

localparam HW = $clog2(PAL_HZ_TOTAL > PAL_HZ_TOTAL60 ? PAL_HZ_TOTAL : PAL_HZ_TOTAL60) + 1;
localparam VW = $clog2(WD_LINES + 1);    // vt_count holds WD_LINES

// the vertical positions, at vt_count's width: TOP blank lines, the active
// lines, the front porch, vsync, the rest of the back porch
localparam logic [VW-1:0] VT_TOP   = VW'(PAL_VT_TOP);                            // active lines VT_TOP ..
localparam logic [VW-1:0] VT_ACT   = VW'(PAL_VT_TOP + PAL_VT_ACT_LN);            // ... VT_ACT-1
localparam logic [VW-1:0] VT_VS0   = VW'(PAL_VT_TOP + PAL_VT_ACT_LN + PAL_VT_FRONT_PORCH);   // vsync from this line, VS_LINES lines
localparam logic [VW-1:0] VT_WD    = VW'(WD_LINES);
localparam logic [VW-1:0] VT_LAST  = VW'(PAL_VT_TOTAL - 1);                      // free-run frame: 0 .. VT_LAST

// the line's constants for the selected rate, registered (static)
logic [HW-1:0] c_total = HW'(PAL_HZ_TOTAL);                       // last hz_count of a line
logic [HW-1:0] c_act   = HW'(PAL_HZ_TOTAL - PAL_HZ_ACT_PIX);      // active from hz_count > c_act
logic [HW-1:0] c_fp    = HW'(PAL_HZ_FRONT_PORCH);                 // hsync from here ...
logic [HW-1:0] c_fps   = HW'(PAL_HZ_FRONT_PORCH + PAL_HZ_SYNC_WIDTH);   // ... to here
always_ff @(posedge clk) begin
    c_total <= i_hz60 ? HW'(PAL_HZ_TOTAL60) : HW'(PAL_HZ_TOTAL);
    c_act   <= i_hz60 ? HW'(PAL_HZ_TOTAL60 - PAL_HZ_ACT_PIX) : HW'(PAL_HZ_TOTAL - PAL_HZ_ACT_PIX);
    c_fp    <= i_hz60 ? HW'(PAL_HZ_FRONT_PORCH60) : HW'(PAL_HZ_FRONT_PORCH);
    c_fps   <= i_hz60 ? HW'(PAL_HZ_FRONT_PORCH60 + PAL_HZ_SYNC_WIDTH) : HW'(PAL_HZ_FRONT_PORCH + PAL_HZ_SYNC_WIDTH);
end

// (a) pixel enable: clk / 2
logic r_dev_cnt    = 1'b0;
logic r_clock_dev  = 1'b0;  // the HDMI pixel clock
logic r_vid_enable = 1'b0;  // pixel enable
always_ff @(posedge clk) begin
    if (reset) begin
        r_dev_cnt   <= 1'b0;
        r_clock_dev <= 1'b0;
    end else begin
        r_dev_cnt    <= ~r_dev_cnt;
        r_clock_dev  <= r_dev_cnt;
        r_vid_enable <= ~r_dev_cnt;
    end
end

// (b) counters, syncs, active flags, RGB gate
//
// Horizontal order : Front Porch   | Sync        | Back Porch | Active region
// Vertical order   : Top (VT_TOP) | Active region | Front Porch | Sync | Back Porch (less VT_TOP)
logic [HW-1:0] hz_count = '0;
logic [VW-1:0] vt_count = '0;
logic [HW-1:0] r_x = '0;
logic [HW-1:0] r_y = '0;
logic          r_frame = 1'b0;       // one clock: the frame restarted (line 0)
logic          r_frame_end = 1'b0;   // restart the frame at the next clock
logic          r_freerun = 1'b0;     // syncs lost: free-run 749 lines + 2 clocks
logic          r_hsync = 1'b0;
logic          r_vsync = 1'b0;
localparam int SWW = $clog2(PAL_VT_SYNC_WIDTH + 1);
localparam logic [SWW-1:0] VS_LINES = SWW'(PAL_VT_SYNC_WIDTH);
logic [SWW-1:0] r_vs_rem  = '0;      // vsync lines still to give, from the next hsync start
logic           r_vs_done = 1'b1;    // this frame's vsync has started (none owed after reset)
logic          hz_region_act;
logic          vt_region_act;
logic [7:0]    r_r, r_g, r_b;

logic vt_count_enable;   // the line's last pixel: the vertical counter steps
logic [VW-1:0] w_vt_y;   // the line in the active window
logic w_vt_act;          // an active line
logic w_watchdog;        // no frame end for WD_LINES lines
logic w_restart;         // restart the frame: input frame end, watchdog, free run
logic w_hs_win;          // the hsync window
logic w_hs_start;        // its first clock: a line's hsync start
always_comb begin
    vt_count_enable = r_vid_enable && (hz_count == c_total);
    w_vt_y          = vt_count - VT_TOP;            // wraps high above the window
    w_vt_act        = (w_vt_y < VT_ACT - VT_TOP);
    w_watchdog      = (vt_count == VT_WD);
    w_restart       = i_frame_end || w_watchdog || (r_freerun && vt_count == VT_LAST);
    w_hs_win        = (hz_count >= c_fp && hz_count < c_fps);
    w_hs_start      = w_hs_win && (r_hsync != SYNC_POL);
end

always_ff @(posedge clk) begin
    if (reset) begin
        hz_count      <= '0;
        vt_count      <= '0;
        r_frame       <= 1'b0;
        r_frame_end   <= 1'b0;
        r_freerun     <= 1'b0;
        r_vs_rem      <= '0;
        r_vs_done     <= 1'b1;
        hz_region_act <= 1'b0;
        vt_region_act <= 1'b0;
    end else begin
        // the watchdog starts the free run, the input's next frame end ends it
        if (i_frame_end)
            r_freerun <= 1'b0;
        else if (w_watchdog)
            r_freerun <= 1'b1;

        // a restart (frame end, watchdog, free run) takes effect a clock later
        r_frame <= r_frame_end;
        if (r_frame_end) begin
            r_frame_end <= 1'b0;
            hz_count    <= '0;
            vt_count    <= '0;
        end else begin
            if (w_restart)
                r_frame_end <= 1'b1;
            if (r_vid_enable)
                hz_count <= vt_count_enable ? '0 : hz_count + 1'b1;
            if (vt_count_enable)
                vt_count <= vt_count + 1'b1;
        end

        // horizontal active region
        hz_region_act <= (hz_count > c_act) && w_vt_act;
        r_x <= ((hz_count > c_act) && w_vt_act) ? hz_count - c_act : '0;

        // syncs: hsync in the window; vsync switches at hsync starts, on for
        // VS_LINES of them from line VT_VS0
        r_hsync <= !SYNC_POL;
        if (w_hs_win)
            r_hsync <= SYNC_POL;
        if (w_hs_start && !r_frame_end) begin
            if (vt_count == VT_VS0 && !r_vs_done) begin
                r_vsync   <= SYNC_POL;
                r_vs_rem  <= VS_LINES - 1'b1;
                r_vs_done <= 1'b1;
            end else if (r_vs_rem != '0) begin
                r_vsync   <= SYNC_POL;
                r_vs_rem  <= r_vs_rem - 1'b1;
            end else begin
                r_vsync   <= !SYNC_POL;
            end
        end
        // the restart: a frame that had no vsync gets it on the new frame's
        // first lines; one in progress goes on (r_vs_rem)
        if (r_frame_end) begin
            r_vs_done <= 1'b0;
            if (!r_vs_done)
                r_vs_rem <= VS_LINES;
        end

        // vertical active region
        vt_region_act <= w_vt_act;
        r_y <= w_vt_act ? HW'(w_vt_y) : '0;

        // pass the data through while active
        r_r <= (vt_region_act && hz_region_act) ? i_r : 8'h00;
        r_g <= (vt_region_act && hz_region_act) ? i_g : 8'h00;
        r_b <= (vt_region_act && hz_region_act) ? i_b : 8'h00;
    end
end

assign o_adv_clk = r_clock_dev;
assign o_hsync   = r_hsync;
assign o_vsync   = r_vsync;
assign o_x       = 12'(r_x);
assign o_y       = 12'(r_y);
assign o_frame   = r_frame;
assign o_r       = r_r;
assign o_g       = r_g;
assign o_b       = r_b;
// ADV data enable
assign o_adv_de  = DE_POL ? (hz_region_act & vt_region_act) : !(hz_region_act & vt_region_act);

endmodule

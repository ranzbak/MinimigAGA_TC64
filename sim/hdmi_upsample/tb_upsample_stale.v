// tb_upsample_stale.v -- the 60 Hz upsampler (pal_to_hd_upsample) must never
// show a pixel its line buffer did not get from the current input line.
//
// The board showed static stripes at the right edge of the HDMI picture after
// a screen-mode change (doc/backlog.md, "static artifacts in the border"): the
// 8 line buffers are never cleared, the read side reads a fixed stretch, and
// where the write side wrote fewer pixels the buffer's old tail reached the
// screen.  This bench fills the whole buffer RAM with a marker colour first
// (stale content from an earlier mode), then runs PAL lines whose picture is
// PIC everywhere outside the sync pulse, and counts output pixels equal to
// MARK.  Pass: none, after the first 8 lines (one turn of the buffers).
//
// HD side as in pal_to_ddr.sv's 60 Hz path: signal_generator with the 720p60
// timing drives hsync and the pixel clock; upsampler PAL_HD_H_RES 1980.
// A buffer word is {b, g, r}.
// +lines=N  PAL lines to run (default 40); +hoffset=N  the OSD offset (default 0)
// +linens=N  input line length in ns (default 64000, PAL); hsync stays 4700
// +perline   every input line gets its own colour: then each output line's
//            non-black pixels must all be one colour (one input line, no
//            older line's tail), in one unbroken run (nothing blanked inside)
`timescale 1ns/1ps
module tb_upsample_stale;

localparam [23:0] MARK = 24'hA5C3E1;   // {b, g, r}
localparam [23:0] PIC  = 24'h336699;   // {b, g, r}

reg clk_114 = 0, clk_148 = 0, reset = 1;
always #4.4075 clk_114 = ~clk_114;   // 113.4375 MHz
always #3.367  clk_148 = ~clk_148;   // 148.5 MHz

// PAL input: 64 us lines, 4.7 us hsync (active high: the upsampler writes
// only while hsync is low); vsync for 3 lines near the start
reg pal_hs = 0, pal_vs = 0;
integer lines = 40, hoff = 0, linens = 64000;
reg perline = 0;
wire [23:0] pic_now = perline ? (24'h100000 + line_no * 24'h010101) : PIC;
integer line_no = 0;
initial begin
	if (!$value$plusargs("lines=%d", lines)) lines = 40;
	if (!$value$plusargs("hoffset=%d", hoff)) hoff = 0;
	perline = $test$plusargs("perline");
	if (!$value$plusargs("linens=%d", linens)) linens = 64000;
end

// HD side
wire hd_clk, hd_hs, hd_vs, hd_de;
wire [7:0] up_r, up_g, up_b;
wire [7:0] vis_r, vis_g, vis_b;   // what goes to the HDMI encoder
wire frame_end;
signal_generator #(
	.PAL_HZ_ACT_PIX(1280), .PAL_HZ_FRONT_PORCH(110), .PAL_HZ_SYNC_WIDTH(40), .PAL_HZ_BACK_PORCH(220),
	.PAL_VT_ACT_LN(720), .PAL_VT_FRONT_PORCH(5), .PAL_VT_SYNC_WIDTH(5), .PAL_VT_BACK_PORCH(20)
) gen (
	.clk(clk_148), .reset(reset), .i_frame_end(frame_end),
	.i_r(up_r), .i_g(up_g), .i_b(up_b),
	.o_x(), .o_y(), .o_r(vis_r), .o_g(vis_g), .o_b(vis_b),
	.o_adv_clk(hd_clk), .o_hsync(hd_hs), .o_vsync(hd_vs), .o_adv_de(hd_de), .o_frame()
);

pal_to_hd_upsample #(.PAL_HD_H_RES(1980)) dut (
	.clk_out(clk_148), .clk_in(clk_114), .reset(reset),
	.i_pal_hsync(pal_hs), .i_pal_vsync(pal_vs),
	.i_pal_r(pic_now[7:0]), .i_pal_g(pic_now[15:8]), .i_pal_b(pic_now[23:16]),
	.i_rtg_enable(1'b0),
	.o_hd_r(up_r), .o_hd_g(up_g), .o_hd_b(up_b), .o_hd_vsync(), .o_frame_end(frame_end),
	.i_hd_hsync(hd_hs), .i_hd_vsync(hd_vs), .i_hd_clk(hd_clk),
	.i_hd_hoffset(hoff[7:0]), .i_hd_voffset(8'd0)
);

// stale content: every buffer word is the marker
integer i;
initial for (i = 0; i < 16384; i = i + 1) dut.upsample_blk_ram.mem[i] = MARK;

// count the pixels that reach the HDMI encoder (signal_generator's output
// while its data enable is high), once per HD pixel clock
reg hd_clk_d = 0;
integer n_mark = 0, n_pic = 0, hx = 0, first_x = -1, first_line = -1;
// per output line (perline mode): its first non-black colour, colour changes,
// runs of non-black pixels
reg [23:0] l_col; reg l_any = 0, l_prev_nb = 0; integer l_runs = 0;
integer n_mixed = 0, n_gaps = 0, n_lines_chk = 0;
always @(posedge clk_148) begin
	hd_clk_d <= hd_clk;
	if (hd_hs) begin
		if (hx != 0 && line_no >= 8 && l_any) begin
			n_lines_chk = n_lines_chk + 1;
			if (l_runs > 1) n_gaps = n_gaps + 1;
		end
		hx <= 0; l_any = 0; l_prev_nb = 0; l_runs = 0;
	end
	else if (hd_clk_d && !hd_clk) begin
		hx <= hx + 1;
		if (line_no >= 8 && hd_de) begin
			if ({vis_b, vis_g, vis_r} == MARK) begin
				n_mark = n_mark + 1;
				if (first_x < 0) begin first_x = hx; first_line = line_no; end
			end
			if (!perline && {vis_b, vis_g, vis_r} == PIC) n_pic = n_pic + 1;
			if (perline) begin
				if ({vis_b, vis_g, vis_r} != 24'h0 && {vis_b, vis_g, vis_r} != MARK) begin
					n_pic = n_pic + 1;
					if (!l_prev_nb) l_runs = l_runs + 1;
					if (!l_any) begin l_any = 1; l_col = {vis_b, vis_g, vis_r}; end
					else if ({vis_b, vis_g, vis_r} != l_col) n_mixed = n_mixed + 1;
					l_prev_nb = 1;
				end else l_prev_nb = 0;
			end
		end
	end
end

// PAL line generator, then the verdict
initial begin
	#200 reset = 0;
	for (line_no = 0; line_no < lines; line_no = line_no + 1) begin
		pal_vs = (line_no >= 1 && line_no < 4);
		pal_hs = 1; #4700;
		pal_hs = 0; #(linens - 4700);
	end
	#20000;
	$display("lines %0d, marker pixels after line 8: %0d, picture pixels: %0d", lines, n_mark, n_pic);
	if (perline) $display("perline: %0d output lines checked, %0d pixels from another input line, %0d lines with a gap", n_lines_chk, n_mixed, n_gaps);
	if (n_pic == 0)        $display("FAIL: no picture reached the output (bench broken)");
	else if (perline && (n_mixed != 0 || n_gaps != 0)) $display("FAIL: output lines mix input lines or have gaps");
	else if (n_mark != 0)  $display("FAIL: %0d output pixels show stale buffer content (first at hd x %0d, pal line %0d)", n_mark, first_x, first_line);
	else                   $display("ALL TESTS PASSED");
	$finish;
end
endmodule

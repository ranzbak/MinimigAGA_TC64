// tb_post_unit.v -- crt_post alone: flat field (cur = next = constant) through
// every line phase, prints w0/w1 and the output; and the bypass identity
// (all controls 0: out == in, delayed) for all 256 values.
`timescale 1ns/1ps
module tb_crt_post_unit #(
	parameter WROM = "../../rtl/openaars/adv7511/crt_wrom.mem",
	parameter LUT  = "../../rtl/openaars/adv7511/crt_lut.mem"
);
reg clk = 0; always #3.367 clk = ~clk;
reg stb = 0, ls = 0; reg [6:0] ph = 0; reg [23:0] cur = 0, nxt = 0;
reg [1:0] scan = 0, hblur = 0, mask = 0, lutp = 0; reg vb = 0;
wire [23:0] o;
crt_post #(.WROM_FILE(WROM), .LUT_FILE(LUT)) dut (
	.clk(clk), .i_stb(stb), .i_line_start(ls), .i_phase(ph), .i_cur(cur), .i_nxt(nxt),
	.i_hz60(1'b0), .i_scan(scan), .i_vblend(vb), .i_hblur(hblur), .i_mask(mask), .i_lut(lutp),
	.i_wwe(1'b0), .i_wwa(11'd0), .i_wwd(18'd0), .o_rgb(o));
always @(posedge clk) stb <= ~stb;
integer i, n, err = 0, wait_px;
task px(input [23:0] c, input [23:0] x); begin cur = c; nxt = x; @(posedge clk); while (!stb) @(posedge clk); end endtask
initial begin
	// bypass identity: value v in, after LATENCY pixels the same value out
	for (i = 0; i < 256 + 8; i = i + 1) begin
		px({i[7:0], ~i[7:0], i[7:0] ^ 8'h5A}, 24'h0);
		if (i >= 8 && o !== {i[7:0] - 8'd8, ~(i[7:0] - 8'd8), (i[7:0] - 8'd8) ^ 8'h5A}) err = err + 1;
	end
	$display("bypass identity: %0d mismatches (latency 8 pixels)", err);
	// horizontal 3-tap on a step 0 -> 255 (scan off, LUT identity)
	for (n = 1; n < 3; n = n + 1) begin
		hblur = n; $write("hblur=%0d step:", n);
		for (i = 0; i < 20; i = i + 1) begin
			px((i < 10) ? 24'h000000 : 24'hFFFFFF, 24'h0);
			if (i >= 14) $write(" %0d", o[7:0]);
		end
		repeat (4) begin px(24'hFFFFFF, 24'h0); $write(" %0d", o[7:0]); end
		$write("   (expect 0 .. %0s .. 255)\n", n == 1 ? "31 223" : "63 191");
	end
	hblur = 0;
	for (n = 0; n < 4; n = n + 1) begin
		vb = n[1]; scan = 2; lutp = n[0] ? 2 : 0;
		$display("vblend=%0d scan=2 lut=%0d: phase idx -> w0 w1 out(flat 255 / flat 0x80)", vb, lutp);
		for (i = 31; i < 106; i = i + 8) begin
			ph = i;
			repeat (10) px(24'hFFFFFF, 24'hFFFFFF);
			$write("  %0d: %0d %0d %0d", i, dut.w0, dut.w1, o[7:0]);
			repeat (10) px(24'h808080, 24'h808080);
			$write(" / %0d\n", o[7:0]);
		end
	end
	$finish;
end
endmodule

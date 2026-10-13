// tb_post_unit.v -- crt_post alone: flat field (cur = next = constant) through
// every line phase, prints w0/w1 and the output; and the bypass identity
// (all controls 0: out == in, delayed) for all 256 values; the phosphor mask
// (column pattern per mode) and bloom (scanline gap filled on bright pixels
// only; no effect without a vertical effect); the linear-light blend
// (2026-10-13): "lin K P C N O" lines for scl_check.py lin -- per kernel K
// and phase P a block of pixels with cur C and next N in every channel,
// the output O once the pipeline holds the block (bit-exact model:
// scl_mkroms.py rtl_blend).
`timescale 1ns/1ps
module tb_crt_post_unit #(
	parameter WROM = "../../rtl/openaars/adv7511/crt_wrom.mem",
	parameter LUT  = "../../rtl/openaars/adv7511/crt_lut.mem",
	parameter BLM  = "../../rtl/openaars/adv7511/crt_bloom.mem",
	parameter SDEC = "../../rtl/openaars/adv7511/crt_sdec.mem",
	parameter SENC = "../../rtl/openaars/adv7511/crt_senc.mem",
	parameter SWROM = "../../rtl/openaars/adv7511/crt_swrom.mem"
);
localparam LAT = 9;   // crt_post latency, pixels (the linear path: 12)
reg clk = 0; always #3.367 clk = ~clk;
reg stb = 0, ls = 0; reg [6:0] ph = 0; reg [23:0] cur = 0, nxt = 0;
reg [1:0] scan = 0, hblur = 0, mask = 0, lutp = 0, bloom = 0; reg vb = 0;
reg lin = 0; reg [1:0] kern = 0; reg [7:0] vph = 0; reg hz60 = 0;
wire [23:0] o;
crt_post #(.HAS_MASK(1), .WROM_FILE(WROM), .LUT_FILE(LUT), .BLOOM_FILE(BLM),
           .SDEC_FILE(SDEC), .SENC_FILE(SENC), .SWROM_FILE(SWROM)) dut (
	.clk(clk), .i_stb(stb), .i_line_start(ls), .i_phase(ph), .i_cur(cur), .i_nxt(nxt),
	.i_hz60(hz60), .i_scan(scan), .i_vblend(vb), .i_hblur(hblur), .i_mask(mask), .i_bloom(bloom), .i_lut(lutp),
	.i_lin(lin), .i_kern(kern), .i_vphase(vph),
	.i_wwe(1'b0), .i_wwa(11'd0), .i_wwd(18'd0), .o_rgb(o));
always @(posedge clk) stb <= ~stb;
integer i, n, err = 0, wait_px, k, gi, gw;
reg [23:0] cap [0:5];
reg [7:0] g0, g1, g2, d0, d1, d2;
reg ok;
task px(input [23:0] c, input [23:0] x); begin cur = c; nxt = x; @(posedge clk); while (!stb) @(posedge clk); end endtask
initial begin
	// bypass identity: value v in, after LATENCY pixels the same value out
	for (i = 0; i < 256 + LAT; i = i + 1) begin
		px({i[7:0], ~i[7:0], i[7:0] ^ 8'h5A}, 24'h0);
		if (i >= LAT && o !== {i[7:0] - LAT[7:0], ~(i[7:0] - LAT[7:0]), (i[7:0] - LAT[7:0]) ^ 8'h5A}) err = err + 1;
	end
	$display("bypass identity: %0d mismatches (latency %0d pixels)", err, LAT);
	// bloom alone (no scanlines, no two-line beam): nothing to fill, identity
	err = 0; bloom = 2;
	for (i = 0; i < 256 + LAT; i = i + 1) begin
		px({i[7:0], ~i[7:0], i[7:0] ^ 8'h5A}, 24'h0);
		if (i >= LAT && o !== {i[7:0] - LAT[7:0], ~(i[7:0] - LAT[7:0]), (i[7:0] - LAT[7:0]) ^ 8'h5A}) err = err + 1;
	end
	$display("bloom alone identity: %0d mismatches", err);
	bloom = 0;
	// horizontal 3-tap on a step 0 -> 255 (scan off, LUT identity)
	for (n = 1; n < 3; n = n + 1) begin
		hblur = n; $write("hblur=%0d step:", n);
		for (i = 0; i < 20; i = i + 1) begin
			px((i < 10) ? 24'h000000 : 24'hFFFFFF, 24'h0);
			if (i >= LAT + 6) $write(" %0d", o[7:0]);
		end
		repeat (4) begin px(24'hFFFFFF, 24'h0); $write(" %0d", o[7:0]); end
		$write("   (expect 0 .. %0s .. 255)\n", n == 1 ? "31 223" : "63 191");
	end
	hblur = 0;
	// phosphor mask on a flat grey: per mode the column pattern of the
	// channels (1, 2: R G B stripes, 3: R+B / G alternating)
	for (n = 1; n < 4; n = n + 1) begin
		mask = n;
		repeat (20) px(24'h808080, 24'h808080);
		for (k = 0; k < 6; k = k + 1) begin cap[k] = o; px(24'h808080, 24'h808080); end
		ok = 1;
		for (k = 0; k < 6; k = k + 1) begin
			if (cap[k] !== cap[(k + ((n == 3) ? 2 : 3)) % 6]) ok = 0;   // the period
			if (n != 3 && ((cap[k][7:0] > cap[k][15:8]) + (cap[k][15:8] > cap[k][23:16]) + (cap[k][23:16] > cap[k][7:0])) == 0) ok = 0;
		end
		if (n != 3) begin   // each of the 3 columns lights another channel
			for (k = 0; k < 3; k = k + 1) begin
				g0 = cap[k][7:0]; g1 = cap[k][15:8]; g2 = cap[k][23:16];
				if (!((g0 > g1 && g0 > g2) || (g1 > g0 && g1 > g2) || (g2 > g0 && g2 > g1))) ok = 0;
			end
			if (cap[0] == cap[1] || cap[1] == cap[2] || cap[0] == cap[2]) ok = 0;
		end else begin       // R and B together, G in the other column
			if (cap[0][7:0] !== cap[0][23:16] || cap[0][7:0] == cap[0][15:8] ||
			    (cap[0][7:0] > cap[0][15:8]) == (cap[1][7:0] > cap[1][15:8])) ok = 0;
		end
		$display("mask=%0d: %06x %06x %06x %06x  %0s", n, cap[0], cap[1], cap[2], cap[3], ok ? "OK" : "FAIL");
	end
	mask = 0;
	// bloom: scanlines dim (profile 2, LUT page 2), single-line beam, at the
	// line phase with the deepest gap: white is filled more with more bloom,
	// a dark grey is not touched
	scan = 2; lutp = 2; vb = 0; gw = 999; gi = 31;
	for (i = 31; i < 106; i = i + 1) begin ph = i; @(posedge clk); @(posedge clk); @(posedge clk); if (dut.w0 < gw) begin gw = dut.w0; gi = i; end end
	ph = gi;
	for (n = 0; n < 3; n = n + 1) begin
		bloom = n;
		repeat (14) px(24'hFFFFFF, 24'hFFFFFF);
		if (n == 0) g0 = o[7:0]; else if (n == 1) g1 = o[7:0]; else g2 = o[7:0];
		repeat (14) px(24'h202020, 24'h202020);
		if (n == 0) d0 = o[7:0]; else if (n == 1) d1 = o[7:0]; else d2 = o[7:0];
	end
	bloom = 0; scan = 0; lutp = 0;
	$display("bloom gap (phase %0d, w0 %0d): white off %0d low %0d high %0d, grey 20 off %0d low %0d high %0d  %0s",
		gi, gw, g0, g1, g2, d0, d1, d2, (g2 > g1 && g1 > g0 && d0 == d1 && d1 == d2) ? "OK" : "FAIL");
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
	// the linear-light blend: kernel x phase x value pairs, LUT page 0
	vb = 0; scan = 0; lutp = 0; bloom = 0; hblur = 0; mask = 0; lin = 1;
	for (n = 0; n < 8; n = n + 1) begin
		kern = n[1:0]; hz60 = n[2];
		for (k = 0; k < 256; k = k + 17) begin
			vph = k;
			for (gi = 0; gi < 6; gi = gi + 1) begin
				g0 = (gi * 53 + k) & 255; g1 = (gi * 97 + 3 * k + 11) & 255;
				repeat (LAT + 4) px({g0, g0, g0}, {g1, g1, g1});
				$display("lin %0d %0d %0d %0d %0d %0d", n, k, g0, g1, o[7:0], (o[23:16] == o[7:0] && o[15:8] == o[7:0]));
			end
		end
	end
	lin = 0;
	$finish;
end
endmodule

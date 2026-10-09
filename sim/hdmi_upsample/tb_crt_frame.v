// tb_crt_frame.v -- the HDMI path with the CRT emulation (pal_to_ddr.sv as
// in the tree) against the HDMI path as committed before it
// (ref/pal_to_ddr_ref.sv + ref/pal_to_hd_upsample_ref.v, 662cd10), fed the
// same Amiga picture.  Both pictures are taken where adv_ddr gets them
// (the 50/60 Hz select of the signal generators' outputs, 24 bit, one pixel
// per HD pixel clock while DE), 1280x720 per HD frame.
//
// Amiga side (clk_114) as in the CRT study (agnus_beamcounter.v PAL timing):
// 454 lowres pixels (7264 clk_114) per line, hsync hpos 37..69, 312 lines
// (313 in a long field), vsync lines 2..5 (short field: hsstrt .. hcenter;
// long field: hcenter .. line 6 hsstrt).  RGB from build/amiga_frame.hex
// (crt_mkframe.py), one word per superhires pixel (4 clk_114).  Syncs active
// high and two clk_114 after RGB, as pal_to_ddr gets them.
//
// plusargs
//   +cfg=H       OSD video config {beam, bloom, mask, hr_filter, lr_filter,
//                scanline}, 12 bits, hex (default 0)
//   +frame=F     the Amiga picture from F instead of build/amiga_frame.hex
//                (312 x 1816 words, crt_mkdither.py's format)
//   +hires=F     Denise's HIRES per line from F (312 words 0/1; default 0)
//   +srcdelay=N  delay the Amiga side (RGB, syncs, HIRES) by N clk_114, both
//                paths (the beam alignment leg: a pre-filtered source, delayed
//                as the filter delays the picture)
//   +sdump=F     the horizontal beam filter's output stream (crt_beamh.v) of
//                one input field from frame 2 on: "V S RRGGBB" per output
//                sample, V / S the line and sample the bench sends then
//   +cfg2=H +cfgframe=N +cfgline=L   change the config to cfg2 during HD
//                frame N, line L of the new path (the OSD-change leg; 3.1 ns
//                after that line's start, off the clk_148 grid)
//   +dbl         31 kHz input (amber's scandoubler: each line twice in 32 us)
//   +lace        interlaced: long and short fields alternate
//   +split       a generated lowres/hires split screen instead of the picture
//                (see below), with Denise's HIRES driven to match
//   +rtg         i_rtg_enable = 1
//   +hoff=N +voff=N   the OSD Video Pos offsets of the new path (8 bit,
//                signed, -128..127; default 0, the reference path keeps 0)
//   +voff2=N +vofframe=F +voffline=L   change VPOS to voff2 during HD frame
//                F, line L of the new path (the VPOS-change legs)
//   +force60     both paths use the 60 Hz upsampler (r_50hz forced 0)
//   +first=N +frames=M   compare (and dump) HD frames N .. N+M-1 (default 3, 1)
//   +out=PREFIX  dump the new path's frames as PREFIX_<n>.hex (RRGGBB per
//                line, raster order) and its line phases as PREFIX_phase.txt
// Prints "frame N: D pixels differ" per compared frame, "lines N" (pixels
// captured, non-black), the path (50/60), "hd frame N: L lines, V vsync"
// for every HD frame of the new path (HD lines, and rising edges of the
// selected signal generator's vsync in it), and every change of the
// frame-latched config ("cfg latched ... at frame end: 1" when it happened
// the clock after a frame end; "beam latched ..." for the beam filter's own
// latch in clk_114, with the input line it happened in).
//
// +split picture: 32-superhires-pixel stripes (0 / 255).  Lowres lines carry
// them in green, hires lines in red; line 150 switches lowres -> hires at
// hpos 120 (before the upsampler's mid-line resolution sample) and is
// marked blue C8, line 200 switches at hpos 300 (after it) and is marked
// blue 64.  Lines 26..149 lowres, 151..199 hires, 201..249 lowres, 250..311 hires.
`timescale 1ns/1ps
module tb_crt_frame;

reg clk_114 = 0, clk_148 = 0, reset = 1;
always #4.4075 clk_114 = ~clk_114;   // 113.4375 MHz
always #3.367  clk_148 = ~clk_148;   // 148.5 MHz

// ---- controls ----
integer frames = 1, first = 3, cfgframe = -1, cfgline = 0, cfg = 0, cfg2 = 0;
reg lace = 0, dbl = 0, split = 0, rtg = 0, force60 = 0, dump = 0;
integer srcdelay = 0;
integer hoff = 0, voff = 0, voff2 = 0, vofframe = -1, voffline = 0;
reg [8*160-1:0] out;
initial begin
	if (!$value$plusargs("cfg=%h", cfg)) cfg = 0;
	if (!$value$plusargs("cfg2=%h", cfg2)) cfg2 = 0;
	if (!$value$plusargs("cfgframe=%d", cfgframe)) cfgframe = -1;
	if (!$value$plusargs("cfgline=%d", cfgline)) cfgline = 0;
	if (!$value$plusargs("frames=%d", frames)) frames = 1;
	if (!$value$plusargs("first=%d", first)) first = 3;
	dump = $value$plusargs("out=%s", out);
	lace    = $test$plusargs("lace");
	dbl     = $test$plusargs("dbl");
	split   = $test$plusargs("split");
	rtg     = $test$plusargs("rtg");
	force60 = $test$plusargs("force60");
	if (!$value$plusargs("srcdelay=%d", srcdelay)) srcdelay = 0;
	if (!$value$plusargs("hoff=%d", hoff)) hoff = 0;
	if (!$value$plusargs("voff=%d", voff)) voff = 0;
	if (!$value$plusargs("voff2=%d", voff2)) voff2 = 0;
	if (!$value$plusargs("vofframe=%d", vofframe)) vofframe = -1;
	if (!$value$plusargs("voffline=%d", voffline)) voffline = 0;
end

// the OSD config, as userio_osd holds it (CLK_28; changes asynchronously to clk_148)
reg [11:0] crt_cfg = 12'd0;
reg        cfg_changed = 0;
initial #1 crt_cfg = cfg[11:0];


// ---- Amiga source ----
localparam W = 1816, H = 312;
integer i;
reg [23:0] img [0:W*H-1];
reg [8*300-1:0] framefn, hiresfn;
reg hl [0:H-1];
initial begin
	for (i = 0; i < H; i = i + 1) hl[i] = 0;
	if (!$value$plusargs("frame=%s", framefn)) framefn = "build/amiga_frame.hex";
	if (!$test$plusargs("split")) $readmemh(framefn, img);
	if ($value$plusargs("hires=%s", hiresfn)) $readmemh(hiresfn, hl);
end

reg [12:0] hcnt = 0;       // clk_114 in the line, 0..7263
reg [8:0]  vcnt = 300;     // start just before a vsync
reg        long_field = 0; // this field is the long one (lace)
wire [8:0] hpos = hcnt[12:4];
wire [12:0] h2 = (hcnt >= 13'd3632) ? hcnt - 13'd3632 : hcnt;   // +dbl: position in the half line
wire [8:0]  h2pos = h2[12:4];
reg        hs = 0, vs = 0;
reg [23:0] rgb = 0;
reg        hires = 0;
reg [1:0]  hs_d = 0, vs_d = 0;

// +split: the generated picture and Denise's HIRES at (vcnt, hpos)
function sp_hires(input [8:0] v, input [8:0] h);
	sp_hires = (v >= 151 && v <= 199) || (v >= 250) ||
	           (v == 150 && h >= 120) || (v == 200 && h >= 300);
endfunction
function [23:0] sp_rgb(input [8:0] v, input [8:0] h, input [10:0] x);
	reg [7:0] s, mk;
	begin
		s  = x[5] ? 8'hFF : 8'h00;
		mk = (v == 150) ? 8'hC8 : (v == 200) ? 8'h64 : 8'h00;
		// black up to hpos 88: hpos 0..12 already counts as the next line
		// (vcnt steps at hpos 0) but lands at the end of this line's buffer
		if (v < 26 || h < 89) sp_rgb = 24'h0;
		else if (sp_hires(v, h)) sp_rgb = {s, 8'h00, mk};     // {r, g, b}: red stripes
		else                     sp_rgb = {8'h00, s, mk};     // green stripes
	end
endfunction

always @(posedge clk_114) begin
	if (hcnt == 13'd7263) begin
		hcnt <= 0;
		if (vcnt == (long_field ? 9'd312 : 9'd311)) begin
			vcnt <= 0;
			long_field <= lace ? ~long_field : 1'b0;
		end else vcnt <= vcnt + 1'b1;
	end else hcnt <= hcnt + 1'b1;
	if (dbl) hs <= (h2pos >= 18 && h2pos < 35);
	else     hs <= (hpos >= 37 && hpos < 70);
	if (!long_field) begin
		if (vcnt == 2 && hpos == 37) vs <= 1;
		if (vcnt == 5 && hpos == 264) vs <= 0;
	end else begin
		if (vcnt == 2 && hpos == 264) vs <= 1;
		if (vcnt == 6 && hpos == 37) vs <= 0;
	end
	if (split) begin
		rgb   <= (vcnt >= H) ? 24'h0 : dbl ? sp_rgb(vcnt, h2pos, h2[12:2]) : sp_rgb(vcnt, hpos, hcnt[12:2]);
		hires <= (vcnt < H) && (dbl ? sp_hires(vcnt, h2pos) : sp_hires(vcnt, hpos));
	end else begin
		rgb   <= (vcnt >= H) ? 24'h0 : dbl ? img[vcnt * W + h2[11:1]] : img[vcnt * W + hcnt[12:2]];
		hires <= (vcnt < H) && hl[vcnt];
	end
	hs_d <= {hs_d[0], hs};
	vs_d <= {vs_d[0], vs};
end
// +srcdelay: the whole Amiga side N clk_114 later
reg [26:0] sd_line [0:255];
reg [7:0]  sd_wp = 8'd0;
initial for (i = 0; i < 256; i = i + 1) sd_line[i] = 27'd0;
wire [26:0] src_now = {hs_d[1], vs_d[1], hires, rgb};
always @(posedge clk_114) begin
	sd_line[sd_wp] <= src_now;
	sd_wp <= sd_wp + 8'd1;
end
// sd_line[sd_wp - n] holds src_now of n clocks ago
wire [7:0]  sd_rp = sd_wp - srcdelay[7:0];
wire [26:0] src = (srcdelay > 0) ? sd_line[sd_rp] : src_now;
wire        pal_hs = src[26], pal_vs = src[25], src_hires = src[24];
wire [23:0] src_rgb = src[23:0];

// ---- the two HDMI paths ----
wire n_clk, n_de, n_vs, n_hs, r_clk, r_de, r_vs, r_hs;
wire [11:0] n_d, r_d;
pal_to_ddr #(.CRT_WROM_FILE("../../rtl/openaars/adv7511/crt_wrom.mem"),
             .CRT_LUT_FILE("../../rtl/openaars/adv7511/crt_lut.mem"),
             .CRT_BLOOM_FILE("../../rtl/openaars/adv7511/crt_bloom.mem"),
             .CRT_HDEC_FILE("../../rtl/openaars/adv7511/crt_hdec.mem"),
             .CRT_HENC_FILE("../../rtl/openaars/adv7511/crt_henc.mem"),
             .CRT_HK_FILE("../../rtl/openaars/adv7511/crt_hk.mem")) dut (
	.clk_148(clk_148), .clk_114(clk_114), .reset(reset), .vga_clk_pixel(1'b0),
	.i_pal_hsync(pal_hs), .i_pal_vsync(pal_vs),
	.i_pal_r(src_rgb[23:16]), .i_pal_g(src_rgb[15:8]), .i_pal_b(src_rgb[7:0]),
	.i_hoffset(hoff[7:0]), .i_voffset(voff[7:0]), .i_rtg_enable(rtg),
	.i_crt_cfg(crt_cfg), .i_pal_hires(src_hires), .i_pal_shres(1'b0),
	.o_clk_pixel(n_clk), .o_de(n_de), .o_vsync(n_vs), .o_hsync(n_hs), .o_data(n_d)
);
pal_to_ddr_ref ref0 (
	.clk_148(clk_148), .clk_114(clk_114), .reset(reset), .vga_clk_pixel(1'b0),
	.i_pal_hsync(pal_hs), .i_pal_vsync(pal_vs),
	.i_pal_r(src_rgb[23:16]), .i_pal_g(src_rgb[15:8]), .i_pal_b(src_rgb[7:0]),
	.i_hoffset(8'd0), .i_voffset(8'd0), .i_rtg_enable(rtg),
	.o_clk_pixel(r_clk), .o_de(r_de), .o_vsync(r_vs), .o_hsync(r_hs), .o_data(r_d)
);

initial begin
	#200 reset = 0;
end
// +force60: both paths on the 60 Hz upsampler
initial begin
	#1;
	if ($test$plusargs("force60")) begin
		force dut.r_50hz = 1'b0;
		force ref0.r_50hz = 1'b0;
	end
end

// both line buffers start black (a real BRAM powers up 0 too)
initial for (i = 0; i < 16384; i = i + 1) begin
	dut.my50hzupsample.upsample_blk_ram.mem[i] = 0;
	dut.my60hzupsample.upsample_blk_ram.mem[i] = 0;
	ref0.my50hzupsample.upsample_blk_ram.mem[i] = 0;
	ref0.my60hzupsample.upsample_blk_ram.mem[i] = 0;
end

// ---- capture: what adv_ddr gets ----
wire        n_sel = dut.r_50hz;
wire        n_hdclk = dut.w_adv_clk;
wire        n_dee   = n_sel ? dut.w_50_adv_de : dut.w_60_adv_de;
wire        n_frame = n_sel ? dut.hd_50hz_gen.r_frame : dut.hd_60hz_gen.r_frame;
wire [23:0] n_px    = {dut.w_o_r, dut.w_o_g, dut.w_o_b};
wire        r_sel = ref0.r_50hz;
wire        r_hdclk = ref0.w_adv_clk;
wire        r_dee   = r_sel ? ref0.w_50_adv_de : ref0.w_60_adv_de;
wire        r_frame = r_sel ? ref0.hd_50hz_gen.r_frame : ref0.hd_60hz_gen.r_frame;
wire [23:0] r_px    = {ref0.w_o_r, ref0.w_o_g, ref0.w_o_b};

reg [23:0] fb_n [0:1280*720-1];
reg [23:0] fb_r [0:1280*720-1];
integer hdl = 0;
integer px_n = 0, px_r = 0, fno_n = 0, fno_r = 0, done_n = 0, done_r = 0, lit_n = 0;
reg ck_n = 0, ck_r = 0;

task dump_n(input integer n);
	integer fo, ko; reg [8*200-1:0] fn;
	begin
		$sformat(fn, "%0s_%0d.hex", out, n);
		fo = $fopen(fn, "w");
		for (ko = 0; ko < 1280*720; ko = ko + 1) $fwrite(fo, "%06x\n", fb_n[ko]);
		$fclose(fo);
	end
endtask

always @(posedge clk_148) begin
	ck_n <= n_hdclk;
	if (n_frame) begin
		if (fno_n >= first && fno_n < first + frames) begin
			$display("new frame %0d: %0d pixels, %0d non-black, path %0d Hz", fno_n, px_n, lit_n, n_sel ? 50 : 60);
			if (dump) dump_n(fno_n);
			done_n = done_n + 1;
		end
		fno_n = fno_n + 1; px_n = 0; lit_n = 0;
	end else if (ck_n && !n_hdclk && n_dee) begin
		if (px_n < 1280*720) fb_n[px_n] = n_px;
		if (n_px != 24'd0) lit_n = lit_n + 1;
		px_n = px_n + 1;
	end
end
integer diff, kd;
always @(posedge clk_148) begin
	ck_r <= r_hdclk;
	if (r_frame) begin
		if (fno_r >= first && fno_r < first + frames) begin
			// fb_n of the same frame is complete: the paths run in lockstep
			// (same clocks, same frame-end source), checked below
			diff = 0;
			for (kd = 0; kd < 1280*720; kd = kd + 1) if (fb_n[kd] !== fb_r[kd]) diff = diff + 1;
			$display("frame %0d: %0d pixels differ (ref %0d pixels, new frame no %0d)", fno_r, diff, px_r, fno_n);
			done_r = done_r + 1;
		end
		fno_r = fno_r + 1; px_r = 0;
	end else if (ck_r && !r_hdclk && r_dee) begin
		if (px_r < 1280*720) fb_r[px_r] = r_px;
		px_r = px_r + 1;
	end
end

// ---- logs: line phase (new path), frame ends and the config latch ----
integer fdp = 0;
reg [8*200-1:0] fname;
integer hdvs = 0, hdfno = 0;
reg     vs_q = 0;
always @(posedge clk_148) begin
	vs_q <= dut.w_hd_vsync;
	if (dut.w_hd_vsync && !vs_q) hdvs = hdvs + 1;
	if (n_frame) begin
		// the frame that ends here: same numbering as "new frame N"
		$display("hd frame %0d: %0d lines, %0d vsync", hdfno, hdl, hdvs);
		hdfno = hdfno + 1;
		hdvs = 0;
		hdl = 0;
	end
	if (dut.w_m_lstart) begin
		if (dump) begin
			if (fdp == 0) begin $sformat(fname, "%0s_phase.txt", out); fdp = $fopen(fname, "w"); end
			$fwrite(fdp, "%0d %0d %0d %0d\n", fno_n, hdl, dut.w_m_phase, dut.w_m_lhires);
		end
		hdl = hdl + 1;
	end
end
// the OSD-change leg
always @(posedge clk_148)
	if (cfgframe >= 0 && !cfg_changed && fno_n == cfgframe && hdl == cfgline) begin
		cfg_changed = 1;
		#3.1 crt_cfg = cfg2[11:0];
		$display("cfg change %03h -> %03h at %0t (frame %0d line %0d)", cfg[11:0], cfg2[11:0], $time, fno_n, hdl);
	end
// +vpdebug: the 50 Hz upsampler's HD raster restarts (Video Pos VPOS)
wire vp_real = dut.my50hzupsample.w_vp_realf;
wire vp_virt = dut.my50hzupsample.r_vp_fire;
always @(posedge clk_114)
	if ($test$plusargs("vpdebug") && (vp_real || vp_virt))
		$display("vp %0s restart at input line %0d hpos %0d: cnt %0d cyc %0d n1 %0d n2 %0d p0 %0d p1 %0d tgt %0d ph %0d since %0d s %0d dbl %0d",
		         vp_real ? "real" : "virtual", vcnt, hpos, dut.my50hzupsample.r_vp_cnt, dut.my50hzupsample.r_vp_cyc,
		         dut.my50hzupsample.r_vp_n1, dut.my50hzupsample.r_vp_n2, dut.my50hzupsample.r_vp_p0,
		         dut.my50hzupsample.r_vp_p1, dut.my50hzupsample.r_vp_tgt, dut.my50hzupsample.r_vp_ph,
		         dut.my50hzupsample.r_vp_since, $signed(dut.my50hzupsample.r_vp_s), dut.my50hzupsample.r_vp_dbl);
// the VPOS-change legs
reg voff_changed = 0;
always @(posedge clk_148)
	if (vofframe >= 0 && !voff_changed && fno_n == vofframe && hdl == voffline) begin
		voff_changed = 1;
		#3.1 voff = voff2;
		$display("voff change -> %0d at %0t (frame %0d line %0d)", voff2, $time, fno_n, hdl);
	end
reg [9:0] cfg_q = 10'd0;
reg ck_fend = 0;
always @(posedge clk_148) begin
	cfg_q <= dut.r_crt_cfg;
	if (cfgframe >= 0 && dut.w_crt_fend) $display("frame end at %0t (frame no %0d)", $time, fno_n);
	if (dut.r_crt_cfg != cfg_q)
		$display("cfg latched %03h -> %03h at %0t, at frame end: %0d", cfg_q, dut.r_crt_cfg, $time, ck_fend);
end
always @(posedge clk_148) ck_fend <= dut.w_crt_fend;   // the latch takes effect the clock after w_crt_fend

// where the upsampler takes the line's resolution sample (hpos), once
integer shown = 0;
always @(posedge clk_114)
	if (shown == 0 && dut.my50hzupsample.r_wcnt == 11'd512 && vcnt == 9'd100 && !dbl) begin
		$display("resolution sample at hpos %0d (line %0d)", hpos, vcnt);
		shown = 1;
	end

// ---- the horizontal beam filter (crt_beamh.v, clk_114) ----
// its frame latch: {on, bloom, width}, logged (once per latch, when it
// changed) with the input line it moved in
reg [4:0] beam_q = 5'd0;
reg       beam_set = 1'b0;
wire [4:0] beam_now = {dut.my_beamh.r_on, dut.my_beamh.r_bloom, dut.my_beamh.r_width};
always @(posedge clk_114) begin
	beam_set <= dut.my_beamh.lset;          // r_on has moved after this
	if (beam_set && beam_now != beam_q) begin
		$display("beam latched %02h -> %02h at %0t, input line %0d hpos %0d, sync delay %0d",
		         beam_q, beam_now, $time, vcnt, hpos, dut.my_beamh.w_sdly);
		beam_q <= beam_now;
	end
end
// bypass: whenever the filter is not on, what the upsamplers get is the
// input exactly (RGB, syncs, HIRES), every clk_114
integer bh_clk = 0, bh_on = 0, bh_bad = 0;
always @(posedge clk_114) if (!reset) begin
	bh_clk = bh_clk + 1;
	if (dut.my_beamh.r_on) bh_on = bh_on + 1;
	else if ({dut.w_bh_r, dut.w_bh_g, dut.w_bh_b, dut.w_bh_hs, dut.w_bh_vs, dut.w_bh_hires, dut.w_bh_shres} !==
	         {dut.w_pal_r, dut.w_pal_g, dut.w_pal_b, dut.w_pal_hsync, dut.w_pal_vsync, dut.i_pal_hires, dut.i_pal_shres})
		bh_bad = bh_bad + 1;
end
// +sdump: one input field of its output stream, from frame 2 on
integer sdf = 0, sd_state = 0;
reg [8*300-1:0] sdfn;
initial if ($value$plusargs("sdump=%s", sdfn)) sdf = $fopen(sdfn, "w");
always @(posedge clk_114) if (sdf != 0) begin
	if (sd_state == 0 && fno_n >= 2 && vcnt == 0 && hcnt == 0) sd_state = 1;
	else if (sd_state == 1 && vcnt == 0 && hcnt == 0) begin sd_state = 2; $fclose(sdf); end
	if (sd_state == 1 && dut.my_beamh.o_stb)
		$fwrite(sdf, "%0d %0d %06x\n", vcnt, hcnt[12:2], dut.my_beamh.f_rgb);
end

initial begin
	wait (done_n >= frames && done_r >= frames);
	#100;
	$display("beam bypass: %0d mismatches in %0d clocks off, %0d clocks on", bh_bad, bh_clk - bh_on, bh_on);
	$display("done: %0d frames", frames);
	$finish;
end
endmodule

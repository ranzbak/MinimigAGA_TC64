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
//   +cfg=H       OSD video config {scaling, beam, bloom, mask, hr_filter,
//                lr_filter, scanline}, 14 bits, hex (default 0; scaling,
//                bits 13:12: 0 line rate, 1 sharp, 2 area)
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
//   +rtg         i_rtg_enable = 1 on the Amiga picture above, with the pixel
//                strobe (vga_clk_pixel) VGA_PIXEL's chipset one: vga_strobe,
//                one clk_114 in 4 (minimig_virtual_top.v; one in 8 with
//                +dbl).  Without +rtg / +rtg720* the strobe is 0
//   +rtg720      an RTG source instead (see "RTG source" below): the
//                Picasso96 mode 1280x720 HiColor at 56.72 MHz, 1504 x 754
//                (50.0 Hz), i_rtg_enable 1
//   +rtg720c     the same at 113.44 MHz (256 colours, a CLUT mode), 2496 x
//                757 (60.04 Hz)
//   +rtght=N +rtgvt=N   N pixels per line / lines per frame instead
//   +rtgw=N +rtgh=N     N active pixels per line / active lines (default
//                1280 / 720)
//   +rtgvbp=N    lines from the end of vsync to the first active line
//                (default: the frame's rest after the active lines, 12
//                front porch, 5 vsync -- Picasso96 vertical sync position 12)
//   +hoffrtg=N +voffrtg=N   the RTG picture's Video Pos pair (default 0)
//   +hoff=N +voff=N   the OSD Video Pos offsets of the new path (8 bit,
//                signed, -128..127; default 0, the reference path keeps 0)
//   +voff2=N +vofframe=F +voffline=L   change VPOS to voff2 during HD frame
//                F, line L of the new path (the VPOS-change legs)
//   +force60     both paths use the 60 Hz upsampler (r_50hz 0: forced)
//   +ring16      the line-rate mode on all 16 line buffers (see "ring")
//   +ntsc        NTSC input: 262-line fields (263 long with +lace), the
//                picture's lines 0..261; the line stays 227 CCK as Agnus
//                makes it here (agnus_beamcounter.v: no long lines), vsync
//                lines 2..5 as in PAL.  frame_freq then picks the 60 Hz path
//   +swfrom=F +swto=G   input fields F..G-1 NTSC, the others PAL (the
//                mode-switch leg, golden.sh: PAL -> NTSC -> PAL); a field
//                is one vcnt wrap, the first (partial) one is field 0
//   +first=N +frames=M   compare (and dump) HD frames N .. N+M-1 (default 3, 1)
//   +out=PREFIX  dump the new path's frames as PREFIX_<n>.hex (RRGGBB per
//                line, raster order) and its line phases as PREFIX_phase.txt:
//                per HD line "frame line phase hires vphase ratio y cur next"
//                (y: the exact-ratio stepping's position, 1/2^20 line; cur,
//                next: the source lines (vcnt) in the two buffers read)
//   +pins=F +pinsfile=PATH   dump the pins "sig F" hashes (see below), one
//                line per clk_148 half-cycle, "C D V H XXX" (o_clk_pixel
//                o_de o_vsync o_hsync, o_data in hex), to PATH (default
//                build/pins_<F>.txt); pins_diff.py compares two dumps
//   +nosync=F    from HD frame F of the new path on, its Amiga hsync and
//                vsync are held inactive (the chipset's syncs stopped, as in
//                RTG mode with the sync start past the frame size) while RGB
//                runs on; the reference path keeps them.  The signal
//                generator's watchdog then ends one frame of 1500 lines
//                (1499 hsyncs counted) and the raster free-runs at 750
//                lines (749 counted); a frame reaching 4000 lines ends the
//                run ("hd frame N: L lines, V vsync, no frame end")
// Prints "frame N: D pixels differ" per compared frame, "pic N: H P" for
// EVERY HD frame of the new path (a 64-bit FNV-1a hash of its captured
// pixels in raster order, and their count), "sig N: H C" for every HD frame
// at the pins (pal_to_ddr's outputs o_clk_pixel, o_de, o_vsync, o_hsync,
// o_data folded in at both clk_148 edges, from one rising edge of o_vsync
// to the next; C = clk_148 cycles), "fsig N" the same per input field N
// -- golden.sh compares them against the frames of the RTL before the
// scaler work (3987b84) -- "path N -> M at frame F field G" when the new
// path's 50/60 Hz choice moves, "lf N L" when HD frame N starts (L: in a
// long field), "lines N" (pixels
// captured, non-black), the path (50/60), "hd frame N: L lines, V vsync"
// for every HD frame of the new path (HD lines, and rising edges of the
// selected signal generator's vsync in it), with an RTG source "rtg path N:
// 1:1|time" (the upsampler's path in HD frame N, at line 360), every change of the
// frame-latched config ("cfg latched ... at frame end: 1" when it happened
// the clock after a frame end; "beam latched ..." for the beam filter's own
// latch in clk_114, with the input line it happened in).
// The vsync check at the pins: every HD frame from 1 on gets exactly one
// o_vsync pulse, 5 HD lines long (o_hsync rises while it is high), where a
// pulse that starts in a frame's lines 0..4 is the frame before's (late:
// signal_generator.sv).  "vsync FAIL: ..." for each fault, and at the end
// "vsync check: N frames, F faults" (golden.sh fails a leg on any FAIL).
//
// RTG source (+rtg720, +rtg720c): what minimig_virtual_top.v gives
// pal_to_ddr in RTG mode.  One strobe (vga_clk_pixel = VGA_PIXEL) per RTG
// pixel, in clock S, only in the active area (VGA_PIXEL is rtg_blank-gated).
// Its pixel on i_pal_r/g/b, black elsewhere, as the RTL times it (whatever
// pal_to_hd_upsample's tap): a 16-bit pixel (2 clk_114) in clocks S and
// S + 1 -- VideoStream.vhd's word is out ahead of the fetch strobe, VGA_PIXEL
// is rtg_pixel_d (one clock after it), red_reg one more -- except a line's
// first pixel, only in S + 1 (red_reg's blank gate, rtg_blank_d2); a CLUT
// pixel (+rtg720c, 1 clk_114) only in S + 2 (akiko.vhd's CLUT register).
// Lines of +rtght pixels of 2 clk_114 (+rtg720c: of 1); hsync pixels
// 0..63, the active pixels from 128 on; +rtgvt lines: vsync lines 0..4
// (both edges at an hsync start, as Agnus's programmable sync), then
// +rtgvbp lines, +rtgh active lines, the rest.  (minimig.card
// programs the line length in colour clocks: 16 pixels at 56.72 MHz, 32
// at 113.44 MHz -- 1504 and 2496 are the nearest to 720p50 / 720p60.)
// Syncs active high, as pal_to_ddr gets them.  The pixel at (x, y) is
// 800000 | y << 11 | x (never black; rtg_check.py decodes it).
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
integer hoffrtg = 0, voffrtg = 0;
integer ntscfrom = -1, ntscto = -1;
reg ntsc = 0;
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
	rtg     = $test$plusargs("rtg");   // +rtg720* match too
	force60 = $test$plusargs("force60");
	if (!$value$plusargs("srcdelay=%d", srcdelay)) srcdelay = 0;
	if (!$value$plusargs("hoff=%d", hoff)) hoff = 0;
	if (!$value$plusargs("hoffrtg=%d", hoffrtg)) hoffrtg = 0;
	if (!$value$plusargs("voffrtg=%d", voffrtg)) voffrtg = 0;
	if (!$value$plusargs("voff=%d", voff)) voff = 0;
	if (!$value$plusargs("voff2=%d", voff2)) voff2 = 0;
	if (!$value$plusargs("vofframe=%d", vofframe)) vofframe = -1;
	if (!$value$plusargs("voffline=%d", voffline)) voffline = 0;
	ntsc = $test$plusargs("ntsc");
	if (!$value$plusargs("swfrom=%d", ntscfrom)) ntscfrom = -1;
	if (!$value$plusargs("swto=%d", ntscto)) ntscto = -1;
end

// the OSD config, as userio_osd holds it (CLK_28; changes asynchronously to clk_148)
reg [13:0] crt_cfg = 14'd0;
reg        cfg_changed = 0;
initial #1 crt_cfg = cfg[13:0];


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
integer    field_no = 0;   // vcnt wraps so far
reg        ntsc_f = 0;     // this field is an NTSC one
initial #1 ntsc_f = ntsc || (ntscfrom == 0);
wire [8:0] vlast = ntsc_f ? (long_field ? 9'd262 : 9'd261) : (long_field ? 9'd312 : 9'd311);
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
		if (vcnt == vlast) begin
			vcnt <= 0;
			long_field <= lace ? ~long_field : 1'b0;
			field_no = field_no + 1;
			ntsc_f <= ntsc || (field_no >= ntscfrom && field_no < ntscto);
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
wire [26:0] src_pal = (srcdelay > 0) ? sd_line[sd_rp] : src_now;

// ---- RTG source (+rtg720, +rtg720c; see the header) ----
reg     rtgsrc = 0;
integer rt_cpp = 2, rt_ht = 1504, rt_vt = 754, rt_w = 1280, rt_va = 720, rt_vbp = 24;
localparam RT_VS = 5, RT_HS = 64, RT_HA0 = 128;
localparam RT_FP = 12;   // lines from the picture to vsync: Picasso96 vert. sync position
initial begin
	rtgsrc = $test$plusargs("rtg720");
	if ($test$plusargs("rtg720c")) rt_cpp = 1;
	if (!$value$plusargs("rtght=%d", rt_ht)) rt_ht = (rt_cpp == 1) ? 2496 : 1504;
	if (!$value$plusargs("rtgvt=%d", rt_vt)) rt_vt = (rt_cpp == 1) ? 757 : 754;
	if (!$value$plusargs("rtgw=%d", rt_w)) rt_w = 1280;
	if (!$value$plusargs("rtgh=%d", rt_va)) rt_va = 720;
	if (!$value$plusargs("rtgvbp=%d", rt_vbp)) rt_vbp = rt_vt - rt_va - RT_VS - RT_FP;
	if (rtgsrc) $display("rtg source: %0d x %0d pixels of %0d clk_114, %0d x %0d active, back porch %0d, %s",
	                     rt_ht, rt_vt, rt_cpp, rt_w, rt_va, rt_vbp, (rt_cpp == 1) ? "CLUT" : "16-bit");
end
integer rt_c = 0, rt_v = 0;   // clk_114 in the line, line in the frame
always @(posedge clk_114) begin
	if (rt_c == rt_ht * rt_cpp - 1) begin
		rt_c <= 0;
		rt_v <= (rt_v == rt_vt - 1) ? 0 : rt_v + 1;
	end else rt_c <= rt_c + 1;
end
integer rt_y, rt_q, rt_p;
reg [23:0] rt_rgb;
reg        rt_stb, rt_hs, rt_vs;
always @* begin
	rt_y   = rt_v - (RT_VS + rt_vbp);   // active line, 0 .. +rtgh - 1
	rt_q   = rt_c - RT_HA0 * rt_cpp;    // clk_114 since the line's first strobe
	// the pixel on RGB this clock (see the header), -1 none
	if (rt_cpp == 1) rt_p = rt_q - 2;                                     // CLUT: S + 2
	else             rt_p = (rt_q >= 1 && rt_q < rt_w * 2) ? rt_q / 2 : -1;   // 16-bit: S, S + 1
	rt_hs  = (rt_c < RT_HS * rt_cpp);
	rt_vs  = (rt_v < RT_VS);
	rt_stb = (rt_y >= 0 && rt_y < rt_va && rt_q >= 0 && rt_q < rt_w * rt_cpp && rt_q % rt_cpp == 0);
	rt_rgb = (rt_y >= 0 && rt_y < rt_va && rt_p >= 0 && rt_p < rt_w) ?
	         24'h800000 | (rt_y[9:0] << 11) | rt_p[10:0] : 24'h0;
end
wire [26:0] src = rtgsrc ? {rt_hs, rt_vs, 1'b0, rt_rgb} : src_pal;
// the pixel strobe: VGA_PIXEL as minimig_virtual_top.v makes it.  RTG
// source: rtg_pixel_d (above); the Amiga picture with +rtg: vga_strobe,
// its counter as there (_15khz: steps of 2 -> one clk_114 in 4).  The
// hardware never gets that pair (with RTG on VGA_PIXEL is the RTG strobe);
// its 312-line frames take the time-based path, which does not use the
// strobe (crt_run.sh rtg, rtg0: the CRT effects gated off with RTG on)
reg [2:0] vga_strobe_ctr = 3'd0;
always @(posedge clk_114)
	vga_strobe_ctr <= !dbl ? {vga_strobe_ctr[2:1], 1'b0} + 3'b010 : vga_strobe_ctr + 3'b001;
wire pix_stb = rtgsrc ? rt_stb : rtg ? (vga_strobe_ctr == 3'b000) : 1'b0;
wire        pal_hs = src[26], pal_vs = src[25], src_hires = src[24];
// +nosync: the new path's syncs from HD frame nosync on (set below)
integer     nosync = -1;
reg         ns_on = 1'b0;
initial if (!$value$plusargs("nosync=%d", nosync)) nosync = -1;
wire        dut_hs = ns_on ? 1'b0 : pal_hs, dut_vs = ns_on ? 1'b0 : pal_vs;
wire [23:0] src_rgb = src[23:0];

// ---- the two HDMI paths ----
wire n_clk, n_de, n_vs, n_hs, r_clk, r_de, r_vs, r_hs;
wire [11:0] n_d, r_d;
pal_to_ddr #(.CRT_WROM_FILE("../../rtl/openaars/adv7511/crt_wrom.mem"),
             .CRT_LUT_FILE("../../rtl/openaars/adv7511/crt_lut.mem"),
             .CRT_BLOOM_FILE("../../rtl/openaars/adv7511/crt_bloom.mem"),
             .CRT_HDEC_FILE("../../rtl/openaars/adv7511/crt_hdec.mem"),
             .CRT_HENC_FILE("../../rtl/openaars/adv7511/crt_henc.mem"),
             .CRT_HK_FILE("../../rtl/openaars/adv7511/crt_hk.mem"),
             .CRT_SDEC_FILE("../../rtl/openaars/adv7511/crt_sdec.mem"),
             .CRT_SENC_FILE("../../rtl/openaars/adv7511/crt_senc.mem"),
             .CRT_SWROM_FILE("../../rtl/openaars/adv7511/crt_swrom.mem"),
             .OSD_FONT_FILE("../../rtl/openaars/adv7511/osd_font.mem")) dut (
	.clk_148(clk_148), .clk_114(clk_114), .reset(reset), .vga_clk_pixel(pix_stb),
	.i_pal_hsync(dut_hs), .i_pal_vsync(dut_vs),
	.i_pal_r(src_rgb[23:16]), .i_pal_g(src_rgb[15:8]), .i_pal_b(src_rgb[7:0]),
	.i_hoffset(hoff[7:0]), .i_voffset(voff[7:0]), .i_rtg_enable(rtg),
	.i_hoffset_rtg(hoffrtg[7:0]), .i_voffset_rtg(voffrtg[7:0]),
	.i_crt_cfg(crt_cfg), .i_pal_hires(src_hires), .i_pal_shres(1'b0),
	.i_osd_clk(osd_clk), .i_osd_txt(osd_txt),   // the OSD text layer: tb_crt_osd2.vh
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
		// the new path's r_50hz is a wire (~myfreq.o_hz60): Verilator's force
		// reaches a register's readers, not a wire's, so force the register
		force dut.myfreq.r_hz60 = 1'b1;
		force ref0.r_50hz = 1'b0;
	end
end

// the line buffers start black (a real BRAM powers up 0 too)
initial for (i = 0; i < 32768; i = i + 1) dut.myupsample.upsample_blk_ram.mem[i] = 0;
initial for (i = 0; i < 16384; i = i + 1) begin
	ref0.my50hzupsample.upsample_blk_ram.mem[i] = 0;
	ref0.my60hzupsample.upsample_blk_ram.mem[i] = 0;
end

// ---- capture: what adv_ddr gets ----
wire        n_sel = dut.r_50hz;
wire        n_hdclk = dut.w_adv_clk;
wire        n_dee   = dut.w_adv_de;
wire        n_frame = dut.hd_gen.r_frame;
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

// pixel hash per HD frame (all frames), FNV-1a 64
localparam [63:0] FNV0 = 64'hcbf29ce484222325, FNVP = 64'h00000100000001b3;
reg [63:0] ph_n = FNV0;
reg        sel_q = 1'b1;
always @(posedge clk_148) begin
	ck_n <= n_hdclk;
	sel_q <= n_sel;
	if (n_sel != sel_q) $display("path %0d -> %0d at frame %0d field %0d", sel_q ? 50 : 60, n_sel ? 50 : 60, fno_n, field_no);
	if (n_frame) begin
		$display("pic %0d: %016h %0d", fno_n, ph_n, px_n);
		ph_n = FNV0;
		if (fno_n >= first && fno_n < first + frames) begin
			$display("new frame %0d: %0d pixels, %0d non-black, path %0d Hz", fno_n, px_n, lit_n, n_sel ? 50 : 60);
			if (dump) dump_n(fno_n);
			done_n = done_n + 1;
		end
		fno_n = fno_n + 1; px_n = 0; lit_n = 0;
		$display("lf %0d %0d", fno_n, long_field);   // the HD frame starting: long field?
	end else if (ck_n && !n_hdclk && n_dee) begin
		ph_n = (ph_n ^ {40'd0, n_px}) * FNVP;
		if (px_n < 1280*720) fb_n[px_n] = n_px;
		if (n_px != 24'd0) lit_n = lit_n + 1;
		px_n = px_n + 1;
	end
end
// the pins, both clk_148 edges, from one o_vsync rising edge to the next
reg [63:0] sg_h = FNV0;
integer    sg_n = 0, sg_c = 0;
reg        sg_vs = 1'b0;
wire [15:0] pins = {n_clk, n_de, n_vs, n_hs, n_d};
// +pins=F: the samples sig F folds in, as text, one line each
integer    pn_f = -1, pn_fd = 0, pn_c = 0;
reg [8*200-1:0] pn_fn;
initial if ($value$plusargs("pins=%d", pn_f)) begin
	if (!$value$plusargs("pinsfile=%s", pn_fn)) $sformat(pn_fn, "build/pins_%0d.txt", pn_f);
	pn_fd = $fopen(pn_fn, "w");
	if (pn_fd == 0) $display("pins: cannot open %0s", pn_fn);
end
task pins_line;
	begin
		$fwrite(pn_fd, "%b %b %b %b %03h\n", pins[15], pins[14], pins[13], pins[12], pins[11:0]);
		pn_c = pn_c + 1;
	end
endtask
always @(posedge clk_148) begin
	sg_vs <= n_vs;
	if (n_vs && !sg_vs) begin
		$display("sig %0d: %016h %0d", sg_n, sg_h, sg_c);
		sg_n = sg_n + 1; sg_h = FNV0; sg_c = 0;
		if (pn_fd != 0 && sg_n == pn_f + 1) begin
			$fclose(pn_fd); pn_fd = 0;
			$display("pins %0d: %0d lines", pn_f, pn_c);
		end
	end
	if (pn_fd != 0 && sg_n == pn_f) pins_line;
	sg_h = (sg_h ^ {48'd0, pins}) * FNVP;
	sg_c = sg_c + 1;
end
always @(negedge clk_148) begin
	if (pn_fd != 0 && sg_n == pn_f) pins_line;
	sg_h = (sg_h ^ {47'd0, 1'b1, pins}) * FNVP;
end
final if (pn_fd != 0) begin
	$fclose(pn_fd);
	$display("pins %0d: the run ended inside the window (%0d lines)", pn_f, pn_c);
end
// the same per INPUT field ("fsig N": field N of the Amiga side, from its
// first clk_148 to its last): windows at fixed times, so a design that
// puts out one vsync more or less (the two-chain design's splice at a
// 50/60 Hz switch) does not renumber the later ones
reg [63:0] fs_h = FNV0;
integer    fs_n = 0, fs_c = 0;
always @(posedge clk_148) begin
	if (field_no != fs_n) begin
		$display("fsig %0d: %016h %0d", fs_n, fs_h, fs_c);
		fs_n = field_no; fs_h = FNV0; fs_c = 0;
	end
	fs_h = (fs_h ^ {48'd0, pins}) * FNVP;
	fs_c = fs_c + 1;
end
always @(negedge clk_148) fs_h = (fs_h ^ {47'd0, 1'b1, pins}) * FNVP;
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

// ---- the vsync check at the pins (see the header) ----
localparam VC_N = 4096;
integer vc_cnt [0:VC_N-1];
integer vc_f = 0, vc_hs = 0, vc_bad = 0, vc_k, vc_done = 0;
reg     vc_vq = 1'b0, vc_hq = 1'b0;
initial for (vc_k = 0; vc_k < VC_N; vc_k = vc_k + 1) vc_cnt[vc_k] = 0;
always @(posedge clk_148) begin
	vc_vq <= n_vs;
	vc_hq <= n_hs;
	if (n_hs && !vc_hq) vc_hs = vc_hs + 1;
	if (n_vs && !vc_vq) begin
		vc_hs = 0;
		vc_k = (dut.hd_gen.vt_count < 5) ? vc_f - 1 : vc_f;
		if (vc_k >= 0 && vc_k < VC_N) vc_cnt[vc_k] = vc_cnt[vc_k] + 1;
	end
	if (!n_vs && vc_vq && vc_hs != 5) begin
		vc_bad = vc_bad + 1;
		$display("vsync FAIL: a pulse of %0d lines, ending in HD frame %0d", vc_hs, vc_f);
	end
	if (n_frame) begin
		// HD frame vc_f + 1 starts: frame vc_f - 1's late lines are over
		if (vc_f >= 2 && vc_f - 1 < VC_N) begin
			vc_done = vc_done + 1;
			if (vc_cnt[vc_f - 1] != 1) begin
				vc_bad = vc_bad + 1;
				$display("vsync FAIL: HD frame %0d has %0d vsync pulses", vc_f - 1, vc_cnt[vc_f - 1]);
			end
		end
		vc_f = vc_f + 1;
	end
end
final $display("vsync check: %0d frames, %0d faults", vc_done, vc_bad);

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
			$fwrite(fdp, "%0d %0d %0d %0d %0d %0d %0d %0d %0d\n", fno_n, hdl, dut.w_m_phase, dut.w_m_lhires,
			        dut.w_m_vphase, dut.r_ratio, $signed(dut.myupsample.r_yl), rg_vc[dut.myupsample.r_rslot],
			        rg_vc[dut.myupsample.w_r16_o ? dut.myupsample.r_rslot + 4'd1 : {1'b0, dut.myupsample.r_rslot[2:0] + 3'd1}]);
		end
		// the RTG source: the path this HD frame shows it on (mid-frame)
		if (rtgsrc && hdl == 360)
			$display("rtg path %0d: %0s", hdfno, dut.myupsample.r_rtg_o ? "1:1" : "time");
		hdl = hdl + 1;
	end
	if (nosync >= 0 && fno_n >= nosync) ns_on <= 1'b1;
	// +nosync without a frame restart: the frame never ends, stop here
	if (nosync >= 0 && hdl >= 4000) begin
		$display("hd frame %0d: %0d lines, %0d vsync, no frame end", hdfno, hdl, hdvs);
		$finish;
	end
end
// the OSD-change leg
always @(posedge clk_148)
	if (cfgframe >= 0 && !cfg_changed && fno_n == cfgframe && hdl == cfgline) begin
		cfg_changed = 1;
		#3.1 crt_cfg = cfg2[13:0];
		$display("cfg change %03h -> %03h at %0t (frame %0d line %0d)", cfg[11:0], cfg2[11:0], $time, fno_n, hdl);
	end
// +vpdebug: the 50 Hz upsampler's HD raster restarts (Video Pos VPOS)
wire vp_real = dut.myupsample.w_vp_realf;
wire vp_virt = dut.myupsample.r_vp_fire;
always @(posedge clk_114)
	if ($test$plusargs("vpdebug") && (vp_real || vp_virt))
		$display("vp %0s restart at input line %0d hpos %0d: cnt %0d cyc %0d n1 %0d n2 %0d p0 %0d p1 %0d tgt %0d ph %0d since %0d s %0d dbl %0d",
		         vp_real ? "real" : "virtual", vcnt, hpos, dut.myupsample.r_vp_cnt, dut.myupsample.r_vp_cyc,
		         dut.myupsample.r_vp_n1, dut.myupsample.r_vp_n2, dut.myupsample.r_vp_p0,
		         dut.myupsample.r_vp_p1, dut.myupsample.r_vp_tgt, dut.myupsample.r_vp_ph,
		         dut.myupsample.r_vp_since, $signed(dut.myupsample.r_vp_s), dut.myupsample.r_vp_dbl);
// the VPOS-change legs
reg voff_changed = 0;
always @(posedge clk_148)
	if (vofframe >= 0 && !voff_changed && fno_n == vofframe && hdl == voffline) begin
		voff_changed = 1;
		#3.1 voff = voff2;
		$display("voff change -> %0d at %0t (frame %0d line %0d)", voff2, $time, fno_n, hdl);
	end
reg [11:0] cfg_q = 12'd0;
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
	if (shown == 0 && dut.myupsample.r_wcnt == 11'd512 && vcnt == 9'd100 && !dbl) begin
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

// ---- the line-buffer ring (findings/scaler/plan.md step 3) ----
// Bench-side bookkeeping of what the upsampler's write side puts where:
// every time it starts a new input line (its buffer toggle), the slot the
// line goes to gets the line's number (lines started since power-up) and
// its source line.  Per HD line the read side's two slots (o_hd_*:
// r_rslot; o_hd_next: the one after it) are looked up, and while the HD
// line is active (DE) every clk_148 checks
//   rd-wr        neither slot is the one the write side is writing
//                (r_addra's slot, while it writes): the reader never reads
//                a line slot the writer is writing
//   overwritten  neither slot got a new line since the HD line started
// and, in the exact-ratio mode (step 4), per HD line
//   wrongline    the cur slot holds the line the stepping asks for: the
//                restart's first line + floor(y)
// All three over the active HD lines whose cur line is of this frame --
// line-rate mode: from the frame's first line on (the top HD lines show
// buffers written before the restart, by design; at NTSC and 31 kHz the
// write side's vsync lines are still running on through those buffers
// then -- today's behaviour, in the golden frames -- "top" counts those
// reads); exact-ratio mode: a >= 0.  Printed per HD frame: "ring N: L
// lines, lag A..B, rd-wr R, overwritten O, wrongline W, ratio X (top T),
// time lag C..D", lag = the line being written minus the cur line at the
// line's first read, time lag the same in lines of time (the write side's
// position inside its line counted) at the first read (C, >= 2: the next
// line is complete) and at the last (D, < 16: cur not yet overwritten).
integer rg_line [0:15];            // number of the line in each slot
integer rg_vc [0:15];              // and its source line (vcnt)
integer rg_gl = 0;                 // lines started so far
integer rg_first = 0;              // the first line after the last write-side restart
reg     rg_tq = 1'b0;
realtime rg_tt = 0, rg_tl = 64000;   // the last toggle's time, the line time (ns)
reg     rg_wpend = 1'b0;
initial for (i = 0; i < 16; i = i + 1) begin rg_line[i] = -1000; rg_vc[i] = -1; end
always @(posedge clk_114) begin
	if (dut.myupsample.w_vp_wr_reset) rg_wpend = 1'b1;
	// the toggle flipped at the last edge: r_wslot names the new line's slot
	if (dut.myupsample.s_next_buf[0] != rg_tq) begin
		if ($realtime - rg_tt > 60000 && $realtime - rg_tt < 68000) rg_tl = $realtime - rg_tt;
		rg_tt = $realtime;
		rg_line[dut.myupsample.r_wslot] = rg_gl;
		rg_vc[dut.myupsample.r_wslot] = vcnt;
		if (rg_wpend) begin rg_first = rg_gl; rg_wpend = 1'b0; end
		rg_gl = rg_gl + 1;
	end
	rg_tq <= dut.myupsample.s_next_buf[0];
end
wire       rg_ratio = dut.myupsample.w_rat_o;
wire       rg_r16   = dut.myupsample.w_r16_o;
reg  [3:0] rg_cs = 0, rg_ns = 0;
integer    rg_cl = 0, rg_nl = 0, rg_a = 0;
reg        rg_act = 1'b0, rg_cnt = 1'b0;
real       rg_f, rg_fmin = 99, rg_fmax = -99, rg_flast = 0;   // the lag in time, at the line's first and last read
integer    rg_rw = 0, rg_rwt = 0, rg_ow = 0, rg_wl = 0, rg_lmin = 99, rg_lmax = -99, rg_lines = 0, rg_lag;
always @(posedge clk_148) begin
	if (dut.myupsample.r_line_start) begin
		// r_rslot moved at the last edge
		rg_cs = dut.myupsample.r_rslot;
		rg_ns = (rg_r16 || rg_ratio) ? rg_cs + 4'd1 : {1'b0, rg_cs[2:0] + 3'd1};
		rg_cl = rg_line[rg_cs]; rg_nl = rg_line[rg_ns];
		rg_a  = $signed(dut.myupsample.r_yl[29:20]);
		rg_act = 1'b0;
		rg_cnt = rg_ratio ? (rg_a >= 0) : (!rg_wpend && rg_cl >= rg_first);
		if (rg_ratio && rg_a >= 0 && hdl < 720 && rg_cl != rg_first + rg_a) begin
			rg_wl = rg_wl + 1;
			if (rg_wl <= 5) $display("ring wrongline: frame %0d line %0d a %0d holds line %0d (first %0d)", fno_n, hdl, rg_a, rg_cl, rg_first);
		end
	end
	if (n_dee) begin
		if (!rg_act) begin
			rg_act = 1'b1;
			if (rg_cnt) begin
				rg_lines = rg_lines + 1;
				rg_lag = (rg_gl - 1) - rg_cl;
				if (rg_lag < rg_lmin) rg_lmin = rg_lag;
				if (rg_lag > rg_lmax) rg_lmax = rg_lag;
				rg_f = (rg_gl - 1) + ($realtime - rg_tt) / rg_tl - rg_cl;
				if (rg_f < rg_fmin) rg_fmin = rg_f;
				if ($test$plusargs("ringdbg") && rg_lag > 4) $display("ringdbg frame %0d line %0d lag %0d cl %0d first %0d gl %0d vcnt %0d", fno_n, hdl, rg_lag, rg_cl, rg_first, rg_gl, vcnt);
			end
		end
		if (dut.myupsample.r_wea && (dut.myupsample.r_addra[14:11] == rg_cs || dut.myupsample.r_addra[14:11] == rg_ns)) begin
			if (rg_cnt) begin
				rg_rw = rg_rw + 1;
				if (rg_rw <= 5) $display("ring rd-wr: frame %0d line %0d slots %0d/%0d written", fno_n, hdl, rg_cs, rg_ns);
			end else rg_rwt = rg_rwt + 1;
		end
		if (rg_cnt) begin
			rg_f = (rg_gl - 1) + ($realtime - rg_tt) / rg_tl - rg_cl;
			if (rg_f > rg_fmax) rg_fmax = rg_f;
		end
		if (rg_cnt && (rg_line[rg_cs] != rg_cl || rg_line[rg_ns] != rg_nl)) begin
			rg_ow = rg_ow + 1;
			if (rg_ow <= 5) $display("ring overwritten: frame %0d line %0d", fno_n, hdl);
		end
	end
	if (n_frame) begin
		$display("ring %0d: %0d lines, lag %0d..%0d, rd-wr %0d, overwritten %0d, wrongline %0d, ratio %0d (top %0d), time lag %0.3f..%0.3f",
		         fno_n, rg_lines, rg_lmin, rg_lmax, rg_rw, rg_ow, rg_wl, rg_ratio, rg_rwt, rg_fmin, rg_fmax);
		rg_lines = 0; rg_lmin = 99; rg_lmax = -99; rg_rw = 0; rg_rwt = 0; rg_ow = 0; rg_wl = 0; rg_fmin = 99; rg_fmax = -99;
	end
end
// +ring16: the line-rate mode on all 16 buffers (the ring's pointer
// arithmetic; pal_to_ddr uses 16 only in the exact-ratio modes)
initial begin
	#1;
	if ($test$plusargs("ring16")) force dut.r_ring16 = 1'b1;
end

initial begin
	wait (done_n >= frames && done_r >= frames);
	#100;
	$display("beam bypass: %0d mismatches in %0d clocks off, %0d clocks on", bh_bad, bh_clk - bh_on, bh_on);
	$display("done: %0d frames", frames);
	$finish;
end
// the OSD text layer: +osd2, +osd2gen, the pin raster position (crt_run.sh osd2*)
`include "tb_crt_osd2.vh"
endmodule

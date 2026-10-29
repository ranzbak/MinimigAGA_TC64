// tb_crt_osd2.vh -- the OSD text layer (osd_text.v in pal_to_ddr.sv) in
// tb_crt_frame.v (included at its end; crt_run.sh legs osd2off, osd2win,
// osd2win60; findings/osd-redesign Phase 2).
//
//   +osd2=DIR      at start, write the layer through pal_to_ddr's i_osd_txt
//                  bus (CLK_28, as userio_osd drives it): DIR/cells.hex (2048
//                  cell words, both lanes), DIR/font_w.hex ({adr, byte}, 2048
//                  font writes), DIR/pal.hex (64 staging palette bytes),
//                  DIR/cfg.hex (txt_cfg), then toggle the commit.  Without it
//                  the bus stays 0: the layer is never committed, i.e. off.
//   +osd2gen=PFX   dump the generator's picture (osd_text's input, w_gen_*)
//                  of the compared HD frames as PFX_<n>.hex, with the same
//                  sampling as +out (which dumps adv_ddr's input w_o_*): the
//                  clock of adv_ddr's first bus word {r, g[7:4]}; and as
//                  PFX_<n>b.hex at the next clock, the second word's
//                  {g[3:0], b} (osd2_check.py pins composites the layer over
//                  each, as adv_ddr takes them)
// Always printed, per pin frame (o_vsync to o_vsync) from 2 on: "osd2 pins
// N: L lines x P pixels, first pixel at generator (x, y), last at (x, y)" --
// the pin DE raster and the generator coordinates (the layer's, as the
// model's) of its first and last pixel, i.e. where the pin raster sits on
// the generator's (the data reaches the pins three clk_148 after w_o_*:
// adv_ddr's data_d1, data_d2, pad register).
reg         osd_clk = 1'b0;
always #17.62 osd_clk = ~osd_clk;          // CLK_28
reg  [106:0] osd_txt = 107'd0;
reg  [15:0] o2_cells [0:2047];
reg  [19:0] o2_font [0:2047];
reg  [7:0]  o2_pal [0:63];
reg  [39:0] o2_cfg [0:0];
reg  [8*300-1:0] o2_dir, o2_fn;
integer     o2_k;
initial if ($value$plusargs("osd2=%s", o2_dir)) begin
	$sformat(o2_fn, "%0s/cells.hex", o2_dir);  $readmemh(o2_fn, o2_cells);
	$sformat(o2_fn, "%0s/font_w.hex", o2_dir); $readmemh(o2_fn, o2_font);
	$sformat(o2_fn, "%0s/pal.hex", o2_dir);    $readmemh(o2_fn, o2_pal);
	$sformat(o2_fn, "%0s/cfg.hex", o2_dir);    $readmemh(o2_fn, o2_cfg);
	// {commit, cfg[39:0], pal_we, pal_adr, pal_dat, font_we, font_adr, font_dat,
	//  txt_we, txt_lane, txt_adr, txt_dat}
	for (o2_k = 0; o2_k < 2048; o2_k = o2_k + 1) begin
		@(negedge osd_clk);
		osd_txt[29:0] = {1'b1, 2'b11, o2_k[10:0], o2_cells[o2_k]};
	end
	@(negedge osd_clk) osd_txt[29] = 1'b0;
	for (o2_k = 0; o2_k < 2048; o2_k = o2_k + 1) begin
		@(negedge osd_clk);
		osd_txt[50:30] = {1'b1, o2_font[o2_k]};
	end
	@(negedge osd_clk) osd_txt[50] = 1'b0;
	for (o2_k = 0; o2_k < 64; o2_k = o2_k + 1) begin
		@(negedge osd_clk);
		osd_txt[65:51] = {1'b1, o2_k[5:0], o2_pal[o2_k]};
	end
	@(negedge osd_clk) osd_txt[65] = 1'b0;
	@(negedge osd_clk) osd_txt[105:66] = o2_cfg[0];
	@(negedge osd_clk) osd_txt[106] = ~osd_txt[106];
	$display("osd2 loaded from %0s at %0t: cfg %010h", o2_dir, $time, o2_cfg[0]);
end

// +osd2gen: the generator's picture, sampled as tb_crt_frame samples w_o_*
// (o2_fb), and at the clock after each of those samples (o2_fb2)
reg  [23:0] o2_fb [0:1280*720-1];
reg  [23:0] o2_fb2 [0:1280*720-1];
reg  [8*200-1:0] o2_gpfx;
reg         o2_gen = 1'b0, o2_ck = 1'b0, o2_tk_q = 1'b0;   // o2_tk_q: o2_fb sampled at the last clock
integer     o2_px = 0, o2_px2 = 0, o2_fno = 0, o2_fo;
initial o2_gen = $value$plusargs("osd2gen=%s", o2_gpfx);
always @(posedge clk_148) begin
	o2_ck <= dut.w_adv_clk;
	o2_tk_q <= !dut.hd_gen.r_frame && o2_ck && !dut.w_adv_clk && dut.w_adv_de;
	if (dut.hd_gen.r_frame) begin
		if (o2_gen && o2_fno >= first && o2_fno < first + frames) begin
			$sformat(o2_fn, "%0s_%0d.hex", o2_gpfx, o2_fno);
			o2_fo = $fopen(o2_fn, "w");
			for (o2_k = 0; o2_k < 1280*720; o2_k = o2_k + 1) $fwrite(o2_fo, "%06x\n", o2_fb[o2_k]);
			$fclose(o2_fo);
			$sformat(o2_fn, "%0s_%0db.hex", o2_gpfx, o2_fno);
			o2_fo = $fopen(o2_fn, "w");
			for (o2_k = 0; o2_k < 1280*720; o2_k = o2_k + 1) $fwrite(o2_fo, "%06x\n", o2_fb2[o2_k]);
			$fclose(o2_fo);
		end
		o2_fno = o2_fno + 1; o2_px = 0; o2_px2 = 0;
	end else begin
		if (o2_tk_q) begin
			if (o2_px2 < 1280*720) o2_fb2[o2_px2] = {dut.w_gen_r, dut.w_gen_g, dut.w_gen_b};
			o2_px2 = o2_px2 + 1;
		end
		if (o2_ck && !dut.w_adv_clk && dut.w_adv_de) begin
			if (o2_px < 1280*720) o2_fb[o2_px] = {dut.w_gen_r, dut.w_gen_g, dut.w_gen_b};
			o2_px = o2_px + 1;
		end
	end
end

// the pin raster on the generator's: the layer's own position, raw counters
// (x >= 1280 / y >= 720 is outside the generator's picture), three clocks
// late, taken at the pins' second words (o_clk_pixel high): osd_text's ny,
// and nx + 1 -- with PE_PHASE 1 the counters run on ~i_pe, a clock after
// the video, and three clocks before a second word nx is that pixel's x - 1
// (calibrated against osd2_check.py pins, which proves pin x = model x)
reg  [11:0] o2_x1 = 0, o2_x2 = 0, o2_x3 = 0, o2_y1 = 0, o2_y2 = 0, o2_y3 = 0;
reg         o2_vs = 1'b0, o2_any = 1'b0, o2_deq = 1'b0;
integer     o2_pf = 0, o2_lines = 0, o2_clks = 0, o2_w = 0;
reg  [11:0] o2_fx = 0, o2_fy = 0, o2_lx = 0, o2_ly = 0;
always @(posedge clk_148) begin
	{o2_x3, o2_x2, o2_x1} <= {o2_x2, o2_x1, dut.my_osd_text.nx + 12'd1};
	{o2_y3, o2_y2, o2_y1} <= {o2_y2, o2_y1, dut.my_osd_text.ny};
	o2_vs <= n_vs;
	o2_deq <= n_de;
	if (n_vs && !o2_vs) begin
		if (o2_any && o2_pf >= 2)
			$display("osd2 pins %0d: %0d lines x %0d pixels, first pixel at generator (%0d, %0d), last at (%0d, %0d)",
			         o2_pf, o2_lines, o2_w, o2_fx, o2_fy, o2_lx, o2_ly);
		o2_pf = o2_pf + 1; o2_any = 1'b0; o2_lines = 0;
	end
	if (n_de && !o2_deq) begin o2_lines = o2_lines + 1; o2_clks = 0; end
	if (!n_de && o2_deq) o2_w = o2_clks / 2;
	if (n_de) begin
		o2_clks = o2_clks + 1;
		if (n_clk) begin
			if (!o2_any) begin o2_fx = o2_x3; o2_fy = o2_y3; o2_any = 1'b1; end
			o2_lx = o2_x3; o2_ly = o2_y3;
		end
	end
end

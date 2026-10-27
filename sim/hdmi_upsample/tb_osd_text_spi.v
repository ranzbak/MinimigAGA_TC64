// tb_osd_text_spi.v -- userio_osd's OSD text layer commands over SPI
// (findings/osd-redesign/plan.md 4.1; userio_osd.v "OSD text layer"), as the
// firmware sends them (fw/ctrl/osd2.c).  The bench keeps its own copy of
// what osd_text.v would hold -- cell RAM (lane writes), font RAM, staging
// palette, txt_cfg at each commit toggle -- from the osd_txt bus, and checks
// every byte against the spec:
//   1. VERSION (0x88) reply bytes 10..13: B5 01 40 20 with OSD_TEXT = 1;
//      MINION_VER on an instance with OSD_TEXT = 0 (an old core's answer)
//   2. 0x2C mode 0: char,attr pairs, both lanes per cell, the cell + 1 and
//      wrapping 0x7FF -> 0x000; an odd last byte writes nothing and the
//      next transfer starts with a char again; mode 1 writes lane 0 only,
//      mode 2 lane 1 only; mode 3 writes nothing
//   3. 0x3C: font bytes from adr, wrapping 0xFFF -> 0x000
//   4. 0x4C: staging palette bytes from entry*4 (entry = d0[3:0]), wrapping
//   5. 0x5C: five bytes = txt_cfg[39:0], the fifth toggles txt_commit once;
//      a sixth byte is ignored; four bytes change the staging but no commit
//   6. an unknown command (0x6C) writes nothing
//   7. 0x0C (the legacy bitmap OSD) still writes osdbuf, and no text-layer
//      command touches osdbuf
// Every write enable is one clk wide (the counts are clk samples).
// Mutants (iverilog -D): OSD_TXT_MUTANT_COMMIT (commit never toggles),
// OSD_TXT_MUTANT_LANE (char / attr lanes swapped): each must FAIL.
// Prints "osd text spi: N errors".
`timescale 1ns/1ps
module tb_osd_text_spi;
reg clk = 0;
always #17.8 clk = ~clk;          // 28.375 MHz
reg [1:0] ph = 0;
always @(posedge clk) ph <= ph + 2'd1;
wire clk7_en = (ph == 2'd0), clk7n_en = (ph == 2'd2);
reg _scs = 1'b1, sdi = 1'b0, sck = 1'b1;
wire sdo, sdo0;
wire [106:0] txt, txt0;

userio_osd #(.OSD_TEXT(1)) dut (
	.clk(clk), .clk7_en(clk7_en), .clk7n_en(clk7n_en), .reset(1'b0),
	.c1(1'b0), .c3(1'b0), .sol(1'b0), .sof(1'b0), .varbeamen(1'b0), .rtg_ena(1'b0),
	.osd_ctrl(8'h00), .in_diag(32'h0), .in_diag_clr(),
	._scs(_scs), .sdi(sdi), .sdo(sdo), .sck(sck), .osd_rx_seq(), .osd_txt(txt),
	.osd_blank(), .osd_pixel(), .osd_enable(), .key_disable(),
	.memory_config(), .chipset_config(), .floppy_config(),
	.scanline(), .dither(), .crt_fx(),
	.ide_config0(), .ide_config1(), .cpu_config(), .autofire_config(), .cd32pad(),
	.usrrst(), .cpurst(), .cpuhlt(), .fifo_full(),
	.host_cs(), .host_adr(), .host_we(), .host_bs(), .host_wdat(),
	.host_rdat(16'h0000), .host_ack(1'b0));
// the same SPI on a core without the layer (OSD_TEXT 0): only its VERSION reply is read
userio_osd #(.OSD_TEXT(0)) dut0 (
	.clk(clk), .clk7_en(clk7_en), .clk7n_en(clk7n_en), .reset(1'b0),
	.c1(1'b0), .c3(1'b0), .sol(1'b0), .sof(1'b0), .varbeamen(1'b0), .rtg_ena(1'b0),
	.osd_ctrl(8'h00), .in_diag(32'h0), .in_diag_clr(),
	._scs(_scs), .sdi(sdi), .sdo(sdo0), .sck(sck), .osd_rx_seq(), .osd_txt(txt0),
	.osd_blank(), .osd_pixel(), .osd_enable(), .key_disable(),
	.memory_config(), .chipset_config(), .floppy_config(),
	.scanline(), .dither(), .crt_fx(),
	.ide_config0(), .ide_config1(), .cpu_config(), .autofire_config(), .cd32pad(),
	.usrrst(), .cpurst(), .cpuhlt(), .fifo_full(),
	.host_cs(), .host_adr(), .host_we(), .host_bs(), .host_wdat(),
	.host_rdat(16'h0000), .host_ack(1'b0));

// ---- the layer's side of osd_txt, as osd_text.v takes it --------------------------
wire        t_commit = txt[106];
wire [39:0] t_cfg    = txt[105:66];
wire        t_pwe    = txt[65];
wire [5:0]  t_padr   = txt[64:59];
wire [7:0]  t_pdat   = txt[58:51];
wire        t_fwe    = txt[50];
wire [11:0] t_fadr   = txt[49:38];
wire [7:0]  t_fdat   = txt[37:30];
wire        t_twe    = txt[29];
wire [1:0]  t_lane   = txt[28:27];
wire [10:0] t_tadr   = txt[26:16];
wire [15:0] t_tdat   = txt[15:0];
reg  [15:0] cells [0:2047];
reg  [7:0]  font  [0:4095];
reg  [7:0]  pal   [0:63];
integer     n_twe = 0, n_fwe = 0, n_pwe = 0, n_commit = 0, i;
reg         commit_q = 1'b0;
reg  [39:0] cfg_at_commit = 40'd0;
initial begin
	for (i = 0; i < 2048; i = i + 1) cells[i] = 16'hEEEE;
	for (i = 0; i < 4096; i = i + 1) font[i] = 8'hEE;
	for (i = 0; i < 64; i = i + 1) pal[i] = 8'hEE;
end
always @(posedge clk) begin
	if (t_twe) begin
		n_twe = n_twe + 1;
		if (t_lane[0]) cells[t_tadr][7:0]  = t_tdat[7:0];
		if (t_lane[1]) cells[t_tadr][15:8] = t_tdat[15:8];
	end
	if (t_fwe) begin n_fwe = n_fwe + 1; font[t_fadr] = t_fdat; end
	if (t_pwe) begin n_pwe = n_pwe + 1; pal[t_padr] = t_pdat; end
	commit_q <= t_commit;
	if (t_commit != commit_q) begin n_commit = n_commit + 1; cfg_at_commit = t_cfg; end
end
// the legacy bitmap: count its writes
integer n_osdbuf = 0;
always @(posedge clk) if (clk7_en && dut.wren) n_osdbuf = n_osdbuf + 1;

// ---- SPI as cfide clocks it --------------------------------------------------------------
reg [7:0] rxb, rxb0;
task spi_byte(input [7:0] tx);
	integer k;
	begin
		for (k = 7; k >= 0; k = k - 1) begin
			sck = 1'b0; sdi = tx[k]; #500;
			rxb[k] = sdo; rxb0[k] = sdo0;
			sck = 1'b1; #500;
		end
	end
endtask
task open(input [7:0] c); begin _scs = 1'b0; #200; spi_byte(c); end endtask
task close; begin #200; _scs = 1'b1; #2000; end endtask

integer err = 0;
task check(input [8*48:1] what, input [39:0] got, input [39:0] want);
	begin
		if (got !== want) begin $display("FAIL %0s: %0h, want %0h", what, got, want); err = err + 1; end
		else $display("  ok %0s: %0h", what, got);
	end
endtask

reg [7:0] ver [0:13];
reg [7:0] ver0 [0:13];
integer b0, b1, b2, b3, bo;
initial begin
	#5000;
	// 1. VERSION
	open(8'h88);
	for (i = 0; i < 14; i = i + 1) begin spi_byte(8'hFF); ver[i] = rxb; ver0[i] = rxb0; end
	close;
	check("VERSION byte 4 (magic)", ver[4], 8'hA4);
	check("VERSION bytes 10..13", {ver[10], ver[11], ver[12], ver[13]}, 32'hB5014020);
	check("OSD_TEXT 0: bytes 10..13 = MINION_VER", {ver0[10], ver0[11], ver0[12], ver0[13]},
	      {4{ver0[3]}});   // byte 3 is MINION_VER on every core
	check("OSD_TEXT 0: bytes 0..5 as with the layer", {ver0[0], ver0[1], ver0[2], ver0[4], ver0[5]},
	      {ver[0], ver[1], ver[2], ver[4], ver[5]});

	// 2. 0x2C
	b0 = n_twe; bo = n_osdbuf;
	open(8'h2C); spi_byte(8'h00); spi_byte(8'h07); spi_byte(8'hFE);        // pairs at 0x7FE
	spi_byte(8'h41); spi_byte(8'h1F); spi_byte(8'h42); spi_byte(8'h2E); spi_byte(8'h43); spi_byte(8'h3D);
	close;
	check("pairs: 3 cells written", n_twe - b0, 3);
	check("pairs: cell 7FE", cells[11'h7FE], 16'h1F41);
	check("pairs: cell 7FF", cells[11'h7FF], 16'h2E42);
	check("pairs: wrap to cell 000", cells[0], 16'h3D43);
	b0 = n_twe;
	open(8'h2C); spi_byte(8'h00); spi_byte(8'h01); spi_byte(8'h23);        // pairs at 0x123
	spi_byte(8'h11); spi_byte(8'h22); spi_byte(8'h33); spi_byte(8'h44); spi_byte(8'h99);   // odd last byte
	close;
	check("pairs: odd last byte writes nothing", n_twe - b0, 2);
	check("pairs: cell 123", cells[11'h123], 16'h2211);
	check("pairs: cell 124", cells[11'h124], 16'h4433);
	check("pairs: cell 125 untouched", cells[11'h125], 16'hEEEE);
	open(8'h2C); spi_byte(8'h00); spi_byte(8'h01); spi_byte(8'h25); spi_byte(8'h55); spi_byte(8'h66); close;
	check("pairs: next transfer starts with a char", cells[11'h125], 16'h6655);
	b0 = n_twe;
	open(8'h2C); spi_byte(8'h01); spi_byte(8'h01); spi_byte(8'h23); spi_byte("A"); spi_byte("B"); close;
	check("chars: 2 cells", n_twe - b0, 2);
	check("chars: cell 123 lane 0 only", cells[11'h123], 16'h2241);
	check("chars: cell 124 lane 0 only", cells[11'h124], 16'h4442);
	open(8'h2C); spi_byte(8'h02); spi_byte(8'h01); spi_byte(8'h24); spi_byte(8'h77); spi_byte(8'h88); close;
	check("attrs: cell 124 lane 1 only", cells[11'h124], 16'h7742);
	check("attrs: cell 125 lane 1 only", cells[11'h125], 16'h8855);
	b0 = n_twe;
	open(8'h2C); spi_byte(8'h03); spi_byte(8'h01); spi_byte(8'h23); spi_byte(8'h01); spi_byte(8'h02); close;
	check("mode 3: writes nothing", n_twe - b0, 0);
	check("mode 3: cell 123 unchanged", cells[11'h123], 16'h2241);
	open(8'h2C); spi_byte(8'h00); spi_byte(8'hF8); spi_byte(8'h00); spi_byte(8'h5A); spi_byte(8'hA5); close;
	check("pairs: d1 bits 7:3 ignored (cell 000)", cells[0], 16'hA55A);

	// 3. 0x3C
	b1 = n_fwe;
	open(8'h3C); spi_byte(8'hFF); spi_byte(8'hFE); spi_byte(8'h01); spi_byte(8'h02); spi_byte(8'h03); close;
	check("font: 3 bytes", n_fwe - b1, 3);
	check("font: FFE FFF 000", {font[12'hFFE], font[12'hFFF], font[0]}, 24'h010203);
	open(8'h3C); spi_byte(8'h08); spi_byte(8'h10); for (i = 0; i < 16; i = i + 1) spi_byte(i * 16 + i); close;
	check("font: glyph 0x81 row 0", font[12'h810], 8'h00);
	check("font: glyph 0x81 row 15", font[12'h81F], 8'hFF);
	check("font: glyph 0x81 row 7", font[12'h817], 8'h77);
	check("font: 0x820 untouched", font[12'h820], 8'hEE);

	// 4. 0x4C
	b2 = n_pwe;
	open(8'h4C); spi_byte(8'h0F); spi_byte(8'hC0); spi_byte(8'h11); spi_byte(8'h22); spi_byte(8'h33);
	spi_byte(8'h40); spi_byte(8'h44); close;
	check("palette: 6 bytes", n_pwe - b2, 6);
	check("palette: entry 15", {pal[60], pal[61], pal[62], pal[63]}, 32'hC0112233);
	check("palette: wrap to entry 0", {pal[0], pal[1]}, 16'h4044);
	open(8'h4C); spi_byte(8'hF5); spi_byte(8'h80); spi_byte(8'h01); spi_byte(8'h02); spi_byte(8'h03); close;
	check("palette: entry d0[3:0] = 5", {pal[20], pal[21], pal[22], pal[23]}, 32'h80010203);

	// 5. 0x5C
	b3 = n_commit;
	open(8'h5C); spi_byte(8'h03); spi_byte(8'h10); spi_byte(8'h05); spi_byte(8'h40); spi_byte(8'h14); close;
	check("cfg: one commit", n_commit - b3, 1);
	check("cfg: txt_cfg at the commit", cfg_at_commit, 40'h1440051003);
	check("cfg: txt_cfg", t_cfg, 40'h1440051003);
	b3 = n_commit;
	open(8'h5C); spi_byte(8'h01); spi_byte(8'h00); spi_byte(8'h00); spi_byte(8'h01); spi_byte(8'h01);
	spi_byte(8'hFF); close;
	check("cfg: 6 bytes, one commit", n_commit - b3, 1);
	check("cfg: the 6th byte ignored", t_cfg, 40'h0101000001);
	b3 = n_commit;
	open(8'h5C); spi_byte(8'h02); spi_byte(8'h0A); spi_byte(8'h0B); spi_byte(8'h0C); close;
	check("cfg: 4 bytes, no commit", n_commit - b3, 0);
	check("cfg: 4 bytes into the staging", t_cfg, 40'h010C0B0A02);

	// 6. unknown command 0x6C
	b0 = n_twe; b1 = n_fwe; b2 = n_pwe; b3 = n_commit;
	open(8'h6C); for (i = 0; i < 8; i = i + 1) spi_byte(8'h01 + i); close;
	check("0x6C: no writes", (n_twe - b0) + (n_fwe - b1) + (n_pwe - b2) + (n_commit - b3), 0);
	check("0x6C: txt_cfg unchanged", t_cfg, 40'h010C0B0A02);
	check("text commands: no osdbuf writes", n_osdbuf - bo, 0);

	// 7. 0x0C, the legacy bitmap
	b0 = n_twe; b1 = n_fwe; b2 = n_pwe; b3 = n_commit; bo = n_osdbuf;
	open(8'h0C); spi_byte(8'h00); spi_byte(8'h00); spi_byte(8'h00); spi_byte(8'h03);
	spi_byte(8'hA1); spi_byte(8'hB2); spi_byte(8'hC3); close;
	check("0x0C: 3 osdbuf writes", n_osdbuf - bo, 3);
	check("0x0C: line 3 bytes 0..2", {dut.osdbuf[11'h300], dut.osdbuf[11'h301], dut.osdbuf[11'h302]}, 24'hA1B2C3);
	check("0x0C: no text layer writes", (n_twe - b0) + (n_fwe - b1) + (n_pwe - b2) + (n_commit - b3), 0);

	$display("osd text spi: %0d errors", err);
	$finish;
end
endmodule

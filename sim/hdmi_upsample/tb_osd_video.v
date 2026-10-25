// tb_osd_video.v -- userio_osd's video config command (OSD_CMD_VID, 0x34)
// over SPI as the OSD firmware sends it: the first data byte
// {dither, hr_filter, lr_filter, scanline}, the optional second byte
// {scaling, beam, bloom, mask} for the HDMI CRT emulation and scaler
// (crt_fx, 8 bits; scaling since 2026-10-13: 0 line rate, 1 sharp, 2 area).
//   1. one data byte (an older firmware): filters and scanlines set, crt_fx
//      stays 0 (mask and bloom off, scaling line rate)
//   2. two data bytes: crt_fx = the second byte, all 8 bits (the scaling
//      in bits 7:6), the first byte as before
//   3. a third byte in the same transfer does not change crt_fx
//   4. another config command with two data bytes leaves the video config
// Prints "osd video: N errors".
`timescale 1ns/1ps
module tb_osd_video;
reg clk = 0;
always #17.8 clk = ~clk;          // 28.375 MHz
reg [1:0] ph = 0;
always @(posedge clk) ph <= ph + 2'd1;
wire clk7_en = (ph == 2'd0), clk7n_en = (ph == 2'd2);
reg _scs = 1'b1, sdi = 1'b0, sck = 1'b1;
wire sdo;
wire [1:0] lr, hr, scan, dith;
wire [7:0] fx;
userio_osd dut (
	.clk(clk), .clk7_en(clk7_en), .clk7n_en(clk7n_en), .reset(1'b0),
	.c1(1'b0), .c3(1'b0), .sol(1'b0), .sof(1'b0), .varbeamen(1'b0), .rtg_ena(1'b0),
	.osd_ctrl(8'h00), .in_diag(32'h0), .in_diag_clr(),
	._scs(_scs), .sdi(sdi), .sdo(sdo), .sck(sck),
	.osd_blank(), .osd_pixel(), .osd_enable(), .key_disable(),
	.lr_filter(lr), .hr_filter(hr), .memory_config(), .chipset_config(), .floppy_config(),
	.scanline(scan), .dither(dith), .crt_fx(fx),
	.ide_config0(), .ide_config1(), .cpu_config(), .autofire_config(), .cd32pad(),
	.usrrst(), .cpurst(), .cpuhlt(), .fifo_full(),
	.host_cs(), .host_adr(), .host_we(), .host_bs(), .host_wdat(),
	.host_rdat(16'h0000), .host_ack(1'b0));

task spi_byte(input [7:0] tx);
	integer i;
	begin
		for (i = 7; i >= 0; i = i - 1) begin
			sck = 1'b0; sdi = tx[i]; #500;
			sck = 1'b1; #500;
		end
	end
endtask
task xfer(input integer n, input [7:0] c, input [7:0] d0, input [7:0] d1, input [7:0] d2);
	begin
		_scs = 1'b0; #200;
		spi_byte(c);
		if (n > 0) spi_byte(d0);
		if (n > 1) spi_byte(d1);
		if (n > 2) spi_byte(d2);
		#200; _scs = 1'b1; #2000;
	end
endtask
integer err = 0;
task check(input [8*40:1] what, input [9:0] got, input [9:0] want);
	begin
		if (got !== want) begin $display("FAIL %0s: %03h, want %03h", what, got, want); err = err + 1; end
		else $display("  ok %0s: %03h", what, got);
	end
endtask
initial begin
	#5000;
	xfer(1, 8'h34, 8'h1D, 8'h00, 8'h00);                 // H filter hires, H+V lores, dim
	check("1 byte: {hr, lr, scan}", {hr, lr, scan}, 10'h1D);
	check("1 byte: crt_fx", fx, 10'h0);
	xfer(2, 8'h34, 8'h01, 8'h0B, 8'h00);                 // dim; 0x0B: bloom 2 (high), mask 3 (shadow)
	check("2 bytes: {hr, lr, scan}", {hr, lr, scan}, 10'h01);
	check("2 bytes: crt_fx", fx, 10'hB);
	xfer(2, 8'h34, 8'h00, 8'hA6, 8'h00);                 // 0xA6: scaling 2 (area), beam 2 (medium), bloom 1, mask 2
	check("2 bytes: crt_fx scaling area + beam", fx, 10'hA6);
	xfer(2, 8'h34, 8'h00, 8'h40, 8'h00);                 // scaling 1 (sharp) alone
	check("2 bytes: crt_fx scaling sharp", fx, 10'h40);
	xfer(2, 8'h34, 8'h01, 8'h1B, 8'h00);                 // beam 1 (sharp), bloom 2, mask 3
	check("2 bytes: crt_fx beam sharp", fx, 10'h1B);
	xfer(2, 8'h34, 8'h01, 8'h0B, 8'h00);
	xfer(3, 8'h34, 8'h00, 8'h06, 8'h0F);                 // the third byte is not the second
	check("3 bytes: crt_fx", fx, 10'h6);
	check("3 bytes: {hr, lr, scan}", {hr, lr, scan}, 10'h0);
	xfer(2, 8'h44, 8'h01, 8'h0F, 8'h00);                 // another command (0x44, floppy config)
	check("other command: crt_fx", fx, 10'h6);
	check("other command: {hr, lr, scan}", {hr, lr, scan}, 10'h0);
	$display("osd video: %0d errors", err);
	$finish;
end
endmodule

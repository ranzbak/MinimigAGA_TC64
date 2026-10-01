// serprobe_ddr3.sv -- sim/ddr3_cpu: every chipset-bus cycle in $DFF000-$DFF1FF
// (TG68K.vhd's 7 MHz bus, which the minimig's Gary/Agnus/Paula sample), one
// line per change of as/rw/uds/lds/addr/data, plus the core's own requests
// (the wrapper's b_*) to the same range.
`define SP_T ddr3_cpu_tb
`define SP_W ddr3_cpu_tb.tg68k.g_ap040.g_pipe.ap040
module serprobe_ddr3;
	reg [55:0] last = 56'h0;
	wire hit = `SP_T.tg68_adr[23:9] == 15'h6FF8;
	wire [55:0] now = {`SP_T.tg68_as, `SP_T.tg68_rw, `SP_T.tg68_uds, `SP_T.tg68_lds,
	                   4'h0, `SP_T.tg68_adr[23:0], `SP_T.tg68_dat_out};
	always @(posedge `SP_T.clk) begin
		if (hit && now != last)
			$display("SER bus t=%0t as=%b rw=%b uds=%b lds=%b a=%h dw=%h", $time,
			         `SP_T.tg68_as, `SP_T.tg68_rw, `SP_T.tg68_uds, `SP_T.tg68_lds,
			         `SP_T.tg68_adr[23:0], `SP_T.tg68_dat_out);
		last <= now;
	end
	always @(posedge `SP_W.clk)
		if (`SP_W.b_req && `SP_W.b_ack && `SP_W.b_addr[31:9] == 23'h6FF8)
			$display("SER core t=%0t %s a=%h d=%h sz=%0d", $time, `SP_W.b_write ? "W" : "R",
			         `SP_W.b_addr, `SP_W.b_write ? `SP_W.b_wdata : `SP_W.b_rdata, `SP_W.b_size);
endmodule

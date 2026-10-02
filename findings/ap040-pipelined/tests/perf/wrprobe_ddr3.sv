// wrprobe_ddr3.sv -- sim/ddr3_cpu: every access to $41040000-$410401FF at
// the core's master port (the wrapper's b_*) and at ddr3_fastram's CPU port,
// so a write that loses its data or its address shows where.
`define WP_W ddr3_cpu_tb.tg68k.g_ap040.g_pipe.ap040
`define WP_F ddr3_cpu_tb.u_fast
module wrprobe_ddr3;
	always @(posedge `WP_W.clk)
		if (`WP_W.b_req && `WP_W.b_ack && `WP_W.b_addr[31:9] == 23'h208200)
			$display("WRP core  t=%0t %s a=%h d=%h sz=%0d", $time, `WP_W.b_write ? "W" : "R",
			         `WP_W.b_addr, `WP_W.b_write ? `WP_W.b_wdata : `WP_W.b_rdata, `WP_W.b_size);
	reg fq = 1'b0;
	always @(posedge `WP_F.sysclk) begin
		fq <= `WP_F.cpu_req && `WP_F.cpu_ack;
		if (`WP_F.cpu_req && `WP_F.cpu_ack && !fq && `WP_F.cpu_wadr[25:9] == 17'h00200)
			$display("WRP fast  t=%0t %s wadr=%h a=%h bs=%b d=%h", $time, `WP_F.cpu_we ? "W" : "R",
			         `WP_F.cpu_wadr, {`WP_F.cpu_wadr, 1'b0}, `WP_F.cpu_bs, `WP_F.cpu_we ? `WP_F.cpu_wdat : `WP_F.cpu_rdat);
	end
endmodule

// rdprobe_ddr3.sv -- sim/ddr3_cpu: the core's data reads of $41030000-$410300FF
// (cbm16_ddr3.asm's MOVE16 source): request, answer, and how it was answered
// (forwarded from a store in flight, the fast read path, or the port), and
// MOVE16's capture index.
`define RP_C ddr3_cpu_tb.tg68k.g_ap040.g_pipe.ap040.core
module rdprobe_ddr3;
	always @(posedge `RP_C.clk) if (`RP_C.ce) begin
		if (`RP_C.d_rd_req && `RP_C.d_rd_addr[31:8] == 24'h410300)
			$display("RDP t=%0t req a=%h fwd=%b fast=%b ack=%b d=%h sbcnt=%0d m16=%b cap=%b rk=%0d",
			  $time, `RP_C.d_rd_addr, `RP_C.g_bus.d_rd_fwd, `RP_C.g_bus.d_rd_fast, `RP_C.d_rd_ack,
			  `RP_C.d_rd_data, `RP_C.g_bus.u_bcu.sb_cnt, `RP_C.u_eaf.mm_16, `RP_C.u_eaf.cap, `RP_C.u_eaf.mm_rk);
		if (`RP_C.u_eaf.mm_16 && `RP_C.u_eaf.cap)
			$display("RDP t=%0t m16 cap rk=%0d d=%h", $time, `RP_C.u_eaf.mm_rk, `RP_C.u_eaf.rd_data);
	end
endmodule

// insprobe_ddr3.sv -- sim/ddr3_cpu: per-instruction clock accounting for the
// perf window (phase 2).  Every clock is put in the same bucket as
// perf_probe.vh's "one bucket" chain (or "frozen" when the core's enable is
// low), and charged to the NEXT instruction to retire; at each retirement
// (WB's last micro-op, u_wb.wb_valid) one line goes to insprobe.txt:
//   <clock> <pc> <total> FZ RET ST EXB XFER RD EAF FE Q EF ED EI
// In an in-order pipeline the clocks between two retirements are what the
// second instruction cost on top of the overlap.  Summed per PC by
// insprobe_report.py.  Use with run_ddr3_dhry.sh:
//   PROBE=$PWD/insprobe_ddr3.sv PROBE_TOP=insprobe_ddr3 ./run_ddr3_dhry.sh <tag>
`define IP_W  ddr3_cpu_tb.tg68k.g_ap040.g_pipe.ap040
`define IP_EN (ddr3_cpu_tb.phase_seen == 32'd2)
module insprobe_ddr3;
localparam [1:0] IP_K_RD = 2'd1, IP_K_IF = 2'd2;
integer f, on, cyc, k;
integer b [0:11];
initial begin on = 0; cyc = 0; f = $fopen("insprobe.txt", "w"); for (k = 0; k < 12; k = k + 1) b[k] = 0; end
always @(posedge `IP_W.clk) begin
	if ((`IP_EN) && !on) begin on = 1; cyc = 0; for (k = 0; k < 12; k = k + 1) b[k] = 0; end
	else if (!(`IP_EN) && on) begin on = 0; $fflush(f); end
	if (on) begin
		cyc = cyc + 1;
		if (!`IP_W.ce_core) b[0] = b[0] + 1;
		else if (`IP_W.core.retire) b[1] = b[1] + 1;
		else if (`IP_W.core.exe_valid) b[2] = b[2] + 1;
		else if (`IP_W.core.eaf_valid) begin
			if (`IP_W.core.ex_stall) b[3] = b[3] + 1; else b[4] = b[4] + 1;
		end
		else if (`IP_W.core.eac_valid) begin
			if (`IP_W.core.g_bus.u_bcu.dq_v || `IP_W.core.d_rd_req ||
			    (`IP_W.core.g_bus.u_bcu.mem_req && `IP_W.core.g_bus.u_bcu.kind == IP_K_RD))
				b[5] = b[5] + 1;
			else b[6] = b[6] + 1;
		end
		else if (`IP_W.core.id_valid) b[7] = b[7] + 1;
		else if (`IP_W.core.q_v0) b[8] = b[8] + 1;
		else if (`IP_W.core.g_bus.u_bcu.mem_req && `IP_W.core.g_bus.u_bcu.kind == IP_K_IF) b[9] = b[9] + 1;
		else if (`IP_W.core.f_req && !`IP_W.core.f_gnt) b[10] = b[10] + 1;
		else b[11] = b[11] + 1;
		if (`IP_W.ce_core && `IP_W.core.u_wb.wb_valid) begin
			$fdisplay(f, "%0d %h %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d", cyc, `IP_W.core.u_wb.wb_pc,
			          b[0]+b[1]+b[2]+b[3]+b[4]+b[5]+b[6]+b[7]+b[8]+b[9]+b[10]+b[11],
			          b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11]);
			for (k = 0; k < 12; k = k + 1) b[k] = 0;
		end
	end
end
endmodule

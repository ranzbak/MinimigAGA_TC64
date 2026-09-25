//--------------------------------------------------------------------------//
// tb_ap040_pipe_cycles.v - cycle-checker bench for the pipelined core      //
// (plan M0.5).  Zero-wait memory (the L1 array, until M5; then the bus     //
// model at wait profile 0).  Writes one line per RETIRED instruction:      //
//     R <clock> <pc>                                                       //
// to +log=<file>, clock counted from reset release.  run_cycles.py turns    //
// the retire times of the measured instruction copies into clocks per      //
// instruction.                                                             //
//                                                                          //
// Registers preset one clock after reset release (the core cannot load    //
// an address register yet): A0-A6 = $1800 + $100*n, ISP = $2000, D0-D7     //
// untouched (the micro-programs set what they need with MOVEQ).            //
//--------------------------------------------------------------------------//
`timescale 1ns/1ps
module tb_ap040_pipe_cycles;
parameter [31:0] PC_RESET = 32'h0000_0400;
parameter         L1_AW   = 12;
localparam        L1_WORDS = (1 << L1_AW);
reg clk = 0;
always #5 clk = ~clk;
reg nreset = 0;
wire        dbg_wb_valid;
wire [31:0] dbg_wb_pc;
ap040_pipe_core #(.PC_RESET(PC_RESET), .PROG_WORDS(32'h7FFF_FFFF), .L1_AW(L1_AW)) dut (
	.clk(clk), .nreset(nreset), .ce(1'b1),
	.dbg_if_valid(), .dbg_if_pc(), .dbg_id_valid(), .dbg_id_pc(),
	.dbg_eac_valid(), .dbg_eac_pc(), .dbg_eaf_valid(), .dbg_eaf_pc(),
	.dbg_ex_valid(), .dbg_ex_pc(), .dbg_wb_valid(dbg_wb_valid), .dbg_wb_pc(dbg_wb_pc),
	.dbg_d0(), .dbg_d1(), .dbg_d2(), .dbg_d3(), .dbg_d4(), .dbg_d5(), .dbg_d6(), .dbg_d7(),
	.dbg_ccr(), .dbg_sr());
reg [15:0] img [0:32767];
string progf, logf;
integer i, fd, max_cycles, cyc;
reg [31:0] halt_pc;
reg done = 0;
integer clk_n = 0;   // own counter: the initial block's loop variable races with this block
always @(posedge clk) if (nreset && !done) begin
	clk_n = clk_n + 1;
	if (dbg_wb_valid) begin
		$fwrite(fd, "R %0d %08x\n", clk_n, dbg_wb_pc);
		if (dbg_wb_pc == halt_pc) done = 1;
	end
end
initial begin
	if (!$value$plusargs("prog=%s", progf)) begin $display("usage: +prog= +log= +halt_pc= [+cycles=]"); $finish; end
	if (!$value$plusargs("log=%s", logf)) logf = "cycles.log";
	if (!$value$plusargs("cycles=%d", max_cycles)) max_cycles = 20000;
	if (!$value$plusargs("halt_pc=%h", halt_pc)) halt_pc = 32'hFFFF_FFFF;
	for (i = 0; i < 32768; i = i + 1) img[i] = 16'h4E71;
	$readmemh(progf, img);
	for (i = 0; i < L1_WORDS; i = i + 1)
		dut.u_l1.mem[(i - (PC_RESET >> 1)) & (L1_WORDS - 1)] = img[i];
	fd = $fopen(logf, "w");
	repeat (3) @(posedge clk);
	nreset = 1;
	@(posedge clk);
	for (i = 0; i < 7; i = i + 1) dut.u_regfile.areg[i] = 32'h1800 + 32'h100 * i;
	dut.u_regfile.isp = 32'h2000;
	for (cyc = 0; cyc < max_cycles && !done; cyc = cyc + 1) @(posedge clk);
	$fclose(fd);
	$display("tb_ap040_pipe_cycles: %0s after %0d clocks", done ? "halt" : "TIMEOUT", cyc);
	$finish;
end
endmodule

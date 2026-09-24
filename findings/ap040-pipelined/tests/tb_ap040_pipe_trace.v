//--------------------------------------------------------------------------//
// tb_ap040_pipe_trace.v - retire-trace dumper for the PIPELINED AP68040     //
// (nonarkitten/AP68040 branch `pipelined`, rtl/ap040_pipe_core.v).         //
//                                                                          //
// Loads a flat program image (+prog=<hex>, one 16-bit word per line from   //
// address 0, the format tb/bin2hex.py produces) into the core's unified    //
// L1 array using the core's own PC_RESET-relative word-index convention    //
// (index = (addr - PC_RESET) >> 1, wrapped to the array size, so the       //
// vector table at 0..$3FF lands in the top 512 words exactly as the        //
// milestone-14 exception path expects).                                    //
//                                                                          //
// Every retired instruction is written to +trace=<file> as one line:       //
//   <pc> <sr> <d0> <d1> <d2> <d3> <d4> <d5> <d6> <d7> <a0> ... <a7>          //
// sampled AFTER the instruction's commit (the register file write lands on //
// the posedge that ends the WB cycle; we sample at the following negedge). //
// The reference-side dumper (tb_ap040_ref_trace.v) writes the same column  //
// layout but sampled at DECODE of each instruction, so compare_trace.py    //
// aligns pipelined record k with reference record k+1 by default.          //
//                                                                          //
// Stops after +cycles=<n> clocks (default 20000) or when +halt_pc=<hex>    //
// retires. Exit status is always 0: this bench PRODUCES evidence, the      //
// comparison is compare_trace.py's job.                                    //
//                                                                          //
// Limitations (deliberate, documented in the assessment):                  //
//  - A0-A6 / USP / ISP / MSP are read hierarchically (dut.u_regfile.*)     //
//    because the core only exposes D0-D7/SR through dbg_* ports.           //
//  - A retire that is held in WB by a stall is printed once (consecutive   //
//    duplicate PCs are collapsed), so a one-instruction self-loop shows as  //
//    a single line.                                                        //
//                                                                          //
// M0.1 streams (same syntax as tb_ap040_ref_trace.v):                      //
//   W <addr> <size> <data>   every store as WB writes it into memory (L1   //
//                            port W; size 1/2/4)                           //
//   X <vec> <fmt> <sr> <pc> [<word>...]  exception entry, taken one clock   //
//                            after its final micro-op commits in WB,        //
//                            decoded from memory at the new SP              //
// The core runs with RESET_FROM_VECTORS=1; its reset micro-op retires with //
// pc ffffffff and gives the state-after-reset record.                      //
//--------------------------------------------------------------------------//
`timescale 1ns/1ps

module tb_ap040_pipe_trace;

parameter [31:0] PC_RESET = 32'h0000_0400;
parameter         L1_AW   = 15;              // 32K words = the 64K image (t_integer uses $3000-$3400, $F100)
localparam        L1_WORDS = (1 << L1_AW);

reg clk = 0;
always #5 clk = ~clk;
reg nreset = 0;

wire        dbg_if_valid,  dbg_id_valid,  dbg_eac_valid;
wire        dbg_eaf_valid, dbg_ex_valid,  dbg_wb_valid;
wire [31:0] dbg_if_pc,     dbg_id_pc,     dbg_eac_pc;
wire [31:0] dbg_eaf_pc,    dbg_ex_pc,     dbg_wb_pc;
wire [31:0] dbg_d0, dbg_d1, dbg_d2, dbg_d3, dbg_d4, dbg_d5, dbg_d6, dbg_d7;
wire  [4:0] dbg_ccr;
wire [15:0] dbg_sr;

ap040_pipe_core #(
	.PC_RESET  (PC_RESET),
	.PROG_WORDS(32'h7FFF_FFFF),   // no fetch budget: run until +cycles/+halt_pc
	.L1_AW     (L1_AW),
	.RESET_FROM_VECTORS(1)        // ISP/PC from vectors 0/1, as the reference
) dut (
	.clk(clk), .nreset(nreset), .ce(1'b1),
	.dbg_if_valid (dbg_if_valid),  .dbg_if_pc (dbg_if_pc),
	.dbg_id_valid (dbg_id_valid),  .dbg_id_pc (dbg_id_pc),
	.dbg_eac_valid(dbg_eac_valid), .dbg_eac_pc(dbg_eac_pc),
	.dbg_eaf_valid(dbg_eaf_valid), .dbg_eaf_pc(dbg_eaf_pc),
	.dbg_ex_valid (dbg_ex_valid),  .dbg_ex_pc (dbg_ex_pc),
	.dbg_wb_valid (dbg_wb_valid),  .dbg_wb_pc (dbg_wb_pc),
	.dbg_d0(dbg_d0), .dbg_d1(dbg_d1), .dbg_d2(dbg_d2), .dbg_d3(dbg_d3),
	.dbg_d4(dbg_d4), .dbg_d5(dbg_d5), .dbg_d6(dbg_d6), .dbg_d7(dbg_d7),
	.dbg_ccr(dbg_ccr), .dbg_sr(dbg_sr)
);

// A7 is banked: pick the live stack pointer the same way the regfile does.
wire [31:0] a7_live = !dbg_sr[13] ? dut.u_regfile.usp :
                       dbg_sr[12] ? dut.u_regfile.msp : dut.u_regfile.isp;

reg [15:0] img [0:32767];
string progf, tracef;      // SV string: a fixed reg truncates long paths silently
integer i, fd, max_cycles, cycles, n_ret;
reg [31:0] halt_pc;
reg        have_halt;

// one-cycle delayed retire marker: regs are valid at the negedge after the
// posedge on which the WB-stage instruction committed
reg        r_valid = 0;
reg [31:0] r_pc = 0;
reg [31:0] last_pc = 32'hFFFF_FFFE;   // not ffffffff: the reset micro-op retires with that pc
reg        done = 0;

// Sampling point, established empirically against the reference trace: the
// regfile write of the instruction shown by dbg_wb_pc lands on the posedge
// BEFORE the one where dbg_wb_valid presents it, and the following
// instruction's write lands on that presenting posedge itself. Reading the
// registers inside the posedge block (pre-NBA values) therefore gives
// "state after this instruction, before the next one".
// memory view (the L1 array; stores are written by WB directly since M1)
function [15:0] mw(input [31:0] a);
	reg [L1_AW-1:0] ix;
	begin
		ix = (a - PC_RESET) >> 1;
		mw = dut.u_l1.mem[ix];
	end
endfunction

integer k, nwords;
reg [31:0] sp;
reg [15:0] fv;
reg        x_pend = 0;
reg [31:0] x_sp;
always @(posedge clk) begin
	if (nreset && !done) begin
		// the store as WB writes it into memory.  A CAS/CAS2 mismatch's locked
		// write-back of the value read (M68040UM p. 7-26; the references do not
		// make it: PLAN D6) is an L line, which compare_trace.py counts apart.
		if (dut.u_l1.wr_req)
			case (dut.u_l1.wr_size)
				2'd0: $fwrite(fd, "%s %08x 1 %02x\n", dut.exe_o.st_rb ? "L" : "W", dut.u_l1.wr_addr, dut.u_l1.wr_data[7:0]);
				2'd1: $fwrite(fd, "%s %08x 2 %04x\n", dut.exe_o.st_rb ? "L" : "W", dut.u_l1.wr_addr, dut.u_l1.wr_data[15:0]);
				default: $fwrite(fd, "%s %08x 4 %08x\n", dut.exe_o.st_rb ? "L" : "W", dut.u_l1.wr_addr, dut.u_l1.wr_data);
			endcase
		// exception entry commits (its final micro-op in WB): every frame
		// store is older, so the frame is in memory one clock later
		if (x_pend) begin
			sp = x_sp;
			fv = mw(sp + 6);
			case (fv[15:12])
				4'd2, 4'd3: nwords = 2;
				4'd4:       nwords = 4;
				4'd7:       nwords = 26;
				default:    nwords = 0;
			endcase
			$fwrite(fd, "X %02x %1x %04x %08x", fv[9:2], fv[15:12], mw(sp), {mw(sp + 2), mw(sp + 4)});
			for (k = 0; k < nwords; k = k + 1) $fwrite(fd, " %04x", mw(sp + 8 + 2 * k));
			$fwrite(fd, "\n");
		end
		x_pend = dut.exe_valid && dut.exe_o.exc;
		x_sp   = dut.exe_o.exc_sp;
	end
end

always @(posedge clk) begin
	if (nreset && dbg_wb_valid && !done && dbg_wb_pc != last_pc) begin
		last_pc = dbg_wb_pc;
		n_ret = n_ret + 1;
		$fwrite(fd, "%08x %04x %08x %08x %08x %08x %08x %08x %08x %08x %08x %08x %08x %08x %08x %08x %08x %08x\n",
		        dbg_wb_pc, dbg_sr,
		        dbg_d0, dbg_d1, dbg_d2, dbg_d3, dbg_d4, dbg_d5, dbg_d6, dbg_d7,
		        dut.u_regfile.areg[0], dut.u_regfile.areg[1], dut.u_regfile.areg[2],
		        dut.u_regfile.areg[3], dut.u_regfile.areg[4], dut.u_regfile.areg[5],
		        dut.u_regfile.areg[6], a7_live);
		if (have_halt && dbg_wb_pc == halt_pc) done = 1;
	end
end

initial begin
	if (!$value$plusargs("prog=%s", progf)) begin
		$display("usage: +prog=<image.hex> [+trace=<out>] [+cycles=<n>] [+halt_pc=<hex>]");
		$finish;
	end
	if (!$value$plusargs("trace=%s", tracef)) tracef = "pipe_trace.txt";
	if (!$value$plusargs("cycles=%d", max_cycles)) max_cycles = 20000;
	have_halt = $value$plusargs("halt_pc=%h", halt_pc);

	for (i = 0; i < 32768; i = i + 1) img[i] = 16'h4E71;   // NOP fill
	$readmemh(progf, img);
	// image word i lives at byte address 2*i; the L1 index is PC_RESET-relative
	for (i = 0; i < L1_WORDS; i = i + 1)
		dut.u_l1.mem[(i - (PC_RESET >> 1)) & (L1_WORDS - 1)] = img[i];
	for (i = L1_WORDS; i < 32768; i = i + 1)
		if (img[i] !== 16'h4E71 && img[i] !== 16'h0000)
			$display("WARNING: image word %0d (addr %h) is outside the %0d-word L1 window and was dropped",
			         i, i * 2, L1_WORDS);

	fd = $fopen(tracef, "w");
	$fwrite(fd, "# pc sr d0 d1 d2 d3 d4 d5 d6 d7 a0 a1 a2 a3 a4 a5 a6 a7  (pipelined, sampled after commit)\n");
	n_ret = 0;

	repeat (3) @(posedge clk);
	nreset = 1;
	// reset-state record (pc ffffffff): since M1 the reset micro-op (ISP and
	// PC from vectors 0/1, RESET_FROM_VECTORS=1) retires with pc ffffffff, so
	// the retire logic above writes it -- the state after the reset sequence,
	// which is what the reference dumper's first line (at the first decode)
	// shows.
	for (cycles = 0; cycles < max_cycles && !done; cycles = cycles + 1) @(posedge clk);
	@(negedge clk);
	$fclose(fd);
	$display("tb_ap040_pipe_trace: %0d instructions retired in %0d cycles (%s), trace in %0s",
	         n_ret, cycles, done ? "halt_pc reached" : "cycle budget exhausted", tracef);
	$display("  final: pc=%08x sr=%04x d0=%08x d1=%08x d2=%08x d3=%08x d7=%08x a7=%08x",
	         last_pc, dbg_sr, dbg_d0, dbg_d1, dbg_d2, dbg_d3, dbg_d7, a7_live);
	$finish;
end

endmodule

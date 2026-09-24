//--------------------------------------------------------------------------//
// tb_ap040_pipe_red_movew.v - RED test: word-sized memory MOVE.             //
//                                                                          //
// Required behaviour (MC68040UM 3.x, and rtl_old/ap040_core.v move_size    //
// decode at ap040_core.v:903): MOVE.W (A0),D0 loads the 16-bit word at A0  //
// into D0[15:0], leaves D0[31:16] untouched, sets N from bit 15 and Z, and  //
// clears V and C (X unchanged).                                            //
//                                                                          //
// Status on the milestone-17 pipelined branch: opcode $3010 is not decoded //
// (ap040_decode.v only recognises size=Long MOVE forms, is_move_mem_l /    //
// is_move_disp) and falls into is_illegal -> vector 4. This bench is       //
// EXPECTED TO FAIL until byte/word sizes exist. It passes only when the     //
// feature is really there; do not "fix" the test.                          //
//--------------------------------------------------------------------------//
`timescale 1ns/1ps
module tb_ap040_pipe_red_movew;
localparam [31:0] PC_RESET = 32'h0000_0400;
localparam        PROG_WORDS = 40;
reg clk = 0; always #5 clk = ~clk;
reg nreset = 0;
wire        dbg_if_valid, dbg_id_valid, dbg_eac_valid, dbg_eaf_valid, dbg_ex_valid, dbg_wb_valid;
wire [31:0] dbg_if_pc, dbg_id_pc, dbg_eac_pc, dbg_eaf_pc, dbg_ex_pc, dbg_wb_pc;
wire [31:0] dbg_d0, dbg_d1, dbg_d2, dbg_d3, dbg_d4, dbg_d5, dbg_d6, dbg_d7;
wire  [4:0] dbg_ccr; wire [15:0] dbg_sr;
ap040_pipe_core #(.PC_RESET(PC_RESET), .PROG_WORDS(PROG_WORDS)) dut (
	.clk(clk), .nreset(nreset), .ce(1'b1),
	.dbg_if_valid(dbg_if_valid), .dbg_if_pc(dbg_if_pc), .dbg_id_valid(dbg_id_valid), .dbg_id_pc(dbg_id_pc),
	.dbg_eac_valid(dbg_eac_valid), .dbg_eac_pc(dbg_eac_pc), .dbg_eaf_valid(dbg_eaf_valid), .dbg_eaf_pc(dbg_eaf_pc),
	.dbg_ex_valid(dbg_ex_valid), .dbg_ex_pc(dbg_ex_pc), .dbg_wb_valid(dbg_wb_valid), .dbg_wb_pc(dbg_wb_pc),
	.dbg_d0(dbg_d0), .dbg_d1(dbg_d1), .dbg_d2(dbg_d2), .dbg_d3(dbg_d3),
	.dbg_d4(dbg_d4), .dbg_d5(dbg_d5), .dbg_d6(dbg_d6), .dbg_d7(dbg_d7), .dbg_ccr(dbg_ccr), .dbg_sr(dbg_sr));
integer errors = 0;
initial begin
	// program at PC_RESET (L1 index 0 = $400)
	dut.u_l1.mem[0] = 16'h3010;   // MOVE.W (A0),D0
	// marker: SMI D1 (fell through normally, and N=1 from the MOVE.W).  M1
	// fix to this bench: it had MOVEQ #1,D1 here, which clears N (PRM 4-134),
	// so the CCR check below could never pass on a correct core.
	dut.u_l1.mem[1] = 16'h5BC1;   // SMI D1
	dut.u_l1.mem[2] = 16'h4E71;
	dut.u_l1.mem[3] = 16'h4E71;
	// operand at $1000 (index (0x1000-0x400)>>1 = 0x600): word $8001
	dut.u_l1.mem[16'h600] = 16'h8001;
	dut.u_l1.mem[16'h601] = 16'hDEAD; // must not be read (a Long read would see it)
	// illegal-instruction vector 4 -> handler at $500 (index $80): MOVEQ #4,D2 ; NOP
	dut.u_l1.mem[16'hE08] = 16'h0000; dut.u_l1.mem[16'hE09] = 16'h0500;
	dut.u_l1.mem[16'h080] = 16'h7404; dut.u_l1.mem[16'h081] = 16'h4E71;
	repeat (3) @(posedge clk);
	nreset = 1;
	@(posedge clk); #1;
	dut.u_regfile.areg[0] = 32'h0000_1000;
	dut.u_regfile.dreg[0] = 32'hAAAA_AAAA;
	dut.u_regfile.isp     = 32'h0000_1800;
	repeat (PROG_WORDS + 60) @(posedge clk);
	if (dbg_d2 == 32'h0000_0004) begin errors = errors + 1;
		$display("FAIL: MOVE.W (A0),D0 took the illegal-instruction vector (opcode $3010 not decoded)"); end
	if (dbg_d0 !== 32'hAAAA_8001) begin errors = errors + 1;
		$display("FAIL: D0 = %h, expected AAAA8001 (word merged into the low half, upper half untouched)", dbg_d0); end
	if (dbg_ccr[3:0] !== 4'b1000) begin errors = errors + 1;   // N=1 Z=0 V=0 C=0
		$display("FAIL: CCR NZVC = %b, expected 1000", dbg_ccr[3:0]); end
	if (dbg_d1 !== 32'h0000_00FF) begin errors = errors + 1;
		$display("FAIL: D1 = %h, expected 000000FF (SMI after MOVE.W: did not retire, or N was clear)", dbg_d1); end
	if (errors == 0) $display("ALL TESTS PASSED"); else $display("TEST FAILED with %0d errors (expected until byte/word MOVE exists)", errors);
	$finish;
end
endmodule

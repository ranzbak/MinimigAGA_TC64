//--------------------------------------------------------------------------//
// tb_ap040_pipe_red_rte_fmt2.v - RED test: RTE must honour the frame format //
//                                                                          //
// Required behaviour (MC68040UM 8.4.2; rtl_old/ap040_core.v S_RTE_FMT at   //
// ~3211-3240): RTE reads the format/vector word at 6(SP); format $0 pops   //
// 8 bytes, format $2 pops 12 (the extra instruction-address longword),     //
// format $1 continues with the next frame, $3 pops 12, $7 pops 60 and      //
// restarts; an unknown format takes vector 14 (FMTERR) with a format-$0    //
// frame instead of returning.                                              //
//                                                                          //
// Status on milestone 17: ap040_ea_fetch.v's RTE sequencer assumes format  //
// $0 unconditionally ("format $0 is assumed unconditionally once the pop   //
// completes", its header) although milestone 17 itself now PUSHES format   //
// $2 frames. Returning from an address-error handler therefore leaves 4    //
// stale bytes on the supervisor stack. EXPECTED TO FAIL on the A7 check.   //
//--------------------------------------------------------------------------//
`timescale 1ns/1ps
module tb_ap040_pipe_red_rte_fmt2;
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
	// $400: RTE ; poison
	dut.u_l1.mem[0] = 16'h4E73;   // RTE
	dut.u_l1.mem[1] = 16'h7263;   // MOVEQ #99,D1 (poison: must not run)
	// $500 (index $80): return target: MOVEQ #5,D0 ; NOP
	dut.u_l1.mem[16'h080] = 16'h7005; dut.u_l1.mem[16'h081] = 16'h4E71;
	// format $2 frame at ISP=$1800 (index $A00): SR=$2000, PC=$00000500, fmt/vec=$200C (fmt 2, vector 3), addr=$00000501
	dut.u_l1.mem[16'hA00] = 16'h2000;
	dut.u_l1.mem[16'hA01] = 16'h0000; dut.u_l1.mem[16'hA02] = 16'h0500;
	dut.u_l1.mem[16'hA03] = 16'h200C;
	dut.u_l1.mem[16'hA04] = 16'h0000; dut.u_l1.mem[16'hA05] = 16'h0501;
	// FMTERR vector 14 -> $600 (index $100): MOVEQ #14,D2
	dut.u_l1.mem[16'hE1C] = 16'h0000; dut.u_l1.mem[16'hE1D] = 16'h0600;
	dut.u_l1.mem[16'h100] = 16'h740E; dut.u_l1.mem[16'h101] = 16'h4E71;
	repeat (3) @(posedge clk);
	nreset = 1;
	@(posedge clk); #1;
	dut.u_regfile.isp = 32'h0000_1800;
	repeat (PROG_WORDS + 60) @(posedge clk);
	if (dbg_d0 !== 32'h0000_0005) begin errors = errors + 1;
		$display("FAIL: D0 = %h, RTE did not return to the frame's PC $500", dbg_d0); end
	if (dbg_d1 !== 32'h0) begin errors = errors + 1;
		$display("FAIL: poison after RTE executed"); end
	if (dbg_d2 !== 32'h0) begin errors = errors + 1;
		$display("FAIL: RTE of a valid format $2 frame took FMTERR"); end
	if (dut.u_regfile.isp !== 32'h0000_180C) begin errors = errors + 1;
		$display("FAIL: ISP = %h after RTE of a format $2 frame, expected 0000180C (12 bytes popped, got %0d)",
		         dut.u_regfile.isp, dut.u_regfile.isp - 32'h1800); end
	if (errors == 0) $display("ALL TESTS PASSED"); else $display("TEST FAILED with %0d errors (expected until RTE decodes the format word)", errors);
	$finish;
end
endmodule

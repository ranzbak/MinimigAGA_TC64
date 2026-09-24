//--------------------------------------------------------------------------//
// tb_ap040_pipe_red_aline_fline.v - RED test: A-line and F-line vectors.    //
//                                                                          //
// Required behaviour (MC68040UM 8.2, rtl_old/ap040_core.v 0xA group at     //
// ~6137 and go_fp_fline at ~1481): an $Axxx opcode takes vector 10 and an  //
// unimplemented $Fxxx coprocessor opcode takes vector 11 (the 68LC040 /    //
// no-FPU build: every FPU op is vector 11, format $0 with the opcode's own //
// PC, or $2 for the FPSP-routed cases) -- NOT the generic illegal vector 4.//
// AmigaOS's 68040.library and the FPSP hang off vectors 10/11, so this is  //
// a boot blocker, not a corner case.                                       //
//                                                                          //
// Status on milestone 17: ap040_decode.v's is_illegal is "anything not     //
// recognised", so $A000 and $F280 both take vector 4. EXPECTED TO FAIL.    //
//--------------------------------------------------------------------------//
`timescale 1ns/1ps
module tb_ap040_pipe_red_aline_fline;
localparam [31:0] PC_RESET = 32'h0000_0400;
localparam        PROG_WORDS = 60;
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
	// $400: A-line op ; (handler A jumps to $410 via A1)
	dut.u_l1.mem[0] = 16'hA000;                       // A-line
	dut.u_l1.mem[1] = 16'h7263;                       // poison MOVEQ #99,D1
	// $410 (index 8): F-line op FNOP ($F280 $0000) ; (handler F jumps to $420 via A2)
	dut.u_l1.mem[8] = 16'hF280; dut.u_l1.mem[9] = 16'h0000;
	dut.u_l1.mem[10] = 16'h7263;                      // poison
	// $420 (index 16): done marker
	dut.u_l1.mem[16] = 16'h7E01;                      // MOVEQ #1,D7
	dut.u_l1.mem[17] = 16'h4E71;
	// vector 4 (illegal) -> $500: MOVEQ #4,D2 ; JMP (A3)   (A3 = $420, so a wrong vector still terminates)
	dut.u_l1.mem[16'hE08] = 16'h0000; dut.u_l1.mem[16'hE09] = 16'h0500;
	dut.u_l1.mem[16'h080] = 16'h7404; dut.u_l1.mem[16'h081] = 16'h4ED3;
	// vector 10 (A-line) -> $600: MOVEQ #10,D3 ; JMP (A1)
	dut.u_l1.mem[16'hE14] = 16'h0000; dut.u_l1.mem[16'hE15] = 16'h0600;
	dut.u_l1.mem[16'h100] = 16'h760A; dut.u_l1.mem[16'h101] = 16'h4ED1;
	// vector 11 (F-line) -> $700: MOVEQ #11,D4 ; JMP (A2)
	dut.u_l1.mem[16'hE16] = 16'h0000; dut.u_l1.mem[16'hE17] = 16'h0700;
	dut.u_l1.mem[16'h180] = 16'h780B; dut.u_l1.mem[16'h181] = 16'h4ED2;
	repeat (3) @(posedge clk);
	nreset = 1;
	@(posedge clk); #1;
	dut.u_regfile.isp     = 32'h0000_1800;
	dut.u_regfile.areg[1] = 32'h0000_0410;
	dut.u_regfile.areg[2] = 32'h0000_0420;
	dut.u_regfile.areg[3] = 32'h0000_0420;
	repeat (PROG_WORDS + 80) @(posedge clk);
	if (dbg_d3 !== 32'h0000_000A) begin errors = errors + 1;
		$display("FAIL: A-line opcode $A000 did not take vector 10 (D3=%h, D2=%h -> vector %0d)", dbg_d3, dbg_d2, dbg_d2); end
	if (dbg_d4 !== 32'h0000_000B) begin errors = errors + 1;
		$display("FAIL: F-line opcode $F280 did not take vector 11 (D4=%h, D2=%h)", dbg_d4, dbg_d2); end
	if (dbg_d1 !== 32'h0) begin errors = errors + 1;
		$display("FAIL: poison after a line-A/F opcode executed"); end
	if (errors == 0) $display("ALL TESTS PASSED"); else $display("TEST FAILED with %0d errors (expected until A/F-line are classified)", errors);
	$finish;
end
endmodule

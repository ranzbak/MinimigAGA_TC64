//--------------------------------------------------------------------------//
// tb_ap040_pipe_red_vbr.v - RED test: vector fetch must go through VBR.     //
//                                                                          //
// Required behaviour (MC68040UM 8.1, rtl_old/ap040_core.v S_EXC_VEC):      //
// the exception vector address is VBR + vector*4.                          //
//                                                                          //
// Status on milestone 17: VBR exists as a MOVEC target, but the vector     //
// fetch in ap040_ea_fetch.v is PC_RESET-relative and never reads it (the   //
// implementation plan, section 6 item 2b: "VBR exists but isn't consulted  //
// yet"). Program: MOVEQ #$40,D0 ; MOVEC D0,VBR ; TRAP #0. With VBR=$40 the  //
// TRAP #0 vector lives at $40+$80 = $C0, which holds a pointer to handler   //
// B (MOVEQ #2,D2); the VBR=0 slot $80 points to handler A (MOVEQ #1,D2).    //
// Expected D2 = 2. EXPECTED TO FAIL (D2 = 1) until VBR is wired.            //
//--------------------------------------------------------------------------//
`timescale 1ns/1ps
module tb_ap040_pipe_red_vbr;
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
	dut.u_l1.mem[0] = 16'h7040;                          // MOVEQ #$40,D0
	dut.u_l1.mem[1] = 16'h4E7B; dut.u_l1.mem[2] = 16'h0801; // MOVEC D0,VBR
	dut.u_l1.mem[3] = 16'h4E40;                          // TRAP #0
	dut.u_l1.mem[4] = 16'h4E71; dut.u_l1.mem[5] = 16'h4E71;
	// VBR=0 world: vector 32 at $80 (index $E40) -> handler A at $500 (index $80)
	dut.u_l1.mem[16'hE40] = 16'h0000; dut.u_l1.mem[16'hE41] = 16'h0500;
	dut.u_l1.mem[16'h080] = 16'h7401; dut.u_l1.mem[16'h081] = 16'h4E71;   // MOVEQ #1,D2
	// VBR=$40 world: vector 32 at $C0 (index $E60) -> handler B at $600 (index $100)
	dut.u_l1.mem[16'hE60] = 16'h0000; dut.u_l1.mem[16'hE61] = 16'h0600;
	dut.u_l1.mem[16'h100] = 16'h7402; dut.u_l1.mem[16'h101] = 16'h4E71;   // MOVEQ #2,D2
	repeat (3) @(posedge clk);
	nreset = 1;
	@(posedge clk); #1;
	dut.u_regfile.isp = 32'h0000_1800;
	repeat (PROG_WORDS + 60) @(posedge clk);
	if (dbg_d2 !== 32'h0000_0002) begin errors = errors + 1;
		$display("FAIL: D2 = %h, expected 00000002 (vector fetched from VBR+$80); 1 means VBR was ignored", dbg_d2); end
	if (errors == 0) $display("ALL TESTS PASSED"); else $display("TEST FAILED with %0d errors (expected until VBR feeds the vector fetch)", errors);
	$finish;
end
endmodule

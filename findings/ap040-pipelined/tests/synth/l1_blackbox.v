// Black-box stand-in for ap040_pipe_l1.v in the OOC budget synth: the L1
// array is the test substrate (4K x 16 words, byte-granular any-alignment
// read and write ports -- ~200K LUTs as flops), not part of the core being
// budgeted.  Removed from the tree at M5.  Ports as of plan M1.
(* black_box *)
module ap040_pipe_l1 #(parameter AW = 12, parameter DW = 16, parameter [31:0] PC_RESET = 32'h400) (
	input clock, input nreset,
	input [AW-1:0] address_a, input en_a, output [31:0] q_a,
	input rd_req, input [31:0] rd_addr, input [1:0] rd_size, output rd_ack, output [31:0] rd_data,
	input wr_req, input [31:0] wr_addr, input [1:0] wr_size, input [31:0] wr_data, output wr_ready
);
endmodule

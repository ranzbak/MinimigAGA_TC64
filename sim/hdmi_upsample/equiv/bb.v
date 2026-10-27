(* blackbox *)
module bram_tdp #(parameter DATA = 72, parameter ADDR = 10) (
  input a_clk, input a_wr, input [ADDR-1:0] a_addr, input [DATA-1:0] a_din, output [DATA-1:0] a_dout,
  input b_clk, input b_wr, input [ADDR-1:0] b_addr, input [DATA-1:0] b_din, output [DATA-1:0] b_dout);
endmodule

`timescale 1ns/1ps
module tb;
  reg clk = 0; always #4 clk = ~clk; reg rstn = 0; initial #100 rstn = 1;
`include "mem_common.vh"
  wire [31:0] adr, dout; wire we, stb, wbcyc; wire [3:0] sel;
  reg ack = 0; reg [31:0] din = 0; reg busy = 0, bw = 0; reg [31:0] ba = 0, bd = 0; reg [3:0] bs = 0; integer cnt = 0;
  always @(posedge clk) begin
    ack <= 0;
    if (stb) begin busy <= 1; ba <= adr; bw <= we; bd <= dout; bs <= sel; cnt <= `WS;
      if (`WS == 0) begin busy <= 0; ack <= 1; if (we) do_write(adr, dout, sel); else din <= rd(adr); end end
    else if (busy) begin if (cnt == 1) begin busy <= 0; ack <= 1; if (bw) do_write(ba, bd, bs); else din <= rd(ba); end
                         else cnt <= cnt - 1; end
  end
  neo_dut #(.C(`C), .IC(`IC), .ICB(`ICB), .BS(`BS)) dut (.clk(clk), .rstn(rstn), .adr(adr), .dat_o(dout), .we(we), .stb(stb), .cyc(wbcyc), .sel(sel), .dat_i(din), .ack(ack));
endmodule

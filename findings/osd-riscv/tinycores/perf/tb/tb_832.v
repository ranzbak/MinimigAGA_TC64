`timescale 1ns/1ps
module tb;
  reg clk = 0; always #4 clk = ~clk; reg rst_n = 0; initial #100 rst_n = 1;
`include "mem_common.vh"
  wire [31:2] addr; wire [31:0] q; wire wr, req; wire [3:0] bs;
  reg ack = 0; reg [31:0] d = 0; integer cnt = 0;
  always @(posedge clk) begin
    ack <= 0;
    if (req && !ack) begin if (cnt == `WS) begin ack <= 1; cnt <= 0; if (wr) begin do_write({addr,2'b00}, q, {bs[0],bs[1],bs[2],bs[3]}); /* 832 bytesel(0) = q(31:24) */ end else d <= rd({addr,2'b00}); end
                      else cnt <= cnt + 1; end
  end
  eightthirtytwo_cpu #(.littleendian(0), .interrupts(1), .dualthread(0), .forwarding(0), .prefetch(0), .debug(0))
    cpu (.clk(clk), .reset_n(rst_n), .interrupt(1'b0), .addr(addr), .d(d), .q(q), .wr(wr), .req(req), .ack(ack), .bytesel(bs),
         .debug_d(32'b0), .debug_q(), .debug_req(), .debug_wr(), .debug_ack(1'b0));
endmodule

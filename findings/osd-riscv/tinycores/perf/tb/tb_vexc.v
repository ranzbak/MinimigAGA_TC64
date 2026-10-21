`timescale 1ns/1ps
// VexRiscv with IBusCachedPlugin: one cmd per 32-byte line, 8 single-word beats, each beat 1+WS cycles on the shared port
module tb;
  reg clk = 0; always #4 clk = ~clk; reg rst = 1; initial #100 rst = 0;
`include "mem_common.vh"
  wire icv, dcv, dwr; wire [31:0] iadr, dadr, ddat; wire [3:0] dmask; wire [1:0] dsize; wire [2:0] isize;
  reg busy = 0, isI = 0, isW = 0; integer cnt = 0, beats = 0; reg [31:0] a = 0;
  reg irv = 0, drv = 0; reg [31:0] rdata = 0;
  wire dcr = !busy && !rst;
  wire icr = !busy && !rst && !dcv;
  always @(posedge clk) begin
    irv <= 0; drv <= 0;
    if (busy) begin
      if (cnt == 0) begin
        if (isW) busy <= 0;
        else if (isI) begin rdata <= rd(a); irv <= 1; a <= a + 4;
          if (beats == 1) busy <= 0; else begin beats <= beats - 1; cnt <= `WS; end end
        else begin rdata <= rd(a); drv <= 1; busy <= 0; end
      end else cnt <= cnt - 1;
    end else if (dcv && dcr) begin
      a <= dadr; isI <= 0; isW <= dwr; if (dwr) do_write(dadr, ddat, dmask);
      if (`WS == 0) begin if (!dwr) begin rdata <= rd(dadr); drv <= 1; end end else begin busy <= 1; cnt <= `WS - 1; end
    end else if (icv && icr) begin
      a <= {iadr[31:5], 5'b0}; isI <= 1; isW <= 0; busy <= 1; beats <= 8; cnt <= `WS;
    end
  end
  `VEXMOD cpu (.clk(clk), .reset(rst), .iBus_cmd_valid(icv), .iBus_cmd_ready(icr), .iBus_cmd_payload_address(iadr),
    .iBus_cmd_payload_size(isize), .iBus_rsp_valid(irv), .iBus_rsp_payload_error(1'b0), .iBus_rsp_payload_data(rdata),
    .timerInterrupt(1'b0), .externalInterrupt(1'b0), .softwareInterrupt(1'b0),
    .dBus_cmd_valid(dcv), .dBus_cmd_ready(dcr), .dBus_cmd_payload_wr(dwr), .dBus_cmd_payload_mask(dmask),
    .dBus_cmd_payload_address(dadr), .dBus_cmd_payload_data(ddat), .dBus_cmd_payload_size(dsize),
    .dBus_rsp_ready(drv), .dBus_rsp_error(1'b0), .dBus_rsp_data(rdata));
endmodule

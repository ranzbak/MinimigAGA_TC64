`timescale 1ns/1ps
module tb;
  reg clk = 0; always #4 clk = ~clk; reg rst = 1; initial #100 rst = 0;
`include "mem_common.vh"
  wire icv, dcv, dwr; wire [31:0] ipc, dadr, ddat; wire [3:0] dmask; wire [1:0] dsize;
  // single shared port: one access in flight; read response 1+WS cycles after accept; writes hold the port WS cycles
  reg busy = 0, isI = 0, isW = 0; integer cnt = 0; reg [31:0] a = 0;
  reg irv = 0, drv = 0; reg [31:0] rdata = 0;
  wire dcr = !busy && !rst;
  wire icr = !busy && !rst && !dcv;
  // access occupies 1+WS cycles like an AHB data phase; next accept can overlap the response cycle
  always @(posedge clk) begin
    irv <= 0; drv <= 0;
    if (busy) begin
      if (cnt == 0) begin busy <= 0; if (!isW) begin rdata <= rd(a); if (isI) irv <= 1; else drv <= 1; end end
      else cnt <= cnt - 1;
    end else if (dcv && dcr) begin
      a <= dadr; isI <= 0; isW <= dwr; if (dwr) do_write(dadr, ddat, dmask);
      if (`WS == 0) begin if (!dwr) begin rdata <= rd(dadr); drv <= 1; end end else begin busy <= 1; cnt <= `WS - 1; end
    end else if (icv && icr) begin
      a <= ipc; isI <= 1; isW <= 0;
      if (`WS == 0) begin rdata <= rd(ipc); irv <= 1; end else begin busy <= 1; cnt <= `WS - 1; end
    end
  end
  `VEXMOD cpu (.clk(clk), .reset(rst), .iBus_cmd_valid(icv), .iBus_cmd_ready(icr), .iBus_cmd_payload_pc(ipc),
    .iBus_rsp_valid(irv), .iBus_rsp_payload_error(1'b0), .iBus_rsp_payload_inst(rdata),
    .timerInterrupt(1'b0), .externalInterrupt(1'b0), .softwareInterrupt(1'b0),
    .dBus_cmd_valid(dcv), .dBus_cmd_ready(dcr), .dBus_cmd_payload_wr(dwr), .dBus_cmd_payload_mask(dmask),
    .dBus_cmd_payload_address(dadr), .dBus_cmd_payload_data(ddat), .dBus_cmd_payload_size(dsize),
    .dBus_rsp_ready(drv), .dBus_rsp_error(1'b0), .dBus_rsp_data(rdata));
endmodule

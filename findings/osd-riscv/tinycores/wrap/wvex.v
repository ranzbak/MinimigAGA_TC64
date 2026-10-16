// Registered-I/O OOC wrapper for generated VexRiscv (IBusSimple/DBusSimple). Module name via `VEXMOD, `DM adds JTAG.
module wtop (input clk, input reset_i, input tck, input tms, input tdi, output tdo,
  input ext_irq_i, input tmr_irq_i, input icr_i, input irv_i, input [31:0] ird_i, input dcr_i, input drv_i, input [31:0] drd_i,
  output reg icv, output reg [31:0] ipc, output reg dcv, output reg dwr, output reg [3:0] dmask, output reg [31:0] dadr,
  output reg [31:0] ddat, output reg [1:0] dsize);
  reg rst, eirq, tirq, icr, irv, dcr, drv; reg [31:0] ird, drd;
  wire icv_w, dcv_w, dwr_w; wire [31:0] ipc_w, dadr_w, ddat_w; wire [3:0] dm_w; wire [1:0] ds_w;
  always @(posedge clk) begin rst <= reset_i; eirq <= ext_irq_i; tirq <= tmr_irq_i; icr <= icr_i; irv <= irv_i; ird <= ird_i;
    dcr <= dcr_i; drv <= drv_i; drd <= drd_i; icv <= icv_w; ipc <= ipc_w; dcv <= dcv_w; dwr <= dwr_w; dmask <= dm_w;
    dadr <= dadr_w; ddat <= ddat_w; dsize <= ds_w; end
  `VEXMOD u_core (.clk(clk), .reset(rst),
`ifdef ICACHE
    .iBus_cmd_valid(icv_w), .iBus_cmd_ready(icr), .iBus_cmd_payload_address(ipc_w), .iBus_cmd_payload_size(), .iBus_rsp_valid(irv),
    .iBus_rsp_payload_error(1'b0), .iBus_rsp_payload_data(ird),
`else
    .iBus_cmd_valid(icv_w), .iBus_cmd_ready(icr), .iBus_cmd_payload_pc(ipc_w), .iBus_rsp_valid(irv),
    .iBus_rsp_payload_error(1'b0), .iBus_rsp_payload_inst(ird),
`endif
    .timerInterrupt(tirq), .externalInterrupt(eirq), .softwareInterrupt(1'b0),
`ifdef DM
    .jtag_tms(tms), .jtag_tdi(tdi), .jtag_tdo(tdo), .jtag_tck(tck), .ndmreset(), .stoptime(), .debugReset(rst),
`endif
    .dBus_cmd_valid(dcv_w), .dBus_cmd_ready(dcr), .dBus_cmd_payload_wr(dwr_w), .dBus_cmd_payload_mask(dm_w),
    .dBus_cmd_payload_address(dadr_w), .dBus_cmd_payload_data(ddat_w), .dBus_cmd_payload_size(ds_w),
    .dBus_rsp_ready(drv), .dBus_rsp_error(1'b0), .dBus_rsp_data(drd));
`ifndef DM
  assign tdo = 1'b0;
`endif
endmodule

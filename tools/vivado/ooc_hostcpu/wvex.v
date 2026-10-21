// Registered-I/O OOC wrapper for the generated VexOsd cores (rtl/host/vexriscv).
// Defines from run.tcl: VEXMOD=<module>, and DMT or DMJ for the debug variants.
// The JTAG pins are plain ports (no register stage): they belong to the tck domain.
module wtop (input clk, input reset_i, input ext_irq_i, input tmr_irq_i,
  input icr_i, input irv_i, input [31:0] ird_i, input dcr_i, input drv_i, input [31:0] drd_i,
  input tck, input tms, input tdi, output tdo,
  input ji_tdi, input ji_enable, input ji_capture, input ji_shift, input ji_update, input ji_reset,
  output reg icv, output reg [31:0] ipc, output reg dcv, output reg dwr, output reg [3:0] dmask,
  output reg [31:0] dadr, output reg [31:0] ddat, output reg [1:0] dsize, output reg ndm, output reg stopt);
  reg rst, eirq, tirq, icr, irv, dcr, drv; reg [31:0] ird, drd;
  wire icv_w, dcv_w, dwr_w, ndm_w, stopt_w; wire [31:0] ipc_w, dadr_w, ddat_w; wire [3:0] dm_w; wire [1:0] ds_w;
  always @(posedge clk) begin rst <= reset_i; eirq <= ext_irq_i; tirq <= tmr_irq_i; icr <= icr_i; irv <= irv_i; ird <= ird_i;
    dcr <= dcr_i; drv <= drv_i; drd <= drd_i; icv <= icv_w; ipc <= ipc_w; dcv <= dcv_w; dwr <= dwr_w; dmask <= dm_w;
    dadr <= dadr_w; ddat <= ddat_w; dsize <= ds_w; ndm <= ndm_w; stopt <= stopt_w; end
  `VEXMOD u_core (.clk(clk), .reset(rst),
    .iBus_cmd_valid(icv_w), .iBus_cmd_ready(icr), .iBus_cmd_payload_address(ipc_w), .iBus_cmd_payload_size(),
    .iBus_rsp_valid(irv), .iBus_rsp_payload_error(1'b0), .iBus_rsp_payload_data(ird),
    .timerInterrupt(tirq), .externalInterrupt(eirq), .softwareInterrupt(1'b0),
`ifdef DMT
    .jtagInstruction_tdi(ji_tdi), .jtagInstruction_enable(ji_enable), .jtagInstruction_capture(ji_capture),
    .jtagInstruction_shift(ji_shift), .jtagInstruction_update(ji_update), .jtagInstruction_reset(ji_reset),
    .jtagInstruction_tdo(tdo), .jtag_tck(tck), .ndmreset(ndm_w), .stoptime(stopt_w), .debugReset(rst),
`endif
`ifdef DMJ
    .jtag_tms(tms), .jtag_tdi(tdi), .jtag_tdo(tdo), .jtag_tck(tck), .ndmreset(ndm_w), .stoptime(stopt_w), .debugReset(rst),
`endif
    .dBus_cmd_valid(dcv_w), .dBus_cmd_ready(dcr), .dBus_cmd_payload_wr(dwr_w), .dBus_cmd_payload_mask(dm_w),
    .dBus_cmd_payload_address(dadr_w), .dBus_cmd_payload_data(ddat_w), .dBus_cmd_payload_size(ds_w),
    .dBus_rsp_ready(drv), .dBus_rsp_error(1'b0), .dBus_rsp_data(drd));
`ifndef DMT
`ifndef DMJ
  assign tdo = 1'b0; assign ndm_w = 1'b0; assign stopt_w = 1'b0;
`endif
`endif
endmodule

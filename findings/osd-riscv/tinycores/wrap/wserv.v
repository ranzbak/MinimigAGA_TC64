`default_nettype wire
// Registered-I/O OOC wrapper for SERV (serv_rf_top, RF in inferred BRAM). W=1 SERV, W=4 QERV.
module wtop #(parameter W = 1, parameter COMPRESSED = 0) (
  input clk, input rst_i, input timer_irq_i,
  input [31:0] ibus_rdt_i, input ibus_ack_i, input [31:0] dbus_rdt_i, input dbus_ack_i,
  output reg [31:0] ibus_adr, output reg ibus_cyc, output reg [31:0] dbus_adr, output reg [31:0] dbus_dat,
  output reg [3:0] dbus_sel, output reg dbus_we, output reg dbus_cyc);
  reg rst, tirq, iack, dack; reg [31:0] irdt, drdt;
  wire [31:0] ia, da, dd; wire ic, dw, dc; wire [3:0] ds;
  always @(posedge clk) begin rst <= rst_i; tirq <= timer_irq_i; irdt <= ibus_rdt_i; iack <= ibus_ack_i;
    drdt <= dbus_rdt_i; dack <= dbus_ack_i; ibus_adr <= ia; ibus_cyc <= ic; dbus_adr <= da; dbus_dat <= dd;
    dbus_sel <= ds; dbus_we <= dw; dbus_cyc <= dc; end
  serv_rf_top #(.RESET_PC(0), .COMPRESSED(COMPRESSED), .MDU(0), .WITH_CSR(1), .W(W)) u_core (
    .clk(clk), .i_rst(rst), .i_timer_irq(tirq),
    .o_ibus_adr(ia), .o_ibus_cyc(ic), .i_ibus_rdt(irdt), .i_ibus_ack(iack),
    .o_dbus_adr(da), .o_dbus_dat(dd), .o_dbus_sel(ds), .o_dbus_we(dw), .o_dbus_cyc(dc),
    .i_dbus_rdt(drdt), .i_dbus_ack(dack),
    .o_ext_rs1(), .o_ext_rs2(), .o_ext_funct3(), .i_ext_rd(32'b0), .i_ext_ready(1'b0), .o_mdu_valid());
endmodule

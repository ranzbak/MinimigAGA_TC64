`timescale 1ns/1ps
module tb;
  reg clk = 0; always #4 clk = ~clk; reg rst = 1; initial #100 rst = 0;
`include "mem_common.vh"
  wire [31:0] ia, da, dd; wire ic, dw, dc; wire [3:0] ds;
  reg iack = 0, dack = 0; integer icnt = 0, dcnt = 0; reg [31:0] irdt = 0, drdt = 0;
  // Wishbone, one access at a time; ack after 1+WS cycles, 1-cycle pulse
  always @(posedge clk) begin
    iack <= 0; dack <= 0;
    if (ic && !iack) begin if (icnt == `WS) begin iack <= 1; irdt <= rd(ia); icnt <= 0; end else icnt <= icnt + 1; end
    if (dc && !dack) begin if (dcnt == `WS) begin dack <= 1; if (dw) do_write(da, dd, ds); else drdt <= rd(da); dcnt <= 0; end
                            else dcnt <= dcnt + 1; end
  end
  serv_rf_top #(.RESET_PC(0), .COMPRESSED(`C), .MDU(0), .WITH_CSR(1), .W(`W)) cpu (.clk(clk), .i_rst(rst), .i_timer_irq(1'b0),
    .o_ibus_adr(ia), .o_ibus_cyc(ic), .i_ibus_rdt(irdt), .i_ibus_ack(iack),
    .o_dbus_adr(da), .o_dbus_dat(dd), .o_dbus_sel(ds), .o_dbus_we(dw), .o_dbus_cyc(dc), .i_dbus_rdt(drdt), .i_dbus_ack(dack),
    .o_ext_rs1(), .o_ext_rs2(), .o_ext_funct3(), .i_ext_rd(32'b0), .i_ext_ready(1'b0), .o_mdu_valid());
endmodule

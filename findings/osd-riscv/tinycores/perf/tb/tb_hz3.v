`timescale 1ns/1ps
module tb;
  reg clk = 0; always #4 clk = ~clk; reg rst_n = 0; initial #100 rst_n = 1;
`include "mem_common.vh"
  wire [31:0] haddr, hwdata; wire hwrite; wire [1:0] htrans; wire [2:0] hsize;
  reg dp = 0, dpw = 0; reg [31:0] dpa = 0; reg [2:0] dps = 0; integer cnt = 0;
  wire hready = !dp || cnt == 0;
  wire [31:0] hrdata = rd(dpa);
  wire [3:0] be = (dps == 0) ? (4'b1 << dpa[1:0]) : (dps == 1) ? (4'b11 << {dpa[1],1'b0}) : 4'hf;
  always @(posedge clk) if (hready) begin
      if (dp && dpw) do_write(dpa, hwdata, be);
      if (htrans[1]) begin dp <= 1; dpa <= haddr; dpw <= hwrite; dps <= hsize; cnt <= `WS; end else dp <= 0;
    end else cnt <= cnt - 1;
  hazard3_cpu_1port #(.RESET_VECTOR(0), .MTVEC_INIT(0), .EXTENSION_A(0), .EXTENSION_C(`C), .EXTENSION_M(1),
    .CSR_COUNTER(0), .DEBUG_SUPPORT(0), .NUM_IRQS(1), .MULDIV_UNROLL(1), .MUL_FAST(1), .FAST_BRANCHCMP(1), .BRANCH_PREDICTOR(0))
  cpu (.clk(clk), .clk_always_on(clk), .rst_n(rst_n), .pwrup_ack(1'b1), .unblock_in(1'b0), .haddr(haddr), .hwrite(hwrite),
    .htrans(htrans), .hsize(hsize), .hready(hready), .hresp(1'b0), .hexokay(1'b1), .hwdata(hwdata), .hrdata(hrdata),
    .fence_rdy(1'b1), .dbg_req_halt(1'b0), .dbg_req_halt_on_reset(1'b0), .dbg_req_resume(1'b0), .dbg_data0_rdata(32'b0),
    .dbg_instr_data(32'b0), .dbg_instr_data_vld(1'b0), .dbg_sbus_addr(32'b0), .dbg_sbus_write(1'b0), .dbg_sbus_size(2'b0),
    .dbg_sbus_vld(1'b0), .dbg_sbus_wdata(32'b0), .mhartid_val(32'b0), .eco_version(4'b0), .irq(1'b0), .soft_irq(1'b0), .timer_irq(1'b0));
endmodule

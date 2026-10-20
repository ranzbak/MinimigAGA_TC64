`timescale 1ns/1ps
// Debug bench top: rv_hostcpu + the L1 memory model and bus checker
// (sim/rv_l1/mem_model.v, sim/rv_l1/bus_checker.v, used by path), driven by
// the Verilator C++ harness harness.cpp (system clock, JTAG pins, the TCP
// servers).  The harness owns time; this module has no clock generator.
//
// Parameter DEBUG (verilator -GDEBUG=<n>):
//   2  VexOsd_DMJ: the RISC-V TAP (IDCODE 0x10002FFF, IR 5) on the pins
//      tck/tms/tdi/tdo directly (OpenOCD: tools/openocd/minimig-rv-pins.cfg)
//   1  VexOsd_DMT behind rtl/host/xilinx/rv_bscane2.v (BSCANE2 USER4 +
//      BUFG): the pins drive the 7-series TAP model xc7_tap.v (XC7A100T:
//      IR 6, IDCODE 0x03631093; instance xc7_jtag, which its BSCANE2
//      stand-in reaches by name, as the unisims reach glbl), whose BSCANE2
//      and BUFG stand-ins replace the unisim primitives (Verilator cannot
//      build JTAG_SIME2.v; xc7_tap.v says why, sim/rv_dbg/xcheck compares
//      the two).  Needs -DRV_DBG_XC7TAP and xc7_tap.v (run.sh adds both).
//      OpenOCD: tools/openocd/minimig-rv-bscan.cfg.
// -DTEETH_USER4 (DEBUG = 1 only): the TAP model's USER4 instruction is
//   0x22 instead of 0x23 (= USER3: the decode takes USER3 first), so
//   OpenOCD's tunnel IR 0x23 selects nothing and the hart cannot be examined.
//
// Plusargs (memory model): +HEX=<file> +WS=<n> +ROMWS=<n>.
// Results (the harness ends the run on $finish): "=== PASS" (DONE 0),
// "=== FAIL <code>" (DONE code, hex), "=== FAIL bus violation",
// "=== FAIL bad address", "=== FAIL uart read".  The cycle timeout is the
// harness's (+timeout=<cycles>).
module tb_rv_dbg #(
  parameter DEBUG = 2
) (
  input  wire        clk,
  input  wire        tck,
  input  wire        tms,
  input  wire        tdi,
  output wire        tdo,
  output wire        core_rst,   // rv_hostcpu's core reset (harness log)
  output reg  [63:0] cycles,     // system clocks since the reset release
  output reg         failed      // set with a "=== FAIL" verdict ($finish)
);
  reg reset_n = 1'b0;
  reg rst     = 1'b1;
  initial failed = 1'b0;

  wire [31:2] addr;
  wire [31:0] q, d;
  wire [3:0]  sel;
  wire        wr, req, ack, irq, done, bad_addr, uart_rd, violation;
  wire [15:0] done_code;
  wire        pin_tdo;

`ifdef RV_DBG_XC7TAP
  // the FPGA's TAP (DEBUG = 1); its tdo is high-Z outside Shift-IR/DR, read
  // as 1 here (a pull-up)
  wire tap_tdo, tap_tdo_oe;
`ifdef TEETH_USER4
  xc7_tap #(.USER4(6'h22)) xc7_jtag (
`else
  xc7_tap xc7_jtag (
`endif
    .tck(tck), .tms(tms), .tdi(tdi), .tdo(tap_tdo), .tdo_oe(tap_tdo_oe));
  assign tdo = tap_tdo_oe ? tap_tdo : 1'b1;
  initial if (DEBUG != 1) begin
    $display("=== FAIL RV_DBG_XC7TAP needs DEBUG=1");
    failed = 1'b1;
    $finish;
  end
`else
  assign tdo = pin_tdo;
  initial if (DEBUG == 1) begin
    $display("=== FAIL DEBUG=1 needs RV_DBG_XC7TAP (and xc7_tap.v)");
    failed = 1'b1;
    $finish;
  end
`endif

  rv_hostcpu #(.DEBUG(DEBUG)) dut (
    .clk(clk), .reset_n(reset_n),
    .addr(addr), .q(q), .sel(sel), .wr(wr), .req(req), .ack(ack), .d(d),
    .irq_ext(irq), .irq_timer(1'b0), .irq_soft(1'b0),
    .jtag_tck(tck), .jtag_tms(tms), .jtag_tdi(tdi), .jtag_tdo(pin_tdo));

  assign core_rst = dut.core_rst;

  mem_model mem (
    .clk(clk), .rst(rst), .addr(addr), .q(q), .sel(sel), .wr(wr), .req(req),
    .ack(ack), .d(d), .irq(irq), .done(done), .done_code(done_code),
    .bad_addr(bad_addr), .uart_rd(uart_rd));

  bus_checker chk (
    .clk(clk), .rst(rst), .req(req), .ack(ack), .wr(wr), .addr(addr), .q(q),
    .sel(sel), .d(d), .violation(violation));

  initial $display("=== TB rv_dbg DEBUG=%0d%s", DEBUG,
`ifdef TEETH_USER4
                   " TEETH_USER4 (USER4 = 0x22)"
`else
                   ""
`endif
                   );

  // reset released in the NBA region of the 8th rising edge (as tb_rv_l1)
  reg [3:0] rst_cnt = 4'd0;
  always @(posedge clk)
    if (rst_cnt != 4'd8) begin
      rst_cnt <= rst_cnt + 4'd1;
      if (rst_cnt == 4'd7) begin
        rst     <= 1'b0;
        reset_n <= 1'b1;
      end
    end

  always @(posedge clk) begin
    if (rst) cycles <= 64'd0;
    else     cycles <= cycles + 64'd1;

    if (!rst) begin
      if (violation) begin
        $display("=== FAIL bus violation");
        failed = 1'b1;
        $finish;
      end else if (bad_addr) begin
        $display("=== FAIL bad address");
        failed = 1'b1;
        $finish;
      end else if (uart_rd) begin
        $display("=== FAIL uart read");
        failed = 1'b1;
        $finish;
      end else if (done) begin
        if (done_code == 16'h0) $display("=== PASS");
        else begin
          $display("=== FAIL %0x", done_code);
          failed = 1'b1;
        end
        $finish;
      end
    end
  end
endmodule

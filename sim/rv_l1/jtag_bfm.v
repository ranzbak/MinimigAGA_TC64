`timescale 1ns/1ps
// JTAG master BFM (simulation only): drives tck/tms/tdi, samples tdo.
//
// TCK period TCK_NS (default 50 ns), free of any relation to the CPU clock.
// One TCK cycle (task step): tms/tdi change while tck is low, tdo is sampled
// just before the rising edge (the TAP drives it on the falling edge), then
// tck high for half a period.  Between scans the TAP is left in
// Run-Test/Idle with tck low.
//
// Tasks (call as <instance>.<task>):
//   jtag_reset              5 x TMS=1 (Test-Logic-Reset), then Run-Test/Idle
//   jtag_idle(n)            n TCK cycles in Run-Test/Idle
//   jtag_ir(width, value)   IR scan, Run-Test/Idle -> ... -> Run-Test/Idle
//   jtag_dr(n, in, out)     DR scan of n bits (1..64), LSB first; out = the
//                           n bits shifted out (out[i] = bit i), upper bits 0
module jtag_bfm #(
  parameter real TCK_NS = 50.0
) (
  output reg tck,
  output reg tms,
  output reg tdi,
  input wire tdo
);
  initial begin tck = 1'b0; tms = 1'b1; tdi = 1'b0; end

  integer n_tck;   // TCK cycles driven so far (for the log)
  initial n_tck = 0;

  task step(input t_ms, input t_di, output t_do);
    begin
      tms = t_ms;
      tdi = t_di;
      #(TCK_NS / 2.0);
      t_do = tdo;
      tck = 1'b1;
      #(TCK_NS / 2.0);
      tck = 1'b0;
      n_tck = n_tck + 1;
    end
  endtask

  task jtag_reset;
    reg dummy;
    integer i;
    begin
      for (i = 0; i < 5; i = i + 1) step(1'b1, 1'b0, dummy);
      step(1'b0, 1'b0, dummy);               // -> Run-Test/Idle
    end
  endtask

  task jtag_idle(input integer n);
    reg dummy;
    integer i;
    begin
      for (i = 0; i < n; i = i + 1) step(1'b0, 1'b0, dummy);
    end
  endtask

  // Run-Test/Idle -> Select-DR -> Select-IR -> Capture-IR -> Shift-IR,
  // width bits (last with TMS=1 -> Exit1-IR) -> Update-IR -> Run-Test/Idle
  task jtag_ir(input integer width, input [31:0] value);
    reg dummy;
    integer i;
    begin
      step(1'b1, 1'b0, dummy);
      step(1'b1, 1'b0, dummy);
      step(1'b0, 1'b0, dummy);
      step(1'b0, 1'b0, dummy);
      for (i = 0; i < width; i = i + 1)
        step(i == width - 1, value[i], dummy);
      step(1'b1, 1'b0, dummy);
      step(1'b0, 1'b0, dummy);
    end
  endtask

  // Run-Test/Idle -> Select-DR -> Capture-DR -> Shift-DR, n bits (last with
  // TMS=1 -> Exit1-DR) -> Update-DR -> Run-Test/Idle
  task jtag_dr(input integer n, input [63:0] din, output [63:0] dout);
    reg b;
    integer i;
    reg dummy;
    begin
      dout = 64'h0;
      step(1'b1, 1'b0, dummy);
      step(1'b0, 1'b0, dummy);
      step(1'b0, 1'b0, dummy);
      for (i = 0; i < n; i = i + 1) begin
        step(i == n - 1, din[i], b);
        dout[i] = b;
      end
      step(1'b1, 1'b0, dummy);
      step(1'b0, 1'b0, dummy);
    end
  endtask
endmodule

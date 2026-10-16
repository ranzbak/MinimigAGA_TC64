`timescale 1ns/1ps
// L1 bench: rv_hostcpu + BE memory model + bus contract checker.
// Parameters (iverilog -P tb_rv_l1.<name>=<n>): EXTRA_WS, DEBUG (0 or 2).
// Plusargs: +HEX=<file> +WS=<n> +ROMWS=<n> +TIMEOUT=<cycles, default 20M>
//           +DUMP_ADDR=<hex byte address> +DUMP_N=<words>  (dump after DONE)
//           +VCD=<file>
// Results: "=== PASS" (DONE 0), "=== FAIL <code>" (DONE code, hex),
//          "=== FAIL bus violation", "=== FAIL bad address", "=== TIMEOUT".
module tb_rv_l1;
  parameter EXTRA_WS = 0;
  parameter DEBUG    = 0;

  // clk_114: T114 = 8.8154 ns
  reg clk = 1'b0;
  always #4.4077 clk = ~clk;

  reg reset_n = 1'b0;
  reg rst     = 1'b1;   // bench-side reset (memory model, checker)

  wire [31:2] addr;
  wire [31:0] q, d;
  wire [3:0]  sel;
  wire        wr, req, ack, irq, done, bad_addr, violation, jtag_tdo;
  wire [15:0] done_code;

  rv_hostcpu #(.DEBUG(DEBUG), .EXTRA_WS(EXTRA_WS)) dut (
    .clk(clk), .reset_n(reset_n),
    .addr(addr), .q(q), .sel(sel), .wr(wr), .req(req), .ack(ack), .d(d),
    .irq_ext(irq), .irq_timer(1'b0), .irq_soft(1'b0),
    .jtag_tck(1'b0), .jtag_tms(1'b1), .jtag_tdi(1'b0), .jtag_tdo(jtag_tdo));

  mem_model mem (
    .clk(clk), .rst(rst), .addr(addr), .q(q), .sel(sel), .wr(wr), .req(req),
    .ack(ack), .d(d), .irq(irq), .done(done), .done_code(done_code),
    .bad_addr(bad_addr));

  bus_checker chk (
    .clk(clk), .rst(rst), .req(req), .ack(ack), .wr(wr), .addr(addr), .q(q),
    .sel(sel), .d(d), .violation(violation));

  integer    timeout, dump_n, k;
  reg [31:0] dump_addr;
  reg [1023:0] vcdfile;
  reg [63:0] cycles;

  initial begin
    if (!$value$plusargs("TIMEOUT=%d", timeout))   timeout = 20000000;
    if (!$value$plusargs("DUMP_ADDR=%h", dump_addr)) dump_addr = 32'h0;
    if (!$value$plusargs("DUMP_N=%d", dump_n))     dump_n = 0;
    if ($value$plusargs("VCD=%s", vcdfile)) begin
      $dumpfile(vcdfile);
      $dumpvars(0, tb_rv_l1);
    end
    $display("=== TB EXTRA_WS=%0d DEBUG=%0d TIMEOUT=%0d", EXTRA_WS, DEBUG, timeout);
    // reset_n asserted (asynchronously) from time 0, released after 8 cycles
    repeat (8) @(posedge clk);
    rst     <= 1'b0;
    reset_n <= 1'b1;
  end

  task finish_run;
    begin
`ifdef RV_HOSTCPU_STATS
      dut.stats_report;
`endif
      $display("=== CYCLES %0d", cycles);
      $finish;
    end
  endtask

  always @(posedge clk) begin
    if (rst) cycles <= 64'd0;
    else     cycles <= cycles + 64'd1;

    if (!rst) begin
      if (violation) begin
        $display("=== FAIL bus violation");
        finish_run;
      end else if (bad_addr) begin
        $display("=== FAIL bad address");
        finish_run;
      end else if (done) begin
        for (k = 0; k < dump_n; k = k + 1)
          $display("=== MEM %08x %08x", dump_addr + 4 * k, mem.mem[(dump_addr >> 2) + k]);
        if (done_code == 16'h0) $display("=== PASS");
        else                    $display("=== FAIL %0x", done_code);
        finish_run;
      end else if (cycles >= timeout) begin
        $display("=== TIMEOUT after %0d cycles", cycles);
        finish_run;
      end
    end
  end
endmodule

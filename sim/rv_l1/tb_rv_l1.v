`timescale 1ns/1ps
// L1 bench: rv_hostcpu + BE memory model + bus contract checker.
// Parameters (iverilog -P tb_rv_l1.<name>=<n>, Verilator -G<name>=<n>):
// EXTRA_WS, DEBUG (0 or 2).
// -DDM_SMOKE (DEBUG=2, + jtag_bfm.v tests/dm_smoke.v): the JTAG BFM drives
// the pin TAP and dm_smoke runs the debug sequence; DONE passes only after
// the whole sequence with the memory word DM_CNT = the debugger's target.
// Plusargs: +HEX=<file> +WS=<n> +ROMWS=<n> +TIMEOUT=<cycles, default 20M>
//           +DUMP_ADDR=<hex byte address> +DUMP_N=<words>  (dump after DONE)
//           +VCD=<file>  (iverilog only; Verilator prints a WARNING)
// Results: "=== PASS" (DONE 0), "=== FAIL <code>" (DONE code, hex),
//          "=== FAIL bus violation", "=== FAIL bad address",
//          "=== FAIL uart read" (a read of 0xFFFFFFF0: cfide never acks it),
//          "=== TIMEOUT"; the memory model ends the run at time 0 with
//          "=== FAIL ..." when +HEX cannot be read.
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
  wire        wr, req, ack, irq, done, bad_addr, uart_rd, violation, jtag_tdo;
  wire [15:0] done_code;
  wire        jtck, jtms, jtdi;

`ifdef DM_SMOKE
  jtag_bfm bfm (.tck(jtck), .tms(jtms), .tdi(jtdi), .tdo(jtag_tdo));
  dm_smoke dm ();
`else
  assign jtck = 1'b0;
  assign jtms = 1'b1;
  assign jtdi = 1'b0;
`endif

  rv_hostcpu #(.DEBUG(DEBUG), .EXTRA_WS(EXTRA_WS)) dut (
    .clk(clk), .reset_n(reset_n),
    .addr(addr), .q(q), .sel(sel), .wr(wr), .req(req), .ack(ack), .d(d),
    .irq_ext(irq), .irq_timer(1'b0), .irq_soft(1'b0),
    .jtag_tck(jtck), .jtag_tms(jtms), .jtag_tdi(jtdi), .jtag_tdo(jtag_tdo));

  mem_model mem (
    .clk(clk), .rst(rst), .addr(addr), .q(q), .sel(sel), .wr(wr), .req(req),
    .ack(ack), .d(d), .irq(irq), .done(done), .done_code(done_code),
    .bad_addr(bad_addr), .uart_rd(uart_rd));

  bus_checker chk (
    .clk(clk), .rst(rst), .req(req), .ack(ack), .wr(wr), .addr(addr), .q(q),
    .sel(sel), .d(d), .violation(violation));

  integer    timeout, dump_n, k;
  reg [31:0] dump_addr;
  reg [8*1024-1:0] vcdfile;
  reg [63:0] cycles;

  initial begin
    if (!$value$plusargs("TIMEOUT=%d", timeout))   timeout = 20000000;
    if (!$value$plusargs("DUMP_ADDR=%h", dump_addr)) dump_addr = 32'h0;
    if (!$value$plusargs("DUMP_N=%d", dump_n))     dump_n = 0;
    if ($value$plusargs("VCD=%s", vcdfile)) begin
`ifdef VERILATOR
      // run.sh builds the Verilator images without --trace
      $display("=== WARNING +VCD ignored: waveforms need iverilog (SIM=iverilog)");
`else
      $dumpfile(vcdfile);
      $dumpvars(0, tb_rv_l1);
`endif
    end
    $display("=== TB EXTRA_WS=%0d DEBUG=%0d TIMEOUT=%0d", EXTRA_WS, DEBUG, timeout);
  end

  // reset_n asserted (asynchronously) from time 0, released in the NBA region
  // of the 8th rising edge.  A clocked block, not "repeat (8) @(posedge clk)"
  // plus <= in an initial block: Verilator (--timing) commits the NBAs of a
  // process resumed by the edge before it runs the edge's always blocks, so
  // they saw rst = 0 one edge earlier than in iverilog (the core started one
  // clock earlier against the absolute-time JTAG BFM: dm_smoke differed by
  // one cycle).  Between always blocks both simulators order NBAs alike.
  reg [3:0] rst_cnt = 4'd0;
  always @(posedge clk)
    if (rst_cnt != 4'd8) begin
      rst_cnt <= rst_cnt + 4'd1;
      if (rst_cnt == 4'd7) begin
        rst     <= 1'b0;
        reset_n <= 1'b1;
      end
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
      end else if (uart_rd) begin
        $display("=== FAIL uart read");
        finish_run;
      end else if (done) begin
        for (k = 0; k < dump_n; k = k + 1)
          $display("=== MEM %08x %08x", dump_addr + 4 * k, mem.mem[(dump_addr >> 2) + k]);
`ifdef DM_SMOKE
        if (done_code == 16'h0 && !dm.complete)
          $display("=== FAIL dm DONE before the debug sequence completed");
        else if (done_code == 16'h0 && dm.memval(32'h4000 >> 2) != dm.target)
          $display("=== FAIL dm DM_CNT %0d at DONE, expected %0d", dm.memval(32'h4000 >> 2), dm.target);
        else
`endif
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

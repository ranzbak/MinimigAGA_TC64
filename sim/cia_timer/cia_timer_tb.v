// The CIA timers' count-source selects (INMODE) and the E-clock-aligned
// reload.  Fixes 1.2 and 1.4 in findings/aga-chipset/mister-fixes.md.
//
// These two changes are the kind a demo either notices or does not, with
// nothing in between and no way to tell from the outside which half is wrong.
// So this bench asks the questions directly:
//
//   - does a timer still count the E clock when INMODE says it should?
//   - does it now count NOTHING when INMODE selects CNT, which is tied high in
//     this design and therefore never has an edge?  That is the whole of the
//     Crystal Kingdom Dizzy fix: a 16-bit one-shot set up that way used to
//     underflow within 92 ms, where real hardware never underflows at all.
//   - is the reload aligned to the E clock, so the first interval after a
//     timer-high write is not short?  That one is heard rather than seen --
//     Risky Woods gets its music tempo wrong.
//
// iverilog, so it can run while a Vivado build holds the machine.
// Run: ./run.sh

`timescale 1ns/1ps

module cia_timer_tb;

  reg clk = 0;
  always #17.8 clk = ~clk;

  reg [1:0] ph = 0;
  always @(posedge clk) ph <= ph + 2'd1;
  wire clk7_en = (ph == 2'd0);

  // The E clock: one enable every 10 clk7 ticks, as the CIAs see it.
  reg [3:0] ediv = 0;
  reg       eclk = 0;
  always @(posedge clk)
    if (clk7_en) begin
      if (ediv == 4'd9) begin
        ediv <= 4'd0;
        eclk <= 1'b1;
      end else begin
        ediv <= ediv + 4'd1;
        eclk <= 1'b0;
      end
    end

  reg        wr = 0, tlo = 0, thi = 0, tcr = 0;
  reg  [7:0] data_in = 0;
  reg        reset = 1;
  reg        cnt = 1'b1;          // idle high, as minimig.v ties it

  wire [7:0] a_out, b_out;
  wire       a_ovf, a_irq, b_irq, spmode;

  cia_timera ta (
    .clk(clk), .clk7_en(clk7_en), .wr(wr), .reset(reset),
    .tlo(tlo), .thi(thi), .tcr(tcr),
    .data_in(data_in), .data_out(a_out),
    .eclk(eclk), .cnt(cnt),
    .tmra_ovf(a_ovf), .spmode(spmode), .irq(a_irq)
  );

  cia_timerb tb_i (
    .clk(clk), .clk7_en(clk7_en), .wr(wr), .reset(reset),
    .tlo(tlo), .thi(thi), .tcr(tcr),
    .data_in(data_in), .data_out(b_out),
    .eclk(eclk), .cnt(cnt), .tmra_ovf(a_ovf), .irq(b_irq)
  );

  integer errors = 0;

  task step(input integer n);
    integer i;
    begin
      for (i = 0; i < n; i = i + 1) @(posedge clk);
    end
  endtask

  // Write one CIA register: assert the select and wr for a single clk7 tick.
  task wreg(input integer which, input [7:0] val);
    begin
      @(posedge clk);
      while (!clk7_en) @(posedge clk);
      data_in = val;
      tlo = (which == 0); thi = (which == 1); tcr = (which == 2);
      wr  = 1'b1;
      @(posedge clk);
      wr  = 1'b0; tlo = 0; thi = 0; tcr = 0;
    end
  endtask

  task check(input [8*48:1] what, input integer got, input integer want);
    begin
      if (got !== want) begin
        $display("FAIL: %0s = %0d, expected %0d", what, got, want);
        errors = errors + 1;
      end else
        $display("  ok: %0s = %0d", what, got);
    end
  endtask

  integer start_val, end_val;

  // Fix 1.2 lives or dies on WHEN the reload happens, not whether it happens,
  // so watching the counter arrive at its new value proves nothing -- the old
  // code reloaded too, just a fraction early.  Watch the reload strobe itself
  // instead: every reload that comes from a timer-high write must coincide
  // with an E-clock edge.  (forceload and underflow reloads are a different
  // path and are not part of this rule.)
  reg checking_reload = 1'b0;
  always @(posedge clk)
    if (clk7_en && checking_reload && ta.reload && !ta.forceload && !ta.underflow) begin
      if (!eclk) begin
        $display("FAIL: timer A reload asserted off the E clock");
        errors = errors + 1;
      end else
        $display("  ok: timer A reload landed on an E-clock edge");
    end

  initial begin
    $dumpfile("cia_timer.vcd");
    $dumpvars(0, cia_timer_tb);

    step(20);
    reset = 0;
    step(20);

    // ---- Timer A, INMODE = 0: counts the E clock -------------------------
    $display("--- timer A, INMODE=0 (E clock) ---");
    wreg(0, 8'hff);          // TALO
    wreg(1, 8'h00);          // TAHI -> counter = 0x00ff
    wreg(2, 8'b0000_0001);   // CRA: START=1, INMODE(bit5)=0
    step(4000);
    start_val = ta.tmr;
    step(8000);
    end_val = ta.tmr;
    if (start_val == end_val) begin
      $display("FAIL: timer A did not count at all with INMODE=0");
      errors = errors + 1;
    end else
      $display("  ok: timer A counts on E (%0d -> %0d)", start_val, end_val);

    // ---- Timer A, INMODE = 1: counts CNT edges, and CNT never moves ------
    $display("--- timer A, INMODE=1 (CNT, tied high) ---");
    wreg(2, 8'b0000_0000);   // stop
    wreg(0, 8'hff);
    wreg(1, 8'h00);
    wreg(2, 8'b0010_0001);   // CRA: START=1, INMODE=1
    step(4000);
    start_val = ta.tmr;
    step(20000);
    check("timer A counter after 20000 clk, INMODE=1", ta.tmr, start_val);
    // The defect in one line: before the fix this counted the E clock.

    // ---- Timer B, INMODE = 01: CNT, likewise counts nothing --------------
    $display("--- timer B, INMODE=01 (CNT, tied high) ---");
    reset = 1; step(20); reset = 0; step(20);
    wreg(0, 8'hff);
    wreg(1, 8'h00);
    wreg(2, 8'b0010_0001);   // CRB: START=1, INMODE=01
    step(4000);
    start_val = tb_i.tmr;
    step(20000);
    check("timer B counter after 20000 clk, INMODE=01", tb_i.tmr, start_val);

    // ---- The reload lands on an E-clock edge -----------------------------
    $display("--- reload is aligned to the E clock ---");
    reset = 1; step(20); reset = 0; step(20);
    wreg(2, 8'b0000_0000);   // stopped
    wreg(0, 8'h34);
    checking_reload = 1'b1;
    wreg(1, 8'h12);          // triggers the reload path
    step(1200);              // more than one E period
    checking_reload = 1'b0;
    check("timer A reloaded to 0x1234", ta.tmr, 32'h1234);

    if (errors == 0)
      $display("\n=== PASS: 0 failures ===");
    else
      $display("\n=== FAIL: %0d failures ===", errors);
    $finish;
  end

endmodule
